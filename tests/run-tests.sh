#!/bin/bash
# Hermetic tests: synthetic PE files, no game data, no wine. Run with: make test
set -uo pipefail
cd "$(dirname "$0")/.."
command -v python3 >/dev/null && python3 -c "import PIL" 2>/dev/null \
    || { echo "tests need python3 with Pillow (test-only): pip3 install pillow"; exit 1; }
T="build/test"
rm -rf "$T"; mkdir -p "$T"
swiftc -O -o "$T/kitchen" tools/kitchen.swift || { echo "FAIL: kitchen does not compile"; exit 1; }

PASS=0; FAIL=0
check() {  # check <description> <python expression over the report `r`>
    if python3 -c "import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$REPORT"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $1"
    fi
}
pe() { python3 tests/fixtures/mkpe.py "$@"; }
exe() {  # the report entry for a path
    echo "next(e for e in r['executables'] if e['path']=='$1')"
}

# --- scan: a 2D DirectDraw game folder with a launcher stub, an uninstaller, leftovers
G="$T/game2d"; mkdir -p "$G/sub"
pe "$G/Game.exe" --size 400000 --imports KERNEL32.dll,USER32.dll,GDI32.dll,DDRAW.dll,DSOUND.dll,DINPUT.dll
pe "$G/Launch.exe" --size 60000 --imports KERNEL32.dll,USER32.dll,SHELL32.dll
pe "$G/unins000.exe" --size 900000 --imports KERNEL32.dll,USER32.dll,GDI32.dll,DDRAW.dll,DSOUND.dll,DINPUT.dll  # same imports as the game, larger
pe "$G/ddraw.dll" --imports KERNEL32.dll,OPENGL32.dll
pe "$G/sub/tool.exe" --console --imports KERNEL32.dll
touch "$G/secdrv.sys" "$G/GAME.ICD"
REPORT="$T/game2d.json"
"$T/kitchen" scan "$G" > "$REPORT" || { echo "FAIL: scan exited non-zero"; exit 1; }
check "Game.exe is i386 gui"            "$(exe Game.exe)['arch']=='i386' and $(exe Game.exe)['subsystem']=='gui'"
check "Game.exe apis classified"        "$(exe Game.exe)['apis']=={'graphics':['gdi','ddraw'],'audio':['directsound'],'input':['directinput']}"
check "console tool detected"           "$(exe sub/tool.exe)['subsystem']=='console'"
check "main exe is the game"            "r['suggestion']['mainExe']=='Game.exe' and r['suggestion']['graphics']=='ddraw'"
check "uninstaller is not the main exe" "'unins000.exe' not in r['suggestion']['candidates']"
check "launcher stub noted"             "any('Launch.exe looks like a launcher stub' in n for n in r['suggestion']['notes'])"
check "local ddraw.dll flagged"         "any(f['path']=='ddraw.dll' and f['kind']=='wrapper' for f in r['found'])"
check "SafeDisc leftovers flagged"      "{f['path'] for f in r['found'] if f['kind']=='protection'}=={'secdrv.sys','GAME.ICD'}"
check "md5 is reported"                 "len($(exe Game.exe)['md5'])==32"

# --- scan: a 64-bit D3D11 game
G="$T/game3d"; mkdir -p "$G"
pe "$G/Game64.exe" --64 --size 300000 --imports KERNEL32.dll,USER32.dll,d3d11.dll,dxgi.dll,XINPUT1_3.dll,xaudio2_9.dll
REPORT="$T/game3d.json"
"$T/kitchen" scan "$G" > "$REPORT"
check "64-bit detected"                 "$(exe Game64.exe)['arch']=='x86_64'"
check "d3d11 classified"                "r['suggestion']['graphics']=='d3d10-11' and r['suggestion']['arch']=='x86_64'"
check "xinput and xaudio2 classified"   "$(exe Game64.exe)['apis']['input']==['xinput'] and $(exe Game64.exe)['apis']['audio']==['xaudio2']"

# --- scan: renderer in a packed DLL, an encrypted blob, a symlinked folder
G="$T/engine"; mkdir -p "$G/real"
pe "$G/real/hl.exe" --size 150000 --imports WSOCK32.dll,KERNEL32.dll,USER32.dll
pe "$G/real/hw.dll" --broken-imports --text "opengl32.dll"
head -c 4096 /dev/urandom > "$G/real/sw.dll"
ln -s real "$G/link"
REPORT="$T/engine.json"
"$T/kitchen" scan "$G/link" > "$REPORT"
check "paths are relative through a symlinked root" "$(exe hl.exe)['path']=='hl.exe'"
check "packed dll: imports unreadable"  "$(exe hw.dll)['imports']=='unreadable'"
check "packed dll: string hint found"   "$(exe hw.dll)['stringHints']==['opengl32.dll'] and $(exe hw.dll)['apis']=={'graphics':['opengl']}"
check "non-PE dll reported, no crash"   "'error' in $(exe sw.dll)"
check "renderer-in-dll note"            "any('renderer lives in a DLL (hw.dll)' in n for n in r['suggestion']['notes'])"

