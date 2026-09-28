#!/bin/bash
# Install the player's game into an app built by the kitchen.
# usage: core/install.sh <Resources dir> <the player's game folder>
# The game goes physically into the prefix as C:\Game (a link from outside the
# prefix would make Wine report a Z:\...\Name.app\... path, which old games
# mishandle); Resources/game links to it for convenience. Icons go to
# Resources/icon. Exit 3: the folder was refused (message on stderr).
set -euo pipefail
RES="$(cd "$1" && pwd)"; SRC="$2"
[ -d "$SRC" ] || { echo "ERROR: not a folder: $SRC" >&2; exit 2; }
mkdir -p "$RES/prefix/drive_c"
"$RES/bin/kitchen" install "$RES/recipe" "$SRC" "$RES/prefix/drive_c/Game" "$RES/icon"
# relative, so the app can be moved
[ -L "$RES/game" ] || ln -s prefix/drive_c/Game "$RES/game"
