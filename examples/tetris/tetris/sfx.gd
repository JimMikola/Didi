extends AudioStreamPlayer

## Generates short WAV tones at runtime (no asset files) and plays them by
## name. game.gd calls play_sfx("rotate"), etc.

var _tones: Dictionary = {}

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_tones["move"] = _tone(300.0, 0.02, 0.10)
	_tones["rotate"] = _tone(480.0, 0.04, 0.20)
	_tones["lock"] = _tone(170.0, 0.06, 0.28)
	_tones["hold"] = _tone(360.0, 0.05, 0.20)
	_tones["clear"] = _sweep(520.0, 880.0, 0.16, 0.30)
	_tones["gameover"] = _sweep(440.0, 140.0, 0.55, 0.30)

func play_sfx(name: String) -> void:
	if _tones.has(name):
		stream = _tones[name]
		play()

func _tone(freq: float, dur: float, amp: float) -> AudioStreamWAV:
	return _sweep(freq, freq, dur, amp)

func _sweep(f0: float, f1: float, dur: float, amp: float) -> AudioStreamWAV:
	var rate := 22050
	var n := int(rate * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var phase := 0.0
	for i in range(n):
		var t := float(i) / float(n)
		var freq: float = lerp(f0, f1, t)
		phase += TAU * freq / float(rate)
		var env := 1.0
		if t < 0.1:
			env = t / 0.1
		elif t > 0.9:
			env = (1.0 - t) / 0.1
		var s := int(sin(phase) * amp * env * 32767.0)
		s = clampi(s, -32768, 32767)
		if s < 0:
			s += 65536
		data.encode_u16(i * 2, s)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w
