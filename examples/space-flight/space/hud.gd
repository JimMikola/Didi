extends Control

## Custom-drawn flight HUD: attitude indicator + color-coded bars + readouts.
## Reads the ship at ../../Ship each frame.

var ship

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	ship = get_node_or_null("../../Ship")

func _process(_delta: float) -> void:
	if not Engine.is_editor_hint():
		queue_redraw()

func _draw() -> void:
	if ship == null:
		return
	var font := get_theme_default_font()
	var vp := size
	draw_string(font, Vector2(24, 32), "SPEED  %5.1f" % ship.get_speed(), HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.6, 1.0, 0.8))
	var ac := Color(0.6, 1.0, 0.8) if ship.flight_assist else Color(1.0, 0.7, 0.3)
	draw_string(font, Vector2(24, 56), "ASSIST %s" % ("ON" if ship.flight_assist else "OFF"), HORIZONTAL_ALIGNMENT_LEFT, -1, 18, ac)
	var bx := 24.0
	var bw := 230.0
	var bh := 18.0
	var gap := 42.0
	var by := vp.y - 24.0 - gap * 3.0 - bh
	_bar(font, Rect2(bx, by, bw, bh), ship.throttle * 100.0, -20.0, 100.0, Color(0.3, 0.8, 1.0), "THROTTLE")
	_bar(font, Rect2(bx, by + gap, bw, bh), ship.fuel, 0.0, ship.max_fuel, Color(0.95, 0.7, 0.2), "FUEL")
	_bar(font, Rect2(bx, by + gap * 2.0, bw, bh), ship.shield, 0.0, ship.max_shield, Color(0.3, 0.6, 1.0), "SHIELD")
	_bar(font, Rect2(bx, by + gap * 3.0, bw, bh), ship.hull, 0.0, ship.max_hull, _hull_color(ship.hull / maxf(1.0, ship.max_hull)), "HULL")
	_attitude(font, Vector2(vp.x * 0.5, vp.y - 120.0), 90.0)
	if ship.destroyed:
		draw_string(font, Vector2(vp.x * 0.5 - 240.0, vp.y * 0.5), "DESTROYED  --  press Enter to restart", HORIZONTAL_ALIGNMENT_LEFT, -1, 34, Color(1.0, 0.3, 0.3))

func _bar(font: Font, r: Rect2, value: float, vmin: float, vmax: float, color: Color, label: String) -> void:
	draw_rect(r, Color(0, 0, 0, 0.5), true)
	var frac := clampf((value - vmin) / (vmax - vmin), 0.0, 1.0)
	draw_rect(Rect2(r.position, Vector2(r.size.x * frac, r.size.y)), color, true)
	draw_rect(r, Color(1, 1, 1, 0.3), false, 1.0)
	if vmin < 0.0:
		var zx := r.position.x + r.size.x * (-vmin / (vmax - vmin))
		draw_line(Vector2(zx, r.position.y), Vector2(zx, r.position.y + r.size.y), Color(1, 1, 1, 0.6), 1.0)
	draw_string(font, Vector2(r.position.x, r.position.y - 4.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 0.85, 0.9))
	draw_string(font, Vector2(r.position.x + r.size.x - 46.0, r.position.y + r.size.y - 3.0), "%d" % int(round(value)), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1))

func _hull_color(frac: float) -> Color:
	return Color(0.9, 0.2, 0.2).lerp(Color(0.3, 1.0, 0.45), clampf(frac, 0.0, 1.0))

func _attitude(font: Font, c: Vector2, r: float) -> void:
	draw_arc(c, r, 0.0, TAU, 48, Color(0.7, 0.8, 0.9, 0.7), 2.0)
	var b = ship.global_transform.basis
	var fwd = -b.z
	var rgt = b.x
	var pitch := asin(clampf(fwd.y, -1.0, 1.0))
	var roll := atan2(rgt.y, b.y.y)
	var dir := Vector2(cos(roll), sin(roll))
	var nrm := Vector2(-dir.y, dir.x)
	var hc := c + nrm * (pitch * (r / 1.2))
	# Clip the horizon line to the gauge circle: draw only the chord inside radius r.
	var w := hc - c
	var bcoef := w.dot(dir)
	var disc := bcoef * bcoef - (w.dot(w) - r * r)
	if disc > 0.0:
		var sq := sqrt(disc)
		draw_line(hc + dir * (-bcoef - sq), hc + dir * (-bcoef + sq), Color(0.4, 1.0, 0.6), 2.0)
	draw_line(c + Vector2(-22, 0), c + Vector2(-7, 0), Color(1, 1, 0.4), 2.0)
	draw_line(c + Vector2(7, 0), c + Vector2(22, 0), Color(1, 1, 0.4), 2.0)
	draw_line(c + Vector2(0, -4), c + Vector2(0, 4), Color(1, 1, 0.4), 2.0)
