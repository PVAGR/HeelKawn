class_name PawnData
extends RefCounted

## Pure data for a single pawn. The Pawn Node2D reads from this; all future
## systems (save/load, AI, macro view) will treat PawnData as the source of
## truth and Pawn (the Node) as a visual representation.

enum Gender { MALE, FEMALE, OTHER }
enum BodyType { SLIM, AVERAGE, BROAD }
enum HairStyle { NONE, SHORT, MOHAWK, BUN }

## Trainable proficiencies. Higher level -> faster work + more XP per tick on
## that skill type. Pawns earn XP only while doing the matching job.
enum Skill { FORAGING, MINING, CHOPPING, BUILDING, HUNTING }

## Skill XP curve. Each skill tracked as raw XP; level = floor(xp / XP_PER_LEVEL).
const XP_PER_LEVEL: float = 100.0
## Soft cap. Skills can technically go higher but we display / multiply against
## this as the "mastery" mark.
const SKILL_LEVEL_MAX: int = 20
## Multiplier applied at level SKILL_LEVEL_MAX. Linear interpolation:
##   work_speed = 1.0 + (level / SKILL_LEVEL_MAX) * (SKILL_BONUS_AT_MAX - 1.0)
## At level 20 a skilled pawn works 2.0x as fast as a novice.
const SKILL_BONUS_AT_MAX: float = 2.0
## XP gained per tick of work on the matching skill. Tuned so a fresh pawn
## passes lvl 1 in ~one job cycle and reaches lvl 5 over a few in-game days.
const XP_PER_WORK_TICK: float = 1.5

## Global monotonic id. Reset when the game starts, serialized per save.
static var _next_id: int = 1

var id: int
var display_name: String = ""
var age: int = 25
var gender: int = Gender.OTHER
var tile_pos: Vector2i = Vector2i.ZERO

## Display color used by the v1 circle renderer. Will be replaced by a sprite
## once we have pawn art. Kept on the data so it survives save/load.
var color: Color = Color.WHITE
var body_type: int = BodyType.AVERAGE
var hair_style: int = HairStyle.SHORT
var hair_color: Color = Color("#5f4630")
var apparel_color: Color = Color("#5d7ea8")

## Needs (0..100, higher is better). Will decay on tick in Phase 2b.
var hunger: float = 100.0
var rest: float = 100.0
var mood: float = 100.0
var health: float = 100.0

## Single-item inventory. Type is Item.Type (NONE = empty hands).
## v1 pawns can only hold one kind of thing at a time; multi-slot / weight
## comes later with proper inventories.
var carrying: int = 0  # Item.Type.NONE
var carrying_qty: int = 0

## Skill XP per Skill enum value. Defaults to 0 for everything; pawns earn it
## by working. Stored as Dictionary so save/load is trivial and so we don't
## have to enumerate skills here.
var skill_xp: Dictionary = {}

## Work-type allow list (RimWorld-style). If false, this pawn will not *claim*
## that class of open job. Eating, sleeping, and hauling are not jobs; they
## are always available. Toggled from the PawnInfoPanel when a pawn is selected.
var work_forage: bool = true
var work_mine:   bool = true
var work_chop:   bool = true
var work_hunt:   bool = true
var work_build:  bool = true

## Traits: modifiers that affect need decay, skill XP, work speed, etc.
## Each pawn starts with 0-2 traits at spawn.
var traits: Array[Trait] = []

## Mood events: temporary emotional states that affect mood decay and behavior.
## Each event has a type, intensity, and duration.
var mood_events: Array[MoodEvent] = []


func _init() -> void:
	id = _next_id
	_next_id += 1


# ==================== traits ====================

## Add a trait to this pawn. Traits modify various multipliers.
func add_trait(trait: Trait) -> void:
	if trait != null and not traits.has(trait):
		traits.append(trait)


## Get cumulative multiplier for a specific stat across all traits.
## Example: get_trait_mult("hunger_decay_mult") -> 1.2 if traits add 20%.
func get_trait_mult(stat_name: String) -> float:
	var mult: float = 1.0
	for trait in traits:
		match stat_name:
			"hunger_decay_mult": mult *= trait.hunger_decay_mult
			"rest_decay_mult": mult *= trait.rest_decay_mult
			"mood_decay_mult": mult *= trait.mood_decay_mult
			"health_max_mult": mult *= trait.health_max_mult
			"skill_xp_mult": mult *= trait.skill_xp_mult
			"work_speed_mult": mult *= trait.work_speed_mult
			"injury_chance_mult": mult *= trait.injury_chance_mult
			"damage_taken_mult": mult *= trait.damage_taken_mult
	return mult


## Check if this pawn has a trait of the given type.
func has_trait(trait_type: int) -> bool:
	for trait in traits:
		if trait.trait_type == trait_type:
			return true
	return false


