## Primitive-based 3D entity renderer.
## Each entity type gets its own InstancedMesh with a composite ArrayMesh
## built from basic primitives (capsule, cylinder, sphere, cone).
## Colors harmonized with the browser renderer palette.
extends Node


# ── Color palette (mirrored from browser constants.js) ─────────────────

const C_BG: Color = Color(0.059, 0.063, 0.059)
const C_DEER: Color = Color(0.769, 0.584, 0.416)
const C_DEER_HEAD: Color = Color(0.831, 0.667, 0.478)
const C_BIRD: Color = Color(0.541, 0.482, 0.420)
const C_BIRD_TAIL: Color = Color(0.420, 0.369, 0.322)
const C_BUTTERFLY: Color = Color(0.659, 0.486, 0.769)
const C_BUTTERFLY_BODY: Color = Color(0.478, 0.353, 0.561)
const C_OAK_TRUNK: Color = Color(0.239, 0.420, 0.239)
const C_OAK_CANOPY: Color = Color(0.239, 0.420, 0.239)
const C_GRASS: Color = Color(0.420, 0.561, 0.369)
const C_GRASS_WILT: Color = Color(0.478, 0.447, 0.329)
const C_WILDFLOWER_STEM: Color = Color(0.478, 0.561, 0.369)
const C_FLOWER_BLOOM: Color = Color(0.769, 0.651, 0.290)
const C_MUSHROOM: Color = Color(0.627, 0.549, 0.471)
const C_WATER_DEEP: Color = Color(0.176, 0.333, 0.431)
const C_WATER_SHALLOW: Color = Color(0.216, 0.412, 0.490)
const C_WATER_SHINE: Color = Color(0.275, 0.510, 0.588)

const C_MOISTURE_DRY: Color = Color(0.400, 0.345, 0.235)
const C_MOISTURE_MID: Color = Color(0.263, 0.275, 0.235)
const C_MOISTURE_WET: Color = Color(0.188, 0.227, 0.204)

# ── Entity mesh sizes ──────────────────────────────────────────────────

const SIZE_TREE: float = 3.0
const SIZE_ANIMAL: float = 1.5
const SIZE_BIRD: float = 1.0
const SIZE_INSECT: float = 0.7
const SIZE_PLANT: float = 0.8
const SIZE_MICRO: float = 0.5

# ── Instance tracking ──────────────────────────────────────────────────

## Map of entity type → InstancedMesh node.
var _type_meshes: Dictionary = {}
## Map of entity type → ArrayMesh (composite mesh).
var _type_arrays: Dictionary = {}
## Water source mesh map: source key → MeshInstance3D.
var _water_instances: Dictionary = {}
## Shader material for water (loaded once).
var _water_shader_mat: ShaderMaterial = null
## Shader material for flower bloom pulse.
var _bloom_shader_mat: ShaderMaterial = null

# ── Public API ─────────────────────────────────────────────────────────

## Build composite ArrayMeshes for all entity types (call once in _ready).
static func build_all_type_meshes() -> Dictionary:
	var meshes: Dictionary = {}
	meshes["TREE"] = _build_tree_mesh()
	meshes["ANIMAL"] = _build_animal_mesh()
	meshes["BIRD"] = _build_bird_mesh()
	meshes["INSECT"] = _build_insect_mesh()
	meshes["PLANT_GRASS"] = _build_grass_mesh()
	meshes["PLANT_FLOWER"] = _build_flower_mesh()
	meshes["MICROORGANISM"] = _build_mushroom_mesh()
	return meshes


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
		mm.use_colors = true
		mm.instance_count = 0

		mi.multimesh = mm
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
			mm.set_instance_color(i, color)


