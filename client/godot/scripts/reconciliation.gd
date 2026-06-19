## Position reconciliation between client agency and server reference positions.
## Mirrors browser reconciliation.js and Python reconciliation.py.
class_name Reconciliation


## Called after each tick packet. Reconciles all mobile entities.
static func reconcile(world: Node, tick: int) -> void:
	var mobile: Array = world.get_alive_mobile()
	for ent in mobile:
		_reconcile_entity(ent, tick)


static func _reconcile_entity(ent, tick: int) -> void:
	# Server acknowledged our deviation — trust it fully
	if ent.ack:
		ent.reconcile_queue.clear()
		ent.reconcile_idx = 0
		ent.x = ent.ref_x
		ent.z = ent.ref_z
		return

	var dx: float = ent.ref_x - ent.x
	var dz: float = ent.ref_z - ent.z
	var divergence: float = sqrt(dx * dx + dz * dz)

	if divergence < LilaConstants.RECONCILE_MIN_DIVERGENCE:
		return

	# Stagger sync: only reconcile every Nth tick based on sync_phase
	var phase_aligned: bool = (tick % 4) == ent.sync_phase
	if not phase_aligned and ent.reconcile_queue.size() > 0:
		return

	# Enqueue ref_position as reconcile target (cap queue)
	if ent.reconcile_queue.size() < LilaConstants.RECONCILE_QUEUE_MAX:
		ent.reconcile_queue.append(Vector2(ent.ref_x, ent.ref_z))
		ent.reconcile_idx = 0
