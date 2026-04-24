class_name WorldGenerator
extends RefCounted

## Seeded procedural world generator.
## Step 1: two Perlin fields (elevation + moisture).
## Step 2: percentile-based biome classification (stable distribution regardless
##         of how tightly FastNoiseLite's fractal layers compress the output).
## Step 3: scatter TileFeatures (ore veins, fertile soil, ruins) on valid biomes.

const ELEVATION_FREQUENCY: float = 0.012
const ELEVATION_OCTAVES: int = 4

const MOISTURE_FREQUENCY: float = 0.010
const MOISTURE_OCTAVES: int = 3

## Percentile splits for elevation (ascending percentiles).
## water | tundra | (plains/desert/forest middle band) | mountain
const P_ELEV_WATER:    float = 0.10   # bottom 10%  -> water       (~10% of map)
const P_ELEV_TUNDRA:   float = 0.22   # 10..22%    -> tundra      (~12% of map)
const P_ELEV_MOUNTAIN: float = 0.88   # top 12%    -> mountain    (~12% of map)
                                      # middle 66% -> moisture-based biomes

## Percentile splits for moisture within the middle elevation band.
## Because elevation and moisture are independent noise fields, global moisture
## percentiles map cleanly onto the middle-elevation subset.
const P_MOIST_DESERT: float = 0.25    # bottom 25% moisture -> desert
const P_MOIST_PLAINS: float = 0.75    # 25..75% moisture   -> plains
                                      # top 25% moisture   -> forest
##
## Expected final distribution:
##   water ~10%, tundra ~12%, mountain ~12%,
##   desert ~16%, plains ~33%, forest ~16%.

## Feature scatter tuning.
## Mountain ore: bigger clusters than v1 because most of these are sealed and
## need MINE_WALL to reach -- you want plenty of payoff once a tunnel breaks
## through. Bumped ~2x from the original.
const ORE_CLUSTERS: int = 20
const ORE_CLUSTER_SIZE_MIN: int = 5
const ORE_CLUSTER_SIZE_MAX: int = 14

## Surface ore: small loose deposits scattered onto plains/desert. These give
## the colony a steady stone supply even before they tunnel. Used to be missing
## entirely, which is why pawns leveled Mining 0 -- there was nothing to mine.
const SURFACE_ORE_CLUSTERS: int = 14
const SURFACE_ORE_CLUSTER_SIZE_MIN: int = 1
const SURFACE_ORE_CLUSTER_SIZE_MAX: int = 4

const FERTILE_CLUSTERS: int = 18
const FERTILE_CLUSTER_SIZE_MIN: int = 4
const FERTILE_CLUSTER_SIZE_MAX: int = 12

const RUIN_COUNT: int = 6

## Per-tile chance to receive a TREE feature, by biome. Trees only land on
## tiles that don't already have a feature, so existing FERTILE_SOIL clusters
## are preserved. Net result: dense (but not solid) forests + scattered
## woodlots in plains.
const TREE_CHANCE_FOREST: float = 0.35
const TREE_CHANCE_PLAINS: float = 0.04

## Wildlife counts. Rabbits are common chip-shots (1 meat each); deer are
## scarcer big-game targets (2 meat each, slower hunt). Both only spawn on
## empty tiles so they never overwrite ore / fertile / trees / ruins.
const RABBIT_COUNT: int = 28
const DEER_COUNT:   int = 10


