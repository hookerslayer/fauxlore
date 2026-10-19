"""Build the 4-neighbour province graph from the RGB province ID raster.

Requires Pillow and NumPy. Run with:
    python tools/build-province-adjacency.py
"""
import json
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
Image.MAX_IMAGE_PIXELS = None


def encoded_ids(rgb):
    ids = rgb[:, 0].astype(np.uint32) << 16
    ids |= rgb[:, 1].astype(np.uint32) << 8
    ids |= rgb[:, 2].astype(np.uint32)
    return ids


def add_edges(edges, first, second):
    mask = (first != second) & (first != 0) & (second != 0)
    if not np.any(mask):
        return
    low = np.minimum(first[mask], second[mask]).astype(np.uint64)
    high = np.maximum(first[mask], second[mask]).astype(np.uint64)
    packed = np.unique((low << 24) | high)
    edges.update(map(int, packed))


def main():
    metadata = json.loads((ROOT / 'map-data/provinces.json').read_text(encoding='utf-8'))
    provinces = {int(item['id']) for item in metadata.values()}
    bounds = (
        min(item['bbox'][0] for item in metadata.values()),
        min(item['bbox'][1] for item in metadata.values()),
        max(item['bbox'][2] for item in metadata.values()),
        max(item['bbox'][3] for item in metadata.values()),
    )
    rgb = np.asarray(Image.open(ROOT / 'map-data/province-ids.png').crop(bounds).convert('RGB'))
    edges = set()
    previous = None
    for row in rgb:
        current = encoded_ids(row)
        add_edges(edges, current[:-1], current[1:])
        if previous is not None:
            add_edges(edges, previous, current)
        previous = current

    adjacency = {str(province_id): set() for province_id in provinces}
    for pair in edges:
        first, second = pair >> 24, pair & 0xFFFFFF
        if first in provinces and second in provinces:
            adjacency[str(first)].add(second)
            adjacency[str(second)].add(first)
    result = {province_id: sorted(neighbors) for province_id, neighbors in adjacency.items()}
    output = ROOT / 'map-data/province-adjacency.json'
    output.write_text(json.dumps(result, separators=(',', ':')), encoding='utf-8')
    print(f'Wrote adjacency for {len(result)} provinces, {len(edges)} unique raster edges: {output}')


if __name__ == '__main__':
    main()
