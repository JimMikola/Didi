extends Node

## Procedural sound (runtime WAV synthesis, no asset files). Polls the ship:
## looping engine hum scaled by throttle, plus impact / low-hull / boom one-shots.

var ship
var _engine: AudioStreamPlayer
var _sfx: AudioStreamPlayer
var _impact: AudioStreamWAV
var _warn: AudioStreamWAV
var _boom: AudioStreamWAV
var _prev_shield: float = 0.0
var _prev_hull: float = 0.0
var _was_destroyed: bool = false
var _warn_cd: float = 0.0

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	ship = get_node_or_null("../Ship")
	_engine = AudioStreamPlayer.new()
	add_child(_engine)
	_sfx = AudioStreamPlayer.new()
	add_child(_sfx)
	_engine.stream = _make_engine()
	_engine.volume_db = -36.0
	_engine.play()
	_impact = _make_impact()
	_warn = _make_beep(820.0, 0.12, 0.35)
	_boom = _make_boom()
	if ship:
		_prev_shield = ship.shield
		_prev_hull = ship.hull

func _process(delta: float) -> void:
	if Engine.is_editor_hint() or ship == null:
		return
	var thr: float = absf(ship.throttle)
	_engine.pitch_scale = 0.8 + thr * 0.9
	_engine.volume_db = lerpf(-34.0, -9.0, clampf(thr, 0.0, 1.0))
	var drop: float = (_prev_shield - ship.shield) + (_prev_hull - ship.hull)
	if drop > 0.5:
		_play_oneshot(_impact, clampf(-18.0 + drop, -18.0, 0.0))
	_prev_shield = ship.shield
	_prev_hull = ship.hull
	if ship.destroyed and not _was_destroyed:
		_play_oneshot(_boom, -2.0)
	_was_destroyed = ship.destroyed
	if not ship.destroyed and ship.hull > 0.0 and ship.hull < ship.max_hull * 0.25:
		_warn_cd -= delta
		if _warn_cd <= 0.0:
			_play_oneshot(_warn, -12.0)
			_warn_cd = 1.0
	else:
		_warn_cd = 0.0

func _play_oneshot(stream: AudioStreamWAV, vol_db: float) -> void:
	_sfx.stream = stream
	_sfx.volume_db = vol_db
	_sfx.play()

func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in range(samples.size()):
		var s := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		if s < 0:
			s += 65536
		data.encode_u16(i * 2, s)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = 22050
	w.stereo = false
	w.data = data
	return w

func _make_engine() -> AudioStreamWAV:
	var rate := 22050
	var dur := 0.5
	var n := int(rate * dur)
	var f1 := 35.0 / dur   # 70 Hz, whole cycles -> seamless loop
	var f2 := f1 * 2.0
	var samples := PackedFloat32Array()
	samples.resize(n)
	for i in range(n):
		var t := float(i) / float(rate)
		samples[i] = (sin(TAU * f1 * t) * 0.6 + sin(TAU * f2 * t) * 0.25) * 0.5
	var w := _wav(samples)
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w

func _make_impact() -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * 0.18)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var samples := PackedFloat32Array()
	samples.resize(n)
	for i in range(n):
		var t := float(i) / float(n)
		var env := pow(1.0 - t, 2.0)
		var tone := sin(TAU * lerpf(180.0, 60.0, t) * (float(i) / float(rate)))
		samples[i] = clampf((tone * 0.6 + rng.randf_range(-1.0, 1.0) * 0.5) * env, -1.0, 1.0)
	return _wav(samples)

func _make_beep(freq: float, dur: float, amp: float) -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * dur)
	var samples := PackedFloat32Array()
	samples.resize(n)
	for i in range(n):
		var t := float(i) / float(n)
		var env := 1.0 if (t > 0.1 and t < 0.9) else (t / 0.1 if t < 0.1 else (1.0 - t) / 0.1)
		samples[i] = sin(TAU * freq * (float(i) / float(rate))) * amp * env
	return _wav(samples)

func _make_boom() -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * 0.7)
	var rng := RandomNumberGenerator.new()
	rng.seed = 13
	var samples := PackedFloat32Array()
	samples.resize(n)
	for i in range(n):
		var t := float(i) / float(n)
		var env := pow(1.0 - t, 1.5)
		var tone := sin(TAU * lerpf(120.0, 30.0, t) * (float(i) / float(rate)))
		samples[i] = clampf((tone * 0.5 + rng.randf_range(-1.0, 1.0) * 0.7) * env, -1.0, 1.0)
	return _wav(samples)
