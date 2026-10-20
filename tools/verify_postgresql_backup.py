"""Restore a backup into a newly created disposable DB; never touch the live DB."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import uuid

import psycopg
from psycopg import sql

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('backup', type=Path)
    args = parser.parse_args()
    folder = args.backup.resolve(strict=True)
    manifest = json.loads((folder / 'manifest.json').read_text(encoding='utf-8'))
    dump = (folder / manifest['dump']).resolve(strict=True)
    if dump.parent != folder:
        raise RuntimeError('Dump must be directly inside the named backup folder')
    if hashlib.sha256(dump.read_bytes()).hexdigest() != manifest['sha256']:
        raise RuntimeError('Backup SHA256 mismatch')
    admin = json.loads((ROOT / '.local/postgres-admin.json').read_text())
    name = 'fauxlore_restore_test_' + uuid.uuid4().hex
    connection = dict(host='127.0.0.1', port=admin['port'], user='postgres',
                      password=admin['password'])
    created = False
    with psycopg.connect(**connection, dbname='postgres', autocommit=True) as db:
        try:
            db.execute(sql.SQL('CREATE DATABASE {}').format(sql.Identifier(name)))
            created = True
            environment = {**os.environ, 'PGPASSWORD': admin['password']}
            result = subprocess.run([
                str(ROOT / '.local/pgsql/bin/pg_restore.exe'), '--exit-on-error',
                '--no-owner', '--no-privileges', '--host=127.0.0.1',
                '--port=' + str(admin['port']), '--username=postgres',
                '--dbname=' + name, str(dump),
            ], env=environment, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError('Test restore failed; private PostgreSQL log must be inspected')
            with psycopg.connect(**connection, dbname=name) as restored:
                counts = {table: restored.execute(sql.SQL('SELECT count(*) FROM {}').format(
                    sql.Identifier(table))).fetchone()[0] for table in manifest['tables']}
            if counts != manifest['tables']:
                raise RuntimeError('Restored table counts do not match the manifest')
            print(json.dumps({'restore_verified': True, 'tables': counts,
                              'live_database_unchanged': True}))
        finally:
            if created:
                # Only this random database, successfully created by this invocation.
                db.execute(sql.SQL('DROP DATABASE {}').format(sql.Identifier(name)))


if __name__ == '__main__':
    main()
