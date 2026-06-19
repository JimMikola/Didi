# Building Tetris with Didi

A worked example of building a 2D Tetris game **entirely through the Didi MCP
server** — no hand-editing of files or the scene. Everything below is done by
calling the `run_gdscript` tool to author scripts, build the scene, and configure
the project in an open Godot editor.

This document is a companion to the `gdscript_authoring_guide` MCP resource
(`didi://guides/gdscript`): that guide covers the tool in general; this one is the
concrete recipe for this game. Read both.

> Status: in progress. Built so far — 2D project config, playfield, tetromino
> data, active piece + collision, gravity + input, line clearing, scoring + HUD,
> next-piece preview + 7-bag, restart, SRS wall kicks, hold piece, ghost piece,
> sound, pause. Feature-complete. Optional extras (lock delay, DAS tuning, music)
> remain. Kept up to date as the project grows.

---

## How Didi shapes the workflow (read this first)

`run_gdscript` runs the GDScript you send on the editor's **main thread**. A few
non-obvious things drive *how* you write code through it:

1. **Authoring files: build content as an array of one-line strings.** The tool
   wraps your script as the body of a function and indents **every physical
   line**. A triple-quoted multi-line string literal would therefore get its
   indentation corrupted. So when writing a `.gd` file, build its text like this
   and let `\t` carry the file's *own* indentation:

   ```gdscript
   var lines = [
       "@tool",
       "extends Node2D",
       "func _ready() -> void:",
       "\tprint(\"hi\")",
   ]
   var content = "\n".join(lines) + "\n"
   var f = FileAccess.open("res://thing.gd", FileAccess.WRITE)
   f.store_string(content)
   f.close()
   ```

   The array lives inside `[ ]`, so the leading whitespace the tool adds is
   ignored; the strings' contents (including `\t`) are written verbatim.

2. **Indent the script you send consistently** — all tabs or all spaces. The tool
   matches the style it detects, but a script that mixes them fails to compile.

3. **Split "change a script" from "use it" across two tool calls.** After you
   write/reload a `.gd` or `set_script()` a node, the new members aren't usable
   until the next frame — i.e. your next call. Call 1 writes + `scan()`s; call 2
   loads/instantiates/calls. To dodge the resource cache when a script changed on
   disk, reload with
   `ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_REPLACE)`.

4. **`@tool` vs not — and what you can test from Didi.** A non-`@tool` script has
   **no live instance in the editor**: the node carries the script (so
   `has_method()` is true) but there is nothing to execute, so calling its methods
   via `run_gdscript` errors. Consequences:
   - Make **data/visual** nodes you want to see and poke from Didi `@tool` (the
     board is `@tool`, so it draws in the editor and you can call its methods).
   - Keep the **gameplay controller** non-`@tool` (so gravity/input only run in
     the real game). You can't drive its methods from the editor — verify its
     *logic* by mirroring the same board calls (which do run), then confirm the
     input/gravity wiring by running the game (F5).

5. **Persist + refresh.** `EditorInterface.get_resource_filesystem().scan()` after
   writing files; `EditorInterface.save_scene()` / `ProjectSettings.save()` to
   persist; `EditorInterface.open_scene_from_path(...)` to show a scene.

---

## Project files this builds

```
res://
├── main.tscn          # Main (Node2D, game.gd) → child Board (Node2D, board.gd)
└── tetris/
    ├── board.gd       # @tool TetrisBoard: grid model + rendering + piece queries
    ├── tetromino.gd   # Tetromino: the 7 pieces (shapes + colors), static data
    └── game.gd        # game controller: gravity, input, spawn/lock (runtime only)
```

---

## Step 1 — Configure the project as a 2D game

Create a 2D main scene, set it as the main scene, and size the window for a 10×20
board (30px cells = 300×600) plus a HUD column. Use 2D-friendly stretch.

```gdscript
var root = Node2D.new()
root.name = "Main"
var packed = PackedScene.new()
packed.pack(root)
ResourceSaver.save(packed, "res://main.tscn")
root.free()

ProjectSettings.set_setting("application/run/main_scene", "res://main.tscn")
ProjectSettings.set_setting("display/window/size/viewport_width", 540)
ProjectSettings.set_setting("display/window/size/viewport_height", 720)
ProjectSettings.set_setting("display/window/stretch/mode", "canvas_items")
ProjectSettings.set_setting("display/window/stretch/aspect", "keep")
ProjectSettings.save()
EditorInterface.get_resource_filesystem().scan()
EditorInterface.open_scene_from_path("res://main.tscn")
```