static func generate(world_seed: int) -> WorldData:
	var data := WorldData.new()
	data.world_seed = world_seed

	var elev_noise := FastNoiseLite.new()
	elev_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	elev_noise.seed = world_seed
	elev_noise.frequency = ELEVATION_FREQUENCY
	elev_noise.fractal_octaves = ELEVATION_OCTAVES

	var moist_noise := FastNoiseLite.new()
	moist_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	moist_noise.seed = world_seed ^ 0x5A5A5A5A
	moist_noise.frequency = MOISTURE_FREQUENCY
	moist_noise.fractal_octaves = MOISTURE_OCTAVES

	# Pass 1: sample both noise fields into the data arrays.
	for y in range(WorldData.HEIGHT):
		for x in range(WorldData.WIDTH):
			var i: int = data.index(x, y)
			data.elevation[i] = (elev_noise.get_noise_2d(x, y) + 1.0) * 0.5
			data.moisture[i] = (moist_noise.get_noise_2d(x, y) + 1.0) * 0.5

	# Pass 2: derive percentile thresholds from the actual sampled distribution.
	var elev_sorted: PackedFloat32Array = data.elevation.duplicate()
	elev_sorted.sort()
	var moist_sorted: PackedFloat32Array = data.moisture.duplicate()
	moist_sorted.sort()

	var water_t: float = _percentile(elev_sorted, P_ELEV_WATER)
	var tundra_t: float = _percentile(elev_sorted, P_ELEV_TUNDRA)
	var mountain_t: float = _percentile(elev_sorted, P_ELEV_MOUNTAIN)
	var desert_t: float = _percentile(moist_sorted, P_MOIST_DESERT)
	var plains_t: float = _percentile(moist_sorted, P_MOIST_PLAINS)

	# Pass 3: classify using the derived thresholds.
	for i in range(WorldData.TILE_COUNT):
		data.biomes[i] = _classify(
			data.elevation[i], data.moisture[i],
			water_t, tundra_t, mountain_t, desert_t, plains_t
		)

	_scatter_features(data, world_seed)
	return data


static func _percentile(sorted_values: PackedFloat32Array, p: float) -> float:
	var n: int = sorted_values.size()
	if n == 0:
		return 0.0
	var idx: int = clamp(int(p * n), 0, n - 1)
	return sorted_values[idx]


static func _classify(
	e: float, m: float,
	water_t: float, tundra_t: float, mountain_t: float,
	desert_t: float, plains_t: float
) -> int:
	if e < water_t:
		return Biome.Type.WATER
	if e > mountain_t:
		return Biome.Type.MOUNTAIN
	if e < tundra_t:
		return Biome.Type.TUNDRA
	if m < desert_t:
		return Biome.Type.DESERT
	if m < plains_t:
		return Biome.Type.PLAINS
	return Biome.Type.FOREST


