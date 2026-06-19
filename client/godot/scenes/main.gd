## Main scene — orchestrates WebSocket, world model, agency, heartbeat, rendering.
extends Node2D


## Isometric rendering constants
const CELL_W: float = 32.0
const CELL_H: float = 16.0
const BLOCK_HEIGHT: float = 10.0


@onready var hud: CanvasLayer = $HUD
@onready var stats_label: Label = $HUD/VBox/StatsLabel
@onready var event_log: RichTextLabel = $HUD/VBox/EventLog
@onready var rain_button: Button = $HUD/VBox/RainButton
@onready var world_view: Node2D = $WorldView

var _agency: Agency = Agency.new()
var _heartbeat: HeartbeatSender = HeartbeatSender.new()
var _particles: RefCounted
var _reconciliation: Reconciliation = Reconciliation.new()

var _world_def: Dictionary = {}
var _session_started: bool = false
var _current_tick: int = 0
var _event_count: int = 0
var _fps: int = 0
var _frame_count: int = 0
var _fps_timer: float = 0.0

## Camera controls
var _camera_offset: Vector2 = Vector2(640, 200)
var _camera_zoom: float = 1.0
var _dragging: bool = false
var _drag_start: Vector2 = Vector2.ZERO
var _drag_offset_start: Vector2 = Vector2.ZERO


func _ready() -> void:
	print("Lila Godot Client starting...")

	# Connect to WebSocket signals
	WS.session_started.connect(_on_session_started)
	WS.tick_packet.connect(_on_tick_packet)
	WS.world_json_ready.connect(_on_world_json_ready)

	# Connect rain button
	rain_button.pressed.connect(_on_rain_pressed)

	# Initialize particle system
	_particles = load("res://scripts/particles.gd").new()

	# Center camera on world
	_camera_offset = Vector2(get_viewport_rect().size.x / 2, 200)


func _on_rain_pressed() -> void:
	WS.send_control("rain", {"intensity": 0.8})
	_add_hud_event("☔ Rain triggered!")


func _on_world_json_ready(data: Dictionary) -> void:
	_world_def = data
	# World JSON is loaded; send it once WS connects
	print("World definition loaded, sending on connect...")


func _process(delta: float) -> void:
	# FPS counter
	_frame_count += 1
	_fps_timer += delta
	if _fps_timer >= 1.0:
		_fps = _frame_count / _fps_timer
		_frame_count = 0
		_fps_timer = 0.0
		_update_stats()

	# Step agency (60 Hz) — WS is an autoload that handles its own _process
	if _session_started:
		var now: float = Time.get_ticks_msec() / 1000.0
		var events: Array = _agency.step(World, delta)

		# Queue events for heartbeat
		for evt: Dictionary in events:
			_heartbeat.queue_event(evt)

		# Step heartbeat sender
		_heartbeat.tick(WS, World, now)

		# Step particles
		_particles.step(delta)

	# Redraw
	queue_redraw()


func _draw() -> void:
	if not _session_started:
		return

	_draw_ground()
	_draw_water_sources()
	_draw_entities()
	_draw_particles()
	_draw_grid_overlay()


func _draw_ground() -> void:
	var size: int = LilaConstants.GRID_SIZE
	var cw: float = CELL_W / 2.0 * _camera_zoom
	var ch: float = CELL_H / 4.0 * _camera_zoom
	for gz in size:
		for gx in size:
			var pos: Vector2 = _grid_to_screen(float(gx), float(gz))

			# Moisture color
			var idx: int = gx + gz * size
			var moisture: float = 0.5
			if idx < World.moisture_grid.size():
				moisture = World.moisture_grid[idx]
			var color: Color = _moisture_color(moisture)

			# Draw isometric diamond
			var pts: PackedVector2Array = PackedVector2Array([
				pos + Vector2(cw, 0.0),
				pos + Vector2(cw * 0.5, ch),
				pos + Vector2(0.0, 0.0),
				pos + Vector2(-cw * 0.5, -ch),
			])
			draw_colored_polygon(pts, color)


func _draw_water_sources() -> void:
	for src: Dictionary in World.water_sources:
		var pos: Vector2 = _grid_to_screen(src.position.x, src.position.y)
		var radius: float = src.get("radius", 3.0)
		var level: float = src.get("water_level", 1.0)

		# Water ellipse (isometric projection of circle)
		var rx: float = radius * CELL_W * level * 0.5
		var ry: float = radius * CELL_H * level * 0.5
		var water_color: Color = Color(0.2, 0.4, 0.8, 0.5 * level)

		draw_circle(pos, rx, water_color)
		# Inner ripple
		var ripple: float = sin(Time.get_ticks_msec() / 500.0) * 0.2 + 0.8
		draw_circle(pos, rx * ripple * 0.7, Color(0.3, 0.6, 1.0, 0.3 * level))


