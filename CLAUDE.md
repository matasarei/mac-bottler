# Claude Code in this project

**Read `AGENTS.md` first: it is the main instruction set** (what this is, the
commands, the rules, the skills, pull requests). This file adds only what is
specific to Claude Code.

## Skills

The skills in `.claude/skills/` load automatically; invoke them as slash commands:

- `/cook <game folder> [recipe name]`: bottle a game end to end.
- `/diagnose <symptom>`: known causes of a symptom and how to confirm each.
- `/improve-bottler <problem>`: a generic fix to `core/`, `tools/` or `win/`,
  test first, as a pull request.

Use them whenever a task matches, rather than working from memory.

## Working here

- Game launches and some builds outlive a tool call: run them in the background,
  and wait for a condition (the window appearing, the process ending) instead of
  sleeping for a fixed time.
- To see a game, use `build/bottler shot <png> --app <app>` and read the image;
  `build/bottler windows <app>` shows where its windows are and whether they are
  on screen.
- When the player needs to run something themselves (a login, a game session),
  suggest `! <command>` so its output lands in the conversation.
