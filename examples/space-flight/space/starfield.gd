@tool
extends Node3D
class_name Starfield

## Unlit star points on a large sphere that follows the camera position
## (not rotation) at runtime, giving distant parallax-free stars.

@export var star_count: int = 1500
@export var radius: float = 1800.0
@export var star_seed: int = 99

func _ready() -> void:
	_build()

func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var cam := get_viewport().get_camera_3d()
	if cam:
		global_position = cam.global_position

func _build() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
	var rng := RandomNumberGenerator.new()
	rng.seed = star_seed
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_POINTS)
	for i in range(star_count):
		var dir := Vector3(rng.randfn(), rng.randfn(), rng.randfn())
		if dir.length() < 0.001:
			dir = Vector3.UP
		dir = dir.normalized()
		var b := rng.randf_range(0.45, 1.0)
		var tint := rng.randf()
		var col := Color(b, b, b)
		if tint > 0.85:
			col = Color(b * 0.8, b * 0.9, b)
		elif tint < 0.15:
			col = Color(b, b * 0.92, b * 0.78)
		st.set_color(col)
		st.add_vertex(dir * radius)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.name = "Stars"
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.use_point_size = true
	mat.point_size = 2.0
	mat.disable_receive_shadows = true
	mi.material_override = mat
	mi.extra_cull_margin = radius
	add_child(mi)
