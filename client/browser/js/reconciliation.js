// ═══════════════════════════════════════════════════════
// līlā — Reconciliation (Client ↔ Server Position Sync)
//
// When a new tick packet arrives, reconcile client-agency positions
// with server reference positions. Trust the client within bounds;
// gently correct when divergence exceeds expected travel distance.
//
// Each entity has a unique sync personality (_syncPhase, _syncSpeed)
// so they don't all nudge at the same time — the sync looks organic,
// not mechanical.
// ═══════════════════════════════════════════════════════

import { SERVER_TICK_RATE } from './constants.js';

/**
 * Reconcile entities after receiving a new tick packet.
 * Called once per server tick, not every frame.
 *
 * Entities are staggered across frames using _syncPhase (0..3) so
 * not all entities react to the sync pulse simultaneously.
 */
export function reconcile(world, tick) {
  for (const ent of world.entities.values()) {
    if (!ent.isMobileConsumer || !ent.isAlive) continue;

    // ── Staggered reaction: each entity has a syncPhase (0..3)
    // Only reconcile this entity when the tick aligns with its phase.
    // This spreads the "nudge" across 4 frames so it looks organic.
    const ticksSinceLastReconcile = tick - ent._lastReconciledTick;
    if (ticksSinceLastReconcile < ent._syncPhase) {
      continue; // not this entity's turn yet
    }

    // If server acknowledged our deviation, trust it fully — no correction needed
    if (ent.ackReceived) {
      // Server snapped to our position. Sync client x/z to ref.
      ent.x = ent.refX;
      ent.z = ent.refZ;
      ent._lastReconciledTick = tick;
      continue;
    }

    const dx = ent.x - ent.refX;
    const dz = ent.z - ent.refZ;
    const divergence = Math.sqrt(dx * dx + dz * dz);

    if (divergence < 0.1) {
      ent._lastReconciledTick = tick;
      continue; // negligible drift
    }

    // Expected max travel per server tick interval
    const speed = ent.speed || 2.0;
    const expectedTravel = speed * SERVER_TICK_RATE;

    // Per-entity sync speed: some entities are sluggish, others quick
    const speedFactor = ent._syncSpeed ?? 1.0;

    if (divergence <= expectedTravel * 2.5) {
      // Within bounds — soft nudge toward reference (gravity well)
      const nudgeFactor = 0.15 * speedFactor; // modulated by entity personality
      ent.x -= dx * nudgeFactor;
      ent.z -= dz * nudgeFactor;
    } else {
      // Significant divergence — lerp more aggressively toward reference.
      // The server will likely send _ack on next tick if this persists.
      const snapFactor = 0.5 * speedFactor;
      ent.x -= dx * snapFactor;
      ent.z -= dz * snapFactor;
    }

    ent._lastReconciledTick = tick;
  }
}
