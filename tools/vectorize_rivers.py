"""Convert the sparse river RGBA mask into simplified river polylines."""

from __future__ import annotations

import argparse
import json
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image


NEIGHBOURS = [(dx, dy) for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dx or dy]


def zhang_suen(mask: np.ndarray) -> np.ndarray:
    """Thin a binary mask to one-pixel-wide 8-connected centerlines."""
    mask = mask.copy()
    while True:
        changed = False
        for phase in (0, 1):
            p2, p3, p4 = mask[:-2, 1:-1], mask[:-2, 2:], mask[1:-1, 2:]
            p5, p6, p7 = mask[2:, 2:], mask[2:, 1:-1], mask[2:, :-2]
            p8, p9 = mask[1:-1, :-2], mask[:-2, :-2]
            neighbours = np.stack((p2, p3, p4, p5, p6, p7, p8, p9))
            count = neighbours.sum(axis=0)
            transitions = sum(
                ((neighbours[i] == 0) & (neighbours[(i + 1) % 8] == 1))
                for i in range(8)
            )
            if phase == 0:
                preserve = (p2 & p4 & p6) | (p4 & p6 & p8)
            else:
                preserve = (p2 & p4 & p8) | (p2 & p6 & p8)
            remove = mask[1:-1, 1:-1] & (count >= 2) & (count <= 6) & (transitions == 1) & ~preserve
            if np.any(remove):
                mask[1:-1, 1:-1][remove] = False
                changed = True
        if not changed:
            return mask


def rdp(points: list[tuple[int, int]], epsilon: float) -> list[tuple[int, int]]:
    if len(points) < 3:
        return points
    a = np.asarray(points[0], dtype=float)
    b = np.asarray(points[-1], dtype=float)
    ab = b - a
    length = float(np.linalg.norm(ab))
    if length == 0:
        distances = [float(np.linalg.norm(np.asarray(p, dtype=float) - a)) for p in points[1:-1]]
    else:
        distances = [
            float(abs(np.cross(ab, np.asarray(p, dtype=float) - a)) / length)
            for p in points[1:-1]
        ]
    if not distances:
        return [points[0], points[-1]]
    index = int(np.argmax(distances)) + 1
    if distances[index - 1] <= epsilon:
        return [points[0], points[-1]]
    return rdp(points[: index + 1], epsilon)[:-1] + rdp(points[index:], epsilon)


def edge_key(a: int, b: int) -> tuple[int, int]:
    return (a, b) if a < b else (b, a)


def pixel_id(rgb: tuple[int, int, int]) -> int:
    return (rgb[0] << 16) | (rgb[1] << 8) | rgb[2]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("rivers", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--province-ids", type=Path)
    parser.add_argument("--provinces", type=Path)
    parser.add_argument("--epsilon", type=float, default=1.5)
    args = parser.parse_args()

    image = Image.open(args.rivers).convert("RGBA")
    width, height = image.size
    alpha_image = image.getchannel("A")
    bbox = alpha_image.getbbox()
    if not bbox:
        raise ValueError("The river image has no non-transparent pixels")
    x0, y0, x1, y1 = bbox
    alpha = np.asarray(alpha_image.crop(bbox)) > 0
    skeleton = zhang_suen(alpha)
    ys, xs = np.nonzero(skeleton)
    points = {(int(y + y0) * width + int(x + x0)) for y, x in zip(ys, xs)}
    del alpha, skeleton, ys, xs

    metadata = {}
    kind_by_id = {}
    ids_image = None
    if args.province_ids and args.provinces:
        metadata = json.loads(args.provinces.read_text(encoding="utf-8"))
        kind_by_id = {entry["id"]: entry["kind"] for entry in metadata.values()}
        ids_image = Image.open(args.province_ids).convert("RGB")
        if ids_image.size != image.size:
            raise ValueError("province-ids.png and rivers.png must have the same dimensions")

    def neighbours(point: int) -> list[int]:
        x, y = point % width, point // width
        result = []
        for dx, dy in NEIGHBOURS:
            nx, ny = x + dx, y + dy
            if 0 <= nx < width and 0 <= ny < height:
                candidate = ny * width + nx
                if candidate in points:
                    result.append(candidate)
        return result

    def touches_sea(point: int) -> bool:
        if ids_image is None:
            return False
        x, y = point % width, point // width
        for radius in range(0, 5):
            for dx in range(-radius, radius + 1):
                for dy in range(-radius, radius + 1):
                    nx, ny = x + dx, y + dy
                    if not (0 <= nx < width and 0 <= ny < height):
                        continue
                    identifier = pixel_id(ids_image.getpixel((nx, ny)))
                    if kind_by_id.get(identifier) == "sea":
                        return True
        return False

    polylines = []
    visited_points: set[int] = set()
    components = 0
    for start in list(points):
        if start in visited_points:
            continue
        components += 1
        component = []
        queue = [start]
        visited_points.add(start)
        while queue:
            point = queue.pop()
            component.append(point)
            for neighbour in neighbours(point):
                if neighbour not in visited_points:
                    visited_points.add(neighbour)
                    queue.append(neighbour)

        adjacency = {point: neighbours(point) for point in component}
        nodes = {point for point, links in adjacency.items() if len(links) != 2}
        if not nodes:
            nodes = {component[0]}

        mouths = {point for point in nodes if len(adjacency[point]) == 1 and touches_sea(point)}
        distances = {point: 0 for point in mouths}
        distance_queue = deque(mouths)
        while distance_queue:
            point = distance_queue.popleft()
            for neighbour in adjacency[point]:
                if neighbour not in distances:
                    distances[neighbour] = distances[point] + 1
                    distance_queue.append(neighbour)
        max_distance = max(distances.values(), default=0)

        visited_edges: set[tuple[int, int]] = set()
        for node in nodes:
            for neighbour in adjacency[node]:
                key = edge_key(node, neighbour)
                if key in visited_edges:
                    continue
                path = [node]
                previous, current = node, neighbour
                visited_edges.add(key)
                while current not in nodes:
                    path.append(current)
                    next_points = [candidate for candidate in adjacency[current] if candidate != previous]
                    if not next_points:
                        break
                    previous, current = current, next_points[0]
                    visited_edges.add(edge_key(previous, current))
                path.append(current)
                # Keep two-point links between nearby junctions. Dropping
                # them makes the network look continuous at overview scale,
                # but turns into visible dashed fragments when zoomed in.
                if len(path) < 2:
                    continue
                xy = [(point % width, point // width) for point in path]
                simplified = rdp(xy, args.epsilon)
                start_distance = distances.get(path[0], max_distance)
                end_distance = distances.get(path[-1], max_distance)
                start_progress = 1.0 - (start_distance / max_distance if max_distance else 0.0)
                end_progress = 1.0 - (end_distance / max_distance if max_distance else 0.0)
                polylines.append({
                    "points": simplified,
                    "width_start": round(0.8 + 1.7 * start_progress, 3),
                    "width_end": round(0.8 + 1.7 * end_progress, 3),
                })

    args.output.write_text(json.dumps({
        "width": width,
        "height": height,
        "components": components,
        "polylines": polylines,
    }, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"components={components} polylines={len(polylines)} pixels={len(points)}")


if __name__ == "__main__":
    main()
