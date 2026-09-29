# Internals and traps

How things work, and what was already tried. Each entry names the game it was
found on; the lesson is written so it applies to other games too.

## Engines

- **Every wine call needs the same environment** (`core/wine-env.sh`): an
  absolute `WINEPREFIX` (wine refuses a relative one), `HOME` inside the bundle,
  and `DYLD_FALLBACK_LIBRARY_PATH` including the runtime's `lib/external`. The
  WoWSilicon runtime bundles FreeType there but loads it by name; without the
  path, wine reports "cannot find the FreeType font library" and GDI games lose
  their TrueType text (WoW draws its own fonts, so wow-launcher never noticed).
- **CrossOver 23 runs 32-bit programs inside `wine64` (WoW64) only when there is
  no `bin/wine`.** A `bin/wine` added for convenience (symlink or script) is
  taken for a 32-bit loader: wineboot leaves `syswow64` empty and every 32-bit
  program fails with "failed to start". Called as `wine` through a symlink,
  `wine64` also segfaults. Scripts use `$WINE` from `core/wine-env.sh`.
- **WoWSilicon Wine 11 (r17) vs CrossOver 23, Alpha Centauri + Thinker, main
  menu, 2026-09-28:** starts, sizes and centres fine, but the game used ~104% CPU
  (focused; ~57% unfocused) plus ~48% for wineserver, against ~10% + 2% on
  CrossOver 23. `WINEMSYNC=1` (supported by the runtime, off by default) made no
  difference. Sound crackled on both the MacBook speakers (already at 48 kHz) and
  AirPods. Unproven guess: Thinker's idle fix does not take effect on this Wine,
  and the spinning loop also starves the audio mixer.

## Display

- **winemac.drv has no virtual desktop.** The Wine "Explorer\Desktops" setting is
  ignored on macOS (checked in the Wine master source: the Mac driver's desktop
  window is always the real screen; only winex11 has a `desktop.c`). A game's
  window is a real macOS window, so "4:3 with black borders" needs our own
  backdrop behind it (`bottler frame`). *Alpha Centauri.*
- **The macOS menu bar hides only for windows that cover the whole screen.** A
  pillarboxed window never does, so the launcher turns on the global "automatically
  hide the menu bar" preference for the session. Before the game starts it records
  the menu bar and Dock settings in a snapshot outside every app
  (`~/Library/Application Support/mac-bottler`) and puts both back when the game
  ends; a snapshot a crashed run left is kept, since it holds the real settings. A
  marker inside the app was lost when a killed run's app was rebuilt, and the menu
  bar stayed hidden. *Alpha Centauri, Counter-Strike.*
- **Games assume their window starts at the screen's top-left.** Once the window
  is centred, `GetCursorPos` (screen coordinates) no longer matches what the game
  expects; edge scrolling breaks on the side away from the origin. Fix: a proxy DLL
  that makes GetCursorPos, SetCursorPos, ScreenToClient and ClientToScreen
  window-relative, clamped to the window, so black borders act as edges.
  *Alpha Centauri (via its own soundx.dll).*
- **Moving another app's window from macOS needs Accessibility permission; from
  inside Wine it does not.** A small Windows helper in the same Wine session can
  `SetWindowPos` the game window freely. *Alpha Centauri.*
- **Very wide native full-screen can break a 2D game's redraw.** Alpha Centauri
  (with Thinker) at 3440x1440 left most of the map black after scrolling; the same
  game at 1920x1440 drew correctly. Prefer a pillarboxed 4:3 surface over native
  ultrawide for old 2D games.
- **Retina:** keep Wine's `RetinaMode=n` for old games: they render at point size
  and macOS scales 2x cleanly; native Retina makes 1999-era UI unreadably small.
- **cnc-ddraw** (DirectDraw wrapper) under this Wine: only its GDI renderer drew
  anything for Alpha Centauri (OpenGL grey, Direct3D 9 black), and its default
  cursor lock needs `devmode=true`. Scaled output lost menu text until
  `minfps` forced redraws. GOG ships cnc-ddraw with some games (Nox): a local
  `ddraw.dll` is loaded even when the game does not use DirectDraw, and its hooks
  cost CPU, so set it aside when the game runs in GDI mode. With Nox the same
  wrapper drew fine through OpenGL, borderless with the aspect kept; its default
  frame rate follows the display (120 Hz), so cap it (`maxfps=60`).
- **Moving an OpenGL game's window turns its picture black.** Counter-Strike
  (Half-Life 1.1, OpenGL) drew in a window it placed itself and went black as
  soon as `bottler-place` moved it, every time. Window mode `game` never moves
  the window.
- **A full-screen display-mode switch from an old OpenGL game stayed black**
  (Counter-Strike at 1728x1080 from the command line). Switching to full screen
  from the game's own options, once it runs in a window, works.
- **A full-screen game started without the focus hides itself**, and some games
  draw nothing until focused: bring the game to the front before judging a black
  or missing window.
