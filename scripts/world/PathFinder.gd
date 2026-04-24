class_name PathFinder
extends RefCounted

## Wrapper around Godot's built-in AStarGrid2D plus a flood-filled
## connected-components map. Two jobs:
##   1. find_path(start, goal) -> actual walkable route avoiding mountains/water.
##   2. component_of(tile)     -> O(1) reachability test so pawns don't claim
##                                jobs stranded on another landmass.
##
## Call `rebuild` after every world load/generate. For terrain updates use
## `sync_tile_from_data` / `set_job_construction_reservation` (see `World` helpers).

const NEIGHBOR_OFFSETS: Array[Vector2i] = [
	Vector2i( 1,  0), Vector2i(-1,  0), Vector2i( 0,  1), Vector2i( 0, -1),
	Vector2i( 1,  1), Vector2i(-1,  1), Vector2i( 1, -1), Vector2i(-1, -1),
]

var _astar: AStarGrid2D

## Per-tile connected component id. -1 = impassable tile. Same non-negative
## value on two tiles == you can walk from one to the other.
var _component_id: PackedInt32Array

## Pending BUILD_WALL jobs: treat cell as impassable so paths route around
## planned walls. Cleared on job complete/cancel/world regen.
var _resv_job: PackedByteArray = PackedByteArray()
## Transient: drag preview for wall mode. Cleared each preview update.
var _resv_preview: PackedByteArray = PackedByteArray()
var _last_preview_tiles: Array[Vector2i] = []


func _init() -> void:
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(0, 0, WorldData.WIDTH, WorldData.HEIGHT)
	_astar.cell_size = Vector2.ONE
	# ONLY_IF_NO_OBSTACLES: diagonal move is forbidden unless BOTH adjacent cardinals
	# are walkable. This prevents "corner-cutting" where the straight-line lerp
	# between two diagonal tile centers would clip through a solid neighbor.
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()
	_component_id.resize(WorldData.TILE_COUNT)
	_resv_job.resize(WorldData.TILE_COUNT)
	_resv_preview.resize(WorldData.TILE_COUNT)


## Rebuild solidity map + connected components for a freshly generated world.
## Uses `WorldData` features + biomes, plus any construction reservations.
func rebuild(data: WorldData) -> void:
	for i in range(WorldData.TILE_COUNT):
		_resv_job[i] = 0
		_resv_preview[i] = 0
	_last_preview_tiles.clear()
	for y in range(WorldData.HEIGHT):
		for x in range(WorldData.WIDTH):
			_refresh_one_tile(x, y, data)
	_compute_components(data)


## After changing terrain in `data` (wall, door, mine-out), re-sync A* for one tile.
func sync_tile_from_data(x: int, y: int, data: WorldData) -> void:
	_refresh_one_tile(x, y, data)
	_compute_components(data)


## Reserve / release a future wall cell for the job queue. `on=true` when a
## BUILD_WALL job is posted; `on=false` when it finishes or is cancelled.
func set_job_construction_reservation(x: int, y: int, on: bool, data: WorldData) -> void:
	if not _astar.region.has_point(Vector2i(x, y)):
		return
	var i: int = y * WorldData.WIDTH + x
	_resv_job[i] = 1 if on else 0
	_refresh_one_tile(x, y, data)
	_compute_components(data)


## Update drag-preview for planned walls. Pass tile coords of cells that
## *would* get a valid wall job. Cleared when `tiles` is empty.
func set_preview_wall_tiles(tiles: Array, data: WorldData) -> void:
	for t in _last_preview_tiles:
		var i: int = t.y * WorldData.WIDTH + t.x
		_resv_preview[i] = 0
	_last_preview_tiles.clear()
	for v in tiles:
		if v is Vector2i:
			var t: Vector2i = v
			if not _astar.region.has_point(t):
				continue
			var i2: int = t.y * WorldData.WIDTH + t.x
			if _resv_job[i2] == 0:
				_resv_preview[i2] = 1
			_last_preview_tiles.append(t)
	for t2 in _last_preview_tiles:
		_refresh_one_tile(t2.x, t2.y, data)
	# Also recompute neighbors? Full recompute is fine at preview rate.
	_compute_components(data)


## Legacy entry point: prefer `sync_tile_from_data` after data edits.
## Forces one tile from explicit passability (used by older call sites only).
## Deprecated: use `WorldData` + `sync_tile_from_data`.
func set_passable(x: int, y: int, passable: bool, data: WorldData) -> void:
	_astar.set_point_solid(Vector2i(x, y), not passable)
	_compute_components(data)


func _refresh_one_tile(x: int, y: int, data: WorldData) -> void:
	var p := Vector2i(x, y)
	if not _astar.region.has_point(p):
		return
	var i3: int = y * WorldData.WIDTH + x
	var base_walk: bool = WorldData.is_tile_walkable(data, x, y)
	var block: bool = (not base_walk) or (_resv_job[i3] > 0) or (_resv_preview[i3] > 0)
	_astar.set_point_solid(p, block)


