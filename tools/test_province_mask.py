"""Small topology regressions; run with python tools/test_province_mask.py."""
import numpy as np
from build_province_mask import label_runs, fill_borders, remove_land_artifacts, water_topology, merge_small_seas


def main():
    # A divided enclosed water body is lake throughout. Two connected tiny
    # sea artifacts merge into the large sea without cycles or land changes.
    ids = np.ones((15, 15), dtype=np.uint32)
    ids[:, :7] = 2
    ids[4, 6] = 3
    ids[5, 6] = 4
    ids[7:9, 10:12] = 5
    ids[9:11, 10:12] = 6
    types = np.array([0, 1, 2, 2, 2, 2, 2], dtype=np.uint8)
    original_land = ids == 1
    neighbors = water_topology(ids, types)
    assert types.tolist() == [0, 1, 2, 2, 2, 3, 3]
    records = merge_small_seas(ids, types, neighbors)
    assert {r['id'] for r in records} == {3, 4}
    assert not np.any(np.isin(ids, [3, 4]))
    assert np.all(ids[original_land] == 1)
    assert np.any(ids == 5) and np.any(ids == 6)
    # Land blocks connected by one original pixel must remain a single province.
    kinds = np.array([
        [2,2,2,2,2,2,2],
        [2,0,0,0,0,0,2],
        [2,0,1,1,1,0,2],
        [2,0,1,0,1,0,2],
        [2,0,0,0,0,0,2],
        [2,2,2,2,2,2,2]], dtype=np.uint8)
    ids, types, exterior = label_runs(kinds)
    assert len(types) == 2 and exterior == 1
    original = ids.copy()
    fill_borders(ids, kinds == 0)
    assert np.all(ids[kinds == 1] == original[kinds == 1])
    assert np.all(ids[kinds == 0] > 0)
    assert np.all(ids[kinds == 2] == 0)

    # Diagonally touching land is distinct; smaller edge sea is retained.
    kinds = np.array([[2,2,0,1], [2,2,0,0], [0,0,1,0], [2,0,0,1]], dtype=np.uint8)
    ids, types, exterior = label_runs(kinds)
    assert np.sum(types == 1) == 3
    assert np.sum(types == 2) == 1 and ids[3,0] > 0
    assert ids[0,0] == 0

    # An isolated ink pixel separated by exterior is still allocated.
    ids = np.zeros((9,9), dtype=np.uint32)
    ids[4,1] = 2
    ids[4,7] = 1
    border = np.zeros_like(ids, dtype=bool)
    border[4,4] = True
    _, fallback = fill_borders(ids, border)
    assert fallback == 1 and ids[4,4] == 1
    assert np.count_nonzero(ids) == 3

    # Thick boundaries fill symmetrically; equal distances choose lower ID.
    ids = np.array([[2,0,0,0,1]], dtype=np.uint32)
    fill_borders(ids, ids == 0)
    assert ids.tolist() == [[2,2,1,1,1]]
    # A 1px-wide bridge in a >3px province survives; a standalone 2px land
    # artifact is retired and handed to its sea neighbor without renumbering.
    ids = np.array([[1,1,1,1,1,1], [0,0,1,0,0,0], [2,2,2,2,2,2],
                    [2,3,3,2,2,2]], dtype=np.uint32)
    types = np.array([0,1,2,1], dtype=np.uint8)
    border = ids == 0
    original = ids.copy()
    retired = remove_land_artifacts(ids, types, border)
    assert [r['id'] for r in retired] == [3]
    assert types.tolist() == [0,1,2,0]
    fill_borders(ids, border)
    assert np.all(ids[original == 3] == 2)
    assert np.array_equal(ids[original == 1], original[original == 1])
    assert np.array_equal(ids[original == 2], original[original == 2])
    print('PASS: bridges, diagonal separation, cropped seas, exterior, contours, ties, artifact reassignment')


if __name__ == '__main__':
    main()
