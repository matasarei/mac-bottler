#!/bin/bash
# Hermetic tests: synthetic PE files, no game data, no wine. Run with: make test
set -uo pipefail
cd "$(dirname "$0")/.."
# --- the repository itself: nothing that may not be published (docs/THIRD-PARTY.md)
AUDIT_FAIL=0
while IFS= read -r f; do
    case "$(echo "$f" | tr '[:upper:]' '[:lower:]')" in
        *.exe|*.dll|*.sys|*.icd|*.pcx|*.bmp|*.png|*.jpg|*.ico|*.icns|*.wav|*.mp3|*.ogg|*.flc|*.wve|*.bik|*.cvr|*.sav|*.mpq|*.ttf|*.fon|*.zip|*.7z|*.tar*|*.dmg|*.iso)
            echo "FAIL: repo tracks a game/media/archive file: $f"; AUDIT_FAIL=1 ;;
    esac
    if [ -f "$f" ] && ! grep -Iq . "$f" 2>/dev/null && [ -s "$f" ]; then echo "FAIL: repo tracks a binary file: $f"; AUDIT_FAIL=1; fi
    if [ -f "$f" ] && [ "$(stat -f %z "$f")" -gt 204800 ]; then echo "FAIL: repo tracks a file over 200 KB: $f"; AUDIT_FAIL=1; fi
done < <(git ls-files)
[ "$AUDIT_FAIL" -eq 0 ] || exit 1

command -v python3 >/dev/null && python3 -c "import PIL" 2>/dev/null \
    || { echo "tests need python3 with Pillow (test-only): pip3 install pillow"; exit 1; }
T="build/test"
rm -rf "$T"; mkdir -p "$T"
swiftc -O -o "$T/bottler" tools/bottler.swift || { echo "FAIL: bottler does not compile"; exit 1; }

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
"$T/bottler" scan "$G" > "$REPORT" || { echo "FAIL: scan exited non-zero"; exit 1; }
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
"$T/bottler" scan "$G" > "$REPORT"
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
"$T/bottler" scan "$G/link" > "$REPORT"
check "paths are relative through a symlinked root" "$(exe hl.exe)['path']=='hl.exe'"
check "packed dll: imports unreadable"  "$(exe hw.dll)['imports']=='unreadable'"
check "packed dll: string hint found"   "$(exe hw.dll)['stringHints']==['opengl32.dll'] and $(exe hw.dll)['apis']=={'graphics':['opengl']}"
check "non-PE dll reported, no crash"   "'error' in $(exe sw.dll)"
check "renderer-in-dll note"            "any('renderer lives in a DLL (hw.dll)' in n for n in r['suggestion']['notes'])"

