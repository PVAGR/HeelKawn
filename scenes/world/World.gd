class_name World
extends Node2D

## Pixels of screen space per tile. The world is rendered as a 256x256 Image
## baked into an ImageTexture, then scaled up so each source pixel = TILE_PIXELS.
const TILE_PIXELS: int = 8

@onready var _sprite: Sprite2D = $Sprite2D

var data: WorldData

## A* + reachability over `data`. Rebuilt in generate().
var pathfinder: PathFinder

## The colony's primary stockpile node, or null if not placed yet. Pawns
## read this to find deposit / eat targets. Main is responsible for
## instantiating and attaching it after each world generation.
var stockpile: Stockpile = null

## All tiles with a BED feature, in placement order. Pawns scan this when
## they want to sleep. Kept in sync via register_bed / unregister_bed.
var _bed_tiles: Array[Vector2i] = []
## bed tile -> Pawn currently sleeping (or walking to) it. A bed is "free"
## if not present in this dict OR mapped to null.
var _bed_occupants: Dictionary = {}

## Cached base image + texture so we can patch individual tiles in-place
## (e.g. when a feature is harvested) without re-rendering the whole world.
var _image: Image
var _texture: ImageTexture


func _ready() -> void:
	_sprite.centered = true
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_sprite.scale = Vector2(TILE_PIXELS, TILE_PIXELS)
	add_to_group("colony_world")
	pathfinder = PathFinder.new()
	generate(randi())


func load_world_data(new_data: WorldData) -> void:
	data = new_data
	pathfinder.rebuild(data)
	_render()
	_bed_tiles.clear()
	_bed_occupants.clear()
	resync_beds_from_map()


func generate(world_seed: int) -> void:
	var t0: int = Time.get_ticks_msec()
	data = WorldGenerator.generate(world_seed)
	var t_gen: int = Time.get_ticks_msec() - t0
	pathfinder.rebuild(data)
	var t_path: int = Time.get_ticks_msec() - t0 - t_gen
	_render()
	# Beds and their occupants don't survive a regen -- the tiles they sit
	# on are gone.
	_bed_tiles.clear()
	_bed_occupants.clear()
	var dt: int = Time.get_ticks_msec() - t0
	print("[World] Generated seed=%d  %dx%d  gen=%dms path=%dms total=%dms" %
		[world_seed, WorldData.WIDTH, WorldData.HEIGHT, t_gen, t_path, dt])
	_print_distribution()


func _print_distribution() -> void:
	var biome_counts: Dictionary = {}
	for biome in Biome.Type.values():
		biome_counts[biome] = 0
	var feature_counts: Dictionary = {}
	for f in TileFeature.Type.values():
		feature_counts[f] = 0
	for i in range(WorldData.TILE_COUNT):
		biome_counts[data.biomes[i]] += 1
		feature_counts[data.features[i]] += 1
	var total: float = float(WorldData.TILE_COUNT)
	var biome_line := "[World] Biomes:"
	for biome in Biome.Type.values():
		biome_line += "  %s=%.1f%%" % [Biome.name_for(biome), 100.0 * biome_counts[biome] / total]
	print(biome_line)
	var feature_line := "[World] Features:"
	for f in TileFeature.Type.values():
		if f == TileFeature.Type.NONE:
			continue
		feature_line += "  %s=%d" % [TileFeature.name_for(f), feature_counts[f]]
	print(feature_line)


func _render() -> void:
	_image = Image.create(WorldData.WIDTH, WorldData.HEIGHT, false, Image.FORMAT_RGB8)
	for y in range(WorldData.HEIGHT):
		for x in range(WorldData.WIDTH):
			_image.set_pixel(x, y, _tile_color(x, y))
	_texture = ImageTexture.create_from_image(_image)
	_sprite.texture = _texture


func _tile_color(x: int, y: int) -> Color:
	var i: int = data.index(x, y)
	var feature: int = data.features[i]
	if feature != TileFeature.Type.NONE:
		return TileFeature.color_for(feature)
	return Biome.color_for(data.biomes[i])


## Remove a tile feature (used when FORAGE / MINE jobs complete). Patches the
## texture in-place so we don't re-render the whole world.
func clear_feature(x: int, y: int) -> void:
	set_feature(x, y, TileFeature.Type.NONE)


## Set or replace the feature at a tile and update the rendered texture.
## Used by FORAGE / MINE / CHOP completion (clear) and by the regrowth
## system (re-spawning trees and fertile soil after a delay). Returns true
## if the tile actually changed.
func set_feature(x: int, y: int, feature: int) -> bool:
	if not data.in_bounds(x, y):
		return false
	var i: int = data.index(x, y)
	if data.features[i] == feature:
		return false
	data.features[i] = feature
	if _image != null:
		_image.set_pixel(x, y, _tile_color(x, y))
		_texture.update(_image)
	return true


