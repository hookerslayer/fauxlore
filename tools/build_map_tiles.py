"""Split the packed province/river texture into browser-loadable tiles."""
from pathlib import Path
import sys
from PIL import Image
import numpy as np

Image.MAX_IMAGE_PIXELS = None

source = Path(sys.argv[1] if len(sys.argv) > 1 else 'map-data/province-ids-rivers.png')
output = Path(sys.argv[2] if len(sys.argv) > 2 else 'map-data/tiles')
tile_size = int(sys.argv[3] if len(sys.argv) > 3 else 2048)
output.mkdir(parents=True, exist_ok=True)
relief = Image.open('relief.png').convert('RGBA')
with Image.open(source) as image:
    image = image.convert('RGBA')
    width, height = image.size
    if relief.size != image.size:
        raise ValueError('Relief and province mask dimensions must match')
    for y in range(0, height, tile_size):
        for x in range(0, width, tile_size):
            box = (x, y, min(x + tile_size, width), min(y + tile_size, height))
            pixels = np.array(image.crop(box))
            terrain = np.asarray(relief.crop(box))
            if not (np.array_equal(terrain[:, :, 0], terrain[:, :, 1])
                    and np.array_equal(terrain[:, :, 1], terrain[:, :, 2])):
                raise ValueError('Packed relief requires grayscale RGB values')
            # Alpha bit 7 stores rivers; bits 0..6 store relief darkness.
            # Transparent relief is neutral. Opacity is applied by the shader.
            darkness = ((255-terrain[:, :, 0].astype(np.float32)) / 255
                        * terrain[:, :, 3] / 255)
            pixels[:, :, 3] = ((pixels[:, :, 3] > 127).astype(np.uint8)*128
                               | np.rint(darkness*127).astype(np.uint8))
            tile = Image.fromarray(pixels)
            tile.save(output / f'{x // tile_size}_{y // tile_size}.png', optimize=True)
print(f'Created {((width + tile_size - 1) // tile_size) * ((height + tile_size - 1) // tile_size)} tiles in {output}')
