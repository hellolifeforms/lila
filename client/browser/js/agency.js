// ═══════════════════════════════════════════════════════
// līlā — Client-Side Agency Engine
//
// Between server ticks, each mobile entity decides what to do based on:
//   - Server intent (state + drives + eligibility flags)
//   - Local perception (nearest food, water, threats from world model)
//   - Motion latent (modulates speed, hesitation, path curvature)
//   - Gravity well toward server ref_position (continuous pull)
//
// This is the "body" in "server is nervous system, client is body."
// ═══════════════════════════════════════════════════════

import { GRID_SIZE } from './constants.js';
import { hasReconcileTarget, getReconcileTarget, advanceReconcile } from './reconciliation.js';

// Gravity well: gentle pull toward ref_position, always active.
// ~0.05 × speed per frame ≈ 3 units/s pull, enough to drift back
// without overpowering the entity's desired behavior.
// Each entity also has _syncSpeed (0.4..1.0) that modulates this.
const GRAVITY_WELL_FACTOR = 0.05;

// Flee direction cache: how long (ms) to keep running in the last
// known safe direction when no threat is found. Mirrors server
// behavior: FleeActor computes escape once, guard exits on arrival.
const FLEE_DIR_TIMEOUT_MS = 3000;

/**
 * Run one frame of local agency for all mobile entities.
 * Called every render frame (~60 Hz).
 */
export function stepAgency(world, dt) {
  const events = []; // client-reported events to send upstream

  for (const ent of world.entities.values()) {
    if (!ent.isMobileConsumer || !ent.isAlive) continue;

    // Update speed from species definition (once)
    if (!ent._speedSet) {
      const def = world.getSpeciesDef(ent.species);
      ent.speed = def?.movement_speed ?? 2.0;
      ent._speedSet = true;
    }

    // Reconciling entities meander toward their queued target
    if (hasReconcileTarget(ent)) {
      const [tx, tz] = getReconcileTarget(ent);
      if (executeReconcileMeander(ent, tx, tz, world, dt)) {
        advanceReconcile(ent);
      }
    } else {
      // Normal agency: evaluate behavior + gravity well toward ref
      const action = evaluateBehavior(ent, world);
      executeAction(ent, action, world, dt, events);
      applyGravityWell(ent, world, dt);
    }
  }

  return events;
}

/**
 * Gently pull entity toward server ref_position.
 * Always active during normal agency. Each entity has its own
 * _syncSpeed (0.4..1.0) so the pull strength varies per entity,
 * making the sync look organic rather than uniform.
 */
function applyGravityWell(ent, world, dt) {
  const dx = ent.refX - ent.x;
  const dz = ent.refZ - ent.z;
  const dist = Math.sqrt(dx * dx + dz * dz);

  if (dist < 0.2) return; // Already close enough

  // Per-entity sync speed modulates the gravity well strength.
  const speedFactor = ent._syncSpeed ?? 0.7;
  const nudge = GRAVITY_WELL_FACTOR * speedFactor * dt;
  ent.x += dx * nudge;
  ent.z += dz * nudge;
  ent.x = clamp(ent.x, GRID_SIZE);
  ent.z = clamp(ent.z, GRID_SIZE);
}

/**
 * Meander a reconciling entity toward its queued target (tx, tz).
 *
 * Produces a spiral/circle motion: radial pull toward target combined
 * with a perpendicular wobble. Returns true when the entity has arrived.
 *
 * The approach curve accelerates as the entity gets closer — it circles
 * wide at first then tightens into the target, like a bird landing.
 *
 * Each entity's _syncSpeed modulates the approach rate.
 */
function executeReconcileMeander(ent, tx, tz, world, dt) {
  const dx = tx - ent.x;
  const dz = tz - ent.z;
  const dist = Math.sqrt(dx * dx + dz * dz);

  if (dist < 0.5) {
    // Close enough — advance to next target
    ent.velocityX = 0;
    ent.velocityZ = 0;
    return true;
  }

  const nx = dx / dist;
  const nz = dz / dist;

  // Perpendicular direction (rotate 90°)
  const px = -nz;
  const pz = nx;

  const speed = ent.speed || 2.0;

  // Per-entity sync speed modulates the radial approach rate.
  const speedFactor = ent._syncSpeed ?? 0.7;

  // Radial step: move toward target
  const radialStep = Math.min(speed * 1.5 * speedFactor * dt, dist);

  // Perpendicular wobble: wide circles that tighten as we approach.
  // Wobble amplitude scales with distance — large arcs far away,
  // gentle spirals near the target.
  const wobblePhase = performance.now() * 0.003 * 3 + entityPhase(ent.id);
  const wobbleAmp = Math.sin(wobblePhase) * Math.min(speed * 0.5, dist * 0.3);
  const wobbleStep = wobbleAmp * dt;

  ent.x += nx * radialStep + px * wobbleStep;
  ent.z += nz * radialStep + pz * wobbleStep;
  ent.x = clamp(ent.x, GRID_SIZE);
  ent.z = clamp(ent.z, GRID_SIZE);

  // Update velocity and facing
  ent.velocityX = nx * speed * 1.5 * speedFactor + px * wobbleAmp;
  ent.velocityZ = nz * speed * 1.5 * speedFactor + pz * wobbleAmp;
  ent.facingAngle = lerpAngle(
    ent.facingAngle, Math.atan2(dz, dx), 0.12
  );

  return false;
}