## Build water source meshes under a parent Node3D.
static func update_water_sources(
	parent: Node3D,
	world: Node,
	material: Object,
) -> Dictionary:
	var sources: Array = world.water_sources
	var instances: Dictionary = {}

	# Remove old instances no longer in world
	for key: String in instances:
		if not _source_exists(sources, key):
			var old: MeshInstance3D = instances[key]
			if old and is_instance_valid(old):
				old.queue_free()
			instances.erase(key)

	# Build or update
	for src: Dictionary in sources:
		var pos: Vector2 = src.position
		var radius: float = src.get("radius", 3.0)
		var level: float = src.get("water_level", 1.0)
		var key: String = "water_%s_%s" % [pos.x, pos.y]

		if not instances.has(key):
			var mi: MeshInstance3D = _build_water_cylinder(radius, material)
			mi.name = "Water_%s" % key
			mi.layers = 1
			parent.add_child(mi)
			instances[key] = mi

		var mi: MeshInstance3D = instances[key]
		var scale: float = radius * level
		mi.transform.origin = Vector3(pos.x, 0.05, pos.y)
		mi.transform.basis = Basis.from_scale(Vector3(scale, 1.0, scale))

	return instances


## Build ground ArrayMesh from moisture grid.
static func build_ground_mesh(moisture_grid: PackedFloat32Array) -> Mesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var size: int = LilaConstants.GRID_SIZE
	var half: float = 0.48  # slight gap avoids seams

	for gz in size:
		for gx in size:
			var idx: int = gx + gz * size
			var moisture: float = 0.5
			if idx < moisture_grid.size():
				moisture = moisture_grid[idx]

			st.set_color(_moisture_color(moisture))

			var cx: float = float(gx)
			var cz: float = float(gz)
			st.add_vertex(Vector3(cx - half, 0.0, cz - half))
			st.add_vertex(Vector3(cx + half, 0.0, cz - half))
			st.add_vertex(Vector3(cx - half, 0.0, cz + half))
			st.add_vertex(Vector3(cx + half, 0.0, cz - half))
			st.add_vertex(Vector3(cx + half, 0.0, cz + half))
			st.add_vertex(Vector3(cx - half, 0.0, cz + half))

	st.generate_normals()
	return st.commit()


## Build particle mesh (small spheres/boxes).
static func build_particle_mesh() -> Mesh:
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(0.3, 0.3, 0.3)
	return box


# ── Composite mesh builders ───────────────────────────────────────────

## Tree: CylinderMesh trunk + SphereMesh canopy
static func _build_tree_mesh() -> Mesh:
	var am: ArrayMesh = ArrayMesh.new()

	# Trunk — narrow cylinder
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var trunk_h: float = 1.8
	var trunk_r: float = 0.18
	var segments: int = 8
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		var cos0: float = cos(a0)
		var sin0: float = sin(a0)
		var cos1: float = cos(a1)
		var sin1: float = sin(a1)

		# Side ring
		var norm = Vector3(cos0, 0.0, sin0).normalized()
		st.set_normal(norm)
		st.add_vertex(Vector3(cos0 * trunk_r, 0.0, sin0 * trunk_r))
		st.add_vertex(Vector3(cos1 * trunk_r, 0.0, sin1 * trunk_r))
		st.add_vertex(Vector3(cos1 * trunk_r, trunk_h, sin1 * trunk_r))
		st.add_vertex(Vector3(cos0 * trunk_r, 0.0, sin0 * trunk_r))
		st.add_vertex(Vector3(cos1 * trunk_r, trunk_h, sin1 * trunk_r))
		st.add_vertex(Vector3(cos0 * trunk_r, trunk_h, sin0 * trunk_r))

	st.generate_normals()
	
	st.commit(am)

	# Canopy — sphere (larger, offset up)
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var canopy_r: float = 0.75
	var canopy_y: float = trunk_h + 0.4
	var rings: int = 6
	var cols: int = 8
	for r in rings:
		var phi0: float = float(r) / rings * PI
		var phi1: float = float(r + 1) / rings * PI
		for c in cols:
			var theta0: float = float(c) / cols * TAU
			var theta1: float = float(c + 1) / cols * TAU

			var v0 = Vector3(cos(theta0) * sin(phi0), cos(phi0), sin(theta0) * sin(phi0))
			var v1 = Vector3(cos(theta1) * sin(phi0), cos(phi0), sin(theta1) * sin(phi0))
			var v2 = Vector3(cos(theta1) * sin(phi1), cos(phi1), sin(theta1) * sin(phi1))
			var v3 = Vector3(cos(theta0) * sin(phi1), cos(phi1), sin(theta0) * sin(phi1))

			v0 = v0 * canopy_r + Vector3(0.0, canopy_y, 0.0)
			v1 = v1 * canopy_r + Vector3(0.0, canopy_y, 0.0)
			v2 = v2 * canopy_r + Vector3(0.0, canopy_y, 0.0)
			v3 = v3 * canopy_r + Vector3(0.0, canopy_y, 0.0)

			st.add_vertex(v0)
			st.add_vertex(v1)
			st.add_vertex(v2)
			st.add_vertex(v0)
			st.add_vertex(v2)
			st.add_vertex(v3)

	st.generate_normals()
	
	st.commit(am)

	return am


