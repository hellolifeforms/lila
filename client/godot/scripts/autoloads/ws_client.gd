## WebSocket client for līlā server communication.
## Handles /ws WebSocket connection, /world.json HTTP fetch, auto-reconnect.
extends Node


## Signals
signal connected
signal disconnected
signal session_started(data: Dictionary)
signal tick_packet(data: Dictionary)
signal world_json_ready(data: Dictionary)


## Persisted world definition string (resent on every reconnect).
var _world_def_json: String = ""


## State
var _ws: WebSocketPeer
var _is_connected: bool = false
var _is_connecting: bool = false
var _reconnect_timer: float = 0.0
var _pending_sends: Array[String] = []


## Host and port (overridable via scene properties or project settings)
var host: String = LilaConstants.DEFAULT_HOST
var port: int = LilaConstants.DEFAULT_PORT


func _ready() -> void:
	_ws = WebSocketPeer.new()
	_load_world_json_local()
	_setup_poll_timer()


## Load world.json from local resources (avoids HTTP issues with websockets server).
func _load_world_json_local() -> void:
	var file: FileAccess = FileAccess.open("res://resources/world.json", FileAccess.READ)
	if file == null:
		push_error("Cannot open res://resources/world.json")
		return
	var text: String = file.get_as_text()
	file.close()
	_world_def_json = text.strip_edges()

	var json_conv: JSON = JSON.new()
	var err: Error = json_conv.parse(text)
	if err == OK:
		world_json_ready.emit(json_conv.data)
		print("World JSON loaded from local file")
	else:
		push_error("Failed to parse world.json: ", json_conv.get_error_message())


## Dedicated poll timer ensures WebSocket I/O is serviced even when
## the render loop stalls (e.g. heavy voxel rebuild frames).
## Server pings every 20s with 10s timeout, so 100ms polling is safe.
var _poll_timer: Timer
func _setup_poll_timer() -> void:
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 0.1
	_poll_timer.one_shot = false
	_poll_timer.timeout.connect(_on_poll_timer)
	add_child(_poll_timer)
	_poll_timer.start()

func _on_poll_timer() -> void:
	if _ws == null:
		return
	_ws.poll()
	var status: int = _ws.get_ready_state()

	if status == WebSocketPeer.STATE_OPEN and _is_connected:
		# Read incoming messages
		while _ws.get_available_packet_count() > 0:
			var packet: PackedByteArray = _ws.get_packet()
			var text: String = packet.get_string_from_utf8()
			_dispatch(text)
		# Flush pending sends
		while _pending_sends.size() > 0:
			var msg: String = _pending_sends.pop_front()
			var err: Error = _ws.send_text(msg)
			if err != OK:
				push_error("WebSocket send failed: ", err)
			break
	elif status == WebSocketPeer.STATE_CLOSED:
		if _is_connected:
			var code: int = _ws.get_close_code()
			_is_connected = false
			_reconnect_timer = LilaConstants.RECONNECT_DELAY
			disconnected.emit()
			print("WebSocket closed (code ", code, "), reconnecting in ", LilaConstants.RECONNECT_DELAY, "s")


func _process(delta: float) -> void:
	if not _is_connected and not _is_connecting:
		_reconnect_timer -= delta
		if _reconnect_timer <= 0:
			_connect_to_server()


func _connect_to_server() -> void:
	_is_connecting = true
	var url: String = "ws://" + host + ":" + str(port) + "/ws"
	print("Connecting to ", url)

	# Fresh WebSocketPeer to avoid stale state from previous connection
	_ws = WebSocketPeer.new()

	var err: Error = _ws.connect_to_url(url)
	if err != OK:
		push_error("Failed to connect to WebSocket: ", err)
		_reconnect_timer = LilaConstants.RECONNECT_DELAY
		_is_connecting = false
		return

	# Wait for actual open
	var wait: float = 0.0
	while _ws.get_ready_state() != WebSocketPeer.STATE_OPEN and wait < 5.0:
		_ws.poll()
		await get_tree().create_timer(0.05).timeout
		wait += 0.05

	if _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_is_connected = true
		_is_connecting = false
		connected.emit()
		print("WebSocket connected")

		# Send world definition (always — works on reconnect)
		if not _world_def_json.is_empty():
			_ws.send_text(_world_def_json)
			print("World definition sent")

		# Flush any pending sends from before connection
		for msg in _pending_sends:
			_ws.send_text(msg)
		_pending_sends.clear()
	else:
		_is_connecting = false
		_reconnect_timer = LilaConstants.RECONNECT_DELAY


func _fetch_world_json() -> void:
	# Send a control request over WebSocket to get world definition.
	# Server sends it back as the first message, or we fetch via WS.
	# For now: send empty world definition request, server responds with session_started.
	# The browser client fetches via HTTP — but Godot's HTTPRequest has issues
	# with websockets library's HTTP passthrough, so we skip HTTP entirely
	# and send world def directly if we have one.
	pass


func _dispatch(text: String) -> void:
	var json_conv: JSON = JSON.new()
	var err: Error = json_conv.parse(text)
	if err != OK:
		push_error("Invalid JSON from server: ", json_conv.get_error_message())
		return

	var data: Dictionary = json_conv.data
	var type: String = data.get("type", "")

	if type == "session_started":
		session_started.emit(data)
	elif type.is_empty() and data.has("tick"):
		# Tick packets don't have a "type" field, they have "tick"
		tick_packet.emit(data)
	else:
		# Pass through unknown types
		tick_packet.emit(data)


## Send a JSON message to the server.
func send(data: Dictionary) -> void:
	var json_str: String = JSON.stringify(data)
	if _is_connected and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(json_str)
	else:
		_pending_sends.append(json_str)


## Send world definition to start a session.
func send_world_definition(world_def: Dictionary) -> void:
	send(world_def)


## Send heartbeat with positions and events.
func send_heartbeat(positions: Dictionary, events: Array) -> void:
	send({
		"type": "heartbeat",
		"positions": positions,
		"events": events,
	})


## Send a control message (pause, resume, shutdown, rain).
func send_control(type: String, extra: Dictionary = {}) -> void:
	var msg: Dictionary = {"type": type}
	msg.merge(extra)
	send(msg)
