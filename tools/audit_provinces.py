"""Audit small provinces against the delivered ID mask; never change geometry."""
import json
from pathlib import Path

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None


def main(directory='map-data'):
    directory = Path(directory)
    meta = {p['id']: p for p in json.loads(
        (directory / 'provinces.json').read_text(encoding='utf-8')).values()}
    image = Image.open(directory / 'province-ids.png').convert('RGB')
    candidates = []
    for p in sorted(meta.values(), key=lambda p: (p['area'], p['id'])):
        if p['area'] > 500:
            continue
        x0, y0, x1, y1 = p['bbox']
        left, top = max(0, x0-1), max(0, y0-1)
        rgb = np.asarray(image.crop((left, top, min(image.width, x1+2),
                                     min(image.height, y1+2))), dtype=np.uint32)
        ids = (rgb[:, :, 0] << 16) | (rgb[:, :, 1] << 8) | rgb[:, :, 2]
        contacts = {}
        for a, b in ((ids[:, :-1], ids[:, 1:]), (ids[:-1], ids[1:])):
            values = np.concatenate((b[(a == p['id']) & (b != p['id'])],
                                     a[(b == p['id']) & (a != p['id'])]))
            neighbors, counts = np.unique(values, return_counts=True)
            for neighbor, count in zip(neighbors.tolist(), counts.tolist()):
                contacts[neighbor] = contacts.get(neighbor, 0) + count
        candidates.append({**p, 'neighbors': [
            {'id': neighbor, 'kind': meta[neighbor]['kind'] if neighbor else 'exterior',
             'shared_pixel_edges': count}
            for neighbor, count in sorted(contacts.items(), key=lambda pair: (-pair[1], pair[0]))]})
    report = {'threshold_is_review_only': True, 'review_max_area': 500,
              'counts': {kind: {str(limit): sum(p['kind'] == kind and p['area'] <= limit
                                              for p in meta.values())
                                for limit in (16, 64, 100, 500, 1000, 2000)}
                         for kind in ('land', 'sea', 'lake')},
              'candidates': candidates}
    output = directory / 'province-audit.json'
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report['counts']))
    print(f'Review candidates: {len(candidates)}; report: {output}')


if __name__ == '__main__':
    main()
