# HeelKawn — project handoff (read me first)

This file is the **shared memory** for this repo. **Every coding session on HeelKawn should start by reading it** and **end (or after meaningful work) with an update** to the *Current focus* and *Changelog* sections.

---

## What this is

- **HeelKawn**: Godot 4 **colony / RimWorld-style** sim — procedural world, pawns, jobs, stockpiles, building designation (beds, walls, doors, zones), day/night, save/load.
- **Entry scene**: `scenes/main/Main.tscn` / `scenes/main/Main.gd` (drives input, designations, bootstrap, F5 save / F8 load).
- **UI**: `ColonyHUD`, `BuildToolbar` (CanvasLayer, bottom bar), `PawnInfoPanel`.

---

## Where we left off (edit this when status changes)

**Last updated:** 2026-04-24

- **Done recently**
  - Build/zone **preview** draws on `BuildPreviewOverlay` (sibling after `World`) so tints are visible; not hidden under the map.
  - **Build toolbar**: clear pressed styling for active Bed/Wall/Door/Zone; **Colony** cluster with **Save [F5]** and **Load [F8]** wired to same handlers as keys.
- **Open / not blocked**
  - (Add next concrete tasks here — bugs, features, playtest notes.)
- **Conventions**
  - `Main.DesignationMode` ↔ `BuildToolbar` `MODE_*` ints must stay aligned (0–4).
  - New toolbar signals from `BuildToolbar` → connect in `Main._ready()`.

---

## Changelog (newest first)

| Date | What changed (short) |
|------|------------------------|
| 2026-04-24 | Added `HEELKAWN_HANDOFF.md` + Cursor rule for session memory; `BuildPreviewOverlay`, toolbar save/load, build-button highlight styles. |

---

## For the AI assistant (instructions)

1. **At the start** of a task in this project: read this file, then the files you need.
2. **After** non-trivial edits (new behavior, new files, user-facing fixes): add a one-line **Changelog** row and refresh **Where we left off** so the *next* session knows the state.
3. Do **not** let this file grow into a novel — keep bullets short; link paths, not long code blocks.

## For the human

- You can **paste goals at the top of “Where we left off”** any time; we’ll align work to that.
- If something is still wrong in-game, add one line under **Open** with steps to reproduce.
