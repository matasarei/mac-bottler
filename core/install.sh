#!/bin/bash
# Install the player's game into an app built by the kitchen.
# usage: core/install.sh <Resources dir> <the player's game folder>
# The game goes to Resources/game, seen by Windows as C:\Game; the icons made
# from it go to Resources/icon. Exit 3: the folder was refused (message on stderr).
set -euo pipefail
RES="$(cd "$1" && pwd)"; SRC="$2"
[ -d "$SRC" ] || { echo "ERROR: not a folder: $SRC" >&2; exit 2; }
"$RES/bin/kitchen" install "$RES/recipe" "$SRC" "$RES/game" "$RES/icon"
# relative, so the app can be moved: prefix/drive_c/Game -> Resources/game
[ -L "$RES/prefix/drive_c/Game" ] || ln -s ../../game "$RES/prefix/drive_c/Game"
