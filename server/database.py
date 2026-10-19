"""PostgreSQL is the authoritative store; import never overwrites game names."""
import json
import os
from pathlib import Path
import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

ROOT = Path(__file__).resolve().parent.parent

CATEGORY_PALETTES = {
    'races': [('Люди','#a9c9e8'),('Дварфы','#c7a27d'),('Эльфы','#ebdc91'),('Зверолюди','#efb38b'),('Гоблины','#82aaa2'),('Гномы','#a5c99b')],
    'religions': [('Правоверие','#e5aaa7'),('Стратерианство','#8daf91'),('Атомизм','#a7c8e8'),('Астроизм','#c2ade0'),('Витализм','#ecdf9b'),('Утонувший','#75636d')],
    'climate': [('Холодный','#b8d4e8'),('Умеренный','#b8bf87'),('Тропический','#d5e8bd'),('Пустынный','#ead79b')],
    'resources': [('Морепродукты','#a4cde5'),('Древесина','#a4aa72'),('Камень','#b9bec0'),('Железо','#a99c8d'),('Золото','#e8ce77'),('Самоцветы','#dfa9c7'),('Пушнина','#98785e'),('Жемчуг','#e4e3dc'),('Бивни','#e6e8e5'),('Зерно','#eadb9a'),('Скот','#b99a78'),('Лён','#d1bfe0'),('Соль','#f0dce0'),('Фрукты','#b6a0d1'),('Чаролист','#d47fbd')],
    'trade': [('Вестмара','#c8b8df'),('Интермара','#b8d7b0'),('Сатмара','#eadb9a'),('Нортмара','#a9c9e8'),('Истмара','#c9ae91')]
}


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
        with db.cursor() as cursor:
            for layer, entries in CATEGORY_PALETTES.items():
                if layer == 'trade':
                    continue
                cursor.executemany('''INSERT INTO map_categories(layer,id,name,color) VALUES(%s,%s,%s,%s)
                    ON CONFLICT(layer,id) DO NOTHING''', [(layer,index,name,color) for index,(name,color) in enumerate(entries,1)])
        old_trade=db.execute("SELECT id FROM map_categories WHERE layer='trade' AND lower(name)=lower('Нортмара')").fetchone()
        new_trade=db.execute("SELECT id FROM map_categories WHERE layer='trade' AND lower(name)=lower('Вестмара')").fetchone()
        if old_trade:
            if new_trade:
                db.execute("UPDATE province_values SET category_id=%s WHERE layer='trade' AND category_id=%s",(new_trade['id'],old_trade['id']))
                db.execute("DELETE FROM map_categories WHERE layer='trade' AND id=%s",(old_trade['id'],))
            else:
                db.execute("UPDATE map_categories SET name='Вестмара',color='#c8b8df' WHERE layer='trade' AND id=%s",(old_trade['id'],))
        for name,color in CATEGORY_PALETTES['trade']:
            existing=db.execute("SELECT id FROM map_categories WHERE layer='trade' AND lower(name)=lower(%s)",(name,)).fetchone()
            if existing:
                db.execute("UPDATE map_categories SET color=%s WHERE layer='trade' AND id=%s",(color,existing['id']))
            else:
                category_id=db.execute("SELECT COALESCE(max(id),0)+1 AS id FROM map_categories WHERE layer='trade'").fetchone()['id']
                db.execute("INSERT INTO map_categories(layer,id,name,color) VALUES('trade',%s,%s,%s)",(category_id,name,color))
        tropical_color=next(color for name,color in CATEGORY_PALETTES['climate'] if name=='Тропический')
        db.execute("UPDATE map_categories SET color=%s WHERE layer='climate' AND name='Тропический'",(tropical_color,))
        # Explicit import only on the first launch; restart does not undo edits.
        if db.execute('SELECT count(*) AS n FROM provinces').fetchone()['n'] == 0:
            import_geometry(db)


def import_geometry(db):
    meta = json.loads((ROOT / 'map-data/provinces.json').read_text(encoding='utf-8'))
    with db.cursor() as cursor:
        cursor.executemany('''INSERT INTO provinces(id,kind,name,center,bbox,area,seed_area,courts,population)
            VALUES(%s,%s,%s,%s,%s,%s,%s,0,0) ON CONFLICT(id) DO UPDATE SET
            kind=excluded.kind, center=excluded.center, bbox=excluded.bbox,
            area=excluded.area, seed_area=excluded.seed_area''', [
            (p['id'], p['kind'], f"Провинция {p['id']}", Jsonb(p['center']), Jsonb(p['bbox']),
             p['area'], p['seed_area']) for p in meta.values()])
