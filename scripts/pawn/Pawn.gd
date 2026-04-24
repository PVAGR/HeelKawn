class_name Pawn
extends Node2D

## A pawn: data container, tick-driven needs, AI state machine, and
## waypoint-following movement. Ticks happen on GameManager.game_tick;
## movement interpolates in _process for smoothness.
##
## State machine (v1):
##
##   IDLE --(hungry + food available)--> GOING_TO_EAT --arrive--> EATING --done--> IDLE
##   IDLE --(job claimed)--> WALKING_TO_JOB --arrive--> WORKING --done--> HAULING
##        --arrive stockpile--> IDLE  (item deposited)
##   IDLE --(nothing else)--> (wander step) --> IDLE

# -------------------- visual tuning --------------------

## Radius of the pawn circle in world units. Kept <= TILE_PIXELS (8) so a
## pawn doesn't visually spill into neighboring tiles as it walks.
const DRAW_RADIUS: float = 3.5
const OUTLINE_WIDTH: float = 1.0
const OUTLINE_WIDTH_BUSY: float = 1.75

## Offset and size of the "carrying" swatch drawn above the pawn's head.
const CARRY_OFFSET: Vector2 = Vector2(0.0, -6.0)
const CARRY_SIZE: Vector2 = Vector2(3.5, 3.5)

# -------------------- need decay tuning --------------------

# Survival drain rates. Tuned so a 5-pawn colony with realistic forage travel
# distances (often ~30-70 tiles to a fertile soil patch) can run a sustained
# food/rest surplus instead of slowly starving. If the colony grows or food
# moves further away these will need re-tuning.
const HUNGER_DECAY_PER_TICK: float = 0.06
const REST_DECAY_PER_TICK:   float = 0.05
const MOOD_DECAY_PER_TICK:   float = 0.03
const THRESHOLD_WARN: float = 50.0
const THRESHOLD_CRIT: float = 25.0

# -------------------- mood recovery --------------------

## Mood gained per tick when both hunger and rest are above MOOD_CONTENT_FLOOR
## ("nothing's wrong, life is fine"). Tuned to outpace the 0.03 decay so a
## pawn whose needs are met slowly trends back toward 100.
const MOOD_GAIN_PER_TICK_CONTENT: float = 0.08
const MOOD_CONTENT_FLOOR: float = 60.0
## One-shot mood gain when finishing a meal (eating from stockpile or hand).
const MOOD_BONUS_ATE: float = 4.0
## One-shot mood gain when waking up fully rested.
const MOOD_BONUS_WOKE_REFRESHED: float = 8.0

## Pawns go eat when hunger drops below this (and a stockpile has food).
const HUNGER_EAT_THRESHOLD: float = 50.0
## Below this, a pawn will eat food directly from its own hands rather than
## insist on hauling it to the stockpile first. Saves starving pawns who got
## stranded mid-haul (unreachable stockpile, no path, etc).
const HUNGER_EMERGENCY: float = 20.0
## Ticks spent "eating" once at the stockpile. 5 ticks = ~0.5s at 1x speed.
const EAT_TICKS: int = 5

# -------------------- sleep tuning --------------------

## Below this, an idle pawn will lie down to sleep wherever they stand
## (preferring a bed if one is reachable). At night the threshold is much
## higher so pawns settle into a natural diurnal schedule instead of working
## around the clock until exhausted.
const REST_SLEEP_THRESHOLD: float = 35.0
const REST_SLEEP_THRESHOLD_NIGHT: float = 75.0
## Below this, the pawn is so exhausted they abandon whatever they were doing
## (job, eating, hauling) and collapse. Without this, busy pawns happily ride
## rest down to 0 because they never reach the IDLE priority chain.
const REST_PANIC_THRESHOLD: float = 12.0

# -------------------- food-supply tuning --------------------

## When the stockpile food count drops below this, idle pawns will preferentially
## claim FORAGE jobs even if other harvest types are closer. Without this safety
## net the colony can starve while pawns happily mine stone (which is exactly
## what a previous tuning pass caused). Tuned to ~2 berries per pawn -- roughly
## one in-flight emergency snack each.
const STOCKPILE_FOOD_LOW_THRESHOLD: int = 10
## Sleep ends and the pawn wakes once rest climbs above this.
const REST_WAKE_THRESHOLD: float = 90.0
## Rest restored per tick while in SLEEPING state. ~7x the normal decay rate
## so a full sleep takes ~120 ticks (12 in-game hours) to go from crit to wake.
const REST_RECOVER_PER_TICK_SLEEP: float = 0.6
## Multiplier applied to REST_RECOVER_PER_TICK_SLEEP when the sleeping pawn is
## standing on a bed they own. Beds make sleep ~67% faster.
const REST_RECOVER_BED_MULTIPLIER: float = 1.67
## Hunger keeps decaying while asleep, but at half rate (rest body burns less).
const HUNGER_DECAY_PER_TICK_SLEEPING: float = 0.05

# -------------------- build tuning --------------------

## How much wood each buildable consumes. Carried in the pawn's hands during
## the walk from stockpile to build site.
const BED_WOOD_COST: int = 1
const WALL_WOOD_COST: int = 2
const DOOR_WOOD_COST: int = 1


## Map of build-job type -> (item_type, qty) needed at the build site. Anything
## listed here triggers the FETCHING_MATERIAL bounce in _begin_job.
static func _materials_for_build(job_type: int) -> Dictionary:
	match job_type:
		Job.Type.BUILD_BED:  return {"item": Item.Type.WOOD, "qty": BED_WOOD_COST}
		Job.Type.BUILD_WALL: return {"item": Item.Type.WOOD, "qty": WALL_WOOD_COST}
		Job.Type.BUILD_DOOR: return {"item": Item.Type.WOOD, "qty": DOOR_WOOD_COST}
	return {}

# -------------------- movement tuning --------------------

# 1 tile = 8 world units, so 24 = 3 tiles/sec at 1x = 18 tiles/sec at 6x.
# Snappier movement makes long forage runs viable without sucking the
# colony's whole tick budget into walk-time.
const WALK_SPEED_WORLD_UNITS_PER_SEC: float = 24.0
## Chance per tick to start a random wander when idle and nothing to do.
const WANDER_CHANCE_PER_TICK: float = 0.08

## Print "retrying haul (no path)" at most once every N ticks per pawn. Keeps
## the log readable while still making stuck hauls obvious.
const HAUL_FAIL_LOG_EVERY_N_TICKS: int = 300

# -------------------- AI state --------------------