# --- scan: bad input
"$T/bottler" scan "$T/does-not-exist" >/dev/null 2>&1; rc=$?
if [ $rc -eq 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: missing folder should exit 2, got $rc"; fi
"$T/bottler" >/dev/null 2>&1; rc=$?
if [ $rc -eq 2 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: no subcommand should exit 2, got $rc"; fi
EMPTY="$T/empty"; mkdir -p "$EMPTY"; REPORT="$T/empty.json"
"$T/bottler" scan "$EMPTY" > "$REPORT"
check "empty folder: no executables, no main exe" "r['executables']==[] and 'mainExe' not in r['suggestion']"

# --- icon / exe-icon on a synthetic exe with 24-bit icons stored contiguously
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
I="$T/icon"; mkdir -p "$I"
pe "$I/game.exe" --imports KERNEL32.dll --icons 16,24,32,48,64
if "$T/bottler" icon "$I/game.exe" "$I/out"; then ok; else bad "icon exits 0"; fi
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

if "$T/bottler" exe-icon "$I/game.exe" "$I/out" "$I/patched.exe"; then ok; else bad "exe-icon exits 0"; fi
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
if "$T/bottler" icon "$I/patched.exe" "$I/round2" && [ "$(px "$I/round2/exe-icon-256.png" 0 0)" = "256 0" ]; then ok; else bad "patched exe yields the new 256 px icon"; fi

python3 -c "
import os, sys
from PIL import Image
os.makedirs(sys.argv[1], exist_ok=True)
Image.frombytes('RGBA', (256, 256), os.urandom(256 * 256 * 4)).save(sys.argv[1] + '/exe-icon-256.png')" "$I/big"
"$T/bottler" exe-icon "$I/game.exe" "$I/big" "$I/refused.exe" 2>/dev/null; rc=$?
if [ $rc -eq 3 ] && [ ! -e "$I/refused.exe" ]; then ok; else bad "oversized icons are refused (exit 3, no output), got $rc"; fi
pe "$I/noicon.exe" --imports KERNEL32.dll
"$T/bottler" icon "$I/noicon.exe" "$I/none" 2>/dev/null; rc=$?
if [ $rc -eq 2 ]; then ok; else bad "exe without icons: icon exits 2, got $rc"; fi
"$T/bottler" exe-icon "$I/noicon.exe" "$I/out" "$I/refused2.exe" 2>/dev/null; rc=$?
if [ $rc -eq 3 ] && [ ! -e "$I/refused2.exe" ]; then ok; else bad "exe without icons: exe-icon refused, got $rc"; fi

# a figure on a transparent background goes on a plate instead of being cropped
pe "$I/figure.exe" --imports KERNEL32.dll --icons 16,32 --figure
if "$T/bottler" icon "$I/figure.exe" "$I/fig"; then ok; else bad "icon on a figure exits 0"; fi
rgb() { python3 -c "import sys; from PIL import Image; print(*Image.open(sys.argv[1]).convert('RGBA').getpixel((int(sys.argv[2]), int(sys.argv[3]))))" "$@"; }
# the 24-bit icon's mask must be applied (ImageIO does not), or there is no figure to plate
if [ "$(rgb "$I/fig/icon_1024.png" 160 512)" = "170 165 154 255" ]; then ok; else bad "figure: the plate fills the body, got $(rgb "$I/fig/icon_1024.png" 160 512)"; fi
if [ "$(px "$I/fig/icon_1024.png" 0 0)" = "1024 0" ]; then ok; else bad "figure: the corner stays transparent"; fi
if [ "$(px "$I/out/icon_1024.png" 150 512)" = "1024 255" ] && [ "$(px "$I/out/icon_1024.png" 60 512)" = "1024 0" ]; then ok; else bad "a picture still fills the body, no plate"; fi
# an opaque card with transparent margins (an icon already drawn for macOS) fills the body
pe "$I/card.exe" --imports KERNEL32.dll --icons 32 --card
"$T/bottler" icon "$I/card.exe" "$I/card" >/dev/null
EDGE="$(rgb "$I/card/icon_1024.png" 115 512)"
if [ "${EDGE##* }" = "255" ] && [ "$EDGE" != "170 165 154 255" ]; then ok; else bad "a card with margins is trimmed and fills the body, no plate: edge is $EDGE"; fi
mode() { python3 -c "import sys; from PIL import Image; print(Image.open(sys.argv[1]).mode)" "$1"; }
if [ "$(mode "$I/fig/exe-icon-256.png")" = "P" ]; then ok; else bad "few-colour exe icon is a palette PNG"; fi
# two icon slots with ~4 KB of room: the largest icon still goes in, the rest is left out
if "$T/bottler" exe-icon "$I/figure.exe" "$I/fig" "$I/figure-patched.exe" 2>/dev/null; then ok; else bad "exe-icon fits a 2-slot exe"; fi
if "$T/bottler" icon "$I/figure-patched.exe" "$I/fig2" 2>/dev/null && [ "$(px "$I/fig2/exe-icon-256.png" 128 128)" = "256 255" ] \
   && [ "$(python3 -c "import sys; from PIL import Image; print(Image.open(sys.argv[1]).convert('RGBA').getpixel((128,128)) == Image.open(sys.argv[2]).convert('RGBA').getpixel((128,128)))" "$I/fig/exe-icon-256.png" "$I/fig2/exe-icon-256.png")" = True ]
then ok; else bad "2-slot exe carries the new 256 px icon"; fi

# --- geometry: fake displays (Cocoa rects: origin bottom-left of the primary, y up)
geo() { "$T/bottler" geometry --screen "$1" --visible "$2" --safe-top "$3" --primary "$4" "${@:5}"; }
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
"$T/bottler" geometry 999999 native >/dev/null 2>&1; rc=$?
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
if i686-w64-mingw32-gcc -O2 -mwindows -o "$X/bottler-place.exe" win/place.c 2>/dev/null; then ok; else bad "place.c builds"; fi

# --- recipes: check, fetch, install on a fake game built here
R="$T/recipe"; SRC="$R/source"; mkdir -p "$SRC/saves" "$R/recipe" "$R/zip/mod/sub"
pe "$SRC/Game.exe" --size 300000 --imports KERNEL32.dll,USER32.dll,DDRAW.dll --icons 16,24,32,48,64
cp "$X/fake.dll" "$SRC/sound.dll"
pe "$SRC/ddraw.dll" --imports KERNEL32.dll
touch "$SRC/secdrv.sys" "$SRC/TERRAN.ICD" "$SRC/aaa.icd" "$SRC/zzz.icd"
# folders full of files around the excluded files: a walker bug once dropped whole folders
for d in fx techs voices aa zz; do mkdir -p "$SRC/$d"; for i in 1 2 3 4 5; do echo "$d $i" > "$SRC/$d/file $i.wav"; done; done
printf '[Game]\r\nMode=1\r\nName=test\r\n\r\n[Other]\r\nx=1\r\n' > "$SRC/Game.ini"
echo "my save" > "$SRC/saves/slot1.sav"
echo "mod v1" > "$R/zip/mod/readme.txt"; echo "data" > "$R/zip/mod/sub/data.txt"
(cd "$R/zip" && zip -qr ../mod.zip mod)
ZIPSHA=$(shasum -a 256 "$R/mod.zip" | cut -d' ' -f1)
GAMEMD5=$(md5 -q "$SRC/Game.exe")
win/proxy.sh def "$SRC/sound.dll" > "$R/recipe/sound.def"
write_recipe() {  # write_recipe <status for the game's md5> [extra top-level json]
cat > "$R/recipe/recipe.json" <<JSON
{
  "schema": 1, "title": "Test Game", "bundleId": "com.example.test", "engine": "crossover-23",
  "detect": { "required": ["Game.exe"], "fingerprint": "Game.exe",
              "builds": { "$GAMEMD5": { "status": "$1", "label": "fixture", "message": "not this one" } } },
  "install": {
    "exclude": ["secdrv.sys", "TERRAN.ICD", "aaa.icd", "zzz.icd"],
    "rename": { "ddraw.dll": "ddraw.dll.gog" },
    "downloads": [ { "url": "file://$PWD/$R/mod.zip", "sha256": "$ZIPSHA",
                     "files": { "mod/readme.txt": "readme.txt", "mod/sub": "extra" } } ],
    "ini": [ { "file": "Game.ini", "section": "Game", "set": { "Mode": "0", "Added": "yes" } } ],
    "proxy": { "dll": "sound.dll" },
    "appIcon": "Game.exe", "exeIcon": "Game.exe"
  },
  "launch": { "variants": [ { "label": "Play", "exe": "Game.exe", "args": [] } ],
              "window": { "mode": "pillarbox:4:3", "align": 8 } }${2:-}
}
JSON
}
write_recipe verified
if "$T/bottler" recipe-check "$R/recipe/recipe.json" >/dev/null; then ok; else bad "valid recipe passes recipe-check"; fi
if "$T/bottler" fetch "$R/recipe" "$R/cache" "$R/recipe/files" >/dev/null; then ok; else bad "fetch exits 0"; fi
expect "fetch copies a mapped file" "mod v1" "$(cat "$R/recipe/files/readme.txt" 2>/dev/null)"
expect "fetch copies a mapped folder" "data" "$(cat "$R/recipe/files/extra/data.txt" 2>/dev/null)"
win/proxy.sh build "$R/recipe/sound.def" "$R/recipe/files/sound.dll" 2>/dev/null
tree_md5() { (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 md5 -q | md5 -q); }
BEFORE=$(tree_md5 "$SRC")
G="$R/game"; ICONS="$R/icons"
OUT=$("$T/bottler" install "$R/recipe" "$SRC" "$G" "$ICONS"); rc=$?
expect "install exits 0" "0" "$rc"
expect "source folder untouched" "$BEFORE" "$(tree_md5 "$SRC")"
if [ ! -e "$G/secdrv.sys" ] && [ ! -e "$G/TERRAN.ICD" ]; then ok; else bad "excluded files not copied"; fi
expect "every folder next to excluded files arrives complete" "25" "$(ls "$G"/fx "$G"/techs "$G"/voices "$G"/aa "$G"/zz | grep -c '\.wav$')"
if [ -e "$G/ddraw.dll.gog" ] && [ ! -e "$G/ddraw.dll" ]; then ok; else bad "ddraw.dll renamed aside"; fi
expect "original DLL kept as _orig" "$(md5 -q "$SRC/sound.dll")" "$(md5 -q "$G/sound_orig.dll" 2>/dev/null)"
expect "proxy DLL installed" "$(md5 -q "$R/recipe/files/sound.dll")" "$(md5 -q "$G/sound.dll" 2>/dev/null)"
expect "download files added" "mod v1" "$(cat "$G/readme.txt" 2>/dev/null)"
expect "ini key set, CRLF kept, new key added in its section" \
    "$(printf '[Game]\r\nMode=0\r\nName=test\r\nAdded=yes\r\n\r\n[Other]\r\nx=1\r\n')" "$(cat "$G/Game.ini")"
if [ -s "$ICONS/AppIcon.icns" ]; then ok; else bad "app icon made"; fi
expect "stock exe kept as .bkp" "$GAMEMD5" "$(md5 -q "$G/Game.exe.bkp" 2>/dev/null)"
if [ "$(md5 -q "$G/Game.exe")" != "$GAMEMD5" ] && [ "$(stat -f %z "$G/Game.exe")" = "$(stat -f %z "$SRC/Game.exe")" ]; then ok; else bad "exe icon patched in place"; fi
expect "install stamp written" "verified" "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['build'])" "$G/.bottler-install.json" 2>/dev/null)"
echo "played" >> "$G/saves/slot1.sav"
AFTER=$(tree_md5 "$G")
OUT=$("$T/bottler" install "$R/recipe" "$SRC" "$G" "$ICONS")
expect "second install changes nothing" "already installed: nothing to change" "$(echo "$OUT" | tail -1)"
expect "second install keeps every file (saves too)" "$AFTER" "$(tree_md5 "$G")"
# a rebuild makes a fresh icon folder over the kept game: the icon comes from the
# stock exe (.bkp), not from the one that already carries it
"$T/bottler" install "$R/recipe" "$SRC" "$G" "$R/icons-rebuild" >/dev/null
expect "rebuild makes the same app icon" "$(md5 -q "$ICONS/icon_1024.png")" "$(md5 -q "$R/icons-rebuild/icon_1024.png" 2>/dev/null)"
sed -i '' 's/"exeIcon": "Game.exe"/"exeIcon": "ddraw.dll.gog"/' "$R/recipe/recipe.json"
OUT=$("$T/bottler" install "$R/recipe" "$SRC" "$R/game-noicon" "$R/icons-noicon" 2>&1)
if echo "$OUT" | grep -q "keeps its own icon" && [ ! -e "$R/game-noicon/ddraw.dll.gog.bkp" ]; then ok; else bad "a refused exe icon leaves no .bkp (so a later install retries)"; fi

write_recipe refuse
"$T/bottler" install "$R/recipe" "$SRC" "$R/game-refused" "$R/icons2" >/dev/null 2>&1; rc=$?
if [ $rc -eq 3 ] && [ ! -e "$R/game-refused/Game.exe" ]; then ok; else bad "refused build: exit 3 and nothing copied, got $rc"; fi
sed -i '' "s/$GAMEMD5/00000000000000000000000000000000/" "$R/recipe/recipe.json"
sed -i '' 's/"fingerprint": "Game.exe",/"fingerprint": "Game.exe", "unknown": "refuse",/' "$R/recipe/recipe.json"
"$T/bottler" install "$R/recipe" "$SRC" "$R/game-unknown" "$R/icons3" >/dev/null 2>&1; rc=$?
expect "unknown build with unknown=refuse exits 3" "3" "$rc"
write_recipe verified ', "tittle": "typo"'
MSG=$("$T/bottler" recipe-check "$R/recipe/recipe.json" 2>&1); rc=$?
if [ $rc -eq 2 ] && echo "$MSG" | grep -q 'unknown key "tittle"'; then ok; else bad "typo'd key is rejected by name"; fi
write_recipe verified
printf 'LIBRARY sound.dll\nEXPORTS\n  "other" = sound_orig."other" @1\n' > "$R/recipe/sound.def"
"$T/bottler" install "$R/recipe" "$SRC" "$R/game-baddef" "$R/icons4" >/dev/null 2>&1; rc=$?
expect "proxy .def not matching the DLL is refused" "3" "$rc"
sed -i '' "s/$ZIPSHA/$(printf '%064d' 0)/" "$R/recipe/recipe.json"
"$T/bottler" fetch "$R/recipe" "$R/cache-bad" "$R/files-bad" >/dev/null 2>&1; rc=$?
expect "wrong download checksum fails fetch" "2" "$rc"

# core/install.sh on a fake app layout
A="$T/app/Contents/Resources"; mkdir -p "$A/bin" "$A/prefix/drive_c"
cp "$T/bottler" "$A/bin/"; write_recipe verified; win/proxy.sh def "$SRC/sound.dll" > "$R/recipe/sound.def"
cp -R "$R/recipe" "$A/recipe"
if bash core/install.sh "$A" "$SRC" >/dev/null; then ok; else bad "core/install.sh exits 0"; fi
if [ -e "$A/prefix/drive_c/Game/Game.exe" ] && [ ! -L "$A/prefix/drive_c/Game" ] && [ "$(readlink "$A/game")" = "prefix/drive_c/Game" ]; then ok; else bad "the game is physically at C:\\Game; Resources/game links to it"; fi
if [ -s "$A/icon/AppIcon.icns" ]; then ok; else bad "install.sh icons go to Resources/icon"; fi
bash core/install.sh "$A" "$T/does-not-exist" >/dev/null 2>&1; rc=$?
expect "install.sh: missing source exits 2" "2" "$rc"

# --- core/launch.sh with a stub wine and a recording bottler
L="$PWD/$T/launch/Contents/Resources"; mkdir -p "$L/bin" "$L/wine/bin" "$L/prefix/drive_c/Game" "$L/recipe"
ln -s prefix/drive_c/Game "$L/game"
cp core/launch.sh core/wine-env.sh "$L/bin/"
cat > "$L/bin/bottler" <<STUB
#!/bin/bash
case "\$1" in frame|menubar) echo "\$*" >> "$L/calls"; exit 0 ;; esac
exec "$PWD/$T/bottler" "\$@"
STUB
cat > "$L/wine/bin/wine64" <<STUB
#!/bin/bash
{ echo "ARGS: \$*"; echo "CWD: \$PWD"; env | grep -E '^(WINEPREFIX|HOME|WINEDLLOVERRIDES|WINEMSYNC|GAME_MODE|DYLD_FALLBACK_LIBRARY_PATH)='; } > "$L/wine.log"
exit "\${STUB_RC:-0}"
STUB
printf '#!/bin/bash\nexit 0\n' > "$L/wine/bin/wineserver"
chmod +x "$L/bin/bottler" "$L/wine/bin/wine64" "$L/wine/bin/wineserver"
printf '[thinker]\r\nwindow_width=1\r\nwindow_height=1\r\n' > "$L/game/thinker.ini"
cat > "$L/recipe/recipe.json" <<'JSON'
{ "schema": 1, "title": "Launch Test", "bundleId": "com.example.launch", "engine": "crossover-23",
  "detect": { "required": ["Game.exe"], "fingerprint": "Game.exe" },
  "launch": {
    "variants": [ { "label": "Plain", "exe": "thinker.exe", "args": [] },
                  { "label": "With args", "exe": "bin/thinker.exe", "args": ["-smac", "two words", "-w", "{w}", "-h", "{h}"] } ],
    "window": { "mode": "pillarbox:4:3", "align": 8, "backdrop": true, "menubar": "hide" },
    "ini": [ { "file": "thinker.ini", "section": "thinker", "set": { "window_width": "{w}", "window_height": "{h}" } } ],
    "env": { "GAME_MODE": "it's quoted" },
    "dllOverrides": { "ddraw": "n,b", "dinput": "b" } } }
