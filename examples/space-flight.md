# Building a 3D space flight sim with Didi

A worked example of building a **3D space flight simulator** — a first-person
cockpit, Newtonian flight through an asteroid field, with survival systems (fuel,
shields, hull) — **entirely through the Didi MCP server** (`run_gdscript`), no
hand-editing.

Companion to the `gdscript_authoring_guide` MCP resource (`didi://guides/gdscript`)
for general tool usage, and to `examples/tetris.md` (a 2D worked example whose
Didi techniques — array-of-lines file writing, `@tool` vs runtime testing,
split-`set_script`-across-calls, `CACHE_MODE_REPLACE` — apply here too).

> Status: **playable — core complete + partial polish.** Steps 1–7 are done (3D
> setup, Newtonian flight with rotational inertia + flight-assist, asteroid field,
> cockpit frame, collision damage with shields/hull/destruction/restart, fuel, and
> the custom instrument HUD), plus Step 8 polish so far: starfield, procedural
> sound, and screen shake. See **Controls** for inputs and **Remaining work** for
> what's built vs. pending. Tunables live on the `Ship` node and each
> `res://space/*.gd` script.

---

## Design decisions (locked)

- **Flight model:** Newtonian 6DOF — thrust accelerates, the ship coasts/drifts —
  with a toggleable **flight-assist** that damps linear (and optionally angular)
  velocity for control.
- **View / cockpit:** first-person. A simple modeled **3D cockpit frame**
  (canopy/struts) around the view for the "inside the ship" feel, plus a **2D HUD
  overlay** (`CanvasLayer`) for the instruments.
- **Controls:** **mouse + keyboard** — mouse aims pitch/yaw, keys handle roll,
  throttle, flight-assist toggle, and systems.
- **Scope:** **survival from the start** — thrust consumes **fuel**; asteroid
  collisions drain **shields** (which recharge over time) then **hull**; hull
  reaching 0 destroys the ship (game over + restart).

## Indicators to surface in the HUD

Attitude (roll / pitch / yaw), throttle + speed, fuel, shield charge, hull
integrity. (Some are also game state driving win/lose, not just readouts.)

---

## Project location

Built in the existing **`demo/`** project (Didi is already installed and running
there, so no second editor instance is needed). The space sim lives alongside the
Tetris example:

```
demo/
├── space.tscn          # the 3D game scene (set as the run target while building this)
└── space/              # scripts: ship/flight, asteroids, systems, hud, ...
```

The window is switched to a landscape 3D resolution; the Tetris scene still runs
(its stretch settings letterbox fine). A clean separate project is an option later
if the shared settings get in the way.

---

## Architecture (as built)

Scene `res://space.tscn`, root `Space` (`Node3D`):

- **`WorldEnvironment`** — dark-space background + ambient light.
- **`Sun`** (`DirectionalLight3D`) — directional light for the asteroids.
- **`Ship`** (`CharacterBody3D`, `space/ship.gd`) — Newtonian flight + survival
  systems: `throttle`/`velocity`/`ang_vel`, `shield`/`hull`/`fuel`, integrated each
  physics frame; thrust along local −Z, flight-assist damps linear + angular;
  collision via `move_and_collide`. Children: `Collision` (sphere) and `Camera3D`
  (`space/camera_shake.gd`) → `Cockpit` (frame struts parented to the camera).
- **`AsteroidField`** (`Node3D`, `space/asteroid_field.gd`, `@tool`) — generates 70
  procedural deformed-sphere `StaticBody3D` asteroids in a shell, clear bubble at
  spawn.
- **`HUD`** (`CanvasLayer`) → `Instruments` (`Control`, `space/hud.gd`) —
  custom-`_draw` attitude indicator + color-coded bars + SPEED/ASSIST readouts.
- **`Starfield`** (`Node3D`, `space/starfield.gd`, `@tool`) — camera-following
  unlit star points.
- **`Sound`** (`Node`, `space/sound.gd`) — runtime-synth engine hum + impact /
  warning / boom one-shots; polls the ship.

`@tool` scripts (`asteroid_field`, `starfield`) generate in-editor and render
there; the gameplay scripts (`ship`, `hud`, `sound`, `camera_shake`) run only at
play time. Per the Tetris pattern, runtime logic was verified by mirroring math in
`run_gdscript` (e.g. damage overflow, fuel rates) or by playtesting.

---

## Controls

| Input | Action |
|-------|--------|
| Mouse | Pitch / yaw (inertial) |
| A / D | Roll left / right |
| W / S | Throttle up / down (−20% … 100%) |
| X | Cut throttle to zero |
| Z | Toggle flight-assist |
| Esc | Release / recapture mouse |
| Enter or R | Restart (after destroyed) |

---

## Roadmap

1. **3D project setup** — landscape window; `space.tscn` with `Node3D` root,
   `Camera3D`, and a `WorldEnvironment` (space background + ambient light); set as
   the run target.
2. **Flight model** — Newtonian 6DOF translation + rotation, mouse+keyboard input,
   flight-assist toggle. (Camera rides the ship.)
3. **Cockpit frame** — simple 3D canopy/strut geometry fixed to the camera, plus
   an empty HUD `CanvasLayer` scaffold.
4. **Asteroid field** — procedural asteroid mesh(es), scattered through the volume
   (visual + collision).
5. **Collision & damage** — shields absorb hits and recharge; hull takes the
   overflow; hull 0 = destroyed → game over + restart.
6. **Fuel** — thrust consumes fuel; running dry cuts thrust.
7. **HUD instruments** — attitude (roll/pitch/yaw), speed/throttle, and
   fuel/shield/hull gauges, all live.
8. **Polish (optional)** — starfield/particles, engine + impact sound, screen
   shake, score/distance, pause.

---

## Remaining work

Core roadmap (Steps 1–7) is **done**: 3D setup, Newtonian flight with inertia +
flight-assist, asteroid field, cockpit frame, collision damage (shields/hull,
destruction, restart), fuel, and the instrument HUD. The game is playable
end-to-end.

Step 8 polish — **done so far:**

- **Starfield** — 1500 unlit star points on a camera-following sphere
  (parallax-free, no clipping). `res://space/starfield.gd`.
- **Sound** — runtime-synth WAV (no asset files): looping engine hum scaled by
  throttle, plus impact / low-hull-warning / destruction one-shots; polls the
  ship so `ship.gd` is untouched. `res://space/sound.gd`.
- **Screen shake** — trauma-based camera jitter on impact (shakes the cockpit too,
  since it's parented to the camera). `res://space/camera_shake.gd`.

Optional, **not yet built:**

- **Score / distance / survival time** readout; **pause**.
- **Skybox / nebula** background (the starfield sits over a flat dark color).
- **Drifting / rotating asteroids**, **radar / off-screen marker**, weapons.
- **HUD attitude tuning** — verify roll/pitch sign and scale against a playtest.