enum State {
	IDLE,
	WALKING_TO_JOB,
	WORKING,
	HAULING,            # carrying a produced item toward the stockpile
	GOING_TO_EAT,       # hungry, walking toward stockpile
	EATING,             # at stockpile, consuming a food item
	SLEEPING,           # restoring rest in place; wakes on full rest or starvation
	FETCHING_MATERIAL,  # build job claimed; walking to stockpile to grab inputs
	GOING_TO_BED,       # tired, walking toward a reserved bed
	## Player-ordered move (Kenshi / RimWorld "draft" step); not a work job.
	DRAFT_WALK,
}

# -------------------- runtime --------------------

var data: PawnData

var _world: World
var _state: int = State.IDLE
var _current_job: Job = null
## Set by Main when the player clicks this pawn. Drives the selection ring
## in _draw and unlocks the side info panel.
var is_selected: bool = false

## Active path: list of tiles AFTER the current tile that must be visited in
## order. Empty means stationary.
var _path: Array[Vector2i] = []
var _path_index: int = 0
var _target_tile: Vector2i = Vector2i.ZERO
var _target_world_pos: Vector2 = Vector2.ZERO

## Ticks remaining in the EATING state.
var _eat_ticks_left: int = 0

## Bed currently reserved by this pawn (Vector2i(-1,-1) = none). Set when we
## start walking to a bed, cleared on wake or panic-abort. World holds the
## authoritative occupancy map; this is just a back-pointer so we know which
## bed to release.
var _reserved_bed: Vector2i = Vector2i(-1, -1)

## The specific zone we're pathing to for the current eat/haul/fetch. Phase
## 10 made stockpiles multi-zone, so "walk to the stockpile" is no longer a
## constant -- we pick a target when we start walking and remember it so the
## arrival handler deposits into / takes from the *same* zone we planned for,
## even if a closer zone got designated mid-walk.
var _target_zone: Stockpile = null

## Last severity level reported per need, to avoid log spam.
var _hunger_level: int = 0
## Failsafe log once: pawn standing on a tile A* now marks as solid.
var _reported_stuck: bool = false
var _rest_level: int = 0
var _mood_level: int = 0

## Game tick at which we last logged a haul failure for this pawn, so the
## retry loop doesn't flood the console.
var _last_haul_fail_log_tick: int = -HAUL_FAIL_LOG_EVERY_N_TICKS


func _ready() -> void:
	GameManager.game_tick.connect(_on_game_tick)


## Called by PawnSpawner immediately after instantiation.
func bind(p_data: PawnData, world_pos: Vector2, world: World) -> void:
	data = p_data
	_world = world
	position = world_pos
	_state = State.IDLE
	_clear_path()
	_reserved_bed = Vector2i(-1, -1)
	add_to_group("pawns")
	queue_redraw()


## Player-ordered direct move. Cancels a claimed work job, drops bed/zone
## holds, and paths to a passable tile (Kenshi / RimWorld "draft" feel).
func draft_goto(world_tile: Vector2i) -> void:
	if _world == null or _world.data == null:
		return
	if not _world.data.in_bounds(world_tile.x, world_tile.y):
		return
	if not _world.pathfinder.is_passable(world_tile):
		return
	release_job_if_any()
	_release_bed_if_reserved()
	_target_zone = null
	_clear_path()
	_state = State.DRAFT_WALK
	if data.tile_pos == world_tile:
		_state = State.IDLE
		queue_redraw()
		return
	var path: Array[Vector2i] = _world.pathfinder.find_path(data.tile_pos, world_tile)
	if path.is_empty():
		_state = State.IDLE
		queue_redraw()
		return
	_start_path(path)
	queue_redraw()


## Called from World when a wall appears under this pawn — step off solid tiles.
func nudge_if_standing_on_solid() -> void:
	if _world == null or _world.pathfinder == null or data == null:
		return
	if _world.pathfinder.is_passable(data.tile_pos):
		return
	var dest: Vector2i = _world.pathfinder.find_adjacent_passable(data.tile_pos)
	if dest.x < 0:
		return
	_clear_path()
	# Stuck pawns are never supposed to be mid-job on the tile that became
	# a wall, but if pathing desyncs, free the job so the AI can recover.
	if _current_job != null:
		JobManager.abandon(_current_job)
		_current_job = null
	_state = State.IDLE
	data.tile_pos = dest
	position = _world.tile_to_world(dest)
	_target_tile = dest
	_target_world_pos = position
	queue_redraw()


## Evict a pawn standing *on* `stand_tile` to any adjacent walkable cell (used
## before a wall build finalizes, while the cell may still be passable in data).
func evict_to_neighbor_of_tile(stand_tile: Vector2i) -> void:
	if _world == null or _world.pathfinder == null or data == null:
		return
	if _state == State.SLEEPING or _state == State.EATING:
		return
	if data.tile_pos != stand_tile:
		return
	var dest: Vector2i = _world.pathfinder.find_adjacent_passable(stand_tile)
	if dest.x < 0:
		return
	_clear_path()
	# If we're standing on a build site, drop work so the site can be committed.
	if _current_job != null:
		JobManager.abandon(_current_job)
		_current_job = null
	_state = State.IDLE
	_target_zone = null
	data.tile_pos = dest
	position = _world.tile_to_world(dest)
	_target_tile = dest
	_target_world_pos = position
	queue_redraw()


## World/navigation: tiles changed (walls, doors, mining). Re-nudge, then
## re-seek paths for movement states.
func on_world_nav_changed() -> void:
	if _world == null or _world.pathfinder == null or data == null:
		return
	if not _world.pathfinder.is_passable(data.tile_pos):
		nudge_if_standing_on_solid()
		return
	match _state:
		State.WALKING_TO_JOB:
			if _current_job != null:
				_walk_to_work_tile(_current_job)
		State.FETCHING_MATERIAL:
			if _current_job != null:
				var mm: Dictionary = _materials_for_build(_current_job.type)
				if not mm.is_empty():
					_begin_fetching_material(mm.item, mm.qty)
		State.HAULING:
			if data.is_carrying():
				_begin_haul_to_stockpile()
		State.GOING_TO_EAT:
			if _target_zone != null and is_instance_valid(_target_zone):
				_begin_going_to_eat(_target_zone)
		State.GOING_TO_BED:
			if _reserved_bed.x < 0:
				pass
			elif data.tile_pos == _reserved_bed:
				pass
			else:
				var pbed: Array[Vector2i] = _world.pathfinder.find_path(
					data.tile_pos, _reserved_bed)
				if pbed.is_empty():
					_world.release_bed(_reserved_bed, self)
					_reserved_bed = Vector2i(-1, -1)
					_state = State.IDLE
					_clear_path()
				else:
					_state = State.GOING_TO_BED
					_start_path(pbed)
		State.DRAFT_WALK:
			_state = State.IDLE
			_clear_path()
		_:
			pass