JSON
export BOTTLER_TEST_SCREENS="0,0,1728,1117;0,0,1728,1084;32;0,0,1728,1117"
rm -f "$L/calls"; bash "$L/bin/launch.sh" "$L" 1 main; rc=$?
expect "launch exits with the game's code" "0" "$rc"
expect "wine runs bottler-place with the rect and the variant's args" \
    "ARGS: $L/bin/bottler-place.exe 144 35 1440 1080 -- C:\\Game\\bin\\thinker.exe -smac two words -w 1440 -h 1080" \
    "$(grep '^ARGS:' "$L/wine.log")"
expect "wine runs in the game's physical folder (C:\\Game, not a Z: path)" "CWD: $L/prefix/drive_c/Game" "$(grep '^CWD:' "$L/wine.log")"
expect "per-launch INI values written" "$(printf '[thinker]\r\nwindow_width=1440\r\nwindow_height=1080\r\n')" "$(cat "$L/game/thinker.ini")"
expect "WINEPREFIX is the bundle's" "WINEPREFIX=$L/prefix" "$(grep '^WINEPREFIX=' "$L/wine.log")"
expect "HOME is inside the bundle" "HOME=$L/home" "$(grep '^HOME=' "$L/wine.log")"
expect "DLL overrides from the recipe" "WINEDLLOVERRIDES=ddraw=n,b;dinput=b" "$(grep '^WINEDLLOVERRIDES=' "$L/wine.log")"
expect "recipe env exported, quotes intact" "GAME_MODE=it's quoted" "$(grep '^GAME_MODE=' "$L/wine.log")"
expect "menu bar: restored, hidden, frame started, restored at exit" \
    "$(printf 'menubar restore %s\nmenubar hide %s\nframe main --wine %s\nmenubar restore %s' "$L/logs/menubar-restore" "$L/logs/menubar-restore" "$L" "$L/logs/menubar-restore")" \
    "$(cat "$L/calls")"
