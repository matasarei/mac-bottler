#!/bin/bash
# Hermetic tests: synthetic PE files, no game data, no wine. Run with: make test
set -uo pipefail
cd "$(dirname "$0")/.."
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

echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