The renderer can stay at `forward_plus`; it renders 2D fine.

---

## Step 2 — The playfield (`res://tetris/board.gd`)

A `@tool extends Node2D` so it renders in the editor. It owns the grid model and
all cell/coordinate math; everything else builds on it.

- Constants: `COLS = 10`, `ROWS = 20`, `CELL = 30`.
- `grid[y][x]` holds a `Color` for a locked cell, or `null` when empty
  (`_init_grid()` fills it with `null`).
- `_draw()` paints the well background, faint grid lines, locked cells, and a
  border.
- `board_size() -> Vector2` returns the pixel extent (for HUD layout).

Add the node to `Main` at position `(30, 60)`, set its `owner` to the scene root
so it persists, and `save_scene()`.

(See "How Didi shapes the workflow" #1 for the array-of-lines write pattern.)

---

## Step 3 — Tetromino data (`res://tetris/tetromino.gd`)

`@tool extends RefCounted`, `class_name Tetromino`. Pure static data + helpers:

- `enum Type { I, O, T, S, Z, J, L }`
- `const COLORS := { Type.I: Color(...), ... }` — one signature color per piece.
- `const SHAPES := { Type.I: [ <rot0>, <rot1>, <rot2>, <rot3> ], ... }` — each
  rotation is an `Array` of four `Vector2i` cell offsets (x = right, y = down),
  laid out in the SRS orientations.
- Static helpers: `types()`, `cells(type, rotation)`, `color(type)`,
  `type_name(type)`.

`const` arrays/dicts of `Vector2i`/`Color` are allowed in GDScript, so the whole
table is compile-time constant.

Reference it from the board with `const Tet = preload("res://tetris/tetromino.gd")`
— `preload` resolves at compile time and avoids any `class_name` registration
timing issues.

---

## Step 4 — Active piece + collision (extend `board.gd`)

Add the active falling piece to the board (state: `has_active`, `active_type`,
`active_rot`, `active_pos`) plus the predicate every move/rotation tests against:

```gdscript
## Absolute grid cells a piece state would occupy.
func piece_cells(type: int, rot: int, pos: Vector2i) -> Array:
	var out: Array = []
	for c in Tet.cells(type, rot):
		out.append(Vector2i(pos.x + c.x, pos.y + c.y))
	return out

## True if every cell is in-bounds and not overlapping a locked cell.
func is_valid(type: int, rot: int, pos: Vector2i) -> bool:
	for c in piece_cells(type, rot, pos):
		if c.x < 0 or c.x >= COLS or c.y < 0 or c.y >= ROWS:
			return false
		if grid[c.y][c.x] != null:
			return false
	return true
```

Plus `set_active()`, `clear_active()`, `spawn(type)` (places at top-center
`(3,0)`, returns `false` if it doesn't fit → game over), and `lock_active()`
(writes the piece's cells into `grid` then clears the active piece). `_draw()`
renders the active piece as a highlighted overlay (e.g. `color.lightened(0.4)`
border) over the locked cells.

Because the board is `@tool`, you can verify all of this from Didi directly:
`board.spawn(...)`, then assert `is_valid(...)` is true on-board and false past the
walls/floor or over a locked cell.

> When you rewrite `board.gd`, remember workflow rule #3: write in one call (force
> a fresh load with `CACHE_MODE_REPLACE` and `set_script` the node), then test in
> the **next** call. Calling the new methods in the same call that re-set the
> script errors.

---

## Step 5 — Gravity + input (`res://tetris/game.gd`)

`extends Node2D` — **not** `@tool`, so it runs only in the real game. Attach it to
the `Main` root node. It holds a reference to the board via a lazy getter
(`get_node_or_null("Board")`) so it works whether or not `_ready` has run.

- **Gravity:** `_process(delta)` accumulates time and steps the piece down every
  `fall_interval` seconds (a shorter `soft_drop_interval` while `ui_down` is held).
  When a downward step is invalid, lock and spawn the next piece.
- **Input** (`_unhandled_input`): ←/→ move, ↓ soft-drop, ↑/X rotate CW, Z rotate
  CCW, Space hard-drop. Allow key-echo on ←/→ (auto-repeat); ignore echo on rotate
  and hard-drop.
- **Move/rotate** are thin wrappers: compute the candidate `(rot,pos)`, call
  `board.is_valid(...)`, and `board.set_active(...)` if it passes. Rotation tries a
  few horizontal kick offsets (`[0, -1, 1, -2, 2]`) so it doesn't fail flush
  against a wall.
- **Spawn next:** pick a random `Type`; if `board.spawn(type)` returns `false`,
  set game-over.

Verify by mirroring the move/rotate/hard-drop loop against the `@tool` board in a
`run_gdscript` call (proves the algorithms), then **run the game (F5)** to confirm
the input and gravity wiring.

### Controls

| Key | Action |
|-----|--------|
| ← / → | Move left / right |
| ↓ | Soft drop (faster fall while held) |
| ↑ or X | Rotate clockwise |
| Z | Rotate counter-clockwise |
| Space | Hard drop |
| C or Shift | Hold / swap |
| P or Esc | Pause |
| Enter or R | Restart (after game over) |

---

## Step 6 — Line clearing (extend `board.gd`, call it from `game.gd`)

Add `clear_lines()` to the board: scan every row, keep the non-full ones in
order, count the full ones, then prepend that many fresh empty rows so the stack
collapses downward. Return the count.

```gdscript
func clear_lines() -> int:
	var kept: Array = []
	var cleared := 0
	for y in range(ROWS):
		var full := true
		for x in range(COLS):
			if grid[y][x] == null:
				full = false
				break
		if full:
			cleared += 1
		else:
			kept.append(grid[y])
	while kept.size() < ROWS:
		var row: Array = []
		for x in range(COLS):
			row.append(null)
		kept.push_front(row)
	grid = kept
	queue_redraw()
	return cleared
```

Then call it from the controller right after locking and before spawning the
next piece, accumulating the total (for the upcoming HUD):

```gdscript
b.lock_active()
lines += b.clear_lines()
_spawn_next()
```

Since the board is `@tool`, test it directly: fill the bottom rows, drop a marker
cell above them, call `clear_lines()`, then assert the returned count and that the
marker collapsed downward by that many rows.

> Editing an existing file: read it with `FileAccess.get_file_as_string`, append
> a method (or `String.replace` a known snippet), and write it back — guarding
> with an `if "clear_lines" in src` check so re-running is idempotent. Reload and
> test in the next call (workflow rule #3).

---

## Step 7 — Scoring + HUD

**HUD nodes (built into the scene).** Add a `HUD` node under `Main` with `Label`
children for the SCORE/LEVEL/LINES captions and values, plus a hidden `GameOver`
banner. Position them in the column to the right of the board (x ≈ 350). Set each
label's `owner` to the scene root so they persist, then `save_scene()`. Style with
`add_theme_font_size_override("font_size", n)` and
`add_theme_color_override("font_color", color)`. They render in the editor, so you
can preview the layout by setting their `text` directly.

**Controller scoring.** In `game.gd`, track `score`, `level`, `lines`. On a line
clear, award `LINE_POINTS[n] * level` where `LINE_POINTS = [0, 100, 300, 500,
800]` (single/double/triple/Tetris), bump `lines`, recompute `level = lines / 10 +
1`, and refresh the labels:

```gdscript
const LINE_POINTS := [0, 100, 300, 500, 800]

func _add_lines(n: int) -> void:
	score += LINE_POINTS[clampi(n, 0, 4)] * level
	lines += n
	level = lines / 10 + 1
	_update_hud()

func _update_hud() -> void:
	var s = get_node_or_null("HUD/ScoreValue")
	if s:
		s.text = str(score)
	# ...same for LevelValue, LinesValue
```

**Level-based gravity.** Replace the fixed fall interval with one that shortens as
the level rises (floored so it stays playable):

```gdscript
func _gravity_interval() -> float:
	return max(0.08, base_fall_interval - float(level - 1) * 0.06)
```

`_process` uses `_gravity_interval()` normally and the shorter `soft_drop_interval`
while `ui_down` is held. On game over, reveal the `GameOver` label.

Verify from Didi by previewing label text and by mirroring the scoring/gravity
formulas (the controller itself only runs under F5).

---

## Step 8 — Next-piece preview + 7-bag

**7-bag randomizer** (in `game.gd`). Instead of independent random picks, deal
from a bag containing one of each piece, shuffled; refill when empty. This
guarantees every 7 spawns contain all 7 pieces — no long droughts or floods.

```gdscript
var _bag: Array = []
var _next_type: int = -1

func _refill_bag() -> void:
	_bag = Tet.types()
	_bag.shuffle()

func _draw_from_bag() -> int:
	if _bag.is_empty():
		_refill_bag()
	return _bag.pop_back()
```

Keep one piece of lookahead in `_next_type`: seed it once in `_ready`
(`_next_type = _draw_from_bag()`), then in `_spawn_next()` spawn `_next_type`,
refill it with the next draw, and update the preview before spawning.

**Preview node** (`res://tetris/preview.gd`, `@tool extends Node2D`). A small box
that draws one piece (rotation 0) in its signature color via `set_piece(type)` +
`queue_redraw()`. Add a `NextPreview` instance and a "NEXT" caption `Label` under
the `HUD` node, below LINES. `game.gd._update_preview()` finds it
(`get_node_or_null("HUD/NextPreview")`) and calls `set_piece(_next_type)`.

Verify the bag from Didi by mirroring it: draw 14 times and assert each
consecutive group of 7 is a full permutation of the seven pieces. The preview node
is `@tool`, so you can call `set_piece(...)` on it directly to see it render in the
editor.

---

## Step 9 — Restart after game over

Let the player restart without relaunching. In `_unhandled_input`, check the key
event first, then branch on `_game_over`: while game over, only Enter / keypad
Enter / R do anything — they call `_restart()` — and all other input is ignored.

```gdscript
func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	var k = event.keycode
	if _game_over:
		if k == KEY_ENTER or k == KEY_KP_ENTER or k == KEY_R:
			_restart()
		return
	# ...normal controls

func _restart() -> void:
	var b = _get_board()
	if b == null:
		return
	b._init_grid()
	b.clear_active()
	score = 0
	level = 1
	lines = 0
	_fall_accum = 0.0
	_bag = []
	_next_type = -1
	_game_over = false
	_set_game_over_visible(false)
	_update_hud()
	_next_type = _draw_from_bag()
	_spawn_next()
```

`_restart()` is essentially the runtime part of `_ready` — it re-initializes the
board grid and all controller state and spawns a fresh piece. Update the
`GameOver` banner text to advertise the key (e.g. `"GAME OVER\nPress Enter"`).

## Step 10 — SRS wall kicks

Replace the simple horizontal nudge with the real Super Rotation System kick
tables, so rotations near walls, the floor, and against the stack behave correctly
(and T-spins become possible).

This works **only because the `SHAPES` table already uses SRS orientations** — the
JLSTZ pieces in a 3×3 box and I in a 4×4 box, rotating about the SRS centers. With
that, the published kick tables apply directly; just negate each offset's y for
the y-down grid.

Add to `tetromino.gd` two tables keyed `"from:to"` (rotation indices `0,1,2,3` =
`0,R,2,L`) — `KICKS_JLSTZ` and `KICKS_I` — plus:

```gdscript
static func kicks(type: int, from_rot: int, to_rot: int) -> Array:
	if type == Type.O:
		return [Vector2i(0, 0)]
	var table = KICKS_I if type == Type.I else KICKS_JLSTZ
	var key = "%d:%d" % [from_rot, to_rot]
	return table.get(key, [Vector2i(0, 0)])
```

Each list's first candidate is `(0,0)` (no kick); the rest are the SRS rescues.
Then point `game.gd._try_rotate` at it — try each candidate offset against
`board.is_valid` and accept the first that fits:

```gdscript
var from_rot = b.active_rot
var nr = (from_rot + dir + 4) % 4
for kick in Tet.kicks(b.active_type, from_rot, nr):
	var np = b.active_pos + kick
	if b.is_valid(b.active_type, nr, np):
		b.set_active(b.active_type, nr, np)
		return true
return false
```

Verify by mirroring against the `@tool` board: place a vertical I flush against the
left wall, rotate to horizontal — the `(0,0)` test fails and the table's `(2,0)`
kick should rescue it, landing the bar against the wall.

---

## Step 11 — Hold piece

Let the player stash the current piece and swap it back later, with the standard
"one hold per drop" rule.

Add `_hold_type` and `_hold_used` to `game.gd`, plus a `HoldPreview` box + "HOLD"
caption in the HUD (reuse `preview.gd`). Refactor spawning so a specific piece can
be spawned without consuming the queue:

```gdscript
func _spawn_type(type: int) -> void:   # spawn one piece; handles game over
	var b = _get_board()
	if b and not b.spawn(type):
		_game_over = true
		_set_game_over_visible(true)

func _spawn_next() -> void:             # pull from the queue; new drop
	var type = _next_type if _next_type >= 0 else _draw_from_bag()
	_next_type = _draw_from_bag()
	_update_preview()
	_hold_used = false                  # a fresh piece re-enables hold
	_spawn_type(type)

func _hold() -> void:
	var b = _get_board()
	if b == null or not b.has_active or _hold_used:
		return
	var cur = b.active_type
	b.clear_active()
	if _hold_type < 0:
		_hold_type = cur
		_spawn_next()                   # empty hold: stash, take from queue
	else:
		var swap = _hold_type
		_hold_type = cur
		_spawn_type(swap)               # filled hold: swap, don't touch queue
	_hold_used = true
	_update_hold()
```

Bind it to C / Shift in `_unhandled_input` (ignore key echo), and reset
`_hold_type`/`_hold_used` in `_restart()`. `_hold_used` is the key invariant: set
on hold, cleared only when a piece arrives from the queue (`_spawn_next`), so you
can't hold twice for the same piece.

Verify by mirroring the state machine against the `@tool` board: spawn → hold
(empty) stashes and pulls the next → second hold is blocked → after a new drop,
hold swaps the stashed piece back in.

---

## Step 12 — Ghost piece, sound, pause

**Ghost piece** (board-only). Add `ghost_pos()` — step the active piece straight
down while `is_valid` holds — and in `_draw()` render the piece at that landing
spot with a translucent fill (`color.a = 0.20`) before drawing the real piece.

```gdscript
func ghost_pos() -> Vector2i:
	var p := active_pos
	while is_valid(active_type, active_rot, p + Vector2i(0, 1)):
		p += Vector2i(0, 1)
	return p
```

**Sound** (no asset files). A `sfx.gd` (`AudioStreamPlayer`) synthesizes short WAV
tones at runtime and plays them by name. Build each tone as an `AudioStreamWAV`
(`FORMAT_16_BITS`) by filling a `PackedByteArray` with enveloped sine samples
(`data.encode_u16(i * 2, sample)`); sweep the frequency for the clear/game-over
cues. Add an `Sfx` node under `Main`; `game.gd._play(name)` calls
`Sfx.play_sfx(name)` on move/rotate/lock/clear/hold/game-over.

```gdscript
func _sweep(f0: float, f1: float, dur: float, amp: float) -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / float(n)
		phase += TAU * lerp(f0, f1, t) / float(rate)
		var env := 1.0 if (t >= 0.1 and t <= 0.9) else (t / 0.1 if t < 0.1 else (1.0 - t) / 0.1)
		var s := clampi(int(sin(phase) * amp * env * 32767.0), -32768, 32767)
		data.encode_u16(i * 2, s if s >= 0 else s + 65536)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = data
	return w
```

**Pause.** Toggle `get_tree().paused` on P / Esc and show a `Paused` banner. The
catch: a paused node normally stops receiving input, so it can't unpause itself —
set the controller's `process_mode = PROCESS_MODE_ALWAYS` in `_ready`, guard
`_process` with `if get_tree().paused: return`, and in `_unhandled_input` handle
the pause key first, then `return` early while paused so gameplay keys are
ignored. Clear the pause in `_restart()`.

Ghost is testable from Didi (board is `@tool`): spawn a piece and assert
`ghost_pos().y > active_pos.y`. Sound and pause only run under F5; de-risk the
audio API by synthesizing one tone in a `run_gdscript` call and checking the
resulting `AudioStreamWAV.data` length (`samples * 2`).

---

## Remaining work

- **Optional extras**: lock delay, DAS/ARR tuning, background music, a settings or
  high-score screen. The core game is complete.
