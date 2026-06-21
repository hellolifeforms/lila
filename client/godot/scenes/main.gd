# līlā — Godot 4.x 3D Client
# Copyright 2025 BioSynthArt Studios LLC
# Licensed under the Apache License, Version 2.0
#
# scenes/main.gd — Main scene: 3D world view with orbit camera
#
# Grid coordinates map 1:1 to world X/Z; Y is height.
# Uses primitive-based MultiMeshInstance3D rendering per entity type.
extends Node3D


@onready var camera = $Camera
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

# Selection state
var _selected_entity = null  # World.WorldEntity (inner class, no global type)
var _mouse_down_pos: Vector2 = Vector2.ZERO
var _mouse_down_time: float = 0.0

# Renderer state
var _type_meshes: Dictionary = {}
var _ground_mat: ShaderMaterial = null


func _ready() -> void:
	LilaConstants.log("Lila Godot Client starting (3D — cube renderer)...")

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

	# Clear selection if selected entity dies
	World.entity_removed.connect(_on_entity_removed)


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

		# Update selection visuals every frame
		_update_selection_billboard()


## Update ground voxel colors (MultiMesh was built once in setup).
func _build_ground() -> void:
	renderer.update_ground_voxels(
		ground_mi.multimesh, World.moisture_grid, World.water_sources
	)


## Update all per-type InstancedMesh entities.
func _build_entities() -> void:
	var entities: Array = World.get_alive()
	var sel_id: String = _selected_entity.id if _selected_entity else ""
	renderer.update_entities(_type_meshes, entities, sel_id)


# ── Input ─────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	# ── Mouse click detection (click vs drag) ──────────────────────
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_mouse_down_pos = event.position
				_mouse_down_time = Time.get_ticks_msec() / 1000.0
			elif not event.pressed:
				# Check if this was a click (not a drag)
				var elapsed: float = (Time.get_ticks_msec() / 1000.0) - _mouse_down_time
				var distance: float = _mouse_down_pos.distance_to(event.position)
				if elapsed < 0.35 and distance < 12.0:
					_select_entity_at_click()

	# ── Keyboard ────────────────────────────────────────────────────
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_deselect_entity()
		elif event.keycode == KEY_R:
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
	LilaConstants.log("Session started: %s" % data.get("session_id", ""))
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
	LilaConstants.log(log_line)


# ── Entity Selection ─────────────────────────────────────────────────

## Build a camera ray from a viewport (screen) position.
func _make_camera_ray(viewport_pos: Vector2) -> Dictionary:
	var cam = get_viewport().get_camera_3d()
	if cam == null:
		return {}
	return {
		"origin": cam.project_ray_origin(viewport_pos),
		"dir": cam.project_ray_normal(viewport_pos),
	}

## Closest distance from a point to an infinite ray (origin → dir).
func _point_to_ray_dist(point: Vector3, ray_origin: Vector3, ray_dir: Vector3) -> float:
	var v: Vector3 = point - ray_origin
	# Project v onto ray_dir; clamp t >= 0 so we only check forward.
	var t: float = v.dot(ray_dir)
	if t < 0.0:
		return point.distance_to(ray_origin)
	var closest: Vector3 = ray_origin + ray_dir * t
	return point.distance_to(closest)

## Compute the entity's 3D world position (accounts for flight altitude).
func _entity_world_pos(ent) -> Vector3:
	var y: float = 0.5  # ground surface
	match ent.type:
		"INSECT":
			y = 1.75
		"BIRD":
			y = 4.0
	return Vector3(ent.x, y, ent.z)

## Find the nearest alive entity by ray-to-point distance in 3D space.
## This works for flying entities (birds/insects) as well as ground entities.
func _find_nearest_entity(ray_origin: Vector3, ray_dir: Vector3):
	var best = null
	var best_dist: float = INF
	for ent in World.get_alive():
		var epos: Vector3 = _entity_world_pos(ent)
		var dist: float = _point_to_ray_dist(epos, ray_origin, ray_dir)
		var hit_radius: float = _get_hit_radius(ent)
		if dist < hit_radius and dist < best_dist:
			best_dist = dist
			best = ent
	return best

## Per-type selection hitbox radius (generous for small/flying entities).
func _get_hit_radius(ent) -> float:
	match ent.type:
		"TREE":
			return 2.5
		"ANIMAL":
			return 2.0
		"BIRD":
			return 4.0
		"INSECT":
			return 4.0
		"PLANT":
			return 2.0
		"MICROORGANISM":
			return 3.0
	return 3.0