rm -f "$L/calls"; STUB_RC=5 bash "$L/bin/launch.sh" "$L" 0 main; rc=$?
expect "a failing game's exit code is passed on" "5" "$rc"
expect "menu bar restored even when the game fails" "menubar restore $L/logs/menubar-restore" "$(tail -1 "$L/calls")"
expect "variant without args" "ARGS: $L/bin/bottler-place.exe 144 35 1440 1080 -- C:\\Game\\thinker.exe" "$(grep '^ARGS:' "$L/wine.log")"
rm -f "$L/wine.log"; bash "$L/bin/launch.sh" "$L" 7 main 2>/dev/null; rc=$?
if [ $rc -eq 2 ] && [ ! -e "$L/wine.log" ]; then ok; else bad "unknown variant: exit 2, wine not started (got $rc)"; fi
unset BOTTLER_TEST_SCREENS

# --- projects: make project, and two projects built at the same time (no engine)
export BOTTLER_RECIPES="$PWD/$T/recipes" BOTTLER_PROJECTS="$PWD/$T/projects"
mkdir -p "$BOTTLER_RECIPES"; cp -R tests/fixtures/recipe-min "$BOTTLER_RECIPES/min"
GA="$T/game-a"; GB="$T/game-b"; mkdir -p "$GA/saves" "$GB"
pe "$GA/Game.exe" --imports KERNEL32.dll --icons 16,32,48; cp "$GA/Game.exe" "$GB/Game.exe"
if core/project.sh one min "$GA" >/dev/null && core/project.sh two min "$GB" >/dev/null; then ok; else bad "make project creates two projects"; fi
expect "project.json records recipe and game" "min $PWD/$GA" \
    "$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['recipe'], d['game'])" "$BOTTLER_PROJECTS/one/project.json")"