## Failsafe: if the sim tile is not passable, nudge. Logs once with context.
func sanity_check_impassable_tile() -> void:
	if _world == null or _world.pathfinder == null or data == null:
		return
	if _world.pathfinder.is_passable(data.tile_pos):
		return
	if not _reported_stuck:
		_reported_stuck = true
		print("[Pawn] WARN: %s on impassable sim tile (%d,%d)  state=%d — forcing nudge" % [
			data.display_name, data.tile_pos.x, data.tile_pos.y, int(_state),
		])
	nudge_if_standing_on_solid()


# ==================== per-frame movement ====================

func _process(delta: float) -> void:
	if data == null or GameManager.is_paused:
		return
	if _path.is_empty():
		return
	var step: float = WALK_SPEED_WORLD_UNITS_PER_SEC * delta * GameManager.game_speed
	var to_target: Vector2 = _target_world_pos - position
	if to_target.length() <= step:
		position = _target_world_pos
		data.tile_pos = _target_tile
		_advance_path()
	else:
		position += to_target.normalized() * step


func _start_path(path: Array[Vector2i]) -> void:
	_path = path
	_path_index = 0
	if _path.is_empty():
		_clear_path()
		_on_path_complete()
		return
	_target_tile = _path[0]
	_target_world_pos = _world.tile_to_world(_target_tile)


func _advance_path() -> void:
	_path_index += 1
	if _path_index < _path.size():
		_target_tile = _path[_path_index]
		_target_world_pos = _world.tile_to_world(_target_tile)
	else:
		_clear_path()
		_on_path_complete()


func _clear_path() -> void:
	_path = []
	_path_index = 0
	_target_tile = data.tile_pos if data != null else Vector2i.ZERO
	_target_world_pos = position


func _on_path_complete() -> void:
	match _state:
		State.DRAFT_WALK:
			_state = State.IDLE
			queue_redraw()
		State.WALKING_TO_JOB:
			if _current_job != null and data.tile_pos == _current_job.work_tile:
				_state = State.WORKING
				queue_redraw()
			else:
				_unclaim_current_job()
		State.HAULING:
			_deposit_at_stockpile()
		State.GOING_TO_EAT:
			_begin_eating()
		State.FETCHING_MATERIAL:
			_arrive_at_stockpile_for_material()
		State.GOING_TO_BED:
			_arrive_at_bed()
		State.IDLE:
			pass


# ==================== per-tick simulation ====================

func _on_game_tick(_tick: int) -> void:
	if data == null:
		return
	_decay_needs()
	_check_thresholds()
	# Panic-sleep interrupt: if rest is critically low and we're not already
	# resolving a true emergency (asleep, eating, or fed/in-hand), abandon
	# what we're doing and collapse. Beats the eat/haul cycle that otherwise
	# keeps a pawn busy until rest hits 0.
	if _should_panic_sleep():
		_force_panic_sleep()
		return
	match _state:
		State.IDLE:
			_tick_idle()
		State.WALKING_TO_JOB:
			_tick_walking()
		State.WORKING:
			_tick_working()
		State.HAULING, State.GOING_TO_EAT, State.FETCHING_MATERIAL, State.GOING_TO_BED, State.DRAFT_WALK:
			# movement handled in _process; state exits on arrival
			pass
		State.EATING:
			_tick_eating()
		State.SLEEPING:
			_tick_sleeping()


func _should_panic_sleep() -> bool:
	if _state == State.SLEEPING:
		return false
	if data.rest > REST_PANIC_THRESHOLD:
		return false
	# Hunger emergency outranks sleep. Better to stagger toward food than nap
	# and wake up dead.
	if data.hunger <= HUNGER_EMERGENCY:
		return false
	# Don't yank a pawn out of an active eating action -- it's only a few ticks
	# and ends naturally; rest can wait that long.
	if _state == State.EATING:
		return false
	return true


## Force the current activity to abort, drop any claimed job back into the
## queue, and lie down. Anything the pawn was carrying stays in their hands;
## they'll deliver it when they wake up.
func _force_panic_sleep() -> void:
	if _state == State.DRAFT_WALK:
		_state = State.IDLE
	if _current_job != null:
		JobManager.abandon(_current_job)
		_current_job = null
	_clear_path()
	# If we were already walking to a bed when panic hit, give up the
	# reservation so other pawns can use it; we're sleeping where we stand.
	_release_bed_if_reserved()
	print("[Pawn] %s collapses from exhaustion  (rest=%.1f hunger=%.1f)" %
		[data.display_name, data.rest, data.hunger])
	_begin_sleeping()


func _tick_idle() -> void:
	if _world == null or _world.pathfinder == null:
		return
	# Priority chain (most urgent first):
	#   1. Starving + holding food          -> eat from hand
	#   2. Holding a non-food item          -> haul to stockpile
	#   3. Hungry + food in stockpile       -> go eat
	#   4. Tired (no food emergency)        -> sleep on the spot
	#   5. Open job available               -> claim and walk to it
	#   6. Nothing                          -> small chance to wander

	# 1. Emergency: starving + holding food = eat it right now, no stockpile.
	if data.hunger <= HUNGER_EMERGENCY and data.is_carrying() and Item.is_food(data.carrying):
		_eat_from_hand()
		return
	# 2. If we're still holding something from a prior task, deliver it first.
	if data.is_carrying():
		_begin_haul_to_stockpile()
		return
	# 3. Need-driven: hungry + food nearby -> go eat
	if _maybe_start_eating():
		return
	# 4. Tired -> sleep. Skipped if we're starving (food first, sleep when full).
	if _maybe_start_sleeping():
		return
	# 5. Job queue: take the best reachable job. We additionally skip build
	# jobs whose required materials aren't on hand at the stockpile -- this
	# prevents pawns from claim/abort looping when wood is empty.
	#
	# Food-emergency override: if the stockpile is almost out of food, do
	# *one* preferential pass restricted to FORAGE jobs, then fall back to the
	# normal filter if no forage is available. Stops the colony from happily
	# mining stone while everyone starves.
	var my_component: int = _world.pathfinder.component_of(data.tile_pos)
	# Treat the whole pantry (berries + meat + any future food) as one number
	# summed across every registered zone. Counting only berries was fine
	# before HUNT existed; now a colony living on hunted meat would have
	# looked like it was starving. And with Phase-10 multi-zone stockpiles
	# we have to sum across zones, not peek at one hardcoded pile.
	var food_emergency: bool = StockpileManager.total_food() < STOCKPILE_FOOD_LOW_THRESHOLD
	var stance_cb: Callable = func(j: Job) -> int:
		return ColonySimServices.job_priority_stance_bias(j)
	var base_passes: Callable = func(j: Job) -> bool:
		if not data.allows_job_type(j.type):
			return false
		if _world.pathfinder.component_of(j.work_tile) != my_component:
			return false
		var mats: Dictionary = _materials_for_build(j.type)
		if not mats.is_empty():
			# Any zone with the material is fine -- the pawn will walk to
			# the closest one in _begin_fetching_material.
			if StockpileManager.total_count_of(mats.item) < mats.qty:
				return false
		return true
	if food_emergency:
		# Either harvest type fills the pantry; let pawns pick whichever is
		# nearest by deferring to JobManager's distance tiebreak. `base_passes`
		# already enforces per-pawn work toggles (work_forage / work_hunt).
		var food_only: Callable = func(j: Job) -> bool:
			if j.type != Job.Type.FORAGE and j.type != Job.Type.HUNT:
				return false
			return base_passes.call(j)
		var food_job: Job = JobManager.claim_next_for(self, food_only, stance_cb)
		if food_job != null:
			_begin_job(food_job)
			return
	var job: Job = JobManager.claim_next_for(self, base_passes, stance_cb)
	if job != null:
		_begin_job(job)
		return
	# 6. Nothing to do: idle wander
	if randf() < WANDER_CHANCE_PER_TICK:
		_start_wander()


