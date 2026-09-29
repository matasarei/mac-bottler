---
name: cook
description: Turn a Windows game folder the user owns into a working mac-bottler app, end to end - analyse the game files, find or write its recipe, build the app, launch it, observe it, fix and repeat until it plays well. Use when the user asks to bottle, port, wrap or "cook" a game, or points at a game folder (with or without a recipe) to make an app from.
---

# /cook <game folder> [recipe name]

Takes a game folder the user owns and ends with `projects/<name>/<Title>.app`
that starts the game and plays well, plus a recipe with notes. A recipe is only
known to be right once the game has been built and played: drafting and verifying
are one loop, never separate jobs. Read `AGENTS.md` and `docs/INTERNALS.md` before
starting: most problems are already in there.

## Rules that never bend

- **The game folder is read only.** Never write, rename or delete anything in it.
- **Nothing from the game is ever committed**: no files, no icons, no export
  lists, no keys. `make test` refuses them; don't work around it.
- **Never rebuild an app while its game is running**: the rebuild copies the game
  folder (with the player's saves) into the new app and then replaces the old one;
  whatever the game saves after the copy is lost. Check first:
  `pgrep -f "<Title>.app/Contents/Resources/wine"` (matches the app wherever it is, `/Applications` included).
- **Say before you take over the screen.** Every test launch opens the game on
  the player's display: say so and for how long, close it after, and leave a game
  the player is using alone.
- **One change at a time**, rebuilt and observed before the next. Every attempt
  goes into the recipe's `notes.md` with its result, including failures.
- Work on a branch (`recipe/<name>`); open a PR at the end. Never merge, never
  push `main`.

## 1. Analyse the game files

```sh
make check
make bottler                                 # build/bottler
build/bottler scan "<game folder>" > /tmp/scan.json
build/bottler hints "<game name>"            # what Lutris' installer scripts know
```

From the scan, write down: the main exe and the other candidates, its
architecture (i386 / x86_64), its graphics, audio and input APIs, the wrapper DLLs
bundled with it (`found` kind `wrapper`), store and copy-protection leftovers
(`store`, `protection`), launcher stubs, packed DLLs (`imports: unreadable`), and
any `.reg`, `.ini` or `.cfg` files that hold settings. From the hints: the exe
Lutris runs, its arguments, DLL overrides and winetricks. Hints are leads, never
applied blindly.

When the scan cannot tell which exe is the game (a game, its editor and its
autorun menu often tie), ask the user once, with the candidates.

**Which copy is it?** Look for signs of a retail, Steam or GOG release (store
files, an unmodified exe) versus a modified one (a `.bak` next to a patched exe,
a replaced `Steam.dll`, a `.reg` that installs a CD key, links to file-sharing
sites). That decides where the recipe lives (step 2).

## 2. Find or write the recipe

**Existing recipe first**: the fingerprint exe's md5 in any `recipes/*/recipe.json`
or `recipes.local/*/recipe.json` `detect.builds`, or the same title. Reuse it.

**Otherwise write one** (schema: `docs/RECIPES.md`):

- **Where**: a retail, Steam or GOG copy gets `recipes/<name>/` (public). A
  modified copy, or any recipe that imports a key or names crack files, goes in
  `recipes.local/<name>/` (git-ignored, never committed; e.g. `cs16-nonsteam`).
- **`title`**: at most 16 bytes, so the Dock shows it (CrossOver engines).
- **`engine`**: `crossover-23`. `wowsilicon-r17` only if a test shows it is
  better for this game (it was not for Alpha Centauri).
- **`detect`**: the main exe as `fingerprint` and in `required`, plus any file
  the recipe depends on (a bundled wrapper, a `.reg`); `builds: {}` and
  `unknown: warn` until played (step 6).
- **`install`**: `exclude` the store and protection leftovers the game does not
  import, uninstallers and config tools; `rename` a bundled wrapper DLL only if the
  game must not use it; `registry` for `.reg` files the game needs in the prefix;
  `appIcon` the exe with the best icon; `exeIcon` the exe that owns the game
  window (the Dock shows its icon). A project may add its own `icon.*`.
- **`launch.variants`**: the real game exe, never a launcher stub, with its
  arguments (`{w}` `{h}` for the size where the game takes one).

**The window and the graphics**, from what the scan found:

| The game | Start with | Seen on |
|---|---|---|
| 2D DirectDraw or GDI, no wrapper bundled | `pillarbox:4:3`, `align: 8`, `backdrop: true`, `menubar: hide`; edge scrolling dead on one side → `install.proxy` on a DLL it loads from its folder | Alpha Centauri (plus a mod for size and CPU: Thinker) |
| 2D DirectDraw with its own wrapper (cnc-ddraw, dgVoodoo) | keep the wrapper: `dllOverrides {"ddraw": "n,b"}`, set it borderless with aspect kept (`install.ini`), `native`, no backdrop; cap its frame rate (`maxfps`) | Nox |
| OpenGL (often in a DLL the scan cannot read) | `game`: the game places its own window and nothing moves it; start windowed, full screen from the game's own options | Counter-Strike 1.6 |
| Direct3D 8/9 | try `native` first; untested so far, record what happens | - |
| Direct3D 10/11/12, 64-bit | not supported by the engines here yet: say so before building | - |

A game that keeps its settings in the registry and overrides the command line
with them: seed them with `install.registry`; a rebuild resets them (the prefix is
recreated).

Then `build/bottler recipe-check <recipe.json>` and start `notes.md` with the
analysis: md5, APIs, wrappers, leftovers, which copy it is, the Lutris hints.

## 3. Build

```sh
make project NAME=<name> RECIPE=<recipe name> GAME="<game folder>"   # once
make app PROJECT=<name>                                             # ~1 min first time, ~15 s after
```

## 4. Launch and observe

Say first that the game will open on the player's screen, and for how long.

```sh
APP="$PWD/projects/<name>/<Title>.app"
open "$APP"                                   # as the player would; wait for the window, not a fixed time
build/bottler windows "$APP"                  # the game window: where, how big, on screen?
build/bottler shot /tmp/game.png --app "$APP" # then look at it (read the png)
build/bottler cpu "$APP" 4                    # CPU of the game and wineserver
build/bottler log "$APP"                      # errors; relaunch with WINEDEBUG=err,+loaddll for detail
build/bottler click <x> <y>                   # drive a menu when needed (screen points)
```

A game started while another app has the focus may hide itself or draw nothing
until focused: bring it to the front before judging a black window. The first
seconds are often an intro video at full CPU; measure at a menu.

Check against this list; each failure goes to the **diagnose** skill:

- the window is where `bottler geometry` says (or where the game put it, in mode
  `game`), the whole picture is drawn, text is visible;
- CPU at a menu is under ~15% (game + wineserver);
- the log has no `failed to start`, no missing DLLs;
- the Dock shows the game's title (and its icon, checked by the user: macOS
  reports a generic icon for Wine processes).

Close the game when done; the launcher then quits and puts the menu bar and Dock
back as they were.

## 5. Ask the user, once per round

What the tools cannot observe: **sound** (plays, no crackle), **feel**
(scrolling, clicks landing, keyboard), **playing** (load a save, a few turns or
minutes), **quit** (everything closes, menu bar and Dock as before), **the Dock
icon**. Batch them into one question with options; never ask about something a
tool can check.

## 6. Fix, repeat, finish

- A recipe-level fix: change the recipe, rebuild, observe again.
- A fix that belongs in `core/`, `tools/` or `win/` (any game could hit it): use
  the **improve-bottler** skill; the recipe waits for that PR.
- Done when every check passes and the user confirmed the rest. Only then mark
  the build `verified` in `detect.builds`, finish `notes.md` (what works, what
  failed and why, what is not verified), and:
  - a public recipe: commit it on its branch, push and `gh pr create --base main`;
  - a `recipes.local/` recipe: nothing to commit; tell the user where it is.

  Report what was verified and what was not.