/**
 * Deterministic per-entity offset for wobble phase.
 */
function entityPhase(eid) {
  let h = 0;
  for (let i = 0; i < eid.length; i++) {
    h = (h * 31 + eid.charCodeAt(i)) & 0xFFFF;
  }
  return (h / 65536) * 2 * Math.PI;
}

/**
 * Spherical lerp between two angles (handles wrapping at ±π).
 */
function lerpAngle(a, b, t) {
  const diff = Math.atan2(Math.sin(b - a), Math.cos(b - a));
  return a + diff * t;
}

// ─── Behavior Evaluators ──────────────────────────────

/**
 * Evaluate what an entity should do based on its intent and local perception.
 * Returns { type, target? } describing the desired action.
 */
function evaluateBehavior(ent, world) {
  const state = ent.state;
  const drive = ent.drive || {};
  const speciesDef = world.getSpeciesDef(ent.species);

  // ── Fleeing (highest priority — threat detected locally) ──
  if (state === 'FLEEING') {
    return evaluateFleeing(ent, world, speciesDef);
  }

  // ── Drinking ──
  if (state === 'DRINKING' || (ent.canDrink && (drive.hydration ?? 1.0) < 0.3)) {
    return evaluateDrinking(ent, world);
  }

  // ── Reproduction seeking ──
  if (ent.reproEligible && (drive.reproductive_drive ?? 0) > 0.5) {
    const mateAction = evaluateMateSeeking(ent, world);
    if (mateAction) return mateAction;
  }

  // ── Foraging / Herbivory ──
  if (state === 'FORAGING' && ent.canConsume) {
    return evaluateForaging(ent, world, speciesDef);
  }

  // ── Hunting / Predation ──
  if ((state === 'HUNTING' || state === 'FORAGING') && ent.canPredatate) {
    return evaluateHunting(ent, world, speciesDef);
  }

  // ── Pollination ──
  if (ent.canPollinate && speciesDef?.is_pollinator) {
    return evaluatePollination(ent, world, speciesDef);
  }

  // ── Resting / Idle — wander with latent-modulated style ──
  return evaluateWandering(ent, world);
}

function evaluateFleeing(ent, world, speciesDef) {
  const fleeTargets = speciesDef?.flee_targets || [];
  if (fleeTargets.length === 0) return evaluateWandering(ent, world);

  const now = performance.now();

  // Find nearest threat
  let nearestThreat = null;
  let bestDistSq = Infinity;
  for (const other of world.entities.values()) {
    if (!other.isAlive) continue;
    const def = world.getSpeciesDef(other.species);
    if (!def || !fleeTargets.includes(other.species)) continue;
    const d2 = ent.distSqTo(other);
    if (d2 < bestDistSq) {
      bestDistSq = d2;
      nearestThreat = other;
    }
  }

  if (nearestThreat && bestDistSq < 400) { // ~20 world units sensory range²
    // Threat confirmed — cache the flee direction
    const dx = ent.x - nearestThreat.x;
    const dz = ent.z - nearestThreat.z;
    const dist = Math.sqrt(dx * dx + dz * dz) || 1;
    ent._fleeDirX = dx / dist;
    ent._fleeDirZ = dz / dist;
    ent._fleeDirExpiry = now + FLEE_DIR_TIMEOUT_MS;
  }

  // Use cached flee direction as fallback.
  // The server computes the escape target once (FleeActor fires on entry only)
  // and holds it until arrival. Mirror this: if the threat is not found this
  // frame (client/server divergence, stale positions, etc.), keep running in
  // the last known safe direction for a short window.
  if (ent._fleeDirX != null && now < ent._fleeDirExpiry) {
    return {
      type: 'flee',
      targetX: clamp(ent.x + ent._fleeDirX * 8, GRID_SIZE),
      targetZ: clamp(ent.z + ent._fleeDirZ * 8, GRID_SIZE),
    };
  }

  // No threat and no cached direction — fall through to wander
  return evaluateWandering(ent, world);
}

