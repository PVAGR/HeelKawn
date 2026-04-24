class_name WorldData
extends RefCounted

## Source of truth for the colony map. Rendering, AI, pathfinding, and save/load
## all read from here. Packed arrays are used so a 256x256 world stays under a
## few hundred KB and iterates fast.

const WIDTH: int = 256
const HEIGHT: int = 256
const TILE_COUNT: int = WIDTH * HEIGHT

## One byte per tile, values are Biome.Type.
var biomes: PackedByteArray

## One byte per tile, values are TileFeature.Type. Most tiles will be NONE (0).
var features: PackedByteArray

## 0.0..1.0, higher = mountains, lower = lowlands.
var elevation: PackedFloat32Array

## 0.0..1.0, higher = wetter.
var moisture: PackedFloat32Array

var world_seed: int = 0


func _init() -> void:
	biomes.resize(TILE_COUNT)
	features.resize(TILE_COUNT)
	elevation.resize(TILE_COUNT)
	moisture.resize(TILE_COUNT)


func index(x: int, y: int) -> int:
	return y * WIDTH + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < WIDTH and y >= 0 and y < HEIGHT


func get_biome(x: int, y: int) -> int:
	return biomes[index(x, y)]


## Overwrite a tile's biome. Used when a wall is mined out (MOUNTAIN ->
## STONE_FLOOR), and any future "build wall" / terraforming systems.
## Caller is responsible for refreshing the visual + pathfinder state.
func set_biome(x: int, y: int, biome: int) -> void:
	if not in_bounds(x, y):
		return
	biomes[index(x, y)] = biome


func get_feature(x: int, y: int) -> int:
	return features[index(x, y)]


func get_elevation(x: int, y: int) -> float:
	return elevation[index(x, y)]


func get_moisture(x: int, y: int) -> float:
	return moisture[index(x, y)]


## Walkability for pathing: passable biomes, no solid built walls. Doors and
## beds (and all other current features) count as walk-through for v1
## (doors stay passable; beds are not terrain blocks).
static func is_tile_walkable(data: WorldData, x: int, y: int) -> bool:
	if not data.in_bounds(x, y):
		return false
	var i: int = data.index(x, y)
	if not Biome.is_passable(data.biomes[i]):
		return false
	if int(data.features[i]) == TileFeature.Type.WALL:
		return false
	return true


## For `GameSave` / `store_var`. Packed arrays round-trip in the snapshot dict.
func to_save_dict() -> Dictionary:
	return {
		"world_seed": world_seed,
		"biomes": biomes,
		"features": features,
		"elevation": elevation,
		"moisture": moisture,
	}


## Rebuilds map data on load. Returns `null` if arrays are wrong size or type.
static func from_save_dict(d: Dictionary) -> Variant:
	if d.is_empty():
		return null
	var w := WorldData.new()
	w.world_seed = int(d.get("world_seed", 0))
	if not _fill_byte_array(w.biomes, d.get("biomes", null)):
		return null
	if not _fill_byte_array(w.features, d.get("features", null)):
		return null
	if not _fill_float32_array(w.elevation, d.get("elevation", null)):
		return null
	if not _fill_float32_array(w.moisture, d.get("moisture", null)):
		return null
	return w


static func _fill_byte_array(into: PackedByteArray, v: Variant) -> bool:
	if v is PackedByteArray:
		if v.size() != TILE_COUNT:
			return false
		for i in range(TILE_COUNT):
			into[i] = v[i]
		return true
	if v is Array:
		if v.size() != TILE_COUNT:
			return false
		for i in range(TILE_COUNT):
			into[i] = int(v[i]) & 0xFF
		return true
	return false


static func _fill_float32_array(into: PackedFloat32Array, v: Variant) -> bool:
	if v is PackedFloat32Array:
		if v.size() != TILE_COUNT:
			return false
		for i in range(TILE_COUNT):
			into[i] = v[i]
		return true
	if v is Array:
		if v.size() != TILE_COUNT:
			return false
		for i in range(TILE_COUNT):
			into[i] = float(v[i])
		return true
	return false
