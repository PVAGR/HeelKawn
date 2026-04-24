## Enemy.gd — Hostile entity (raider, brigand) that attacks the colony.
## Enemies spawn in groups, patrol the map, and attempt to destroy buildings/kill pawns.
extends Node2D
class_name Enemy

enum Type { RAIDER, BRIGAND, WARLORD }

const SPECIES_DATA: Dictionary = {
	Type.RAIDER: {
		"name": "Raider",
		"color": Color("#8b0000"),  # dark red
		"speed": 45.0,
		"size": 5.0,
		"health": 30.0,
		"melee_damage": 8.0,  # per hit
		"attack_cooldown": 60,  # ticks between attacks
		"vision_range": 80.0,
	},
	Type.BRIGAND: {
		"name": "Brigand",
		"color": Color("#b22222"),  # firebrick
		"speed": 50.0,
		"size": 5.5,
		"health": 40.0,
		"melee_damage": 10.0,
		"attack_cooldown": 50,
		"vision_range": 100.0,
	},
	Type.WARLORD: {
		"name": "Warlord",
		"color": Color("#8b0000"),  # dark red
		"speed": 55.0,
		"size": 6.5,
		"health": 60.0,
		"melee_damage": 15.0,
		"attack_cooldown": 40,
		"vision_range": 120.0,
	},
}

@export var enemy_type: Type = Type.RAIDER

var tile_pos: Vector2i = Vector2i.ZERO
var world_pos: Vector2 = Vector2.ZERO
var health: float = 30.0
var max_health: float = 30.0
var age_ticks: int = 0
var attack_cooldown: int = 0
var _world: World = null
var _target_pawn: Pawn = null
var _current_path: Array[Vector2i] = []
var _path_index: int = 0
var _dead: bool = false
var _anim_t: float = 0.0
var _sfx: AudioStreamPlayer2D = null

func _ready() -> void:
	add_to_group("enemies")
	GameManager.game_tick.connect(_on_game_tick)
	_sfx = AudioStreamPlayer2D.new()
	_sfx.max_distance = 360.0
	_sfx.volume_db = -4.0
	add_child(_sfx)
	queue_redraw()


func bind(p_enemy_type: Type, p_tile: Vector2i, p_world: World) -> void:
	enemy_type = p_enemy_type
	tile_pos = p_tile
	world_pos = p_world.tile_to_world(tile_pos)
	position = world_pos
	_world = p_world
	var spec = SPECIES_DATA[enemy_type]
	health = spec.health
	max_health = spec.health
	age_ticks = 0
	attack_cooldown = 0


func _physics_process(delta: float) -> void:
	if _dead or _world == null:
		return
	_anim_t += delta * 5.5
	
	# Move along current path or toward target pawn
	var target_world: Vector2
	if _target_pawn != null and is_instance_valid(_target_pawn):
		target_world = _target_pawn.position
	elif not _current_path.is_empty() and _path_index < _current_path.size():
		target_world = _world.tile_to_world(_current_path[_path_index])
	else:
		return
	
	var direction: Vector2 = (target_world - position).normalized()
	var spec = SPECIES_DATA[enemy_type]
	position += direction * spec.speed * delta
	
	# Check if reached tile
	if position.distance_to(target_world) < spec.size * 2:
		tile_pos = _world.world_to_tile(target_world)
		position = target_world
		if not _current_path.is_empty() and _path_index < _current_path.size():
			_path_index += 1


func _on_game_tick(_tick: int) -> void:
	if _dead or _world == null:
		return
	
	age_ticks += 1
	if attack_cooldown > 0:
		attack_cooldown -= 1
	
	# Look for target pawn
	_find_target_pawn()
	
	# If we have a target, attack or move toward it
	if _target_pawn != null and is_instance_valid(_target_pawn):
		var dist_to_target: float = position.distance_to(_target_pawn.position)
		var spec = SPECIES_DATA[enemy_type]
		
		if dist_to_target < spec.size * 3 + 8:  # Melee range
			_attack_pawn(_target_pawn)
		else:
			# Path to target
			var target_tile: Vector2i = _world.world_to_tile(_target_pawn.position)
			_current_path = _world.pathfinder.find_path(tile_pos, target_tile)
			_path_index = 0
	else:
		# Random wander
		if randf() < 0.05:
			_wander()


func _find_target_pawn() -> void:
	var spec = SPECIES_DATA[enemy_type]
	var range_sq: float = spec.vision_range * spec.vision_range
	
	# Target closest pawn
	var closest_pawn: Pawn = null
	var closest_dist_sq: float = INF
	
	for pawn in get_tree().get_nodes_in_group("pawns"):
		if not is_instance_valid(pawn):
			continue
		var dist_sq: float = (pawn.position - position).length_squared()
		if dist_sq < range_sq and dist_sq < closest_dist_sq:
			closest_pawn = pawn
			closest_dist_sq = dist_sq
	
	_target_pawn = closest_pawn