function evaluateDrinking(ent, world) {
  const water = world.findNearestWater(ent.x, ent.z);
  if (water) {
    // Approach water source edge
    const wx = water.position[0], wz = water.position[2];
    const r = water.radius || 1;
    const dx = wx - ent.x, dz = wz - ent.z;
    const dist = Math.sqrt(dx * dx + dz * dz) || 1;
    // Approach to just outside the water edge
    const approachR = Math.max(r - 0.5, 0.3);
    return {
      type: 'drink',
      targetX: clamp(wx - (dx / dist) * approachR, GRID_SIZE),
      targetZ: clamp(wz - (dz / dist) * approachR, GRID_SIZE),
    };
  }
  return evaluateWandering(ent, world);
}

function evaluateMateSeeking(ent, world) {
  let best = null;
  let bestDist = 15; // sensory range
  for (const other of world.entities.values()) {
    if (other.id === ent.id) continue;
    if (other.species !== ent.species) continue;
    if (!other.isAlive) continue;
    const d = ent.distanceTo(other);
    if (d < bestDist) {
      bestDist = d;
      best = other;
    }
  }
  if (best) {
    return {
      type: 'seek_mate',
      targetX: best.x,
      targetZ: best.z,
      targetId: best.id,
    };
  }
  return null; // no mate nearby, fall through to other behaviors
}

function evaluateForaging(ent, world, speciesDef) {
  const dietOrder = speciesDef?.diet_order || [];

  // Try each food preference in order
  for (const entry of dietOrder) {
    // Handle both tuple format ["species", 1.0] and bare string "species"
    const foodSpecies = Array.isArray(entry) ? entry[0] : entry;
    const food = world.findNearestSpecies(ent.x, ent.z, [foodSpecies], ent.id);
    if (food && ent.distanceTo(food) < 15) {
      return {
        type: 'forage',
        targetX: food.x,
        targetZ: food.z,
        targetId: food.id,
      };
    }
  }

  // No preferred food — wander to search
  return evaluateWandering(ent, world);
}

function evaluateHunting(ent, world, speciesDef) {
  const dietOrder = speciesDef?.diet_order || [];
  const preySpecies = dietOrder.map(entry =>
    Array.isArray(entry) ? entry[0] : entry
  );

  if (preySpecies.length > 0) {
    const prey = world.findNearestSpecies(ent.x, ent.z, preySpecies, ent.id);
    if (prey && ent.distanceTo(prey) < 15) {
      return {
        type: 'hunt',
        targetX: prey.x,
        targetZ: prey.z,
        targetId: prey.id,
      };
    }
  }

  // No prey — wander (or fall back to foraging if omnivore)
  return evaluateWandering(ent, world);
}

function evaluatePollination(ent, world, speciesDef) {
  const pollTargets = speciesDef?.pollination_targets || [];
  if (pollTargets.length === 0) return evaluateWandering(ent, world);

  // Find nearest FRUITING flower
  for (const flower of world.entities.values()) {
    if (!flower.isAlive) continue;
    if (!pollTargets.includes(flower.species)) continue;
    if (flower.state !== 'FRUITING') continue;
    const dist = ent.distanceTo(flower);
    if (dist < 15 && dist > 0.5) {
      return {
        type: 'pollinate',
        targetX: flower.x,
        targetZ: flower.z,
        targetId: flower.id,
      };
    }
  }

  // No fruiting flowers — wander to search
  return evaluateWandering(ent, world);
}

function evaluateWandering(ent, world) {
  // Reuse existing wander target if still valid and not reached
  if (ent.hasTarget && ent._lastActionType === 'wander') {
    const dx = ent.targetX - ent.x;
    const dz = ent.targetZ - ent.z;
    if (Math.sqrt(dx * dx + dz * dz) > 0.5) {
      // Still have distance to current wander target — keep it
      return { type: 'wander', targetX: ent.targetX, targetZ: ent.targetZ };
    }
  }

  const ml = ent.motionLatent || [0, 0, 0, 0];
  const urgency = Math.abs(ml[0]); // dim 0 = pace/urgency

  // Wander range modulated by urgency — high urgency = tighter wander
  const wanderRange = 2 + (1 - urgency) * 4;
  return {
    type: 'wander',
    targetX: clamp(ent.x + (Math.random() - 0.5) * wanderRange * 2, GRID_SIZE),
    targetZ: clamp(ent.z + (Math.random() - 0.5) * wanderRange * 2, GRID_SIZE),
  };
}

// ─── Action Execution ─────────────────────────────────

/**
 * Execute an action for one entity over one frame.
 * Handles movement toward target and interaction triggers.
 */
