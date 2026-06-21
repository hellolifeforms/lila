## Simple cube-based 3D entity renderer.
## Each entity type gets a single BoxMesh (cube) with type-appropriate color
## harmonized with the browser renderer palette.
class_name Renderer
extends Node


# ── Color palette (mirrored from browser constants.js) ─────────────────

const C_BG: Color = Color(0.059, 0.063, 0.059)
const C_DEER: Color = Color(0.769, 0.584, 0.416)
const C_WOLF: Color = Color(0.45, 0.45, 0.45)
const C_BIRD: Color = Color(0.541, 0.482, 0.420)
const C_BUTTERFLY: Color = Color(0.659, 0.486, 0.769)
const C_TREE: Color = Color(0.239, 0.420, 0.239)
const C_GRASS: Color = Color(0.420, 0.561, 0.369)
const C_GRASS_WILT: Color = Color(0.478, 0.447, 0.329)
const C_WILDFLOWER: Color = Color(0.478, 0.561, 0.369)
const C_MUSHROOM: Color = Color(0.627, 0.549, 0.471)

const C_MOISTURE_DRY: Color = Color(0.400, 0.345, 0.235)
const C_MOISTURE_MID: Color = Color(0.263, 0.275, 0.235)
const C_MOISTURE_WET: Color = Color(0.188, 0.227, 0.204)
const C_WATER: Color = Color(0.15, 0.35, 0.55)

# ── Entity cube sizes ──────────────────────────────────────────────────

const SIZE_TREE: float = 3.0
const SIZE_ANIMAL: float = 1.5
const SIZE_BIRD: float = 1.0
const SIZE_INSECT: float = 0.7
const SIZE_PLANT: float = 0.8
const SIZE_MICRO: float = 0.5

# ── Instance tracking ──────────────────────────────────────────────────

## Map of entity type → MultiMeshInstance3D node.
var _type_meshes: Dictionary = {}
## Water source mesh map: source key → MeshInstance3D.
# ── Public API ─────────────────────────────────────────────────────────

## Build simple BoxMesh cubes for all entity types (call once in _ready).
static func build_all_type_meshes() -> Dictionary:
	var meshes: Dictionary = {}
	for key in ["TREE", "ANIMAL", "BIRD", "INSECT", "PLANT_GRASS", "PLANT_FLOWER", "MICROORGANISM"]:
		meshes[key] = BoxMesh.new()
	return meshes


## Shader material that reads per-instance custom data as color.
## Uses INSTANCE_CUSTOM instead of INSTANCE_COLOR (broken in Godot 4.7).
static func _make_vertex_color_material() -> ShaderMaterial:
	var shader: Shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_always;

void vertex() {
    COLOR = INSTANCE_CUSTOM;
}

void fragment() {
    ALBEDO = COLOR.rgb;
    ALPHA = COLOR.a;
    ROUGHNESS = 0.85;
    METALLIC = 0.0;
}
"""
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	return mat


## Material for ground voxels: reads INSTANCE_CUSTOM for per-cell color.
static func make_ground_material() -> ShaderMaterial:
	var shader: Shader = Shader.new()
	shader.code = """
shader_type spatial;

void vertex() {
    COLOR = INSTANCE_CUSTOM;
}

void fragment() {
    ALBEDO = COLOR.rgb;
    ROUGHNESS = 0.9;
    METALLIC = 0.0;
}
"""
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	return mat


## Material for particle MultiMesh: reads INSTANCE_CUSTOM, unshaded for glow effect.
static func make_particle_material() -> ShaderMaterial:
	var shader: Shader = Shader.new()
	shader.code = """
shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_always, unshaded;

void vertex() {
    COLOR = INSTANCE_CUSTOM;
}

