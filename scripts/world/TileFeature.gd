class_name TileFeature
extends RefCounted

## Resource / point-of-interest overlays that sit on top of a tile's biome.
## Stored as one byte per tile in WorldData.features. NONE means "bare biome".
enum Type {
	NONE,
	ORE_VEIN,
	FERTILE_SOIL,
	RUIN,
	TREE,
	BED,           # built by pawns from wood; passable; speeds up sleep recovery
	WALL,          # built by pawns from wood; impassable; blocks pathing + LoS
	DOOR,          # built by pawns from wood; passable; future: open/close state
	RABBIT,        # passive wildlife; HUNT yields 1 meat; respawns
	DEER,          # passive wildlife; HUNT yields 2 meat; slower hunt; respawns
}

## Colors used for the v1 pixel renderer. Chosen to pop against the biome below.
const COLORS: Dictionary = {
	Type.NONE:         Color(0, 0, 0, 0),
	Type.ORE_VEIN:     Color8(255, 111,   0),
	Type.FERTILE_SOIL: Color8( 51, 105,  30),
	Type.RUIN:         Color8(173,  20,  87),
	Type.TREE:         Color8( 27,  73,  29),  # very dark forest green
	Type.BED:          Color8(220, 180, 120),  # warm wheat -- reads as built furniture
	Type.WALL:         Color8( 90,  60,  35),  # dark wood-brown plank
	Type.DOOR:         Color8(160, 100,  45),  # lighter wood, slightly orange
	Type.RABBIT:       Color8(245, 240, 230),  # off-white; reads against grass + sand
	Type.DEER:         Color8(170, 110,  55),  # warm tan; obvious "animal" sprite
}

const NAMES: Dictionary = {
	Type.NONE:         "None",
	Type.ORE_VEIN:     "Ore Vein",
	Type.FERTILE_SOIL: "Fertile Soil",
	Type.RUIN:         "Ruin",
	Type.TREE:         "Tree",
	Type.BED:          "Bed",
	Type.WALL:         "Wall",
	Type.DOOR:         "Door",
	Type.RABBIT:       "Rabbit",
	Type.DEER:         "Deer",
}


## True if a feature is huntable wildlife. Centralizes the rabbit/deer test
## so callers (job seeding, regrowth, validation) don't have to enumerate.
static func is_wildlife(f: int) -> bool:
	return f == Type.RABBIT or f == Type.DEER


static func color_for(f: int) -> Color:
	return COLORS.get(f, Color.MAGENTA)


static func name_for(f: int) -> String:
	return NAMES.get(f, "Unknown")
