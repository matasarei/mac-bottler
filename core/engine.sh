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
    # fetch <url> <sha256> <local copy or ""> -> path of the verified archive in the cache
    fetch() {
        local file; file="$CACHE/$(basename "$1")"
        if [ ! -f "$file" ] && [ -n "$3" ] && [ -f "$3" ] \
           && echo "$2  $3" | shasum -a 256 -c - >/dev/null 2>&1; then
            cp -c "$3" "$file.part" 2>/dev/null || cp "$3" "$file.part"   # a local Wineskin install
            mv "$file.part" "$file"
        fi
        if [ ! -f "$file" ]; then
            echo "==> downloading $(basename "$1")" >&2
            curl -fL --progress-bar -o "$file.part" "$1" && mv "$file.part" "$file"
        fi
        echo "$2  $file" | shasum -a 256 -c - >/dev/null \
            || { echo "ERROR: checksum mismatch: delete $file and retry" >&2; return 1; }
        echo "$file"
    }
    ARCHIVE="$(fetch "$ENGINE_URL" "$ENGINE_SHA256" "${ENGINE_LOCAL:-}")"
    TMP="$CACHE/$NAME.unpack"; rm -rf "$TMP"; mkdir -p "$TMP/engine" "$TMP/wrapper"
    echo "==> unpacking engine $NAME"
    7zz x -y -o"$TMP/engine" "$ARCHIVE" >/dev/null
    tar -xf "$TMP"/engine/*.tar --strip-components 1 -C "$RES/wine"
    # the wrapper's frameworks: from a local Wineskin install with the same tree, else the download
    FRAMEWORKS="${ENGINE_FRAMEWORKS_LOCAL:-}"
    if [ -z "$FRAMEWORKS" ] || [ ! -d "$FRAMEWORKS" ] \
       || [ "$("$(dirname "$0")/tree-sha.sh" "$FRAMEWORKS")" != "$ENGINE_FRAMEWORKS_SHA256" ]; then
        WRAPPER="$(fetch "$ENGINE_WRAPPER_URL" "$ENGINE_WRAPPER_SHA256" "")"
        7zz x -y -o"$TMP/wrapper" "$WRAPPER" >/dev/null
        tar -xf "$TMP"/wrapper/*.tar -C "$TMP/wrapper" "$ENGINE_FRAMEWORKS"
        FRAMEWORKS="$TMP/wrapper/$ENGINE_FRAMEWORKS"
    fi
    [ "$("$(dirname "$0")/tree-sha.sh" "$FRAMEWORKS")" = "$ENGINE_FRAMEWORKS_SHA256" ] \
        || { echo "ERROR: $NAME frameworks checksum mismatch: $FRAMEWORKS"; exit 1; }
    # the engine loads these by name, from the same place as the other engines' (core/wine-env.sh)
    mkdir -p "$RES/wine/lib/external"
    ditto "$FRAMEWORKS" "$RES/wine/lib/external"
    rm -rf "$TMP"
    ;;
*)
    echo "ERROR: engine kind '$ENGINE_KIND' ($NAME) is not supported"; exit 1 ;;
esac

[ -x "$RES/wine/$ENGINE_LOADER" ] || { echo "ERROR: $NAME unpacked without $ENGINE_LOADER"; exit 1; }
