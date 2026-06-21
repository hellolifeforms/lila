# līlā — Godot 4.x 3D Client
# Copyright 2025 BioSynthArt Studios LLC
# Licensed under the Apache License, Version 2.0
#
# scripts/autoloads/world_model.gd — Client-side world model
#
# Entity registry, spatial queries, and environment state. Mirrors browser
# world-model.js and Python world_model.py.
extends Node


## Signals emitted for renderer consumption
signal entity_spawned(entity_id: String)
signal entity_removed(entity_id: String)
signal entities_updated()


## WorldEntity — per-entity client state
class WorldEntity:
	var id: String
	var type: String
	var species: String
	var skeleton_id: String = ""

	## Local (agency) position in grid units
	var x: float = 0.0
	var z: float = 0.0

	## Server reference position (gravity well anchor)
	var ref_x: float = 0.0
	var ref_z: float = 0.0

	var state: String = "IDLE"
	var drive: Dictionary = {}
	var motion_latent: PackedFloat32Array = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])

	## Eligibility flags from server
	var can_consume: bool = false
	var can_predate: bool = false
	var can_pollinate: bool = false
	var repro_eligible: bool = false
	var can_drink: bool = false

	## Acknowledgment from server
	var ack: bool = false

	## Reconciliation — queue of target positions consumed smoothly by agency
	var reconcile_queue: PackedVector2Array = PackedVector2Array()
	var reconcile_idx: int = 0

	## Sync personality (derived from id hash)
	var sync_phase: int = 0
	var sync_speed: float = 1.0

	## Rendering
	var facing_angle: float = 0.0
	var alive: bool = true

	## Wander target persistence (mirrors browser/Python hasTarget + targetX/targetZ)
	var target_x: float = 0.0
	var target_z: float = 0.0
	var has_target: bool = false
	var last_action_type: String = ""

	## Reconciliation tracking (mirrors browser/Python _lastReconciledTick)
	var last_reconciled_tick: int = -10

	func _init(entity_id: String, etype: String, especies: String):
		id = entity_id
		type = etype
		species = especies
		# Deterministic sync personality from id hash
		var hash_val: int = hash(entity_id)
		var abs_hash: int = absi(hash_val)
		sync_phase = abs_hash % 4
		sync_speed = 0.4 + (abs_hash % 10) * 0.06


## Entity registry keyed by entity id
var entities: Dictionary = {}

## Species definitions from session_started
var species_defs: Dictionary = {}

## Moisture grid (GRID_SIZE x GRID_SIZE)
var moisture_grid: PackedFloat32Array

## Water sources: array of {position: Vector2, radius: float, water_level: float}
var water_sources: Array[Dictionary] = []


func _ready() -> void:
	var size: int = LilaConstants.GRID_SIZE * LilaConstants.GRID_SIZE
	moisture_grid = PackedFloat32Array()
	moisture_grid.resize(size)
	moisture_grid.fill(0.5)


## Apply a single entity update from a tick packet.
func apply_update(data: Dictionary) -> void:
	var eid: String = data.get("id", "")
	if eid.is_empty():
		return

	var is_new: bool = false
	var ent: WorldEntity = entities.get(eid)
	if ent == null:
		is_new = true
		ent = WorldEntity.new(eid, data.get("type", "ANIMAL"), data.get("species", "unknown"))
		entities[eid] = ent

	var pos: Variant = data.get("ref_position", [0, 0, 0])
	ent.ref_x = _vec_x(pos)
	ent.ref_z = _vec_z(pos)

	# Initialize local position from server ref on first contact
	# (mirrors Python client's apply_update behavior)
	if is_new:
		ent.x = ent.ref_x
		ent.z = ent.ref_z

	ent.state = data.get("state", ent.state)

	var drive_data: Dictionary = data.get("drive", {})
	if not drive_data.is_empty():
		ent.drive = drive_data

	var latent: Variant = data.get("motion_latent", [])
	if latent is Array:
		ent.motion_latent = PackedFloat32Array(latent)

	ent.can_consume = data.get("_can_consume", false)
	ent.can_predate = data.get("_can_predate", false)
	ent.can_pollinate = data.get("_can_pollinate", false)
	ent.repro_eligible = data.get("_repro_eligible", false)
	ent.can_drink = data.get("_can_drink", false)
	ent.ack = data.get("_ack", false)


## Apply entity spawn from tick packet.
func apply_spawn(data: Dictionary) -> void:
	var eid: String = data.get("id", "")
	var etype: String = data.get("type", "ANIMAL")
	var especies: String = data.get("species", "unknown")

	var ent: WorldEntity = WorldEntity.new(eid, etype, especies)
	ent.skeleton_id = data.get("skeleton_id", "")

	var pos: Variant = data.get("ref_position", [0, 0, 0])
	ent.ref_x = _vec_x(pos)
	ent.ref_z = _vec_z(pos)
	ent.x = ent.ref_x
	ent.z = ent.ref_z

	ent.state = data.get("state", "IDLE")

	var drive_data: Dictionary = data.get("drive", {})
	if not drive_data.is_empty():
		ent.drive = drive_data

	var latent: Variant = data.get("motion_latent", [])
	if latent is Array:
		ent.motion_latent = PackedFloat32Array(latent)

	entities[eid] = ent
	entity_spawned.emit(eid)


