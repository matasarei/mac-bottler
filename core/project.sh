#!/bin/bash
# Create a project: one game built from one recipe, with its own local state.
# usage: core/project.sh <name> <recipe name> <the player's game folder>
# Writes projects/<name>/project.json. projects/ is git-ignored: it holds your
# game's path and, after make app, an app with the game inside.
set -euo pipefail
cd "$(dirname "$0")/.."
NAME="$1"; RECIPE="$2"; GAME="$3"
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "ERROR: project name must be lowercase letters, digits and dashes: $NAME"; exit 2; }
RECIPES="${BOTTLER_RECIPES:-recipes}"   # BOTTLER_RECIPES: tests
[ -f "$RECIPES/$RECIPE/recipe.json" ] || { echo "ERROR: no recipe $RECIPES/$RECIPE"; exit 2; }
[ -d "$GAME" ] || { echo "ERROR: not a folder: $GAME"; exit 2; }
GAME="$(cd "$GAME" && pwd)"
P="${BOTTLER_PROJECTS:-projects}/$NAME"   # BOTTLER_PROJECTS: tests
[ ! -e "$P/project.json" ] || { echo "ERROR: project $NAME exists: $P/project.json"; exit 2; }
mkdir -p "$P"
python3 -c 'import json,sys; json.dump({"recipe": sys.argv[1], "game": sys.argv[2]}, open(sys.argv[3], "w"), indent=2)' "$RECIPE" "$GAME" "$P/project.json"
echo "==> project $NAME: recipe $RECIPE, game $GAME"
echo "    next: make app PROJECT=$NAME"
