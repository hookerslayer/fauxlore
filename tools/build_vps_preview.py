"""Build a new isolated guest-only VPS preview without touching live config."""

import shutil
import tempfile
import argparse
from pathlib import Path

from build_supabase_site import PUBLIC, public_source

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--postgrest', action='store_true', help='Build guest-only PostgREST integration preview')
    args = parser.parse_args()
    local = ROOT / '.local'
    local.mkdir(exist_ok=True)
    target = Path(tempfile.mkdtemp(prefix='vps-preview-', dir=local))
    for name in PUBLIC:
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(public_source(name), destination)
    for name in ('assets', 'map-data/tiles'):
        shutil.copytree(ROOT / name, target / name)
    shutil.copy2(ROOT / 'map-data/province-adjacency.json', target / 'map-data/province-adjacency.json')
    (target / 'app-config.js').write_text(
        "window.FAUXLORE_CONFIG = {backend: '" + ('vps-postgrest' if args.postgrest else 'vps-preview') +
        "', supabaseUrl: '" + ('vps-postgrest-preview' if args.postgrest else 'vps-preview') + "'};\n", encoding='utf-8'
    )
    print(target)


if __name__ == '__main__':
    main()
