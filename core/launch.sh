#!/bin/bash
# Start the game of an app built by mac-bottler, as its recipe says.
# usage: launch.sh <Resources dir> [variant index] [display id | main]
# Computes the window for the display (bottler prepare-launch, which also writes
# the recipe's per-launch INI values), hides the menu bar and shows the black
# backdrop if the recipe asks, runs the game through bottler-place.exe, and
# restores the menu bar however the game ends. Log: Resources/logs/last-launch.log
set -uo pipefail
RES="$(cd "$1" && pwd)"; VARIANT="${2:-0}"; DISPLAY_ID="${3:-main}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# per-user state outside every app (wine-env.sh moves HOME into the bundle): a
# rebuilt or deleted app must not strand the menu bar hidden
STATE="${BOTTLER_STATE:-$HOME/Library/Application Support/mac-bottler}"   # BOTTLER_STATE: tests
mkdir -p "$STATE"
# shellcheck source=core/wine-env.sh
source "$HERE/wine-env.sh"
KITCHEN="$RES/bin/bottler"
mkdir -p "$RES/logs"
LOG="$RES/logs/last-launch.log"
: > "$LOG"

PLAN="$("$KITCHEN" prepare-launch "$RES" "$VARIANT" "$DISPLAY_ID" 2>>"$LOG")" \
    || { echo "cannot prepare the launch, see $LOG" >&2; exit 2; }
# sets GX GY GW GH REG_FILE GAME_EXE GAME_ARGS WIN_TITLE BACKDROP MENUBAR RECIPE_OVERRIDES, exports the recipe's env
eval "$PLAN"
# the recipe's per-launch registry values (bottler prepare-launch wrote them to drive C:)
[ -n "$REG_FILE" ] && "$WINE" regedit /S "$REG_FILE" >>"$LOG" 2>&1

# the menu bar and Dock as the player has them, put back however the game ends (a
# snapshot a crashed run left behind is kept: it holds the real settings)
SNAPSHOT="$STATE/desktop.json"
FRAME_PID=""
restore() {
    [ -n "$FRAME_PID" ] && kill "$FRAME_PID" 2>/dev/null
    "$KITCHEN" desktop restore "$SNAPSHOT" >>"$LOG" 2>&1
}
trap restore EXIT
"$KITCHEN" desktop save "$SNAPSHOT" >>"$LOG" 2>&1
[ "$MENUBAR" = hide ] && "$KITCHEN" menubar hide >>"$LOG" 2>&1
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
"$WINE" "$RES/bin/bottler-place.exe" "$GX" "$GY" "$GW" "$GH" ${TITLE_ARGS[@]+"${TITLE_ARGS[@]}"} \
    -- "$GAME_EXE" ${GAME_ARGS[@]+"${GAME_ARGS[@]}"} >>"$LOG" 2>&1
RC=$?
"$(dirname "$WINE")/wineserver" -w >>"$LOG" 2>&1   # let the whole session end first
exit $RC
