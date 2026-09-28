#!/bin/bash
# Proxy DLLs: a game loads our DLL under the name of one of its own; every export
# is forwarded to the original (renamed <name>_orig.dll), and win/cursor.c runs
# when it loads.
#
#   win/proxy.sh def <original.dll>             print the forwarding .def (store it in the recipe)
#   win/proxy.sh build <file.def> <out.dll>     build the proxy DLL from a .def
#   win/proxy.sh exports <file.dll>             print "ordinal name" lines (tests, install checks)
#
# 32-bit DLLs only for now. Unnamed (ordinal-only) exports are refused.
set -euo pipefail
OBJDUMP=i686-w64-mingw32-objdump
CC=i686-w64-mingw32-gcc
HERE="$(cd "$(dirname "$0")" && pwd)"

exports() {  # "ordinal name", sorted by ordinal
    "$OBJDUMP" -p "$1" | awk '
        /^\[Ordinal\/Name Pointer\] Table/ { on = 1; next }
        on && /^$/ { on = 0 }
        on && match($0, /\+base\[ *[0-9]+\]/) {
            ord = substr($0, RSTART + 6, RLENGTH - 7) + 0
            print ord, $NF
        }' | sort -n
}

case "${1:-}" in
exports)
    exports "$2" ;;
def)
    DLL="$2"
    format="$("$OBJDUMP" -f "$DLL" 2>/dev/null || true)"
    case "$format" in *"file format pei-i386"*) ;; *) echo "proxy.sh: $DLL is not a 32-bit DLL" >&2; exit 1 ;; esac
    base="$(basename "$DLL")"; name="${base%.*}"
    total=$("$OBJDUMP" -p "$DLL" | awk '/^Export Address Table --/ { on = 1; next } on && /^$/ { on = 0 } on && /\[ *[0-9]+\]/ { n++ } END { print n + 0 }')
    named=$(exports "$DLL" | wc -l | tr -d ' ')
    [ "$named" -gt 0 ] || { echo "proxy.sh: $DLL exports nothing" >&2; exit 1; }
    [ "$named" -eq "$total" ] || { echo "proxy.sh: $DLL has unnamed exports ($named of $total named)" >&2; exit 1; }
    echo "; proxy for $base: every export forwarded to ${name}_orig.dll (win/proxy.sh def $base)"
    echo "LIBRARY $base"
    echo "EXPORTS"
    exports "$DLL" | while read -r ord sym; do
        printf '  "%s" = %s_orig."%s" @%s\n' "$sym" "$name" "$sym" "$ord"
    done ;;
build)
    DEF="$2"; OUT="$3"
    "$CC" -O2 -shared -o "$OUT" "$HERE/cursor.c" "$DEF" -Wl,--enable-stdcall-fixup ;;
*)
    sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