func _tick_walking() -> void:
	if _state == State.DRAFT_WALK:
		return
	if _current_job == null:
		_state = State.IDLE
		_clear_path()
		return
	if not _is_job_tile_still_valid(_current_job):
		_cancel_current_job()


func _tick_working() -> void:
	if _current_job == null:
		_state = State.IDLE
		return
	# Starving: let go of non-harvest work so the next tick can path to food.
	if data.hunger <= HUNGER_EMERGENCY and _current_job != null:
		if _current_job.type != Job.Type.FORAGE and _current_job.type != Job.Type.HUNT:
			_unclaim_current_job()
			return
	if not _is_job_tile_still_valid(_current_job):
		_cancel_current_job()
		return
	# Skill-modulated work rate: progress per tick = work_speed_for(skill).
	# Always at least 1 progress per tick (a fresh pawn isn't slower than the
	# old constant-rate baseline). XP accrues only while actually working.
	var skill: int = PawnData.skill_for_job(_current_job.type)
	var speed: float = data.effective_labor_mult()
	if skill >= 0:
		speed *= data.work_speed_for(skill)
		var leveled_up: bool = data.add_skill_xp(skill, PawnData.XP_PER_WORK_TICK)
		if leveled_up:
			print("[Pawn] %s's %s went up to %d" % [
				data.display_name,
				PawnData.skill_name(skill),
				data.get_skill_level(skill),
			])
	_current_job.work_ticks_done += int(ceil(speed))
	if _current_job.work_ticks_done >= _current_job.work_ticks_needed:
		_complete_current_job()


func _tick_eating() -> void:
	_eat_ticks_left -= 1
	if _eat_ticks_left <= 0:
		_finish_eating()


# ==================== jobs (FORAGE / MINE) ====================

func _begin_job(job: Job) -> void:
	_current_job = job
	# Build jobs need raw materials in hand before we walk to the build site.
	# If we don't already have the right item in sufficient quantity, bounce
	# to the stockpile first.
	var mats: Dictionary = _materials_for_build(job.type)
	if not mats.is_empty():
		var item_type: int = mats.item
		var need_qty: int = mats.qty
		var have: int = data.carrying_qty if data.carrying == item_type else 0
		if have < need_qty:
			_begin_fetching_material(item_type, need_qty)
			return
	_walk_to_work_tile(job)


## Path the pawn to its current job's work_tile, transitioning to WORKING on
## arrival. Used by both the initial _begin_job and the post-fetch handoff.
func _walk_to_work_tile(job: Job) -> void:
	if data.tile_pos == job.work_tile:
		_clear_path()
		_state = State.WORKING
		queue_redraw()
		return
	var path: Array[Vector2i] = _world.pathfinder.find_path(data.tile_pos, job.work_tile)
	if path.is_empty():
		_unclaim_current_job()
		return
	_state = State.WALKING_TO_JOB
	_start_path(path)
	queue_redraw()


# ==================== material fetch (build jobs) ====================

## Walk to the nearest stockpile zone that has the requested materials and
## pick up `qty` of `item_type` for the active job. Aborts the job (with a
## one-line log) if no reachable zone has enough.
func _begin_fetching_material(item_type: int, qty: int) -> void:
	var sp: Stockpile = StockpileManager.find_source_for(
		item_type, qty, data.tile_pos, _world.pathfinder
	)
	if sp == null:
		print("[Pawn] %s aborts build job: no reachable zone has %d %s" %
			[data.display_name, qty, Item.name_for(item_type)])
		_unclaim_current_job()
		return
	_target_zone = sp
	var target_tile: Vector2i = sp.nearest_tile_to(data.tile_pos)
	if data.tile_pos == target_tile:
		_pickup_material(item_type, qty)
		return
	var path: Array[Vector2i] = _world.pathfinder.find_path(data.tile_pos, target_tile)
	if path.is_empty():
		_unclaim_current_job()
		return
	_state = State.FETCHING_MATERIAL
	_start_path(path)
	queue_redraw()


## Called when the FETCHING_MATERIAL walk completes. Take the materials out
## of the stockpile (per the build job's recipe), then walk back to the
## build site. If someone else cleared the stockpile out from under us,
## abort the job.
func _arrive_at_stockpile_for_material() -> void:
	if _current_job == null:
		_reset_to_idle()
		return
	var mats: Dictionary = _materials_for_build(_current_job.type)
	if mats.is_empty():
		_reset_to_idle()
		return
	var item_type: int = mats.item
	var need_qty: int = mats.qty
	var have: int = data.carrying_qty if data.carrying == item_type else 0
	var to_take: int = max(0, need_qty - have)
	_pickup_material(item_type, to_take)


func _pickup_material(item_type: int, qty: int) -> void:
	# qty <= 0 means we already have enough on hand; just walk to the build
	# site without bothering the stockpile.
	if qty <= 0:
		if _current_job != null:
			_walk_to_work_tile(_current_job)
		else:
			_reset_to_idle()
		return
	# Prefer the zone we planned for when we started walking. If it's gone
	# (wiped by reroll, e.g.) or ran dry, fall back to nearest zone with the
	# material -- saves the trip if there's still wood elsewhere.
	var sp: Stockpile = _target_zone
	if sp == null or not is_instance_valid(sp) or sp.count_of(item_type) < qty:
		sp = StockpileManager.find_source_for(item_type, qty, data.tile_pos, _world.pathfinder)
	if sp == null:
		_target_zone = null
		_unclaim_current_job()
		return
	var taken: int = sp.take_item(item_type, qty)
	if taken < qty:
		# Partial take: put it back so we don't strand items in our hand.
		if taken > 0:
			sp.add_item(item_type, taken)
		print("[Pawn] %s aborts build job: zone ran out of %s mid-fetch" %
			[data.display_name, Item.name_for(item_type)])
		_target_zone = null
		_unclaim_current_job()
		return
	# Stack onto existing carry of the same type, otherwise replace.
	if data.carrying == item_type:
		data.carrying_qty += taken
	else:
		data.carrying = item_type
		data.carrying_qty = taken
	_target_zone = null
	queue_redraw()
	if _current_job != null:
		_walk_to_work_tile(_current_job)
	else:
		_reset_to_idle()


