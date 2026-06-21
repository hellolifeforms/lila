# līlā — Python Client
# Copyright 2025 BioSynthArt Studios LLC
# Licensed under the Apache License, Version 2.0
#
# lila_client/reconciliation.py — Reconciliation (Client ↔ Server Position Sync)
#
# When a new tick packet arrives, reconcile client-agency positions
with server reference positions. Trust the client within bounds;
gently correct when divergence exceeds expected travel distance.

Each tick, divergent entities get their ref_position enqueued as a
reconcile target. The agency system then smoothly meanders toward
that target over the next ~2 seconds. If a new target arrives before
the old one is reached, the entity transitions smoothly (no snap).

Each entity has a unique sync personality (_sync_phase, _sync_speed)
so they don't all queue reconciliation targets at the same time —
the sync looks organic, not mechanical.

Additionally, a continuous gravity well pulls all entities gently
toward their ref_position during normal agency, preventing sudden
direction changes when new tick targets arrive.
"""

from __future__ import annotations


def reconcile(world, tick: int) -> None:
    """Enqueue reconciliation targets after receiving a new tick packet.

    Does NOT modify positions directly — the agency system at 60fps
    consumes the queue and moves entities smoothly.

    Entities are staggered across ticks using _sync_phase (0..3) so
    not all entities react to the sync pulse simultaneously.

    Called once per server tick, not every frame.
    """
    import math

    for ent in world.entities.values():
        if not ent.is_mobile_consumer or not ent.is_alive:
            continue

        # ── Staggered reaction: each entity has a syncPhase (0..3)
        # Only enqueue reconcile targets when the tick aligns with phase.
        # This spreads the "nudge" across frames so it looks organic.
        ticks_since_last = tick - ent._last_reconciled_tick
        if ticks_since_last < ent._sync_phase:
            continue  # not this entity's turn yet

        # Server acknowledged our deviation — trust it fully.
        # Clear any pending reconcile targets since server now matches us.
        if ent.ack_received:
            ent._reconcile_queue.clear()
            ent._reconcile_idx = 0
            ent._last_reconciled_tick = tick
            continue

        dx = ent.x - ent.ref_x
        dz = ent.z - ent.ref_z
        divergence = math.sqrt(dx * dx + dz * dz)

        if divergence < 0.1:
            # Negligible drift — nothing to reconcile.
            # Prune completed targets.
            ent._reconcile_queue = ent._reconcile_queue[ent._reconcile_idx:]
            ent._reconcile_idx = 0
            ent._last_reconciled_tick = tick
            continue

        # Prune completed targets before enqueueing new one.
        ent._reconcile_queue = ent._reconcile_queue[ent._reconcile_idx:]
        ent._reconcile_idx = 0

        # Enqueue the ref_position as a reconcile target.
        # If there's already an unfinished target, append — the agency
        # system will chain through them smoothly.
        ent._reconcile_queue.append((ent.ref_x, ent.ref_z))

        # If the queue grew too long (entity falling behind), keep only
        # the latest target to avoid chasing ghosts.
        if len(ent._reconcile_queue) > 2:
            ent._reconcile_queue = [ent._reconcile_queue[-1]]

        ent._last_reconciled_tick = tick


def has_reconcile_target(ent) -> bool:
    """Check if an entity has pending reconciliation work."""
    return ent._reconcile_idx < len(ent._reconcile_queue)


def get_reconcile_target(ent) -> tuple[float, float]:
    """Get the current reconcile target (tx, tz) for an entity."""
    idx = min(ent._reconcile_idx, len(ent._reconcile_queue) - 1)
    return ent._reconcile_queue[idx]


def advance_reconcile(ent) -> None:
    """Advance to the next target in the queue (called when current is reached)."""
    ent._reconcile_idx += 1
