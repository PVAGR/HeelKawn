extends Node

## Single entry point for lightweight Phase-2b simulation hooks: settlement
## need pressure, labor stance, and (later) district tie-ins. Ticks with the sim.

## Broad macro labour bias — affects which job *types* get a few extra priority
## points when the queue is being searched (not work toggles: those are per-pawn).
enum LaborStance {
	BALANCED,
	FOOD_FIRST,
	BUILD_FIRST,
	HAUL_FIRST,
}

## Emitted so HUD and future UIs can reflect demand without polling every item.
signal demand_snapshot(
		food: float, housing: float, materials: float, hauling: float)

var current_labor_stance: int = LaborStance.BALANCED

var _food_press: float = 0.0
var _housing_press: float = 0.0
var _mat_press: float = 0.0
var _haul_press: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	GameManager.game_tick.connect(_on_tick)
	# Autoloads run before Main exists; one frame later we can see World/pawns.
	call_deferred("_bootstrap_demands_after_scene")


func _bootstrap_demands_after_scene() -> void:
	_refresh_demands()
	demand_snapshot.emit(_food_press, _housing_press, _mat_press, _haul_press)


func _on_tick(tick: int) -> void:
	_refresh_demands()
	if tick % 30 == 0:
		demand_snapshot.emit(_food_press, _housing_press, _mat_press, _haul_press)


## Food pressure: 0 = plenty, 1 = acute shortage (simplified: inverse of food cap).
func _refresh_demands() -> void:
	var food_total: int = StockpileManager.total_food()
	_food_press = clamp(1.0 - float(food_total) / 30.0, 0.0, 1.0)
	_refresh_housing_pressure()
	var wood: int = StockpileManager.total_count_of(Item.Type.WOOD)
	var stone: int = StockpileManager.total_count_of(Item.Type.STONE)
	_mat_press = clamp(1.0 - float(mini(wood, 24) + mini(stone, 12)) / 40.0, 0.0, 1.0)
	# Haul: open jobs scale approximates how much the queue is backlogged.
	var open_harvest: int = JobManager.open_count()
	_haul_press = clamp(float(open_harvest) / 120.0, 0.0, 1.0)


## 0 = enough beds (or no pawns); 1 = many pawns share few beds. Uses `World` bed
## list vs pawns in group `pawns` (rough macro signal, not per-night scheduling).
func _refresh_housing_pressure() -> void:
	var tr: SceneTree = get_tree()
	if tr == null:
		_housing_press = 0.0
		return
	var pawns: int = tr.get_nodes_in_group("pawns").size()
	if pawns <= 0:
		_housing_press = 0.0
		return
	var beds: int = 0
	for n in tr.get_nodes_in_group("colony_world"):
		if n is World:
			beds = (n as World).bed_count()
			break
	if beds >= pawns:
		_housing_press = 0.0
	else:
		_housing_press = clamp(float(pawns - beds) / float(pawns), 0.0, 1.0)


func get_stance_display() -> String:
	return _stance_name(current_labor_stance)


func get_food_pressure() -> float:
	return _food_press


func get_housing_pressure() -> float:
	return _housing_press


func cycle_labor_stance() -> void:
	current_labor_stance = (current_labor_stance + 1) % 4
	print("[Colony] Labor stance: %s" % _stance_name(current_labor_stance))
	_refresh_demands()
	demand_snapshot.emit(_food_press, _housing_press, _mat_press, _haul_press)


func _stance_name(s: int) -> String:
	match s:
		LaborStance.BALANCED:   return "balanced"
		LaborStance.FOOD_FIRST:  return "food first"
		LaborStance.BUILD_FIRST: return "build first"
		LaborStance.HAUL_FIRST:  return "haul first"
	return "?"


## For `JobManager.claim_next_for` third argument. Small nudges only — the core
## queue priority still wins in large gaps.
func job_priority_stance_bias(job: Job) -> int:
	if job == null:
		return 0
	match current_labor_stance:
		LaborStance.BALANCED:
			return 0
		LaborStance.FOOD_FIRST:
			if job.type == Job.Type.FORAGE or job.type == Job.Type.HUNT:
				return 3
			return 0
		LaborStance.BUILD_FIRST:
			if job.type == Job.Type.BUILD_BED or job.type == Job.Type.BUILD_WALL \
					or job.type == Job.Type.BUILD_DOOR or job.type == Job.Type.MINE_WALL:
				return 3
			return 0
		LaborStance.HAUL_FIRST:
			# Pawns that already carry re-route in `_tick_idle`; this biases fetch jobs.
			match job.type:
				Job.Type.FORAGE, Job.Type.MINE, Job.Type.CHOP, Job.Type.MINE_WALL, \
				Job.Type.HUNT:
					return 2
			return 0
	return 0


## Need urgency (0..1) for scoring autonomous choices.
static func need_urgency_hunger(hunger: float) -> float:
	return clamp(1.0 - hunger / 100.0, 0.0, 1.0)


static func need_urgency_rest(rest: float) -> float:
	return clamp(1.0 - rest / 100.0, 0.0, 1.0)