## Deer / Animal: Capsule body + cone snout + small sphere head
static func _build_animal_mesh() -> Mesh:
	var am: ArrayMesh = ArrayMesh.new()

	# Body — capsule-like (cylinder with hemispheres)
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var body_len: float = 0.7
	var body_r: float = 0.25
	var segments: int = 8

	# Central cylinder (along X axis)
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		var cos0: float = cos(a0)
		var sin0: float = sin(a0)
		var cos1: float = cos(a1)
		var sin1: float = sin(a1)

		var norm = Vector3(0.0, cos0, sin0).normalized()
		st.set_normal(norm)
		st.add_vertex(Vector3(-body_len, cos0 * body_r, sin0 * body_r))
		st.add_vertex(Vector3(-body_len, cos1 * body_r, sin1 * body_r))
		st.add_vertex(Vector3(body_len, cos1 * body_r, sin1 * body_r))
		st.add_vertex(Vector3(-body_len, cos0 * body_r, sin0 * body_r))
		st.add_vertex(Vector3(body_len, cos1 * body_r, sin1 * body_r))
		st.add_vertex(Vector3(body_len, cos0 * body_r, sin0 * body_r))

	# Front hemisphere (head area, +X)
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		for j in 4:
			var phi0: float = float(j) / 4 * 0.5 * PI  # 0 to 90°
			var phi1: float = float(j + 1) / 4 * 0.5 * PI
			var cos_a0 = cos(a0)
			var sin_a0 = sin(a0)
			var cos_a1 = cos(a1)
			var sin_a1 = sin(a1)

			var cx: float = body_len + cos(phi0) * body_r * 0.8
			var cy0: float = sin(phi0) * cos_a0 * body_r * 0.8
			var cz0: float = sin(phi0) * sin_a0 * body_r * 0.8
			var cy1: float = sin(phi1) * cos_a1 * body_r * 0.8
			var cz1: float = sin(phi1) * sin_a1 * body_r * 0.8

			st.add_vertex(Vector3(cx, cy0, cz0))
			st.add_vertex(Vector3(body_len + cos(phi1) * body_r * 0.8, cy0, cz0))
			st.add_vertex(Vector3(body_len + cos(phi1) * body_r * 0.8, cy1, cz1))
			st.add_vertex(Vector3(cx, cy0, cz0))
			st.add_vertex(Vector3(body_len + cos(phi1) * body_r * 0.8, cy1, cz1))
			st.add_vertex(Vector3(body_len + cos(phi0) * body_r * 0.8, cy1, cz1))

	st.generate_normals()
	
	st.commit(am)

	# Snout — small cone at front
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var snout_len: float = 0.2
	var snout_r: float = 0.12
	var snut_tip_x: float = body_len + body_r * 0.8 + snout_len
	var snut_base_x: float = body_len + body_r * 0.8
	for i in segments:
		var a: float = float(i) / segments * TAU
		var a2: float = float(i + 1) / segments * TAU
		st.add_vertex(Vector3(snut_tip_x, 0.0, 0.0))
		st.add_vertex(Vector3(snut_base_x, cos(a) * snout_r, sin(a) * snout_r))
		st.add_vertex(Vector3(snut_base_x, cos(a2) * snout_r, sin(a2) * snout_r))

	st.generate_normals()
	
	st.commit(am)

	# Legs — 4 thin cylinders at bottom
	for lx in [-0.4, 0.3]:
		for lz_sign in [-1, 1]:
			st = SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			var leg_h: float = 0.35
			var leg_r: float = 0.06
			var leg_x: float = lx
			var leg_z: float = lz_sign * body_r * 0.6
			for i in 6:
				var a: float = float(i) / 6 * TAU
				var a2: float = float(i + 1) / 6 * TAU
				var n = Vector3(0.0, cos(a), sin(a)).normalized()
				st.set_normal(n)
				st.add_vertex(Vector3(leg_x, 0.0, leg_z + sin(a) * leg_r + cos(a) * leg_r * 0.0))
				# Simplified: just a vertical cylinder
				var vx0: float = leg_x
				var vy0: float = 0.0
				var vz0: float = leg_z + cos(a) * leg_r
				var vz1: float = leg_z + cos(a2) * leg_r
				st.set_normal(Vector3(0.0, cos(a), sin(a)))
				st.add_vertex(Vector3(vx0, vy0, leg_z + cos(a) * leg_r))
				st.add_vertex(Vector3(vx0, vy0, leg_z + cos(a2) * leg_r))
				st.add_vertex(Vector3(vx0, leg_h, leg_z + cos(a2) * leg_r))
				st.add_vertex(Vector3(vx0, vy0, leg_z + cos(a) * leg_r))
				st.add_vertex(Vector3(vx0, leg_h, leg_z + cos(a2) * leg_r))
				st.add_vertex(Vector3(vx0, leg_h, leg_z + cos(a) * leg_r))
			st.generate_normals()
			st.commit(am)

	return am


