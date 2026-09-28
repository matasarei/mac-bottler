#!/bin/bash
# Install a pinned Wine engine into an app bundle. Idempotent.
# usage: core/engine.sh <engine name> <Resources dir> <download cache dir>
set -euo pipefail
NAME="$1"; CACHE="$3"
mkdir -p "$2"; RES="$(cd "$2" && pwd)"
ENV_FILE="$(dirname "$0")/../engines/$NAME.env"
[ -f "$ENV_FILE" ] || { echo "ERROR: unknown engine '$NAME' (see engines/)"; exit 1; }
# shellcheck source=/dev/null
source "$ENV_FILE"

if [ -x "$RES/wine/$ENGINE_LOADER" ]; then
    echo "==> engine $NAME already present, skipping"
    exit 0
fi
mkdir -p "$CACHE" "$RES/wine"
case "$ENGINE_KIND" in
tar.xz)
    ARCHIVE="$CACHE/$NAME.tar.xz"
    if [ ! -f "$ARCHIVE" ]; then
        echo "==> downloading engine $NAME"
        curl -fL --progress-bar -o "$ARCHIVE.part" "$ENGINE_URL"
        mv "$ARCHIVE.part" "$ARCHIVE"
    fi
    echo "$ENGINE_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null \
        || { echo "ERROR: $NAME checksum mismatch: delete $ARCHIVE and retry"; exit 1; }
    echo "==> unpacking engine $NAME"
    tar -xJf "$ARCHIVE" --strip-components 1 -C "$RES/wine"
    ;;
wineskin)
    command -v 7zz >/dev/null || { echo "ERROR: 7zz not found: brew install sevenzip"; exit 1; }
    ARCHIVE="${ENGINE_URL#file://}"
    [ -f "$ARCHIVE" ] || { echo "ERROR: engine archive not found: $ARCHIVE (install it with Wineskin Winery)"; exit 1; }
    echo "$ENGINE_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null \
        || { echo "ERROR: $NAME archive checksum mismatch: $ARCHIVE"; exit 1; }
    [ -d "$ENGINE_FRAMEWORKS" ] || { echo "ERROR: Wineskin wrapper frameworks not found: $ENGINE_FRAMEWORKS"; exit 1; }
    [ "$("$(dirname "$0")/tree-sha.sh" "$ENGINE_FRAMEWORKS")" = "$ENGINE_FRAMEWORKS_SHA256" ] \
        || { echo "ERROR: $NAME frameworks checksum mismatch: $ENGINE_FRAMEWORKS"; exit 1; }
    echo "==> unpacking engine $NAME"
    TMP="$CACHE/$NAME.unpack"; rm -rf "$TMP"; mkdir -p "$TMP"
    7zz x -y -o"$TMP" "$ARCHIVE" >/dev/null
    tar -xf "$TMP"/*.tar --strip-components 1 -C "$RES/wine"
    rm -rf "$TMP"
    # the engine loads these by name, from the same place as the other engines' (core/wine-env.sh)
    mkdir -p "$RES/wine/lib/external"
    ditto "$ENGINE_FRAMEWORKS" "$RES/wine/lib/external"
    ;;
*)
    echo "ERROR: engine kind '$ENGINE_KIND' ($NAME) is not supported"; exit 1 ;;
esac

[ -x "$RES/wine/$ENGINE_LOADER" ] || { echo "ERROR: $NAME unpacked without $ENGINE_LOADER"; exit 1; }
