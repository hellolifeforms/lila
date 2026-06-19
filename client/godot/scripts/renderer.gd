## Isometric voxel-style renderer.
## Draws the world as a pseudo-3D isometric grid with colored blocks.
## Swap this file for real 3D later — no simulation code changes needed.
class_name Renderer


## Isometric cell dimensions
const CELL_W: float = 32.0
const CELL_H: float = 16.0
const BLOCK_HEIGHT: float = 10.0

## World offset for centering
var _offset: Vector2 = Vector2.ZERO
var _grid_size: int = LilaConstants.GRID_SIZE


## Convert grid (x, z) to screen position (isometric projection).
static func grid_to_screen(gx: float, gz: float, offset: Vector2 = Vector2.ZERO) -> Vector2:
	var sx: float = (gx - gz) * (CELL_W / 2.0) + offset.x
	var sy: float = (gx + gz) * (CELL_H / 2.0) + offset.y
	return Vector2(sx, sy)


## Draw the moisture heatmap grid.
static func draw_ground(viewport: Viewport, world: Node, offset: Vector2 = Vector2.ZERO) -> void:
	var size: int = LilaConstants.GRID_SIZE
	for gz in size:
		for gx in size:
			var pos: Vector2 = grid_to_screen(float(gx), float(gz), offset)
			var idx: int = gx + gz * size
			var moisture: float = 0.5
			if idx < world.moisture_grid.size():
				moisture = world.moisture_grid[idx]

			# Color from moisture: teal (dry) to amber (wet)
			var color: Color = _moisture_color(moisture)

			# Draw isometric diamond
			var points: PackedVector2Array = PackedVector2Array([
				pos + Vector2(CELL_W / 2.0, 0.0),
				pos + Vector2(CELL_W / 4.0, CELL_H / 2.0),
				pos + Vector2(0.0, 0.0),
				pos + Vector2(-CELL_W / 4.0, -CELL_H / 2.0),
			])
			# Note: Godot 2D doesn't have a simple polygon draw in Viewport,
			# we use draw functions in _draw() callback instead.
			# This is a placeholder — actual drawing happens in main.gd _draw().


## Draw all entities.
static func draw_entities(viewport: Viewport, world: Node, offset: Vector2 = Vector2.ZERO) -> void:
	var entities: Array = world.get_alive()
	# Sort by z for isometric depth ordering
	entities.sort_custom(func(a, b): return a.z < b.z)

	for ent in entities:
		draw_entity(viewport, ent, offset)


## Draw a single entity as a colored block.
static func draw_entity(viewport: Viewport, ent, offset: Vector2 = Vector2.ZERO) -> void:
	var pos: Vector2 = grid_to_screen(ent.x, ent.z, offset)

	# Get color from species or type
	var color: Color = _get_entity_color(ent)
	var size: float = _get_entity_size(ent)

	# Height offset for insects (they "fly")
	var height_offset: float = 0.0
	if ent.type == "INSECT":
		height_offset = -20.0 + sin(Time.get_ticks_msec() / 300.0 + ent.sync_phase) * 5.0

	var block_pos: Vector2 = pos + Vector2(0, height_offset)

	# Draw block (top face)
	var half_w: float = size * CELL_W / 4.0
	var half_h: float = size * CELL_H / 4.0

	# Top face (isometric diamond)
	var top_points: PackedVector2Array = PackedVector2Array([
		block_pos + Vector2(half_w, -BLOCK_HEIGHT),
		block_pos + Vector2(half_w * 0.5, -BLOCK_HEIGHT + half_h * 0.5),
		block_pos + Vector2(0, -BLOCK_HEIGHT),
		block_pos + Vector2(-half_w * 0.5, -BLOCK_HEIGHT - half_h * 0.5),
	])


## Draw water sources.
static func draw_water_sources(viewport: Viewport, world: Node, offset: Vector2 = Vector2.ZERO) -> void:
	for src: Dictionary in world.water_sources:
		var pos: Vector2 = grid_to_screen(src.position.x, src.position.y, offset)
		var radius: float = src.get("radius", 3.0)
		var level: float = src.get("water_level", 1.0)

		# Effective radius based on water level
		var effective_radius: float = radius * CELL_W * level

		# Water color with alpha based on level
		var water_color: Color = Color(0.2, 0.4, 0.8, 0.4 * level)


## Draw particles.
static func draw_particles(viewport: Viewport, particles: Array, offset: Vector2 = Vector2.ZERO) -> void:
	for particle in particles:
		var pos: Vector2 = grid_to_screen(particle.position.x, particle.position.y, offset)
		var color: Color = particle.color
		color.a = particle.life / particle.max_life


## Get entity color from species or type.
static func _get_entity_color(ent) -> Color:
	if ent.species in LilaConstants.SPECIES_COLORS:
		return LilaConstants.SPECIES_COLORS[ent.species]
	if ent.type in LilaConstants.TYPE_COLORS:
		return LilaConstants.TYPE_COLORS[ent.type]
	return Color(0.5, 0.5, 0.5)


## Get entity block size.
static func _get_entity_size(ent) -> float:
	match ent.type:
		"TREE":
			return 3.0
		"ANIMAL":
			return 1.5
		"BIRD":
			return 1.0
		"INSECT":
			return 0.7
		"PLANT":
			return 0.8
		_:
			return 1.0


## Get color for moisture value.
static func _moisture_color(moisture: float) -> Color:
	if moisture < 0.33:
		return Color(0.9, 0.85, 0.7)  # Sandy/dry
	elif moisture < 0.66:
		return Color(0.7, 0.8, 0.6)  # Green/grassy
	else:
		return Color(0.4, 0.7, 0.6)  # Teal/moist
