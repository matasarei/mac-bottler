---
name: cook
description: Turn a Windows game folder the user owns into a working mac-bottler app, end to end - scan the game, pick or draft its recipe, build the app, launch it, observe it, fix and repeat until it plays well. Use when the user asks to bottle, port, wrap or "cook" a game, or points at a game folder to make an app from.
---

# /cook <game folder> [recipe name]

Takes a game folder the user owns and ends with `projects/<name>/<Title>.app`
that starts the game and plays well, plus a committed recipe with notes. Read
`CLAUDE.md` and `docs/INTERNALS.md` before starting: most problems are already
in there.

## Rules that never bend

- **The game folder is read only.** Never write, rename or delete anything in it.
- **Nothing from the game is ever committed**: no files, no icons, no export
  lists. `make test` refuses them; don't work around it.
- **Never rebuild an app while its game is running**: the rebuild moves the game
  folder (with the player's saves) into the new app. Check first:
  `pgrep -f "projects/<name>/.*Resources/wine"`.
- **One change at a time**, rebuilt and observed before the next. Every attempt
  goes into `recipes/<recipe>/notes.md` with its result, including failures.
- Work on a branch (`recipe/<name>`); open a PR at the end. Never merge, never
  push `main`.

## 1. Scan

```sh
make check
swiftc -O -o build/bottler tools/bottler.swift
build/bottler scan "<game folder>" > /tmp/scan.json
```

Read `suggestion` (main exe, candidates, graphics API, notes) and `found`
(wrapper DLLs, copy-protection and store leftovers). The suggestion is a
starting point: a game, its editor and its autorun menu often tie. When
unsure which exe is the game, ask the user in one question with the candidates.

Optionally, `build/bottler hints "<game name>"` (once it exists) for what Lutris
knows; hints are never applied blindly.

## 2. Recipe

Look for an existing recipe first: the fingerprint exe's md5 in any
`recipes/*/recipe.json` `detect.builds`, or the same title. Reuse it if found.

Otherwise draft `recipes/<name>/recipe.json` (schema: `docs/RECIPES.md`):

- `engine`: `crossover-23` (the default; `wowsilicon-r17` only if a test shows it
  is better for this game).
- `detect`: the main exe as `fingerprint` and in `required`; the scanned md5 as
  `verified` only after the game has been played successfully; `unknown: warn`.
- `install.exclude`: the protection and store leftovers the scan found.
- `install.rename`: a bundled wrapper DLL only if the game should *not* use it
  (a local `ddraw.dll` loads even in GDI mode and costs CPU).
- `install.appIcon` / `exeIcon`: the exe with the best icon / the exe the Dock
  shows (the one that owns the game window).
- `launch.variants`: the real game exe (not a launcher stub) and its arguments.
- `launch.window`: old 2D games (ddraw, gdi): `pillarbox:4:3`, `align: 8`,
  `backdrop: true`, `menubar: hide`. 3D games or games with their own scaler:
  `native`.

Then `build/bottler recipe-check recipes/<name>/recipe.json` and start
`notes.md` with the scan's facts (md5, APIs, leftovers).

## 3. Build

```sh
make project NAME=<name> RECIPE=<name> GAME="<game folder>"   # once
make app PROJECT=<name>                                       # ~1 min first time, ~15 s after
```

## 4. Launch and observe

```sh
APP="$PWD/projects/<name>/<Title>.app"; R="$APP/Contents/Resources"
( bash "$R/bin/launch.sh" "$R" 0 main & ); sleep 30
build/bottler windows "$APP"          # the game window: where, how big, on screen?
build/bottler shot /tmp/game.png --app "$APP"   # then look at it (Read the png)
build/bottler cpu "$APP" 4            # idle CPU of the game and wineserver
build/bottler log "$APP"              # errors; relaunch with WINEDEBUG=err,+loaddll for detail
build/bottler click <x> <y>           # drive a menu when needed (screen points)
```

A game started from a terminal is not the active app, and some games draw less
or pause until focused: ask the user to click it, or open the app and click Play
(`open "$APP"`, find the button with `windows`, `click`).

Check against this list; each failure goes to the **diagnose** skill:

- the window is where `bottler geometry` says, the whole picture is drawn, text is visible;
- idle CPU at a menu is under ~15% (game + wineserver);
- the log has no `failed to start`, no missing DLLs;
- the Dock shows the game's icon and title.

## 5. Ask the user, once per round

What the tools cannot observe: **sound** (plays, no crackle), **feel**
(scrolling, clicks landing, keyboard), **playing** (load a save, a few turns or
minutes), **quit** (the launcher and the menu bar come back). Batch them into
one question with options; never ask about something a tool can check.

## 6. Fix, repeat, finish

- A recipe-level fix: change the recipe, rebuild, observe again.
- A fix that belongs in `core/`, `tools/` or `win/` (any game could hit it): use
  the **improve-bottler** skill; the recipe waits for that PR.
- Done when every check passes and the user confirmed the rest. Then mark the
  build `verified` in `detect.builds`, finish `notes.md`, commit the recipe on
  its branch, push and `gh pr create --base main`. Report what was verified and
  what was not.
