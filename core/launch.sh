#!/bin/bash
# Start the game of an app built by the kitchen, as its recipe says.
# usage: launch.sh <Resources dir> [variant index] [display id | main]
# Computes the window for the display (kitchen prepare-launch, which also writes
# the recipe's per-launch INI values), hides the menu bar and shows the black
# backdrop if the recipe asks, runs the game through kitchen-place.exe, and
# restores the menu bar however the game ends. Log: Resources/logs/last-launch.log
set -uo pipefail
RES="$(cd "$1" && pwd)"; VARIANT="${2:-0}"; DISPLAY_ID="${3:-main}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=core/wine-env.sh
source "$HERE/wine-env.sh"
KITCHEN="$RES/bin/kitchen"
mkdir -p "$RES/logs"
LOG="$RES/logs/last-launch.log"
: > "$LOG"

PLAN="$("$KITCHEN" prepare-launch "$RES" "$VARIANT" "$DISPLAY_ID" 2>>"$LOG")" \
    || { echo "cannot prepare the launch, see $LOG" >&2; exit 2; }
# sets GX GY GW GH GAME_EXE GAME_ARGS WIN_TITLE BACKDROP MENUBAR RECIPE_OVERRIDES, exports the recipe's env
eval "$PLAN"

MARKER="$RES/logs/menubar-restore"
FRAME_PID=""
restore() {
    [ -n "$FRAME_PID" ] && kill "$FRAME_PID" 2>/dev/null
    "$KITCHEN" menubar restore "$MARKER" >>"$LOG" 2>&1
}
trap restore EXIT
"$KITCHEN" menubar restore "$MARKER" >>"$LOG" 2>&1   # a crashed run may have left it hidden
[ "$MENUBAR" = hide ] && "$KITCHEN" menubar hide "$MARKER" >>"$LOG" 2>&1
[ -n "$RECIPE_OVERRIDES" ] && export WINEDLLOVERRIDES="$RECIPE_OVERRIDES"
if [ "$BACKDROP" = 1 ]; then
    "$KITCHEN" frame "$DISPLAY_ID" --wine "$RES" >>"$LOG" 2>&1 &
    FRAME_PID=$!
fi

TITLE_ARGS=()
[ -n "$WIN_TITLE" ] && TITLE_ARGS=(--title "$WIN_TITLE")
# the physical folder, which Wine sees as C:\Game: launchers start the game relative
# to it, and a path through Resources/game would reach Wine as a Z:\ path
cd "$RES/prefix/drive_c/Game" || exit 2
# bash 3.2 (macOS): an empty array is "unbound" under set -u, hence ${a[@]+...}
"$WINE" "$RES/bin/kitchen-place.exe" "$GX" "$GY" "$GW" "$GH" ${TITLE_ARGS[@]+"${TITLE_ARGS[@]}"} \
    -- "$GAME_EXE" ${GAME_ARGS[@]+"${GAME_ARGS[@]}"} >>"$LOG" 2>&1
RC=$?
"$(dirname "$WINE")/wineserver" -w >>"$LOG" 2>&1   # let the whole session end first
exit $RC