func _draw_entities() -> void:
	var entities: Array = World.get_alive()
	# Sort by isometric depth (x + z)
	entities.sort_custom(func(a, b): return (a.x + a.z) < (b.x + b.z))

	for ent in entities:
		var pos: Vector2 = _grid_to_screen(ent.x, ent.z)
		var color: Color = _get_entity_color(ent)
		var size: float = _get_entity_size(ent)

		# Skip degenerate polygons (zero or negative size after zoom)
		if size * _camera_zoom <= 0.1:
			continue

		# Height offset for insects
		var height_offset: float = 0.0
		if ent.type == "INSECT":
			height_offset = -20.0 + sin(Time.get_ticks_msec() / 300.0 + float(ent.sync_phase)) * 5.0

		var block_pos: Vector2 = pos + Vector2(0, height_offset)
		var half_w: float = size * CELL_W / 4.0 * _camera_zoom
		var half_h: float = size * CELL_H / 4.0 * _camera_zoom
		var block_h: float = BLOCK_HEIGHT * size * _camera_zoom

		# Draw block top face (isometric diamond)
		var top_pts: PackedVector2Array = PackedVector2Array([
			block_pos + Vector2(half_w, -block_h),
			block_pos + Vector2(half_w * 0.5, -block_h + half_h * 0.5),
			block_pos + Vector2(0.0, -block_h),
			block_pos + Vector2(-half_w * 0.5, -block_h - half_h * 0.5),
		])

		# Darken for side effect
		var side_color: Color = color.darkened(0.3)

		# Right side face
		var right_pts: PackedVector2Array = PackedVector2Array([
			block_pos + Vector2(half_w, 0.0),
			block_pos + Vector2(half_w * 0.5, -half_h * 0.5),
			top_pts[1],
			top_pts[0],
		])
		draw_colored_polygon(right_pts, side_color)

		# Left side face
		var left_side_color: Color = color.darkened(0.5)
		var left_pts: PackedVector2Array = PackedVector2Array([
			block_pos + Vector2(-half_w, 0.0),
			block_pos + Vector2(-half_w * 0.5, -half_h * 0.5),
			top_pts[3],
			top_pts[2],
		])
		draw_colored_polygon(left_pts, left_side_color)

		# Top face
		draw_colored_polygon(top_pts, color)

		# Dormant overlay
		if ent.state == "DORMANT":
			draw_colored_polygon(top_pts, Color(0.3, 0.2, 0.15, 0.7))

		# State label for mobile entities
		if ent.type in ["ANIMAL", "BIRD", "INSECT"]:
			var label_pos: Vector2 = block_pos + Vector2(0, -BLOCK_HEIGHT * size - half_h - 5)
			var state_color: Color = LilaConstants.STATE_COLORS.get(ent.state, Color.WHITE)
			draw_string(
				ThemeDB.fallback_font,
				label_pos,
				ent.state,
				1,
				-1,
				10,
				state_color
			)


func _draw_particles() -> void:
	for particle in _particles.get_alive():
		var pos: Vector2 = _grid_to_screen(particle.position.x, particle.position.y)
		var color: Color = particle.color
		color.a = maxf(0.0, particle.life / particle.max_life)
		var radius: float = particle.size * 5.0
		draw_circle(pos, radius, color)


func _draw_grid_overlay() -> void:
	# Draw subtle grid lines at major intervals
	var size: int = LilaConstants.GRID_SIZE
	var step: int = 8
	var grid_color: Color = Color(1.0, 1.0, 1.0, 0.08)

	for i in range(0, size, step):
		# Lines along x
		var p1: Vector2 = _grid_to_screen(float(i), 0.0)
		var p2: Vector2 = _grid_to_screen(float(i), float(size - 1))
		draw_line(p1, p2, grid_color)

		# Lines along z
		var p3: Vector2 = _grid_to_screen(0.0, float(i))
		var p4: Vector2 = _grid_to_screen(float(size - 1), float(i))
		draw_line(p3, p4, grid_color)


## Convert grid (x, z) to screen position (isometric).
func _grid_to_screen(gx: float, gz: float) -> Vector2:
	var sx: float = (gx - gz) * (CELL_W / 2.0) * _camera_zoom + _camera_offset.x
	var sy: float = (gx + gz) * (CELL_H / 2.0) * _camera_zoom + _camera_offset.y
	return Vector2(sx, sy)


## Color for moisture value.
func _moisture_color(moisture: float) -> Color:
	if moisture < 0.33:
		return Color(0.9, 0.85, 0.7)  # Sandy
	elif moisture < 0.66:
		return Color(0.7, 0.8, 0.6)  # Grassy
	else:
		return Color(0.4, 0.7, 0.6)  # Moist teal