core/project.sh one min "$GA" >/dev/null 2>&1; rc=$?; expect "an existing project is not overwritten" "2" "$rc"
core/project.sh "Bad Name" min "$GA" >/dev/null 2>&1; rc=$?; expect "a bad project name is refused" "2" "$rc"
core/build-app.sh "$BOTTLER_PROJECTS/one" --no-engine > "$T/build-one.log" 2>&1 & P1=$!
core/build-app.sh "$BOTTLER_PROJECTS/two" --no-engine > "$T/build-two.log" 2>&1 & P2=$!
wait $P1; r1=$?; wait $P2; r2=$?
expect "two projects build at the same time" "0 0" "$r1 $r2"
for n in one two; do
    B="$BOTTLER_PROJECTS/$n/Bottler Test.app"
    expect "$n: bundle id from the recipe" "com.matasarei.bottler.test" "$(defaults read "$B/Contents/Info" CFBundleIdentifier 2>/dev/null)"
    expect "$n: the icon made from the game is the bundle icon" "AppIcon" "$(defaults read "$B/Contents/Info" CFBundleIconFile 2>/dev/null)"
    expect "$n: a background app until its window shows (no Dock tile when it goes straight to the game)" "1" "$(defaults read "$B/Contents/Info" LSUIElement 2>/dev/null)"
    if [ -s "$B/Contents/Resources/AppIcon.icns" ]; then ok; else bad "$n: AppIcon.icns in Resources"; fi
    if [ -f "$B/Contents/Resources/prefix/drive_c/Game/Game.exe" ] && [ -e "$B/Contents/Resources/game/Game.exe" ]; then ok; else bad "$n: game installed at build time"; fi
    if file "$B/Contents/MacOS/launcher" 2>/dev/null | grep -q "Mach-O 64-bit executable"; then ok; else bad "$n: launcher built"; fi
    for f in bottler bottler-place.exe install.sh launch.sh wine-env.sh; do
        if [ -s "$B/Contents/Resources/bin/$f" ]; then ok; else bad "$n: bundle has bin/$f"; fi
    done
    if codesign -v "$B" 2>/dev/null; then ok; else bad "$n: bundle seal verifies"; fi
    if [ ! -e "$BOTTLER_PROJECTS/$n/.build/Bottler Test.app" ]; then ok; else bad "$n: no half-built app left in .build"; fi
