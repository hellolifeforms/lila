## Main scene - 3D world view with orbit camera.
## Grid coordinates map 1:1 to world X/Z; Y is height.
extends Node3D


@onready var camera: Camera3D = $Camera
@onready var ground_mi: MeshInstance3D = $Ground
@onready var entity_multi: MultiMeshInstance3D = $Entities
@onready var particle_instance: MultiMeshInstance3D = $Particles
@onready var hud: CanvasLayer = $HUD
@onready var stats_label: Label = $HUD/VBox/StatsLabel
@onready var event_log: RichTextLabel = $HUD/VBox/EventLog
@onready var rain_button: Button = $HUD/VBox/RainButton

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

## Entity block height in world units.
const BLOCK_HEIGHT: float = 2.0


func _ready() -> void:
	print("Lila Godot Client starting (3D)...")

	WS.session_started.connect(_on_session_started)
	WS.tick_packet.connect(_on_tick_packet)
	WS.world_json_ready.connect(_on_world_json_ready)
	rain_button.pressed.connect(_on_rain_pressed)

	_particles = load("res://scripts/particles.gd").new()
	_setup_particles()
	_setup_entities()

	# Orbit target = center of grid
	camera.target = Vector3(
		float(LilaConstants.GRID_SIZE) / 2.0,
		0.0,
		float(LilaConstants.GRID_SIZE) / 2.0
	)
	camera._update_position()


# ── Entity MultiMesh setup ────────────────────────────────────────

func _setup_entities() -> void:
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(1.0, 1.0, 1.0)

	var mm: MultiMesh = MultiMesh.new()
	mm.mesh = box
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = 0
	entity_multi.multimesh = mm


# ── Particle MultiMesh setup ──────────────────────────────────────

func _setup_particles() -> void:
	# Tiny box as particle marker (SphereMesh API changed in 4.7)
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(0.4, 0.4, 0.4)

	var mm: MultiMesh = MultiMesh.new()
	mm.mesh = box
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = 500
	particle_instance.multimesh = mm


func _update_particle_mesh() -> void:
	var alive: Array = _particles.get_alive()
	var count: int = alive.size()
	var mm: MultiMesh = particle_instance.multimesh
	if mm == null:
		return

	mm.instance_count = count
	var t: Transform3D
	for i in count:
		var p = alive[i]
		t.origin = Vector3(p.position.x, 0.5, p.position.y)
		var s: float = p.size * 2.0
		t.basis = Basis.from_scale(Vector3(s, s, s))
		mm.set_instance_transform(i, t)
		var c: Color = p.color
		c.a = maxf(0.0, p.life / p.max_life)
		mm.set_instance_color(i, c)


# ── ImmediateMesh rendering ──────────────────────────────────────
# Ground mesh: locked once in _ready, updated every frame.
# Entity mesh: same pattern.

func _process(delta: float) -> void:
	# FPS counter
	_frame_count += 1
	_fps_timer += delta
	if _fps_timer >= 1.0:
		_fps = _frame_count / _fps_timer
		_frame_count = 0
		_fps_timer = 0.0
		_update_stats()

	if _session_started:
		var now: float = Time.get_ticks_msec() / 1000.0
		var events: Array = _agency.step(World, delta)
		for evt: Dictionary in events:
			_heartbeat.queue_event(evt)
		_heartbeat.tick(WS, World, now)
		_particles.step(delta)

		# Rebuild meshes every frame
		_build_ground()
		_build_entities()
		_update_particle_mesh()


## Build ground tiles as ArrayMesh via SurfaceTool.
func _build_ground() -> void:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var size: int = LilaConstants.GRID_SIZE
	var half: float = 0.49  # slight gap avoids z-fighting seams

	for gz in size:
		for gx in size:
			var idx: int = gx + gz * size
			var moisture: float = 0.5
			if idx < World.moisture_grid.size():
				moisture = World.moisture_grid[idx]
			st.set_color(_moisture_color(moisture))

			var cx: float = float(gx)
			var cz: float = float(gz)
			# Two triangles per tile
			st.add_vertex(Vector3(cx - half, 0.0, cz - half))
			st.add_vertex(Vector3(cx + half, 0.0, cz - half))
			st.add_vertex(Vector3(cx - half, 0.0, cz + half))
			st.add_vertex(Vector3(cx + half, 0.0, cz - half))
			st.add_vertex(Vector3(cx + half, 0.0, cz + half))
			st.add_vertex(Vector3(cx - half, 0.0, cz + half))

	st.generate_normals()
	var mesh: Mesh = st.commit()
	ground_mi.mesh = mesh