## Bird: Elongated capsule body + tail cone + wing planes
static func _build_bird_mesh() -> Mesh:
	var am: ArrayMesh = ArrayMesh.new()

	# Body — elongated capsule along X
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var body_len: float = 0.35
	var body_r: float = 0.13
	var segments: int = 6

	# Central cylinder
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		var cos0: float = cos(a0)
		var sin0: float = sin(a0)
		var cos1: float = cos(a1)
		var sin1: float = sin(a1)
		var norm = Vector3(0.0, cos0, sin0).normalized()
		st.set_normal(norm)
		st.add_vertex(Vector3(-body_len, cos0 * body_r, sin0 * body_r))
		st.add_vertex(Vector3(-body_len, cos1 * body_r, sin1 * body_r))
		st.add_vertex(Vector3(body_len, cos1 * body_r, sin1 * body_r))
		st.add_vertex(Vector3(-body_len, cos0 * body_r, sin0 * body_r))
		st.add_vertex(Vector3(body_len, cos1 * body_r, sin1 * body_r))
		st.add_vertex(Vector3(body_len, cos0 * body_r, sin0 * body_r))

	# Nose cone at front (+X)
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		var tip_x: float = body_len + 0.2
		st.add_vertex(Vector3(tip_x, 0.0, 0.0))
		st.add_vertex(Vector3(body_len, cos(a0) * body_r, sin(a0) * body_r))
		st.add_vertex(Vector3(body_len, cos(a1) * body_r, sin(a1) * body_r))

	# Tail cone at back (-X)
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		var tail_tip_x: float = -body_len - 0.2
		st.add_vertex(Vector3(tail_tip_x, 0.0, 0.0))
		st.add_vertex(Vector3(-body_len, cos(a1) * body_r * 0.7, sin(a1) * body_r * 0.7))
		st.add_vertex(Vector3(-body_len, cos(a0) * body_r * 0.7, sin(a0) * body_r * 0.7))

	st.generate_normals()
	
	st.commit(am)

	# Wings — thin flat planes extending upward (will rotate with entity facing)
	# Left wing
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wing_w: float = 0.45
	var wing_d: float = 0.02
	var wing_y: float = 0.1
	st.add_vertex(Vector3(0.0, wing_y, body_r * 0.5))
	st.add_vertex(Vector3(wing_w, wing_y * 0.3, body_r * 0.5))
	st.add_vertex(Vector3(0.0, wing_y, -body_r * 0.5))
	st.add_vertex(Vector3(wing_w, wing_y * 0.3, body_r * 0.5))
	st.add_vertex(Vector3(wing_w, wing_y * 0.3, -body_r * 0.5))
	st.add_vertex(Vector3(0.0, wing_y, -body_r * 0.5))
	st.generate_normals()
	st.commit(am)

	return am


