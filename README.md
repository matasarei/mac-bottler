# mac-bottler

Build a native-feeling macOS app for a Windows game, on your own Mac, from a small
per-game **recipe**. Each app is self-contained: a pinned Wine runtime, its own
prefix, the game installed from **your own copy**, and a tiny launcher (game
variant, display, Play). Resolution, aspect ratio, borders and sound are detected
at every launch.

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

## Layout

| Path | What |
|---|---|
| `recipes/<game>/` | `recipe.json` (how the game is detected, installed and launched) and `notes.md` (what was tried and why) |
| `engines/` | pinned Wine runtimes (URL + SHA256) |
| `core/` | generic build, install and launch scripts, and the launcher template |
| `tools/` | `bottler`, the Swift CLI: scan a game, make icons, display geometry, backdrop, observe a running game |
| `win/` | small Windows helpers built with mingw (window placement, proxy DLLs) |
| `docs/` | `INTERNALS.md` (mechanisms and traps), `RECIPES.md` (recipe schema), `THIRD-PARTY.md` |

## License

MIT, see `LICENSE`. Third-party components are listed in `docs/THIRD-PARTY.md`.
