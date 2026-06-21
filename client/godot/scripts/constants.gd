## Shared constants mirroring browser/Python clients.
class_name LilaConstants

## Print with HH:MM:SS timestamp prefix.
static func log(msg: Variant) -> void:
	var t: Dictionary = Time.get_datetime_dict_from_system()
	var ts: String = "%02d:%02d:%02d" % [t.hour, t.minute, t.second]
	print("[%s] %s" % [ts, str(msg)])


## Grid dimensions (matches server voxel grid)
const GRID_SIZE: int = 32

## Cell size in pixels (2D render space)
const CELL_PX: int = 18

## Server tick rate in seconds (push frequency)
const SERVER_TICK_RATE: float = 2.0

## Heartbeat interval in milliseconds (client → server)
const HEARTBEAT_INTERVAL_MS: int = 1000

## Reconciliation thresholds
const RECONCILE_MIN_DIVERGENCE: float = 0.1
const RECONCILE_NUDGE_FACTOR: float = 0.15
const RECONCILE_SNAP_FACTOR: float = 0.5
const RECONCILE_QUEUE_MAX: int = 2

## Agency
const GRAVITY_WELL_FACTOR: float = 0.05
const INTERACTION_COOLDOWN: float = 2.0
const WANDER_MARGIN: float = 4.0
const ARRIVAL_DISTANCE: float = 0.8

## Reconnect delay in seconds
const RECONNECT_DELAY: float = 3.0

## Default server address
const DEFAULT_HOST: String = "localhost"
const DEFAULT_PORT: int = 8001

## Entity type colors (fallback for renderer)
## Harmonized with browser constants.js palette.
const TYPE_COLORS: Dictionary = {
	"ANIMAL": Color(0.77, 0.58, 0.42),    # deer brown #c4956a
	"BIRD": Color(0.54, 0.48, 0.42),      # bird brown #8a7b6b
	"INSECT": Color(0.66, 0.49, 0.77),    # butterfly purple #a87cc4
	"PLANT": Color(0.42, 0.56, 0.37),     # grass green #6b8f5e
	"TREE": Color(0.24, 0.42, 0.24),      # oak green #3d6b3d
	"MICROORGANISM": Color(0.63, 0.55, 0.47),  # mushroom #a08c78
}

## Species name → color override
const SPECIES_COLORS: Dictionary = {
	"deer": Color(0.77, 0.58, 0.42),
	"wolf": Color(0.45, 0.45, 0.45),
	"butterfly": Color(0.66, 0.49, 0.77),
	"songbird": Color(0.54, 0.48, 0.42),
	"meadow_oak": Color(0.24, 0.42, 0.24),
	"meadow_grass": Color(0.42, 0.56, 0.37),
	"wildflower": Color(0.48, 0.56, 0.37),
	"mushroom": Color(0.63, 0.55, 0.47),
}

## State → color tint for HUD overlay / debug
const STATE_COLORS: Dictionary = {
	"IDLE": Color(0.6, 0.6, 0.6),
	"FORAGING": Color(0.3, 0.8, 0.3),
	"HUNTING": Color(0.9, 0.2, 0.2),
	"FLEEING": Color(1.0, 0.3, 0.3),
	"RESTING": Color(0.5, 0.5, 0.8),
	"DRINKING": Color(0.2, 0.5, 0.9),
	"REPRODUCING": Color(0.9, 0.4, 0.7),
	"DYING": Color(0.3, 0.1, 0.1),
	"GROWING": Color(0.3, 0.7, 0.3),
	"WILTING": Color(0.6, 0.5, 0.2),
	"DORMANT": Color(0.4, 0.3, 0.2),
	"FRUITING": Color(1.0, 0.8, 0.1),
	"POLLINATING": Color(1.0, 0.9, 0.3),
	"ACTIVE": Color(0.5, 0.6, 0.5),
	"BLOOMING": Color(0.8, 0.7, 0.5),
}

## Mobile entity types (send positions in heartbeat)
const MOBILE_TYPES: Array[StringName] = ["ANIMAL", "BIRD", "INSECT"]

## Particle colors (harmonized with browser event colors)
const PARTICLE_CONSUMPTION: Color = Color(0.35, 0.85, 0.37)  # #8faa6e
const PARTICLE_POLLINATION: Color = Color(0.77, 0.65, 0.29)  # #c4a64a
const PARTICLE_DEATH: Color = Color(0.43, 0.35, 0.35)       # #6e5a5a
