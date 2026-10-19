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
from .database import ROOT, connect, initialize

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
        if int(request.headers.get('content-length','0')) > 65536:
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
        return db.execute('''SELECT a.id,a.email,a.nickname,a.role FROM accounts a
            JOIN sessions s ON a.id=s.account_id
            WHERE s.token_hash=%s AND s.expires_at>now()''', (digest(token),)).fetchone()


def require_user(request, admin=False):
    user = current_user(request)
    if not user:
        raise HTTPException(401, 'Войдите в аккаунт')
    if admin and user['role'] != 'admin':
        raise HTTPException(403, 'Нужна роль admin')
    return user


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
    for value in values:
        by_id[value['province_id']].setdefault('layers',{})[value['layer']] = {
            k:value[k] for k in ('id','name','color')}
    return {'provinces': provinces, 'categories': categories,
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
    return {'user':user}


@app.post('/api/auth/login')
def login(body: Credentials, request: Request, response: Response):
    limit(request,'login')
    with connect() as db:
        user = db.execute('SELECT * FROM accounts WHERE email=%s',(email_value(body.email),)).fetchone()
        try:
            hasher.verify(user['password_hash'] if user else DUMMY_HASH,body.password)
        except (VerifyMismatchError,InvalidHashError):
            raise HTTPException(401,'Неверный email или пароль')
        if not user:
            raise HTTPException(401,'Неверный email или пароль')
        issue_session(db,response,user['id'])
    return {'user':{k:user[k] for k in ('id','email','nickname','role')}}


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


class ProvinceEdit(BaseModel):
    name: str = Field(min_length=1,max_length=120)


@app.patch('/api/admin/provinces/{province_id}')
def rename(province_id: int, body: ProvinceEdit, request: Request):
    require_user(request,admin=True)
    name=body.name.strip()
    if not name:
        raise HTTPException(422,'Название не может быть пустым')
    with connect() as db:
        row=db.execute('UPDATE provinces SET name=%s WHERE id=%s RETURNING id,name',(name,province_id)).fetchone()
    if not row:
        raise HTTPException(404,'Провинция не найдена')
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
    allowed = canonical in ('index.html','viewer.css','viewer.js','ui.js','map-tools.js') or canonical.startswith(roots)
    if not allowed or not target.is_file():
        raise HTTPException(404)
    return FileResponse(target)