## Remove an entity by id.
func apply_removal(eid: String) -> void:
	if entities.has(eid):
		entities[eid].alive = false
		entity_removed.emit(eid)


## Remove all dead entities from registry.
func flush_dead() -> void:
	var dead: PackedStringArray = PackedStringArray()
	for eid in entities:
		if not entities[eid].alive:
			dead.append(eid)
	for eid in dead:
		entities.erase(eid)


## Apply voxel deltas for moisture layer.
func apply_voxel_deltas(deltas: Variant) -> void:
	if deltas == null:
		return
	# Can be Dictionary keyed by layer, or direct {coord: value}
	var moisture_deltas: Dictionary = {}
	if deltas is Dictionary:
		moisture_deltas = deltas.get("moisture", deltas)
		if moisture_deltas == null:
			moisture_deltas = deltas

	for key: String in moisture_deltas:
		var coords: PackedInt32Array = _parse_coord_key(key)
		if coords.size() == 3:
			var idx: int = coords[0] + coords[1] * LilaConstants.GRID_SIZE + coords[2] * LilaConstants.GRID_SIZE * LilaConstants.GRID_SIZE
			if idx >= 0 and idx < moisture_grid.size():
				moisture_grid[idx] = moisture_deltas[key]


## Apply water sources from tick packet.
func apply_water_sources(sources: Variant) -> void:
	if sources == null or sources is not Array:
		return
	water_sources.clear()
	for src: Dictionary in sources:
		var pos: Variant = src.get("position", [0, 0, 0])
		var current_radius: float = src.get("radius", 3.0)
		var level: float = src.get("water_level", 1.0)
		# Derive max_radius so the renderer can use the full footprint for blending
		# (server sets radius = max_radius * water_level each tick)
		var max_radius: float = current_radius / level if level > 0.01 else current_radius
		water_sources.append({
			"position": Vector2(_vec_x(pos), _vec_z(pos)),
			"radius": current_radius,
			"max_radius": max_radius,
			"water_level": level,
		})


## Get alive mobile entities (animals, birds, insects).
func get_alive_mobile() -> Array[WorldEntity]:
	var result: Array[WorldEntity] = []
	for eid in entities:
		var ent: WorldEntity = entities[eid]
		if ent.alive and ent.type in ["ANIMAL", "BIRD", "INSECT"]:
			result.append(ent)
	return result


## Get all alive entities.
func get_alive() -> Array[WorldEntity]:
	var result: Array[WorldEntity] = []
	for eid in entities:
		if entities[eid].alive:
			result.append(entities[eid])
	return result


## Find nearest alive entity of given type(s) from position (x, z).
func find_nearest(pos_x: float, pos_z: float, type_filter: PackedStringArray = PackedStringArray()) -> WorldEntity:
	var best: WorldEntity = null
	var best_dist: float = INF
	for eid in entities:
		var ent: WorldEntity = entities[eid]
		if not ent.alive:
			continue
		if not type_filter.is_empty() and not type_filter.has(ent.type):
			continue
		var dist: float = _dist(pos_x, pos_z, ent.x, ent.z)
		if dist < best_dist:
			best_dist = dist
			best = ent
	return best


## Find nearest entity of a specific species.
func find_nearest_species(pos_x: float, pos_z: float, species_name: String) -> WorldEntity:
	var best: WorldEntity = null
	var best_dist: float = INF
	for eid in entities:
		var ent: WorldEntity = entities[eid]
		if not ent.alive or ent.species != species_name:
			continue
		var dist: float = _dist(pos_x, pos_z, ent.x, ent.z)
		if dist < best_dist:
			best_dist = dist
			best = ent
	return best


## Find nearest mate (same species, alive) for an entity.
func find_nearest_mate(ent: WorldEntity) -> WorldEntity:
	var best: WorldEntity = null
	var best_dist: float = INF
	for eid in entities:
		var other: WorldEntity = entities[eid]
		if not other.alive or other.id == ent.id or other.species != ent.species:
			continue
		var dist: float = _dist(ent.x, ent.z, other.x, other.z)
		if dist < best_dist:
			best_dist = dist
			best = other
	return best


## Find nearest water source from position.
func find_nearest_water(pos_x: float, pos_z: float) -> Dictionary:
	var best: Dictionary = {}
	var best_dist: float = INF
	for src: Dictionary in water_sources:
		var pos: Vector2 = src.position
		var dist: float = sqrt((pos_x - pos.x) ** 2 + (pos_z - pos.y) ** 2)
		if dist < best_dist:
			best_dist = dist
			best = src
	return best


## Get entity by id.
func get_entity(eid: String) -> WorldEntity:
	return entities.get(eid)


func get_entity_count() -> int:
	return entities.size()


# -- Helpers --

static func _vec_x(v: Variant) -> float:
	if v is Array and v.size() >= 1:
		return float(v[0])
	return 0.0

static func _vec_z(v: Variant) -> float:
	if v is Array and v.size() >= 3:
		return float(v[2])
	elif v is Array and v.size() >= 2:
		return float(v[1])
	return 0.0

static func _dist(x1: float, z1: float, x2: float, z2: float) -> float:
	return sqrt((x1 - x2) ** 2 + (z1 - z2) ** 2)

static func _parse_coord_key(key: String) -> PackedInt32Array:
	var parts: PackedStringArray = key.split(",", false)
	var result: PackedInt32Array = PackedInt32Array()
	for p in parts:
		result.append(p.to_int())
	return result
