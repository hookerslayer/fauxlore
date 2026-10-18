"""Build a gap-free province ID raster from fauxlore.png. Requires Pillow, numpy.

Run: python tools/build_province_mask.py [source.png] [output-directory]
No resampling, erosion or opening: even a one-pixel land bridge is preserved.
"""
from pathlib import Path
import json
import sys
import time
import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None  # This local input deliberately contains 100M pixels.


def label_runs(kinds):
    """Four-connected components using horizontal runs and union/find.

    Different terrain types never merge. Working memory is one uint32 raster
    plus run metadata; no Python object is allocated for every pixel.
    """
    h, w = kinds.shape
    labels = np.zeros((h, w), dtype=np.uint32)
    parents = [0]
    types = [0]
    edges = [False]

    def root(a):
        while parents[a] != a:
            parents[a] = parents[parents[a]]
            a = parents[a]
        return a

    previous = []
    for y in range(h):
        row = kinds[y]
        cuts = np.flatnonzero(row[1:] != row[:-1]) + 1
        starts = np.r_[0, cuts]
        ends = np.r_[cuts, w]
        current = []
        j = 0
        for start, end in zip(starts.tolist(), ends.tolist()):
            kind = int(row[start])
            if not kind:
                continue
            while j < len(previous) and previous[j][1] <= start:
                j += 1
            k = j
            matches = []
            while k < len(previous) and previous[k][0] < end:
                if previous[k][3] == kind:
                    matches.append(root(previous[k][2]))
                k += 1
            if matches:
                lab = min(matches)
                for other in matches:
                    parents[other] = lab
            else:
                lab = len(parents)
                parents.append(lab)
                types.append(kind)
                edges.append(False)
            if y == 0 or y == h - 1 or start == 0 or end == w:
                edges[lab] = True
            labels[y, start:end] = lab
            current.append((start, end, lab, kind))
        previous = current
        if y % 1000 == 0:
            print(f'Component scan: {y}/{h}', flush=True)
    roots = np.array([root(i) for i in range(len(parents))], dtype=np.uint32)
    edge_roots = set(roots[np.array(edges, dtype=bool)].tolist())
    # Only the largest edge-connected transparent component is exterior.
    # Other components at the edge can be legitimate cropped sea provinces.
    provisional_areas = np.bincount(labels.ravel(), minlength=len(parents))
    root_areas = np.bincount(roots, weights=provisional_areas, minlength=len(parents))
    water_edge_roots = [r for r in edge_roots if types[r] == 2]
    background_root = max(water_edge_roots, key=lambda r: root_areas[r]) if water_edge_roots else None
    lookup = np.zeros(len(parents), dtype=np.uint32)
    province_types = [0]
    root_ids = {}
    exterior_roots = set()
    for i in range(1, len(parents)):
        r = int(roots[i])
        if r == background_root:
            exterior_roots.add(r)
            continue
        if r not in root_ids:
            root_ids[r] = len(province_types)
            province_types.append(types[r])
        lookup[i] = root_ids[r]
    for y in range(h):
        labels[y] = lookup[labels[y]]
    return labels, np.array(province_types, dtype=np.uint8), len(exterior_roots)


