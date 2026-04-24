class_name Biome
extends RefCounted

## Biome types used by WorldGenerator and WorldData.
## Stored as a single byte per tile in WorldData.biomes.
enum Type {
	PLAINS,
	FOREST,
	DESERT,
	TUNDRA,
	MOUNTAIN,
	WATER,
	STONE_FLOOR,  # mined-out mountain rock; passable, slow, leaves a visible scar
}

## Display color for each biome in the v1 pixel-rendered world.
const COLORS: Dictionary = {
	Type.PLAINS:      Color8(124, 179,  66),
	Type.FOREST:      Color8( 46, 125,  50),
	Type.DESERT:      Color8(253, 216,  53),
	Type.TUNDRA:      Color8(224, 242, 241),
	Type.MOUNTAIN:    Color8(109,  76,  65),
	Type.WATER:       Color8( 25, 118, 210),
	Type.STONE_FLOOR: Color8(158, 142, 130),  # cool light gray-brown, distinct from mountain
}

const NAMES: Dictionary = {
	Type.PLAINS:      "Plains",
	Type.FOREST:      "Forest",
	Type.DESERT:      "Desert",
	Type.TUNDRA:      "Tundra",
	Type.MOUNTAIN:    "Mountain",
	Type.WATER:       "Water",
	Type.STONE_FLOOR: "Stone Floor",
}

## Movement cost multiplier. Biomes with IMPASSABLE must be cleared (mined,
## bridged, etc.) before they can be traversed. This is why the pawn
## pathfinder will refuse to route paths through mountains -- they're raw
## rock that has to be mined out, RimWorld-style.
const IMPASSABLE: float = 9999.0
const MOVEMENT_COST: Dictionary = {
	Type.PLAINS:      1.0,
	Type.FOREST:      1.4,
	Type.DESERT:      1.2,
	Type.TUNDRA:      1.3,
	Type.MOUNTAIN:    IMPASSABLE,
	Type.WATER:       IMPASSABLE,
	Type.STONE_FLOOR: 1.6,
}


static func color_for(biome: int) -> Color:
	return COLORS.get(biome, Color.MAGENTA)


static func name_for(biome: int) -> String:
	return NAMES.get(biome, "Unknown")


static func is_passable(biome: int) -> bool:
	return MOVEMENT_COST.get(biome, IMPASSABLE) < IMPASSABLE
