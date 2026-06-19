@tool
extends Node3D
class_name AsteroidField

## Procedurally scatters asteroids (deformed-sphere StaticBody3D meshes) in a
## shell around the origin, leaving a clear bubble at the ship spawn.

@export var count: int = 70
@export var field_radius: float = 240.0
@export var clear_radius: float = 30.0
@export var min_scale: float = 2.0
@export var max_scale: float = 9.0
@export var rng_seed: int = 1337

const BASE_MESHES := 6

func _ready() -> void:
	generate()

func generate() -> void:
	for c in get_children():
		remove_child(c)
		c.free()
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	var bases: Array = []
	for i in range(BASE_MESHES):
		bases.append(_make_asteroid_mesh(rng))
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.40, 0.38)
	mat.roughness = 1.0
	mat.metallic = 0.0
	for i in range(count):
		var dir := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		if dir.length() < 0.001:
			dir = Vector3.RIGHT
		dir = dir.normalized()
		var r := rng.randf_range(clear_radius, field_radius)
		var body := StaticBody3D.new()
		body.position = dir * r
		body.rotation = Vector3(rng.randf_range(0, TAU), rng.randf_range(0, TAU), rng.randf_range(0, TAU))
		var s := rng.randf_range(min_scale, max_scale)
		body.scale = Vector3(s, s, s)
		var mi := MeshInstance3D.new()
		mi.mesh = bases[rng.randi() % bases.size()]
		mi.material_override = mat
		body.add_child(mi)
		var col := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = 1.1
		col.shape = shape
		body.add_child(col)
		add_child(body)

func _make_asteroid_mesh(rng: RandomNumberGenerator) -> ArrayMesh:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 12
	sphere.rings = 8
	var arrays := sphere.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var noise := FastNoiseLite.new()
	noise.seed = rng.randi()
	var amp := rng.randf_range(0.28, 0.5)
	var deformed := PackedVector3Array()
	for v in verts:
		var n := v.normalized()
		var d := noise.get_noise_3d(n.x * 3.0, n.y * 3.0, n.z * 3.0)
		deformed.append(n * (1.0 + d * amp))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for idx in indices:
		st.add_vertex(deformed[idx])
	st.generate_normals()
	return st.commit()
