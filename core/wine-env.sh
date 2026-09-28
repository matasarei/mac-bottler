# Environment for every wine call against an app bundle. Source it with the
# bundle's Resources dir in $RES. One place, so the prefix build and the game
# launch can never drift apart.
export WINEPREFIX="$RES/prefix"
# HOME inside the bundle: this wine creates $HOME/Wine otherwise (wow-launcher issue #12)
export HOME="$RES/home"
# The runtime bundles FreeType, GnuTLS and friends in lib/external but loads
# them by name; without this, GDI games lose their TrueType text.
export DYLD_FALLBACK_LIBRARY_PATH="$RES/wine/lib/external:/usr/lib"
export WINEDEBUG="${WINEDEBUG:--all}"
