## Client-side agency engine — runs at 60 Hz between server ticks.
## Mirrors browser agency.js and Python agency.py.
## Server is the nervous system (intent), client is the body (execution).
class_name Agency


var _cooldowns: Dictionary = {}  # "source_target" -> timestamp


## Step all mobile entities. Returns array of client events to send upstream.
func step(world: Node, delta: float) -> Array:
	var events: Array = []
	var mobile: Array = world.get_alive_mobile()
	var now: float = Time.get_ticks_msec() / 1000.0

	for ent in mobile:
		var ent_events: Array = _step_entity(ent, world, delta, now)
		for evt in ent_events:
			events.append(evt)

	return events


func _step_entity(ent, world: Node, delta: float, now: float) -> Array:
	var events: Array = []

	if not ent.alive:
		return events

	# Check for reconcile target first
	if ent.reconcile_idx < ent.reconcile_queue.size():
		ent.last_action_type = "reconciling"
		_execute_reconcile(ent, delta)
		return events

	# Evaluate behavior priority chain
	var target: Vector2 = Vector2.ZERO

	if ent.state == "FLEEING":
		var flee_result: Dictionary = _evaluate_fleeing(ent, world)
		target = flee_result.get("target", Vector2.ZERO)
		ent.last_action_type = "fleeing"
	elif ent.state == "DRINKING" or (ent.can_drink and ent.drive.get("hydration", 1.0) < 0.3):
		var drink_result: Dictionary = _evaluate_drinking(ent, world)
		target = drink_result.get("target", Vector2.ZERO)
		ent.last_action_type = "drinking"
	elif ent.repro_eligible and ent.drive.get("reproductive_drive", 0.0) > 0.5:
		var mate_result: Dictionary = _evaluate_mate_seeking(ent, world)
		target = mate_result.get("target", Vector2.ZERO)
		ent.last_action_type = "seek_mate"
	elif ent.state == "FORAGING" and ent.can_consume:
		var forage_result: Dictionary = _evaluate_foraging(ent, world)
		target = forage_result.get("target", Vector2.ZERO)
		ent.last_action_type = "foraging"
		events.append_array(forage_result.get("events", []))
	elif ent.state == "HUNTING" and ent.can_predate:
		var hunt_result: Dictionary = _evaluate_hunting(ent, world)
		target = hunt_result.get("target", Vector2.ZERO)
		ent.last_action_type = "hunting"
		events.append_array(hunt_result.get("events", []))
	elif ent.can_pollinate:
		var poll_result: Dictionary = _evaluate_pollination(ent, world)
		target = poll_result.get("target", Vector2.ZERO)
		ent.last_action_type = "pollinating"
		events.append_array(poll_result.get("events", []))
	else:
		target = _evaluate_wandering(ent, delta)
		ent.last_action_type = "wander"

	# Move toward target
	if target != Vector2.ZERO:
		_move_toward(ent, target, delta, world)

	# Gravity well: gentle pull toward server reference position
	# Multiplied by delta for frame-rate independence (mirrors Python/browser)
	var speed_factor: float = ent.sync_speed
	var dx_gw: float = ent.ref_x - ent.x
	var dz_gw: float = ent.ref_z - ent.z
	var dist_gw: float = sqrt(dx_gw * dx_gw + dz_gw * dz_gw)
	if dist_gw > 0.2:  # Skip if already close enough (mirrors Python/browser threshold)
		var nudge: float = LilaConstants.GRAVITY_WELL_FACTOR * speed_factor * delta
		ent.x += dx_gw * nudge
		ent.z += dz_gw * nudge

	# Clamp to grid bounds
	ent.x = clampf(ent.x, 0.0, float(LilaConstants.GRID_SIZE - 1))
	ent.z = clampf(ent.z, 0.0, float(LilaConstants.GRID_SIZE - 1))

	return events


func _execute_reconcile(ent, delta: float) -> void:
	if ent.reconcile_idx >= ent.reconcile_queue.size():
		ent.reconcile_queue.clear()
		ent.reconcile_idx = 0
		return

	var target: Vector2 = ent.reconcile_queue[ent.reconcile_idx]
	var dx: float = target.x - ent.x
	var dz: float = target.y - ent.z
	var dist: float = sqrt(dx * dx + dz * dz)

	if dist < LilaConstants.ARRIVAL_DISTANCE:
		ent.reconcile_idx += 1
		return

	# Spiral meander toward target (organic movement)
	var speed: float = 2.0 * ent.sync_speed
	var target_angle: float = atan2(dz, dx)
	var wobble: float = sin(Time.get_ticks_msec() / 200.0 + ent.sync_phase) * 0.5
	var move_angle: float = target_angle + wobble
	var move_x: float = cos(move_angle) * speed * delta
	var move_z: float = sin(move_angle) * speed * delta

	ent.x += move_x
	ent.z += move_z

	# Smoothly interpolate facing direction (no instant snaps)
	var angle_diff: float = wrapf(target_angle - ent.facing_angle, -PI, PI)
	ent.facing_angle += clampf(angle_diff, -LilaConstants.TURN_SPEED * delta, LilaConstants.TURN_SPEED * delta)