def fill_borders(labels, border):
    """Multi-source Manhattan Voronoi on contour pixels only.

    Each round moves one pixel through the original contour. At equal distance
    the smallest ID wins. Seed pixels (including narrow bridges) never change.
    Exterior transparent pixels are not eligible for expansion.
    """
    h, w = labels.shape
    ys, xs = np.nonzero(border)
    rounds = 0
    while len(ys):
        best = np.full(len(ys), np.iinfo(np.uint32).max, dtype=np.uint32)
        for dy, dx in ((-1, 0), (0, -1), (0, 1), (1, 0)):
            ny, nx = ys + dy, xs + dx
            valid = (ny >= 0) & (ny < h) & (nx >= 0) & (nx < w)
            indices = np.flatnonzero(valid)
            values = labels[ny[valid], nx[valid]]
            usable = values != 0
            indices, values = indices[usable], values[usable]
            best[indices] = np.minimum(best[indices], values)
        assigned = best != np.iinfo(np.uint32).max
        if not assigned.any():
            break
        labels[ys[assigned], xs[assigned]] = best[assigned]
        ys, xs = ys[~assigned], xs[~assigned]
        rounds += 1
    # Disconnected strokes have no path through the contour to any seed.
    # Assign them by Euclidean distance to the already allocated province grid.
    # Resolve independently against a frozen grid, so order cannot affect IDs.
    fallback = []
    for y, x in zip(ys.tolist(), xs.tolist()):
        radius = 8
        while True:
            top, bottom = max(0, y-radius), min(h, y+radius+1)
            left, right = max(0, x-radius), min(w, x+radius+1)
            py, px = np.nonzero(labels[top:bottom, left:right])
            if len(py):
                distances = (py + top-y)**2 + (px + left-x)**2
                closest = distances.min()
                if closest <= radius**2 or radius >= max(h, w):
                    candidates = labels[py[distances == closest]+top, px[distances == closest]+left]
                    fallback.append(int(candidates.min()))
                    break
            if radius >= max(h, w):
                raise ValueError('No province seeds in source')
            radius *= 2
    if len(ys):
        labels[ys, xs] = fallback
    return rounds, int(len(ys))


def remove_land_artifacts(labels, types, border, max_pixels=3):
    """Retire only tiny standalone land seeds; leave every other ID intact."""
    areas = np.bincount(labels.ravel(), minlength=len(types))
    retired = np.flatnonzero((types == 1) & (areas <= max_pixels))
    records = []
    for province_id in retired.tolist():
        ys, xs = np.nonzero(labels == province_id)
        records.append({'id': province_id, 'seed_area': int(areas[province_id]),
                        'pixels': [[int(x), int(y)] for y, x in zip(ys, xs)]})
        labels[ys, xs] = 0
        border[ys, xs] = True
        types[province_id] = 0
    return records


def remove_edge_sea_artifacts(labels, types, border, max_pixels=64):
    """Retire tiny sea components touching the image edge as exterior noise.

    Large sea provinces cropped by the image boundary are valid and remain
    untouched. Tiny isolated transparent fragments at the edge are outside
    the playable map and should stay background ID 0 instead of becoming
    searchable provinces.
    """
    h, w = labels.shape
    areas = np.bincount(labels.ravel(), minlength=len(types))
    edge_ids = np.unique(np.concatenate((
        labels[0, :], labels[-1, :], labels[:, 0], labels[:, -1]
    )))
    retired = [int(province_id) for province_id in edge_ids
               if province_id > 0 and types[province_id] == 2
               and areas[province_id] <= max_pixels]
    records = []
    for province_id in retired:
        ys, xs = np.nonzero(labels == province_id)
        records.append({'id': province_id, 'seed_area': int(areas[province_id]),
                        'pixels': [[int(x), int(y)] for y, x in zip(ys, xs)]})
        labels[ys, xs] = 0
        # Keep these pixels as exterior background. They are removed after
        # contour filling, so marking them as border preserves the seed check
        # without sending them through another assignment pass.
        border[ys, xs] = True
        types[province_id] = 0
    return records


def water_topology(labels, types):
    """Classify connected water networks: exterior/edge access means sea."""
    neighbors = [dict() for _ in types]
    for y in range(labels.shape[0]):
        pairs = [(labels[y, :-1], labels[y, 1:])]
        if y:
            pairs.append((labels[y-1], labels[y]))
        for a, b in pairs:
            different = a != b
            lo, hi = np.minimum(a[different], b[different]), np.maximum(a[different], b[different])
            keys, counts = np.unique(lo.astype(np.uint64)*len(types)+hi, return_counts=True)
            for key, count in zip(keys.tolist(), counts.tolist()):
                i, j = divmod(key, len(types))
                neighbors[i][j] = neighbors[i].get(j, 0)+count
                neighbors[j][i] = neighbors[j].get(i, 0)+count
    edge = set(np.concatenate((labels[0], labels[-1], labels[:, 0], labels[:, -1])).tolist())
    sea = {i for i in range(1, len(types)) if types[i] == 2 and (i in edge or 0 in neighbors[i])}
    pending = list(sea)
    while pending:
        for j in neighbors[pending.pop()]:
            if types[j] == 2 and j not in sea:
                sea.add(j)
                pending.append(j)
    for i in range(1, len(types)):
        if types[i] == 2 and i not in sea:
            types[i] = 3
    return neighbors


