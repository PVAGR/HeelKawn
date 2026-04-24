class_name Stockpile
extends Node2D

## A rectangular stockpile zone with an item filter. Pawns haul accepted
## items here and eat from zones whose filter admits food. The colony can
## have many zones simultaneously -- StockpileManager knows about all of
## them and routes pawns to the closest accepting one.
##
## History: v1 was a single-tile stockpile with no filter. v2 (Phase 10)
## widened it into a rectangle + filter. The old API (tile, add_item,
## take_item, count_of, count_food, pick_food) is preserved so existing
## call sites keep working without churn.

## What this zone is allowed to hold. A pawn will only haul an item to the
## zone if accepts(item_type) returns true. Food covers berries + meat.
enum Filter {
	ALL,       # default; accepts anything haulable. Used for the seed pile.
	FOOD,      # berries + meat
	BERRY,     # berries only
	MEAT,      # meat only
	WOOD,
	STONE,
}

# ---------- visual tuning ----------

const TILE_PIXELS: int = 8
const BORDER_COLOR: Color = Color(1.0, 0.88, 0.40)
const BORDER_WIDTH: float = 1.5
const LABEL_COLOR: Color = Color(0.95, 0.95, 0.90, 0.95)
const LABEL_SHADOW: Color = Color(0.05, 0.05, 0.05, 0.85)
const LABEL_FONT_SIZE: int = 9

## Fill tint per filter. Kept low-alpha so the underlying biome still shows
## through and the player can read "oh the grass is still grass, this is
## just a stockpile overlay".
const FILTER_FILL: Dictionary = {
	Filter.ALL:   Color(0.35, 0.25, 0.12, 0.45),
	Filter.FOOD:  Color(0.95, 0.35, 0.25, 0.35),
	Filter.BERRY: Color(0.85, 0.20, 0.30, 0.35),
	Filter.MEAT:  Color(0.65, 0.20, 0.15, 0.40),
	Filter.WOOD:  Color(0.55, 0.35, 0.12, 0.40),
	Filter.STONE: Color(0.45, 0.45, 0.50, 0.45),
}

const FILTER_NAME: Dictionary = {
	Filter.ALL:   "All",
	Filter.FOOD:  "Food",
	Filter.BERRY: "Berries",
	Filter.MEAT:  "Meat",
	Filter.WOOD:  "Wood",
	Filter.STONE: "Stone",
}


# ---------- zone data ----------

## Primary anchor tile (top-left corner of `rect`). Kept as a public field
## for back-compat with older code paths that only know about a point pile.
var tile: Vector2i = Vector2i.ZERO

## Tile-space rectangle the zone covers. Position+size must fit inside the
## world grid; no overlap enforcement -- if two zones overlap the pawns will
## use whichever the nearest-zone search picks. Always at least 1x1.
var rect: Rect2i = Rect2i(0, 0, 1, 1)

## What this zone accepts. Drives pawn hauling and the zone tint.
var filter: int = Filter.ALL

## item Type -> int quantity. Aggregated across the whole zone (we don't
## track per-tile placement yet -- that's a visual polish step for later).
var inventory: Dictionary = {}


# ---------- set up ----------

## Convenience used by Main when placing a zone. Sets both the anchor tile
## and the matching rect in one call.
func set_rect_tiles(r: Rect2i) -> void:
	rect = r
	tile = r.position
	queue_redraw()


func set_filter(f: int) -> void:
	filter = f
	queue_redraw()


# ---------- inventory API (same shape as v1) ----------

func add_item(type: int, qty: int = 1) -> void:
	if type == Item.Type.NONE or qty <= 0:
		return
	inventory[type] = inventory.get(type, 0) + qty
	queue_redraw()


func take_item(type: int, qty: int = 1) -> int:
	if type == Item.Type.NONE or qty <= 0:
		return 0
	var have: int = inventory.get(type, 0)
	var taken: int = min(have, qty)
	if taken <= 0:
		return 0
	inventory[type] = have - taken
	if inventory[type] <= 0:
		inventory.erase(type)
	queue_redraw()
	return taken


func count_of(type: int) -> int:
	return inventory.get(type, 0)


func has_item(type: int) -> bool:
	return inventory.get(type, 0) > 0


func has_any_food() -> bool:
	for t in inventory:
		if Item.is_food(t):
			return true
	return false


func count_food() -> int:
	var total: int = 0
	for t in inventory:
		if Item.is_food(t):
			total += inventory[t]
	return total


