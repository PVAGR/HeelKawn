## EnemySpawner.gd — Manages enemy spawning, waves, and difficulty scaling.
class_name EnemySpawner
extends Node

const INITIAL_RAID_SIZE: int = 3
const MAX_ENEMIES: int = 20
const RAID_INTERVAL_TICKS: int = 3000  # ~5 minutes at 1x speed = one raid every 5 in-game days
const DIFFICULTY_SCALE: float = 1.1  # Increase difficulty by 10% each raid

var enemies: Array[Enemy] = []
var _tick_counter: int = 0
var _next_raid_tick: int = RAID_INTERVAL_TICKS
var _raid_number: int = 0
var _difficulty: float = 1.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()


func spawn_raid(world: World) -> void:
	_raid_number += 1
	_difficulty = pow(DIFFICULTY_SCALE, _raid_number)
	
	var raid_size: int = int(INITIAL_RAID_SIZE * _difficulty)
	raid_size = clampi(raid_size, 1, MAX_ENEMIES - enemies.size())
	
	var spawn_edge: int = randi() % 4  # 0=top, 1=bottom, 2=left, 3=right
	var spawn_tiles: Array[Vector2i] = []
	
	# Pick spawn tiles along one edge
	match spawn_edge:
		0:  # Top edge
			for x in range(0, WorldData.WIDTH, 5):
				spawn_tiles.append(Vector2i(x, 0))
		1:  # Bottom edge
			for x in range(0, WorldData.WIDTH, 5):
				spawn_tiles.append(Vector2i(x, WorldData.HEIGHT - 1))
		2:  # Left edge
			for y in range(0, WorldData.HEIGHT, 5):
				spawn_tiles.append(Vector2i(0, y))
		3:  # Right edge
			for y in range(0, WorldData.HEIGHT, 5):
				spawn_tiles.append(Vector2i(WorldData.WIDTH - 1, y))
	
	spawn_tiles.shuffle()
	
	var spawned: int = 0
	for tile in spawn_tiles:
		if spawned >= raid_size:
			break
		
		if not world.pathfinder.is_passable(tile):
			continue
		
		# Pick enemy type based on difficulty
		var enemy_type: int = Enemy.Type.RAIDER
		if _difficulty > 2.0 and randf() < 0.3:
			enemy_type = Enemy.Type.BRIGAND
		if _difficulty > 4.0 and randf() < 0.2:
			enemy_type = Enemy.Type.WARLORD
		
		var enemy := Enemy.new()
		add_child(enemy)
		enemy.bind(enemy_type, tile, world)
		enemies.append(enemy)
		spawned += 1
	
	print("[EnemySpawner] Raid #%d spawned: %d enemies (difficulty %.1fx)" % [_raid_number, spawned, _difficulty])


func cleanup_dead_enemies() -> void:
	enemies = enemies.filter(func(e): return is_instance_valid(e) and e != null)


func get_enemy_count() -> int:
	cleanup_dead_enemies()
	return enemies.size()


func describe() -> String:
	return "Enemies: %d active / %d max (raid #%d, difficulty %.1fx)" % [
		get_enemy_count(), MAX_ENEMIES, _raid_number, _difficulty
	]