def merge_small_seas(labels, types, neighbors, max_pixels=64):
    """Merge small sea IDs into water neighbors; preserve enclosed lakes."""
    areas = np.bincount(labels.ravel(), minlength=len(types))
    small = set(np.flatnonzero((types == 2) & (areas <= max_pixels)).tolist())
    lookup = np.arange(len(types), dtype=np.uint32)
    records = []
    # Process whole groups so neighboring artifacts cannot merge in a cycle.
    while small:
        group = {min(small)}
        pending = list(group)
        while pending:
            for j in neighbors[pending.pop()]:
                if j in small and j not in group:
                    group.add(j)
                    pending.append(j)
        small.difference_update(group)
        contacts = {}
        for i in group:
            for j, count in neighbors[i].items():
                if j not in group and types[j] == 2:
                    contacts[j] = contacts.get(j, 0)+count
        if contacts:
            target = min(contacts, key=lambda j: (-contacts[j], j))
        elif any(0 in neighbors[i] for i in group):
            target = 0
        else:
            continue
        for i in sorted(group):
            lookup[i] = target
            types[i] = 0
            records.append({'id': i, 'area': int(areas[i]), 'assigned_to': target})
    for y in range(labels.shape[0]):
        labels[y] = lookup[labels[y]]
    return records


