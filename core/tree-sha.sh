#!/bin/bash
# Print one SHA256 for a directory tree: every file's path and content hash and
# every symlink's path and target, in sorted order. Pins folders that have no
# single download to checksum (e.g. a Wineskin wrapper's Frameworks).
# usage: core/tree-sha.sh <dir>
set -euo pipefail
cd "$1"
find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf 'L %s %s\n' "$f" "$(readlink "$f")"
    else printf 'F %s %s\n' "$f" "$(shasum -a 256 "$f" | cut -d' ' -f1)"; fi
done | shasum -a 256 | cut -d' ' -f1