func _is_job_tile_still_valid(job: Job) -> bool:
	if _world == null or _world.data == null:
		return false
	if not _world.data.in_bounds(job.tile.x, job.tile.y):
		return false
	match job.type:
		Job.Type.FORAGE:
			return _world.data.get_feature(job.tile.x, job.tile.y) == TileFeature.Type.FERTILE_SOIL
		Job.Type.MINE:
			return _world.data.get_feature(job.tile.x, job.tile.y) == TileFeature.Type.ORE_VEIN
		Job.Type.MINE_WALL:
			return _world.data.get_biome(job.tile.x, job.tile.y) == Biome.Type.MOUNTAIN
		Job.Type.CHOP:
			return _world.data.get_feature(job.tile.x, job.tile.y) == TileFeature.Type.TREE
		Job.Type.HUNT:
			# Animals are tile features; the hunt's still valid as long as the
			# critter hasn't already been killed (cleared) by someone else.
			return TileFeature.is_wildlife(_world.data.get_feature(job.tile.x, job.tile.y))
		Job.Type.BUILD_BED, Job.Type.BUILD_WALL:
			# Build sites are still valid if the tile is empty (no feature) and
			# the underlying biome is passable. We DON'T check pathfinder
			# passability for walls -- the wall tile itself is always passable
			# until the moment the wall snaps in (work_tile is adjacent).
			var f1: int = _world.data.get_feature(job.tile.x, job.tile.y)
			if f1 != TileFeature.Type.NONE:
				return false
			return Biome.is_passable(_world.data.get_biome(job.tile.x, job.tile.y))
		Job.Type.BUILD_DOOR:
			# Fresh door: empty tile. Replace-door: still a WALL (worker stands
			# on a neighbor; job completes into build_door swap).
			var f2: int = _world.data.get_feature(job.tile.x, job.tile.y)
			if f2 == TileFeature.Type.WALL or f2 == TileFeature.Type.NONE:
				return Biome.is_passable(_world.data.get_biome(job.tile.x, job.tile.y))
			return false
	return false


## Work finished successfully. Produce the item into the pawn's hands and
## transition to HAULING (walk it to the stockpile).
func _complete_current_job() -> void:
	var job: Job = _current_job
	var produced_type: int = Item.Type.NONE
	# Most harvests yield 1; only HUNT (deer) yields more, but plumbing it as a
	# variable keeps room for future high-yield jobs without re-plumbing again.
	var produced_qty: int = 1
	match job.type:
		Job.Type.FORAGE:
			produced_type = Item.Type.BERRY
			_world.clear_feature(job.tile.x, job.tile.y)
			print("[Pawn] %s foraged berries @(%d,%d)" % [data.display_name, job.tile.x, job.tile.y])
		Job.Type.MINE:
			produced_type = Item.Type.STONE
			_world.clear_feature(job.tile.x, job.tile.y)
			print("[Pawn] %s mined stone @(%d,%d)" % [data.display_name, job.tile.x, job.tile.y])
		Job.Type.MINE_WALL:
			produced_type = Item.Type.STONE
			# This converts MOUNTAIN -> STONE_FLOOR and rebuilds the components
			# map, which can cascade-unlock sealed ore veins.
			_world.mine_out_wall(job.tile.x, job.tile.y)
			print("[Pawn] %s mined wall @(%d,%d) -> stone floor" % [data.display_name, job.tile.x, job.tile.y])
		Job.Type.CHOP:
			produced_type = Item.Type.WOOD
			_world.clear_feature(job.tile.x, job.tile.y)
			print("[Pawn] %s chopped tree @(%d,%d)" % [data.display_name, job.tile.x, job.tile.y])
		Job.Type.HUNT:
			produced_type = Item.Type.MEAT
			# Read the species off the tile BEFORE we clear it, so we know
			# whether to grant 1 (rabbit) or 2 (deer) meat.
			var animal_feat: int = _world.data.get_feature(job.tile.x, job.tile.y)
			produced_qty = 2 if animal_feat == TileFeature.Type.DEER else 1
			_world.clear_feature(job.tile.x, job.tile.y)
			print("[Pawn] %s hunted %s @(%d,%d) -> %d meat" % [
				data.display_name, TileFeature.name_for(animal_feat),
				job.tile.x, job.tile.y, produced_qty])
		Job.Type.BUILD_BED, Job.Type.BUILD_WALL, Job.Type.BUILD_DOOR:
			_finish_build(job)
	JobManager.complete(job)
	_current_job = null
	_state = State.IDLE   # reset before transitioning; _begin_haul will set it
	_clear_path()
	queue_redraw()
	# Harvest jobs put a fresh item in the pawn's hands -- haul it to the stockpile.
	# Build jobs don't produce anything haulable.
	if produced_type != Item.Type.NONE:
		data.carrying = produced_type
		data.carrying_qty = produced_qty
		_begin_haul_to_stockpile()


## Place the right TileFeature for a build job, consuming the carried materials.
## Bails out cleanly if we somehow arrived without the wood in hand.
func _finish_build(job: Job) -> void:
	var mats: Dictionary = _materials_for_build(job.type)
	if mats.is_empty():
		return
	var item_type: int = mats.item
	var need_qty: int = mats.qty
	if data.carrying != item_type or data.carrying_qty < need_qty:
		print("[Pawn] %s missing material at completion -- %s not built @(%d,%d)" %
			[data.display_name, Job.describe_type(job.type), job.tile.x, job.tile.y])
		return
	data.carrying_qty -= need_qty
	if data.carrying_qty <= 0:
		data.clear_carry()
	match job.type:
		Job.Type.BUILD_BED:
			_world.set_feature(job.tile.x, job.tile.y, TileFeature.Type.BED)
			_world.register_bed(job.tile)
			print("[Pawn] %s built a bed @(%d,%d)" % [data.display_name, job.tile.x, job.tile.y])
		Job.Type.BUILD_WALL:
			_world.build_wall(job.tile.x, job.tile.y)
			print("[Pawn] %s built a wall @(%d,%d)" % [data.display_name, job.tile.x, job.tile.y])
		Job.Type.BUILD_DOOR:
			_world.build_door(job.tile.x, job.tile.y)
			print("[Pawn] %s placed a door @(%d,%d)" % [data.display_name, job.tile.x, job.tile.y])