function executeAction(ent, action, world, dt, events) {
  if (!action || (!action.targetX && action.type !== 'wander')) return;

  const ml = ent.motionLatent || [0, 0, 0, 0];
  const urgency = (ml[0] + 1) * 0.5; // normalize to 0..1
  const caution = Math.abs(ml[1]);   // dim 1 = alertness

  // Base speed from species or default
  const baseSpeed = ent.speed || 2.0;

  // Modulate speed by action type
  const speedMods = {
    flee: 1.5 + urgency * 0.5,
    hunt: 1.2 + urgency * 0.3,
    forage: 0.8 + urgency * 0.4,
    drink: 0.7,
    seek_mate: 0.6 + urgency * 0.3,
    pollinate: 0.5 + urgency * 0.3,
  };
  const speedMod = speedMods[action.type] ?? (0.3 + (1 - caution) * 0.4);

  const effectiveSpeed = baseSpeed * speedMod;

  const targetX = action.targetX ?? ent.x;
  const targetZ = action.targetZ ?? ent.z;

  // Move toward target
  const dx = targetX - ent.x;
  const dz = targetZ - ent.z;
  const dist = Math.sqrt(dx * dx + dz * dz);

  if (dist > 0.1) {
    const step = Math.min(effectiveSpeed * dt, dist);
    // Add slight curvature based on caution (dim 1) — high caution = more wobble
    const wobble = caution * Math.sin(performance.now() * 0.003 + ent.x) * 0.3;

    ent.x += (dx / dist) * step + wobble * dt;
    ent.z += (dz / dist) * step - wobble * dt;
    ent.x = clamp(ent.x, GRID_SIZE);
    ent.z = clamp(ent.z, GRID_SIZE);

    ent.velocityX = (dx / dist) * effectiveSpeed;
    ent.velocityZ = (dz / dist) * effectiveSpeed;

    // Lerp facing angle toward travel direction (smooth rotation)
    const targetAngle = Math.atan2(dz, dx);
    ent.facingAngle = lerpAngle(ent.facingAngle, targetAngle, 0.15);
  } else {
    // Arrived at target
    ent.velocityX = 0;
    ent.velocityZ = 0;

    // Check for interaction triggers on arrival (with cooldown)
    checkInteraction(ent, action, world, events);

    // Reset wander target so next frame picks a new one
    if (action.type === 'wander') {
      ent.hasTarget = false;
    }
  }

  ent.targetX = targetX;
  ent.targetZ = targetZ;
  ent._lastActionType = action.type;
  ent.hasTarget = true;
}

/**
 * Check if an entity should trigger an interaction on target arrival.
 * Reports events upstream for server absorption.
 * Uses per-target cooldown to prevent event spam.
 */
function checkInteraction(ent, action, world, events) {
  const targetId = action.targetId;
  if (!targetId) return;

  const targetEnt = world.entities.get(targetId);
  if (!targetEnt || !targetEnt.isAlive) return;

  const dist = ent.distanceTo(targetEnt);
  if (dist > 3.0) return; // too far for any interaction

  // Cooldown: don't re-interact with same target within 2 seconds
  const now = performance.now();
  if (!ent._interactionCooldowns) ent._interactionCooldowns = {};
  const key = `${ent.id}:${targetId}`;
  const cooldownMs = 2000;
  if (ent._interactionCooldowns[key] && (now - ent._interactionCooldowns[key]) < cooldownMs) {
    return; // still on cooldown
  }

  switch (action.type) {
    case 'forage':
      if (dist < 2.0 && ent.canConsume) {
        events.push({
          type: 'consumption',
          source_id: ent.id,
          target_id: targetId,
          position: [targetEnt.x, 0, targetEnt.z],
        });
        ent._interactionCooldowns[key] = now;
      }
      break;

    case 'hunt':
      if (dist < 1.5 && ent.canPredatate) {
        events.push({
          type: 'predation',
          source_id: ent.id,
          target_id: targetId,
          kill_position: [targetEnt.x, 0, targetEnt.z],
        });
        ent._interactionCooldowns[key] = now;
      }
      break;

    case 'pollinate':
      if (dist < 1.5 && ent.canPollinate) {
        events.push({
          type: 'pollination',
          source_id: ent.id,
          target_id: targetId,
          position: [targetEnt.x, 0, targetEnt.z],
        });
        ent._interactionCooldowns[key] = now;
      }
      break;

    case 'seek_mate':
      if (dist < 3.0 && ent.reproEligible) {
        events.push({
          type: 'repro',
          parent_id: ent.id,
          offspring_count: 1,
          client_position: [ent.x, 0, ent.z],
        });
        ent._interactionCooldowns[key] = now;
      }
      break;
  }
}

// ─── Helpers ──────────────────────────────────────────

function clamp(v, max) {
  return Math.max(0.5, Math.min(max - 0.5, v));
}
