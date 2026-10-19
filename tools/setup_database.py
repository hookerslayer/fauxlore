"""Workspace-local PostgreSQL, no system service."""
import json
from pathlib import Path
import secrets
import subprocess
import psycopg
from psycopg import sql

ROOT=Path(__file__).resolve().parent.parent
LOCAL=ROOT/'.local'
BIN=LOCAL/'pgsql/bin'
DATA=LOCAL/'pgdata'

def run(name,*args):
    subprocess.run([str(BIN/(name+'.exe')),*map(str,args)],check=True,cwd=ROOT)

def main():
    LOCAL.mkdir(exist_ok=True)
    admin_file=LOCAL/'postgres-admin.json'
    config_file=LOCAL/'database.json'
    if admin_file.exists():
        admin=json.loads(admin_file.read_text())
    else:
        admin={'password':secrets.token_urlsafe(32),'port':55432}
        admin_file.write_text(json.dumps(admin))
    if not (DATA/'PG_VERSION').exists():
        password_file=LOCAL/'init-password.tmp'
        password_file.write_text(admin['password'])
        try:
            run('initdb','-D',DATA,'-U','postgres','--pwfile',password_file,
                '--auth=scram-sha-256','--encoding=UTF8','--locale=C')
        finally:
            password_file.unlink(missing_ok=True)
    status=subprocess.run([str(BIN/'pg_ctl.exe'),'-D',str(DATA),'status'],capture_output=True)
    if status.returncode:
        run('pg_ctl','-D',DATA,'-l',LOCAL/'postgres.log','-o',f"-p {admin['port']} -h 127.0.0.1",'-w','start')
    if not config_file.exists():
        password=secrets.token_urlsafe(32)
        with psycopg.connect(host='127.0.0.1',port=admin['port'],dbname='postgres',user='postgres',password=admin['password'],autocommit=True) as db:
            db.execute(sql.SQL('CREATE ROLE fauxlore LOGIN PASSWORD {}').format(sql.Literal(password)))
            db.execute('CREATE DATABASE fauxlore OWNER fauxlore')
        config_file.write_text(json.dumps({'url':f"postgresql://fauxlore:{password}@127.0.0.1:{admin['port']}/fauxlore"}))
    print('PostgreSQL ready on localhost:55432; application role is not a superuser.')

if __name__=='__main__':
    main()
