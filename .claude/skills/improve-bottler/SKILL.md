---
name: improve-bottler
description: Fix or extend mac-bottler's shared code (core/, tools/, win/) when a problem found while bottling a game belongs to every game, not one recipe - branch, failing test first, fix, re-verify the affected apps, open a pull request. Never merges. Use when the cook or diagnose skill finds a generic bug or a missing generic feature.
---

# /improve-bottler <the problem>

For changes to `core/`, `tools/` or `win/`. A change that only one game needs
belongs in its recipe instead (`CLAUDE.md`: nothing generic is built ahead of a
recipe's need, and nothing game-specific lives outside `recipes/`).

## Steps

1. **Branch from an up-to-date `main`**: `git switch main && git pull --ff-only
   && git switch -c fix/<slug>` (or `feature/<slug>`). Never commit to `main`.
2. **Write the failing test first** in `tests/run-tests.sh`, hermetic: synthetic
   PE files (`tests/fixtures/mkpe.py`), fake app layouts, stub wine, fake
   displays (`bottler geometry --screen …`, `BOTTLER_TEST_SCREENS`). Run
   `make test` and see it fail for the right reason.
3. **Fix it**, matching the surrounding code's style. Keep game names out of
   generic code: `grep -rniE "<game-specific words>" core tools win` stays empty.
4. **Prove it**:
   - `make test` and `make compile` pass (quote the result lines);
   - break the fix on purpose once and confirm the new test fails (then restore);
   - rebuild every project whose app is affected (`make app PROJECT=<name>`,
     never while its game runs) and re-check it with the observe tools; ask the
     user only for what tools cannot check (sound, feel).
5. **Document**: a new trap goes into `docs/INTERNALS.md`; a schema change into
   `docs/RECIPES.md`; a new component into `docs/THIRD-PARTY.md`.
6. **Commit** with the rulings in the body (what you decided, why, what it costs
   if wrong), then `git push -u origin <branch>` and
   `gh pr create --base main` with: the problem, the cause, the fix, the test,
   what was verified on which apps, and what was not.

## Never

- merge, push `main`, force-push, amend, or skip hooks;
- weaken or delete a test to get to green;
- commit anything from a game (`make test` refuses binaries and game files);
- copy code from projects under a different license without the maintainer's
  approval (see `docs/THIRD-PARTY.md`).