## Return the list of tiles to visit AFTER start to reach goal. Empty if:
##   - start == goal (already there),
##   - start or goal out of bounds,
##   - goal is solid,
##   - no path exists.
func find_path(start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if start == goal:
		return out
	if not _astar.region.has_point(start) or not _astar.region.has_point(goal):
		return out
	if _astar.is_point_solid(goal):
		return out
	# Fast reject: different components means no hope of a path.
	if component_of(start) != component_of(goal):
		return out
	var packed: PackedVector2Array = _astar.get_id_path(start, goal)
	if packed.size() <= 1:
		return out
	for i in range(1, packed.size()):
		out.append(Vector2i(packed[i]))
	return out


## Find a passable tile next to `tile` (8-way). Used to park a pawn next to
## an impassable target (e.g. an ore vein on a mountain). Returns (-1,-1)
## if the tile is surrounded by impassable terrain.
func find_adjacent_passable(tile: Vector2i) -> Vector2i:
	for offset in NEIGHBOR_OFFSETS:
		var t: Vector2i = tile + offset
		if not _astar.region.has_point(t):
			continue
		if not _astar.is_point_solid(t):
			return t
	return Vector2i(-1, -1)


func is_passable(tile: Vector2i) -> bool:
	if not _astar.region.has_point(tile):
		return false
	return not _astar.is_point_solid(tile)


## Component id for a tile, or -1 if tile is impassable / out of bounds.
func component_of(tile: Vector2i) -> int:
	if tile.x < 0 or tile.x >= WorldData.WIDTH or tile.y < 0 or tile.y >= WorldData.HEIGHT:
		return -1
	return _component_id[tile.y * WorldData.WIDTH + tile.x]


## Return true if two tiles are in the same walkable component.
func are_reachable(a: Vector2i, b: Vector2i) -> bool:
	var ca: int = component_of(a)
	if ca < 0:
		return false
	return ca == component_of(b)


## Which connected component has the most tiles? Used to pick the "main
## continent" for placing the colony's stockpile and restricting pawn spawns
## to the same landmass.
func largest_component_id() -> int:
	var counts: Dictionary = {}
	for id in _component_id:
		if id < 0:
			continue
		counts[id] = counts.get(id, 0) + 1
	var best_id: int = -1
	var best_count: int = 0
	for id in counts:
		if counts[id] > best_count:
			best_count = counts[id]
			best_id = id
	return best_id


## Find a tile belonging to `comp_id` closest to `center`. Used to place the
## stockpile at world center while guaranteeing it's on the main landmass.
## Returns (-1,-1) if the component has no tile within max_radius of center.
func find_tile_in_component_near(comp_id: int, center: Vector2i, max_radius: int = 128) -> Vector2i:
	if component_of(center) == comp_id:
		return center
	for r in range(1, max_radius + 1):
		# Check the ring of distance r (Chebyshev) around center.
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var t: Vector2i = center + Vector2i(dx, dy)
				if component_of(t) == comp_id:
					return t
	return Vector2i(-1, -1)


# -------------------- internals --------------------

## Drives off A* solidity (set_point_solid), NOT raw biome data, so anything
## that flips passability after generation -- mined-out walls, built walls,
## bridges -- shows up in the component map. Otherwise pawns would happily
## try to path through a wall they just built.
func _compute_components(_data: WorldData) -> void:
	_component_id.resize(WorldData.TILE_COUNT)
	for i in range(_component_id.size()):
		_component_id[i] = -1
	var current_id: int = 0
	var queue: Array[Vector2i] = []
	for y in range(WorldData.HEIGHT):
		for x in range(WorldData.WIDTH):
			var idx: int = y * WorldData.WIDTH + x
			if _component_id[idx] != -1:
				continue
			var here := Vector2i(x, y)
			if _astar.is_point_solid(here):
				continue
			queue.clear()
			queue.append(here)
			_component_id[idx] = current_id
			while not queue.is_empty():
				var t: Vector2i = queue.pop_back()
				for offset in NEIGHBOR_OFFSETS:
					var nx: int = t.x + offset.x
					var ny: int = t.y + offset.y
					if nx < 0 or nx >= WorldData.WIDTH or ny < 0 or ny >= WorldData.HEIGHT:
						continue
					var nidx: int = ny * WorldData.WIDTH + nx
					if _component_id[nidx] != -1:
						continue
					var n := Vector2i(nx, ny)
					if _astar.is_point_solid(n):
						continue
					# Diagonal step: mirror AStarGrid2D DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES.
					# Both cardinal neighbors must also be walkable, otherwise A*
					# will refuse this diagonal and the two tiles are really in
					# different components for path purposes.
					if offset.x != 0 and offset.y != 0:
						if _astar.is_point_solid(Vector2i(nx, t.y)):
							continue
						if _astar.is_point_solid(Vector2i(t.x, ny)):
							continue
					_component_id[nidx] = current_id
					queue.append(n)
			current_id += 1