func _cancel_current_job() -> void:
	if _current_job != null:
		JobManager.cancel(_current_job)
	_reset_to_idle()


func _unclaim_current_job() -> void:
	if _current_job != null:
		JobManager.abandon(_current_job)
	_reset_to_idle()


func _reset_to_idle() -> void:
	_current_job = null
	# Drop any zone handle so the GC isn't rooted on a freed node after a
	# reroll. Each state that needs a zone re-picks one when it starts.
	_target_zone = null
	_state = State.IDLE
	_clear_path()
	queue_redraw()


func release_job_if_any() -> void:
	if _current_job != null:
		JobManager.cancel(_current_job)
		_current_job = null
	# If we held a bed reservation from a previous life (world reroll), drop
	# it. The bed itself is gone too, but releasing keeps the dict tidy.
	_release_bed_if_reserved()


## Read-only accessor for the current AI state. UI / debug code uses this
## instead of poking _state directly.
func get_state() -> int:
	return _state


# ==================== hauling ====================

func _begin_haul_to_stockpile() -> void:
	if not data.is_carrying():
		_state = State.IDLE
		return
	# Find the closest zone that accepts what we're carrying. "Accepts" also
	# covers the seed ALL pile, so old saves / worlds without specialized
	# zones keep working unchanged.
	var sp: Stockpile = StockpileManager.find_drop_zone(
		data.carrying, data.tile_pos, _world.pathfinder
	)
	if sp == null:
		# No zone exists that will take this item. Hold onto it and stay idle;
		# next tick we'll try again (maybe the player designated a zone).
		_log_haul_fail("no accepting zone")
		_state = State.IDLE
		return
	_target_zone = sp
	var target_tile: Vector2i = sp.nearest_tile_to(data.tile_pos)
	if data.tile_pos == target_tile:
		_deposit_at_stockpile()
		return
	var path: Array[Vector2i] = _world.pathfinder.find_path(data.tile_pos, target_tile)
	if path.is_empty():
		_log_haul_fail("no path")
		_state = State.IDLE
		return
	_state = State.HAULING
	_start_path(path)
	queue_redraw()
	print("[Pawn] %s hauling %s -> zone %s (%d,%d), path_len=%d, from (%d,%d)" % [
		data.display_name, Item.name_for(data.carrying),
		Stockpile.FILTER_NAME.get(sp.filter, "?"),
		target_tile.x, target_tile.y, path.size(),
		data.tile_pos.x, data.tile_pos.y
	])


func _log_haul_fail(reason: String) -> void:
	var t: int = GameManager.tick_count
	if t - _last_haul_fail_log_tick < HAUL_FAIL_LOG_EVERY_N_TICKS:
		return
	_last_haul_fail_log_tick = t
	var my_comp: int = -1
	if _world != null and _world.pathfinder != null:
		my_comp = _world.pathfinder.component_of(data.tile_pos)
	var zone_count: int = StockpileManager.zones().size()
	print("[Pawn] %s haul FAIL (%s): at (%d,%d) comp=%d  carrying=%s x%d  zones=%d" % [
		data.display_name, reason,
		data.tile_pos.x, data.tile_pos.y, my_comp,
		Item.name_for(data.carrying), data.carrying_qty, zone_count
	])


func _deposit_at_stockpile() -> void:
	# Prefer the zone we planned for; fall back to nearest accepting zone
	# if that one somehow vanished (reroll, player deleted it mid-walk).
	var sp: Stockpile = _target_zone
	if sp == null or not is_instance_valid(sp) or not sp.accepts(data.carrying):
		sp = StockpileManager.find_drop_zone(
			data.carrying, data.tile_pos, _world.pathfinder
		)
	if sp != null and data.is_carrying():
		sp.add_item(data.carrying, data.carrying_qty)
		print("[Pawn] %s deposited %d %s into %s zone (zone now has %d)" % [
			data.display_name, data.carrying_qty,
			Item.name_for(data.carrying),
			Stockpile.FILTER_NAME.get(sp.filter, "?"),
			sp.count_of(data.carrying)
		])
	data.clear_carry()
	_target_zone = null
	_reset_to_idle()


# ==================== eating ====================

func _maybe_start_eating() -> bool:
	if data.hunger >= HUNGER_EAT_THRESHOLD:
		return false
	if data.is_carrying():
		# Carrying something -- finish that errand first.
		return false
	var sp: Stockpile = StockpileManager.find_food_source(data.tile_pos, _world.pathfinder)
	if sp == null:
		return false
	_begin_going_to_eat(sp)
	return true


func _begin_going_to_eat(sp: Stockpile) -> void:
	_target_zone = sp
	var target_tile: Vector2i = sp.nearest_tile_to(data.tile_pos)
	if data.tile_pos == target_tile:
		_begin_eating()
		return
	var path: Array[Vector2i] = _world.pathfinder.find_path(data.tile_pos, target_tile)
	if path.is_empty():
		return
	_state = State.GOING_TO_EAT
	_start_path(path)
	queue_redraw()


func _begin_eating() -> void:
	var sp: Stockpile = _target_zone
	if sp == null or not is_instance_valid(sp) or not sp.has_any_food():
		# The zone we planned for got emptied; try another.
		sp = StockpileManager.find_food_source(data.tile_pos, _world.pathfinder)
	if sp == null:
		_target_zone = null
		_reset_to_idle()
		return
	_target_zone = sp
	_state = State.EATING
	_eat_ticks_left = EAT_TICKS
	queue_redraw()


func _finish_eating() -> void:
	var sp: Stockpile = _target_zone
	if sp == null or not is_instance_valid(sp):
		sp = StockpileManager.find_food_source(data.tile_pos, _world.pathfinder)
	if sp != null:
		var food_type: int = sp.pick_food()
		if food_type != Item.Type.NONE:
			var taken: int = sp.take_item(food_type, 1)
			if taken > 0:
				var gain: float = Item.hunger_restore(food_type)
				data.hunger = min(100.0, data.hunger + gain)
				data.mood = min(100.0, data.mood + MOOD_BONUS_ATE)
				# After eating, reset warning band so we don't re-log instantly.
				_hunger_level = _level_for(data.hunger)
				print("[Pawn] %s ate 1 %s  (+%.0f hunger -> %.1f, mood %.1f)" % [
					data.display_name, Item.name_for(food_type), gain, data.hunger, data.mood
				])
	_target_zone = null
	_reset_to_idle()


# ==================== sleep ====================