void fragment() {
    ALBEDO = COLOR.rgb;
    ALPHA = COLOR.a;
}
"""
	var mat: ShaderMaterial = ShaderMaterial.new()
	mat.shader = shader
	return mat


## Set up MultiMeshInstance3D nodes inside a parent Node3D.
## Returns map type → MultiMeshInstance3D.
static func setup_type_meshes(parent: Node3D, meshes: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for type_name: String in meshes:
		var mi: Node3D = MultiMeshInstance3D.new()
		mi.name = "Instances_%s" % type_name
		mi.layers = 1

		var mm: MultiMesh = MultiMesh.new()
		mm.mesh = meshes[type_name]
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.instance_count = 0

		mi.multimesh = mm
		mi.material_override = _make_vertex_color_material()
		parent.add_child(mi)
		result[type_name] = mi
	return result


## Update all MultiMeshInstance3D instances for the current entity set.
## Sorts entities by type, then populates transforms + colors.
static func update_entities(
	type_meshes: Dictionary,
	entities: Array,
	face_dir: bool = true,
) -> void:
	# Bucket entities by mesh key
	var buckets: Dictionary = {}
	for type_name in type_meshes:
		buckets[type_name] = []

	for ent in entities:
		var key: String = _entity_to_mesh_key(ent)
		if key and buckets.has(key):
			buckets[key].append(ent)

	# Also handle state-based color tinting
	var tick_ms: float = float(Time.get_ticks_msec())

	for key: String in buckets:
		var mi: Node3D = type_meshes[key]
		if mi == null:
			continue
		var list: Array = buckets[key]
		var mm: MultiMesh = mi.multimesh
		if mm == null:
			continue
		mm.instance_count = list.size()

		for i in list.size():
			var ent = list[i]
			var color: Color = _get_entity_color(ent)
			var size: float = _get_entity_size(ent)
			var transform: Transform3D = _build_entity_transform(ent, size, tick_ms)

			# Dormant / wilted entities darker
			if ent.state == "DORMANT" or ent.state == "DEAD":
				color = color.darkened(0.55)

			# Wilted plants shift color
			var sv: Dictionary = ent.drive
			if ent.type == "PLANT" and sv.get("hydration", 1.0) < 0.25:
				color = C_GRASS_WILT

			mm.set_instance_transform(i, transform)
			mm.set_instance_custom_data(i, color)



## Build ground as MultiMesh of 1x1x1 BoxMesh voxels (one per grid cell).
## Each voxel sits at (gx, 0, gz) with top face at y=0.5.
## Cells inside a water source get water color blended by water_level.
static func build_ground_voxels(
	moisture_grid: PackedFloat32Array,
	water_sources: Array,
) -> MultiMesh:
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)

	var mm: MultiMesh = MultiMesh.new()
	mm.mesh = box
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true

	var size: int = LilaConstants.GRID_SIZE
	mm.instance_count = size * size

	var i: int = 0
	for gz in size:
		for gx in size:
			var idx: int = gx + gz * size
			var moisture: float = 0.5
			if idx < moisture_grid.size():
				moisture = moisture_grid[idx]

			# Check if this cell falls inside any water source
			var color: Color = _moisture_color(moisture)
			var cell_pos: Vector2 = Vector2(float(gx), float(gz))
			for src: Dictionary in water_sources:
				var src_pos: Vector2 = src.position
				var radius: float = src.get("radius", 3.0)
				var level: float = src.get("water_level", 1.0)
				if level < 0.02:
					continue
				var dist: float = cell_pos.distance_to(src_pos)
				if dist <= radius:
					# Blend toward water color; closer = more water
					var blend: float = (1.0 - dist / radius) * level
					color = color.lerp(C_WATER, blend)
					break  # first (closest) match wins; sources rarely overlap

			var t: Transform3D
			t.origin = Vector3(float(gx), 0.0, float(gz))
			t.basis = Basis.IDENTITY

			mm.set_instance_transform(i, t)
			mm.set_instance_custom_data(i, color)
			i += 1

	return mm


## Build particle mesh (small spheres/boxes).
static func build_particle_mesh() -> Mesh:
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(0.3, 0.3, 0.3)
	return box



# ── Color helpers ────────────────────────────────────────────────────────

static func _moisture_color(moisture: float) -> Color:
	if moisture < 0.33:
		return C_MOISTURE_DRY
	elif moisture < 0.66:
		return C_MOISTURE_MID
	else:
		return C_MOISTURE_WET


static func _get_entity_color(ent) -> Color:
	var species: String = ent.species
	match ent.type:
		"ANIMAL":
			if species == "wolf":
				return C_WOLF
			return C_DEER
		"BIRD":
			return C_BIRD
		"INSECT":
			return C_BUTTERFLY
		"TREE":
			return C_TREE
		"PLANT":
			if species == "wildflower":
				return C_WILDFLOWER
			return C_GRASS
		"MICROORGANISM":
			return C_MUSHROOM
	return Color(0.5, 0.5, 0.5)


static func _get_entity_size(ent) -> float:
	match ent.type:
		"TREE":
			return SIZE_TREE
		"ANIMAL":
			return SIZE_ANIMAL
		"BIRD":
			return SIZE_BIRD
		"INSECT":
			return SIZE_INSECT
		"PLANT":
			return SIZE_PLANT
		"MICROORGANISM":
			return SIZE_MICRO
	return 1.0


static func _entity_to_mesh_key(ent) -> String:
	match ent.type:
		"TREE":
			return "TREE"
		"ANIMAL":
			return "ANIMAL"
		"BIRD":
			return "BIRD"
		"INSECT":
			return "INSECT"
		"PLANT":
			if ent.species == "wildflower":
				return "PLANT_FLOWER"
			return "PLANT_GRASS"
		"MICROORGANISM":
			return "MICROORGANISM"
	return ""


static func _build_entity_transform(ent, size: float, tick_ms: float) -> Transform3D:
	var cx: float = ent.x
	var cz: float = ent.z
	var cy: float = 0.5
	var y_extra: float = 0.0

	# Insects float above ground
	if ent.type == "INSECT":
		y_extra = 2.5 + sin(tick_ms / 300.0 + float(ent.sync_phase)) * 0.8
		cy += y_extra

	# Birds fly higher
	if ent.type == "BIRD":
		y_extra = 3.5 + sin(tick_ms / 400.0 + float(ent.sync_phase)) * 0.5
		cy += y_extra

	# Trees grow taller with growth state_var
	var sv: Dictionary = ent.drive
	if ent.type == "TREE":
		var growth: float = sv.get("growth", 0.5)
		cy = 0.0  # trunk rooted at ground
		size = SIZE_TREE * (0.5 + growth * 0.5)  # scale by growth

	# Plants scale by growth
	if ent.type == "PLANT":
		var growth: float = sv.get("growth", 0.3)
		size = SIZE_PLANT * (0.3 + growth * 0.7)

	# Mushroom size by activity
	if ent.type == "MICROORGANISM":
		var activity: float = sv.get("activity", 0.5)
		size = SIZE_MICRO * (0.3 + activity * 0.7)

	# Resting animals are smaller (crouched)
	if ent.type == "ANIMAL" and ent.state == "RESTING":
		size *= 0.75

	# Facing direction
	var angle: float = ent.facing_angle

	# Build transform
	var t: Transform3D
	t.origin = Vector3(cx, cy, cz)

	# Rotate around Y axis to face direction, scale uniformly
	var rot: Basis = Basis.from_euler(Vector3(0.0, -angle + PI / 2.0, 0.0))
	var sc: float = size * 0.6  # normalize to world units
	t.basis = rot * Basis.from_scale(Vector3(sc, sc, sc))

	return t


