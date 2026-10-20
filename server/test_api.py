"""Integration tests against real PostgreSQL in a disposable, isolated schema."""
import os
import re
import secrets
import unittest
import json
from urllib.parse import unquote
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.conninfo import make_conninfo
from fastapi.testclient import TestClient
from .database import database_url, ROOT, connect, import_geometry
from .app import app, attempts


class APIIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base_url=database_url()
        cls.old_env=os.environ.get('DATABASE_URL')
        cls.schema='test_'+secrets.token_hex(8)
        with psycopg.connect(cls.base_url,autocommit=True) as db:
            db.execute(sql.SQL('CREATE SCHEMA {}').format(sql.Identifier(cls.schema)))
        os.environ['DATABASE_URL']=make_conninfo(cls.base_url,options=f'-c search_path={cls.schema}')
        cls.old_origin=os.environ.pop('APP_ORIGIN',None)
        cls.client=TestClient(app)
        cls.client.__enter__()

    @classmethod
    def tearDownClass(cls):
        cls.client.__exit__(None,None,None)
        if cls.old_env is None:
            os.environ.pop('DATABASE_URL',None)
        else:
            os.environ['DATABASE_URL']=cls.old_env
        if cls.old_origin is not None:
            os.environ['APP_ORIGIN']=cls.old_origin
        with psycopg.connect(cls.base_url,autocommit=True) as db:
            db.execute(sql.SQL('DROP SCHEMA {} CASCADE').format(sql.Identifier(cls.schema)))

    def setUp(self):
        attempts.clear()
        self.client.cookies.clear()

    def test_full_account_and_map_lifecycle(self):
        c=self.client
        self.assertEqual(c.get('/api/health').json()['database'],'postgresql')
        payload=c.get('/api/map').json()
        self.assertEqual(len(payload['provinces']),len(json.loads((ROOT/'map-data/provinces.json').read_text(encoding='utf-8'))))
        self.assertNotIn(1071,{p['id'] for p in payload['provinces']})
        self.assertEqual(c.get('/.local/database.json').status_code,404)
        self.assertEqual(c.get('/assets/%2e%2e/.local/database.json').status_code,404)
        self.assertEqual(c.get('/map-data/tiles/%2e%2e/%2e%2e/.local/database.json').status_code,404)
        self.assertEqual(c.get('/server/app.py').status_code,404)
        self.assertEqual(c.get('/api/preferences').status_code,401)
        with connect() as db:
            db.execute("INSERT INTO map_categories VALUES('states',1,'Тестовое государство','#112233')")
            db.execute("INSERT INTO province_values VALUES(1550,'states',1)")
            db.execute('UPDATE provinces SET population=100,development=0 WHERE id=1550')
        province=next(p for p in c.get('/api/map').json()['provinces'] if p['id']==1550)
        self.assertEqual(province['layers']['states']['color'],'#112233')
        self.assertEqual(province['population'],100)
        self.assertEqual(province['development'],0)
        creds={'email':'integration@example.invalid','password':'integration-safe-password','nickname':'Тестовый игрок'}
        self.assertEqual(c.post('/api/auth/register',json=creds,headers={'Origin':'https://evil.invalid'}).status_code,403)
        response=c.post('/api/auth/register',json={**creds,'role':'admin'})
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(response.json()['user']['role'],'player')
        self.assertIn('HttpOnly',response.headers['set-cookie'])
        self.assertEqual(c.patch('/api/admin/provinces/1550',json={'name':'Не разрешено'}).status_code,403)
        self.assertEqual(c.post('/api/admin/markers',json={'province_id':1550,'x':10,'y':20,'type':'capital','name':'Столица'}).status_code,403)
        self.assertEqual(c.put('/api/preferences',json={'layer':'races','role':'admin'}).status_code,200)
        self.assertEqual(c.get('/api/preferences').json(),{'layer':'races'})
        c.post('/api/auth/logout',json={})
        self.assertIsNone(c.get('/api/auth/me').json()['user'])
        self.assertEqual(c.post('/api/auth/login',json={**creds,'password':'wrong'}).status_code,401)
        self.assertEqual(c.post('/api/auth/login',json=creds).status_code,200)
        with connect() as db:
            db.execute("UPDATE accounts SET role='admin' WHERE email=%s",(creds['email'],))
        self.assertEqual(c.patch('/api/admin/provinces/1550',json={'name':'Тестовая провинция'}).status_code,200)
        terrain=c.patch('/api/admin/provinces/1550',json={'terrain_type':'forest'})
        self.assertEqual(terrain.status_code,200,terrain.text)
        self.assertEqual(terrain.json()['terrain_type'],'forest')
        province=next(p for p in c.get('/api/map').json()['provinces'] if p['id']==1550)
        self.assertEqual(province['terrain_type'],'forest')
        self.assertEqual(c.patch('/api/admin/provinces/1550',json={'terrain_type':'marsh'}).json()['terrain_type'],'marsh')
        self.assertEqual(c.patch('/api/admin/provinces/1550',json={'terrain_type':None}).json()['terrain_type'],None)
        self.assertEqual(c.patch('/api/admin/provinces/1550',json={'terrain_type':'desert'}).status_code,422)
        with connect() as db:
            marker_point=db.execute('SELECT center FROM provinces WHERE id=1550').fetchone()['center']
        marker=c.post('/api/admin/markers',json={'province_id':1550,'x':marker_point[0],'y':marker_point[1],'type':'capital','name':'Тестовая столица'})
        self.assertEqual(marker.status_code,200,marker.text)
        self.assertEqual(marker.json()['state_id'],1)
        self.assertEqual(marker.json()['state_name'],'Тестовое государство')
        self.assertEqual((marker.json()['x'],marker.json()['y']),tuple(marker_point))
        map_marker=next(m for m in c.get('/api/map').json()['markers'] if m['id']==marker.json()['id'])
        self.assertEqual((map_marker['x'],map_marker['y']),tuple(marker_point))
        self.assertEqual(c.post('/api/admin/markers',json={'province_id':1550,'x':10,'y':20,'type':'ruins','name':'Старые руины'}).status_code,422)
        removed_type=c.post('/api/admin/markers',json={'province_id':1550,'type':'interest','name':'Рунический камень','description':'Древняя надпись'})
        self.assertEqual(removed_type.status_code,422)
        with self.assertRaises(psycopg.errors.CheckViolation):
            with connect() as db:
                db.execute("INSERT INTO map_markers(province_id,x,y,type,name) VALUES(%s,%s,%s,'ruins','Удалённый тип')",(1550,*marker_point))
        markers=c.get('/api/map').json()['markers']
        self.assertEqual({m['id'] for m in markers},{marker.json()['id']})
        self.assertEqual(c.delete(f"/api/admin/markers/{marker.json()['id']}",headers={'Content-Type':'application/json'}).status_code,200)
        with connect() as db:
            import_geometry(db)
            self.assertEqual(db.execute('SELECT name FROM provinces WHERE id=1550').fetchone()['name'],'Тестовая провинция')
        before=set((ROOT/'.local/mail').glob('*.eml'))
        response=c.post('/api/auth/reset-request',json={'email':creds['email']})
        self.assertEqual(response.status_code,200,response.text)
        new=set((ROOT/'.local/mail').glob('*.eml'))-before
        self.assertEqual(len(new),1)
        file=new.pop()
        from email import policy
        from email.parser import BytesParser
        message=BytesParser(policy=policy.default).parsebytes(file.read_bytes()).get_content()
        token=re.search(r'#reset=([A-Za-z0-9_-]+)',message).group(1)
        file.unlink()
        reset={'token':token,'password':'a-different-safe-password'}
        self.assertEqual(c.post('/api/auth/reset',json=reset).status_code,200)
        self.assertIsNone(c.get('/api/auth/me').json()['user'])
        self.assertEqual(c.post('/api/auth/reset',json=reset).status_code,400)
        self.assertEqual(c.post('/api/auth/login',json=creds).status_code,401)
        self.assertEqual(c.post('/api/auth/login',json={**creds,'password':reset['password']}).status_code,200)


if __name__=='__main__':
    unittest.main()
