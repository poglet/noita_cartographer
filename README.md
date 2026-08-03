# Cartographer

A fullscreen explorable map for Noita with true fog of war. Only terrain that
has actually been on your screen is ever revealed.

## Install

Copy or symlink this folder into `Noita/mods/cartographer`, then enable
**Cartographer** from the in-game Mods menu.

> Enabling mods through the Mods menu is the only reliable route. Editing
> `save00/mod_config.xml` directly does not stick, because Steam Cloud syncs
> the file back over your changes on the next launch.

## Controls

| Input | Action |
| --- | --- |
| `M` | Open / close the map |
| Left drag | Pan (with momentum) |
| Mouse wheel, `+` / `-` | Zoom, anchored on the cursor |
| Right click | Recentre on the player |
| `Home` | Fit the whole explored region |
| `Esc` | Close |

Hovering an item pin shows a panel with its details. For wands that is the
full inventory stat block plus the spells it contains.

## Settings

| Setting | Default | Notes |
| --- | --- | --- |
| Remember the map across saves | on | Stores explored data in the save |
| Mark discovered items | on | Pins wands, potions, spells, perks, orbs |
| Invulnerable while the map is open | on | See "no pause" below |
| Experimental: force engine pause | **off** | Unverified, may upset the inventory |
| Terrain scan budget | 900 | Cells mapped per frame in new areas |
| Terrain refresh budget | 220 | Cells re-checked so digging shows up |
| Show render statistics | off | Draw batch counts, for tuning |

## How the fog of war works

Each frame the rectangle returned by `GameGetCameraBounds()` is marked as
seen. That rectangle *is* what the engine just rendered, so the map is exactly
what you have looked at — no reveal radius, no line-of-sight approximation. If
it was on screen it is on the map, and if it never was, it is not.

## Engine constraints worth knowing

These were established by testing in game, and each one shaped the design.

**There is no way to pause Noita from Lua.** No `GameSetPaused`, nothing in
the component list, nothing on the world state entity. `OnPausedChanged` only
*observes* pause. The map therefore takes over input instead: while it is open
`ControlsComponent.enabled` is forced false every frame, so a left-drag cannot
fire your wand and WASD cannot walk you off a ledge. Because the world keeps
running, you are made invulnerable while the map is open.

**`GuiImage` caches textures on first upload.** `ModImageMakeEditable` plus
`ModImageSetPixel` correctly edit the CPU-side copy — verified with
`ModImageGetPixel` — but the GPU texture is uploaded once and never refreshed,
so a live pixel canvas is impossible. Everything is drawn with stretched 1x1
sprites instead.

**That would mean one widget per cell, which does not scale.** Three things
make a fullscreen map affordable anyway:

- *Run-length batching.* Terrain is horizontally coherent, so a row of 40
  identical cells costs one stretched sprite rather than forty.
- *Cached run decomposition.* Runs depend only on cell data, never on the
  camera, so they are computed once per chunk instead of every frame.
- *Adaptive LOD.* A four-level pyramid, the coarsest collapsing a whole chunk
  to one cell; the renderer steps to a coarser level until it fits
  `WIDGET_BUDGET`. Zooming out costs detail, never framerate. Levels cascade
  from the previous one rather than from full resolution, and chunks are drawn
  from the centre of the view outwards so that if the budget ever does run
  out, the loss is at the edges instead of as holes in the middle.

**Once a `Gui` object exists, `GuiStartFrame` must be called every frame.**
Skipping it leaves the previous frame's widgets resident, and a leftover
fullscreen backdrop goes on swallowing mouse clicks until the game is
restarted. `update()` therefore always starts a frame and simply draws nothing
when the map is closed.

**There is no "what material is at this pixel" call.** Terrain is classified
with zero-length raytraces, which do work as point samples (`RaytraceSurfaces`
returns no hit in air and a hit in ground). That yields solid / liquid / air
only, so the map is a biome-tinted silhouette rather than a shrunken
screenshot.

## Layout

| File | Responsibility |
| --- | --- |
| `init.lua` | Callback wiring and settings refresh |
| `files/config.lua` | Tunables, keycodes, palette |
| `files/store.lua` | Chunked cell storage, LOD pyramid, run cache |
| `files/scanner.lua` | Camera-rect fog recording, terrain sampling |
| `files/markers.lua` | Item discovery, descriptions, serialisation |
| `files/mapview.lua` | Input, zoom/pan, rendering |
| `files/persist.lua` | RLE + base64 save/load |

Cells are stored as packed byte-strings, one byte per cell, a row at a time.
A fully explored chunk costs about 6 KB that way versus roughly 50 KB as a
Lua table, which matters because a long run can touch a thousand chunks.

## Limitations

- Saving is capped at 2 MB of encoded data. Past that the map stops persisting
  and says so on screen, rather than writing without bound into your save.
- Wand tooltips are a snapshot from when the item was first seen, not live
  data.
- Gold nuggets are deliberately not pinned; they would bury everything else.
- Chests are not pinned — the tag was never confirmed.
- Parallel worlds are recorded, but no effort is made to present them well.
