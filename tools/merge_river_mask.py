"""Pack the sparse river alpha mask into the map ID texture alpha channel."""

from pathlib import Path
import argparse

from PIL import Image


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("province_ids", type=Path)
    parser.add_argument("rivers", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    ids = Image.open(args.province_ids).convert("RGB")
    river_alpha = Image.open(args.rivers).getchannel("A")
    if ids.size != river_alpha.size:
        raise ValueError("The province and river images must have the same dimensions")
    packed = ids.copy()
    packed.putalpha(river_alpha)
    packed.save(args.output, optimize=True)
    print(f"wrote {args.output} ({ids.width}x{ids.height})")


if __name__ == "__main__":
    main()
