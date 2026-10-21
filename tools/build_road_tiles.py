"""Lossless, lazy-loaded routing tiles; never decode province IDs through PNG alpha."""
import gzip
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
Image.MAX_IMAGE_PIXELS = None
SIZE = 512

def main():
    output = ROOT / 'map-data/road-tiles'
    output.mkdir(parents=True, exist_ok=True)
    with Image.open(ROOT / 'map-data/province-ids.png') as image:
        for y in range(0, image.height, SIZE):
            for x in range(0, image.width, SIZE):
                red, green, blue = image.crop((x, y, x + SIZE, y + SIZE)).convert('RGB').split()
                if red.getextrema()[1] > 0:
                    raise ValueError('Routing format requires province IDs <= 65535')
                pixels = bytearray(SIZE * SIZE * 2)
                pixels[0::2] = blue.tobytes()
                pixels[1::2] = green.tobytes()
                # Stable gzip header makes identical rebuilds byte-identical.
                (output / f'{x // SIZE}_{y // SIZE}.bin.gz').write_bytes(
                    gzip.compress(pixels, mtime=0))
    print(f'Routing tiles: {output}')

if __name__ == '__main__':
    main()