## Butterfly: Body capsule + 2 pairs of wing planes
static func _build_insect_mesh() -> Mesh:
	var am: ArrayMesh = ArrayMesh.new()

	# Body — small capsule along X
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var body_len: float = 0.12
	var body_r: float = 0.06
	var segments: int = 6

	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		var cos0: float = cos(a0)
		var sin0: float = sin(a0)
		var cos1: float = cos(a1)
		var sin1: float = sin(a1)
		var norm = Vector3(0.0, cos0, sin0).normalized()
		st.set_normal(norm)
		st.add_vertex(Vector3(-body_len, cos0 * body_r, sin0 * body_r))
		st.add_vertex(Vector3(-body_len, cos1 * body_r, sin1 * body_r))
		st.add_vertex(Vector3(body_len, cos1 * body_r, sin1 * body_r))
		st.add_vertex(Vector3(-body_len, cos0 * body_r, sin0 * body_r))
		st.add_vertex(Vector3(body_len, cos1 * body_r, sin1 * body_r))
		st.add_vertex(Vector3(body_len, cos0 * body_r, sin0 * body_r))

	# Hemispherical cap at front
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		for j in 3:
			var p0: float = float(j) / 3 * 0.5 * PI
			var p1: float = float(j + 1) / 3 * 0.5 * PI
			var cx: float = body_len + cos(p0) * body_r
			var cy0: float = sin(p0) * cos(a0) * body_r
			var cz0: float = sin(p0) * sin(a0) * body_r
			var cy1: float = sin(p1) * cos(a1) * body_r
			var cz1: float = sin(p1) * sin(a1) * body_r
			st.add_vertex(Vector3(cx, cy0, cz0))
			st.add_vertex(Vector3(body_len + cos(p1) * body_r, cy0, cz0))
			st.add_vertex(Vector3(body_len + cos(p1) * body_r, cy1, cz1))
			st.add_vertex(Vector3(cx, cy0, cz0))
			st.add_vertex(Vector3(body_len + cos(p1) * body_r, cy1, cz1))
			st.add_vertex(Vector3(body_len + cos(p0) * body_r, cy1, cz1))

	st.generate_normals()
	
	st.commit(am)

	# Wings — 4 thin planes (2 pairs, upper + lower)
	for pair in [0, 1]:
		var base_y: float = 0.08 + pair * 0.02
		var wing_span: float = 0.3 - pair * 0.08
		# Upper pair
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.add_vertex(Vector3(0.0, base_y, 0.0))
		st.add_vertex(Vector3(wing_span * 0.6, base_y * 0.4, wing_span * 0.5))
		st.add_vertex(Vector3(-wing_span * 0.3, base_y * 0.6, wing_span * 0.5))
		st.add_vertex(Vector3(0.0, base_y, 0.0))
		st.add_vertex(Vector3(-wing_span * 0.3, base_y * 0.6, wing_span * 0.5))
		st.add_vertex(Vector3(0.0, base_y, wing_span * 0.55))
		st.generate_normals()
		st.commit(am)

		# Lower pair (mirror)
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.add_vertex(Vector3(0.0, -base_y, 0.0))
		st.add_vertex(Vector3(-wing_span * 0.3, -base_y * 0.6, wing_span * 0.5))
		st.add_vertex(Vector3(wing_span * 0.6, -base_y * 0.4, wing_span * 0.5))
		st.add_vertex(Vector3(0.0, -base_y, 0.0))
		st.add_vertex(Vector3(0.0, -base_y, wing_span * 0.55))
		st.add_vertex(Vector3(-wing_span * 0.3, -base_y * 0.6, wing_span * 0.5))
		st.generate_normals()
		st.commit(am)

	return am


