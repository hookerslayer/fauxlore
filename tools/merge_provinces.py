"""Merge explicitly selected province IDs without regenerating map topology."""
import json
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
MAP = ROOT / "map-data"
MERGES = (
    (1301, 1315),
    (392, 463),
    (175, 280),
    (4030, 4094),
    (2260, 2470),
    (3059, 3179),
    (3059, 3040),
    (3779, 3698),
    (195, 187),
    (4138, 4113),
    (2771, 2886),
)
Image.MAX_IMAGE_PIXELS = None


def encoded(rgb):
    return ((rgb[:, :, 0].astype(np.uint32) << 16)
            | (rgb[:, :, 1].astype(np.uint32) << 8)
            | rgb[:, :, 2].astype(np.uint32))


def rgb_from_ids(ids):
    rgb = np.empty((*ids.shape, 3), dtype=np.uint8)
    rgb[:, :, 0] = ids >> 16
    rgb[:, :, 1] = (ids >> 8) & 255
    rgb[:, :, 2] = ids & 255
    return rgb


def remap_image(path, mapping):
    with Image.open(path) as source:
        image = source.convert("RGBA")
    pixels = np.asarray(image).copy()
    ids = encoded(pixels[:, :, :3])
    for old, new in mapping.items():
        ids[ids == old] = new
    pixels[:, :, :3] = rgb_from_ids(ids)
    Image.fromarray(pixels).save(path, optimize=True)


def main():
    meta_path = MAP / "provinces.json"
    metadata = json.loads(meta_path.read_text(encoding="utf-8"))
    by_id = {item["id"]: item for item in metadata.values()}
    mapping = {}
    for survivor, retired in MERGES:
        target = mapping.get(survivor, survivor)
        if target not in by_id:
            raise ValueError(f"Missing surviving province metadata: {target}")
        # Older manual merges are already present in map-data. Skipping their
        # retired IDs makes this maintenance script safe to run again.
        if retired not in by_id:
            continue
        if by_id[target]["kind"] != "sea" or by_id[retired]["kind"] != "sea":
            raise ValueError(f"Only sea provinces may be merged: {target}, {retired}")
        mapping[retired] = target
    # Resolve the intentional 3179 -> 3059 <- 3040 chain.
    for retired, target in list(mapping.items()):
        while target in mapping:
            target = mapping[target]
        mapping[retired] = target

    # Recompute exact geometry from the source raster; don't renumber anything.
    remap_image(MAP / "province-ids.png", mapping)
    remap_image(MAP / "province-ids-rivers.png", mapping)
    with Image.open(MAP / "province-ids.png") as image:
        ids = encoded(np.asarray(image.convert("RGB")))
    values, counts = np.unique(ids, return_counts=True)
    sums_x = np.zeros(int(values.max()) + 1, dtype=np.float64)
    sums_y = np.zeros_like(sums_x)
    min_x = np.full(len(sums_x), image.width, dtype=np.int32)
    max_x = np.full(len(sums_x), -1, dtype=np.int32)
    min_y = np.full(len(sums_x), image.height, dtype=np.int32)
    max_y = np.full(len(sums_x), -1, dtype=np.int32)
    x = np.arange(image.width, dtype=np.int32)
    for y, row in enumerate(ids):
        sums_x += np.bincount(row, weights=x, minlength=len(sums_x))
        sums_y += np.bincount(row, minlength=len(sums_y)) * y
        np.minimum.at(min_x, row, x)
        np.maximum.at(max_x, row, x)
        present = np.unique(row)
        min_y[present] = np.minimum(min_y[present], y)
        max_y[present] = y

    retired_ids = set(mapping)
    updated = {}
    for province_id, item in by_id.items():
        if province_id in retired_ids or counts[values == province_id].size == 0:
            continue
        area = int(counts[np.searchsorted(values, province_id)])
        updated[f"#{province_id:06X}"] = {
            **item,
            "center": [round(sums_x[province_id] / area, 2),
                       round(sums_y[province_id] / area, 2)],
            "bbox": [int(min_x[province_id]), int(min_y[province_id]),
                     int(max_x[province_id]), int(max_y[province_id])],
            "area": area,
            "seed_area": item["seed_area"] + sum(
                by_id[old]["seed_area"] for old, new in mapping.items()
                if new == province_id),
        }
    meta_path.write_text(json.dumps(updated, ensure_ascii=False, indent=2), encoding="utf-8")

    # Keep the diagnostic province preview aligned to the new IDs.
    rng = np.random.default_rng(42)
    colors = rng.integers(60, 235, (int(values.max()) + 1, 3), dtype=np.uint8)
    colors[0] = [245, 247, 250]
    for province_id, item in by_id.items():
        if item["kind"] == "sea":
            colors[province_id, 0] //= 2
            colors[province_id, 2] = 210
    Image.fromarray(colors[ids[::5, ::5]]).save(MAP / "province-preview.png")

    report_path = MAP / "report.json"
    report = json.loads(report_path.read_text(encoding="utf-8"))
    report["provinces"] -= len(retired_ids)
    report["sea"] -= len(retired_ids)
    report.setdefault("retired_manual_sea_merges", []).extend(
        {"id": old, "assigned_to": new} for old, new in mapping.items())
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"mapping": mapping, "province_count": len(updated)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
