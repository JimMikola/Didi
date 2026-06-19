extends Node2D

## Tetris controller: gravity, input, scoring, 7-bag, preview, hold, sound,
## pause. Runs only at runtime.

const Tet = preload("res://tetris/tetromino.gd")

@export var base_fall_interval: float = 0.8
@export var soft_drop_interval: float = 0.04

const LINE_POINTS := [0, 100, 300, 500, 800]

var board
var score: int = 0
var level: int = 1
var lines: int = 0
var _fall_accum: float = 0.0
var _game_over: bool = false
var _bag: Array = []
var _next_type: int = -1
var _hold_type: int = -1
var _hold_used: bool = false

func _ready() -> void:
	randomize()
	process_mode = PROCESS_MODE_ALWAYS
	if Engine.is_editor_hint():
		return
	board = _get_board()
	_set_game_over_visible(false)
	_update_hud()
	_update_hold()
	_next_type = _draw_from_bag()
	_spawn_next()

func _get_board():
	if board == null:
		board = get_node_or_null("Board")
	return board

func _gravity_interval() -> float:
	return max(0.08, base_fall_interval - float(level - 1) * 0.06)

func _process(delta: float) -> void:
	if _game_over or get_tree().paused:
		return
	var b = _get_board()
	if b == null or not b.has_active:
		return
	var interval = soft_drop_interval if Input.is_action_pressed("ui_down") else _gravity_interval()
	_fall_accum += delta
	if _fall_accum >= interval:
		_fall_accum = 0.0
		_step_down()

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	var k = event.keycode
	if (k == KEY_P or k == KEY_ESCAPE) and not event.echo:
		_toggle_pause()
		return
	if get_tree().paused:
		return
	if _game_over:
		if k == KEY_ENTER or k == KEY_KP_ENTER or k == KEY_R:
			_restart()
		return
	if k == KEY_LEFT:
		if _try_move(-1, 0): _play("move")
	elif k == KEY_RIGHT:
		if _try_move(1, 0): _play("move")
	elif (k == KEY_UP or k == KEY_X) and not event.echo:
		if _try_rotate(1): _play("rotate")
	elif k == KEY_Z and not event.echo:
		if _try_rotate(-1): _play("rotate")
	elif (k == KEY_C or k == KEY_SHIFT) and not event.echo:
		_hold()
	elif k == KEY_SPACE and not event.echo:
		_hard_drop()

func _try_move(dx: int, dy: int) -> bool:
	var b = _get_board()
	if b == null or not b.has_active:
		return false
	var np = b.active_pos + Vector2i(dx, dy)
	if b.is_valid(b.active_type, b.active_rot, np):
		b.set_active(b.active_type, b.active_rot, np)
		return true
	return false

func _try_rotate(dir: int) -> bool:
	var b = _get_board()
	if b == null or not b.has_active:
		return false
	var from_rot = b.active_rot
	var nr = (from_rot + dir + 4) % 4
	for kick in Tet.kicks(b.active_type, from_rot, nr):
		var np = b.active_pos + kick
		if b.is_valid(b.active_type, nr, np):
			b.set_active(b.active_type, nr, np)
			return true
	return false

func _step_down() -> void:
	if _try_move(0, 1):
		return
	_lock_and_spawn()

func _hard_drop() -> void:
	var b = _get_board()
	if b == null or not b.has_active:
		return
	while _try_move(0, 1):
		pass
	_lock_and_spawn()

func _lock_and_spawn() -> void:
	var b = _get_board()
	if b == null:
		return
	b.lock_active()
	var n = b.clear_lines()
	if n > 0:
		_add_lines(n)
		_play("clear")
	else:
		_play("lock")
	_spawn_next()

func _add_lines(n: int) -> void:
	score += LINE_POINTS[clampi(n, 0, 4)] * level
	lines += n
	level = lines / 10 + 1
	_update_hud()

func _refill_bag() -> void:
	_bag = Tet.types()
	_bag.shuffle()

func _draw_from_bag() -> int:
	if _bag.is_empty():
		_refill_bag()
	return _bag.pop_back()

func _spawn_type(type: int) -> void:
	var b = _get_board()
	if b == null:
		return
	if not b.spawn(type):
		_game_over = true
		_set_game_over_visible(true)
		_play("gameover")
		print("Tetris: GAME OVER  score=", score, " lines=", lines)

func _spawn_next() -> void:
	var type = _next_type
	if type < 0:
		type = _draw_from_bag()
	_next_type = _draw_from_bag()
	_update_preview()
	_hold_used = false
	_spawn_type(type)

func _hold() -> void:
	var b = _get_board()
	if b == null or not b.has_active or _hold_used:
		return
	var cur = b.active_type
	b.clear_active()
	if _hold_type < 0:
		_hold_type = cur
		_spawn_next()
	else:
		var swap = _hold_type
		_hold_type = cur
		_spawn_type(swap)
	_hold_used = true
	_play("hold")
	_update_hold()

func _toggle_pause() -> void:
	if _game_over:
		return
	var p = not get_tree().paused
	get_tree().paused = p
	var lbl = get_node_or_null("HUD/Paused")
	if lbl:
		lbl.visible = p

func _play(name: String) -> void:
	var s = get_node_or_null("Sfx")
	if s:
		s.play_sfx(name)

func _update_hud() -> void:
	var s = get_node_or_null("HUD/ScoreValue")
	if s:
		s.text = str(score)
	var l = get_node_or_null("HUD/LevelValue")
	if l:
		l.text = str(level)
	var nn = get_node_or_null("HUD/LinesValue")
	if nn:
		nn.text = str(lines)

func _update_preview() -> void:
	var p = get_node_or_null("HUD/NextPreview")
	if p:
		p.set_piece(_next_type)

func _update_hold() -> void:
	var p = get_node_or_null("HUD/HoldPreview")
	if p:
		p.set_piece(_hold_type)

func _set_game_over_visible(v: bool) -> void:
	var g = get_node_or_null("HUD/GameOver")
	if g:
		g.visible = v

func _restart() -> void:
	var b = _get_board()
	if b == null:
		return
	get_tree().paused = false
	var pl = get_node_or_null("HUD/Paused")
	if pl:
		pl.visible = false
	b._init_grid()
	b.clear_active()
	score = 0
	level = 1
	lines = 0
	_fall_accum = 0.0
	_bag = []
	_next_type = -1
	_hold_type = -1
	_hold_used = false
	_game_over = false
	_set_game_over_visible(false)
	_update_hud()
	_update_hold()
	_next_type = _draw_from_bag()
	_spawn_next()