done
echo "played" > "$BOTTLER_PROJECTS/one/Bottler Test.app/Contents/Resources/game/saves/slot.sav"
if core/build-app.sh "$BOTTLER_PROJECTS/one" --no-engine > "$T/rebuild.log" 2>&1; then ok; else bad "rebuild exits 0"; fi
expect "a rebuild keeps the app's saves" "played" "$(cat "$BOTTLER_PROJECTS/one/Bottler Test.app/Contents/Resources/game/saves/slot.sav" 2>/dev/null)"

# a local recipe: a folder given instead of a name is copied into the project (never committed)
LOCAL="$T/my-recipe"; cp -R tests/fixtures/recipe-min "$LOCAL"
python3 - "$LOCAL/recipe.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["title"] = "Local Test"; d["install"]["registry"] = ["settings.reg"]
json.dump(d, open(sys.argv[1], "w"), indent=2)
PY
GL="$T/game-local"; mkdir -p "$GL"; cp "$GA/Game.exe" "$GL/"; printf 'Windows Registry Editor Version 5.00\r\n' > "$GL/settings.reg"
if core/project.sh mine "$LOCAL" "$GL" >/dev/null; then ok; else bad "make project takes a recipe folder"; fi
expect "a local recipe is recorded as local" "local" "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['recipe'])" "$BOTTLER_PROJECTS/mine/project.json" 2>/dev/null)"
if [ -f "$BOTTLER_PROJECTS/mine/recipe/recipe.json" ]; then ok; else bad "the local recipe is copied into the project"; fi
if core/build-app.sh "$BOTTLER_PROJECTS/mine" --no-engine > "$T/build-local.log" 2>&1 && [ -d "$BOTTLER_PROJECTS/mine/Local Test.app" ]; then ok; else bad "a project builds from its local recipe"; fi
expect "recipe-field lists the registry files" "settings.reg" "$("$T/bottler" recipe-field "$BOTTLER_PROJECTS/mine/recipe/recipe.json" install.registry 2>&1)"
rm "$GL/settings.reg"; mkdir -p "$T/gl-icons"
"$T/bottler" install "$BOTTLER_PROJECTS/mine/recipe" "$GL" "$T/gl-game" "$T/gl-icons" >/dev/null 2>&1; rc=$?
expect "a registry file missing from the game is refused" "3" "$rc"
unset BOTTLER_RECIPES BOTTLER_PROJECTS