## Returns true and starts sleeping if the pawn is tired enough. Called from
## _tick_idle, so this only fires when nothing more urgent is happening.
##
## Bed preference: try to reserve and walk to the nearest free bed. If no bed
## is reachable, lie down on the spot (slower recovery, but better than dying).
func _maybe_start_sleeping() -> bool:
	# At night the threshold is raised so well-rested pawns still go to bed
	# when the sun goes down, giving the colony a real day/night rhythm.
	var threshold: float = REST_SLEEP_THRESHOLD_NIGHT if DayNightCycle.is_night_for_tick(GameManager.tick_count) else REST_SLEEP_THRESHOLD
	if data.rest > threshold:
		return false
	# Don't curl up while starving -- if there's any food path open we should
	# have taken it already in step 3, but if we got here it means no food is
	# reachable and sleeping won't fix that.
	if data.hunger <= HUNGER_EMERGENCY:
		return false
	# Don't sleep mid-haul; stockpile that item first.
	if data.is_carrying():
		return false
	if _try_walk_to_bed():
		return true
	_begin_sleeping()
	return true


## Find the closest free bed and reserve+walk to it. Returns false if no bed
## is available; the caller falls back to floor-sleep.
func _try_walk_to_bed() -> bool:
	if _world == null:
		return false
	var bed: Vector2i = _world.find_free_bed_for(self, data.tile_pos)
	if bed.x < 0:
		return false
	if not _world.reserve_bed(bed, self):
		return false
	_reserved_bed = bed
	if data.tile_pos == bed:
		_begin_sleeping()
		return true
	var path: Array[Vector2i] = _world.pathfinder.find_path(data.tile_pos, bed)
	if path.is_empty():
		# Reservation failed in practice: release it and fall back to floor.
		_world.release_bed(bed, self)
		_reserved_bed = Vector2i(-1, -1)
		return false
	_state = State.GOING_TO_BED
	_start_path(path)
	queue_redraw()
	return true


func _arrive_at_bed() -> void:
	# We may have been bumped off our reservation by a regen / world reset.
	# Re-confirm before sleeping.
	if _reserved_bed.x < 0 or not _world.is_bed_owned_by(_reserved_bed, self):
		_reserved_bed = Vector2i(-1, -1)
	_begin_sleeping()


func _begin_sleeping() -> void:
	_state = State.SLEEPING
	_clear_path()
	queue_redraw()
	var on_bed: bool = _reserved_bed.x >= 0 and data.tile_pos == _reserved_bed
	var where: String = " in a bed" if on_bed else ""
	print("[Pawn] %s lies down to sleep%s  (rest=%.1f)" % [data.display_name, where, data.rest])


## Per-tick while in SLEEPING. The actual rest restoration / hunger decay
## happens in _decay_needs (which checks the state). Here we only handle
## the wake conditions.
func _tick_sleeping() -> void:
	# Wake up early if we get critically hungry -- food trumps sleep.
	if data.hunger <= HUNGER_EMERGENCY:
		print("[Pawn] %s wakes hungry  (hunger=%.1f rest=%.1f)" %
			[data.display_name, data.hunger, data.rest])
		_release_bed_if_reserved()
		_reset_to_idle()
		return
	# Normal wake on rest restored.
	if data.rest >= REST_WAKE_THRESHOLD:
		data.mood = min(100.0, data.mood + MOOD_BONUS_WOKE_REFRESHED)
		print("[Pawn] %s wakes refreshed  (rest=%.1f, mood %.1f)" %
			[data.display_name, data.rest, data.mood])
		_release_bed_if_reserved()
		_reset_to_idle()
		return


## Drop any bed reservation we hold. Safe to call multiple times.
func _release_bed_if_reserved() -> void:
	if _reserved_bed.x < 0:
		return
	if _world != null:
		_world.release_bed(_reserved_bed, self)
	_reserved_bed = Vector2i(-1, -1)


## Emergency food path: consume one unit of whatever food the pawn is
## carrying, then drop back to IDLE. No stockpile interaction, no eating
## state -- the pawn just wolfs it down on the spot.
func _eat_from_hand() -> void:
	if not data.is_carrying() or not Item.is_food(data.carrying):
		return
	var food_type: int = data.carrying
	var gain: float = Item.hunger_restore(food_type)
	data.hunger = min(100.0, data.hunger + gain)
	data.mood = min(100.0, data.mood + MOOD_BONUS_ATE)
	data.carrying_qty -= 1
	if data.carrying_qty <= 0:
		data.clear_carry()
	_hunger_level = _level_for(data.hunger)
	print("[Pawn] %s ate 1 %s FROM HAND (emergency, +%.0f hunger -> %.1f, mood %.1f)" % [
		data.display_name, Item.name_for(food_type), gain, data.hunger, data.mood
	])
	queue_redraw()


# ==================== needs ====================

func _decay_needs() -> void:
	# Sleeping pawns metabolize slower and recover rest instead of losing it.
	# A bed that the pawn has reserved AND is currently standing on grants a
	# faster recovery rate -- the payoff for hauling wood and building.
	# Everything else (mood, etc.) decays normally so a 24-hour nap still
	# erodes happiness.
	if _state == State.SLEEPING:
		data.hunger = max(0.0, data.hunger - HUNGER_DECAY_PER_TICK_SLEEPING)
		var rate: float = REST_RECOVER_PER_TICK_SLEEP
		if _reserved_bed.x >= 0 and data.tile_pos == _reserved_bed and \
				_world != null and _world.is_bed_owned_by(_reserved_bed, self):
			rate *= REST_RECOVER_BED_MULTIPLIER
		data.rest = min(100.0, data.rest + rate)
	else:
		data.hunger = max(0.0, data.hunger - HUNGER_DECAY_PER_TICK)
		data.rest   = max(0.0, data.rest   - REST_DECAY_PER_TICK)
	# Mood: net loss when needs aren't met, net gain when they are.
	# Passive contentment outpaces decay, so a pawn whose hunger AND rest are
	# both comfortable will recover happiness on their own.
	if data.hunger >= MOOD_CONTENT_FLOOR and data.rest >= MOOD_CONTENT_FLOOR:
		data.mood = min(100.0, data.mood + MOOD_GAIN_PER_TICK_CONTENT - MOOD_DECAY_PER_TICK)
	else:
		data.mood = max(0.0, data.mood - MOOD_DECAY_PER_TICK)


func _check_thresholds() -> void:
	_hunger_level = _update_level(data.hunger, _hunger_level, "hungry",  "starving")
	_rest_level   = _update_level(data.rest,   _rest_level,   "tired",   "exhausted")
	_mood_level   = _update_level(data.mood,   _mood_level,   "unhappy", "miserable")