## Grass: 3 thin blade planes clustered together
static func _build_grass_mesh() -> Mesh:
	var am: ArrayMesh = ArrayMesh.new()
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var blade_h: float = 0.4
	var blade_w: float = 0.04

	for i in 3:
		var angle: float = float(i) * 2.1
		var ox: float = cos(angle) * 0.12
		var oz: float = sin(angle) * 0.12
		var tilt: float = 0.15 * cos(angle)

		st.add_vertex(Vector3(ox, 0.0, oz))
		st.add_vertex(Vector3(ox + blade_w, 0.0, oz))
		st.add_vertex(Vector3(ox + tilt, blade_h, oz))
		st.add_vertex(Vector3(ox + tilt, blade_h, oz))
		st.add_vertex(Vector3(ox + blade_w, 0.0, oz))
		st.add_vertex(Vector3(ox + blade_w + tilt, blade_h * 0.95, oz))

	st.generate_normals()
	st.commit(am)
	return am


## Wildflower: Stem cylinder + bloom sphere (bloom visible via color override)
static func _build_flower_mesh() -> Mesh:
	var am: ArrayMesh = ArrayMesh.new()

	# Stem — thin cylinder
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stem_h: float = 0.35
	var stem_r: float = 0.04
	var segments: int = 5
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		var cos0: float = cos(a0)
		var sin0: float = sin(a0)
		var cos1: float = cos(a1)
		var sin1: float = sin(a1)
		var norm = Vector3(cos0, 0.0, sin0).normalized()
		st.set_normal(norm)
		st.add_vertex(Vector3(cos0 * stem_r, 0.0, sin0 * stem_r))
		st.add_vertex(Vector3(cos1 * stem_r, 0.0, sin1 * stem_r))
		st.add_vertex(Vector3(cos1 * stem_r, stem_h, sin1 * stem_r))
		st.add_vertex(Vector3(cos0 * stem_r, 0.0, sin0 * stem_r))
		st.add_vertex(Vector3(cos1 * stem_r, stem_h, sin1 * stem_r))
		st.add_vertex(Vector3(cos0 * stem_r, stem_h, sin0 * stem_r))
	st.generate_normals()
	st.commit(am)

	# Bloom — small sphere at top (FRUITING state makes this colorful)
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bloom_r: float = 0.12
	var bloom_y: float = stem_h + 0.02
	var rings: int = 4
	var cols: int = 6
	for r in rings:
		var phi0: float = float(r) / rings * PI
		var phi1: float = float(r + 1) / rings * PI
		for c in cols:
			var theta0: float = float(c) / cols * TAU
			var theta1: float = float(c + 1) / cols * TAU
			var v0 = Vector3(cos(theta0)*sin(phi0), cos(phi0), sin(theta0)*sin(phi0))
			var v1 = Vector3(cos(theta1)*sin(phi0), cos(phi0), sin(theta1)*sin(phi0))
			var v2 = Vector3(cos(theta1)*sin(phi1), cos(phi1), sin(theta1)*sin(phi1))
			var v3 = Vector3(cos(theta0)*sin(phi1), cos(phi1), sin(theta0)*sin(phi1))
			v0 = v0 * bloom_r + Vector3(0.0, bloom_y, 0.0)
			v1 = v1 * bloom_r + Vector3(0.0, bloom_y, 0.0)
			v2 = v2 * bloom_r + Vector3(0.0, bloom_y, 0.0)
			v3 = v3 * bloom_r + Vector3(0.0, bloom_y, 0.0)
			st.add_vertex(v0); st.add_vertex(v1); st.add_vertex(v2)
			st.add_vertex(v0); st.add_vertex(v2); st.add_vertex(v3)
	st.generate_normals()
	st.commit(am)

	return am


