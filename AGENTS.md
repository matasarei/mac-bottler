# Instructions for agents working on mac-bottler

These are the instructions for any agent (Claude, Codex, Cursor, Copilot or other)
and for people. Tool-specific additions live in their own files (`CLAUDE.md` for
Claude Code) and never contradict this one.

## What this is

A kitchen for building a native-feeling macOS app for a Windows game, on the
player's own Mac, from the player's own copy. A **recipe** (`recipes/<game>/`)
says how one game is detected, installed and launched; a **project**
(`projects/<name>/`, git-ignored) is one game on this machine: which recipe,
where the copy is, and the built app with the game inside.

Read before changing anything:

- `docs/INTERNALS.md`: how things work and every trap already hit. Most problems
  are in there.
- `docs/RECIPES.md`: the recipe schema.
- `docs/THIRD-PARTY.md`: embedded components and their licences.

## Commands

```sh
make check                                    # build prerequisites
make bottler                                  # build/bottler: scan, hints, icon, observe
make project NAME=<name> RECIPE=<recipe> GAME="<game folder>"
make app PROJECT=<name>                       # ~1 min first time, ~15 s after
make test                                     # hermetic tests + repo audit
make compile                                  # Swift type-check
make lint                                     # shellcheck
build/bottler windows|shot|cpu|click|log <app>   # observe a running game
```

## Skills: use them

The skills are step-by-step procedures in plain markdown. **Whatever tool you
are, when a task matches one, read its file and follow it** instead of improvising:

| Skill | File | Use it to |
|---|---|---|
| cook | `.claude/skills/cook/SKILL.md` | bottle a game end to end, with or without a recipe: analyse the files, find or write the recipe, build, launch, observe, fix until it plays |
| diagnose | `.claude/skills/diagnose/SKILL.md` | go from a symptom (black screen, no sound, crackle, high CPU, wrong Dock icon…) to its known causes and the test that confirms each |
| improve-bottler | `.claude/skills/improve-bottler/SKILL.md` | fix or extend the shared code (`core/`, `tools/`, `win/`): branch, failing test first, fix, re-verify apps, pull request |

They live under `.claude/` because Claude Code loads them from there; nothing in
them is Claude-specific.

## Rules

**The repository**

- **The repo is the source of truth.** A built app is a disposable artifact:
  never fix something inside an app bundle and leave it there. Change the recipe
  or the tools, then rebuild.
- **Generic code stays generic.** Nothing game-specific lives outside `recipes/`.
  A feature enters `core/`, `tools/` or `win/` only when a recipe needs it; a
  behaviour two recipes duplicate moves into `core/`.
- **No game files, no game art, no keys, ever.** Not in commits, not in fixtures.
  Icons are made from the player's own copy at build time; a project's own icon
  (`projects/<name>/icon.*`) stays in the project. `make test` audits the repo
  and refuses binaries, media, `.reg` files and anything shaped like a CD key.
- **Only games the player owns.** A recipe that is tied to one particular copy
  (a modified or non-Steam build, a recipe that imports a key or names crack
  files) goes in `recipes.local/<name>/` (git-ignored), never in `recipes/`.
- **Pinned downloads only.** Everything the build fetches is a URL plus its
  SHA256, updated together (`make check-pins` checks they still resolve).

**Working on a game**

- **One change at a time, verified in the running game.** Observe with the tools
  (windows, screenshots, CPU, logs); ask the player only for what tools cannot
  observe (sound, feel, "does it play right"), batched into one question.
- **Record what was tried.** Every attempt, including failures and why, goes into
  the recipe's `notes.md`.
- **Never rebuild an app while its game runs**: the rebuild moves the game folder,
  with the player's saves, into the new app. Check first:
  `pgrep -f "projects/<name>/.*Resources/wine"`.
- **Say before you take over the screen.** A test launch opens a full-screen game
  on the player's display: announce it and how long it stays, close it after, and
  leave a game the player is using alone.
- **Leave the player's desktop as you found it.** The launcher records the menu
  bar and Dock settings and puts them back; tests use separate preference domains
  (`BOTTLER_TEST_PREFS`). Never change the player's real settings from a test.

**Code and tests**

- **Test first.** A new check must be seen failing for the right reason before
  the fix, and a fix is broken on purpose once to prove the test bites. Tests are
  hermetic: synthetic PE files (`tests/fixtures/mkpe.py`), stub wine, fake
  displays; no game data, no network.
- **Match the surrounding code**: its naming, comment density and idiom.
- A new trap goes into `docs/INTERNALS.md`, a schema change into
  `docs/RECIPES.md`, a new component into `docs/THIRD-PARTY.md`.

## Pull requests and releases

- Work on a branch, one coherent change per pull request, and say in it what was
  verified, how, and what was not. Commit bodies carry the decisions made along
  the way (`Ruling: what, why, what it costs if wrong`).
- A pull request stacked on another targets that branch; when the lower one is
  merged, retarget it to `main` before merging.
- Merging, releases, tags and pushes to `main` are the maintainer's decision,
  never an agent's. No force-push, no amend, no skipped hooks.
- A built app that has ever had a game installed must never be distributed.
