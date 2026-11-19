"""Build a named, non-live VPS production release bundle."""
import argparse
import re
import shutil
from pathlib import Path

from build_supabase_site import PUBLIC, public_source

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('name', help='release name, for example modifiers-20261112')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,63}', args.name):
        raise SystemExit('Release name must contain only lowercase latin letters, digits and dashes')

    target = ROOT / '.local' / 'releases' / args.name
    if target.exists():
        raise SystemExit(f'Refusing to overwrite existing release: {target}')

    for name in PUBLIC:
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(public_source(name), destination)
    for name in ('assets', 'map-data/tiles'):
        shutil.copytree(ROOT / name, target / name)
    shutil.copy2(ROOT / 'map-data/province-adjacency.json', target / 'map-data/province-adjacency.json')
    (target / 'app-config.js').write_text(
        "window.FAUXLORE_CONFIG = {backend: 'vps-postgrest', supabaseUrl: 'https://sixiemeterre.ru'};\n",
        encoding='utf-8',
    )
    print(target)


if __name__ == '__main__':
    main()
