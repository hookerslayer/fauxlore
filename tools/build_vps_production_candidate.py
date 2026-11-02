"""Create a separate, non-live VPS production-candidate static bundle."""
import shutil
from pathlib import Path

from build_supabase_site import PUBLIC

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / '.local' / 'fauxlore-production-candidate'


def main():
    TARGET.parent.mkdir(exist_ok=True)
    if TARGET.exists():
        raise SystemExit(f'Refusing to overwrite existing candidate: {TARGET}')

    for name in PUBLIC:
        destination = TARGET / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, destination)
    for name in ('assets', 'map-data/tiles'):
        shutil.copytree(ROOT / name, TARGET / name)
    shutil.copy2(ROOT / 'map-data/province-adjacency.json', TARGET / 'map-data/province-adjacency.json')
    (TARGET / 'app-config.js').write_text(
        "window.FAUXLORE_CONFIG = {backend: 'vps-postgrest', "
        "supabaseUrl: 'https://sixiemeterre.ru'};\n",
        encoding='utf-8',
    )
    (TARGET / 'CANDIDATE-NOT-LIVE.txt').write_text(
        'Candidate build only. Nginx is not switched to this directory.\n', encoding='utf-8'
    )
    print(TARGET)


if __name__ == '__main__':
    main()