## Build a wall on the target tile: place the WALL feature, mark the tile
## impassable in the pathfinder, and recompute connected components. Returns
## true if the tile actually changed (false if it was already a wall, or out
## of bounds, or already impassable mountain/water -- those are nonsense
## build sites).
func build_wall(x: int, y: int) -> bool:
	if not data.in_bounds(x, y):
		return false
	if not Biome.is_passable(data.biomes[data.index(x, y)]):
		return false
	# Shove pawns *before* the feature flips: tile may be reserved in A* or
	# still walkable in `data` — nudge by logical tile, not by solidity.
	nudge_occupants_off_tile_for_construction(x, y)
	if not set_feature(x, y, TileFeature.Type.WALL):
		return false
	# Clear any pending path reservation for this cell; _refresh re-reads WALL
	# from `data` as non-walkable.
	if pathfinder != null:
		pathfinder.set_job_construction_reservation(x, y, false, data)
	_bump_occupants_off_tile(x, y)
	notify_pawns_nav_changed()
	return true


## Nudge pawns off (x,y) when that tile is still walkable in `data` (e.g. just
## before a wall build completes, or a planned reservation).
func nudge_occupants_off_tile_for_construction(x: int, y: int) -> void:
	var tr: SceneTree = get_tree()
	if tr == null or pathfinder == null:
		return
	var here := Vector2i(x, y)
	for _i in range(4):
		var any: bool = false
		for node in tr.get_nodes_in_group("pawns"):
			if node is Pawn:
				var p: Pawn = node
				if p.data != null and p.data.tile_pos == here:
					p.evict_to_neighbor_of_tile(here)
					any = true
		if not any:
			break


func notify_pawns_nav_changed() -> void:
	var tr: SceneTree = get_tree()
	if tr == null:
		return
	for node in tr.get_nodes_in_group("pawns"):
		if node is Pawn:
			(node as Pawn).on_world_nav_changed()


## `JobManager` only: release path reservations on full job **cancel** (the job
## is destroyed). `abandon` does **not** call this — the site stays reserved
## for the next claim.
func on_construction_path_job_ended(job: Job) -> void:
	if data == null or pathfinder == null or job == null:
		return
	if job.type == Job.Type.BUILD_WALL:
		pathfinder.set_job_construction_reservation(job.tile.x, job.tile.y, false, data)
		notify_pawns_nav_changed()


## Pawns in group "pawns" whose `tile_pos` matches (x,y) are nudged to the
## nearest passable neighbor. Re-run a few times if multiple pawns share a tile.
func _bump_occupants_off_tile(x: int, y: int) -> void:
	var target: Vector2i = Vector2i(x, y)
	var tr: SceneTree = get_tree()
	if tr == null:
		return
	for _i in range(8):
		var any: bool = false
		for node in tr.get_nodes_in_group("pawns"):
			if node is Pawn:
				var pawn: Pawn = node
				if pawn.data != null and pawn.data.tile_pos == target:
					pawn.nudge_if_standing_on_solid()
					any = true
		if not any:
			break


## Public alias: after a wall job reserves a cell, shove pawns nudged to solid.
func kick_occupants_off_reserved_build_tile(x: int, y: int) -> void:
	_bump_occupants_off_tile(x, y)


## Build a door on the target tile, OR replace an existing WALL (same tile).
## Doors stay passable in A*. Replacing a wall clears that tile's solidity.
func build_door(x: int, y: int) -> bool:
	if not data.in_bounds(x, y):
		return false
	var i: int = data.index(x, y)
	var feat: int = data.features[i]
	# "Stronghold" style: punch a door through a wall without deleting the
	# rest of the line — swap feature and reopen the tile for pathing.
	if feat == TileFeature.Type.WALL:
		if not set_feature(x, y, TileFeature.Type.DOOR):
			return false
		if pathfinder != null:
			pathfinder.sync_tile_from_data(x, y, data)
		notify_pawns_nav_changed()
		return true
	# New door on empty passable land (Kenshi / RimWorld: door on an opening).
	if not Biome.is_passable(data.biomes[i]):
		return false
	if feat != TileFeature.Type.NONE:
		return false
	if not set_feature(x, y, TileFeature.Type.DOOR):
		return false
	if pathfinder != null:
		pathfinder.sync_tile_from_data(x, y, data)
	notify_pawns_nav_changed()
	return true


## Convert a MOUNTAIN tile into a STONE_FLOOR (passable). Used by MINE_WALL
## jobs to let pawns tunnel into mountain ranges. Updates the texture, the
## A* solidity map, and the connected-components map in one shot. Returns
## true if the tile was actually changed.
func mine_out_wall(x: int, y: int) -> bool:
	if not data.in_bounds(x, y):
		return false
	var i: int = data.index(x, y)
	if data.biomes[i] != Biome.Type.MOUNTAIN:
		return false
	data.biomes[i] = Biome.Type.STONE_FLOOR
	# Any feature riding on the mountain (e.g. ORE_VEIN) is harvested at the
	# same time -- you can't extract ore without removing the rock around it.
	if data.features[i] != TileFeature.Type.NONE:
		data.features[i] = TileFeature.Type.NONE
	if _image != null:
		_image.set_pixel(x, y, _tile_color(x, y))
		_texture.update(_image)
	# Pathfinder: the tile is now passable; recompute components so anything
	# that was sealed behind this wall joins the right component.
	if pathfinder != null:
		pathfinder.sync_tile_from_data(x, y, data)
	notify_pawns_nav_changed()
	return true


