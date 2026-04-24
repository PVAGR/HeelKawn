## Trait.gd — Pawn trait system. Traits modify need decay, skill XP, work speed,
## mood thresholds, and other gameplay multipliers.
extends Resource
class_name Trait

enum Type {
	# Physical/Work
	WORKHORSE,      # +20% work speed, +50% hunger
	LAZY,           # -30% work speed, -20% hunger
	TOUGH,          # +25% health max, -10% damage taken
	FRAIL,          # -25% health max, +25% damage taken
	
	# Mental/Learning
	QUICK_LEARNER,  # +50% skill XP gain
	SLOW_LEARNER,   # -50% skill XP gain
	FOCUSED,        # +30% work speed when well-rested
	EASILY_BORED,   # -20% work speed if doing same job >30 ticks
	
	# Social/Mood
	OPTIMIST,       # Mood slowly improves even without positive events
	PESSIMIST,      # Mood decays faster, needs more joy
	SOCIAL,         # Gets mood boost from other pawns nearby
	LONER,          # Mood penalty if too many pawns nearby
	
	# Need-based
	IRON_STOMACH,   # -30% hunger decay
	EATS_LIKE_BIRD, # +30% hunger decay
	NIGHT_OWL,      # -30% rest decay at night, +30% rest decay during day
	EARLY_BIRD,     # +30% rest decay at night, -30% rest decay during day
	
	# Hazard/Job-specific
	UNLUCKY,        # +50% chance injury during hazardous jobs
	LUCKY,          # -50% chance injury during hazardous jobs
	RECKLESS,       # +30% work speed but +100% injury chance
	CAUTIOUS,       # -20% work speed but -50% injury chance
}

## Name and description of this trait.
@export var trait_type: Type
@export var display_name: String
@export var description: String

## Multipliers applied when this pawn has this trait.
## (Default 1.0 = no change)
@export var hunger_decay_mult: float = 1.0
@export var rest_decay_mult: float = 1.0
@export var mood_decay_mult: float = 1.0
@export var health_max_mult: float = 1.0
@export var skill_xp_mult: float = 1.0
@export var work_speed_mult: float = 1.0
@export var injury_chance_mult: float = 1.0
@export var damage_taken_mult: float = 1.0

func _init(p_type: Type = Type.WORKHORSE) -> void:
	trait_type = p_type
	_init_from_type()

func _init_from_type() -> void:
	match trait_type:
		Type.WORKHORSE:
			display_name = "Workhorse"
			description = "Loves to work, rarely tires of labor."
			work_speed_mult = 1.2
			hunger_decay_mult = 1.5
		Type.LAZY:
			display_name = "Lazy"
			description = "Moves slowly, takes frequent breaks."
			work_speed_mult = 0.7
			hunger_decay_mult = 0.8
		Type.TOUGH:
			display_name = "Tough"
			description = "Resilient to injury and pain."
			health_max_mult = 1.25
			damage_taken_mult = 0.9
		Type.FRAIL:
			display_name = "Frail"
			description = "Weak and easily hurt."
			health_max_mult = 0.75
			damage_taken_mult = 1.25
		Type.QUICK_LEARNER:
			display_name = "Quick Learner"
			description = "Picks up skills rapidly."
			skill_xp_mult = 1.5
		Type.SLOW_LEARNER:
			display_name = "Slow Learner"
			description = "Struggles to master new skills."
			skill_xp_mult = 0.5
		Type.FOCUSED:
			display_name = "Focused"
			description = "Works best when well-rested."
			# Special: handled in Pawn.effective_labor_mult()
		Type.EASILY_BORED:
			display_name = "Easily Bored"
			description = "Gets restless doing the same thing."
			# Special: tracked in Pawn._same_job_tick_counter
		Type.OPTIMIST:
			display_name = "Optimist"
			description = "Stays cheerful even in hardship."
			mood_decay_mult = 0.7
		Type.PESSIMIST:
			display_name = "Pessimist"
			description = "Always sees the dark side."
			mood_decay_mult = 1.3
		Type.SOCIAL:
			display_name = "Social"
			description = "Enjoys time with other pawns."
			# Special: mood boost when others nearby
		Type.LONER:
			display_name = "Loner"
			description = "Prefers to work alone."
			# Special: mood penalty when crowded
		Type.IRON_STOMACH:
			display_name = "Iron Stomach"
			description = "Can survive on almost nothing."
			hunger_decay_mult = 0.7
		Type.EATS_LIKE_BIRD:
			display_name = "Eats Like a Bird"
			description = "Always hungry despite eating well."
			hunger_decay_mult = 1.3
		Type.NIGHT_OWL:
			display_name = "Night Owl"
			description = "Prefers working at night."
			# Special: handled in DayNightCycle
		Type.EARLY_BIRD:
			display_name = "Early Bird"
			description = "Rises with the sun."
			# Special: handled in DayNightCycle
		Type.UNLUCKY:
			display_name = "Unlucky"
			description = "Misfortune seems to follow this pawn."
			injury_chance_mult = 1.5
		Type.LUCKY:
			display_name = "Lucky"
			description = "Fortune smiles on this pawn."
			injury_chance_mult = 0.5
		Type.RECKLESS:
			display_name = "Reckless"
			description = "Bold to the point of foolishness."
			work_speed_mult = 1.3
			injury_chance_mult = 2.0
		Type.CAUTIOUS:
			display_name = "Cautious"
			description = "Takes no unnecessary risks."
			work_speed_mult = 0.8
			injury_chance_mult = 0.5

## Get a random trait from the pool.
static func random() -> Trait:
	var types: Array = Type.values()
	var random_type: Type = types[randi() % types.size()]
	return Trait.new(random_type)

## Get a trait by type.
static func get_trait(p_type: Type) -> Trait:
	return Trait.new(p_type)
