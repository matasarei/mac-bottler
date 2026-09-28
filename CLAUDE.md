# Development rules for this project

Read this before changing anything. Background: `docs/INTERNALS.md` (how things
work and the traps already hit; read it first), `docs/RECIPES.md` (recipe schema),
`docs/THIRD-PARTY.md` (embedded components and licenses).

## Ground rules

- **The repo is the source of truth.** A built app is a disposable artifact: never
  fix something inside an app bundle and leave it there. Change the recipe or the
  tools, then rebuild with make.
- **Generic code stays generic.** Nothing game-specific lives outside
  `recipes/<game>/`. A feature enters `core/`, `tools/` or `win/` only when a recipe
  needs it; a behaviour two recipes duplicate moves into `core/`.
- **No game files, no game art, ever.** Not in commits, not in fixtures, not in a
  release. Icons are generated at install time from the user's own executable;
  test fixtures are synthetic.
- **Pinned downloads only.** Every artifact fetched by the build (engines, mods)
  is a URL plus its SHA256, updated together.
- **One change at a time, verified in the running game.** Tools can observe
  windows, screenshots and CPU; what they cannot (sound, feel, "does it play
  right") is confirmed by the user before the next change.
- **Record what was tried.** Every attempt on a game, including the ones that
  failed and why, goes into `recipes/<game>/notes.md`.

## Skills

- `/cook <game folder>`: bottle a game end to end (scan, recipe, build, launch,
  observe, fix). `/diagnose <symptom>`: known causes and how to confirm them.
  `/improve-bottler <problem>`: generic fixes, test first, as a pull request.
- The observe tools (`bottler windows|shot|cpu|click|log <app>`) are how an
  agent sees a running game; ask the user only for sound and feel.

## Pull requests and releases

- Work on a branch; open a pull request with what was verified and how.
- Merging, releases, tags and pushes to `main` are the maintainer's decision,
  never an agent's.
- A built app that has ever had a game installed must never be distributed.
