---
name: diagnose
description: Find the cause of a problem in a mac-bottler app (black or broken picture, missing text, wrong window placement, no sound, crackle, high CPU, crashes, programs that fail to start, wrong Dock name or icon, missing saves) from its symptom, using the causes already found and the bottler observe tools. Use when a bottled game misbehaves, or when the cook skill's checks fail.
---

# /diagnose <symptom>

Symptom first, then the known causes in order of likelihood, each with the test
that confirms or rules it out. Confirm before changing anything, change one thing
at a time, and write the result into the recipe's `notes.md`. The background for
each cause is in `docs/INTERNALS.md`; add a new entry there when you find a new
one.

Tools: `build/bottler windows|shot|cpu|log <app>`, a launch with
`WINEDEBUG=err,+loaddll` (or `+process`, `warn+dsound`) set before
`launch.sh`, and `build/bottler scan` on the installed game folder
(`<app>/Contents/Resources/game`).

## Nothing starts, or "failed to start"

1. **A `bin/wine` inside a CrossOver engine**: it is taken for a 32-bit loader;
   `prefix/drive_c/windows/syswow64` is empty. Test: count its files (should be
   ~780). Scripts must call `$WINE` from `core/wine-env.sh`.
2. **A relative `WINEPREFIX`**: wine refuses it. Test: the log's first lines.
3. **Missing libraries**: `DYLD_FALLBACK_LIBRARY_PATH` must include
   `wine/lib/external`. Test: "cannot find the FreeType font library".
4. **The mod/launcher refuses the exe version** (e.g. Thinker needs v2.0): a
   dialog appears; `bottler shot` shows it.

## Picture: black, grey, stretched, partly drawn, text missing

1. **A very wide native surface** (old 2D games at ultrawide width): the map
   stays black after scrolling. Test: switch the recipe to `pillarbox:4:3`.
2. **A DirectDraw wrapper's renderer** (cnc-ddraw): only its GDI renderer drew
   here; OpenGL grey, Direct3D 9 black. Text vanished when scaled until `minfps`
   forced redraws.
3. **The game only redraws when focused**: click it (`bottler click`) and shoot again.
4. **A display-mode switch**: the whole display changes resolution (seen when a
   mod's "custom resolution full-screen" was used). Use a windowed/borderless mode.

## Window in the wrong place or size

1. **The game positions itself at 0,0** (normal): `bottler-place.exe` must
   find it. Test: `bottler windows`; if several large windows exist, set
   `launch.window.title`.
2. **A size the game refuses**: Thinker needs both sides divisible by 8 and no
   larger than the *primary* display, and picks another mode otherwise. Test:
   compare `bottler windows` with `bottler geometry <display> <mode> <align>`.
3. **A title bar was forced**: clips the bottom and breaks minimise; don't.

## Mouse: edge scrolling dead on one side, clicks offset

1. **The game reads `GetCursorPos` as if its window were at 0,0**: needs the
   cursor proxy (`install.proxy` with a DLL the game loads from its own folder).
   Test: scrolling works on the top/left edges only.

## No sound

1. **Sound files missing from the installed game**: compare the installed
   `fx/` (or the game's sound folder) with the source. The installer checks every
   file arrived; an old install may predate that.
2. **The game runs from a `Z:\...\Name.app\...` path**: launch must start from
   `prefix/drive_c/Game`. Test: `WINEDEBUG=+process` shows the exe's path.
3. **DirectSound/CoreAudio**: `WINEDEBUG=warn+dsound,+loaddll`; `DSOUND.dll`,
   `winecoreaudio.drv` loaded and "buffer underrun" warnings mean audio is
   flowing, so look for missing files instead.

## Sound crackles

1. **The output device runs at 44.1 kHz**: 48 kHz was clean. Test: Audio MIDI
   Setup, or `system_profiler SPAudioDataType`.
2. Not helped (tried): DirectSound `HelBuflen`, turning off the game's 3D sound
   and EAX, the Wine 11 runtime.

## High CPU

1. **The game spins its main loop** (common before 2005): a mod with an idle fix
   helped (Thinker), a PeekMessage wait hook did not under Wine. Test:
   `bottler cpu` at an idle menu.
2. **A local wrapper DLL loaded but unused** costs CPU: set it aside.
3. **wineserver busy**: `WINEMSYNC=1` is on in `core/wine-env.sh`; check it is set.

## Crashes after changing the game's exe

1. **The PE file was rebuilt** (rcedit and similar): games with self-modifying
   code break. Only in-place `.rsrc` changes (`bottler exe-icon`) are safe.

## Dock or menu bar name/icon wrong

1. **Name "wine64-preloader"**: `bottler dock-name` did not run (CrossOver
   engines only; titles over 16 bytes are refused with a warning).
2. **The Dock icon comes from the running exe**, not the bundle: set
   `install.exeIcon` to the exe that owns the game window.
3. **A second, identical tile**: the launcher must leave the Dock while playing.

## Saves missing, or settings point elsewhere

1. **Absolute paths remembered in the game's settings** (e.g. `Latest Save`
   pointing at an old install): clear them with an `install.ini` edit.
2. **The game runs from another folder** (the `Z:` path above).
