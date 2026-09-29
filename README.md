# mac-bottler

Build a native-feeling macOS app for a Windows game, on your own Mac, from a small
per-game **recipe**. Each app is self-contained: a pinned Wine runtime, its own
prefix, the game installed from **your own copy**, and a tiny launcher (game
variant, display, Play). With nothing to choose (one variant, one display) there
is no launcher window: the app starts the game and quits with it. For a game with
a choice, tick "Start … right away next time" to get the same; hold ⌥ Option while
opening the app to see the window anyway. Resolution, aspect ratio, borders and
sound are detected at every launch.

No game files and no game artwork are ever part of this repository or of a built
app before you install your game into it. The app icon is generated at install
time from your game's own executable.

> Status: early. The first recipe is **Sid Meier's Alpha Centauri**; Nox and
> Counter-Strike 1.6 follow. See `.tasks/` for the plan in progress.

## Requirements

- macOS on Apple Silicon with Rosetta 2
- Xcode Command Line Tools: `xcode-select --install`
- mingw-w64, for the small Windows-side helpers: `brew install mingw-w64`

```sh
make check
```

For development, `make test` also needs Python 3 with Pillow (`pip3 install pillow`);
it runs on synthetic executables only, never on game files.

## Usage

```sh
make project NAME=alpha-centauri RECIPE=alpha-centauri GAME="/path/to/your/game folder"
make app PROJECT=alpha-centauri
open "projects/alpha-centauri/Alpha Centauri.app"
```

A project (`projects/<name>/`, never committed) is one game: which recipe, where
your copy of the game is, and the built app with the game inside. `RECIPE` can
also be a path to a recipe folder: it is copied into the project and stays local.
Recipes of your own that should not be public go in `recipes.local/<name>/`
(git-ignored); `make project` finds them by name, like the ones in `recipes/`. An
image dropped into the project as `icon.icns`, `icon.png`, `icon.ico` or `icon.jpg`
becomes the app's icon (and the Dock's, inside the game's exe) instead of the one
made from the game. Rebuilding
keeps the app's saves. Build as many projects as you like; builds of different
projects never touch each other. Everything reusable (engines, a clean prefix per
engine, pinned downloads) is cached in `build/cache/` and cloned into each app,
so a rebuild takes seconds.

## With an agent

Agents follow `AGENTS.md` (the rules and the skills; `CLAUDE.md` adds only what is
specific to Claude Code). The **cook** skill runs the whole loop: it scans the game,
picks or drafts a recipe, builds the app, launches and observes it, and fixes what
it finds, asking you only about sound and feel. In Claude Code that is
`/cook "/path/to/your/game folder"`; any other agent follows
`.claude/skills/cook/SKILL.md`.

## Layout

| Path | What |
|---|---|
| `projects/<name>/` | your local projects: `project.json`, the built app, logs (git-ignored) |
| `recipes/<game>/` | `recipe.json` (how the game is detected, installed and launched) and `notes.md` (what was tried and why) |
| `engines/` | pinned Wine runtimes (URL + SHA256) |
| `core/` | generic build, install and launch scripts, and the launcher template |
| `tools/` | `bottler`, the Swift CLI: scan a game, make icons, display geometry, backdrop, observe a running game |
| `win/` | small Windows helpers built with mingw (window placement, proxy DLLs) |
| `docs/` | `INTERNALS.md` (mechanisms and traps), `RECIPES.md` (recipe schema), `THIRD-PARTY.md` |

## License

MIT, see `LICENSE`. Third-party components are listed in `docs/THIRD-PARTY.md`.
