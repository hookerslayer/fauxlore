"""Create a restorable private PostgreSQL + source snapshot before migration."""
import hashlib
import json
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from server.database import connect, database_url


def main():
    stamp = datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S')
    destination = ROOT.parent / f'PostgreSQL-version-{stamp}'
    destination.mkdir(exist_ok=False)
    dump = destination / f'fauxlore-postgresql-{stamp}.dump'
    binary = ROOT / '.local/pgsql/bin'
    subprocess.run([str(binary / 'pg_dump.exe'), '--dbname', database_url(),
                    '--format=custom', '--file', str(dump)], check=True, capture_output=True)
    listing = subprocess.run([str(binary / 'pg_restore.exe'), '--list', str(dump)],
                             check=True, capture_output=True, text=True).stdout
    (destination / 'dump-contents.txt').write_text(listing, encoding='utf-8')
    with connect() as db:
        tables = [r['tablename'] for r in db.execute(
            "SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename")]
        from psycopg import sql
        counts = {name: db.execute(sql.SQL('SELECT count(*) AS n FROM {}').format(
            sql.Identifier(name))).fetchone()['n'] for name in tables}
    project = destination / 'project'
    shutil.copytree(ROOT, project, ignore=shutil.ignore_patterns(
        '.git', '.local', '.venv', 'node_modules', '__pycache__', '.pytest_cache'))
    manifest = {'created_at': datetime.now(timezone.utc).isoformat(), 'tables': counts,
                'dump': dump.name, 'sha256': hashlib.sha256(dump.read_bytes()).hexdigest(),
                'restore': 'Start project/tools/start-local.ps1 once; stop API; use pg_restore --clean --if-exists --no-owner --no-privileges --dbname=<local URL> <dump>; start API again.',
                'runtime': 'Python environment and PostgreSQL binaries are recreated by start-local.ps1. Private .local configuration is machine-specific, not required to restore.',
                'private': True}
    (destination / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    archive = destination / f'fauxlore-postgresql-project-{stamp}.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=3) as z:
        for file in project.rglob('*'):
            if file.is_file(): z.write(file, file.relative_to(destination))
        for file in (dump, destination / 'manifest.json', destination / 'dump-contents.txt'):
            z.write(file, file.name)
    print(json.dumps({'directory': str(destination), 'dump': str(dump), 'archive': str(archive),
                      'archive_bytes': archive.stat().st_size, 'sha256': manifest['sha256'], 'tables': counts}))


if __name__ == '__main__':
    main()
