extends Camera3D

## Impact screen shake. Polls the ship for shield/hull drops and jitters the
## camera (and the cockpit parented to it) with decaying trauma.

@export var max_offset: float = 0.22
@export var max_roll: float = 0.05
@export var decay: float = 1.8

var ship
var trauma: float = 0.0
var _prev_shield: float = 0.0
var _prev_hull: float = 0.0

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	ship = get_parent()
	_prev_shield = ship.shield
	_prev_hull = ship.hull

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or ship == null:
		return
	var drop: float = (_prev_shield - ship.shield) + (_prev_hull - ship.hull)
	_prev_shield = ship.shield
	_prev_hull = ship.hull
	if drop > 0.5:
		trauma = clampf(trauma + clampf(drop / 30.0, 0.15, 0.85), 0.0, 1.0)
	trauma = maxf(0.0, trauma - decay * delta)
	var shake: float = trauma * trauma
	position = Vector3(randf_range(-1.0, 1.0) * max_offset * shake, randf_range(-1.0, 1.0) * max_offset * shake, 0.0)
	rotation = Vector3(0.0, 0.0, randf_range(-1.0, 1.0) * max_roll * shake)
