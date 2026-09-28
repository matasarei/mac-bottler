# Environment for every wine call against an app bundle. Source it with the
# bundle's Resources dir in $RES. One place, so the prefix build and the game
# launch can never drift apart.
export WINEPREFIX="$RES/prefix"
# The engine's loader: bin/wine (wowsilicon) or bin/wine64 (CrossOver). Never add a
# bin/wine to a CrossOver engine: it takes that for a 32-bit loader and 32-bit
# programs stop starting (docs/INTERNALS.md).
WINE="$RES/wine/bin/wine"
[ -x "$WINE" ] || WINE="$RES/wine/bin/wine64"
export WINE
# HOME inside the bundle: this wine creates $HOME/Wine otherwise (wow-launcher issue #12)
export HOME="$RES/home"
# The runtime bundles FreeType, GnuTLS and friends in lib/external but loads
# them by name; without this, GDI games lose their TrueType text.
export DYLD_FALLBACK_LIBRARY_PATH="$RES/wine/lib/external:/usr/lib"
export WINEDEBUG="${WINEDEBUG:--all}"
# Mach-based sync primitives instead of wineserver round trips (both engines support it).
export WINEMSYNC=1
