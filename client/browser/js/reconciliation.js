// ═══════════════════════════════════════════════════════
// līlā — Reconciliation (Client ↔ Server Position Sync)
//
// When a new tick packet arrives, reconcile client-agency positions
// with server reference positions. Trust the client within bounds;
// gently correct when divergence exceeds expected travel distance.
//
// Each tick, divergent entities get their ref_position enqueued as a
// reconcile target. The agency system then smoothly meanders toward
// that target over the next ~2 seconds. If a new target arrives before
// the old one is reached, the entity transitions smoothly (no snap).
//
// Each entity has a unique sync personality (_syncPhase, _syncSpeed)
// so they don't all queue reconciliation targets at the same time —
// the sync looks organic, not mechanical.
//
// Additionally, a continuous gravity well pulls all entities gently
// toward their ref_position during normal agency, preventing sudden
// direction changes when new tick targets arrive.
// ═══════════════════════════════════════════════════════

/**
 * Enqueue reconciliation targets after receiving a new tick packet.
 *
 * Does NOT modify positions directly — the agency system at 60fps
 * consumes the queue and moves entities smoothly.
 *
 * Entities are staggered across ticks using _syncPhase (0..3) so
 * not all entities react to the sync pulse simultaneously.
 *
 * Called once per server tick, not every frame.
 */
export function reconcile(world, tick) {
  for (const ent of world.entities.values()) {
    if (!ent.isMobileConsumer || !ent.isAlive) continue;

    // ── Staggered reaction: each entity has a syncPhase (0..3)
    // Only enqueue reconcile targets when the tick aligns with phase.
    // This spreads the "nudge" across frames so it looks organic.
    const ticksSinceLast = tick - ent._lastReconciledTick;
    if (ticksSinceLast < ent._syncPhase) {
      continue; // not this entity's turn yet
    }

    // Server acknowledged our deviation — trust it fully.
    // Clear any pending reconcile targets since server now matches us.
    if (ent.ackReceived) {
      ent._reconcileQueue = [];
      ent._reconcileIdx = 0;
      ent._lastReconciledTick = tick;
      continue;
    }

    const dx = ent.x - ent.refX;
    const dz = ent.z - ent.refZ;
    const divergence = Math.sqrt(dx * dx + dz * dz);

    if (divergence < 0.1) {
      // Negligible drift — nothing to reconcile.
      // Prune completed targets.
      ent._reconcileQueue = ent._reconcileQueue.slice(ent._reconcileIdx);
      ent._reconcileIdx = 0;
      ent._lastReconciledTick = tick;
      continue;
    }

    // Prune completed targets before enqueueing new one.
    ent._reconcileQueue = ent._reconcileQueue.slice(ent._reconcileIdx);
    ent._reconcileIdx = 0;

    // Enqueue the ref_position as a reconcile target.
    // If there's already an unfinished target, append — the agency
    // system will chain through them smoothly.
    ent._reconcileQueue.push([ent.refX, ent.refZ]);

    // If the queue grew too long (entity falling behind), keep only
    // the latest target to avoid chasing ghosts.
    if (ent._reconcileQueue.length > 2) {
      ent._reconcileQueue = [ent._reconcileQueue[ent._reconcileQueue.length - 1]];
    }

    ent._lastReconciledTick = tick;
  }
}

/** Check if an entity has pending reconciliation work. */
export function hasReconcileTarget(ent) {
  return ent._reconcileIdx < ent._reconcileQueue.length;
}

/** Get the current reconcile target [tx, tz] for an entity. */
export function getReconcileTarget(ent) {
  const idx = Math.min(ent._reconcileIdx, ent._reconcileQueue.length - 1);
  return ent._reconcileQueue[idx];
}

/** Advance to the next target in the queue (called when current is reached). */
export function advanceReconcile(ent) {
  ent._reconcileIdx += 1;
}
