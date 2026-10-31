"""Build the public static client without database dumps, sources or credentials."""
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ('index.html', 'viewer.js', 'viewer.css', 'ui.js', 'wall.js', 'rules.js', 'docs/fauxlore.md', 'military-ui.js', 'garrison-ui.js', 'state-principles.js', 'map-tools.js',
          'supabase-api.js', 'projection-sync.js', 'view-state.js', 'supabase-return.html', 'supabase-return.js', 'app-config.js')


def main():
    target = ROOT / '.local/supabase-site'
    target.mkdir(parents=True, exist_ok=True)
    obsolete_roads = (target / 'map-data/road-tiles').resolve()
    if target.resolve() not in obsolete_roads.parents:
        raise RuntimeError('Road cache target is outside the local build')
    if obsolete_roads.exists():
        shutil.rmtree(obsolete_roads)
    for obsolete in ('economy.js', 'estate-demography.js', 'road-worker.js', 'road-routing.js'):
        (target / obsolete).unlink(missing_ok=True)
    for obsolete in ('military-terrain.png', 'military-terrain-bounds.json'):
        (target / 'map-data' / obsolete).unlink(missing_ok=True)
    (target / 'docs' / 'rules.md').unlink(missing_ok=True)
    old_calculator = (target / 'sixiemeterre_northeast').resolve()
    if target.resolve() not in old_calculator.parents:
        raise RuntimeError('Old calculator target is outside the local build')
    if old_calculator.exists():
        shutil.rmtree(old_calculator)
    for name in PUBLIC:
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / name, destination)
    for name in ('assets', 'map-data/tiles'):
        shutil.copytree(ROOT / name, target / name, dirs_exist_ok=True)
    for name in ('province-adjacency.json',):
        shutil.copy2(ROOT / 'map-data' / name, target / 'map-data' / name)
    print(target)


if __name__ == '__main__':
    main()