## Get trait display string for UI.
func traits_display() -> String:
	if traits.is_empty():
		return "No traits"
	var names: PackedStringArray = []
	for trait in traits:
		names.append(trait.display_name)
	return ", ".join(names)


# ==================== mood events ====================

## Add a mood event (e.g., joy, sorrow, stress) that affects mood temporarily.
func add_mood_event(event_type: int, intensity: float = 50.0, duration_ticks: int = 300) -> void:
	var event := MoodEvent.new(event_type, intensity, duration_ticks)
	mood_events.append(event)


## Get the total mood impact (delta per tick) from all active mood events.
func get_mood_event_impact() -> float:
	var total_impact: float = 0.0
	for event in mood_events:
		total_impact += event.mood_impact()
	return total_impact


## Process mood event decay. Returns true if there are any events left.
func process_mood_events() -> bool:
	var expired: Array[int] = []
	for i in range(mood_events.size()):
		if mood_events[i].decay_tick():
			expired.append(i)
	# Remove expired events in reverse order to avoid index issues
	for i in expired.size() - 1 downto 0:
		mood_events.remove_at(expired[i])
	return not mood_events.is_empty()


## Get current crisis level (0.0 = fine, 1.0 = collapse). Based on mood and recent events.
func get_crisis_level() -> float:
	var crisis: float = 0.0
	# Mood directly contributes: low mood = high crisis
	var mood_crisis: float = 1.0 - (clamp(mood, 0.0, 100.0) / 100.0)  # 0.0 at mood 100, 1.0 at mood 0
	crisis += mood_crisis * 0.5
	# Despair events spike crisis immediately
	for event in mood_events:
		if event.type == MoodEvent.Type.DESPAIR:
			crisis += event.intensity / 100.0 * 0.5
	return clamp(crisis, 0.0, 1.0)


## Get the most recent significant mood event for UI display.
func get_active_mood_event() -> MoodEvent:
	if mood_events.is_empty():
		return null
	# Return the event with highest intensity
	var best_event: MoodEvent = mood_events[0]
	for event in mood_events:
		if event.intensity > best_event.intensity:
			best_event = event
	return best_event


## Get description of current mood state for UI.
func mood_state_display() -> String:
	if mood < 25.0:
		return "CRITICAL DEPRESSION"
	elif mood < 45.0:
		return "Very unhappy"
	elif mood < 60.0:
		return "Unhappy"
	elif mood < 75.0:
		return "Content"
	elif mood < 90.0:
		return "Happy"
	else:
		return "ECSTATIC"


# ==================== skills ====================

func get_skill_xp(skill: int) -> float:
	return float(skill_xp.get(skill, 0.0))


func get_skill_level(skill: int) -> int:
	return int(get_skill_xp(skill) / XP_PER_LEVEL)


## Add XP to a skill. Returns true when the level changed (so callers can log
## a "Brenna's mining went up to 3!" message).
func add_skill_xp(skill: int, amount: float) -> bool:
	var before: int = get_skill_level(skill)
	var trait_mult: float = get_trait_mult("skill_xp_mult")
	skill_xp[skill] = get_skill_xp(skill) + amount * trait_mult
	return get_skill_level(skill) != before


## Speed multiplier to apply to per-tick work progress for `skill`. Linearly
## interpolates from 1.0 at level 0 to SKILL_BONUS_AT_MAX at SKILL_LEVEL_MAX,
## then plateaus.
func work_speed_for(skill: int) -> float:
	var lvl: int = mini(get_skill_level(skill), SKILL_LEVEL_MAX)
	if lvl <= 0:
		return 1.0
	var t: float = float(lvl) / float(SKILL_LEVEL_MAX)
	return 1.0 + t * (SKILL_BONUS_AT_MAX - 1.0)


## Multiplier applied to work ticks (low health and fatigue slow labour).
## Traits can also modify work speed.
func effective_labor_mult() -> float:
	var h: float = clamp(health * 0.01, 0.0, 1.0)
	var r: float = clamp(rest * 0.01, 0.0, 1.0)
	var base_mult: float = max(0.2, h * 0.55 + r * 0.45)
	var trait_mult: float = get_trait_mult("work_speed_mult")
	return base_mult * trait_mult


static func skill_name(skill: int) -> String:
	match skill:
		Skill.FORAGING: return "Foraging"
		Skill.MINING:   return "Mining"
		Skill.CHOPPING: return "Chopping"
		Skill.BUILDING: return "Building"
		Skill.HUNTING:  return "Hunting"
	return "?"


## Map a job type to the skill that benefits from it. Returns -1 for jobs
## that don't grant XP (e.g. hauling).
static func skill_for_job(job_type: int) -> int:
	match job_type:
		Job.Type.FORAGE:     return Skill.FORAGING
		Job.Type.MINE:       return Skill.MINING
		Job.Type.MINE_WALL:  return Skill.MINING
		Job.Type.CHOP:       return Skill.CHOPPING
		Job.Type.HUNT:       return Skill.HUNTING
		Job.Type.BUILD_BED:  return Skill.BUILDING
		Job.Type.BUILD_WALL: return Skill.BUILDING
		Job.Type.BUILD_DOOR: return Skill.BUILDING
	return -1


