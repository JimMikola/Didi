@tool
extends Node2D
class_name TetrisBoard

## The Tetris playfield: grid model, active piece, ghost, rendering.
## grid[y][x] holds a Color for a locked cell, or null when empty.

const Tet = preload("res://tetris/tetromino.gd")

const COLS := 10
const ROWS := 20
const CELL := 30

const BG_COLOR := Color(0.07, 0.07, 0.10)
const GRID_COLOR := Color(1, 1, 1, 0.06)
const BORDER_COLOR := Color(0.55, 0.55, 0.65)

var grid: Array = []

var has_active: bool = false
var active_type: int = -1
var active_rot: int = 0
var active_pos: Vector2i = Vector2i.ZERO

func _ready() -> void:
	_init_grid()
	queue_redraw()

func _init_grid() -> void:
	grid.clear()
	for y in range(ROWS):
		var row: Array = []
		for x in range(COLS):
			row.append(null)
		grid.append(row)

func board_size() -> Vector2:
	return Vector2(COLS * CELL, ROWS * CELL)

func piece_cells(type: int, rot: int, pos: Vector2i) -> Array:
	var out: Array = []
	for c in Tet.cells(type, rot):
		out.append(Vector2i(pos.x + c.x, pos.y + c.y))
	return out

func is_valid(type: int, rot: int, pos: Vector2i) -> bool:
	for c in piece_cells(type, rot, pos):
		if c.x < 0 or c.x >= COLS or c.y < 0 or c.y >= ROWS:
			return false
		if grid[c.y][c.x] != null:
			return false
	return true

## Lowest valid position straight down from the active piece (the ghost).
func ghost_pos() -> Vector2i:
	var p := active_pos
	while is_valid(active_type, active_rot, p + Vector2i(0, 1)):
		p += Vector2i(0, 1)
	return p

func set_active(type: int, rot: int, pos: Vector2i) -> void:
	active_type = type
	active_rot = rot
	active_pos = pos
	has_active = true
	queue_redraw()

func clear_active() -> void:
	has_active = false
	active_type = -1
	queue_redraw()

func spawn(type: int) -> bool:
	var pos := Vector2i(3, 0)
	if not is_valid(type, 0, pos):
		return false
	set_active(type, 0, pos)
	return true

func lock_active() -> void:
	if not has_active:
		return
	var col := Tet.color(active_type)
	for c in piece_cells(active_type, active_rot, active_pos):
		if c.x >= 0 and c.x < COLS and c.y >= 0 and c.y < ROWS:
			grid[c.y][c.x] = col
	clear_active()

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

func _draw() -> void:
	var w := COLS * CELL
	var h := ROWS * CELL
	draw_rect(Rect2(0, 0, w, h), BG_COLOR, true)
	for x in range(COLS + 1):
		draw_line(Vector2(x * CELL, 0), Vector2(x * CELL, h), GRID_COLOR)
	for y in range(ROWS + 1):
		draw_line(Vector2(0, y * CELL), Vector2(w, y * CELL), GRID_COLOR)
	for y in range(ROWS):
		for x in range(COLS):
			if grid[y][x] != null:
				_draw_cell(x, y, grid[y][x], false)
	if has_active:
		var gp := ghost_pos()
		if gp != active_pos:
			var gcol := Tet.color(active_type)
			gcol.a = 0.20
			for gc in piece_cells(active_type, active_rot, gp):
				if gc.x >= 0 and gc.x < COLS and gc.y >= 0 and gc.y < ROWS:
					draw_rect(Rect2(gc.x * CELL + 1, gc.y * CELL + 1, CELL - 2, CELL - 2), gcol, true)
		var col := Tet.color(active_type)
		for c in piece_cells(active_type, active_rot, active_pos):
			if c.x >= 0 and c.x < COLS and c.y >= 0 and c.y < ROWS:
				_draw_cell(c.x, c.y, col, true)
	draw_rect(Rect2(0, 0, w, h), BORDER_COLOR, false, 2.0)

func _draw_cell(x: int, y: int, color: Color, active: bool) -> void:
	var r := Rect2(x * CELL + 1, y * CELL + 1, CELL - 2, CELL - 2)
	draw_rect(r, color, true)
	if active:
		draw_rect(r, color.lightened(0.4), false, 2.0)