func _attack_pawn(pawn: Pawn) -> void:
	if attack_cooldown > 0 or pawn == null or not is_instance_valid(pawn):
		return
	
	var spec = SPECIES_DATA[enemy_type]
	var damage: float = spec.melee_damage
	
	# Apply some randomness
	damage *= randf_range(0.8, 1.2)
	
	pawn.data.health = max(0.0, pawn.data.health - damage)
	pawn.data.add_mood_event(MoodEvent.Type.DREAD, 80.0, 400)
	attack_cooldown = spec.attack_cooldown
	_play_sfx("res://assets/audio/enemy_attack.ogg", randf_range(0.9, 1.05))
	
	print("[Enemy] %s attacked %s for %.1f damage (health %.1f)" % 
		[spec.name, pawn.data.display_name, damage, pawn.data.health])
	
	# If pawn dies from this hit, trigger despair cascade
	if pawn.data.health <= 0:
		pawn._check_death_conditions()


func _wander() -> void:
	var spec = SPECIES_DATA[enemy_type]
	var range_tiles: int = int(spec.vision_range / 8.0)
	
	var target_x: int = tile_pos.x + randi_range(-range_tiles, range_tiles)
	var target_y: int = tile_pos.y + randi_range(-range_tiles, range_tiles)
	target_x = clampi(target_x, 0, WorldData.WIDTH - 1)
	target_y = clampi(target_y, 0, WorldData.HEIGHT - 1)
	
	_current_path = _world.pathfinder.find_path(tile_pos, Vector2i(target_x, target_y))
	_path_index = 0


func take_damage(damage: float) -> void:
	health = max(0.0, health - damage)
	if health <= 0:
		_die()


func _die() -> void:
	_dead = true
	var spec = SPECIES_DATA[enemy_type]
	# Drop loot
	_drop_loot()
	_play_sfx("res://assets/audio/enemy_die.ogg", 0.9)
	remove_from_group("enemies")
	queue_free()


func _drop_loot() -> void:
	# Enemies drop random loot: wood, stone, or items
	var loot_type: int = Item.Type.NONE
	var loot_qty: int = 0
	
	match randi() % 3:
		0:  # Wood
			loot_type = Item.Type.WOOD
			loot_qty = randi_range(1, 3)
		1:  # Stone
			loot_type = Item.Type.STONE
			loot_qty = randi_range(2, 4)
		2:  # Food
			loot_type = Item.Type.MEAT
			loot_qty = randi_range(1, 2)
	
	if loot_type != Item.Type.NONE:
		var sp: Stockpile = StockpileManager.find_drop_zone(loot_type, tile_pos, _world.pathfinder)
		if sp != null:
			sp.add_item(loot_type, loot_qty)
			print("[Enemy] %s dropped %d %s" % [SPECIES_DATA[enemy_type].name, loot_qty, Item.name_for(loot_type)])


func _draw() -> void:
	if _dead:
		return
	var spec = SPECIES_DATA[enemy_type]
	var color: Color = spec.color
	var pulse: float = 0.2 + 0.2 * (sin(_anim_t) * 0.5 + 0.5)
	# Health affects color brightness
	var health_factor: float = clamp(health / max_health, 0.2, 1.0)
	color = color.lerp(Color.BLACK, 1.0 - health_factor)
	draw_circle(Vector2.ZERO, spec.size, color)
	draw_circle(Vector2.ZERO, spec.size + 0.8, Color(color.r, color.g, color.b, pulse), false)
	# Compact health bar under enemy
	var ratio: float = clamp(health / max_health, 0.0, 1.0)
	var w: float = spec.size * 2.2
	var bg := Rect2(Vector2(-w * 0.5, spec.size + 2.8), Vector2(w, 1.1))
	draw_rect(bg, Color(0, 0, 0, 0.7), true)
	if ratio > 0.0:
		draw_rect(Rect2(bg.position, Vector2(bg.size.x * ratio, bg.size.y)), Color(1.0, 0.25, 0.2), true)


func get_species_name() -> String:
	return SPECIES_DATA[enemy_type].name


func _play_sfx(path: String, pitch: float = 1.0) -> void:
	if _sfx == null or not ResourceLoader.exists(path):
		return
	var stream: AudioStream = load(path)
	if stream == null:
		return
	_sfx.stream = stream
	_sfx.pitch_scale = pitch
	_sfx.play()
