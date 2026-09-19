"""Converts the binary PGM files cartrun writes into one-bit PNGs.

pdc turns any PNG in the source tree into a Playdate bitmap, so these are what
the shelf loads.
"""

import pathlib
import sys

from PIL import Image

source, destination = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
destination.mkdir(parents=True, exist_ok=True)

for pgm in sorted(source.glob("*.pgm")):
    # cartrun also writes a "-levels" dump of the console's own four-level
    # picture, which exists for diagnosing the reduction and is not shipped.
    if pgm.stem.endswith("-levels"):
        continue
    image = Image.open(pgm).convert("L")
    # The pixels are already pure black and white; "1" without dithering keeps
    # them that way rather than dithering an already-dithered image.
    image.convert("1", dither=Image.Dither.NONE).save(destination / (pgm.stem + ".png"))
    print(f"{pgm.stem}.png")
