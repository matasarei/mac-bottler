#!/bin/bash
# Create the app's Wine prefix inside the bundle. Idempotent.
# usage: core/prefix.sh <Resources dir>
set -euo pipefail
mkdir -p "$1"; RES="$(cd "$1" && pwd)"   # wine refuses relative prefix paths

if [ -d "$RES/prefix/drive_c" ]; then
    echo "==> prefix already present, skipping"
    exit 0
fi
# shellcheck source=core/wine-env.sh
source "$(dirname "$0")/wine-env.sh"
[ -x "$WINE" ] || { echo "ERROR: no engine at $RES/wine (run make engine)"; exit 1; }
mkdir -p "$HOME"
echo "==> creating the wine prefix (about a minute)"
LOG="$RES/prefix-build.log"
WINEDLLOVERRIDES="mshtml=;mscoree=" "$WINE" wineboot -u >"$LOG" 2>&1 \
    || { echo "ERROR: wineboot failed, see $LOG"; exit 1; }
"$RES/wine/bin/wineserver" -w

# Old games render at point size and macOS scales 2x cleanly (docs/INTERNALS.md).
"$WINE" reg add 'HKCU\Software\Wine\Mac Driver' /v RetinaMode /t REG_SZ /d n /f >>"$LOG" 2>&1 \
    || { echo "ERROR: registry write failed, see $LOG"; exit 1; }
"$RES/wine/bin/wineserver" -w
rm -f "$LOG"
