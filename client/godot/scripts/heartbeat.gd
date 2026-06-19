## Accumulates entity positions and agency events, sends heartbeats upstream.
## Mirrors browser heartbeat.js.
class_name HeartbeatSender


var _last_send: float = 0.0
var _queued_events: Array = []


## Call every frame. Sends heartbeat when interval elapses.
func tick(ws: Node, world: Node, now: float) -> void:
	var interval: float = float(LilaConstants.HEARTBEAT_INTERVAL_MS) / 1000.0
	if now - _last_send < interval:
		return

	_last_send = now

	# Build positions dict (only alive mobile consumers)
	var positions: Dictionary = {}
	var mobile: Array = world.get_alive_mobile()
	for ent in mobile:
		positions[ent.id] = [ent.x, 0.0, ent.z]

	# Send heartbeat
	if positions.size() > 0 or _queued_events.size() > 0:
		ws.send_heartbeat(positions, _queued_events.duplicate())
	_queued_events.clear()


## Queue a client event for next heartbeat.
func queue_event(evt: Dictionary) -> void:
	_queued_events.append(evt)