# --- dock-name on a fake CrossOver engine
E="$T/engine/wine"; mkdir -p "$E/bin" "$E/lib/wine/x86_64-unix"
PL='<?xml version="1.0"?><plist version="1.0"><dict>
    <key>CFBundleName</key>
    <string>WineskinCX23.7.1-4</string>
    <key>LSUIElement</key>
    <string>1</string>
</dict>
</plist>'
printf 'MACHO-HEAD %s TAIL' "$PL" > "$E/bin/wine64-preloader"
printf 'MACHO-HEAD %s TAIL' "$PL" > "$E/bin/wine64"
printf 'abc\0wine64-preloader\0def' > "$E/lib/wine/x86_64-unix/ntdll.so"
SIZE_BEFORE=$(stat -f %z "$E/bin/wine64-preloader")
if "$T/bottler" dock-name "$E" "Alpha Centauri" >/dev/null 2>&1; then ok; else bad "dock-name exits 0"; fi
if [ -f "$E/bin/Alpha Centauri" ] && [ "$(readlink "$E/bin/wine64-preloader")" = "Alpha Centauri" ]; then ok; else bad "loader renamed, old name kept as a link"; fi
expect "ntdll names the new loader (NUL-padded, same size)" "abc|Alpha Centauri|||def" "$(tr '\0' '|' < "$E/lib/wine/x86_64-unix/ntdll.so")"
if grep -q "<string>Alpha Centauri</string>" "$E/bin/Alpha Centauri" && grep -q "<string>Alpha Centauri</string>" "$E/bin/wine64"; then ok; else bad "CFBundleName set in both loaders"; fi
expect "loader size unchanged" "$SIZE_BEFORE" "$(stat -f %z "$E/bin/Alpha Centauri")"
expect "second run changes nothing" "" "$("$T/bottler" dock-name "$E" "Alpha Centauri" 2>&1)"
"$T/bottler" dock-name "$E" "A name longer than sixteen" >/dev/null 2>&1; rc=$?
expect "a name over 16 bytes is refused" "3" "$rc"

