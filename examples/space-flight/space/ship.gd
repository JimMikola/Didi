extends CharacterBody3D

## Newtonian 6DOF flight + survival systems (shields, hull, collision damage).
## Mouse = pitch/yaw (inertial), A/D = roll, W/S = throttle (-20%..100%),
## Z = flight-assist, Esc = free mouse, Enter/R = restart when destroyed.

@export var max_thrust: float = 30.0
@export var min_throttle: float = -0.2
@export var throttle_rate: float = 0.8
@export var assist_linear_damp: float = 1.5
@export var pitch_yaw_accel: float = 0.012
@export var roll_accel: float = 3.0
@export var max_ang_rate: float = 2.6
@export var angular_assist_damp: float = 3.0

@export_group("Systems")
@export var max_shield: float = 100.0
@export var max_hull: float = 100.0
@export var shield_recharge_rate: float = 12.0
@export var shield_recharge_delay: float = 3.0
@export var collision_damage: float = 2.5    # damage per unit of closing speed
@export var bounce: float = 0.4
@export var max_fuel: float = 100.0
@export var fuel_burn_rate: float = 9.0     # units/sec at full throttle
@export var fuel_regen_rate: float = 4.0     # passive regen units/sec

var throttle: float = 0.0
var flight_assist: bool = true
var ang_vel: Vector3 = Vector3.ZERO
var shield: float = 100.0
var hull: float = 100.0
var fuel: float = 100.0
var destroyed: bool = false
var _shield_cd: float = 0.0
var _mouse_delta: Vector2 = Vector2.ZERO

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	shield = max_shield
	hull = max_hull
	fuel = max_fuel
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_mouse_delta += event.relative
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if destroyed:
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER, KEY_R]:
			_restart()
		return
	if event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
	elif event.keycode == KEY_Z:
		flight_assist = not flight_assist
	elif event.keycode == KEY_X:
		throttle = 0.0

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or destroyed:
		return
	if Input.is_key_pressed(KEY_W):
		throttle = minf(1.0, throttle + throttle_rate * delta)
	if Input.is_key_pressed(KEY_S):
		throttle = maxf(min_throttle, throttle - throttle_rate * delta)

	ang_vel.x += -_mouse_delta.y * pitch_yaw_accel
	ang_vel.y += -_mouse_delta.x * pitch_yaw_accel
	_mouse_delta = Vector2.ZERO
	var roll_in := 0.0
	if Input.is_key_pressed(KEY_A):
		roll_in += 1.0
	if Input.is_key_pressed(KEY_D):
		roll_in -= 1.0
	ang_vel.z += roll_in * roll_accel * delta
	if flight_assist:
		ang_vel = ang_vel.lerp(Vector3.ZERO, clampf(angular_assist_damp * delta, 0.0, 1.0))
	ang_vel.x = clampf(ang_vel.x, -max_ang_rate, max_ang_rate)
	ang_vel.y = clampf(ang_vel.y, -max_ang_rate, max_ang_rate)
	ang_vel.z = clampf(ang_vel.z, -max_ang_rate, max_ang_rate)
	rotate_object_local(Vector3.RIGHT, ang_vel.x * delta)
	rotate_object_local(Vector3.UP, ang_vel.y * delta)
	rotate_object_local(Vector3.BACK, ang_vel.z * delta)
	transform = transform.orthonormalized()

	if _shield_cd > 0.0:
		_shield_cd -= delta
	elif shield < max_shield:
		shield = minf(max_shield, shield + shield_recharge_rate * delta)

	fuel = clampf(fuel + (fuel_regen_rate - fuel_burn_rate * absf(throttle)) * delta, 0.0, max_fuel)
	var effective_throttle := throttle if fuel > 0.0 else 0.0
	var forward := -global_transform.basis.z
	velocity += forward * (effective_throttle * max_thrust) * delta
	if flight_assist:
		velocity = velocity.lerp(Vector3.ZERO, clampf(assist_linear_damp * delta, 0.0, 1.0))
	var col := move_and_collide(velocity * delta)
	if col != null:
		_on_collision(col)

func _on_collision(col: KinematicCollision3D) -> void:
	var n := col.get_normal()
	var into := maxf(0.0, -velocity.dot(n))
	_apply_damage(into * collision_damage)
	velocity = velocity.bounce(n) * bounce

func _apply_damage(dmg: float) -> void:
	if dmg <= 0.0:
		return
	_shield_cd = shield_recharge_delay
	if shield >= dmg:
		shield -= dmg
	else:
		hull -= (dmg - shield)
		shield = 0.0
		if hull <= 0.0:
			hull = 0.0
			_destroy()

func _destroy() -> void:
	destroyed = true
	velocity = Vector3.ZERO
	ang_vel = Vector3.ZERO
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _restart() -> void:
	shield = max_shield
	hull = max_hull
	throttle = 0.0
	velocity = Vector3.ZERO
	ang_vel = Vector3.ZERO
	_shield_cd = 0.0
	destroyed = false
	fuel = max_fuel
	transform = Transform3D.IDENTITY
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func get_speed() -> float:
	return velocity.length()