## Build entity cubes as MultiMesh instances (BoxMesh primitive).
func _build_entities() -> void:
	var mm: MultiMesh = entity_multi.multimesh
	if mm == null:
		return

	var entities: Array = World.get_alive()
	mm.instance_count = entities.size()

	for i in entities.size():
		var ent = entities[i]
		if is_nan(ent.x) or is_nan(ent.z) or is_inf(ent.x) or is_inf(ent.z):
			continue

		var color: Color = _get_entity_color(ent)
		var size: float = _get_entity_size(ent)

		var y_off: float = 0.0
		if ent.type == "INSECT":
			y_off = 3.0 + sin(Time.get_ticks_msec() / 300.0 + float(ent.sync_phase)) * 0.8

		var cx: float = ent.x
		var cy: float = BLOCK_HEIGHT * size * 0.5 + y_off
		var cz: float = ent.z

		# Dormant entities are darker
		if ent.state == "DORMANT":
			color = color.darkened(0.5)

		var t: Transform3D
		t.origin = Vector3(cx, cy, cz)
		t.basis = Basis.from_scale(Vector3(size, BLOCK_HEIGHT * size, size))
		mm.set_instance_transform(i, t)
		mm.set_instance_color(i, color)


# ── Input ─────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_R:
			WS.send_control("rain", {"intensity": 0.8})
			_add_hud_event("☔ Rain triggered!")
		elif event.keycode == KEY_SPACE:
			WS.send_control("pause")
			_add_hud_event("⏸ Paused")


# ── WebSocket callbacks ───────────────────────────────────────────

func _on_rain_pressed() -> void:
	WS.send_control("rain", {"intensity": 0.8})
	_add_hud_event("☔ Rain triggered!")


func _on_world_json_ready(data: Dictionary) -> void:
	_world_def = data


func _on_session_started(data: Dictionary) -> void:
	print("Session started: ", data.get("session_id", ""))
	World.species_defs = data.get("species", {})
	_session_started = true
	World.flush_dead()


func _on_tick_packet(data: Dictionary) -> void:
	_current_tick = data.get("tick", _current_tick)

	for update: Dictionary in data.get("entity_updates", []):
		World.apply_update(update)
	for spawn: Dictionary in data.get("entity_spawns", []):
		World.apply_spawn(spawn)

	for removal_id: String in data.get("entity_removals", []):
		var ent = World.get_entity(removal_id)
		var px: float = ent.x if ent != null else 0.0
		var pz: float = ent.z if ent != null else 0.0
		World.apply_removal(removal_id)
		_particles.spawn(px, pz, "DEATH_NATURAL", 6)

	var voxels: Variant = data.get("voxel_deltas", null)
	if voxels != null:
		World.apply_voxel_deltas(voxels)
	var waters: Variant = data.get("water_sources", null)
	if waters != null:
		World.apply_water_sources(waters)

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

	_reconciliation.reconcile(World, _current_tick)
	if _current_tick % 10 == 0:
		World.flush_dead()

	# Debug: log entity positions every 10 ticks for telemetry comparison
	if _current_tick % 10 == 0:
		_log_entity_telemetry()


# ── HUD helpers ───────────────────────────────────────────────────

func _update_stats() -> void:
	stats_label.text = "Tick: %d | Entities: %d | Events: %d | FPS: %d" % [
		_current_tick, World.get_entity_count(), _event_count, _fps
	]


func _add_hud_event(text: String) -> void:
	_event_count += 1
	event_log.append_text("[color=ffcc66]%s[/color]\n" % text)
	var max_lines: int = 50
	var lines: PackedStringArray = event_log.text.split("\n")
	if lines.size() > max_lines:
		event_log.set_text("\n".join(lines.slice(-max_lines)))


# ── Color helpers ─────────────────────────────────────────────────

func _moisture_color(moisture: float) -> Color:
	if moisture < 0.33:
		return Color(0.9, 0.85, 0.7)
	elif moisture < 0.66:
		return Color(0.7, 0.8, 0.6)
	else:
		return Color(0.4, 0.7, 0.6)


func _get_entity_color(ent) -> Color:
	if ent.species in LilaConstants.SPECIES_COLORS:
		return LilaConstants.SPECIES_COLORS[ent.species]
	if ent.type in LilaConstants.TYPE_COLORS:
		return LilaConstants.TYPE_COLORS[ent.type]
	return Color(0.5, 0.5, 0.5)


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


# ── Telemetry / Debug helpers ──────────────────────────────────────────

func _log_entity_telemetry() -> void:
	"""Log entity positions for debugging reconciliation. Mirrors server telemetry."""
	var mobile: Array = World.get_alive_mobile()
	if mobile.is_empty():
		return
	var log_line: String = "[telemetry] tick=%d entities=%d" % [_current_tick, mobile.size()]
	for i in minf(5, mobile.size()):
		var ent = mobile[i]
		var divergence: float = sqrt(
			(ent.x - ent.ref_x) ** 2 + (ent.z - ent.ref_z) ** 2
		)
		log_line += " | %s: local=(%.2f,%.2f) ref=(%.2f,%.2f) div=%.3f ack=%s queue=%d" % [
			ent.id,
			ent.x, ent.z,
			ent.ref_x, ent.ref_z,
			divergence,
			ent.ack,
			ent.reconcile_queue.size(),
		]
	print(log_line)
