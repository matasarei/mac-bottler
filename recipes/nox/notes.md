# Nox: notes

## The game folder (GOG release, as found in an older Wineskin wrapper)

- `bottler scan`: `Game.exe` is the game (i386, GUI; DDRAW + GDI, DSOUND + WINMM +
  Miles `mss32.dll`, DINPUT, WSOCK32). md5 `ed88f606b4d1245f95911496fa6c06b6`.
- `NOX.EXE` is GOG's stub (GDI only, 76 KB). It is not used.
- `goggame.dll` (Galaxy) is not imported by `Game.exe`, so it is excluded, as are
  the uninstaller and the cnc-ddraw config tool.
- The folder ships **cnc-ddraw** (`ddraw.dll`, `ddraw.ini`, `Shaders/`). It is
  added after install (newer timestamps than the GOG files) and is required by
  this recipe. It does the scaling and pillarboxing itself.
- `game.sdb` / `game.cmd`: GOG's Windows compatibility shim database; meaningless
  under Wine.
- The old wrapper's `Save` is an absolute symlink out of the prefix; install skips
  symlinks, and Nox creates `Save/` itself.
- `bottler hints nox`: Lutris has a GOG wine installer (runs `NOX.EXE`,
  `reset_desktop`) and an OpenNox HD Linux port. Neither was needed.

## What works

- **cnc-ddraw borderless** (`fullscreen=true`, `windowed=true`, `border=false`,
  `maintas=true`), with the OpenGL renderer and the Catmull-Rom shader it ships
  with. `ddraw=n,b` loads it. The window covers the whole display; cnc-ddraw draws
  the 4:3 picture centred with black borders. So there is no backdrop, no cursor
  proxy and no pillarbox mode in the recipe (`window.mode: native`).
  - Note: with SMAC only cnc-ddraw's GDI renderer drew; here OpenGL draws fine.
- `savesettings=0`, `resizable=false`: cnc-ddraw must not remember a window from
  another display.
- The Dock name "Nox" (dock-name) works.
- The icon: `Game.exe`'s 32 px mask on a stone plate. It is 44% transparent, so it
  was plated. It needed the icon fixes in the tool: 24-bit masks, a 2-slot exe
  with 2960 bytes of room, and indexed PNGs.
- The developer played a first run, character creation included: "it worked well".

## CPU

- At the character screen with cnc-ddraw `maxfps=-1` (it follows the display's
  refresh, 120 Hz here): 23% (game) + 1.4% (wineserver). That is over the ~15%
  target.
- The fix: `maxfps=60`. It is not measured yet in focus: unfocused, the game
  pauses (~1%).
- The first seconds (intro video) run at ~100%; this is normal.

## Not verified yet

- Idle CPU with `maxfps=60` in focus.
- Sound; the Dock icon while running; quitting back to the launcher.
- A second display.
