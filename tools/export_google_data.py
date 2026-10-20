"""Export all PostgreSQL rows to a private, typed Sheets migration dataset."""
import base64
import hashlib
import json
import sys
from datetime import date, datetime, timezone
from decimal import Decimal
from pathlib import Path
from psycopg import sql

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from server.database import connect


def main():
    output = ROOT / '.local/google-migration'
    output.mkdir(parents=True, exist_ok=True)
    sheets, blobs, counts = {}, [], {}
    with connect() as db:
        db.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY')
        tables = db.execute("SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename").fetchall()
        for table in tables:
            name = table['tablename']
            cursor = db.execute(sql.SQL('SELECT * FROM {}').format(sql.Identifier(name)))
            headers = [c.name for c in cursor.description]
            rows = cursor.fetchall()
            counts[name] = len(rows)
            matrix = []
            for row_index, row in enumerate(rows):
                values = []
                for column in headers:
                    value = row[column]
                    if isinstance(value, (bytes, memoryview)):
                        raw = bytes(value)
                        key = f'{name}:{row.get("id",row_index)}:{column}'
                        encoded = base64.b64encode(raw).decode()
                        for index in range(0, len(encoded), 30000):
                            blobs.append([key, index//30000, encoded[index:index+30000], hashlib.sha256(raw).hexdigest()])
                        value = '@blob:' + key
                    elif isinstance(value, (dict, list)):
                        value = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
                    elif isinstance(value, (date, datetime)):
                        value = value.isoformat()
                    elif isinstance(value, Decimal):
                        value = float(value)
                    values.append(value)
                matrix.append(values)
            if name == 'accounts':
                headers += ['google_sub']
                for row in matrix: row.append(None)
            destination = '_legacy_' + name if name in ('sessions', 'password_resets') else name
            sheets[destination] = {'headers': headers, 'rows': matrix}
    sheets['sessions'] = {'headers': ['token_hash','account_id','expires_at'], 'rows': []}
    sheets['_blobs'] = {'headers': ['key','chunk_index','base64','sha256'], 'rows': blobs}
    region = json.loads((ROOT/'map-data/view-region.json').read_text(encoding='utf-8'))['bounds']
    signature = '|'.join(f'{p.name}:{p.stat().st_mtime_ns}:{p.stat().st_size}' for p in sorted((ROOT/'map-data/tiles').glob('*.png')))
    settings = {'region': region, 'calendar': {'year':1452,'turn':1}, 'tile_revision': hashlib.sha256(signature.encode()).hexdigest()[:16], 'data_revision': 1}
    sheets['_settings'] = {'headers': ['key','value_json'], 'rows': [[k,json.dumps(v)] for k,v in settings.items()]}
    sheets['_operations'] = {'headers': ['id','account_id','request_hash','result_json','created_at'], 'rows': []}
    manifest = {'created_at': datetime.now(timezone.utc).isoformat(), 'source_counts': counts,
                'binary_chunks': len(blobs), 'private': True, 'sheets': sheets}
    path = output/'export.json'
    path.write_text(json.dumps(manifest, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
    print(json.dumps({'path':str(path),'counts':counts,'binary_chunks':len(blobs),'bytes':path.stat().st_size}))


if __name__ == '__main__': main()