## Convert a world-space point into tile coordinates. Returns (-1, -1) if
## the point is outside the map.
func world_to_tile(world_pos: Vector2) -> Vector2i:
	var half_w: float = WorldData.WIDTH * TILE_PIXELS * 0.5
	var half_h: float = WorldData.HEIGHT * TILE_PIXELS * 0.5
	var local := world_pos - global_position
	var tx: int = int(floor((local.x + half_w) / TILE_PIXELS))
	var ty: int = int(floor((local.y + half_h) / TILE_PIXELS))
	if not data.in_bounds(tx, ty):
		return Vector2i(-1, -1)
	return Vector2i(tx, ty)


## Convert tile coordinates into world-space (centered on the tile).
func tile_to_world(tile: Vector2i) -> Vector2:
	var half_w: float = WorldData.WIDTH * TILE_PIXELS * 0.5
	var half_h: float = WorldData.HEIGHT * TILE_PIXELS * 0.5
	return global_position + Vector2(
		tile.x * TILE_PIXELS - half_w + TILE_PIXELS * 0.5,
		tile.y * TILE_PIXELS - half_h + TILE_PIXELS * 0.5
	)


# ==================== beds ====================
#
# Beds are rendered through the regular feature pipeline (TileFeature.BED), but
# we additionally track them here so pawns can ask "is there a bed I can sleep
# in nearby?" without scanning every tile every tick.
#
# Reservation model: a tired pawn calls reserve_bed() before walking to it,
# then release_bed() on wake or panic-abort. Two pawns can never end up
# walking to the same bed and arguing over it.

func register_bed(tile: Vector2i) -> void:
	if not _bed_tiles.has(tile):
		_bed_tiles.append(tile)
	# Newly built beds start free.
	if not _bed_occupants.has(tile):
		_bed_occupants[tile] = null


func unregister_bed(tile: Vector2i) -> void:
	_bed_tiles.erase(tile)
	_bed_occupants.erase(tile)


func is_bed(tile: Vector2i) -> bool:
	return _bed_occupants.has(tile)


func is_bed_free(tile: Vector2i) -> bool:
	return _bed_occupants.has(tile) and _bed_occupants[tile] == null


## True if the bed is currently reserved/occupied by `pawn` specifically. Used
## by Pawn._decay_needs to grant the bed sleep bonus only to its rightful sleeper.
func is_bed_owned_by(tile: Vector2i, pawn: Pawn) -> bool:
	return _bed_occupants.get(tile, null) == pawn


## Atomically reserve the given bed for `pawn`. Returns false if it's not a
## bed or someone else already holds it. Successful reserve survives the walk
## to the bed and the entire sleep, then must be released.
func reserve_bed(tile: Vector2i, pawn: Pawn) -> bool:
	if not _bed_occupants.has(tile):
		return false
	var current = _bed_occupants[tile]
	if current != null and current != pawn:
		return false
	_bed_occupants[tile] = pawn
	return true


func release_bed(tile: Vector2i, pawn: Pawn) -> void:
	if not _bed_occupants.has(tile):
		return
	if _bed_occupants[tile] == pawn:
		_bed_occupants[tile] = null


## Find the closest unreserved bed reachable from `from_tile` for `pawn`. Closest
## by Chebyshev distance to keep this O(N_beds); reachability uses the connected-
## components map so we never propose a bed across an impassable wall. Returns
## Vector2i(-1,-1) if no bed qualifies.
func find_free_bed_for(pawn: Pawn, from_tile: Vector2i) -> Vector2i:
	if _bed_tiles.is_empty() or pathfinder == null:
		return Vector2i(-1, -1)
	var my_component: int = pathfinder.component_of(from_tile)
	var best := Vector2i(-1, -1)
	var best_dist: int = 0x7FFFFFFF
	for t in _bed_tiles:
		if not is_bed_free(t):
			# Allow a pawn to "find" the bed it already holds (defensive).
			if _bed_occupants.get(t, null) != pawn:
				continue
		if pathfinder.component_of(t) != my_component:
			continue
		var d: int = max(abs(t.x - from_tile.x), abs(t.y - from_tile.y))
		if d < best_dist:
			best = t
			best_dist = d
	return best


func bed_count() -> int:
	return _bed_tiles.size()


## After loading a world from save (or any bulk feature change), rescan the
## map for BED features and repopulate `_bed_tiles` / free slots in
## `_bed_occupants`. No occupants carry over a regen, but load keeps data.
func resync_beds_from_map() -> void:
	_bed_tiles.clear()
	_bed_occupants.clear()
	for y in range(WorldData.HEIGHT):
		for x in range(WorldData.WIDTH):
			if data.get_feature(x, y) == TileFeature.Type.BED:
				var t: Vector2i = Vector2i(x, y)
				register_bed(t)