## Entity color from species/type.
func _get_entity_color(ent) -> Color:
	if ent.species in LilaConstants.SPECIES_COLORS:
		return LilaConstants.SPECIES_COLORS[ent.species]
	if ent.type in LilaConstants.TYPE_COLORS:
		return LilaConstants.TYPE_COLORS[ent.type]
	return Color(0.5, 0.5, 0.5)


## Entity block size.
func _get_entity_size(ent) -> float:
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


## Update HUD stats.
func _update_stats() -> void:
	stats_label.text = "Tick: %d | Entities: %d | Events: %d | FPS: %d" % [
		_current_tick, World.get_entity_count(), _event_count, _fps
	]


## Add event to HUD log.
func _add_hud_event(text: String) -> void:
	_event_count += 1
	event_log.append_text("[color=ffcc66]%s[/color]\n" % text)
	# Keep last 50 events
	var max_lines: int = 50
	var lines: PackedStringArray = event_log.text.split("\n")
	if lines.size() > max_lines:
		event_log.set_text("\n".join(lines.slice(-max_lines)))


## Handle session_started from server.
func _on_session_started(data: Dictionary) -> void:
	print("Session started: ", data.get("session_id", ""))
	print("Entities: ", data.get("entity_count", 0))

	# Store species definitions
	World.species_defs = data.get("species", {})

	_session_started = true

	# Flush dead entities periodically
	World.flush_dead()


## Handle tick packet from server.
func _on_tick_packet(data: Dictionary) -> void:
	_current_tick = data.get("tick", _current_tick)

	# Apply entity updates
	for update: Dictionary in data.get("entity_updates", []):
		World.apply_update(update)

	# Apply spawns
	for spawn: Dictionary in data.get("entity_spawns", []):
		World.apply_spawn(spawn)

	# Apply removals
	for removal_id: String in data.get("entity_removals", []):
		var ent = World.get_entity(removal_id)
		var px: float = ent.x if ent != null else 0.0
		var pz: float = ent.z if ent != null else 0.0
		World.apply_removal(removal_id)
		_particles.spawn(px, pz, "DEATH_NATURAL", 6)

	# Apply voxel deltas
	var voxels: Variant = data.get("voxel_deltas", null)
	if voxels != null:
		World.apply_voxel_deltas(voxels)

	# Apply water sources
	var waters: Variant = data.get("water_sources", null)
	if waters != null:
		World.apply_water_sources(waters)

	# Process events
	for evt: Dictionary in data.get("events", []):
		var evt_type: String = evt.get("type", "")
		var source_id: String = evt.get("source_id", "")
		var pos: Variant = evt.get("position", [0, 0, 0])
		var px: float = pos[0] if pos is Array else 0.0
		var pz: float = pos[2] if pos is Array and pos.size() > 2 else 0.0

		match evt_type.to_upper():
			"CONSUMPTION":
				_particles.spawn(px, pz, "CONSUMPTION", 6)
				_add_hud_event("🌿 " + source_id + " consumed")
			"POLLINATION":
				_particles.spawn(px, pz, "POLLINATION", 8)
				_add_hud_event("🦋 " + source_id + " pollinated")
			"DEATH_NATURAL", "DEATH_STARVE":
				_particles.spawn(px, pz, "DEATH_NATURAL", 6)
				_add_hud_event("💀 " + source_id + " died")
			"REPRODUCTION":
				_add_hud_event("🐣 " + source_id + " reproduced")
			"STATE_CHANGE":
				pass  # Silent, handled by entity state update

	# Reconcile positions
	_reconciliation.reconcile(World, _current_tick)

	# Flush dead entities periodically
	if _current_tick % 10 == 0:
		World.flush_dead()


func _input(event: InputEvent) -> void:
	# Key controls
	if event is InputEventKey and event.pressed:
		if event.keycode == Key.R:
			WS.send_control("rain", {"intensity": 0.8})
			_add_hud_event("☔ Rain triggered!")
		elif event.keycode == Key.SPACE:
			WS.send_control("pause")
			_add_hud_event("⏸ Paused")

	# Camera pan with right/middle mouse drag
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.pressed:
				_dragging = true
				_drag_start = event.position
				_drag_offset_start = _camera_offset
			else:
				_dragging = false

	# Camera zoom with mouse wheel
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera_zoom = minf(_camera_zoom * 1.2, 4.0)
			queue_redraw()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera_zoom = maxf(_camera_zoom * 0.8, 0.2)
			queue_redraw()

	# Pan while dragging
	if _dragging and event is InputEventMouseMotion:
		var delta: Vector2 = event.position - _drag_start
		_camera_offset = _drag_offset_start + delta
		queue_redraw()
