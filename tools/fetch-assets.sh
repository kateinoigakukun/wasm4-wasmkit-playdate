#!/bin/sh
# Downloads the game carts, which this repository deliberately does not carry.
# They belong to their authors; `carts.txt` names them and records each one's
# origin and licence.
set -eu
cd "$(dirname "$0")/.."

# The one list. Adding a game means adding a line there, not here.
tools/carts.sh >/dev/null

mkdir -p Source/carts

for cart in $(tools/carts.sh ids); do
    if [ ! -f "Source/carts/$cart.wasm" ]; then
        echo "fetching cart $cart"
        curl -fsSL -o "Source/carts/$cart.wasm" "https://wasm4.org/carts/$cart.wasm"
    fi
done

echo "carts ready"