static func _scatter_features(data: WorldData, world_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ 0xABCD1234

	_scatter_cluster(
		data, rng, ORE_CLUSTERS,
		ORE_CLUSTER_SIZE_MIN, ORE_CLUSTER_SIZE_MAX,
		[Biome.Type.MOUNTAIN],
		TileFeature.Type.ORE_VEIN
	)
	# Surface ore on passable land -- pawns can mine these directly without
	# tunneling, so they always have *some* mining work available.
	_scatter_cluster(
		data, rng, SURFACE_ORE_CLUSTERS,
		SURFACE_ORE_CLUSTER_SIZE_MIN, SURFACE_ORE_CLUSTER_SIZE_MAX,
		[Biome.Type.PLAINS, Biome.Type.DESERT, Biome.Type.TUNDRA],
		TileFeature.Type.ORE_VEIN
	)
	_scatter_cluster(
		data, rng, FERTILE_CLUSTERS,
		FERTILE_CLUSTER_SIZE_MIN, FERTILE_CLUSTER_SIZE_MAX,
		[Biome.Type.PLAINS, Biome.Type.FOREST],
		TileFeature.Type.FERTILE_SOIL
	)
	_scatter_single(
		data, rng, RUIN_COUNT,
		[Biome.Type.PLAINS, Biome.Type.FOREST, Biome.Type.DESERT, Biome.Type.TUNDRA],
		TileFeature.Type.RUIN
	)
	_scatter_trees(data, rng)
	# Wildlife last so we can cleanly skip any tile that already has a feature.
	_scatter_wildlife(data, rng)


## Place RABBIT_COUNT rabbits + DEER_COUNT deer on random empty tiles in
## plains/forest. We sample candidate tiles instead of trying to find an
## empty one in a tight loop -- the world is mostly empty so this converges
## fast and never overwrites existing features. Deer prefer forest, rabbits
## prefer plains, but both can appear in either.
static func _scatter_wildlife(data: WorldData, rng: RandomNumberGenerator) -> void:
	_scatter_animal(
		data, rng, RABBIT_COUNT,
		[Biome.Type.PLAINS, Biome.Type.FOREST],
		TileFeature.Type.RABBIT
	)
	_scatter_animal(
		data, rng, DEER_COUNT,
		[Biome.Type.FOREST, Biome.Type.PLAINS],
		TileFeature.Type.DEER
	)


## Place `count` of `feature` on random tiles whose biome is in `allowed_biomes`
## AND whose feature slot is currently NONE. Up to 80 attempts per animal --
## if we can't find an empty matching tile that fast the map is full enough
## that one fewer rabbit doesn't matter.
static func _scatter_animal(
	data: WorldData,
	rng: RandomNumberGenerator,
	count: int,
	allowed_biomes: Array,
	feature: int
) -> void:
	for _i in range(count):
		var placed: bool = false
		for _try in range(80):
			var tx: int = rng.randi_range(0, WorldData.WIDTH - 1)
			var ty: int = rng.randi_range(0, WorldData.HEIGHT - 1)
			var idx: int = data.index(tx, ty)
			if data.features[idx] != TileFeature.Type.NONE:
				continue
			if not (data.biomes[idx] in allowed_biomes):
				continue
			data.features[idx] = feature
			placed = true
			break
		if not placed:
			break  # map is saturated; stop trying so we don't burn cycles


## Probabilistic per-tile tree placement. Runs AFTER cluster scatter so it
## doesn't overwrite fertile soil / ore / ruins. Stays out of impassable
## biomes (you can't grow a tree on a lake or a mountain).
static func _scatter_trees(data: WorldData, rng: RandomNumberGenerator) -> void:
	for y in range(WorldData.HEIGHT):
		for x in range(WorldData.WIDTH):
			var i: int = data.index(x, y)
			if data.features[i] != TileFeature.Type.NONE:
				continue
			var biome: int = data.biomes[i]
			var chance: float = 0.0
			if biome == Biome.Type.FOREST:
				chance = TREE_CHANCE_FOREST
			elif biome == Biome.Type.PLAINS:
				chance = TREE_CHANCE_PLAINS
			else:
				continue
			if rng.randf() < chance:
				data.features[i] = TileFeature.Type.TREE


## Drop `count` clusters of `feature` onto tiles whose biome is in `allowed_biomes`.
## Each cluster is a small random walk so it looks organic, not circular.
static func _scatter_cluster(
	data: WorldData,
	rng: RandomNumberGenerator,
	count: int,
	size_min: int,
	size_max: int,
	allowed_biomes: Array,
	feature: int
) -> void:
	for _i in range(count):
		var seed_pos := _find_random_tile_of_biomes(data, rng, allowed_biomes)
		if seed_pos.x < 0:
			continue
		var size: int = rng.randi_range(size_min, size_max)
		var cx: int = seed_pos.x
		var cy: int = seed_pos.y
		for _j in range(size):
			if data.in_bounds(cx, cy) and data.biomes[data.index(cx, cy)] in allowed_biomes:
				data.features[data.index(cx, cy)] = feature
			cx += rng.randi_range(-1, 1)
			cy += rng.randi_range(-1, 1)


## Drop `count` single-tile features on tiles of the allowed biomes.
static func _scatter_single(
	data: WorldData,
	rng: RandomNumberGenerator,
	count: int,
	allowed_biomes: Array,
	feature: int
) -> void:
	for _i in range(count):
		var pos := _find_random_tile_of_biomes(data, rng, allowed_biomes)
		if pos.x < 0:
			continue
		data.features[data.index(pos.x, pos.y)] = feature


static func _find_random_tile_of_biomes(
	data: WorldData,
	rng: RandomNumberGenerator,
	allowed_biomes: Array
) -> Vector2i:
	for _try in range(80):
		var tx: int = rng.randi_range(0, WorldData.WIDTH - 1)
		var ty: int = rng.randi_range(0, WorldData.HEIGHT - 1)
		if data.biomes[data.index(tx, ty)] in allowed_biomes:
			return Vector2i(tx, ty)
	return Vector2i(-1, -1)
