class_name PawnSpawner
extends Node

## Spawns the starting group of pawns. Main drives the lifecycle (spawn order
## relative to world + stockpile placement is important), so this script no
## longer auto-spawns on _ready.
##
## Spawns are restricted to a single connected component when requested, which
## guarantees every pawn can reach the stockpile and pick up jobs on its own
## landmass. Otherwise falls back to any plains/forest tile.

const STARTER_COUNT: int = 5
const MAX_PLACEMENT_ATTEMPTS: int = 2000

const FIRST_NAMES: Array[String] = [
	"Aldric", "Brenna", "Cormac", "Dena", "Elric", "Fiona", "Garrick",
	"Hilda", "Ivor", "Jora", "Kenan", "Lira", "Morven", "Nessa",
	"Osric", "Petra", "Quinn", "Rhea", "Silas", "Tess", "Ulric",
	"Vera", "Wren", "Xara", "Yorick", "Zella",
]

const PAWN_COLORS: Array[Color] = [
	Color("#29b6f6"),  # light blue
	Color("#ef5350"),  # red
	Color("#ffee58"),  # yellow
	Color("#ab47bc"),  # purple
	Color("#26a69a"),  # teal
	Color("#ff7043"),  # orange
	Color("#ec407a"),  # pink
]

const SPAWNABLE_BIOMES: Array[int] = [Biome.Type.PLAINS, Biome.Type.FOREST]

@export var pawn_scene: PackedScene

var pawns: Array[Pawn] = []
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()


## Free existing pawns (releasing any claimed jobs) and spawn a fresh set.
## required_component_id defaults to -1 (no constraint); pass a component id
## to confine spawning to a specific landmass (e.g. the one containing the
## stockpile).
func respawn(world: World, required_component_id: int = -1) -> void:
	clear_pawns()
	spawn_starters(world, required_component_id)


func clear_pawns() -> void:
	for p in pawns:
		if p != null and is_instance_valid(p):
			p.release_job_if_any()
			p.queue_free()
	pawns.clear()


## Remove a pawn from the spawner (when it dies). Cleans up the reference.
func remove_pawn(pawn: Pawn) -> void:
	pawns.erase(pawn)
	if pawn != null and is_instance_valid(pawn):
		pawn.release_job_if_any()
		pawn.queue_free()


## Dump a needs + skills table for all pawns. Hotkeyed to T by Main.gd.
func print_stats() -> void:
	print("[Stats] --- pawn needs (tick %d) ---" % GameManager.tick_count)
	print("[Stats]   Name               Age  Hunger  Rest   Mood   Carrying          Skills (Fo/Mi/Ch/Bu/Hu)   Tile")
	for p in pawns:
		var d := p.data
		var carry_str: String = "-"
		if d.is_carrying():
			carry_str = "%s x%d" % [Item.name_for(d.carrying), d.carrying_qty]
		var skills_str: String = "%2d/%2d/%2d/%2d/%2d" % [
			d.get_skill_level(PawnData.Skill.FORAGING),
			d.get_skill_level(PawnData.Skill.MINING),
			d.get_skill_level(PawnData.Skill.CHOPPING),
			d.get_skill_level(PawnData.Skill.BUILDING),
			d.get_skill_level(PawnData.Skill.HUNTING),
		]
		print("[Stats]   %-18s %3d  %5.1f   %5.1f  %5.1f  %-16s  %-25s (%d,%d)" %
			[d.display_name, d.age, d.hunger, d.rest, d.mood, carry_str,
			 skills_str, d.tile_pos.x, d.tile_pos.y])


func spawn_starters(world: World, required_component_id: int = -1) -> void:
	var used_tiles: Dictionary = {}
	var placed: int = 0
	for attempt in range(MAX_PLACEMENT_ATTEMPTS):
		if placed >= STARTER_COUNT:
			break
		var tile := Vector2i(
			_rng.randi_range(0, WorldData.WIDTH - 1),
			_rng.randi_range(0, WorldData.HEIGHT - 1)
		)
		if used_tiles.has(tile):
			continue
		var biome: int = world.data.get_biome(tile.x, tile.y)
		if not SPAWNABLE_BIOMES.has(biome):
			continue
		if required_component_id >= 0 and world.pathfinder.component_of(tile) != required_component_id:
			continue
		used_tiles[tile] = true

		var data := PawnData.new()
		data.display_name = _pick_name(used_tiles)
		data.age = _rng.randi_range(18, 55)
		data.gender = _rng.randi_range(0, 1)
		data.tile_pos = tile
		data.color = PAWN_COLORS[placed % PAWN_COLORS.size()]
		
		# Assign 0-2 random traits to this pawn
		_assign_random_traits(data)

		var pawn: Pawn = pawn_scene.instantiate()
		add_child(pawn)
		pawn.bind(data, world.tile_to_world(tile), world)
		pawns.append(pawn)
		placed += 1

		print("[Spawn] #%d %s  tile=(%d,%d) biome=%s" %
			[placed, data.describe(), tile.x, tile.y, Biome.name_for(biome)])

	if placed < STARTER_COUNT:
		push_warning("[PawnSpawner] Only placed %d / %d pawns (component=%d)" %
			[placed, STARTER_COUNT, required_component_id])


## Reconstruct one pawn from `PawnData` (e.g. after `PawnData.from_save_dict`). Does
## not check component — caller must ensure the tile is passable.
func spawn_from_data(d: PawnData, world: World) -> void:
	var p: Pawn = pawn_scene.instantiate()
	add_child(p)
	p.bind(d, world.tile_to_world(d.tile_pos), world)
	pawns.append(p)
	print("[Spawn] load: %s @(%d,%d)" % [d.display_name, d.tile_pos.x, d.tile_pos.y])


## Pick a name we haven't used yet this run.
func _pick_name(used_tiles: Dictionary) -> String:
	var used_names: Dictionary = {}
	for p in pawns:
		used_names[p.data.display_name] = true
	var available: Array[String] = []
	for n in FIRST_NAMES:
		if not used_names.has(n):
			available.append(n)
	if available.is_empty():
		return "Settler-%d" % used_tiles.size()
	return available[_rng.randi() % available.size()]


## Assign 0-2 random traits to a pawn. Called at spawn time.
func _assign_random_traits(pawn_data: PawnData) -> void:
	var num_traits: int = _rng.randi_range(0, 2)  # 0, 1, or 2 traits
	var trait_types: Array = Trait.Type.values()
	var assigned: Dictionary = {}
	
	for _i in range(num_traits):
		if trait_types.is_empty():
			break
		var trait_type = trait_types[_rng.randi() % trait_types.size()]
		# Avoid duplicate traits
		if not assigned.has(trait_type):
			assigned[trait_type] = true
			var trait := Trait.new(trait_type)
			pawn_data.add_trait(trait)
			print("[Spawn] trait: %s -> %s" % [pawn_data.display_name, trait.display_name])

