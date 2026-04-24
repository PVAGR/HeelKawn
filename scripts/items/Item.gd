class_name Item
extends RefCounted

## Item types the colony produces, carries, stockpiles, and consumes.
## Kept as a plain enum + lookup tables until we need item data (stacking rules,
## nutrition, stack size). Item.Type.NONE means "no item" (e.g. pawn not carrying).

enum Type {
	NONE,
	BERRY,   # produced by FORAGE;    eaten to restore hunger
	STONE,   # produced by MINE/MINE_WALL; raw building material
	WOOD,    # produced by CHOP;      future: beds, walls, doors
	MEAT,    # produced by HUNT;      heartier food than berries
}

## Display color for the carry-indicator above a pawn and for the stockpile icon.
const COLORS: Dictionary = {
	Type.NONE:  Color(0, 0, 0, 0),
	Type.BERRY: Color8(229, 57,  53),   # bright red
	Type.STONE: Color8(189, 189, 189),  # light gray
	Type.WOOD:  Color8(141,  85,  36),  # warm brown
	Type.MEAT:  Color8(178,  60,  60),  # darker, blood-red -- distinct from berry
}

const NAMES: Dictionary = {
	Type.NONE:  "None",
	Type.BERRY: "Berry",
	Type.STONE: "Stone",
	Type.WOOD:  "Wood",
	Type.MEAT:  "Meat",
}

## Short single-letter label used in the stockpile's inventory readout.
const LABELS: Dictionary = {
	Type.NONE:  "-",
	Type.BERRY: "B",
	Type.STONE: "S",
	Type.WOOD:  "W",
	Type.MEAT:  "M",
}

## Hunger restored per unit when a pawn consumes this item. Non-food items
## map to 0 and won't be chosen by the "eat" behavior. Meat is significantly
## heartier than berries, so a single hunted deer is worth a meaningful chunk
## of the colony's daily food budget.
const HUNGER_RESTORE: Dictionary = {
	Type.NONE:  0.0,
	Type.BERRY: 60.0,
	Type.STONE: 0.0,
	Type.WOOD:  0.0,
	Type.MEAT:  85.0,
}


static func color_for(t: int) -> Color:
	return COLORS.get(t, Color.MAGENTA)


static func name_for(t: int) -> String:
	return NAMES.get(t, "Unknown")


static func label_for(t: int) -> String:
	return LABELS.get(t, "?")


static func hunger_restore(t: int) -> float:
	return HUNGER_RESTORE.get(t, 0.0)


static func is_food(t: int) -> bool:
	return HUNGER_RESTORE.get(t, 0.0) > 0.0