def main(source='fauxlore.png', destination='map-data'):
    started = time.time()
    out = Path(destination)
    out.mkdir(parents=True, exist_ok=True)
    rgba = np.array(Image.open(source).convert('RGBA'))
    h, w = rgba.shape[:2]
    # The actual source uses beige (255,231,214), transparent seas, black land
    # contours, and dark blue (23,39,61) sea contours. Include pale beige variants.
    land = ((rgba[:, :, 0] >= 230) & (rgba[:, :, 1] >= 200)
            & (rgba[:, :, 2] >= 180) & (rgba[:, :, 3] >= 128))
    water = rgba[:, :, 3] == 0
    kinds = np.zeros((h, w), dtype=np.uint8)
    kinds[land] = 1
    kinds[water] = 2
    border = kinds == 0
    palette = Image.open(source).getcolors(1_000_000)
    print('Labelling original-resolution components', flush=True)
    del rgba, land, water
    labels, types, exterior_count = label_runs(kinds)
    original_contour_pixels = int(border.sum())
    retired = remove_land_artifacts(labels, types, border)
    seed_areas = np.bincount(labels.ravel(), minlength=len(types))
    # Track exact seed preservation after contour assignment.
    seed_hash = sum(int(np.sum(labels[y], dtype=np.uint64)) for y in range(h))
    print(f'Provinces: {np.count_nonzero(types)}; retired artifacts: {len(retired)}; allocating contours', flush=True)
    rounds, fallback_count = fill_borders(labels, border)
    unassigned = int(np.count_nonzero(border & (labels == 0)))
    assert unassigned == 0, 'Contour pixels must all belong to provinces'
    preserved_hash = sum(int(np.sum(labels[y][~border[y]], dtype=np.uint64)) for y in range(h))
    assert seed_hash == preserved_hash, 'Original seed pixels changed'
    retired_edge_sea = remove_edge_sea_artifacts(labels, types, border)
    neighbors = water_topology(labels, types)
    retired_small_sea = merge_small_seas(labels, types, neighbors)
    for record in retired:
        receivers = {}
        for x, y in record['pixels']:
            receiver = int(labels[y, x])
            assert receiver > 0 and types[receiver] != 0
            receivers[str(receiver)] = receivers.get(str(receiver), 0) + 1
        record['assigned_to'] = receivers
    count = len(types)
    areas = np.bincount(labels.ravel(), minlength=count)
    sx = np.zeros(count, dtype=np.float64)
    sy = np.zeros(count, dtype=np.float64)
    minx = np.full(count, w, dtype=np.int32)
    maxx = np.full(count, -1, dtype=np.int32)
    miny = np.full(count, h, dtype=np.int32)
    maxy = np.full(count, -1, dtype=np.int32)
    xcoords = np.arange(w)
    for y in range(h):
        row = labels[y]
        sx += np.bincount(row, weights=xcoords, minlength=count)
        sy += np.bincount(row, minlength=count) * y
        np.minimum.at(minx, row, xcoords)
        np.maximum.at(maxx, row, xcoords)
        ids = np.unique(row)
        miny[ids] = np.minimum(miny[ids], y)
        maxy[ids] = y
    if count > 0x1000000:
        raise ValueError('Province IDs exceed RGB capacity')
    rgb = np.empty((h, w, 3), dtype=np.uint8)
    rgb[:, :, 0] = labels >> 16
    rgb[:, :, 1] = (labels >> 8) & 255
    rgb[:, :, 2] = labels & 255
    Image.fromarray(rgb).save(out / 'province-ids.png')
    # Verify lossless round-trip of the delivered ID asset, one channel at a time.
    restored = np.asarray(Image.open(out / 'province-ids.png'))
    assert np.array_equal(restored, rgb)
    del restored, rgb
    meta = {}
    for i in range(1, count):
        if types[i] == 0:
            assert areas[i] == 0, 'Retired ID still present'
            continue
        meta[f'#{i:06X}'] = {
            'id': i, 'kind': {1: 'land', 2: 'sea', 3: 'lake'}[int(types[i])],
            'center': [round(sx[i]/areas[i], 2), round(sy[i]/areas[i], 2)],
            'bbox': [int(minx[i]), int(miny[i]), int(maxx[i]), int(maxy[i])],
            'area': int(areas[i]), 'seed_area': int(seed_areas[i]),
        }
    (out / 'provinces.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf-8')
    # A diagnostic overview, never used to identify provinces.
    rng = np.random.default_rng(42)
    colors = rng.integers(60, 235, (count, 3), dtype=np.uint8)
    colors[0] = [245, 247, 250]
    colors[types == 2, 0] //= 2
    colors[types == 2, 2] = 210
    preview = Image.fromarray(colors[labels[::5, ::5]])
    preview.save(out / 'province-preview.png')
    Image.fromarray(np.array([[0,0,0], [255,231,214], [75,135,190], [75,135,190]], dtype=np.uint8)[types[labels[::5, ::5]]]).save(out / 'terrain-preview.png')
    tiny = [i for i in range(1, count) if types[i] != 0 and seed_areas[i] < 16]
    report = {
        'source': str(source), 'width': w, 'height': h,
        'provinces': int(np.count_nonzero(types)), 'land': int(np.sum(types == 1)),
        'sea': int(np.sum(types == 2)), 'lake': int(np.sum(types == 3)), 'exterior_components': exterior_count,
        'contour_pixels': original_contour_pixels, 'unassigned_contour_pixels': unassigned,
        'reassigned_artifact_pixels': sum(r['seed_area'] for r in retired),
        'retired_land_artifacts': retired,
        'retired_edge_sea_artifacts': retired_edge_sea,
        'retired_small_sea_artifacts': retired_small_sea,
        'small_sea_max_area': 64,
        'lake_rule': 'Water network without 4-connected water access to exterior or image edge',
        'isolated_contour_pixels_assigned_by_distance': fallback_count,
        'contour_expansion_rounds': rounds, 'seed_pixels_preserved': seed_hash == preserved_hash,
        'png_roundtrip_verified': True,
        'tiny_component_ids_under_16_seed_pixels': tiny,
        'largest_provinces': sorted(meta.values(), key=lambda p: p['area'], reverse=True)[:12],
        'source_top_colors': sorted(palette, reverse=True)[:15] if palette else [],
        'elapsed_seconds': round(time.time()-started, 1),
    }
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ('largest_provinces','source_top_colors','tiny_component_ids_under_16_seed_pixels')}, ensure_ascii=False), flush=True)
    print(f'Tiny components requiring review: {len(tiny)}', flush=True)


if __name__ == '__main__':
    main(*sys.argv[1:])
