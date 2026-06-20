## Orbit / trackball camera controller.
## Attach as a script on a Camera3D node.
##
## Controls:
##   Left  mouse drag — orbit around target
##   Right mouse drag — pan target
##   Scroll wheel       — zoom in / out
##   R / Space          — forwarded (not consumed)

extends Camera3D

## World-space point the camera orbits around.
@export var target: Vector3 = Vector3.ZERO

## Distance from target.
@export var distance: float = 45.0

## Horizontal angle (radians). 0 = looking down +Z.
@export var theta: float = PI / 4.0

## Vertical angle (radians). PI/2 = straight on, smaller = higher.
@export var phi: float = PI / 3.0

## Zoom range
@export var min_distance: float = 5.0
@export var max_distance: float = 200.0

## Zoom multiplier per scroll tick.
@export var zoom_factor: float = 1.15

## Pan speed (world units per pixel of drag).
@export var pan_speed: float = 0.03

## Orbit speed multiplier.
@export var orbit_speed: float = 0.003

var _dragging_orbit: bool = false
var _dragging_pan: bool = false
var _drag_start: Vector2 = Vector2.ZERO


func _ready() -> void:
	_update_position()


func _process(_delta: float) -> void:
	# Smoothly follow target in case it moves externally
	global_transform.origin = get_desired_position()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_dragging_orbit = true
				_drag_start = event.position
			else:
				_dragging_orbit = false

		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_dragging_pan = true
				_drag_start = event.position
			else:
				_dragging_pan = false

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			distance = maxf(distance / zoom_factor, min_distance)
			_update_position()

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			distance = minf(distance * zoom_factor, max_distance)
			_update_position()

	if _dragging_orbit and event is InputEventMouseMotion:
		var delta: Vector2 = event.position - _drag_start
		theta -= delta.x * orbit_speed
		phi = clampf(phi + delta.y * orbit_speed, 0.05, PI - 0.05)
		_drag_start = event.position
		_update_position()

	if _dragging_pan and event is InputEventMouseMotion:
		var delta: Vector2 = event.position - _drag_start
		_pan_target(delta)
		_drag_start = event.position
		_update_position()


func _pan_target(screen_delta: Vector2) -> void:
	# Compute camera right and up vectors for panning
	var forward: Vector3 = global_transform.basis.z
	var right: Vector3 = global_transform.basis.x
	var up: Vector3 = global_transform.basis.y

	# Pan perpendicular to view direction
	var pan_move: Vector3 = -right * screen_delta.x * pan_speed + up * screen_delta.y * pan_speed
	target += pan_move


func get_desired_position() -> Vector3:
	var x: float = distance * sin(phi) * cos(theta)
	var y: float = distance * cos(phi)
	var z: float = distance * sin(phi) * sin(theta)
	return target + Vector3(x, y, z)


func _update_position() -> void:
	position = get_desired_position()
	look_at(target, Vector3.UP)
