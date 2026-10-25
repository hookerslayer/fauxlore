"""Build the public static client without database dumps, sources or credentials."""
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ('index.html', 'viewer.js', 'viewer.css', 'ui.js', 'military-ui.js', 'economy.js', 'estate-demography.js', 'state-principles.js', 'map-tools.js', 'road-worker.js', 'road-routing.js',
          'supabase-api.js', 'supabase-return.html', 'supabase-return.js', 'app-config.js')


def main():
    target = ROOT / '.local/supabase-site'
    target.mkdir(parents=True, exist_ok=True)
    for name in PUBLIC:
        shutil.copy2(ROOT / name, target / name)
    for name in ('assets', 'map-data/tiles', 'map-data/road-tiles'):
        shutil.copytree(ROOT / name, target / name, dirs_exist_ok=True)
    shutil.copy2(ROOT / 'map-data/province-adjacency.json', target / 'map-data/province-adjacency.json')
    print(target)


if __name__ == '__main__':
    main()
