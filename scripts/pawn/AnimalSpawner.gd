## AnimalSpawner.gd — Manages animal lifecycle: spawning, population control, starvation.
class_name AnimalSpawner
extends Node

const INITIAL_RABBITS: int = 8
const INITIAL_DEER: int = 4
const MAX_ANIMALS: int = 50
const SPAWN_RATE_CHECK_INTERVAL: int = 100  # ticks between population checks

var animals: Array[Animal] = []
var _tick_counter: int = 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()


func spawn_initial(world: World) -> void:
	_spawn_group(Animal.Type.RABBIT, INITIAL_RABBITS, world)
	_spawn_group(Animal.Type.DEER, INITIAL_DEER, world)
	print("[AnimalSpawner] Spawned %d rabbits and %d deer" % [INITIAL_RABBITS, INITIAL_DEER])


func _spawn_group(animal_type: int, count: int, world: World) -> void:
	var spawned: int = 0
	for attempt in range(count * 10):  # max 10x attempts
		if spawned >= count or animals.size() >= MAX_ANIMALS:
			break
		
		var tile := Vector2i(
			_rng.randi_range(0, WorldData.WIDTH - 1),
			_rng.randi_range(0, WorldData.HEIGHT - 1)
		)
		
		var biome: int = world.data.get_biome(tile.x, tile.y)
		# Rabbits: forests and plains. Deer: only forests.
		if animal_type == Animal.Type.RABBIT:
			if not biome in [Biome.Type.FOREST, Biome.Type.PLAINS]:
				continue
		elif animal_type == Animal.Type.DEER:
			if biome != Biome.Type.FOREST:
				continue
		
		if not world.pathfinder.is_passable(tile):
			continue
		
		var animal := Animal.new()
		add_child(animal)
		animal.bind(animal_type, tile, world)
		animals.append(animal)
		spawned += 1


func spawn_animal(animal_type: int, tile: Vector2i, world: World = null) -> void:
	if world == null:
		# Find world from scene tree
		if has_node("/root/Main"):
			var main = get_node("/root/Main")
			if main.has_method("get_world"):
				world = main.get_world()
	
	if world == null or animals.size() >= MAX_ANIMALS:
		return
	
	var animal := Animal.new()
	add_child(animal)
	animal.bind(animal_type, tile, world)
	animals.append(animal)


func cleanup_dead_animals() -> void:
	animals = animals.filter(func(a): return is_instance_valid(a) and a != null)


func get_animal_count_by_type(animal_type: int) -> int:
	var count: int = 0
	for animal in animals:
		if is_instance_valid(animal) and animal.animal_type == animal_type:
			count += 1
	return count


func describe() -> String:
	var rabbits: int = get_animal_count_by_type(Animal.Type.RABBIT)
	var deer: int = get_animal_count_by_type(Animal.Type.DEER)
	return "Animals: %d rabbits, %d deer (total %d / %d)" % [rabbits, deer, animals.size(), MAX_ANIMALS]
