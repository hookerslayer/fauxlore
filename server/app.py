import base64
import binascii
import hashlib
import json
import logging
import os
import re
import secrets
import smtplib
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from email.message import EmailMessage
from pathlib import Path

from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError, InvalidHashError
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from psycopg.errors import UniqueViolation
from psycopg.types.json import Jsonb
from .database import ROOT, connect, initialize, CATEGORY_PALETTES

hasher = PasswordHasher()
DUMMY_HASH = hasher.hash(secrets.token_urlsafe(32))
COOKIE = 'fauxlore_session'
attempts = defaultdict(deque)


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


@asynccontextmanager
async def lifespan(app):
    initialize()
    yield


app = FastAPI(title='Fauxlore API', lifespan=lifespan, docs_url=None, redoc_url=None)


@app.middleware('http')
async def headers_and_origin(request, call_next):
    # Cookie-authenticated writes must originate from this site. No wildcard CORS.
    if request.method not in ('GET', 'HEAD', 'OPTIONS'):
        origin = request.headers.get('origin')
        expected = os.getenv('APP_ORIGIN', str(request.base_url).rstrip('/'))
        allowed_origins={expected}
        if os.getenv('APP_ENV','local')=='local' and request.url.hostname in ('localhost','127.0.0.1'):
            allowed_origins.add(str(request.base_url).rstrip('/'))
        if origin and origin not in allowed_origins:
            return Response('Origin rejected', status_code=403)
        if request.headers.get('sec-fetch-site') == 'cross-site':
            return Response('Cross-site write rejected', status_code=403)
        if not request.headers.get('content-type','').startswith('application/json'):
            return Response('JSON required', status_code=415)
        large_json=request.url.path in ('/api/profile/avatar','/api/chat/messages')
        if int(request.headers.get('content-length','0')) > (3*1024*1024 if large_json else 65536):
            return Response('Request too large', status_code=413)
    response = await call_next(request)
    response.headers['X-Content-Type-Options'] = 'nosniff'
    response.headers['Referrer-Policy'] = 'same-origin'
    response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    if request.url.path.startswith('/api/'):
        response.headers['Cache-Control'] = 'no-store'
    return response


def limit(request, action, maximum=12):
    key = (request.client.host, action)
    now = time.monotonic()
    bucket = attempts[key]
    while bucket and bucket[0] < now-900:
        bucket.popleft()
    if len(bucket) >= maximum:
        raise HTTPException(429, 'Слишком много попыток. Попробуйте через 15 минут.')
    bucket.append(now)
    if len(attempts) > 10000:
        for old in list(attempts):
            if not attempts[old] or attempts[old][-1] < now-900:
                del attempts[old]


def current_user(request):
    token = request.cookies.get(COOKIE)
    if not token:
        return None
    with connect() as db:
        return db.execute('''SELECT a.id,a.email,a.nickname,a.role,a.reputation,a.avatar_type,a.chat_banned,a.is_test_profile,
            COALESCE((SELECT array_agg(state_id) FROM account_states x WHERE x.account_id=a.id),'{}') AS state_ids
            FROM accounts a JOIN sessions s ON a.id=s.account_id
            WHERE s.token_hash=%s AND s.expires_at>now()''', (digest(token),)).fetchone()


def require_user(request, admin=False):
    user = current_user(request)
    if not user:
        raise HTTPException(401, 'Войдите в аккаунт')
    if admin and user['role'] != 'admin':
        raise HTTPException(403, 'Нужна роль admin')
    return user


def request_actor(db,request):
    user=require_user(request)
    test_id=request.headers.get('x-fauxlore-test-profile')
    if not test_id:return user
    if user['role']!='admin':raise HTTPException(403,'Тестовые профили доступны только администратору')
    try:test_id=int(test_id)
    except ValueError:raise HTTPException(400,'Некорректный тестовый профиль')
    profile=db.execute("SELECT id,email,nickname,role,reputation,avatar_type,chat_banned,is_test_profile FROM accounts WHERE id=%s AND is_test_profile=true",(test_id,)).fetchone()
    if not profile:raise HTTPException(403,'Тестовый профиль не найден')
    return profile


IMAGE_TYPES={'image/png':(b'\x89PNG\r\n\x1a\n',),'image/jpeg':(b'\xff\xd8\xff',),'image/gif':(b'GIF87a',b'GIF89a'),'image/webp':(b'RIFF',)}
MAX_IMAGE_SIZE=2*1024*1024