## Return the item Type to eat right now (highest-stocked food), or NONE.
func pick_food() -> int:
	var best_type: int = Item.Type.NONE
	var best_qty: int = 0
	for t in inventory:
		if not Item.is_food(t):
			continue
		if inventory[t] > best_qty:
			best_type = t
			best_qty = inventory[t]
	return best_type


# ---------- zone geometry ----------

## Does this zone's filter allow the given item to be deposited? Fed in from
## StockpileManager during drop-zone selection.
func accepts(item_type: int) -> bool:
	if item_type == Item.Type.NONE:
		return false
	match filter:
		Filter.ALL:
			return true
		Filter.FOOD:
			return Item.is_food(item_type)
		Filter.BERRY:
			return item_type == Item.Type.BERRY
		Filter.MEAT:
			return item_type == Item.Type.MEAT
		Filter.WOOD:
			return item_type == Item.Type.WOOD
		Filter.STONE:
			return item_type == Item.Type.STONE
	return false


func contains_tile(t: Vector2i) -> bool:
	return rect.has_point(t)


## The tile inside this zone that's closest (Chebyshev) to `from_tile`. Used
## by pawns pathing in so a 4x4 pantry is reachable from any side instead of
## forcing everyone to file to one corner.
func nearest_tile_to(from_tile: Vector2i) -> Vector2i:
	var x: int = clamp(from_tile.x, rect.position.x, rect.position.x + rect.size.x - 1)
	var y: int = clamp(from_tile.y, rect.position.y, rect.position.y + rect.size.y - 1)
	return Vector2i(x, y)


## Square tile distance (Chebyshev) from this zone's nearest edge tile to
## `from_tile`. 0 if inside the zone.
func chebyshev_distance_from(from_tile: Vector2i) -> int:
	var near: Vector2i = nearest_tile_to(from_tile)
	return max(abs(near.x - from_tile.x), abs(near.y - from_tile.y))


# ---------- drawing ----------

func _draw() -> void:
	# Draw the whole rectangle tinted by filter. We live at the world-space
	# position of the anchor tile, so the rect is offset so (0,0) sits on
	# the top-left of that tile.
	var half_tile: float = TILE_PIXELS * 0.5
	var w: float = rect.size.x * TILE_PIXELS
	var h: float = rect.size.y * TILE_PIXELS
	var origin: Vector2 = Vector2(-half_tile, -half_tile)  # top-left corner of the anchor tile in local space
	var area := Rect2(origin, Vector2(w, h))

	var fill: Color = FILTER_FILL.get(filter, FILTER_FILL[Filter.ALL])
	draw_rect(area, fill, true)
	draw_rect(area, BORDER_COLOR, false, BORDER_WIDTH)
	_draw_label(area)
	_draw_inventory_readout(area)


## Compact "filter-name (total)" banner along the top edge. Uses the default
## theme font so we don't have to ship a font asset.
func _draw_label(area: Rect2) -> void:
	var font: Font = ThemeDB.fallback_font
	var text: String = "%s" % FILTER_NAME.get(filter, "?")
	var total: int = 0
	for t in inventory:
		total += inventory[t]
	if total > 0:
		text += "  %d" % total
	var pos: Vector2 = area.position + Vector2(2, -2)
	draw_string(font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, LABEL_SHADOW)
	draw_string(font, pos,                 text, HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, LABEL_COLOR)


## Inventory bars along the top of the zone, one per stocked item type.
func _draw_inventory_readout(area: Rect2) -> void:
	if inventory.is_empty():
		return
	var bar_width: float = 2.5
	var bar_spacing: float = 1.25
	var base_y: float = area.position.y - 2.0
	var max_height: float = 18.0
	var qty_per_pixel: float = 1.0
	var bars: Array = []
	for t in inventory:
		bars.append({"type": t, "qty": inventory[t]})
	var total_width: float = bars.size() * bar_width + max(0, bars.size() - 1) * bar_spacing
	# Right-align the readout so the label on the left stays readable.
	var x: float = area.position.x + area.size.x - total_width - 2.0
	for b in bars:
		var bh: float = min(max_height, b.qty * qty_per_pixel)
		draw_rect(Rect2(x, base_y - bh, bar_width, bh), Item.color_for(b.type), true)
		draw_rect(Rect2(x, base_y - bh, bar_width, bh), Color.BLACK, false, 0.5)
		x += bar_width + bar_spacing
