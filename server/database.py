"""PostgreSQL is the authoritative store; import never overwrites game names."""
import json
import os
from pathlib import Path
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

ROOT = Path(__file__).resolve().parent.parent


def database_url():
    if os.getenv('DATABASE_URL'):
        return os.environ['DATABASE_URL']
    config = ROOT / '.local' / 'database.json'
    if config.exists():
        return json.loads(config.read_text())['url']
    raise RuntimeError('Настройте DATABASE_URL или запустите tools/start-local.ps1')


def connect():
    return psycopg.connect(database_url(), row_factory=dict_row)


def initialize():
    with connect() as db:
        db.execute((ROOT / 'server/schema.sql').read_text(encoding='utf-8'))
        # Explicit import only on the first launch; restart does not undo edits.
        if db.execute('SELECT count(*) AS n FROM provinces').fetchone()['n'] == 0:
            import_geometry(db)


def import_geometry(db):
    meta = json.loads((ROOT / 'map-data/provinces.json').read_text(encoding='utf-8'))
    with db.cursor() as cursor:
        cursor.executemany('''INSERT INTO provinces(id,kind,name,center,bbox,area,seed_area)
            VALUES(%s,%s,%s,%s,%s,%s,%s) ON CONFLICT(id) DO UPDATE SET
            kind=excluded.kind, center=excluded.center, bbox=excluded.bbox,
            area=excluded.area, seed_area=excluded.seed_area''', [
            (p['id'], p['kind'], f"Провинция {p['id']}", Jsonb(p['center']), Jsonb(p['bbox']),
             p['area'], p['seed_area']) for p in meta.values()])
