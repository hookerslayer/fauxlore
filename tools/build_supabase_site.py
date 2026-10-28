"""Build the public static client without database dumps, sources or credentials."""
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ('index.html', 'viewer.js', 'viewer.css', 'ui.js', 'wall.js', 'rules.js', 'docs/rules.md', 'military-ui.js', 'garrison-ui.js', 'economy.js', 'estate-demography.js', 'state-principles.js', 'map-tools.js', 'road-worker.js', 'road-routing.js',
          'sixiemeterre_northeast/militaryEngine.js', 'sixiemeterre_northeast/modifierSystem.js',
          'supabase-api.js', 'supabase-return.html', 'supabase-return.js', 'app-config.js')


def main():
    target = ROOT / '.local/supabase-site'
    target.mkdir(parents=True, exist_ok=True)
    for name in PUBLIC:
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, destination)
    for name in ('assets', 'map-data/tiles', 'map-data/road-tiles'):
        shutil.copytree(ROOT / name, target / name, dirs_exist_ok=True)
    for name in ('province-adjacency.json', 'military-terrain.png', 'military-terrain-bounds.json'):
        shutil.copy2(ROOT / 'map-data' / name, target / 'map-data' / name)
    print(target)


if __name__ == '__main__':
    main()
