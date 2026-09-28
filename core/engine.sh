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
case "$ENGINE_KIND" in
    tar.xz) ;;
    *) echo "ERROR: engine kind '$ENGINE_KIND' ($NAME) is not supported yet"; exit 1 ;;
esac

mkdir -p "$CACHE"
ARCHIVE="$CACHE/$NAME.tar.xz"
if [ ! -f "$ARCHIVE" ]; then
    echo "==> downloading engine $NAME"
    curl -fL --progress-bar -o "$ARCHIVE.part" "$ENGINE_URL"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
echo "$ENGINE_SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null \
    || { echo "ERROR: $NAME checksum mismatch: delete $ARCHIVE and retry"; exit 1; }

echo "==> unpacking engine $NAME"
mkdir -p "$RES/wine"
tar -xJf "$ARCHIVE" --strip-components 1 -C "$RES/wine"
[ -x "$RES/wine/$ENGINE_LOADER" ] || { echo "ERROR: $NAME unpacked without $ENGINE_LOADER"; exit 1; }
