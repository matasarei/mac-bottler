# mac-bottler

[![CI](https://github.com/matasarei/mac-bottler/actions/workflows/ci.yml/badge.svg)](https://github.com/matasarei/mac-bottler/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/github/license/matasarei/mac-bottler)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)
[![Apple Silicon | Intel](https://img.shields.io/badge/Apple%20Silicon%20%7C%20Intel-black?logo=apple)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](tools/bottler.swift)
[![Wine](https://img.shields.io/badge/Wine-CrossOver%2023-8A1538?logo=wine&logoColor=white)](docs/THIRD-PARTY.md)

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

> Status: early. Recipes: **Sid Meier's Alpha Centauri** (Steam) and **Nox** (GOG).
> Your own recipes for copies that should not be public go in `recipes.local/`.

Inspired by [wow-launcher](https://github.com/matasarei/wow-launcher), a dedicated
native macOS launcher for classic World of Warcraft on Apple Silicon. mac-bottler
takes the same approach (a pinned Wine runtime, fixes baked in, one self-contained
app) and turns it into a kitchen that bottles any game from a recipe.

## Requirements

- macOS 14 or newer, on Apple Silicon (with Rosetta 2: the Wine engine is Intel
  code) or on Intel. The tools and the launcher are compiled on your Mac, for its
  own CPU and macOS. Tested so far on Apple Silicon only.
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

No AI subscription? [OpenCode](https://opencode.ai) with an open model works too:
the skills are plain markdown, and a local ~30B coding model (Qwen3 Coder 30B, for
example) can follow them. [opencode-skills](https://github.com/matasarei/opencode-skills)
is a ready set of OpenCode skills tuned for such local models.

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
