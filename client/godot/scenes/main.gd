## Main scene - 3D world view with orbit camera.
## Grid coordinates map 1:1 to world X/Z; Y is height.
## Uses simple cube-based InstancedMesh rendering per entity type.
extends Node3D


@onready var camera: Camera3D = $Camera
@onready var renderer: Node = $Renderer
@onready var ground_mi: MultiMeshInstance3D = $Ground
@onready var entity_parent: Node3D = $Entities
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

# Renderer state
var _type_meshes: Dictionary = {}
var _ground_mat: ShaderMaterial = null


func _ready() -> void:
	print("Lila Godot Client starting (3D — cube renderer)...")

	WS.session_started.connect(_on_session_started)
	WS.tick_packet.connect(_on_tick_packet)
	WS.world_json_ready.connect(_on_world_json_ready)
	rain_button.pressed.connect(_on_rain_pressed)

	_particles = load("res://scripts/particles.gd").new()

	_setup_particles()
	_setup_renderer()

	# Orbit target = center of grid
	camera.target = Vector3(
		float(LilaConstants.GRID_SIZE) / 2.0,
		0.0,
		float(LilaConstants.GRID_SIZE) / 2.0
	)
	camera._update_position()


# ── Renderer setup ────────────────────────────────────────────────────

func _setup_renderer() -> void:
	# Build composite ArrayMeshes for each entity type
	var meshes: Dictionary = renderer.build_all_type_meshes()

	# Create InstancedMesh nodes under Entities parent
	_type_meshes = renderer.setup_type_meshes(entity_parent, meshes)

	# Ground voxels — reads INSTANCE_CUSTOM for per-cell color
	_ground_mat = renderer.make_ground_material()
	ground_mi.material_override = _ground_mat
	# Build voxel MultiMesh once — transforms are static, only colors change
	var ground_mm: MultiMesh = renderer.build_ground_voxels()
	ground_mi.multimesh = ground_mm


# ── Particle MultiMesh setup ──────────────────────────────────────────

func _setup_particles() -> void:
	var box: BoxMesh = BoxMesh.new()
	box.size = Vector3(0.3, 0.3, 0.3)

	var mm: MultiMesh = MultiMesh.new()
	mm.mesh = box
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.instance_count = 500
	particle_instance.multimesh = mm

	# Particles need a material that reads INSTANCE_CUSTOM for per-instance colors.
	particle_instance.material_override = renderer.make_particle_material()


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
		mm.set_instance_custom_data(i, c)


# ── Main loop ─────────────────────────────────────────────────────────

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


## Update ground voxel colors (MultiMesh was built once in setup).
func _build_ground() -> void:
	renderer.update_ground_voxels(
		ground_mi.multimesh, World.moisture_grid, World.water_sources
	)


## Update all per-type InstancedMesh entities.
func _build_entities() -> void:
	var entities: Array = World.get_alive()
	renderer.update_entities(_type_meshes, entities)


# ── Input ─────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_R:
			WS.send_control("rain", {"intensity": 0.8})
			_add_hud_event("☔ Rain triggered!")
		elif event.keycode == KEY_SPACE:
			WS.send_control("pause")
			_add_hud_event("⏸ Paused")


# ── WebSocket callbacks ────────────────────────────────────────────────

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

	# Debug: log entity positions every 10 ticks
	if _current_tick % 10 == 0:
		_log_entity_telemetry()


# ── HUD helpers ────────────────────────────────────────────────────────

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


# ── Telemetry / Debug ──────────────────────────────────────────────────

func _log_entity_telemetry() -> void:
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
