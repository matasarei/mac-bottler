#!/bin/bash
# Build a standalone app for a recipe. Run through make: make app RECIPE=recipes/<game> [APP=...]
# usage: core/build-app.sh <recipe dir> [app path, default ~/Applications/<title>.app] [--no-engine]
# --no-engine skips the Wine engine and prefix (tests: bundle structure only).
set -euo pipefail
cd "$(dirname "$0")/.."
RECIPE="$(cd "$1" && pwd)"; APP="${2:-}"; NO_ENGINE="${3:-}"
KITCHEN=build/bottler
mkdir -p build build/deps
swiftc -O -o "$KITCHEN" tools/bottler.swift
"$KITCHEN" recipe-check "$RECIPE/recipe.json"
TITLE="$("$KITCHEN" recipe-field "$RECIPE/recipe.json" title)"
BUNDLE_ID="$("$KITCHEN" recipe-field "$RECIPE/recipe.json" bundleId)"
ENGINE="$("$KITCHEN" recipe-field "$RECIPE/recipe.json" engine)"
PROXY_DLL="$("$KITCHEN" recipe-field "$RECIPE/recipe.json" proxy.dll)"
PROXY_DEF="$("$KITCHEN" recipe-field "$RECIPE/recipe.json" proxy.def)"
[ -n "$APP" ] || APP="$HOME/Applications/$TITLE.app"
RES="$APP/Contents/Resources"

echo "==> app skeleton: $APP"
mkdir -p "$APP/Contents/MacOS" "$RES/bin" "$RES/logs"
VERSION="$(git describe --tags --always 2>/dev/null || echo dev)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$TITLE</string>
    <key>CFBundleDisplayName</key><string>$TITLE</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>launcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
</dict>
</plist>
PLIST

if [ "$NO_ENGINE" != "--no-engine" ]; then
    core/engine.sh "$ENGINE" "$RES" build/deps
    core/prefix.sh "$RES"
    # CrossOver engines: the running game shows as the title in the Dock and menu bar
    if [ "$(. "engines/$ENGINE.env"; echo "$ENGINE_KIND")" = wineskin ]; then
        "$KITCHEN" dock-name "$RES/wine" "$TITLE" || echo "warning: the Dock will show wine64-preloader"
    fi
fi

echo "==> recipe"
rm -rf "$RES/recipe"; mkdir -p "$RES/recipe"
cp -R "$RECIPE/." "$RES/recipe/"
"$KITCHEN" fetch "$RES/recipe" build/deps/downloads "$RES/recipe/files"
if [ -n "$PROXY_DLL" ]; then
    echo "==> proxy $PROXY_DLL"
    win/proxy.sh build "$RES/recipe/$PROXY_DEF" "$RES/recipe/files/$PROXY_DLL"
fi

echo "==> tools"
cp "$KITCHEN" "$RES/bin/bottler"
i686-w64-mingw32-gcc -O2 -mwindows -o "$RES/bin/bottler-place.exe" win/place.c
cp core/install.sh core/launch.sh core/wine-env.sh "$RES/bin/"

echo "==> launcher"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/launcher" core/launcher/Launcher.swift

# absolute symlinks break the bundle seal (the prefix's z: -> /); wine recreates them
find "$RES" -type l -lname '/*' -delete
echo "==> signing (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>&1 | grep -v "replacing existing signature" || true
echo "==> done: $APP"
