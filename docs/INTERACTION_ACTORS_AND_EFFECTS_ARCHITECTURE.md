# Interaction Actor Model + Effects Architecture

**Status:** Phase 1 ✅ Complete · Phase 2 ✅ Complete · Phase 3 (Distributed Readiness) Pending  
**Created:** 2026-05-30  
**Last Updated:** 2026-06-16  
**Owner:** līlā Ecosystem Engine Team  

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Architecture Overview](#architecture-overview)
3. [Effects Model — Immutable Delta Descriptions](#effects-model--immutable-delta-descriptions)
4. [Interaction Actor Protocol](#interaction-actor-protocol)
5. [Phase 1: Effects Extraction + Interaction Actors ✅ COMPLETE](#phase-1-effects-extraction--interaction-actors-complete)
6. [Phase 2: Flow + Guard Actors ✅ Complete](#phase-2-flow--guard-actors-complete)
7. [Phase 3: Distributed Readiness (Future)](#phase-3-distributed-readiness-future)
8. [Serialization Layer — Pluggable Format Design](#serialization-layer--pluggable-format-design)
9. [Effect Application Order & Conflict Resolution](#effect-application-order--conflict-resolution)
10. [File Structure](#file-structure)
11. [Open Questions](#open-questions)

---

## Executive Summary

This document describes the līlā ecosystem engine's **Interaction Actor Model** with an **Immutable Effects System**. The result is:

- **Distributed-ready**: Effects are immutable data structures that can be serialized, transmitted across network boundaries, and replayed deterministically.
- **Truly parallel**: All actors run concurrently (read-only state → effects emission), then effects are applied atomically in a single batch pass. No entity mutates another's state during actor execution.
- **Extensible**: Adding a new interaction type requires only one actor class + its effect types. The engine core never changes.
- **Testable**: Actors are pure functions of their context — unit-testable without the full simulation harness.

---

## Architecture Overview

### `engine.py` (~782 lines after decomposition) — Thin Orchestrator

The engine coordinates a seven-phase tick loop. All entity behavior flows through the actor system — there is no inline behavior logic in the engine:

```
EcosystemEngine (thin orchestrator, ~782 lines)
├── step() → 7-phase sequential loop over ALL entities
│   ├── Phase 1: Flow Actors      → flow_actor_registry[species].resolve(ctx) → EffectBus.apply_flow_batch()
│   ├── Phase 2: Interactions     → actor_registry[species].resolve(ctx) → EffectBus.apply_batch()
│   ├── Phase 3: Guard Actors     → guard_actor_registry[species].resolve(ctx) → EffectBus.apply_effects_with_om_deposit()
│   ├── Phase 4: Voxel effects    → SoilDrain/SoilDeposit intents → handlers via EffectBus
│   ├── Phase 5: World processes  → SoilEvaporation/WaterReplenish intents → handlers via EffectBus
│   ├── Phase 6: Motor inference  → BYOM adapter (mlp/static/random)
│   └── Phase 7: Lifecycle        → removals + spawns from deferred lists
├── Actor Registry                → build_interaction_registry(compiled)
├── Effect Bus                    → collect, resolve conflicts, apply atomically
└── Extracted Subsystems
    ├── LayoutManager (layout.py)        — world loading + randomization
    ├── SpatialIndex (spatial_index.py)  — neighbor queries (BruteForceSpatialIndex)
    ├── MovementSystem (movement_system.py) — gate policy + kinematics
    ├── MovementActor (actors/movement_actors.py) — target selection as pure actor
```

All worlds require `species_definitions`. Worlds without it fail at init with a clear error.

---

## Target Architecture Overview

```
EcosystemEngine (thin orchestrator, ~782 lines)
├── Spatial Index (query layer)
├── Entity Registry
├── Voxel Grid
│
├── Actor Registry
│   ├── Interaction Actors (Phase 1 ✅ COMPLETE)
│   │   ├── FleeActor          → detects predators, emits StateTransition + SetTarget
│   │   ├── PredationActor     → detects prey proximity, emits StateVarDelta + RemoveEntity
│   │   ├── HerbivoryActor     → detects plants in range, emits StateVarDelta (both sides)
│   │   └── PollinationActor   → detects fruiting flowers, emits StateVarDelta + LingerEffect
│   │
│   ├── Flow Actors (Phase 2 ✅ COMPLETE)
│   │   ├── ConsumerFlowActor  → hunger/energy/hydration/repro drive evolution
│   │   ├── ProducerFlowActor  → growth/water uptake/Liebig's law
│   │   └── DecomposerFlowActor → activity/population dynamics
│   │
│   └── Guard Actors (Phase 2 ✅ COMPLETE)
│       ├── ConsumerGuardActor → hysteresis-based state transitions
│       ├── ProducerGuardActor → wilting/fruiting/dormancy
│       └── DecomposerGuardActor → active/blooming/dormant
│
├── Effect Bus (collects, batches, applies effects) ✅ COMPLETE
│   ├── Collect: gather all effects from all actors this tick
│   ├── Resolve: handle conflicts (e.g., entity dies mid-tick)
│   └── Apply: single-pass atomic application to state
│
└── Serialization Layer (Phase 3 ⏳ FUTURE)
    ├── JSON serializer (default, WebSocket-compatible)
    ├── Pluggable interface for msgpack/protobuf later
    └── Effect log for deterministic replay
```

### Core Design Principles

1. **Read-only actors**: Each actor receives a read-only snapshot of state and emits effects. No side effects during actor execution.
2. **Batch application**: All effects from all actors are collected, then applied in a single atomic pass at the end of each phase (or tick).
3. **Pure function pattern**: `resolve(ctx) → list[Effect]` — given the same context, always produces the same effects. Deterministic by construction.
4. **Separation of concerns**: The engine manages lifecycle and spatial indexing; actors manage behavior logic.

---

## Effects Model — Immutable Delta Descriptions

Effects are immutable dataclasses that describe *what changed* rather than performing mutations. They serve as the universal currency between actors and the effect applier.

### Effect Base Class

```python
from dataclasses import dataclass, field
from typing import Any
from enum import Enum


class EffectType(str, Enum):
    # State variable changes
    STATE_VAR_DELTA = "state_var_delta"       # Increment/decrement a state var
    SET_STATE_VAR = "set_state_var"           # Set to absolute value

    # Entity lifecycle
    SPAWN_ENTITY = "spawn_entity"             # Create new entity
    REMOVE_ENTITY = "remove_entity"           # Remove existing entity
    STATE_TRANSITION = "state_transition"     # Change discrete state

    # Environmental changes
    VOXEL_DELTA = "voxel_delta"               # Change voxel layer value
    VOXEL_BATCH_DELTA = "voxel_batch_delta"   # Multiple voxel changes at once

    # Entity behavior modifiers
    LINGER_EFFECT = "linger_effect"           # Stay at location for N ticks
    CLEAR_TARGET = "clear_target"             # Reset movement target
    SET_TARGET = "set_target"                 # Set new movement target

    # Events (for client broadcast)
    EVENT_RECORD = "event_record"             # Log simulation event


@dataclass(frozen=True, kw_only=True)
class Effect:
    """Base class for all simulation effects."""
    effect_type: EffectType
    tick: int

    def to_dict(self) -> dict[str, Any]:
        """Serialize to dict (used by JSON serializer)."""
        return asdict(self)  # or custom serialization


@dataclass(frozen=True, kw_only=True)
class StateVarDelta(Effect):
    """An entity's state variable changes by a delta."""
    effect_type: EffectType = EffectType.STATE_VAR_DELTA
    entity_id: str
    var_name: str       # "hunger", "energy", "health", ...
    delta: float         # can be negative (drain) or positive (recovery)


@dataclass(frozen=True, kw_only=True)
class SetStateVar(Effect):
    """Set a state variable to an absolute value."""
    effect_type: EffectType = EffectType.SET_STATE_VAR
    entity_id: str
    var_name: str
    value: float


@dataclass(frozen=True, kw_only=True)
class StateTransition(Effect):
    """Request a discrete state change."""
    effect_type: EffectType = EffectType.STATE_TRANSITION
    entity_id: str
    new_state: str       # "FORAGING", "FLEEING", "DYING", ...


@dataclass(frozen=True, kw_only=True)
class VoxelDelta(Effect):
    """Change to the voxel grid."""
    effect_type: EffectType = EffectType.VOXEL_DELTA
    layer: str           # "moisture", "nutrients_fast", "organic_matter"
    x: int
    y: int
    z: int
    delta: float


@dataclass(frozen=True, kw_only=True)
class VoxelBatchDelta(Effect):
    """Multiple voxel changes at once (batched for efficiency)."""
    effect_type: EffectType = EffectType.VOXEL_BATCH_DELTA
    changes: list[tuple[str, int, int, int, float]]  # (layer, x, y, z, delta)


@dataclass(frozen=True, kw_only=True)
class SpawnEntity(Effect):
    """Request a new entity be created."""
    effect_type: EffectType = EffectType.SPAWN_ENTITY
    entity_id: str
    type: str            # "ANIMAL", "PLANT", etc.
    species: str | None
    position: list[float]  # [x, y, z]
    metadata: dict[str, Any]
    state_vars: dict[str, float]
    skeleton_id: str | None = None


@dataclass(frozen=True, kw_only=True)
class RemoveEntity(Effect):
    """Request an entity be removed."""
    effect_type: EffectType = EffectType.REMOVE_ENTITY
    entity_id: str


@dataclass(frozen=True, kw_only=True)
class LingerEffect(Effect):
    """Entity stays at current location for N ticks."""
    effect_type: EffectType = EffectType.LINGER_EFFECT
    entity_id: str
    linger_ticks: int


@dataclass(frozen=True, kw_only=True)
class ClearTarget(Effect):
    """Clear an entity's movement target."""
    effect_type: EffectType = EffectType.CLEAR_TARGET
    entity_id: str


@dataclass(frozen=True, kw_only=True)
class SetTarget(Effect):
    """Set a new movement target for an entity."""
    effect_type: EffectType = EffectType.SET_TARGET
    entity_id: str
    position: list[float]  # [x, y, z]


@dataclass(frozen=True, kw_only=True)
class EventRecord(Effect):
    """Log a simulation event for client broadcast."""
    effect_type: EffectType = EffectType.EVENT_RECORD
    event_type: str       # "PREDATION", "CONSUMPTION", "STATE_CHANGE", ...
    source_id: str | None
    target_id: str | None
    position: list[float]  # [x, y, z]
    extra: dict[str, Any] = field(default_factory=dict)


# ── Effect Application Order Priority ────────────────────────────────────────
# When multiple effects target the same entity in one tick, apply in this order:
#   1. REMOVE_ENTITY (entity is gone; no further effects matter)
#   2. STATE_TRANSITION → DYING/DEAD (entity entering terminal state)
#   3. SET_STATE_VAR (absolute values before deltas — ensures correct base)
#   4. LINGER_EFFECT / CLEAR_TARGET / SET_TARGET (behavior modifiers)
#   5. STATE_VAR_DELTA (incremental changes)
#   6. VOXEL_BATCH_DELTA / VOXEL_DELTA (environmental changes, no entity conflict)
#   7. SPAWN_ENTITY (new entities don't conflict with existing ones)
#   8. EVENT_RECORD (side-effect-free logging)


EFFECT_PRIORITY: dict[EffectType, int] = {
    EffectType.REMOVE_ENTITY: 0,
    EffectType.STATE_TRANSITION: 1,
    EffectType.SET_STATE_VAR: 2,
    EffectType.LINGER_EFFECT: 3,
    EffectType.CLEAR_TARGET: 4,
    EffectType.SET_TARGET: 5,
    EffectType.STATE_VAR_DELTA: 6,
    EffectType.VOXEL_BATCH_DELTA: 7,
    EffectType.VOXEL_DELTA: 7,
    EffectType.SPAWN_ENTITY: 8,
    EffectType.EVENT_RECORD: 9,
}
```

### Why Immutable Dataclasses?

1. **Deterministic replay**: Serialize effects → send to another node → apply in order → identical state. No shared mutable dicts.
2. **Network transport**: Frozen dataclasses serialize cleanly to JSON (and later msgpack/protobuf).
3. **Conflict detection**: When two actors produce conflicting effects on the same entity, the effect bus can detect and resolve them before application.
4. **Testing**: Each actor is a pure function — pass in context, assert output effects. No mock state needed.

---

## Interaction Actor Protocol

Each actor implements a clean interface:

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class InteractionContext:
    """Read-only snapshot passed to actors.

    Actors receive this context and must not mutate it. All state access
    goes through read-only views or queries.
    """
    tick: int

    # The entity this actor is evaluating (read-only view)
    entity: dict[str, Any]

    # Trait-derived parameters for the entity's species
    params: DerivedParams

    # Spatial query results — entities within sensory range
    nearby_entities: list[dict[str, Any]] = field(default_factory=list)

    # Read-only voxel access (no mutations through context)
    voxel_grid: VoxelManager = field(repr=False)

    # Water sources (read-only)
    water_sources: list[dict[str, Any]] = field(default_factory=list, repr=False)

    # Biome and climate configuration
    biome: BiomeConfig
    climate: dict[str, float] = field(default_factory=dict)


class InteractionActor(ABC):
    """Base protocol for all simulation actors.

    Each actor implements resolve() which takes a read-only context
    and returns a list of effects describing what should change.
    The engine's effect bus collects all effects from all actors,
    then applies them atomically.
    """

    @abstractmethod
    def resolve(self, ctx: InteractionContext) -> list[Effect]:
        """Evaluate conditions and return effects to apply.

        Args:
            ctx: Read-only simulation context snapshot.

        Returns:
            List of immutable Effect objects describing state changes.
            Empty list if no action is needed.
        """
        ...


class FlowActor(InteractionActor):
    """Subtype for continuous flow actors (Phase 2)."""

    def resolve(self, ctx: InteractionContext) -> list[Effect]:
        raise NotImplementedError


class GuardActor(InteractionActor):
    """Subtype for discrete state transition actors (Phase 2)."""

    def resolve(self, ctx: InteractionContext) -> list[Effect]:
        raise NotImplementedError
```

---

## Phase 1: Effects Extraction + Interaction Actors ✅ COMPLETE

**Status:** Implemented and tested. All interaction types (flee, predation, herbivory, pollination) are actor-based.

### File Structure (Current)

```
ecosim/
├── engine.py              ← Thin orchestrator (~782 lines after decomposition)
├── effects.py             ← ✅ Effect dataclasses + EffectBus (~550 lines)
├── actors/                ← ✅ Actor system directory
│   ├── __init__.py        ← ✅ InteractionContext, InteractionActor base, build_interaction_registry()
│   ├── interaction_actors.py  ← ✅ FleeActor, PredationActor, HerbivoryActor, PollinationActor (~550 lines)
│   ├── flow_actors.py     ← ✅ ConsumerFlowActor, ProducerFlowActor, DecomposerFlowActor (~580 lines)
│   ├── guard_actors.py    ← ✅ ConsumerGuardActor, ProducerGuardActor, DecomposerGuardActor (~620 lines)
│   └── movement_actors.py ← ✅ MovementActor — target selection as effect-emitting actor (~490 lines)
├── interactions.py        ← Compile-time templates + InteractionParams
├── traits.py              ← TraitVector, DerivedParams, allometric derivations
├── trait_compiler.py      ← TraitCompiler, CompiledEcology, compile_world()
├── entities.py            ← Entity schemas, init_entity()
├── voxel_manager.py       ← VoxelGrid protocol + UniformVoxelGrid (5 layers)
├── world_processes.py     ← World-process handlers (evaporation, water replenish, soil drain/deposit)
├── constants.py           ← Universal simulation constants (single source of truth)
├── config.py              ← SIM_CONFIG loader
├── layout.py              ← LayoutManager — world loading + randomization
├── spatial_index.py       ← SpatialIndex protocol + BruteForceSpatialIndex
├── movement_system.py     ← MovementSystem — gate policy + kinematics
├── environment_manager.py ← Environment state encapsulation
└── biome.py               ← Biome presets → BiomeConfig
```

### PredationActor — Before vs After

**Before (in engine.py, directly mutating):**

```python
def _predation_event(self, predator: dict, prey: dict, p: DerivedParams) -> None:
    """Execute a predation event: predator kills and consumes prey."""
    predator["state_vars"]["hunger"] = max(
        0.0, predator["state_vars"]["hunger"] - p.predation_relief)
    predator["state_vars"]["energy"] = min(
        1.0, predator["state_vars"]["energy"] + p.predation_energy_gain)
    prey["state"] = "DYING"
    self._schedule_removal(prey)
    self._deposit_organic_matter(prey, self._get_params(prey))
    self._events.append({
        "type": "PREDATION", "tick": self.tick,
        "source_id": predator["id"], "target_id": prey["id"],
        "position": list(prey["position"]),
    })
```

**After (PredationActor, returning effects):**

```python
class PredationActor(InteractionActor):
    """Carnivore/insectivore attempts to catch nearby prey."""

    def resolve(self, ctx: InteractionContext) -> list[Effect]:
        p = ctx.params
        if p.diet_type not in ("carnivore", "insectivore", "omnivore"):
            return []

        if ctx.entity["state"] != "HUNTING" or ctx.entity["state_vars"]["hunger"] <= 0.3:
            return []

        # Find catchable prey from interaction matrix
        prey_species = [
            s for s, _ in self._get_diet_order(p.species_id)
            if any(ix.interaction_type == "predation"
                   for ix in ctx.compiled.get_interactions(p.species_id, s))
        ]

        prey = None
        best_dist = float("inf")
        for other in ctx.nearby_entities:
            if other.get("species") not in prey_species:
                continue
            d = self._distance(ctx.entity["position"], other["position"])
            if d < PREDATION_CATCH_DISTANCE and d < best_dist:
                best_dist = d
                prey = other

        if prey is None:
            return []

        # Build effects — no mutations, just descriptions of what should happen
        gx, gy, gz = ctx.voxel_grid.world_to_grid(*prey["position"])
        deposit_amount = self._compute_om_deposit(prey, p)

        effects: list[Effect] = [
            StateVarDelta(entity_id=ctx.entity["id"], var_name="hunger",
                          delta=-p.predation_relief, tick=ctx.tick),
            StateVarDelta(entity_id=ctx.entity["id"], var_name="energy",
                          delta=p.predation_energy_gain, tick=ctx.tick),
            SetStateVar(entity_id=prey["id"], var_name="health", value=0.0, tick=ctx.tick),
            StateTransition(entity_id=prey["id"], new_state="DYING", tick=ctx.tick),
            RemoveEntity(entity_id=prey["id"], tick=ctx.tick),
            VoxelDelta(layer="organic_matter", x=gx, y=gy, z=gz,
                       delta=deposit_amount, tick=ctx.tick),
            EventRecord(event_type="PREDATION", source_id=ctx.entity["id"],
                        target_id=prey["id"], position=list(prey["position"]),
                        tick=ctx.tick),
        ]
        return effects
```

### FleeActor — Before vs After

**Before (in engine.py):**

```python
def _resolve_flee(self, e: dict, p: DerivedParams, pos: list[float]) -> None:
    flee_from = self.compiled.get_flee_targets(p.species_id)
    if not flee_from or p.speed <= 0:
        return
    nearby = self._entities_in_range(pos, p.sensory_range, e["id"])
    for other in nearby:
        if other.get("species", "") in flee_from:
            if self._distance(pos, other["position"]) < FLEE_TRIGGER_DISTANCE:
                old_state = e["state"]
                e["state"] = "FLEEING"
                e["_target"] = self._flee_direction(pos, other["position"])
                if old_state != "FLEEING":
                    self._emit_state_change(e, old_state, "FLEEING")
```

**After (FleeActor):**

```python
class FleeActor(InteractionActor):
    """Check for nearby predators and trigger flee response."""

    def resolve(self, ctx: InteractionContext) -> list[Effect]:
        p = ctx.params
        if p.speed <= 0:
            return []

        flee_targets = self._get_flee_targets(p.species_id)
        if not flee_targets:
            return []

        for other in ctx.nearby_entities:
            if other.get("species", "") in flee_targets:
                if self._distance(ctx.entity["position"], other["position"]) < FLEE_TRIGGER_DISTANCE:
                    escape_pos = self._flee_direction(
                        ctx.entity["position"], other["position"]
                    )
                    old_state = ctx.entity["state"]
                    effects: list[Effect] = [
                        StateTransition(entity_id=ctx.entity["id"], new_state="FLEEING", tick=ctx.tick),
                        SetTarget(entity_id=ctx.entity["id"], position=escape_pos, tick=ctx.tick),
                    ]
                    if old_state != "FLEEING":
                        effects.append(EventRecord(
                            event_type="STATE_CHANGE", source_id=ctx.entity["id"],
                            target_id=None, position=list(ctx.entity["position"]),
                            extra={"prev_state": old_state, "new_state": "FLEEING"},
                            tick=ctx.tick))
                    return effects
        return []
```

### Engine `step()` — Actor-Based Tick Loop

```python
def step(self, dt: float = 0.1) -> dict[str, Any]:
    """Advance the simulation by one tick."""
    self.tick += 1
    self._events.clear()
    self._spawns.clear()
    self._removals.clear()
    self._rebuild_spatial_index()

    # Phase 1: Flow — actor-based
    flow_effects = []
    for entity in list(self.entities.values()):
        if not is_alive(entity):
            continue
        actor = self._get_flow_actor(entity.get("species"))
        if actor:
            ctx = self._build_flow_context(entity, dt)
            flow_effects.extend(actor.resolve(ctx))
    self.effect_bus.apply_flow_batch(flow_effects, ...)

    # Phase 2: Interactions — actor-based
    interaction_effects = []
    for entity in list(self.entities.values()):
        if not is_alive(entity):
            continue
        actors = self.actor_registry.get(entity.get("species"))
        if actors:
            ctx = self._build_interaction_context(entity, dt)
            for actor in actors:
                interaction_effects.extend(actor.resolve(ctx))
    self.effect_bus.apply_batch(interaction_effects, self.entities, ...)

    # Phase 3: Guards — actor-based
    guard_effects = []
    for entity in list(self.entities.values()):
        if not is_alive(entity):
            continue
        actor = self._get_guard_actor(entity.get("species"))
        if actor:
            ctx = self._build_guard_context(entity, dt)
            guard_effects.extend(actor.resolve(ctx))
    self.effect_bus.apply_effects_with_om_deposit(guard_effects, ...)

    # Phase 4-7: Voxel effects, world processes, motor inference, lifecycle
    ...
```

### Effect Bus — Collect and Apply ✅ IMPLEMENTED

```python
class EffectBus:
    """Collects effects from all actors and applies them atomically."""

    def apply_batch(self, effects, entities, voxels, spawns, removals, events) -> None:
        sorted_effects = sorted(effects, key=lambda e: EFFECT_PRIORITY.get(e.effect_type, 9))
        removed_ids: set[str] = set()
        for effect in sorted_effects:
            # ... apply by priority, skip effects on removed entities
            ...
```

---

## Phase 2: Flow + Guard Actors ✅ Complete

**Status:** IMPLEMENTED. All flow and guard logic extracted into actor classes. The engine uses actor system exclusively — no inline behavior logic remains.

### File Structure

```
ecosim/
├── engine.py              ← ~782 lines (thin orchestrator)
├── effects.py             ← ~550 lines — EffectBus with apply_flow_batch() + apply_effects_with_om_deposit()
├── actors/
│   ├── __init__.py        ← ~390 lines — FlowContext/GuardContext, registries, builders
│   ├── interaction_actors.py  ← ~550 lines: FleeActor, PredationActor, HerbivoryActor, PollinationActor
│   ├── flow_actors.py     ← ~580 lines: ConsumerFlowActor, ProducerFlowActor, DecomposerFlowActor
│   ├── guard_actors.py    ← ~620 lines: ConsumerGuardActor, ProducerGuardActor, DecomposerGuardActor
│   └── movement_actors.py ← ~490 lines: MovementActor
├── constants.py           ← ~160 lines: universal simulation constants
└── config.py              ← ~140 lines: SIM_CONFIG loader
```

### ConsumerFlowActor — Implementation Summary

**Handles**: hunger buildup, energy drain/recovery, hydration loss, drinking recovery, near-water bonus, reproductive drive, health degradation under starvation/dehydration, colony health.

**Key design decisions**:
- `FlowContext` extends `InteractionContext` with `dt`, `rain_ticks_remaining`, and `_entities` (for tree collapse check)
- All rate constants from `constants.py` and `config.py`
- Biome modifiers and world rate multipliers applied on top of trait-derived base rates
- Lingering effects (e.g., pollination visits) handled via `LingerEffect` + energy recovery

### ConsumerGuardActor — Implementation Summary

**State machine priority** (highest to lowest):
1. Death (health ≤ 0 or age ≥ lifespan) → `RemoveEntity` + `EventRecord(DEATH_STARVE/NATURAL)` + `DepositOrganicMatter`
2. Colony swarming (colony_health < 0.3) → `StateTransition(SWARMING)`
3. Fleeing (set by interaction resolver, cleared when target reached) → `StateTransition(IDLE)`
4. Reproduction (drive > threshold AND mate available) → `SpawnEntity` + `EventRecord(REPRODUCTION)`
5. Drinking (hydration hysteresis: enter < p.hydration_enter, exit ≥ p.hydration_exit)
6. Resting (energy hysteresis: enter < p.energy_enter, exit ≥ p.energy_exit)
7. Foraging/Hunting (hunger hysteresis: enter ≥ p.hunger_enter, exit < p.hunger_exit)
8. Idle (default)

**Key design decisions**:
- `GuardContext` extends `InteractionContext` with `_entities` for mate search and support count
- Death triggers `RemoveEntity` + `EventRecord` + `DepositOrganicMatter`
- Reproduction checks proximity to potential mates in full entity list
- State transitions emit `StateTransition` effects; engine applies them and emits STATE_CHANGE events

---

## Phase 3: Distributed Readiness (Future)

**Status:** NOT STARTED. Serialization layer for network transport and deterministic replay.

### Goals

1. **JSON serializer**: Convert Effect objects to/from JSON for WebSocket transmission.
2. **Pluggable format interface**: Abstract serialization behind a protocol so msgpack/protobuf can be swapped in later without changing actor code.
3. **Effect log**: Record all effects per tick for deterministic replay and debugging.
4. **Network transport**: Send effect batches from server to client, or between simulation nodes.

---

## Serialization Layer — Pluggable Format Design

```python
class EffectSerializer(ABC):
    """Protocol for serializing/deserializing effects."""

    @abstractmethod
    def serialize(self, effects: list[Effect]) -> bytes | str: ...

    @abstractmethod
    def deserialize(self, data: bytes | str) -> list[Effect]: ...


class JsonSerializer(EffectSerializer):
    """Default JSON serializer — WebSocket-compatible."""

    def serialize(self, effects: list[Effect]) -> str:
        return json.dumps([e.to_dict() for e in effects])

    def deserialize(self, data: str) -> list[Effect]:
        raw = json.loads(data)
        # Map dicts back to Effect subclasses by effect_type
        ...


class MsgpackSerializer(EffectSerializer):
    """Future: more compact binary format."""
    ...
```

---

## Effect Application Order & Conflict Resolution

When multiple effects target the same entity in one tick, apply in this order:

1. **REMOVE_ENTITY** — entity is gone; no further effects matter
2. **STATE_TRANSITION → DYING/DEAD** — entity entering terminal state
3. **SET_STATE_VAR** — absolute values before deltas (ensures correct base)
4. **LINGER_EFFECT / CLEAR_TARGET / SET_TARGET** — behavior modifiers
5. **STATE_VAR_DELTA** — incremental changes
6. **VOXEL_BATCH_DELTA / VOXEL_DELTA** — environmental changes, no entity conflict
7. **SPAWN_ENTITY** — new entities don't conflict with existing ones
8. **EVENT_RECORD** — side-effect-free logging

The `EffectBus.apply_batch()` method sorts effects by priority before application and tracks removed IDs to prevent cascading mutations on dead entities.

---

## File Structure

```
ecosim/
├── engine.py              ← Thin orchestrator (~782 lines)
├── effects.py             ← Effect dataclasses + EffectBus (~550 lines)
├── actors/                ← Actor system
│   ├── __init__.py        ← Context classes, bases, registries, builders (~390 lines)
│   ├── interaction_actors.py  ← FleeActor, PredationActor, HerbivoryActor, PollinationActor (~550 lines)
│   ├── flow_actors.py     ← ConsumerFlowActor, ProducerFlowActor, DecomposerFlowActor (~580 lines)
│   ├── guard_actors.py    ← ConsumerGuardActor, ProducerGuardActor, DecomposerGuardActor (~620 lines)
│   └── movement_actors.py ← MovementActor (~490 lines)
├── interactions.py        ← Compile-time templates + InteractionParams
├── traits.py              ← TraitVector, DerivedParams, allometric derivations
├── trait_compiler.py      ← TraitCompiler, CompiledEcology, compile_world()
├── entities.py            ← Entity schemas, init_entity(), is_alive(), is_mobile()
├── voxel_manager.py       ← VoxelGrid protocol + UniformVoxelGrid (5 layers)
├── world_processes.py     ← World-process handlers dispatched through EffectBus
├── constants.py           ← Universal simulation constants
├── config.py              ← SIM_CONFIG loader
├── layout.py              ← LayoutManager — world loading + randomization
├── spatial_index.py       ← SpatialIndex protocol + BruteForceSpatialIndex
├── movement_system.py     ← MovementSystem — gate policy + kinematics
├── environment_manager.py ← Environment state encapsulation
├── biome.py               ← Biome presets → BiomeConfig
├── model_adapter.py       ← MotorAdapter protocol, ContextSpec
├── telemetry.py           ← Telemetry bus — JSONL event stream
└── worker.py              ← Async WS tick loop + HTTP viz server
```

---

## Open Questions

1. **Flow actor granularity**: Should flow actors emit individual StateVarDelta effects per variable, or batch them into a single SET_STATE_VAR effect? Batching reduces effect count but loses the ability to apply deltas in priority order.

2. **Movement handling**: Movement mutates entity position directly (requires engine-level access). Should this remain inline in the engine, or should a MovementActor emit SetTarget effects that the engine resolves? (MovementActor is now implemented and emits SetTarget/ClearTarget effects.)

3. **Effect bus performance**: For large simulations (1000+ entities), sorting effects by priority each tick adds O(n log n) overhead. Could we batch-sort once per phase instead of per entity?

4. **Deterministic replay**: Should the effect log include the full context snapshot, or just the effects? Full context enables exact replay but increases storage; effects-only is more compact but requires re-running the simulation to reconstruct state.

5. **Actor composition**: Some behaviors span multiple phases (e.g., pollination involves interaction detection + lingering behavior). Should we support composite actors that coordinate across phases, or keep each actor phase-scoped?