## Mushroom: Cap (cylinder top) + stalk
static func _build_mushroom_mesh() -> Mesh:
	var am: ArrayMesh = ArrayMesh.new()

	# Stalk
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stalk_h: float = 0.2
	var stalk_r: float = 0.06
	var segments: int = 6
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		var cos0: float = cos(a0)
		var sin0: float = sin(a0)
		var cos1: float = cos(a1)
		var sin1: float = sin(a1)
		var norm = Vector3(cos0, 0.0, sin0).normalized()
		st.set_normal(norm)
		st.add_vertex(Vector3(cos0 * stalk_r, 0.0, sin0 * stalk_r))
		st.add_vertex(Vector3(cos1 * stalk_r, 0.0, sin1 * stalk_r))
		st.add_vertex(Vector3(cos1 * stalk_r, stalk_h, sin1 * stalk_r))
		st.add_vertex(Vector3(cos0 * stalk_r, 0.0, sin0 * stalk_r))
		st.add_vertex(Vector3(cos1 * stalk_r, stalk_h, sin1 * stalk_r))
		st.add_vertex(Vector3(cos0 * stalk_r, stalk_h, sin0 * stalk_r))
	st.generate_normals()
	st.commit(am)

	# Cap — wider cylinder top (flat, like a dome)
	st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cap_r: float = 0.2
	var cap_y: float = stalk_h - 0.02
	# Top face
	var center: Vector3 = Vector3(0.0, cap_y + 0.06, 0.0)
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		st.set_normal(Vector3.UP)
		st.add_vertex(center)
		st.add_vertex(Vector3(cos(a0) * cap_r, cap_y + 0.06, sin(a0) * cap_r))
		st.add_vertex(Vector3(cos(a1) * cap_r, cap_y + 0.06, sin(a1) * cap_r))

	# Side ring
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		var cos0: float = cos(a0)
		var sin0: float = sin(a0)
		var cos1: float = cos(a1)
		var sin1: float = sin(a1)
		var norm = Vector3(cos0, -0.3, sin0).normalized()
		st.set_normal(norm)
		st.add_vertex(Vector3(cos0 * cap_r, cap_y + 0.06, sin0 * cap_r))
		st.add_vertex(Vector3(cos1 * cap_r, cap_y + 0.06, sin1 * cap_r))
		st.add_vertex(Vector3(cos1 * cap_r, cap_y, sin1 * cap_r))
		st.add_vertex(Vector3(cos0 * cap_r, cap_y + 0.06, sin0 * cap_r))
		st.add_vertex(Vector3(cos1 * cap_r, cap_y, sin1 * cap_r))
		st.add_vertex(Vector3(cos0 * cap_r, cap_y, sin0 * cap_r))

	st.generate_normals()
	st.commit(am)

	return am


## Water pool: flat cylinder
static func _build_water_cylinder(radius: float, material: Object) -> MeshInstance3D:
	var mi: MeshInstance3D = MeshInstance3D.new()

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segments: int = 16
	var center: Vector3 = Vector3.ZERO
	for i in segments:
		var a0: float = float(i) / segments * TAU
		var a1: float = float(i + 1) / segments * TAU
		st.add_vertex(center)
		st.add_vertex(Vector3(cos(a0) * radius, 0.0, sin(a0) * radius))
		st.add_vertex(Vector3(cos(a1) * radius, 0.0, sin(a1) * radius))
	st.generate_normals()

	var mesh: Mesh = st.commit()
	mi.mesh = mesh
	if material:
		mi.set_surface_override_material(0, material)
	mi.transform.basis = Basis.from_scale(Vector3(radius, 1.0, radius))

	return mi


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
				return Color(0.45, 0.45, 0.45)
			return C_DEER
		"BIRD":
			return C_BIRD
		"INSECT":
			return C_BUTTERFLY
		"TREE":
			return C_OAK_TRUNK
		"PLANT":
			if species == "wildflower":
				return C_WILDFLOWER_STEM
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


static func _source_exists(sources: Array, key: String) -> bool:
	for src: Dictionary in sources:
		var pos: Vector2 = src.position
		if "water_%s_%s" % [pos.x, pos.y] == key:
			return true
	return false