## Handle a click-to-select event.
func _select_entity_at_click() -> void:
	var ray: Dictionary = _make_camera_ray(_mouse_down_pos)
	if ray.is_empty():
		LilaConstants.log("[select] no camera")
		return
	var ent = _find_nearest_entity(ray["origin"], ray["dir"])
	if ent != null:
		_selected_entity = ent
		var epos: Vector3 = _entity_world_pos(ent)
		var dist: float = _point_to_ray_dist(epos, ray["origin"], ray["dir"])
		_add_hud_event("🔍 %s · %s" % [ent.species.capitalize(), ent.state])
		LilaConstants.log("[select] %s (%s) at (%.1f,%.1f,%.1f) ray_dist=%.2f" % [
			ent.id, ent.type, epos.x, epos.y, epos.z, dist])
	else:
		LilaConstants.log("[select] no entity near click ray, %d alive" % World.get_entity_count())
		_deselect_entity()

## Clear selection.
func _deselect_entity() -> void:
	_selected_entity = null

## Called when an entity is removed from the world.
func _on_entity_removed(entity_id: String) -> void:
	if _selected_entity and _selected_entity.id == entity_id:
		_selected_entity = null

## Update the selection stats billboard on the HUD.
func _update_selection_billboard() -> void:
	var selection_label: Label = $HUD/SelectionLabel
	if selection_label == null:
		return

	if _selected_entity:
		selection_label.visible = true
		var ent = _selected_entity
		var type_emoji: String = _get_type_emoji(ent.type)
		selection_label.text = "%s %s · %s\n%s" % [
			type_emoji,
			ent.species.capitalize(),
			ent.state,
			_format_drives(ent)
		]
	else:
		selection_label.visible = false

## Return an emoji for the entity type.
func _get_type_emoji(etype: String) -> String:
	match etype:
		"ANIMAL":
			return "🦌"
		"BIRD":
			return "🐦"
		"INSECT":
			return "🦋"
		"PLANT":
			return "🌿"
		"TREE":
			return "🌳"
		"MICROORGANISM":
			return "🍄"
	return "❓"

## Format drive/state variables as a compact stats line.
func _format_drives(ent) -> String:
	var sv: Dictionary = ent.drive
	var parts: Array[String] = []

	match ent.type:
		"ANIMAL", "BIRD":
			if sv.has("hunger"):
				parts.append("🍖%.0f" % (sv["hunger"] * 100.0))
			if sv.has("energy"):
				parts.append("⚡%.0f" % (sv["energy"] * 100.0))
			if sv.has("hydration"):
				parts.append("💧%.0f" % (sv["hydration"] * 100.0))
			if sv.has("health"):
				parts.append("❤️%.0f" % (sv["health"] * 100.0))
			if sv.has("reproductive_drive") and sv["reproductive_drive"] > 0.0:
				parts.append("💕%.0f" % (sv["reproductive_drive"] * 100.0))
			if sv.has("age"):
				parts.append("⏳%.1f" % sv["age"])
		"PLANT", "TREE":
			if sv.has("hydration"):
				parts.append("💧%.0f" % (sv["hydration"] * 100.0))
			if sv.has("growth"):
				parts.append("🌱%.0f" % (sv["growth"] * 100.0))
			if sv.has("nutrient_store"):
				parts.append("🧪%.0f" % (sv["nutrient_store"] * 100.0))
			if sv.has("health"):
				parts.append("❤️%.0f" % (sv["health"] * 100.0))
			if sv.has("age"):
				parts.append("⏳%.1f" % sv["age"])
		"INSECT":
			if sv.has("hunger"):
				parts.append("🍖%.0f" % (sv["hunger"] * 100.0))
			if sv.has("energy"):
				parts.append("⚡%.0f" % (sv["energy"] * 100.0))
			if sv.has("colony_health"):
				parts.append("🐝%.0f" % (sv["colony_health"] * 100.0))
			if sv.has("reproductive_drive") and sv["reproductive_drive"] > 0.0:
				parts.append("💕%.0f" % (sv["reproductive_drive"] * 100.0))
		"MICROORGANISM":
			if sv.has("population"):
				parts.append("🧫%.0f" % (sv["population"] * 100.0))
			if sv.has("activity"):
				parts.append("🔬%.0f" % (sv["activity"] * 100.0))

	return " ".join(parts)