func _evaluate_fleeing(ent, world: Node) -> Dictionary:
	# Find nearest threat based on species definitions
	var species_def: Dictionary = world.species_defs.get(ent.species, {})
	var flee_targets: Array = species_def.get("flee_targets", [])

	if flee_targets.is_empty():
		return {"target": Vector2.ZERO}

	var best: Variant = world.find_nearest(ent.x, ent.z, PackedStringArray(["ANIMAL", "BIRD"]))
	if best == null or flee_targets.has(best.species):
		if best != null:
			# Flee away from threat
			var away_x: float = ent.x - best.x
			var away_z: float = ent.z - best.z
			var len: float = sqrt(away_x * away_x + away_z * away_z)
			if len > 0.01:
				away_x /= len
				away_z /= len
				# Clamp to grid
				var target_x: float = clampf(ent.x + away_x * 10.0, 0.0, float(LilaConstants.GRID_SIZE - 1))
				var target_z: float = clampf(ent.z + away_z * 10.0, 0.0, float(LilaConstants.GRID_SIZE - 1))
				return {"target": Vector2(target_x, target_z)}

	return {"target": Vector2.ZERO}


func _evaluate_drinking(ent, world: Node) -> Dictionary:
	var water: Dictionary = world.find_nearest_water(ent.x, ent.z)
	if water.is_empty():
		return {"target": Vector2.ZERO}

	var pos: Vector2 = water.position
	var radius: float = water.get("radius", 3.0)
	# Move to water source edge
	var dx: float = pos.x - ent.x
	var dz: float = pos.y - ent.z
	var dist: float = sqrt(dx * dx + dz * dz)

	if dist <= radius:
		return {"target": Vector2.ZERO}  # Already at water

	var edge_x: float = pos.x - (dx / dist) * radius
	var edge_z: float = pos.y - (dz / dist) * radius
	return {"target": Vector2(edge_x, edge_z)}


func _evaluate_mate_seeking(ent, world: Node) -> Dictionary:
	var mate: Variant = world.find_nearest_mate(ent)
	if mate == null:
		return {"target": Vector2.ZERO}

	var dx: float = mate.x - ent.x
	var dz: float = mate.z - ent.z
	var dist: float = sqrt(dx * dx + dz * dz)

	if dist < LilaConstants.ARRIVAL_DISTANCE:
		# Check cooldown and fire repro event
		var key: String = ent.id + "_" + mate.id
		var last: float = _cooldowns.get(key, 0.0)
		var now: float = Time.get_ticks_msec() / 1000.0
		if now - last > LilaConstants.INTERACTION_COOLDOWN:
			_cooldowns[key] = now
			var events: Array = []
			events.append({
				"type": "repro",
				"parent_id": ent.id,
				"offspring_count": 1,
				"client_position": [ent.x, 0.0, ent.z],
			})
			return {"target": Vector2.ZERO, "events": events}

	return {"target": Vector2(mate.x, mate.z)}


func _evaluate_foraging(ent, world: Node) -> Dictionary:
	var species_def: Dictionary = world.species_defs.get(ent.species, {})
	var diet_order: Array = species_def.get("diet_order", [])

	var events: Array = []
	var best_target: Vector2 = Vector2.ZERO
	var best_dist: float = INF
	var best_entity: Variant = null

	for diet_entry in diet_order:
		var target_species: String = diet_entry[0]
		var candidates: Array = world.get_alive()
		for candidate in candidates:
			if candidate.species == target_species:
				var dist: float = sqrt((ent.x - candidate.x) ** 2 + (ent.z - candidate.z) ** 2)
				if dist < best_dist:
					best_dist = dist
					best_target = Vector2(candidate.x, candidate.z)
					best_entity = candidate

	if best_entity != null and best_dist < LilaConstants.ARRIVAL_DISTANCE:
		# Check cooldown and fire consumption event
		var key: String = ent.id + "_" + best_entity.id
		var last: float = _cooldowns.get(key, 0.0)
		var now: float = Time.get_ticks_msec() / 1000.0
		if now - last > LilaConstants.INTERACTION_COOLDOWN:
			_cooldowns[key] = now
			events.append({
				"type": "consumption",
				"source_id": ent.id,
				"target_id": best_entity.id,
				"position": [ent.x, 0.0, ent.z],
			})
		return {"target": Vector2.ZERO, "events": events}

	if best_target != Vector2.ZERO:
		return {"target": best_target, "events": events}
	return {"target": Vector2.ZERO, "events": events}


