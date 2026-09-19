#!/bin/sh
# Regenerates the shelf cover images.
#
# The covers are produced by running each cart in this runtime and reducing its
# final frame exactly as the device does, rather than by copying screenshots
# from elsewhere: the art then matches what the game actually looks like here,
# and there is no third-party image to account for.
#
# Requires Python with Pillow. The PNGs are not committed, so run this once
# after `make assets`, and again whenever the cart list changes.
set -eu
cd "$(dirname "$0")/../.."

make build/test/cartrun
mkdir -p build/covers Source/covers
./build/test/cartrun Source/carts build/covers
python3 tools/covers/topng.py build/covers Source/covers
echo "wrote $(ls Source/covers/*.png | wc -l | tr -d ' ') covers"
