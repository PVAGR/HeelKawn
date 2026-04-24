extends Node

## Global registry of every stockpile zone currently placed on the world.
## Pawns ask this manager "where should I drop this berry?" or "where's the
## closest pantry with food?" and the manager walks its list to find the
## best candidate. Scope is kept small -- N_zones is expected to stay well
## under 50, so O(N) linear scans are fine.
##
## Emits zone_registered / zone_unregistered so the HUD can refresh totals
## without every frame polling this list.

signal zone_registered(zone: Stockpile)
signal zone_unregistered(zone: Stockpile)

var _zones: Array[Stockpile] = []


func register(z: Stockpile) -> void:
	if z == null or _zones.has(z):
		return
	_zones.append(z)
	zone_registered.emit(z)


func unregister(z: Stockpile) -> void:
	if z == null:
		return
	var idx: int = _zones.find(z)
	if idx < 0:
		return
	_zones.remove_at(idx)
	zone_unregistered.emit(z)


func clear_all() -> void:
	# Defensive copy because listeners may reorder the list.
	var snap: Array[Stockpile] = _zones.duplicate()
	_zones.clear()
	for z in snap:
		zone_unregistered.emit(z)


## Read-only view into the live zone list. Do NOT mutate the returned array;
## callers iterate it for UI and hauling decisions.
func zones() -> Array[Stockpile]:
	return _zones


## Total of a specific item type across every zone. Used by the HUD + food-
## emergency override in Pawn.
func total_count_of(item_type: int) -> int:
	var total: int = 0
	for z in _zones:
		total += z.count_of(item_type)
	return total


## Total food across every zone, summing across all food item types. Used by
## the food-emergency override in Pawn._tick_idle.
func total_food() -> int:
	var total: int = 0
	for z in _zones:
		total += z.count_food()
	return total


## True if any zone has at least one unit of any food item. Cheaper than
## total_food() since we can bail after the first hit.
func has_any_food() -> bool:
	for z in _zones:
		if z.has_any_food():
			return true
	return false


# ---------- nearest-zone queries ----------
#
# All "find" helpers take an optional `pathfinder` so we can skip zones that
# aren't reachable from the pawn's current tile. If no pathfinder is passed
# we fall back to raw Chebyshev distance (MVP hunters-gatherers get lucky).

## Closest zone that accepts `item_type`, or null. Ties break on the first
## candidate encountered (insertion order).
func find_drop_zone(item_type: int, from_tile: Vector2i, pathfinder: PathFinder = null) -> Stockpile:
	var best: Stockpile = null
	var best_d: int = 0x7FFFFFFF
	var my_comp: int = -1
	if pathfinder != null:
		my_comp = pathfinder.component_of(from_tile)
	for z in _zones:
		if not z.accepts(item_type):
			continue
		if pathfinder != null:
			# Any tile in the zone needs to be in the same connected component.
			var near: Vector2i = z.nearest_tile_to(from_tile)
			if pathfinder.component_of(near) != my_comp:
				continue
		var d: int = z.chebyshev_distance_from(from_tile)
		if d < best_d:
			best = z
			best_d = d
	return best


## Closest zone that currently has any food AND accepts food. Hungry pawns
## call this to pick where to eat.
func find_food_source(from_tile: Vector2i, pathfinder: PathFinder = null) -> Stockpile:
	var best: Stockpile = null
	var best_d: int = 0x7FFFFFFF
	var my_comp: int = -1
	if pathfinder != null:
		my_comp = pathfinder.component_of(from_tile)
	for z in _zones:
		if not z.has_any_food():
			continue
		if pathfinder != null:
			var near: Vector2i = z.nearest_tile_to(from_tile)
			if pathfinder.component_of(near) != my_comp:
				continue
		var d: int = z.chebyshev_distance_from(from_tile)
		if d < best_d:
			best = z
			best_d = d
	return best


## Closest zone that has at least `qty` of `item_type`. Used by fetch-
## material for builds (walls, beds, doors needing wood).
func find_source_for(item_type: int, qty: int, from_tile: Vector2i, pathfinder: PathFinder = null) -> Stockpile:
	var best: Stockpile = null
	var best_d: int = 0x7FFFFFFF
	var my_comp: int = -1
	if pathfinder != null:
		my_comp = pathfinder.component_of(from_tile)
	for z in _zones:
		if z.count_of(item_type) < qty:
			continue
		if pathfinder != null:
			var near: Vector2i = z.nearest_tile_to(from_tile)
			if pathfinder.component_of(near) != my_comp:
				continue
		var d: int = z.chebyshev_distance_from(from_tile)
		if d < best_d:
			best = z
			best_d = d
	return best
