# Sid Meier's Alpha Centauri / Alien Crossfire: notes

What was tried on this game and why, most recent findings first. The general
lessons are also in `docs/INTERNALS.md`.

## Builds

| md5 of terranx.exe | Source | Status |
|---|---|---|
| `d505e007c20824a9869ff18099f2e9c8` | Steam (EA), v2.0 | verified |

GOG and patched-CD copies should be v2.0 too, but are untested. GOG's November 2024
update ships a `ddraw.dll` in the game folder; the recipe sets it aside
(`ddraw.dll.gog`) because it loads even in GDI mode and costs CPU. A v1.0 exe
will not run Thinker: apply the official 2.0 patch first.

## Why Thinker

- **The unmodded game spins the CPU** (~170% idle, plus wineserver). Thinker's
  built-in idle fix brings it to ~10%. The standalone smac-cpu-fix and cnc-ddraw's
  tick limiters had no effect under Wine.
- **Native-resolution mode leaves the map black after scrolling** on a 3440-wide
  screen; Thinker's fix for that did not help at that width, but a 4:3 window of
  1920x1440 draws correctly. Hence `pillarbox:4:3`.
- **Resolutions not divisible by 8 crash the game** (Thinker's notes): `align: 8`.
- **Original game:** Thinker's `-smac` switch runs the original SMAC rules and
  factions on the Crossfire engine, keeping every fix (it needs Thinker's
  `smac_mod/` files). The real `terran.exe` would lose them.
- Thinker requires `DirectDraw=0` (GDI mode) in `Alpha Centauri.Ini`.

## Display

- Thinker's windowed mode (`video_mode=2`) is borderless and placed at the
  top-left; `kitchen-place.exe` centres it, `kitchen frame` puts black behind it,
  the menu bar auto-hides while playing.
- Centring breaks edge scrolling: the game compares `GetCursorPos` (screen
  coordinates) with its window size. The game's own `soundx.dll` (loaded from
  its folder) is replaced by a proxy (`soundx.def`) that makes the cursor
  window-relative; the original is kept as `soundx_orig.dll`.
- A real titled macOS window was tried and abandoned: cnc-ddraw gave one but
  only its GDI renderer drew, text vanished when scaled, and it conflicts with
  Thinker; patching the game's CreateWindowEx style gave a title bar but clipped
  the bottom and broke minimise.
- Thinker refuses a window larger than the *primary* display: a game shown on a
  taller secondary display may be capped (not yet tested).

## Icon

- The app icon comes from `terran.exe` (the original planet, 48 px, scaled x18
  with no smoothing). The Dock shows the icon of the running exe, so the same
  icon is written into `terranx.exe` in place (`kitchen exe-icon`); rcedit's
  full rebuild made the game crash (self-modifying code sections).

## Engine

- CrossOver 23 (default). WoWSilicon Wine 11 ran the game at ~105% CPU plus ~48%
  wineserver and crackled on every output; msync made no difference.

## Sound

- 44.1 kHz output devices (the MacBook speakers) crackle; 48 kHz is clean. The
  recipe does not change the system's audio format; set the device to 48 kHz in
  Audio MIDI Setup if needed. The game's 3D sound and EAX are turned off (EAX
  does not exist under Wine; 3D sound only adds mixing work).
