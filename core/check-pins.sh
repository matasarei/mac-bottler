#!/bin/bash
# Check that every pinned download still exists and still has its pinned SHA256:
# the https engines in engines/ and the downloads in every recipe. They live in
# other people's releases; a retag there would break every new build silently.
# Local-only pins (file:// engines) are skipped. CI runs this monthly.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0
check() {  # check <label> <url> <sha256>
    if ! curl -fsSL -o "$TMP/f" "$2"; then echo "FAIL: $1: $2 does not download"; FAIL=1; return; fi
    local got; got="$(shasum -a 256 "$TMP/f" | cut -d' ' -f1)"
    if [ "$got" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: sha256 is $got, pinned $3"; FAIL=1; fi
}
for env in engines/*.env; do
    # shellcheck source=/dev/null
    url="$(. "$env"; echo "$ENGINE_URL")"
    # shellcheck source=/dev/null
    sha="$(. "$env"; echo "$ENGINE_SHA256")"
    case "$url" in https://*) check "$env" "$url" "$sha" ;; *) echo "skip: $env (local)" ;; esac
done
for r in recipes/*/recipe.json; do
    python3 -c 'import json,sys
for d in json.load(open(sys.argv[1])).get("install", {}).get("downloads", []): print(d["url"], d["sha256"])' "$r" |
    while read -r url sha; do check "$r" "$url" "$sha"; done || FAIL=1
done
exit $FAIL
