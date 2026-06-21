# līlā — Godot 4.x 3D Client
# Copyright 2025 BioSynthArt Studios LLC
# Licensed under the Apache License, Version 2.0
#
# scripts/reconciliation.gd — Position reconciliation
#
# Reconciles client-agency positions with server reference positions.
# Mirrors browser reconciliation.js and Python reconciliation.py.
#
# When a new tick packet arrives, reconcile client positions within bounds;
# gently correct when divergence exceeds expected travel distance.
##
## Each tick, divergent entities get their ref_position enqueued as a
## reconcile target. The agency system then smoothly meanders toward
## that target over the next ~2 seconds. If a new target arrives before
## the old one is reached, the entity transitions smoothly (no snap).
##
## Each entity has a unique sync personality (sync_phase, sync_speed)
## so they don't all queue reconciliation targets at the same time.
##
## Additionally, a continuous gravity well pulls all entities gently
## toward their ref_position during normal agency, preventing sudden
## direction changes when new tick targets arrive.
class_name Reconciliation


## Called after each tick packet. Reconciles all mobile entities.
static func reconcile(world: Node, tick: int) -> void:
	var mobile: Array = world.get_alive_mobile()
	for ent in mobile:
		_reconcile_entity(ent, tick)


static func _reconcile_entity(ent, tick: int) -> void:
	# Staggered reaction: each entity has a sync_phase (0..3)
	# Only enqueue reconcile targets when ticks since last reconcile >= phase.
	# This spreads the "nudge" across frames so it looks organic.
	var ticks_since_last: int = tick - ent.last_reconciled_tick
	if ticks_since_last < ent.sync_phase:
		return  # not this entity's turn yet

	# Server acknowledged our deviation — trust it fully.
	# Clear any pending reconcile targets since server now matches us.
	if ent.ack:
		ent.reconcile_queue.clear()
		ent.reconcile_idx = 0
		ent.last_reconciled_tick = tick
		return

	var dx: float = ent.x - ent.ref_x
	var dz: float = ent.z - ent.ref_z
	var divergence: float = sqrt(dx * dx + dz * dz)

	if divergence < LilaConstants.RECONCILE_MIN_DIVERGENCE:
		# Negligible drift — nothing to reconcile.
		# Prune completed targets.
		_prune_queue(ent)
		ent.last_reconciled_tick = tick
		return

	# Prune completed targets before enqueueing new one.
	_prune_queue(ent)

	# Enqueue the ref_position as a reconcile target.
	# If there's already an unfinished target, append — the agency
	# system will chain through them smoothly.
	if ent.reconcile_queue.size() < LilaConstants.RECONCILE_QUEUE_MAX:
		ent.reconcile_queue.append(Vector2(ent.ref_x, ent.ref_z))

	# If the queue grew too long (entity falling behind), keep only
	# the latest target to avoid chasing ghosts.
	if ent.reconcile_queue.size() > LilaConstants.RECONCILE_QUEUE_MAX:
		ent.reconcile_queue = PackedVector2Array([ent.reconcile_queue[-1]])
		ent.reconcile_idx = 0

	ent.last_reconciled_tick = tick


static func _prune_queue(ent) -> void:
	"""Prune completed targets from the reconcile queue."""
	if ent.reconcile_idx > 0 and ent.reconcile_idx < ent.reconcile_queue.size():
		var remaining: PackedVector2Array = PackedVector2Array()
		for i in range(ent.reconcile_idx, ent.reconcile_queue.size()):
			remaining.append(ent.reconcile_queue[i])
		ent.reconcile_queue = remaining
		ent.reconcile_idx = 0
	elif ent.reconcile_idx >= ent.reconcile_queue.size():
		ent.reconcile_queue.clear()
		ent.reconcile_idx = 0