## False if this pawn is not allowed to take `job_type` from the job queue.
func allows_job_type(job_type: int) -> bool:
	match job_type:
		Job.Type.FORAGE:
			return work_forage
		Job.Type.MINE, Job.Type.MINE_WALL:
			return work_mine
		Job.Type.CHOP:
			return work_chop
		Job.Type.HUNT:
			return work_hunt
		Job.Type.BUILD_BED, Job.Type.BUILD_WALL, Job.Type.BUILD_DOOR:
			return work_build
	return true


func describe() -> String:
	return "#%d %s (age %d)" % [id, display_name, age]


## Serialize for `GameSave` (store_var). All numeric work flags included.
func to_save_dict() -> Dictionary:
	var sx: Dictionary = {}
	for k in skill_xp:
		sx[str(k)] = skill_xp[k]
	var trait_types: Array = []
	for trait in traits:
		trait_types.append(trait.trait_type)
	return {
		"id": id,
		"display_name": display_name,
		"age": age,
		"gender": gender,
		"tile_x": tile_pos.x,
		"tile_y": tile_pos.y,
		"color": [color.r, color.g, color.b, color.a],
		"body_type": body_type,
		"hair_style": hair_style,
		"hair_color": [hair_color.r, hair_color.g, hair_color.b, hair_color.a],
		"apparel_color": [apparel_color.r, apparel_color.g, apparel_color.b, apparel_color.a],
		"hunger": hunger,
		"rest": rest,
		"mood": mood,
		"health": health,
		"carrying": carrying,
		"carrying_qty": carrying_qty,
		"skill_xp": sx,
		"work_forage": work_forage,
		"work_mine": work_mine,
		"work_chop": work_chop,
		"work_hunt": work_hunt,
		"work_build": work_build,
		"trait_types": trait_types,
	}


## Rebuild from `to_save_dict`. Overrides the auto id from _init and bumps
## `_next_id` so future spawns don't collide.
static func from_save_dict(d: Dictionary) -> PawnData:
	var p := PawnData.new()
	p.id = int(d.get("id", p.id))
	p.display_name = str(d.get("display_name", p.display_name))
	p.age = int(d.get("age", p.age))
	p.gender = int(d.get("gender", p.gender))
	p.tile_pos = Vector2i(int(d.get("tile_x", 0)), int(d.get("tile_y", 0)))
	var c: Array = d.get("color", [1, 1, 1, 1])
	if c.size() >= 3:
		p.color = Color(float(c[0]), float(c[1]), float(c[2]), float(c[3]) if c.size() > 3 else 1.0)
	p.body_type = int(d.get("body_type", BodyType.AVERAGE))
	p.hair_style = int(d.get("hair_style", HairStyle.SHORT))
	var hc: Array = d.get("hair_color", [0.37, 0.27, 0.18, 1.0])
	if hc.size() >= 3:
		p.hair_color = Color(float(hc[0]), float(hc[1]), float(hc[2]), float(hc[3]) if hc.size() > 3 else 1.0)
	var ac: Array = d.get("apparel_color", [0.36, 0.49, 0.66, 1.0])
	if ac.size() >= 3:
		p.apparel_color = Color(float(ac[0]), float(ac[1]), float(ac[2]), float(ac[3]) if ac.size() > 3 else 1.0)
	p.hunger = float(d.get("hunger", 100.0))
	p.rest = float(d.get("rest", 100.0))
	p.mood = float(d.get("mood", 100.0))
	p.health = float(d.get("health", 100.0))
	p.carrying = int(d.get("carrying", 0))
	p.carrying_qty = int(d.get("carrying_qty", 0))
	p.skill_xp = {}
	if d.has("skill_xp") and d["skill_xp"] is Dictionary:
		for k in d["skill_xp"]:
			p.skill_xp[int(k)] = float(d["skill_xp"][k])
	p.work_forage = bool(d.get("work_forage", true))
	p.work_mine = bool(d.get("work_mine", true))
	p.work_chop = bool(d.get("work_chop", true))
	p.work_hunt = bool(d.get("work_hunt", true))
	p.work_build = bool(d.get("work_build", true))
	# Load traits
	if d.has("trait_types") and d["trait_types"] is Array:
		for trait_type in d["trait_types"]:
			p.traits.append(Trait.new(int(trait_type)))
	_next_id = maxi(_next_id, p.id + 1)
	return p


func is_carrying() -> bool:
	return carrying != 0 and carrying_qty > 0


func clear_carry() -> void:
	carrying = 0
	carrying_qty = 0