# --- scan: bad input
"$T/kitchen" scan "$T/does-not-exist" >/dev/null 2>&1; rc=$?
if [ $rc -eq 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: missing folder should exit 2, got $rc"; fi
"$T/kitchen" >/dev/null 2>&1; rc=$?
if [ $rc -eq 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: no subcommand should exit 2, got $rc"; fi
EMPTY="$T/empty"; mkdir -p "$EMPTY"; REPORT="$T/empty.json"
"$T/kitchen" scan "$EMPTY" > "$REPORT"
check "empty folder: no executables, no main exe" "r['executables']==[] and 'mainExe' not in r['suggestion']"

# --- icon / exe-icon on a synthetic exe with 24-bit icons stored contiguously
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
I="$T/icon"; mkdir -p "$I"
pe "$I/game.exe" --imports KERNEL32.dll --icons 16,24,32,48,64
if "$T/kitchen" icon "$I/game.exe" "$I/out"; then ok; else bad "icon exits 0"; fi
for f in AppIcon.icns icon_1024.png exe-icon-256.png exe-icon-48.png exe-icon-32.png exe-icon-16.png; do
    if [ -s "$I/out/$f" ]; then ok; else bad "icon writes $f"; fi
done
px() { python3 -c "
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert('RGBA'); x, y = int(sys.argv[2]), int(sys.argv[3])
print(im.size[0], im.getpixel((x, y))[3])" "$@"; }
if [ "$(px "$I/out/icon_1024.png" 0 0)" = "1024 0" ]; then ok; else bad "master corner is transparent"; fi
if [ "$(px "$I/out/icon_1024.png" 512 512)" = "1024 255" ]; then ok; else bad "master centre is opaque"; fi
if [ "$(px "$I/out/exe-icon-256.png" 128 128)" = "256 255" ]; then ok; else bad "exe icon is 256 px"; fi

if "$T/kitchen" exe-icon "$I/game.exe" "$I/out" "$I/patched.exe"; then ok; else bad "exe-icon exits 0"; fi
if [ "$(stat -f %z "$I/game.exe")" = "$(stat -f %z "$I/patched.exe")" ]; then ok; else bad "exe-icon keeps the file size"; fi
if python3 - "$I/game.exe" "$I/patched.exe" <<'PY'
import struct, sys
a, b = open(sys.argv[1], "rb").read(), open(sys.argv[2], "rb").read()
pe = struct.unpack_from("<I", a, 0x3C)[0]
n = struct.unpack_from("<H", a, pe + 6)[0]; opt = struct.unpack_from("<H", a, pe + 20)[0]
rsrc = [struct.unpack_from("<8sIIII", a, pe + 24 + opt + 40 * i) for i in range(n)]
lo, hi = [(s[4], s[4] + s[3]) for s in rsrc if s[0].rstrip(b"\0") == b".rsrc"][0]
changed = [i for i in range(len(a)) if a[i] != b[i]]
sys.exit(0 if changed and all(lo <= i < hi for i in changed) else 1)
PY
then ok; else bad "exe-icon changes bytes only inside .rsrc"; fi
if "$T/kitchen" icon "$I/patched.exe" "$I/round2" && [ "$(px "$I/round2/exe-icon-256.png" 0 0)" = "256 0" ]; then ok; else bad "patched exe yields the new 256 px icon"; fi

python3 -c "
import os, sys
from PIL import Image
os.makedirs(sys.argv[1], exist_ok=True)
Image.frombytes('RGBA', (256, 256), os.urandom(256 * 256 * 4)).save(sys.argv[1] + '/exe-icon-256.png')" "$I/big"
"$T/kitchen" exe-icon "$I/game.exe" "$I/big" "$I/refused.exe" 2>/dev/null; rc=$?
if [ $rc -eq 3 ] && [ ! -e "$I/refused.exe" ]; then ok; else bad "oversized icons are refused (exit 3, no output), got $rc"; fi
pe "$I/noicon.exe" --imports KERNEL32.dll
"$T/kitchen" icon "$I/noicon.exe" "$I/none" 2>/dev/null; rc=$?
if [ $rc -eq 2 ]; then ok; else bad "exe without icons: icon exits 2, got $rc"; fi
"$T/kitchen" exe-icon "$I/noicon.exe" "$I/out" "$I/refused2.exe" 2>/dev/null; rc=$?
if [ $rc -eq 3 ] && [ ! -e "$I/refused2.exe" ]; then ok; else bad "exe without icons: exe-icon refused, got $rc"; fi

# --- geometry: fake displays (Cocoa rects: origin bottom-left of the primary, y up)
geo() { "$T/kitchen" geometry --screen "$1" --visible "$2" --safe-top "$3" --primary "$4" "${@:5}"; }
expect() {  # expect <description> <expected> <actual>
    if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$2', got '$3'"; fi
}
UW=0,0,3440,1440; MB=0,0,1728,1117
expect "ultrawide, menu bar ignored: 4:3 centred" "760 0 1920 1440" \
    "$(geo $UW 0,0,3440,1410 0 $UW pillarbox:4:3 8)"
expect "MacBook, below the notch" "144 35 1440 1080" \
    "$(geo $MB 0,0,1728,1084 32 $MB pillarbox:4:3 8)"
expect "native mode fills the usable area" "0 0 3440 1440" \
    "$(geo $UW 0,0,3440,1410 0 $UW native 8)"
expect "visible Dock at the bottom is left out" "808 1 1824 1368" \
    "$(geo $UW 0,70,3440,1340 0 $UW pillarbox:4:3 8)"
expect "display left of the primary: negative x" "-2240 0 1920 1440" \
    "$(geo -2560,-323,2560,1440 -2560,-323,2560,1440 0 $MB pillarbox:4:3 8)"
expect "display above the primary: negative y" "760 -1440 1920 1440" \
    "$(geo 0,1117,3440,1440 0,1117,3440,1440 0 $MB pillarbox:4:3 8)"
expect "portrait display: width-limited 4:3" "0 556 1080 808" \
    "$(geo 0,0,1080,1920 0,0,1080,1920 0 0,0,1080,1920 pillarbox:4:3 8)"
expect "no align keeps odd sizes" "0 0 1728 1117" \
    "$(geo $MB $MB 0 $MB native)"
geo $UW $UW 0 $UW pillarbox:four 8 >/dev/null 2>&1; rc=$?
expect "bad mode exits 2" "2" "$rc"
"$T/kitchen" geometry 999999 native >/dev/null 2>&1; rc=$?
expect "unknown display exits 2" "2" "$rc"

# --- win helpers: proxy DLL round trip on a throwaway DLL built here
X="$T/proxy"; mkdir -p "$X"
printf 'int __stdcall a(int x){return x;}\nint b(void){return 2;}\nint c(void){return 3;}\n' > "$X/fake.c"
printf 'LIBRARY fake.dll\nEXPORTS\n  "?mangled@Thing@@QAEXH@Z" = a@4 @7\n  plain_b = b @2\n  third_c = c @5\n' > "$X/fake-src.def"
i686-w64-mingw32-gcc -shared -o "$X/fake.dll" "$X/fake.c" "$X/fake-src.def" 2>/dev/null || bad "fake DLL builds"
if win/proxy.sh def "$X/fake.dll" > "$X/fake.def"; then ok; else bad "proxy def exits 0"; fi
expect "def forwards to fake_orig" "3" "$(grep -c '= fake_orig\.' "$X/fake.def")"
if win/proxy.sh build "$X/fake.def" "$X/proxy.dll" 2>/dev/null; then ok; else bad "proxy build exits 0"; fi
expect "proxy export table matches the original" "$(win/proxy.sh exports "$X/fake.dll")" "$(win/proxy.sh exports "$X/proxy.dll")"
expect "mangled name kept at its ordinal" "7 ?mangled@Thing@@QAEXH@Z" "$(win/proxy.sh exports "$X/proxy.dll" | grep mangled)"
printf 'LIBRARY noname.dll\nEXPORTS\n  named = b @1\n  hidden = c @2 NONAME\n' > "$X/noname-src.def"
i686-w64-mingw32-gcc -shared -o "$X/noname.dll" "$X/fake.c" "$X/noname-src.def" 2>/dev/null
win/proxy.sh def "$X/noname.dll" >/dev/null 2>&1; rc=$?
expect "unnamed exports are refused" "1" "$rc"
pe "$X/x64.dll" --64 --imports KERNEL32.dll
win/proxy.sh def "$X/x64.dll" >/dev/null 2>&1; rc=$?
expect "64-bit DLLs are refused" "1" "$rc"
if i686-w64-mingw32-gcc -O2 -mwindows -o "$X/kitchen-place.exe" win/place.c 2>/dev/null; then ok; else bad "place.c builds"; fi

echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
