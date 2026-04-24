## CombatResolver.gd — Handles melee combat rounds between pawns and enemies
class_name CombatResolver

# Combat mechanics tuning
const BASE_HIT_CHANCE: float = 0.75  # 75% base hit probability
const BASE_DODGE_CHANCE: float = 0.2  # 20% dodge chance (enemy type dependent)
const BASE_DAMAGE: float = 10.0
const SKILL_ACCURACY_BONUS_PER_LEVEL: float = 0.02  # 2% accuracy per skill level
const SKILL_DODGE_BONUS_PER_LEVEL: float = 0.02  # 2% dodge per rest level (endurance proxy)

## Execute one attack from attacker to defender. Returns true if hit landed.
## Defender takes damage, loses health, may be injured.
static func resolve_attack(attacker: Node, defender: Node) -> bool:
	if attacker == null or defender == null:
		return false
	
	# Determine if attack hits
	var hit_chance: float = BASE_HIT_CHANCE
	
	# Apply attacker accuracy (for pawns, use skill levels)
	if attacker is Pawn:
		var pawn_attacker: Pawn = attacker as Pawn
		var avg_skill: float = _get_average_skill(pawn_attacker.data) / 100.0
		hit_chance += SKILL_ACCURACY_BONUS_PER_LEVEL * avg_skill
	
	# Apply defender dodge (for pawns, use rest as endurance proxy)
	if defender is Pawn:
		var pawn_defender: Pawn = defender as Pawn
		var dodge_chance: float = pawn_defender.data.rest * 0.002 + 0.1  # 10% base + 0.2% per rest
		hit_chance = hit_chance * (1.0 - dodge_chance)
	elif defender is Enemy:
		var enemy: Enemy = defender as Enemy
		var spec = Enemy.SPECIES_DATA.get(enemy.enemy_type, {})
		var dodge_chance: float = BASE_DODGE_CHANCE
		hit_chance *= (1.0 - dodge_chance)
	
	hit_chance = clamp(hit_chance, 0.2, 0.95)
	
	# Roll to hit
	if randf() > hit_chance:
		return false
	
	# Calculate damage
	var damage: float = _calculate_damage(attacker, defender)
	
	# Apply damage
	if defender is Pawn:
		var pawn_defender: Pawn = defender as Pawn
		pawn_defender.data.health = max(0.0, pawn_defender.data.health - damage)
		pawn_defender.data.add_mood_event(MoodEvent.Type.STRESS, 60.0, 300)
		
		# Injury check: small chance to get injured
		if randf() < 0.15:  # 15% injury chance per hit
			pawn_defender.data.add_mood_event(MoodEvent.Type.STRESS, 40.0, 200)
		
		if pawn_defender.data.health <= 0:
			pawn_defender._check_death_conditions()
		
		print("[Combat] Pawn %s took %.1f damage (health %.1f)" % 
			[pawn_defender.data.display_name, damage, pawn_defender.data.health])
	
	elif defender is Enemy:
		var enemy_defender: Enemy = defender as Enemy
		enemy_defender.take_damage(damage)
		print("[Combat] Enemy %s took %.1f damage (health %.1f)" % 
			[enemy_defender.get_species_name(), damage, enemy_defender.health])
	
	return true


## Calculate damage from attacker to defender
static func _calculate_damage(attacker: Node, defender: Node) -> float:
	var damage: float = BASE_DAMAGE
	
	# Attacker modifiers
	if attacker is Pawn:
		var pawn_attacker: Pawn = attacker as Pawn
		# Skill-based damage: mining/hunting skills translate to combat
		var combat_skill: float = (pawn_attacker.data.skill_xp.get(PawnData.Skill.HUNTING, 0.0) +
									pawn_attacker.data.skill_xp.get(PawnData.Skill.MINING, 0.0)) / 200.0
		damage *= (1.0 + combat_skill * 0.5)  # Up to 50% damage increase from skills
		
		# Health/rest affects damage
		damage *= pawn_attacker.data.effective_labor_mult()
		
		# Trait multipliers
		damage *= pawn_attacker.data.get_trait_mult("work_speed_mult")
	
	elif attacker is Enemy:
		var enemy: Enemy = attacker as Enemy
		var spec = Enemy.SPECIES_DATA.get(enemy.enemy_type, {})
		damage = spec.get("melee_damage", BASE_DAMAGE)
	
	# Defender reduction
	if defender is Pawn:
		var pawn_defender: Pawn = defender as Pawn
		# Armor concept: health affects damage reduction
		var armor_factor: float = 1.0 - (pawn_defender.data.health / 200.0).clamp(0.0, 0.5)
		damage *= (1.0 - armor_factor)
	
	return max(1.0, damage)


## Get average of all skill levels (for accuracy calculation)
static func _get_average_skill(pawn_data: PawnData) -> float:
	var total: float = 0.0
	var count: int = 0
	for skill_xp in pawn_data.skill_xp.values():
		total += skill_xp
		count += 1
	return total / max(1, count)
