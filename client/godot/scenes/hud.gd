# līlā — Godot 4.x 3D Client
# Copyright 2025 BioSynthArt Studios LLC
# Licensed under the Apache License, Version 2.0
#
# scenes/hud.gd — HUD overlay: stats panel, event log, controls
extends CanvasLayer


@onready var stats_label: Label = $VBox/StatsLabel
@onready var event_log: RichTextLabel = $VBox/EventLog
@onready var rain_button: Button = $VBox/RainButton

var _event_count: int = 0
var _tick: int = 0
var _fps: int = 0
var _frame_count: int = 0
var _fps_timer: float = 0.0


func _process(delta: float) -> void:
	_frame_count += 1
	_fps_timer += delta
	if _fps_timer >= 1.0:
		_fps = _frame_count / _fps_timer
		_frame_count = 0
		_fps_timer = 0.0

	stats_label.text = "Tick: %d | Entities: %d | Events: %d | FPS: %d" % [
		_tick, World.get_entity_count(), _event_count, _fps
	]


func update_tick(tick: int) -> void:
	_tick = tick


func add_event(text: String) -> void:
	_event_count += 1
	event_log.append_text("[color=ffcc66]%s[/color]\n" % text)
	# Keep last 50 events
	var max_lines: int = 50
	var lines: PackedStringArray = event_log.text.split("\n")
	if lines.size() > max_lines:
		event_log.set_text("\n".join(lines.slice(-max_lines)))


func on_rain_button_pressed() -> void:
	WS.send_control("rain", {"intensity": 0.8})
	add_event("☔ Rain triggered!")