# --- hints: a fake Lutris API in local files
H="$PWD/$T/lutris"; mkdir -p "$H/installers"
cat > "$H/games" <<'JSON'
{"results": [{"name": "Anachronox", "slug": "anachronox", "year": 2001},
             {"name": "Nox", "slug": "nox", "year": 2000},
             {"name": "Nox Archaist", "slug": "nox-archaist", "year": null}]}
JSON
cat > "$H/installers/nox" <<'JSON'
{"results": [{"version": "GOG", "runner": "wine",
  "script": {"game": {"exe": "drive_c/GOG Games/Nox/NOX.EXE", "args": "-window"},
             "wine": {"overrides": {"ddraw.dll": "n"}},
             "installer": [{"task": {"name": "winetricks", "app": "d3dx9"}}, {"move": {}}]}}]}
JSON
echo '{"results": []}' > "$H/installers/nox-archaist"
OUT=$(BOTTLER_LUTRIS_API="file://$H" "$T/bottler" hints nox)
expect "hints: the exact name comes first" "Nox (2000, lutris.net/games/nox)" "$(echo "$OUT" | head -1)"
if echo "$OUT" | grep -q 'exe: drive_c/GOG Games/Nox/NOX.EXE' && echo "$OUT" | grep -q 'args: -window'; then ok; else bad "hints show exe and args"; fi
if echo "$OUT" | grep -q '"ddraw.dll":"n"' && echo "$OUT" | grep -q 'installer: winetricks d3dx9, move'; then ok; else bad "hints show overrides and winetricks"; fi
expect "hints: order is exact, whole words, then substrings" "Nox|Nox Archaist|Anachronox" \
    "$(echo "$OUT" | grep -E '^[A-Z]' | sed 's/ (.*//' | paste -sd'|' -)"
expect "hints: a null year prints as ?" "Nox Archaist (?, lutris.net/games/nox-archaist)" "$(echo "$OUT" | grep '^Nox Archaist')"
OUT=$(BOTTLER_LUTRIS_API="file://$H/missing" "$T/bottler" hints nox); rc=$?
if [ $rc -eq 0 ] && echo "$OUT" | grep -q "^warning: Lutris is not reachable"; then ok; else bad "hints: unreachable API is a warning, exit 0"; fi

# --- observing an app: cpu, windows, log, shot (fake app with a busy process)
F="$PWD/$T/Fake.app"; mkdir -p "$F/Contents/MacOS" "$F/Contents/Resources/logs"
# a copied system binary is killed by code signing; build a busy loop instead
echo 'int main(void) { volatile unsigned long n = 0; for (;;) n++; }' | cc -x c -O0 -o "$F/Contents/MacOS/busy" -
"$F/Contents/MacOS/busy" & BUSY=$!
CPU=$("$T/bottler" cpu "$F" 1 | python3 -c "import json,sys; d=json.load(sys.stdin); print(int(d[0]['cpu']) if d and d[0]['name']=='busy' else -1)")
kill $BUSY 2>/dev/null; wait $BUSY 2>/dev/null
if [ "$CPU" -ge 70 ] && [ "$CPU" -le 130 ]; then ok; else bad "cpu reports a busy process near one core, got $CPU"; fi
expect "cpu with nothing running is an empty list" "[" "$("$T/bottler" cpu "$F" 0.2 | head -c 1)"
expect "a windowless app has no windows" "0" "$("$T/bottler" windows "$F" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")"
"$T/bottler" log "$F" >/dev/null 2>&1; rc=$?; expect "log without a launch log exits 2" "2" "$rc"
echo "line one" > "$F/Contents/Resources/logs/last-launch.log"
expect "log prints the launch log" "line one" "$("$T/bottler" log "$F")"
"$T/bottler" shot "$T/none.png" --app "$F" >/dev/null 2>&1; rc=$?; expect "shot of an app without windows exits 2" "2" "$rc"
"$T/bottler" windows "$T/not-an-app" >/dev/null 2>&1; rc=$?; expect "windows on a non-app exits 2" "2" "$rc"

# ini-set on a new file and a missing section
"$T/bottler" ini-set "$T/new.ini" Main a=1 b=2
expect "ini-set creates file and section" "$(printf '[Main]\na=1\nb=2\n')" "$(cat "$T/new.ini")"

echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