func _evaluate_hunting(ent, world: Node) -> Dictionary:
	var species_def: Dictionary = world.species_defs.get(ent.species, {})
	var diet_order: Array = species_def.get("diet_order", [])

	var events: Array = []
	var best_target: Vector2 = Vector2.ZERO
	var best_dist: float = INF
	var best_entity: Variant = null

	# Find prey from diet breadth
	for diet_entry in diet_order:
		var target_species: String = diet_entry[0]
		var candidates: Array = world.get_alive_mobile()
		for candidate in candidates:
			if candidate.species == target_species:
				var dist: float = sqrt((ent.x - candidate.x) ** 2 + (ent.z - candidate.z) ** 2)
				if dist < best_dist:
					best_dist = dist
					best_target = Vector2(candidate.x, candidate.z)
					best_entity = candidate

	if best_entity != null and best_dist < LilaConstants.ARRIVAL_DISTANCE:
		var key: String = ent.id + "_" + best_entity.id
		var last: float = _cooldowns.get(key, 0.0)
		var now: float = Time.get_ticks_msec() / 1000.0
		if now - last > LilaConstants.INTERACTION_COOLDOWN:
			_cooldowns[key] = now
			events.append({
				"type": "predation",
				"source_id": ent.id,
				"target_id": best_entity.id,
				"position": [ent.x, 0.0, ent.z],
			})
		return {"target": Vector2.ZERO, "events": events}

	if best_target != Vector2.ZERO:
		return {"target": best_target, "events": events}
	return {"target": Vector2.ZERO, "events": events}


func _evaluate_pollination(ent, world: Node) -> Dictionary:
	var species_def: Dictionary = world.species_defs.get(ent.species, {})
	var poll_targets: Array = species_def.get("pollination_targets", [])

	var events: Array = []
	var best_target: Vector2 = Vector2.ZERO
	var best_dist: float = INF
	var best_entity: Variant = null

	var candidates: Array = world.get_alive()
	for candidate in candidates:
		if candidate.type == "PLANT" and candidate.state == "FRUITING":
			if poll_targets.is_empty() or poll_targets.has(candidate.species):
				var dist: float = sqrt((ent.x - candidate.x) ** 2 + (ent.z - candidate.z) ** 2)
				if dist < best_dist:
					best_dist = dist
					best_target = Vector2(candidate.x, candidate.z)
					best_entity = candidate

	if best_entity != null and best_dist < LilaConstants.ARRIVAL_DISTANCE:
		var key: String = ent.id + "_" + best_entity.id
		var last: float = _cooldowns.get(key, 0.0)
		var now: float = Time.get_ticks_msec() / 1000.0
		if now - last > LilaConstants.INTERACTION_COOLDOWN:
			_cooldowns[key] = now
			events.append({
				"type": "pollination",
				"source_id": ent.id,
				"target_id": best_entity.id,
				"position": [ent.x, 0.0, ent.z],
			})
		return {"target": Vector2.ZERO, "events": events}

	if best_target != Vector2.ZERO:
		return {"target": best_target, "events": events}
	return {"target": Vector2.ZERO, "events": events}


func _evaluate_wandering(ent, delta: float) -> Vector2:
	# Reuse existing wander target if still valid and not reached (mirrors Python/browser)
	if ent.has_target and ent.last_action_type == "wander":
		var dtx: float = ent.target_x - ent.x
		var dtz: float = ent.target_z - ent.z
		if sqrt(dtx * dtx + dtz * dtz) > 0.5:
			return Vector2(ent.target_x, ent.target_z)

	# Pick new wander target modulated by motion latent
	var latent: PackedFloat32Array = ent.motion_latent
	var pace: float = 1.0
	if latent.size() >= 1:
		pace = 0.5 + latent[0] * 0.5  # Map to 0-1 range roughly

	var wander_range: float = LilaConstants.WANDER_MARGIN * pace
	var angle: float = randf() * TAU
	var target_x: float = clampf(ent.x + cos(angle) * wander_range, 0.0, float(LilaConstants.GRID_SIZE - 1))
	var target_z: float = clampf(ent.z + sin(angle) * wander_range, 0.0, float(LilaConstants.GRID_SIZE - 1))

	return Vector2(target_x, target_z)


func _move_toward(ent, target: Vector2, delta: float, world: Node) -> void:
	var dx: float = target.x - ent.x
	var dz: float = target.y - ent.z
	var dist: float = sqrt(dx * dx + dz * dz)

	# Speed from species definition
	var species_def: Dictionary = world.species_defs.get(ent.species, {})
	var max_speed: float = species_def.get("movement_speed", 2.0)

	# Modulate by motion latent pace
	var latent: PackedFloat32Array = ent.motion_latent
	var pace: float = 1.0
	if latent.size() >= 1:
		pace = 0.5 + latent[0] * 0.5

	var move_dist: float = max_speed * pace * delta
	move_dist = minf(move_dist, dist)

	if dist < LilaConstants.ARRIVAL_DISTANCE:
		ent.has_target = false
		return

	var move_x: float = (dx / dist) * move_dist
	var move_z: float = (dz / dist) * move_dist

	ent.x += move_x
	ent.z += move_z

	# Smoothly interpolate facing direction (no instant snaps)
	var target_angle: float = atan2(dz, dx)
	var angle_diff: float = wrapf(target_angle - ent.facing_angle, -PI, PI)
	ent.facing_angle += clampf(angle_diff, -LilaConstants.TURN_SPEED * delta, LilaConstants.TURN_SPEED * delta)

	# Track target for wander persistence (mirrors Python/browser hasTarget)
	ent.target_x = target.x
	ent.target_z = target.y
	ent.has_target = true