- **Games list the display in pixels** (3456x2160 on a 14" MacBook Pro) while
  Wine's `RetinaMode=n` makes a Windows pixel a macOS point: that size is twice the
  screen. Pick the point size (1728-class); old engines have no HUD scaling, so
  the pixel size would make text half as big.

## Launching

- **Old games parse their own command line.** `bottler-place` quoted every
  argument (`"-game" "cstrike"`), and Half-Life 1.1 then saw no options at all: it
  started Half-Life instead of Counter-Strike, full screen and black. Arguments
  are now quoted only when they must be (`win/cmdline.h`, the CommandLineToArgvW
  rules).
- **Settings in the registry beat the command line** in some games
  (Counter-Strike's "run in a window"): seed or change them in the registry, not
  only in `args`.

## Installing

- **The game must live physically inside the prefix** (`prefix/drive_c/Game`,
  Windows `C:\Game`). A symlink from `drive_c` to a folder elsewhere in the
  bundle makes Wine report the game's real location as
  `Z:\Users\...\Name.app\Contents\...`; launchers that start the game relative
  to their folder then pass that path on. Launch from the physical folder too.
- **`FileManager` enumerator trap:** `skipDescendants()` called on a *file*
  skips the most recently opened folder instead. The first installer lost all of
  Alpha Centauri's `fx/` (every sound: the game ran silent with DirectSound
  working) and `techs/`. The installer now only skips folders and checks that
  every source file arrived.
- **Games remember absolute paths in their settings** (Alpha Centauri's
  `Latest Save` pointed at the old install): clear them at install, or the load
  dialog opens a folder that does not exist.

## Executables and icons

- **The Dock icon of a running Wine game comes from the running .exe's icon
  resource**, not from the app bundle. An `exeIcon.icns` next to the loader or
  under `$CX_ROOT/Resources` had no effect.
- **Never rebuild a game's PE file to change its icon.** rcedit's full resource
  rebuild made Alpha Centauri's `terranx.exe` crash (it has self-modifying code
  sections). The safe method: overwrite the existing RT_ICON data block in place
  with PNG icons (256/48/32/16), re-point the RT_ICON entries and rewrite the group
  icon in its own slot, and refuse unless every changed byte stays inside `.rsrc`
  and the file size is unchanged.
- **When the icons do not fit in place and `.rsrc` is the file's last section**
  (unsigned, nothing after it: Nox's `Game.exe`, this Counter-Strike copy's `hl.exe`),
  the new icon data is appended at the end of `.rsrc` and only its size fields,
  `SizeOfImage` and the resource directory size change. Nothing before `.rsrc` moves.
  An exe with a section after it (SMAC's `terranx.exe`: `.reloc`) stays in place.
- **Some exes have very little room for icons.** Nox's `Game.exe` has two slots
  and 2960 bytes. The exe icons are therefore written as indexed PNGs whenever they
  have 256 colours or fewer (lossless; a plated 256 px pixel-art icon is ~2.6 KB),
  and `exe-icon` keeps as many sizes as fit, the largest first (the Dock shows it),
  then 32, 48 and 16 px. A refused patch removes its `.bkp`, so a later install
  tries again.
- **ImageIO ignores the AND mask of 24-bit BMP icons** (it applies it to 4- and
  8-bit ones): the transparent parts decode opaque. `largestIcon` clears the masked
  pixels itself.
- **Transparent margins are trimmed first**: the icon is cut to the square around
  what it draws. An icon already drawn as a rounded card for macOS (this
  Counter-Strike copy's `hl.exe`) then fills the body instead of going on a plate.
- **A figure on a transparent background goes on a plate.** When at least 30% of
  the (trimmed) icon is transparent (Nox's mask: 44%, SMAC's `terranx.exe`: 56%), filling the
  squircle would cut the figure and leave holes, so it is drawn whole on a flat
  stone-coloured plate at a whole-pixel scale. Pictures (SMAC's `terran.exe`: 0%; a
  round icon is ~21%) still fill the body.
- **The exe's icon is re-patched from the stock `.bkp` at every install**, and
  only rewritten when the bytes differ, so a changed icon (a project's `icon.*`)
  reaches the Dock too. Exes are recognised by their `MZ` header, not their name
  (`Game.exe.bkp`).
- **Large images are scaled down to the body**, not cropped: the fill rule was
  written for 32-48 px exe icons, scaled up by whole pixels.
- **The app icon is made from the stock exe** (`<exe>.bkp`) when `appIcon` and
  `exeIcon` name the same exe: a rebuild keeps the installed game, whose exe
  already carries the made icon.
- **The Dock name** is the loader's file name as exec'd. On the CrossOver 23 engine
  we renamed the loader and patched the one path string in `ntdll.so`; on the
  WoWSilicon Wine 11 runtime that string cannot be patched, and wow-launcher's
  `ROSETTA_X87_PATH` shim + symlink is the working method.
- **Old executables often carry copy-protection leftovers** (SafeDisc:
  `secdrv.sys`, `drvmgt.dll`) even in digital releases; they are not needed and
  are excluded at install.

## Audio

- **44.1 kHz output devices can crackle** with old DirectSound games under Wine;
  the MacBook speakers at 48 kHz were clean. Doubling DirectSound's `HelBuflen`
  and turning off the game's 3D sound/EAX did not help on their own.

## CPU

- **Many old games spin their main loop at 100%.** Alpha Centauri used ~170% CPU
  idle; Thinker's built-in idle fix brought it to ~10%. The standalone
  smac-cpu-fix (a PeekMessageA wait hook) had no effect under Wine, and
  cnc-ddraw's `maxgameticks`/`limiter_type` did not either.

## Games that did not bottle (yet)

- **Counter-Strike 1.6, Steam.** Steam's Mac build is 32-bit and cannot run on
  macOS 10.15 or later; the 2023 25th anniversary update added no 64-bit Mac
  build. The Windows build needs the Steam client running (inside Wine). Xash3D
  FWGS builds natively for Apple Silicon in seconds and runs Steam's files, but
  its client (cs16-client) needs current Steam data
  (`sprites/scope_arc_{nw,ne,sw}.tga`); with 2002-era data, creating a game
  crashed, and it has its own menu instead of Steam's VGUI2 one. A copy that
  runs without Steam is a modified copy: its recipe belongs in `recipes.local/`.
