#!/bin/bash
# Build a project's app: the recipe's engine, a prefix, the tools, the launcher,
# and the player's game installed inside. Run through make: make app PROJECT=<name>
# usage: core/build-app.sh <project dir> [--no-engine]
# --no-engine skips the Wine engine and prefix (tests: bundle structure only).
#
# Everything is written inside the project folder, except the shared cache
# (build/cache), which is only written through a temp folder and an atomic rename
# under a lock, so several builds of different projects never conflict. A rebuild
# keeps the app's game folder (saves, settings): install never overwrites.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PROJ="$(cd "$1" && pwd)"; NO_ENGINE="${2:-}"
[ -f "$PROJ/project.json" ] || { echo "ERROR: no project.json in $PROJ (make project first)"; exit 2; }
WORK="$PROJ/.build"; CACHE="$ROOT/build/cache"
mkdir -p "$WORK" "$CACHE" "$PROJ/logs"
field() { python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],''))" "$PROJ/project.json" "$1"; }
RECIPE="${BOTTLER_RECIPES:-$ROOT/recipes}/$(field recipe)"   # BOTTLER_RECIPES: tests
PRIVATE="${BOTTLER_LOCAL_RECIPES:-$ROOT/recipes.local}/$(field recipe)"   # your own recipes, git-ignored
if [ ! -f "$RECIPE/recipe.json" ] && [ -f "$PRIVATE/recipe.json" ]; then RECIPE="$PRIVATE"; fi
if [ "$(field recipe)" = local ]; then RECIPE="$PROJ/recipe"; fi   # a project's own recipe
GAME_SRC="$(field game)"
[ -f "$RECIPE/recipe.json" ] || { echo "ERROR: no recipe at $RECIPE"; exit 2; }
[ -d "$GAME_SRC" ] || { echo "ERROR: the project's game folder is missing: $GAME_SRC"; exit 2; }

echo "==> tools"
BOTTLER="$WORK/bottler"
swiftc -O -o "$BOTTLER" tools/bottler.swift
"$BOTTLER" recipe-check "$RECIPE/recipe.json"
TITLE="$("$BOTTLER" recipe-field "$RECIPE/recipe.json" title)"
BUNDLE_ID="$("$BOTTLER" recipe-field "$RECIPE/recipe.json" bundleId)"
ENGINE="$("$BOTTLER" recipe-field "$RECIPE/recipe.json" engine)"
PROXY_DLL="$("$BOTTLER" recipe-field "$RECIPE/recipe.json" proxy.dll)"
APP="$PROJ/$TITLE.app"
NEW="$WORK/$TITLE.app"
rm -rf "$NEW"
RES="$NEW/Contents/Resources"
mkdir -p "$NEW/Contents/MacOS" "$RES/bin" "$RES/logs"

# Run a command holding a lock in the shared cache. mkdir is atomic; the owner's
# pid is recorded, so a lock left by a crashed build is recognised and removed.
with_lock() {  # with_lock <name> <command...>
    local lock="$CACHE/.lock-$1" rc=0; shift
    until mkdir "$lock" 2>/dev/null; do
        local owner; owner="$(cat "$lock/pid" 2>/dev/null || true)"
        if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then rm -rf "$lock"; continue; fi
        sleep 1
    done
    echo $$ > "$lock/pid"
    "$@" || rc=$?
    rm -rf "$lock"
    return $rc
}

if [ "$NO_ENGINE" != "--no-engine" ]; then
    # shellcheck source=/dev/null
    ENGINE_SHA="$(. "engines/$ENGINE.env"; echo "$ENGINE_SHA256")"
    # shellcheck source=/dev/null
    ENGINE_KIND="$(. "engines/$ENGINE.env"; echo "$ENGINE_KIND")"
    KEY="$ENGINE-${ENGINE_SHA:0:12}"
    ENGINE_CACHE="$CACHE/engines/$KEY"; PREFIX_CACHE="$CACHE/prefixes/$KEY"
    build_engine() {
        [ -d "$ENGINE_CACHE" ] && return 0
        echo "==> engine $ENGINE (first build only)"
        local tmp="$CACHE/engines/.tmp-$$"; rm -rf "$tmp"; mkdir -p "$tmp"
        core/engine.sh "$ENGINE" "$tmp" "$CACHE/downloads" && mv "$tmp/wine" "$ENGINE_CACHE"
        local rc=$?; rm -rf "$tmp"; return $rc
    }
    build_prefix() {
        [ -d "$PREFIX_CACHE" ] && return 0
        echo "==> prefix template for $ENGINE (first build only, about a minute)"
        local tmp="$CACHE/prefixes/.tmp-$$"; rm -rf "$tmp"; mkdir -p "$tmp"
        cp -cR "$ENGINE_CACHE" "$tmp/wine" && core/prefix.sh "$tmp" && mv "$tmp/prefix" "$PREFIX_CACHE"
        local rc=$?; rm -rf "$tmp"; return $rc
    }
    mkdir -p "$CACHE/engines" "$CACHE/prefixes"
    with_lock "engine-$KEY" build_engine
    with_lock "prefix-$KEY" build_prefix
    echo "==> engine and prefix (APFS clones of the cache)"
    cp -cR "$ENGINE_CACHE" "$RES/wine"
    cp -cR "$PREFIX_CACHE" "$RES/prefix"
    # CrossOver engines: the running game shows as the title in the Dock and menu bar
    if [ "$ENGINE_KIND" = wineskin ]; then
        "$BOTTLER" dock-name "$RES/wine" "$TITLE" || echo "warning: the Dock will show wine64-preloader"
    fi