func _update_level(value: float, prev_level: int, warn_word: String, crit_word: String) -> int:
	var new_level: int = _level_for(value)
	if new_level > prev_level:
		var word := warn_word if new_level == 1 else crit_word
		print("[Pawn] %s is %s  (value=%.1f)" % [data.display_name, word, value])
	return new_level


static func _level_for(value: float) -> int:
	if value <= THRESHOLD_CRIT:
		return 2
	if value <= THRESHOLD_WARN:
		return 1
	return 0


# ==================== wander fallback ====================

## Only 4-way: the straight-line lerp between two cardinally-adjacent tile
## centers can never visually enter a neighboring tile, so pawns never appear
## to clip through an impassable corner during a wander step.
const WANDER_OFFSETS: Array[Vector2i] = [
	Vector2i( 1, 0), Vector2i(-1, 0), Vector2i(0,  1), Vector2i(0, -1),
]


func _start_wander() -> void:
	if _world == null or _world.pathfinder == null:
		return
	var candidates: Array[Vector2i] = []
	for offset in WANDER_OFFSETS:
		var t: Vector2i = data.tile_pos + offset
		if _world.pathfinder.is_passable(t):
			candidates.append(t)
	if candidates.is_empty():
		return
	var chosen: Vector2i = candidates[randi() % candidates.size()]
	var path: Array[Vector2i] = [chosen]
	_start_path(path)


# ==================== render ====================

func _draw() -> void:
	if data == null:
		return
	# Sleeping pawns render slightly dimmer to read as "off duty".
	var body_color: Color = data.color
	if _state == State.SLEEPING:
		body_color = data.color.darkened(0.25)
	draw_circle(Vector2.ZERO, DRAW_RADIUS, body_color)
	if is_selected:
		# Bright yellow ring sits just outside the body and the busy outline so
		# it reads even when the pawn is mid-task.
		var sel_color := Color(1.0, 0.92, 0.18)
		draw_arc(
			Vector2.ZERO,
			DRAW_RADIUS + 3.5,
			0.0,
			TAU,
			28,
			sel_color,
			1.4,
			true
		)
	# Outline color/width communicates state.
	var busy: bool = (
		_state == State.WORKING
		or _state == State.EATING
		or _state == State.DRAFT_WALK
	)
	var outline_c: Color = Color.BLACK
	if _state == State.WORKING:
		outline_c = Color.WHITE
	elif _state == State.EATING:
		outline_c = Color(0.2, 0.9, 0.2)  # green
	elif _state == State.GOING_TO_EAT:
		outline_c = Color(1.0, 0.85, 0.2)  # amber
	elif _state == State.SLEEPING:
		outline_c = Color(0.49, 0.30, 0.81)  # purple
	elif _state == State.GOING_TO_BED:
		outline_c = Color(0.78, 0.66, 1.0)  # light purple
	elif _state == State.FETCHING_MATERIAL:
		outline_c = Color(0.95, 0.65, 0.35)  # warm orange -- "carrying back"
	elif _state == State.DRAFT_WALK:
		outline_c = Color(0.45, 0.95, 1.0)  # bright cyan
	var outline_w: float = OUTLINE_WIDTH_BUSY if busy else OUTLINE_WIDTH
	draw_arc(Vector2.ZERO, DRAW_RADIUS, 0.0, TAU, 20, outline_c, outline_w, true)
	# Sleep "Z" mark: tiny purple zig-zag floating above a sleeping pawn.
	if _state == State.SLEEPING:
		var z_color := Color(0.78, 0.66, 1.0)
		var z_top := Vector2(2.0, -8.0)
		var z_mid_r := Vector2(5.0, -8.0)
		var z_mid_l := Vector2(2.0, -5.0)
		var z_bot := Vector2(5.0, -5.0)
		draw_line(z_top, z_mid_r, z_color, 0.7, true)
		draw_line(z_mid_r, z_mid_l, z_color, 0.7, true)
		draw_line(z_mid_l, z_bot, z_color, 0.7, true)
	# Carry indicator: small colored swatch above the head.
	if data.is_carrying():
		var c: Color = Item.color_for(data.carrying)
		var rect := Rect2(
			CARRY_OFFSET - CARRY_SIZE * 0.5,
			CARRY_SIZE
		)
		draw_rect(rect, c, true)
		draw_rect(rect, Color.BLACK, false, 0.6)


# ---------------------------------------------------------------------------
# Public introspection (used by PawnInfoPanel / selection UI)
#
# get_state() already lives up in the AI section -- don't add another one
# down here or you'll get a "duplicate function" parse error that takes the
# whole class down with it (Pawn fails to load -> JobManager signals can't
# resolve `pawn: Pawn` -> every dependent script fails to load too).
# ---------------------------------------------------------------------------

## Read-only accessor for the pawn's current job, may be null.
func get_current_job() -> Job:
	return _current_job


## Returns true if the pawn is currently asleep in a registered bed.
func is_in_bed() -> bool:
	return _state == State.SLEEPING and _reserved_bed.x >= 0


## Human-readable summary of what the pawn is doing right now.
## Used by the info panel and (optionally) tooltips.
func describe_state() -> String:
	match _state:
		State.IDLE:
			return "Idle"
		State.WALKING_TO_JOB:
			if _current_job != null:
				return "Heading out: %s" % _verb_for_job(_current_job.type).to_lower()
			return "Walking"
		State.WORKING:
			if _current_job != null:
				return _verb_for_job(_current_job.type)
			return "Working"
		State.HAULING:
			if data != null and data.is_carrying():
				return "Hauling %s" % Item.name_for(data.carrying)
			return "Hauling"
		State.GOING_TO_EAT:
			return "Heading to eat"
		State.EATING:
			return "Eating"
		State.SLEEPING:
			if _reserved_bed.x >= 0:
				return "Sleeping in bed"
			return "Sleeping on the ground"
		State.GOING_TO_BED:
			return "Heading to bed"
		State.FETCHING_MATERIAL:
			if _current_job != null:
				return "Fetching wood for %s" % \
					_verb_for_job(_current_job.type).to_lower()
			return "Fetching materials"
		State.DRAFT_WALK:
			return "Moving (direct order)"
	return "?"


static func _verb_for_job(job_type: int) -> String:
	match job_type:
		Job.Type.FORAGE:
			return "Foraging berries"
		Job.Type.MINE:
			return "Mining stone"
		Job.Type.MINE_WALL:
			return "Tunneling"
		Job.Type.CHOP:
			return "Chopping wood"
		Job.Type.HUNT:
			return "Hunting"
		Job.Type.BUILD_BED:
			return "Building bed"
		Job.Type.BUILD_WALL:
			return "Building wall"
		Job.Type.BUILD_DOOR:
			return "Building door"
	return "Working"
