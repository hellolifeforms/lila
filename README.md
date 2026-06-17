<!--
  līlā — BYOM Ecosystem Simulation Engine
  Copyright 2025 BioSynthArt Studios LLC
  Licensed under the Apache License, Version 2.0
  https://github.com/hellolifeforms/lila
-->

# līlā — Ecosystem Simulation Engine

> Define a world in JSON. The engine grows an ecosystem. Nothing is scripted — everything emerges.

[![CI](https://github.com/hellolifeforms/lila/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/hellolifeforms/lila/actions/workflows/test.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

līlā is an ecosystem simulation engine. Species are defined as functional trait vectors in JSON — body mass, diet, locomotion, thermoregulation. The engine derives behavior from allometric scaling laws (Kleiber's Law, metabolic theory of ecology). Hunger cycles, predator-prey dynamics, soil nutrients, water depletion, dormancy, and recovery all emerge from this.

The core (`ecosim`) has **zero external dependencies** — stdlib Python only.

## Quick start

```bash
git clone https://github.com/hellolifeforms/lila.git
cd lila/deploy/compose
docker compose up --build
```

Open **http://localhost:8001**. A temperate meadow with deer, songbirds, butterflies, wildflowers, grass, and oak trees is running. Click **☔ Rain** to trigger recovery, or **⏺ Record** to capture dynamics.

## Architecture

```
Browser client (60 Hz)  │  Python debug client (60 Hz)
   agency + heartbeat     agency + replay
       │  │                   │  │
       │  └── heartbeat 1 Hz  │  │
       │  intent 0.5 Hz       │  │ WebSocket
       │                      │  │
┌──────▼──────────────────────▼──▼────────────┐
│  Worker — async WS server, one port/session │
│  Streams intent packets, absorbs heartbeats │
└──────┬──────────────────────────────────────┘
       │
┌──────▼──────────────────────────────────────┐
│  ecosim (stdlib Python)                     │
│                                             │
│  7-phase tick (0.5 Hz):                     │
│    flow → interactions → guards →           │
│    voxel FX → water → motor → spawn/kill    │
│                                             │
│  Traits → allometric derivation →           │
│  interaction templates                      │
│                                             │
│  Actor system → immutable effects           │
│  BYOM adapters → motor inference            │
│  VoxelGrid (5 layers, sparse)               │
│  Telemetry → JSONL event stream             │
└─────────────────────────────────────────────┘
```

**Intent-based agency is the core architecture.** The server emits state, drives, motion latents, and reference positions at 0.5 Hz. Clients run local behavior at 60 Hz and report heartbeats upstream at 1 Hz. Divergence between client and server is reconciled — soft-nudge within bounds, snap with acknowledgment on large drift. Divergence is treated as emergence and not as error.

## Key features

- **Trait-based species** — a species is a point in trait space. The `TraitCompiler` derives all engine parameters at init. Adding a new species is writing a JSON vector, not code.
- **Actor effects system** — flow, guard, interaction, movement, and reproduction actors each read a frozen `InteractionContext` and emit immutable effects. The `EffectBus` collects, prioritizes, and applies them atomically. Enables deterministic replay.
- **BYOM adapters** — plug in custom ML models for motor inference. The engine builds context vectors, calls `infer()`, and writes latent vectors back. Three levels defined: motor (implemented), behavior (designed), narrative (designed).
- **VoxelGrid protocol** — sparse 3D grid with five layers (`nutrients_fast`, `nutrients_slow`, `moisture`, `temperature`, `organic_matter`). Abstract storage strategy via Protocol — `UniformVoxelGrid` is the current implementation, octree swap-in ready.
- **Telemetry** — structured JSONL event stream written to `~/.lila/logs/` with WebSocket broadcast. Config snapshots, time-series aggregates, and event batching for training data and post-mortem replay.
- **Two clients** — modular browser visualizer (client-side agency, reconciliation, recording) and Python debug client (ImGui view, telemetry timeline, JSONL replay).
- **ASAL-compatible search** — `Init(θ) / Step(θ) / Render(θ)` substrate. Diversity-driven GA with CLIP evaluation produces a UMAP atlas of discovered ecosystems.

## Ecosystem search

```bash
cd search && uv sync
uv run python -m scripts.run_illumination \
    --pop-size 64 --generations 100 --steps 2000 --frames 20 \
    --workers 4 -o results/illuminate
```

See [`search/README.md`](search/README.md) for details.

## Essays

- ["The Pulse of Līlā"](https://www.hellolifeforms.com/p/the-pulse-of-lila) — intent-based architecture: global mind, local body
- ["The Mathematics of Līlā"](https://www.hellolifeforms.com/p/the-mathematics-of-lila) — intent as vector field, gaits as limit cycles, multi-observer worlds as fiber bundles
- ["The Unseen Hand"](https://www.hellolifeforms.com/p/the-unseen-hand) — small invisible ML as the driver of felt presence
- ["Life as It Could Be"](https://www.hellolifeforms.com/p/life-as-it-could-be) — ecological substrates and foundation-model-guided ALife search

## Developing

See [`DEVELOPING.md`](DEVELOPING.md) for the `uv` workflow, tests, and architecture deep dives.

## License

Apache 2.0. Copyright 2025 BioSynthArt Studios LLC.

> The name [līlā](https://www.embodiedphilosophy.com/what-is-lila/) comes from Sanskrit — spontaneous, purposeless creative unfolding. There's no win condition. The world plays as itself.