def image_bytes(data_url):
    if not data_url:return None,None
    if not isinstance(data_url,str) or ',' not in data_url:raise HTTPException(422,'Не удалось прочитать изображение')
    header,encoded=data_url.split(',',1)
    mime=header[5:].split(';',1)[0].lower() if header.startswith('data:') else ''
    signatures=IMAGE_TYPES.get(mime)
    if not signatures:raise HTTPException(422,'Поддерживаются PNG, JPEG, GIF и WebP')
    try:data=base64.b64decode(encoded,validate=True)
    except (binascii.Error,ValueError):raise HTTPException(422,'Некорректный файл изображения')
    if not data or len(data)>MAX_IMAGE_SIZE:raise HTTPException(413,'Размер изображения не должен превышать 2 МБ')
    valid=any(data.startswith(signature) for signature in signatures)
    if mime=='image/webp':valid=valid and len(data)>=12 and data[8:12]==b'WEBP'
    if not valid:raise HTTPException(422,'Содержимое файла не совпадает с его форматом')
    return data,mime


class Credentials(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    password: str = Field(min_length=1, max_length=128)


class Registration(Credentials):
    nickname: str = Field(min_length=2, max_length=40)


def email_value(value):
    value = value.strip().lower()
    if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', value):
        raise HTTPException(422, 'Проверьте адрес электронной почты')
    return value


def issue_session(db, response, account_id):
    token = secrets.token_urlsafe(48)
    db.execute('DELETE FROM sessions WHERE expires_at<now()')
    db.execute("INSERT INTO sessions VALUES(%s,%s,now()+interval '7 days')", (digest(token),account_id))
    response.set_cookie(COOKIE, token, httponly=True, samesite='lax', max_age=604800,
                        secure=os.getenv('COOKIE_SECURE') == '1', path='/')


@app.get('/api/health')
def health():
    with connect() as db:
        db.execute('SELECT 1')
    return {'ok': True, 'database': 'postgresql'}


@app.get('/api/map')
def map_data():
    with connect() as db:
        provinces = db.execute('SELECT * FROM provinces ORDER BY id').fetchall()
        values = db.execute('''SELECT v.province_id,v.layer,c.id,c.name,c.color
            FROM province_values v JOIN map_categories c ON (v.layer,v.category_id)=(c.layer,c.id)''').fetchall()
        categories = db.execute('SELECT * FROM map_categories ORDER BY layer,name').fetchall()
    by_id = {p['id']:p for p in provinces}
    state_colors = {c['name']:c['color'] for c in categories if c['layer']=='states'}
    for value in values:
        by_id[value['province_id']].setdefault('layers',{})[value['layer']] = {
            k:value[k] for k in ('id','name','color')}
    for province in provinces:
        if province['kind']=='sea':
            # Sea cells keep only their identity and geometry needed by the renderer.
            province.pop('layers',None)
            for field in ('province_type','courts','population','development','taxes','production',
                          'warehouse','control','tension','has_capital_marker','has_city_marker',
                          'control_color'):
                province.pop(field,None)
            continue
        if province.get('control') and province.get('control') != province.get('layers',{}).get('states',{}).get('name'):
            province['control_color']=state_colors.get(province['control'])
    return {'provinces': provinces, 'categories': categories,
            'adjacency': json.loads((ROOT/'map-data/province-adjacency.json').read_text()),
            'region': json.loads((ROOT/'map-data/view-region.json').read_text())['bounds'],
            'calendar': {'year':1452,'turn':1}}


@app.get('/api/auth/me')
def me(request: Request):
    return {'user':current_user(request)}


@app.post('/api/auth/register')
def register(body: Registration, request: Request, response: Response):
    limit(request,'register',6)
    email = email_value(body.email)
    if len(body.password)<10:
        raise HTTPException(422,'Пароль должен содержать не менее 10 символов')
    nickname = body.nickname.strip()
    if len(nickname)<2:
        raise HTTPException(422,'Укажите имя длиной от 2 символов')
    try:
        with connect() as db:
            user = db.execute('''INSERT INTO accounts(email,nickname,password_hash) VALUES(%s,%s,%s)
                RETURNING id,email,nickname,role''',(email,nickname,hasher.hash(body.password))).fetchone()
            issue_session(db,response,user['id'])
    except UniqueViolation:
        raise HTTPException(409,'Не удалось зарегистрироваться с этим email')
    return {'user':{**user,'state_ids':[],'reputation':0,'avatar_type':None,'chat_banned':False,'is_test_profile':False}}


@app.post('/api/auth/login')
def login(body: Credentials, request: Request, response: Response):
    limit(request,'login')
    with connect() as db:
        user = db.execute('''SELECT a.*,
            COALESCE((SELECT array_agg(state_id) FROM account_states x WHERE x.account_id=a.id),'{}') AS state_ids
            FROM accounts a WHERE email=%s''',(email_value(body.email),)).fetchone()
        try:
            hasher.verify(user['password_hash'] if user else DUMMY_HASH,body.password)
        except (VerifyMismatchError,InvalidHashError):
            raise HTTPException(401,'Неверный email или пароль')
        if not user or user['is_test_profile']:
            raise HTTPException(401,'Неверный email или пароль')
        issue_session(db,response,user['id'])
    return {'user':{k:user[k] for k in ('id','email','nickname','role','state_ids','reputation','avatar_type','chat_banned','is_test_profile')}}


@app.post('/api/auth/logout')
def logout(request: Request, response: Response):
    with connect() as db:
        db.execute('DELETE FROM sessions WHERE token_hash=%s',(digest(request.cookies.get(COOKIE,'')),))
    response.delete_cookie(COOKIE,path='/')
    return {'ok':True}


class EmailBody(BaseModel):
    email: str = Field(max_length=254)


@app.post('/api/auth/reset-request')
def reset_request(body: EmailBody, request: Request):
    limit(request,'reset',5)
    with connect() as db:
        user = db.execute('SELECT id,email FROM accounts WHERE email=%s',(email_value(body.email),)).fetchone()
        if user:
            token = secrets.token_urlsafe(48)
            db.execute('DELETE FROM password_resets WHERE account_id=%s OR expires_at<now()',(user['id'],))
            db.execute("INSERT INTO password_resets VALUES(%s,%s,now()+interval '30 minutes')",(digest(token),user['id']))
            # Configured origin prevents Host-header injection in email links.
            link = os.getenv('APP_ORIGIN','http://127.0.0.1:8002').rstrip('/')+'/#reset='+token
            message = EmailMessage()
            message['Subject'] = 'Fauxlore — восстановление доступа'
            message['To'] = user['email']
            message['From'] = os.getenv('SMTP_FROM','noreply@localhost')
            message.set_content('Ссылка действует 30 минут:\n'+link)
            if os.getenv('SMTP_HOST'):
                try:
                    with smtplib.SMTP(os.environ['SMTP_HOST'],int(os.getenv('SMTP_PORT','587')),timeout=10) as smtp:
                        smtp.starttls()
                        if os.getenv('SMTP_USER'):
                            smtp.login(os.environ['SMTP_USER'],os.environ['SMTP_PASSWORD'])
                        smtp.send_message(message)
                except (OSError,smtplib.SMTPException):
                    logging.error('Password reset email delivery failed')
                    raise HTTPException(503,'Сервис доставки почты временно недоступен')
            elif os.getenv('APP_ENV','local') == 'local':
                outbox = ROOT/'.local/mail'
                outbox.mkdir(parents=True,exist_ok=True)
                (outbox/f'{secrets.token_hex(12)}.eml').write_bytes(message.as_bytes())
            else:
                raise HTTPException(503,'Доставка почты не настроена')
    return {'message':'Если аккаунт существует, инструкция отправлена. В локальном режиме письмо сохраняется в .local/mail.'}


class ResetBody(BaseModel):
    token: str = Field(min_length=20,max_length=128)
    password: str = Field(min_length=10,max_length=128)


@app.post('/api/auth/reset')
def reset(body: ResetBody, request: Request):
    limit(request,'reset-confirm')
    with connect() as db:
        row = db.execute('DELETE FROM password_resets WHERE token_hash=%s AND expires_at>now() RETURNING account_id',
                         (digest(body.token),)).fetchone()
        if not row:
            raise HTTPException(400,'Ссылка недействительна или истекла')
        db.execute('UPDATE accounts SET password_hash=%s WHERE id=%s',(hasher.hash(body.password),row['account_id']))
        db.execute('DELETE FROM sessions WHERE account_id=%s',(row['account_id'],))
    return {'message':'Пароль обновлён. Войдите с новым паролем.'}


class AvatarBody(BaseModel):
    image_data: str | None = Field(default=None,max_length=2800000)


class ChatMessageBody(BaseModel):
    text: str | None = Field(default=None,max_length=2000)
    image_data: str | None = Field(default=None,max_length=2800000)
    image_selected: bool = False


class ReactionBody(BaseModel):
    reaction: str


class ChatBanBody(BaseModel):
    banned: bool


def ensure_test_profiles(db):
    rows=db.execute('SELECT id,email,nickname,role,reputation,is_test_profile,chat_banned FROM accounts WHERE is_test_profile=true ORDER BY id LIMIT 2').fetchall()
    for number in range(len(rows)+1,3):
        email=f'fauxlore-test-{number}@invalid.local'
        row=db.execute('''INSERT INTO accounts(email,nickname,password_hash,is_test_profile)
            VALUES(%s,%s,%s,true) ON CONFLICT(email) DO UPDATE SET is_test_profile=true
            RETURNING id,email,nickname,role,reputation,is_test_profile,chat_banned''',
            (email,f'Тестовый игрок {number}',hasher.hash(secrets.token_urlsafe(32)))).fetchone()
        rows.append(row)
    return rows


@app.get('/api/admin/test-profiles')
def admin_test_profiles(request: Request):
    require_user(request,admin=True)
    with connect() as db:
        return ensure_test_profiles(db)


@app.get('/api/profile')
def profile(request: Request):
    with connect() as db:
        actor=request_actor(db,request)
        return {k:actor[k] for k in ('id','email','nickname','role','reputation','avatar_type','chat_banned','is_test_profile')}


@app.post('/api/profile/avatar')
def update_avatar(body: AvatarBody, request: Request):
    with connect() as db:
        actor=request_actor(db,request)
        data,mime=image_bytes(body.image_data)
        db.execute('UPDATE accounts SET avatar_data=%s,avatar_type=%s WHERE id=%s',(data,mime,actor['id']))
    return {'ok':True,'avatar_url':f"/api/profile/avatar/{actor['id']}" if data else None}


@app.get('/api/profile/avatar/{account_id}')
def get_avatar(account_id: int, request: Request):
    require_user(request)
    with connect() as db:
        row=db.execute('SELECT avatar_data,avatar_type FROM accounts WHERE id=%s',(account_id,)).fetchone()
    if not row or not row['avatar_data']:raise HTTPException(404,'Аватар не найден')
    return Response(content=bytes(row['avatar_data']),media_type=row['avatar_type'],headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'})


def profile_card(row):
    account_id=row.get('author_id',row['id'])
    return {'id':account_id,'nickname':row['nickname'],'role':row['role'],'reputation':row['reputation'],
            'avatar_url':f"/api/profile/avatar/{account_id}" if row.get('avatar_type') else None,
            'is_test_profile':row.get('is_test_profile',False)}


@app.get('/api/chat/messages')
def chat_messages(request: Request):
    actual=require_user(request)
    with connect() as db:
        actor=request_actor(db,request)
        messages=db.execute('''SELECT m.id,m.account_id,m.body,m.image_type,m.created_at,m.deleted_at,
                a.id AS author_id,a.nickname,a.role,a.reputation,a.avatar_type,a.chat_banned
            FROM (SELECT * FROM chat_messages ORDER BY id DESC LIMIT 100) m
            JOIN accounts a ON a.id=m.account_id ORDER BY m.id''').fetchall()
        ids=[m['id'] for m in messages]
        reactions={}
        if ids:
            for row in db.execute('SELECT message_id,reaction,count(*) AS total FROM chat_reactions WHERE message_id=ANY(%s) GROUP BY message_id,reaction',(ids,)).fetchall():
                reactions.setdefault(row['message_id'],{})[row['reaction']]=row['total']
            mine={row['message_id']:row['reaction'] for row in db.execute('SELECT message_id,reaction FROM chat_reactions WHERE message_id=ANY(%s) AND account_id=%s',(ids,actor['id'])).fetchall()}
        else:mine={}
        output=[]
        for message in messages:
            deleted=message['deleted_at'] is not None
            output.append({'id':message['id'],'text':'Сообщение удалено администратором' if deleted else message['body'],
                'image_url':None if deleted or not message['image_type'] else f"/api/chat/messages/{message['id']}/image",
                'created_at':message['created_at'],'deleted':deleted,'author':profile_card(message),
                'reactions':reactions.get(message['id'],{}),'my_reaction':mine.get(message['id']),
                'can_delete':actual['role']=='admin' and not deleted,
                'can_mute':actual['role']=='admin' and message['role']!='admin' and not message['chat_banned'],
                'author_banned':message['chat_banned']})
        return {'messages':output,'current_user':profile_card(actor),'can_moderate':actual['role']=='admin','muted':actor['chat_banned']}


@app.post('/api/chat/messages')
def send_chat_message(body: ChatMessageBody, request: Request):
    actual=require_user(request);text=(body.text or '').strip() or None
    with connect() as db:
        actor=request_actor(db,request)
        if actor['chat_banned']:raise HTTPException(403,'Этому профилю запрещено писать в чат')
        data,mime=image_bytes(body.image_data)
        if body.image_selected and not data:raise HTTPException(422,'Изображение не было передано. Выберите файл ещё раз.')
        if not text and not data:raise HTTPException(422,'Добавьте текст или изображение')
        row=db.execute('INSERT INTO chat_messages(account_id,body,image_data,image_type) VALUES(%s,%s,%s,%s) RETURNING id',(actor['id'],text,data,mime)).fetchone()
    return {'id':row['id'],'image_attached':bool(data)}


@app.get('/api/chat/messages/{message_id}/image')
def chat_image(message_id: int, request: Request):
    require_user(request)
    with connect() as db:
        row=db.execute('SELECT image_data,image_type FROM chat_messages WHERE id=%s AND deleted_at IS NULL',(message_id,)).fetchone()
    if not row or not row['image_data']:raise HTTPException(404,'Изображение не найдено')
    return Response(content=bytes(row['image_data']),media_type=row['image_type'],headers={'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'})


@app.post('/api/chat/messages/{message_id}/reaction')
def react_to_message(message_id: int, body: ReactionBody, request: Request):
    if body.reaction not in ('laugh','like','dislike'):raise HTTPException(422,'Неизвестная реакция')
    with connect() as db:
        actor=request_actor(db,request)
        message=db.execute('SELECT account_id FROM chat_messages WHERE id=%s AND deleted_at IS NULL FOR UPDATE',(message_id,)).fetchone()
        if not message:raise HTTPException(404,'Сообщение не найдено')
        previous=db.execute('SELECT reaction FROM chat_reactions WHERE message_id=%s AND account_id=%s FOR UPDATE',(message_id,actor['id'])).fetchone()
        new_reaction=None if previous and previous['reaction']==body.reaction else body.reaction
        impact={'like':1,'dislike':-1,'laugh':0}
        delta=(impact[new_reaction] if new_reaction else 0)-(impact[previous['reaction']] if previous else 0)
        if new_reaction:
            db.execute('''INSERT INTO chat_reactions(message_id,account_id,reaction) VALUES(%s,%s,%s)
                ON CONFLICT(message_id,account_id) DO UPDATE SET reaction=excluded.reaction''',(message_id,actor['id'],new_reaction))
        elif previous:db.execute('DELETE FROM chat_reactions WHERE message_id=%s AND account_id=%s',(message_id,actor['id']))
        reputation_delta=delta if message['account_id']!=actor['id'] else 0
        if reputation_delta:db.execute('UPDATE accounts SET reputation=reputation+%s WHERE id=%s',(reputation_delta,message['account_id']))
        return {'reaction':new_reaction,'reputation_delta':reputation_delta}


@app.delete('/api/admin/chat/messages/{message_id}')
def delete_chat_message(message_id: int, request: Request):
    require_user(request,admin=True)
    with connect() as db:
        message=db.execute('SELECT account_id FROM chat_messages WHERE id=%s AND deleted_at IS NULL FOR UPDATE',(message_id,)).fetchone()
        if not message:raise HTTPException(404,'Сообщение не найдено')
        impact=db.execute("SELECT COALESCE(sum(CASE reaction WHEN 'like' THEN 1 WHEN 'dislike' THEN -1 ELSE 0 END),0) AS score FROM chat_reactions WHERE message_id=%s",(message_id,)).fetchone()['score']
        if impact:db.execute('UPDATE accounts SET reputation=reputation-%s WHERE id=%s',(impact,message['account_id']))
        db.execute('DELETE FROM chat_reactions WHERE message_id=%s',(message_id,))
        db.execute('UPDATE chat_messages SET body=NULL,image_data=NULL,image_type=NULL,deleted_at=now() WHERE id=%s',(message_id,))
    return {'ok':True}


@app.post('/api/admin/chat/users/{account_id}/ban')
def set_chat_ban(account_id: int, body: ChatBanBody, request: Request):
    admin=require_user(request,admin=True)
    with connect() as db:
        target=db.execute('SELECT role,is_test_profile FROM accounts WHERE id=%s FOR UPDATE',(account_id,)).fetchone()
        if not target:raise HTTPException(404,'Пользователь не найден')
        if target['role']=='admin' or account_id==admin['id']:raise HTTPException(403,'Нельзя ограничить чат другому администратору')
        db.execute('UPDATE accounts SET chat_banned=%s WHERE id=%s',(body.banned,account_id))
    return {'ok':True,'banned':body.banned}


@app.get('/api/preferences')
def preferences(request: Request):
    user = require_user(request)
    with connect() as db:
        row = db.execute('SELECT settings FROM user_preferences WHERE account_id=%s',(user['id'],)).fetchone()
    return row['settings'] if row else {}


@app.put('/api/preferences')
def save_preferences(body: dict, request: Request):
    user = require_user(request)
    # Only explicit visual settings; no arbitrary session or permission fields.
    clean = {k:v for k,v in body.items() if k in ('layer','markers','information','showIds')}
    if len(json.dumps(clean))>8192:
        raise HTTPException(422,'Слишком большой набор настроек')
    with connect() as db:
        db.execute('''INSERT INTO user_preferences VALUES(%s,%s) ON CONFLICT(account_id)
            DO UPDATE SET settings=excluded.settings''',(user['id'],Jsonb(clean)))
    return {'ok':True}


PROVINCE_TYPES={'Столица','Город','Регион','Колония','Нейтральная'}
EDITABLE_LAYERS={'race':'races','religion':'religions','state':'states','resource':'resources','trade':'trade','climate':'climate'}


class ProvinceEdit(BaseModel):
    model_config={'extra':'forbid'}
    name: str | None = Field(default=None,max_length=120)
    race: str | None = Field(default=None,max_length=80)
    religion: str | None = Field(default=None,max_length=80)
    state: str | None = Field(default=None,max_length=100)
    province_type: str | None = Field(default=None,max_length=30)
    courts: int | None = Field(default=None,ge=0,le=100000000)
    resource: str | None = Field(default=None,max_length=80)
    trade: str | None = Field(default=None,max_length=80)
    development: int | None = Field(default=None,ge=0,le=1000000)
    control: str | None = Field(default=None,max_length=100)
    climate: str | None = Field(default=None,max_length=80)
    capital: bool | None = None
    city: bool | None = None


class BulkRule(BaseModel):
    model_config={'extra':'forbid'}
    condition_field: str
    condition_value: object = None
    target_field: str
    target_value: object = None


class BulkEdit(BaseModel):
    model_config={'extra':'forbid'}
    rules: list[BulkRule] = Field(min_length=1,max_length=50)


def category_color(name):
    raw=hashlib.sha256(name.encode('utf-8')).digest()
    return '#'+''.join(f'{75+byte%141:02x}' for byte in raw[:3])


def assign_category(db,province_id,layer,name,allow_new=False):
    name=(name or '').strip()
    if not name:
        db.execute('DELETE FROM province_values WHERE province_id=%s AND layer=%s',(province_id,layer))
        return None
    category=db.execute('SELECT id FROM map_categories WHERE layer=%s AND lower(name)=lower(%s)',(layer,name)).fetchone()
    if not category and allow_new:
        color=category_color(name)
        category=db.execute('''INSERT INTO map_categories(layer,id,name,color)
            SELECT %s,COALESCE(max(id),0)+1,%s,%s FROM map_categories WHERE layer=%s
            RETURNING id''',(layer,name,color,layer)).fetchone()
    if not category:
        raise HTTPException(422,f'Неизвестное значение: {name}')
    db.execute('''INSERT INTO province_values(province_id,layer,category_id) VALUES(%s,%s,%s)
        ON CONFLICT(province_id,layer) DO UPDATE SET category_id=excluded.category_id''',
        (province_id,layer,category['id']))
    return category['id']


def ensure_state_category(db,name):
    category=db.execute("SELECT id,name FROM map_categories WHERE layer='states' AND lower(name)=lower(%s)",(name,)).fetchone()
    if category:return category
    category_id=db.execute("SELECT COALESCE(max(id),0)+1 AS id FROM map_categories WHERE layer='states'").fetchone()['id']
    return db.execute("INSERT INTO map_categories(layer,id,name,color) VALUES('states',%s,%s,%s) RETURNING id,name",
                      (category_id,name,category_color(name))).fetchone()


def province_payload(db,province_id):
    province=db.execute('SELECT * FROM provinces WHERE id=%s',(province_id,)).fetchone()
    if not province:return None
    province=dict(province)
    province['layers']={}
    for row in db.execute('''SELECT v.layer,c.id,c.name,c.color FROM province_values v
        JOIN map_categories c ON (v.layer,v.category_id)=(c.layer,c.id) WHERE v.province_id=%s''',(province_id,)).fetchall():
        province['layers'][row['layer']]={k:row[k] for k in ('id','name','color')}
    owner=province['layers'].get('states',{}).get('name')
    if province.get('control') and province['control']!=owner:
        color=db.execute("SELECT color FROM map_categories WHERE layer='states' AND name=%s",(province['control'],)).fetchone()
        province['control_color']=color['color'] if color else None
    return province


BULK_SCALAR_FIELDS={'province_type':'province_type','courts':'courts','development':'development','control':'control','capital':'has_capital_marker','city':'has_city_marker'}
BULK_FIELDS={**EDITABLE_LAYERS,**{key:key for key in BULK_SCALAR_FIELDS}}


def normalize_bulk_value(field,value,target=False):
    if field not in BULK_FIELDS:
        raise HTTPException(422,'Неизвестный параметр правила')
    if field in EDITABLE_LAYERS:
        if value is None:return None
        if not isinstance(value,str) or len(value)>120:
            raise HTTPException(422,'Для категорий укажите текстовое значение или «не задано»')
        value=value.strip() or None
        if target and value and field=='state':return value
        return value
    if field=='province_type':
        if not isinstance(value,str) or value not in PROVINCE_TYPES:raise HTTPException(422,'Неизвестный тип провинции')
        return value
    if field in ('courts','development'):
        limit=100000000 if field=='courts' else 1000000
        if isinstance(value,bool) or not isinstance(value,int) or value<0 or value>limit:
            raise HTTPException(422,'Значение должно быть целым неотрицательным числом')
        return value
    if field in ('capital','city'):
        if not isinstance(value,bool):raise HTTPException(422,'Для маркера выберите да или нет')
        return value
    if value is None:return None
    if not isinstance(value,str) or len(value)>120:raise HTTPException(422,'Значение должно быть текстом')
    return value.strip() or None


def bulk_rule_ids(db,field,value,bounds):
    x0,y0,x1,y1=bounds
    clauses=["p.kind='land'", "(p.center->>0)::double precision >= %s", "(p.center->>0)::double precision < %s", "(p.center->>1)::double precision >= %s", "(p.center->>1)::double precision < %s"]
    params=[x0,x1,y0,y1]
    if field in EDITABLE_LAYERS:
        layer=EDITABLE_LAYERS[field]
        exists="EXISTS (SELECT 1 FROM province_values v JOIN map_categories c ON (v.layer,v.category_id)=(c.layer,c.id) WHERE v.province_id=p.id AND v.layer=%s AND lower(c.name)=lower(%s))"
        if value is None:clauses.append("NOT EXISTS (SELECT 1 FROM province_values v WHERE v.province_id=p.id AND v.layer=%s)");params.append(layer)
        else:clauses.append(exists);params.extend((layer,value))
    else:
        col=BULK_SCALAR_FIELDS[field]
        if field=='control' and value is not None:
            clauses.append(f"lower(p.{col})=lower(%s)");params.append(value)
        else:clauses.append(f"p.{col} IS NOT DISTINCT FROM %s");params.append(value)
    rows=db.execute(f"SELECT p.id FROM provinces p WHERE {' AND '.join(clauses)} ORDER BY p.id",params).fetchall()
    return [row['id'] for row in rows]


def apply_province_changes(db,province,changes):
    province_id=province['id']
    if 'name' in changes and not (changes['name'] or '').strip():raise HTTPException(422,'Название не может быть пустым')
    if 'province_type' in changes and changes['province_type'] not in PROVINCE_TYPES:raise HTTPException(422,'Неизвестный тип провинции')
    for field in ('capital','city'):
        if field in changes and changes[field] is None:raise HTTPException(422,'Укажите значение маркера')
    for field in ('race','religion','resource','climate'):
        if field in changes and changes[field] is not None:changes[field]=changes[field].strip() or None
    if 'state' in changes and changes['state'] is not None:changes['state']=changes['state'].strip()
    if 'control' in changes and changes['control'] is not None:changes['control']=changes['control'].strip() or None
    if province['kind']!='land':raise HTTPException(422,'Редактировать можно только сухопутные провинции')
    for field,layer in EDITABLE_LAYERS.items():
        if field in changes:assign_category(db,province_id,layer,changes[field],allow_new=field=='state')
    if 'control' in changes and changes['control']:changes['control']=ensure_state_category(db,changes['control'])['name']
    updates={}
    if 'name' in changes:updates['name']=changes['name'].strip()
    if 'courts' in changes:updates.update(courts=changes['courts'],population=changes['courts']*4)
    if 'development' in changes:updates['development']=changes['development']
    if 'control' in changes:updates['control']=changes['control']
    if 'capital' in changes:updates['has_capital_marker']=changes['capital']
    if 'city' in changes:updates['has_city_marker']=changes['city']
    state_exists=db.execute("SELECT 1 FROM province_values WHERE province_id=%s AND layer='states'",(province_id,)).fetchone() is not None
    capital=updates.get('has_capital_marker',province['has_capital_marker']);city=updates.get('has_city_marker',province['has_city_marker'])
    dependencies=any(field in changes for field in ('capital','city','state'))
    if capital:updates['province_type']='Столица'
    elif city:updates['province_type']='Город'
    elif 'province_type' in changes:updates['province_type']=changes['province_type']
    elif dependencies:updates['province_type']='Регион' if state_exists else 'Нейтральная'
    if updates:
        assignments=', '.join(f'{field}=%s' for field in updates)
        db.execute(f'UPDATE provinces SET {assignments} WHERE id=%s',(*updates.values(),province_id))


@app.patch('/api/admin/provinces/{province_id}')
def edit_province(province_id: int, body: ProvinceEdit, request: Request):
    require_user(request,admin=True)
    changes=body.model_dump(exclude_unset=True)
    if not changes:raise HTTPException(422,'Нет изменений')
    with connect() as db:
        province=db.execute('SELECT * FROM provinces WHERE id=%s FOR UPDATE',(province_id,)).fetchone()
        if not province:raise HTTPException(404,'Провинция не найдена')
        apply_province_changes(db,province,changes)
        result=province_payload(db,province_id)
    return result


def prepare_bulk_rules(body):
    rules=[]
    for index,item in enumerate(body.rules,1):
        condition=normalize_bulk_value(item.condition_field,item.condition_value)
        target=normalize_bulk_value(item.target_field,item.target_value,target=True)
        if item.target_field=='name':raise HTTPException(422,'Массовое переименование отключено')
        if item.target_field in EDITABLE_LAYERS and target and item.target_field!='state':
            # Resolve categories during preview as well, so no partial batch can fail.
            pass
        rules.append({'condition_field':item.condition_field,'condition_value':condition,'target_field':item.target_field,'target_value':target,'index':index})
    return rules


def bulk_match(db,rules):
    bounds=json.loads((ROOT/'map-data/view-region.json').read_text(encoding='utf-8'))['bounds']
    matches=[];merged={};conflicts={}
    for rule in rules:
        condition=rule['condition_field'];condition_value=rule['condition_value']
        if condition in EDITABLE_LAYERS and condition_value is not None:
            row=db.execute('SELECT name FROM map_categories WHERE layer=%s AND lower(name)=lower(%s)',(EDITABLE_LAYERS[condition],condition_value)).fetchone()
            if not row:raise HTTPException(422,f'Неизвестное условие: {condition_value}')
            rule['condition_value']=row['name']
        target=rule['target_field'];value=rule['target_value']
        if target in EDITABLE_LAYERS and value is not None and target!='state':
            row=db.execute('SELECT name FROM map_categories WHERE layer=%s AND lower(name)=lower(%s)',(EDITABLE_LAYERS[target],value)).fetchone()
            if not row:raise HTTPException(422,f'Неизвестное значение: {value}')
            rule['target_value']=row['name']
        ids=bulk_rule_ids(db,rule['condition_field'],rule['condition_value'],bounds);matches.append(ids)
        for pid in ids:
            target=rule['target_field'];value=rule['target_value']
            prior=merged.setdefault(pid,{})
            if target in prior and prior[target]!=value:conflicts.setdefault(pid,set()).add(target)
            else:prior[target]=value
    return matches,merged,conflicts


@app.post('/api/admin/provinces/bulk-preview')
def preview_bulk_edit(body: BulkEdit, request: Request):
    require_user(request,admin=True);rules=prepare_bulk_rules(body)
    with connect() as db:
        counts,merged,conflicts=bulk_match(db,rules)
        examples=sorted(conflicts)[:10]
        return {'rule_counts':[len(ids) for ids in counts],'total':len(merged),'conflict_count':len(conflicts),'conflict_examples':examples}


@app.post('/api/admin/provinces/bulk-edit')
def bulk_edit(body: BulkEdit, request: Request):
    require_user(request,admin=True);rules=prepare_bulk_rules(body)
    with connect() as db:
        counts,merged,conflicts=bulk_match(db,rules)
        if conflicts:raise HTTPException(409,detail={'message':'Правила пересекаются и задают разные значения одному параметру','province_ids':sorted(conflicts)[:10]})
        ids=sorted(merged)
        if not ids:return {'updated_count':0,'rule_counts':[len(items) for items in counts]}
        provinces=db.execute('SELECT * FROM provinces WHERE id=ANY(%s) ORDER BY id FOR UPDATE',(ids,)).fetchall()
        for province in provinces:
            changes={key:value for key,value in merged[province['id']].items()}
            apply_province_changes(db,province,changes)
        return {'updated_count':len(provinces),'rule_counts':[len(items) for items in counts]}


@app.patch('/api/provinces/{province_id}/name')
def player_rename(province_id:int,body:ProvinceEdit,request:Request):
    user=require_user(request)
    name=(body.name or '').strip()
    if not name:raise HTTPException(422,'Название не может быть пустым')
    with connect() as db:
        allowed=db.execute('''SELECT 1 FROM province_values v JOIN account_states a ON a.state_id=v.category_id
            AND a.layer=v.layer WHERE v.province_id=%s AND v.layer='states' AND a.account_id=%s''',
            (province_id,user['id'])).fetchone()
        if not allowed:raise HTTPException(403,'Вы не владеете государством этой провинции')
        row=db.execute("UPDATE provinces SET name=%s WHERE id=%s AND kind='land' RETURNING id,name",(name,province_id)).fetchone()
        if not row:raise HTTPException(404,'Сухопутная провинция не найдена')
    return row


# Whitelist only public assets. Never serve .local, .env, source, or DB dumps.
@app.get('/{path:path}')
def public_file(path: str):
    path = path or 'index.html'
    roots = ('assets/','map-data/tiles/')
    target = (ROOT/path).resolve()
    if not target.is_relative_to(ROOT):
        raise HTTPException(404)
    canonical=target.relative_to(ROOT).as_posix()
    allowed = canonical in ('index.html','viewer.css','viewer.js','ui.js','chat.js','map-tools.js') or canonical.startswith(roots)
    if not allowed or not target.is_file():
        raise HTTPException(404)
    return FileResponse(target)
