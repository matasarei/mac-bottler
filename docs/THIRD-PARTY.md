# Third-party components and what is (not) in this repository

This repository is MIT-licensed (`LICENSE`) and contains only its own code,
documentation and recipes. `make test` fails if a binary, a media or game file,
an archive, or a file over 200 KB is ever tracked.

**Never in the repository:** game files of any kind (executables, DLLs, art,
sound, saves), anything derived from them (icons, a DLL's export list), and the
built apps. They live in `projects/` and `build/`, both git-ignored. A game is
always the player's own copy: it is read from the folder given to
`make project`, and icons and proxy export lists are made from it at build time.

## Downloaded or read at build time

| Component | Used for | License | Where it comes from |
|---|---|---|---|
| WineskinCX 23.7.1 engine (CrossOver 23 / Wine 8.0.1) | default Wine engine | Wine: LGPL-2.1; CrossOver's Wine sources are published by CodeWeavers under the LGPL | read from the local Wineskin Winery install (`~/Library/Application Support/Wineskin/Engines`), SHA256-pinned in `engines/crossover-23.env`; not redistributed |
| Wineskin 3.0.6_3 wrapper frameworks (FreeType, GnuTLS, GStreamer, …) | libraries the CrossOver engine loads | each library's own license (LGPL / MIT / FreeType License …) | read from the local Wineskin wrapper template, pinned by `core/tree-sha.sh`; not redistributed |
| WoWSilicon Wine runtime r17 (WineAndAqua Wine 11.13 + mtld3d) | optional engine | Wine: LGPL-2.1; mtld3d and packaging: see WoWSilicon | downloaded from WoWSilicon's GitHub release, SHA256-pinned in `engines/wowsilicon-r17.env` |
| Thinker mod v5.5 (Alpha Centauri recipe) | engine fixes, windowed mode, CPU idle fix | MIT ("Copyright (c) Thinker Mod authors") | downloaded from induktio/thinker's GitHub release, SHA256-pinned in `recipes/alpha-centauri/recipe.json` |

## Build tools (on the building machine, not shipped)

| Tool | Used for | License |
|---|---|---|
| Xcode Command Line Tools (swiftc, codesign, iconutil) | the `bottler` CLI, the launcher, signing | Apple |
| mingw-w64 (Homebrew) | the small Windows helpers in `win/`; their runtime is linked into those helpers | mingw-w64 runtime: ZPL / MIT-style; GCC: GPL with the runtime exception |
| 7-Zip (Homebrew `sevenzip`) | unpacking the Wineskin engine archive | LGPL-2.1 + BSD-3-Clause |
| Python 3 + Pillow | tests only (synthetic PE files, pixel checks) | PSF / MIT-CMU |

## Techniques and prior work

- The Windows helpers patch import tables (IAT) to redirect four user32 calls,
  a standard technique implemented here from the PE format documentation.
  smac-cpu-fix (GPL-3.0) was read while investigating Alpha Centauri; no code
  from it is used.
- Pinned values and build patterns follow matasarei/wow-launcher (MIT, same author).
