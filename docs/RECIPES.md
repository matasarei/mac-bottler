# Recipes

A recipe is a folder `recipes/<game>/` with:

- `recipe.json`: how the game is detected, installed and launched (schema below);
- `notes.md`: what was tried on this game and why, including what failed;

It is the only place anything game-specific lives.

A recipe that should not be public (for one particular copy of a game) goes in
`recipes.local/<name>/` (git-ignored), where `make project RECIPE=<name>` finds it
after `recipes/`. For a one-off, it can also live in its project: `make project NAME=<name> RECIPE=<path to a recipe folder>
GAME=…` copies the folder to `projects/<name>/recipe/` (git-ignored) and the
project builds from it. `bottler recipe-check
recipes/<game>/recipe.json` validates it; unknown keys are errors, so a typo fails
the build instead of the game.

## Build time and install time

- `make app RECIPE=recipes/<game>` (on the machine that builds the app) copies the
  recipe into the app as `Resources/recipe/`, fetches and verifies its
  `downloads`, and builds its `proxy` DLL. Results go to `Resources/recipe/files/`.
- Install (the app's Install button, `bottler install`) copies the player's own
  game folder into the app and applies `install`. It needs no network and no
  compiler, and running it again changes nothing.

## Schema (version 1)

```json
{
  "schema": 1,
  "title": "Alpha Centauri",
  "bundleId": "com.matasarei.bottler.alpha-centauri",
  "engine": "crossover-23",

  "detect": {
    "required": ["terranx.exe", "terran.exe"],
    "fingerprint": "terranx.exe",
    "builds": {
      "d505e007c20824a9869ff18099f2e9c8": { "status": "verified", "label": "Steam v2.0" },
      "0123456789abcdef0123456789abcdef": { "status": "refuse", "message": "v1.0: apply the official 2.0 patch" }
    },
    "unknown": "warn"
  },

  "install": {
    "exclude": ["EmptySteamDepot", "secdrv.sys", "drvmgt.dll"],
    "rename": { "ddraw.dll": "ddraw.dll.gog" },
    "downloads": [
      { "url": "https://…/Thinker_v5.5.zip", "sha256": "…", "files": { "thinker.exe": "thinker.exe", "basenames": "basenames" } }
    ],
    "ini": [
      { "file": "Alpha Centauri.Ini", "section": "Alpha Centauri", "set": { "DirectDraw": "0" } }
    ],
    "proxy": { "dll": "soundx.dll" },
    "appIcon": "terran.exe",
    "exeIcon": "terranx.exe"
  },

  "launch": {
    "variants": [
      { "label": "Alien Crossfire", "exe": "thinker.exe", "args": [] },
      { "label": "Alpha Centauri", "exe": "thinker.exe", "args": ["-smac"] }
    ],
    "window": { "mode": "pillarbox:4:3", "align": 8, "backdrop": true, "menubar": "hide", "title": "" },
    "ini": [
      { "file": "thinker.ini", "section": "thinker", "set": { "window_width": "{w}", "window_height": "{h}" } }
    ],
    "env": {},
    "dllOverrides": {}
  }
}
```

| Key | Meaning |
|---|---|
| `schema` | always `1` for now |
| `title` | app and window name shown to the player |
| `bundleId` | the app's bundle identifier |
| `engine` | a file name in `engines/` without `.env` |
| `detect.required` | paths that must exist in the chosen game folder |
| `detect.fingerprint` | the file whose md5 identifies the build |
| `detect.builds` | md5 → `status` `verified` (tested), `unverified` (accepted with a warning) or `refuse` (with `message`); `label` is for people |
| `detect.unknown` | a build not listed: `warn` (install, with a warning) or `refuse` |
| `install.exclude` | top-level names not copied from the game folder |
| `install.rename` | game-folder file → new name, when it exists (e.g. set a bundled wrapper aside) |
| `install.downloads` | pinned archives fetched at build time: `url`, `sha256`, and `files` mapping a path inside the archive to a path in the game folder. Zip only for now. |
| `install.ini` | INI edits applied at install; the section is created and keys added when missing; CRLF files stay CRLF |
| `install.proxy` | `dll` in the game folder is renamed `<name>_orig.dll` and replaced by a proxy forwarding every export to it. The export list is read from the project's own copy of the DLL at build time (`win/proxy.sh def`), so nothing derived from the game is in the repo. |
| `install.appIcon` | the exe whose icon becomes the app icon (`bottler icon`); a project's own `projects/<name>/icon.*` wins over it |
| `install.registry` | `.reg` files in the game folder, imported into the prefix at every build (the prefix is rebuilt from the cache each time); a listed file missing from the game refuses the install |
| `install.exeIcon` | the exe that gets that icon written into it in place (`bottler exe-icon`), so the Dock shows it; the stock exe is kept as `<exe>.bkp` |
| `launch.variants` | what the player can start: `label`, `exe` (relative to the game folder), `args` (`{w}`, `{h}`, `{x}`, `{y}` are the window's geometry) |
| `launch.window.mode` | `native` or `pillarbox:<w>:<h>` (see `bottler geometry`): the window is kept at that rect. `game`: the game places its own window, windowed or full screen, and nothing moves it (moving an OpenGL window turned it black); `{w}`/`{h}` are the display's full width by the tallest display mode below the notch, so the scale stays the same |
| `launch.window.align` | round the window's sides down to a multiple of this |
| `launch.window.backdrop` | black backdrop behind the window (`bottler frame`) |
| `launch.window.menubar` | `hide` (auto-hide while playing) or `keep` |
| `launch.window.title` | text the game window's title contains, when the largest window is not the game's |
| `launch.ini` | INI edits applied at every launch; `{w}`, `{h}`, `{x}`, `{y}` are the window's geometry |
| `launch.modeCache` | `true`: load the display-mode cache into the game (`win/modecache.c`). For games that enumerate the display modes over and over at start: ~400 modes on a Retina Mac made Counter-Strike's menu take ~18 s; with the cache, ~4.5 s |
| `launch.env` | extra environment variables for wine |
| `launch.dllOverrides` | `WINEDLLOVERRIDES` entries, e.g. `{"ddraw": "n,b"}` |

## Fields no recipe uses yet

Every field above is used by a recipe, except two kept on purpose:

- `launch.window.title`: the remedy the diagnose skill gives when a game's largest
  window is not the game (a splash or launcher window beside it). Tested.
- `launch.env`: the one way to pass an engine switch (a Wine or MoltenVK
  environment variable) without changing code. Tested.

A field that turns out to have no use is removed (`launch.registry` was, after the
game it was built for did better with its own settings).