fi
mkdir -p "$RES/prefix/drive_c"

echo "==> recipe"
cp -R "$RECIPE" "$RES/recipe"
# the project's own icon, if it has one (projects/<name>/icon.icns|png|ico|jpg)
for ext in icns png ico jpg; do
    if [ -f "$PROJ/icon.$ext" ]; then
        cp "$PROJ/icon.$ext" "$RES/recipe/project-icon.$ext"; echo "==> icon: the project's icon.$ext"; break
    fi
done
with_lock downloads "$BOTTLER" fetch "$RES/recipe" "$CACHE/downloads" "$RES/recipe/files"
if [ -n "$PROXY_DLL" ]; then
    # the export list comes from the project's own copy of the DLL, never from the repo
    echo "==> proxy $PROXY_DLL"
    DEF="$RES/recipe/${PROXY_DLL%.*}.def"
    win/proxy.sh def "$GAME_SRC/$PROXY_DLL" > "$DEF"
    win/proxy.sh build "$DEF" "$RES/recipe/files/$PROXY_DLL"
fi

echo "==> helpers and launcher"
cp "$BOTTLER" "$RES/bin/bottler"
i686-w64-mingw32-gcc -O2 -mwindows -o "$RES/bin/bottler-place.exe" win/place.c
mkdir -p "$RES/prefix/drive_c/bottler"   # C:\bottler: helpers loaded into the game (launch.modeCache)
i686-w64-mingw32-gcc -O2 -shared -o "$RES/prefix/drive_c/bottler/bottler-modecache.dll" win/modecache.c
cp core/install.sh core/launch.sh core/wine-env.sh "$RES/bin/"
swiftc -O -parse-as-library -o "$NEW/Contents/MacOS/launcher" core/launcher/Launcher.swift core/launcher/Decision.swift

echo "==> game"
# a rebuild keeps the game folder of the app it replaces (saves, settings)
if [ -d "$APP/Contents/Resources/prefix/drive_c/Game" ]; then
    mv "$APP/Contents/Resources/prefix/drive_c/Game" "$RES/prefix/drive_c/Game"
fi
if [ -f "$APP/Contents/Resources/launcher.conf" ]; then cp "$APP/Contents/Resources/launcher.conf" "$RES/"; fi
# and its Wine registry for the user (HKCU): games keep settings there (video options)
# that a fresh prefix from the cache would lose; recipe .reg files are imported on top
if [ -f "$APP/Contents/Resources/prefix/user.reg" ]; then cp "$APP/Contents/Resources/prefix/user.reg" "$RES/prefix/user.reg"; fi
bash "$RES/bin/install.sh" "$RES" "$GAME_SRC" | tee "$PROJ/logs/install.log"
# .reg files the game ships (recipe install.registry), imported into this build's
# fresh prefix: settings a game reads from the registry rather than from its folder
REGS="$("$BOTTLER" recipe-field "$RECIPE/recipe.json" install.registry)"
if [ -n "$REGS" ] && [ "$NO_ENGINE" != "--no-engine" ]; then
    (
        # shellcheck source=/dev/null
        . "$RES/bin/wine-env.sh"
        while IFS= read -r reg; do
            echo "==> registry: $reg"
            "$WINE" regedit /S "C:\\Game\\${reg//\//\\}" >>"$PROJ/logs/install.log" 2>&1
        done <<< "$REGS"
        "$(dirname "$WINE")/wineserver" -w
    )
fi
# the icon made from the game (recipe install.appIcon) becomes the bundle's icon
ICON_KEY=""
if [ -f "$RES/icon/AppIcon.icns" ]; then
    cp "$RES/icon/AppIcon.icns" "$RES/AppIcon.icns"
    ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi

VERSION="$(git describe --tags --always 2>/dev/null || echo dev)"
cat > "$NEW/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$TITLE</string>
    <key>CFBundleDisplayName</key><string>$TITLE</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>launcher</string>
    $ICON_KEY
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST

# absolute symlinks break the bundle seal (the prefix's z: -> /); wine-env.sh recreates z:
find "$RES" -type l -lname '/*' -delete
echo "==> signing (ad-hoc)"
codesign --force --deep --sign - "$NEW" 2>&1 | grep -v "replacing existing signature" || true

# swap in the new app
if [ -d "$APP" ]; then mv "$APP" "$WORK/previous.app.$$"; fi
mv "$NEW" "$APP"
rm -rf "$WORK/previous.app.$$"
touch "$APP"   # Finder and the Dock pick up the new icon
echo "==> done: $APP"
