# līlā — Godot 4.x 3D Client
# Copyright 2025 BioSynthArt Studios LLC
# Licensed under the Apache License, Version 2.0
#
# scripts/particles.gd — Simple particle system for event visualizations
#
# Spawns particles for consumption, pollination, death, and other
# ecosystem events. Particles are pooled and updated each frame.
extends RefCounted


class Particle:
	var position: Vector2  # Grid coordinates
	var velocity: Vector2  # Grid units per second
	var color: Color
	var life: float
	var max_life: float
	var size: float

	func is_alive() -> bool:
		return life > 0.0

	func step(delta: float) -> void:
		life -= delta
		position += velocity * delta
		velocity *= 0.95  # Damping


var _particles: Array[Particle] = []
const MAX_PARTICLES: int = 500


## Update all particles, remove dead ones.
func step(delta: float) -> void:
	var i: int = _particles.size() - 1
	while i >= 0:
		var p: Particle = _particles[i]
		p.step(delta)
		if not p.is_alive():
			_particles.remove_at(i)
		i -= 1


## Spawn particles at a grid position for an event type.
func spawn(grid_x: float, grid_z: float, event_type: String, count: int = 8) -> void:
	var color: Color
	match event_type.to_upper():
		"CONSUMPTION":
			color = LilaConstants.PARTICLE_CONSUMPTION
		"POLLINATION":
			color = LilaConstants.PARTICLE_POLLINATION
		"DEATH_NATURAL", "DEATH_STARVE":
			color = LilaConstants.PARTICLE_DEATH
		_:
			color = Color(1.0, 1.0, 1.0)

	for i in count:
		if _particles.size() >= MAX_PARTICLES:
			_particles.remove_at(0)

		var p: Particle = Particle.new()
		p.position = Vector2(grid_x, grid_z)
		var angle: float = randf() * TAU
		var speed: float = randf_range(0.5, 2.0)
		p.velocity = Vector2(cos(angle), sin(angle)) * speed
		p.color = color
		p.life = randf_range(0.5, 1.5)
		p.max_life = p.life
		p.size = randf_range(0.2, 0.5)
		_particles.append(p)


## Get all alive particles.
func get_alive() -> Array[Particle]:
	return _particles
