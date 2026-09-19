# Third-party material

This project is Apache-2.0 (see `LICENSE`). No game is committed to this repository.

## Games

`make assets` downloads these from wasm4.org into `Source/carts/`,
where `pdc` packages them into the build. Each carries a permissive licence from
its own upstream repository.

The list is `carts.txt`, which is also what the shelf and the downloader read;
the table below is generated from it.

<!-- carts:begin -->
| Cart | Upstream | Licence |
| --- | --- | --- |
| `watris` | `aduros/wasm4`, `examples/watris` | ISC |
| `snake` | `aduros/wasm4`, tutorial | ISC |
| `2048` | github.com/peterhellberg/w4-2048 | MIT |
| `corn` | github.com/SLiV9/corn | MIT |
| `one-slime-army` | github.com/ibillingsley/wasm4-gamejam | ISC |
| `zxz` | github.com/drcz/ZxZ | BSD-2-Clause |
| `tictactoe` | github.com/christopher-kleine/tic-tac-toe-wasm4 | BSD-2-Clause |
| `mazethingie` | github.com/joyrider3774/mazethingie_wasm4 | MIT |
| `platformer-test` | `aduros/wasm4`, `examples/platformer-test` | ISC |
| `sound-demo` | `aduros/wasm4`, `examples/sound-demo` | ISC |
| `raw-assembly` | `aduros/wasm4`, `examples/raw-assembly` | ISC |
| `number-slide` | wasm4.org/play/number-slide, by Giovana Ferreira Waterkemper and Jamily Goncalves de Sales Souza | CC BY-NC-SA 4.0 |
| `smash-sugar-parallelepipeds` | wasm4.org/play/smash-sugar-parallelepipeds, by Lázaro Albuquerque (lzralbu.itch.io) | CC BY-NC-SA 4.0 |
<!-- carts:end -->

`docs/number-slide.png` is a screenshot of Number Slide rendered by this
runtime. The game is CC BY-NC-SA 4.0, by Giovana Ferreira Waterkemper and
Jamily Goncalves de Sales Souza, so that image carries those terms rather than
this project's Apache-2.0.

## Ported code

`Sources/WASM4/Framebuffer.swift` and `Sources/WASM4/APU.swift` are translations
of `runtimes/native/src/framebuffer.c` and `apu.c` from `aduros/wasm4`, ISC,
Copyright (c) Bruno Garcia. `Sources/WASM4/Font.swift` is the 1792-byte font
table from `framebuffer.c`, reproduced byte for byte.

## Vendored build support

`buildsupport/link_map.ld` is copied from the Playdate SDK's
`C_API/buildsupport/`, which is 0BSD and intended to be copied into projects.

