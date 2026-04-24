extends Node2D

## Top-level scene controller. Owns input hotkeys and the startup/reroll
## sequence: world -> stockpile -> pawns -> jobs. Each step depends on the
## previous, so order here matters.

const STOCKPILE_SCENE: PackedScene = preload("res://scenes/stockpile/Stockpile.tscn")

## Tuning for initial job generation.
const FORAGE_WORK_TICKS: int = 20
const MINE_WORK_TICKS: int = 40
const MINE_WALL_WORK_TICKS: int = 60   # walls are slower than loose ore
const CHOP_WORK_TICKS: int = 25
const HUNT_RABBIT_WORK_TICKS: int = 20 # quick chase + clobber; small payoff
const HUNT_DEER_WORK_TICKS:   int = 45 # bigger animal, harder to bring down
const BUILD_BED_WORK_TICKS: int = 30   # roughly the same as a mine: solid effort but not a chore
const BUILD_WALL_WORK_TICKS: int = 40  # heftier than a bed -- it's structural
const BUILD_DOOR_WORK_TICKS: int = 25  # quick, slots between two walls
# Harvest priorities. ALL EQUAL on purpose: pawns then pick the nearest job
# of any harvest type, which gives a natural mix. (Earlier I tried bumping
# MINE above the rest and it caused pawns to ignore food entirely -- they
# starved while mining stone. Don't do that again.)
# Food balance is enforced separately by the food-emergency override in
# Pawn._tick_idle, which forces idle pawns onto FORAGE jobs when the
# stockpile is almost out.
const FORAGE_PRIORITY: int = 3
const MINE_PRIORITY: int = 3
const CHOP_PRIORITY: int = 3
const HUNT_PRIORITY: int = 3       # peer of forage/mine/chop -- distance breaks ties
const MINE_WALL_PRIORITY: int = 2
## Build jobs sit at the top of the harvest stack so once the player designates
## a site, pawns prioritize getting it up over yet another forage. Walls > beds
## > doors just because walls usually frame what comes next. The materials
## filter prevents pawns from claiming a build with no wood in stockpile, so
## these don't actually starve out harvest work.
const BUILD_BED_PRIORITY: int = 4
const BUILD_WALL_PRIORITY: int = 5
const BUILD_DOOR_PRIORITY: int = 4

## When player presses B, designate this many beds in a tight ring around the
## stockpile (or as many as fit before we run out of slots / scan radius).
const BEDS_PER_DESIGNATION: int = 5
## Search radius around the stockpile for bed sites. 6 -> 13x13 area.
const BED_SCAN_RADIUS: int = 6
const MAX_FORAGE_JOBS: int = 80
## Bumped from 40 alongside the new surface-ore deposits so the queue can
## actually hold them all -- otherwise the reactive seeder spends cycles
## repeatedly trying to repost.
const MAX_MINE_JOBS: int = 80
const MAX_CHOP_JOBS: int = 60
## All wildlife on the main landmass is huntable; this just caps how many we
## actually post at once so the queue stays readable.
const MAX_HUNT_JOBS: int = 50
## Cap concurrent tunnels so the colony doesn't dump all its labor into rocks.
## When one finishes, the reactive seeder posts the next.
const MAX_ACTIVE_MINE_WALL_JOBS: int = 4

# -------------------- regrowth tuning --------------------
# Renewable resources: berries grow back on FERTILE_SOIL and trees grow back
# on the tiles they were chopped from. Without this the colony exhausts the
# map and starves once everything has been harvested once.
#
# 600 ticks = 60s real at 1x, 10s real at 6x = ~1 in-game day.
const FORAGE_REGROW_TICKS: int = 600
## Trees take longer (slower-growing). 1500 ticks ~ 2.5 in-game days.
const TREE_REGROW_TICKS: int = 1500
## Wildlife respawn: roughly between berries and trees. Each kill seeds a
## fresh animal of the same species back on the same tile after this delay,
## representing herd / warren repopulation rather than literal resurrection.
const RABBIT_REGROW_TICKS: int = 900
const DEER_REGROW_TICKS:   int = 1800

@onready var _world: World = $World
@onready var _preview_layer: Node2D = $BuildPreviewOverlay
@onready var _pawn_spawner: PawnSpawner = $PawnSpawner
@onready var _animal_spawner: AnimalSpawner = $AnimalSpawner
@onready var _hud: ColonyHUD = $ColonyHUD
@onready var _toolbar: BuildToolbar = $BuildToolbar
@onready var _info_panel: PawnInfoPanel = $PawnInfoPanel
@onready var _day_night: DayNightCycle = $DayNight

# -------------------- selection --------------------
## Currently selected pawn (right-side info panel). null = nothing selected.
## Click a pawn to select; click empty ground or press Esc to deselect.
var _selected_pawn: Pawn = null
## Pixel radius around a pawn that counts as a click hit. Pawns draw at
## DRAW_RADIUS=3.5; we add a generous slop so moving targets are easy to grab.
const SELECT_PICK_RADIUS_PX: float = 7.0

## Pending regrowth events. Each entry is a Dictionary:
##   { "tile": Vector2i, "feature": int (TileFeature.Type), "ready_tick": int }
## Processed every tick; tiles whose feature slot is still NONE and biome is
## still compatible get the feature back and a fresh job posted.
var _regrow_queue: Array = []

# -------------------- designation (player build mode) --------------------
## Player build modes. NONE means clicks are ignored. Every other mode uses
## the same click-drag rectangle system:
##   - click + release on the same tile  -> stamp one tile (back-compat).
##   - click + drag + release             -> stamp every tile in the rect.
##
## BUILD_BED / BUILD_WALL / BUILD_DOOR post one build job per tile in the rect.
## DESIGNATE_ZONE creates a single Stockpile covering the whole rect.
enum DesignationMode { NONE, BUILD_BED, BUILD_WALL, BUILD_DOOR, DESIGNATE_ZONE }
var _designation_mode: int = DesignationMode.NONE
## Currently hovered tile in tile coords, or (-1,-1) if mouse is off-map.
var _hover_tile: Vector2i = Vector2i(-1, -1)

# -------------------- drag-to-stamp state --------------------
## Filter applied to the next-designated zone. Cycles through Stockpile.Filter
## via the F key or the toolbar "Filter:" button. Doesn't affect already-
## placed zones.
var _zone_next_filter: int = 0  # Stockpile.Filter.ALL -- typed as int to
                                # avoid touching Stockpile before autoloads load
## True while the player is holding left mouse in a designation mode. The
## rectangle grows with the mouse; release commits.
var _is_dragging: bool = false
## First and current tile of the in-progress drag. (-1,-1) when not dragging.
var _drag_start: Vector2i = Vector2i(-1, -1)
var _drag_current: Vector2i = Vector2i(-1, -1)

## Zones have their own size caps; build-mode stamps use a tile count cap to
## keep a stray wide drag from dumping 10k jobs into the queue.
const ZONE_MAX_AREA: int = 400   # 20x20 cap for stockpile zones
const BUILD_DRAG_MAX_TILES: int = 256  # ~16x16 of walls/beds/doors at once


func _ready() -> void:
	GameManager.game_tick.connect(_on_game_tick)
	GameManager.speed_changed.connect(_on_speed_changed)
	# React to mining progress: when a wall comes down or an ore is cleared,
	# new ores can become reachable and we may want to queue the next tunnel.
	JobManager.job_completed.connect(_on_job_completed)
	# Bottom toolbar: lets the player drive everything with the mouse.
	if _toolbar != null:
		_toolbar.mode_requested.connect(_on_toolbar_mode_requested)
		_toolbar.speed_index_requested.connect(GameManager.set_speed_index)
		_toolbar.pause_toggled.connect(GameManager.toggle_pause)
		_toolbar.reroll_requested.connect(_reroll_world)
		_toolbar.zone_filter_cycle_requested.connect(_cycle_zone_filter)
		_toolbar.save_requested.connect(_colony_save)
		_toolbar.load_requested.connect(_colony_load)
		_push_zone_filter_label_to_toolbar()
	print("[Main] Scene ready. Tick interval: %.2fs" % GameManager.TICK_INTERVAL_SECONDS)
	_bootstrap_colony()


func _on_toolbar_mode_requested(mode: int) -> void:
	# Toolbar mode ints match Main.DesignationMode by construction.
	_set_designation_mode(mode)


## Full colony startup (or reboot after R). Order:
##   1. World already generated (World._ready runs before Main._ready).
##   2. Pick the main landmass via largest-component.
##   3. Place the stockpile somewhere central on that landmass.
##   4. Spawn pawns, restricted to that landmass so they can reach the stockpile.
##   5. Seed initial jobs from world features.
func _bootstrap_colony() -> void:
	var main_component: int = _world.pathfinder.largest_component_id()
	if main_component < 0:
		push_error("[Main] No passable tiles in world; cannot bootstrap colony.")
		return
	_place_stockpile(main_component)
	_pawn_spawner.spawn_starters(_world, main_component)
	# Spawn animals and register spawner with world for breeding
	_animal_spawner.spawn_initial(_world)
	_world.set_meta("animal_spawner", _animal_spawner)
	_seed_jobs_from_world()
	# Seed initial tunneling toward sealed ore.
	_react_to_mining_progress()
	if _hud != null:
		_hud.bind(_world, _pawn_spawner)


## Instantiate the seed Stockpile zone at the nearest main-component tile
## to the world center. Frees any previous zone first. Registers the zone
## with StockpileManager so every system (pawns, HUD) finds it through the
## same manager as player-designated zones.
##
## Note: we deliberately ship the seed zone as a 3x3 ALL-filter pile. That's
## wide enough that adjacent tiles are walkable-in from any direction
## (pawns don't have to queue through a single corner) and ALL means the
## brand-new colony has somewhere to dump anything until the player decides
## to specialize with designated zones.
func _place_stockpile(main_component: int) -> void:
	if _world.stockpile != null:
		StockpileManager.unregister(_world.stockpile)
		_world.stockpile.queue_free()
		_world.stockpile = null
	var center := Vector2i(WorldData.WIDTH / 2, WorldData.HEIGHT / 2)
	var tile: Vector2i = _world.pathfinder.find_tile_in_component_near(main_component, center)
	if tile.x < 0:
		push_error("[Main] Could not find a tile on the main component to place the stockpile.")
		return
	var seed_rect: Rect2i = _fit_seed_stockpile_rect(tile, main_component, 3, 3)
	var sp: Stockpile = STOCKPILE_SCENE.instantiate()
	sp.set_filter(Stockpile.Filter.ALL)
	sp.set_rect_tiles(seed_rect)
	sp.position = _world.tile_to_world(seed_rect.position)
	add_child(sp)
	_world.stockpile = sp
	StockpileManager.register(sp)
	print("[Main] Seed stockpile placed at %s (%dx%d, ALL)" %
		[seed_rect.position, seed_rect.size.x, seed_rect.size.y])


## Clamp a desired-size seed stockpile rectangle so it stays on the main
## component. We start at (tile - half) and shrink toward the anchor if any
## candidate tile is impassable. Guaranteed to return at least a 1x1 rect
## containing `tile`.
func _fit_seed_stockpile_rect(tile: Vector2i, main_component: int, w: int, h: int) -> Rect2i:
	var start_x: int = tile.x - (w / 2)
	var start_y: int = tile.y - (h / 2)
	# Pull in from edges first so the rect stays inside the world.
	start_x = clamp(start_x, 0, WorldData.WIDTH - w)
	start_y = clamp(start_y, 0, WorldData.HEIGHT - h)
	# If any candidate tile is off-component, shrink to a 1x1 fallback.
	for dy in range(h):
		for dx in range(w):
			var t := Vector2i(start_x + dx, start_y + dy)
			if _world.pathfinder.component_of(t) != main_component:
				return Rect2i(tile, Vector2i.ONE)
	return Rect2i(Vector2i(start_x, start_y), Vector2i(w, h))


func _on_game_tick(tick: int) -> void:
	_process_regrowth(tick)
	# Post hunting jobs for live animals every 10 ticks
	if tick % 10 == 0:
		_post_hunting_jobs_for_animals()
	if tick % 100 == 0:
		print("[Main] Tick %d" % tick)
	# Failsafe: pawns that slipped into solid tiles (rare) get nudged; log once per pawn.
	if tick % 60 == 0 and _pawn_spawner != null:
		for p in _pawn_spawner.pawns:
			if p != null and is_instance_valid(p):
				p.sanity_check_impassable_tile()


func _on_speed_changed(speed: float, paused: bool) -> void:
	if paused:
		print("[Main] PAUSED")
	else:
		print("[Main] Speed: %.1fx" % speed)


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE:
			GameManager.toggle_pause()
		KEY_1:
			GameManager.set_speed_index(0)
		KEY_2:
			GameManager.set_speed_index(1)
		KEY_3:
			GameManager.set_speed_index(2)
		KEY_4:
			GameManager.set_speed_index(3)
		KEY_R:
			_reroll_world()
		KEY_T:
			_pawn_spawner.print_stats()
		KEY_J:
			JobManager.print_debug()
		KEY_I:
			_print_stockpile()
		KEY_B:
			# Shift+B is the legacy "stamp 5 beds near the stockpile" shortcut,
			# kept for quick demos. Plain B enters bed-designation mode.
			if event.shift_pressed:
				_designate_beds_near_stockpile()
			else:
				_toggle_designation_mode(DesignationMode.BUILD_BED)
		KEY_W:
			_toggle_designation_mode(DesignationMode.BUILD_WALL)
		KEY_O:
			_toggle_designation_mode(DesignationMode.BUILD_DOOR)
		KEY_Z:
			_toggle_designation_mode(DesignationMode.DESIGNATE_ZONE)
		KEY_F:
			_cycle_zone_filter()
		KEY_F5:
			_colony_save()
		KEY_F8:
			_colony_load()
		KEY_M:
			ColonySimServices.cycle_labor_stance()
		KEY_ESCAPE:
			# Esc clears either a drag-in-progress, an active build mode, or
			# a pawn selection (in that priority order). Each extra Esc peels
			# off the next layer.
			if _is_dragging:
				_cancel_drag()
			elif _designation_mode != DesignationMode.NONE:
				_set_designation_mode(DesignationMode.NONE)
			elif _selected_pawn != null:
				_set_selected_pawn(null)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_update_hover_tile(event.position)
		# Safety net: if the toolbar / HUD swallowed the mouse-release (e.g.
		# the player ended a drag over a UI button), we never got
		# _on_left_release. Detect it here by polling the raw button state
		# and cancel instead of leaving the drag stuck forever.
		if _is_dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_cancel_drag()
			return
		if _is_dragging:
			_drag_current = _hover_tile
			if _designation_mode == DesignationMode.BUILD_WALL:
				_update_wall_path_preview()
			_queue_designation_redraw()
		return
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		match mb.button_index:
			MOUSE_BUTTON_LEFT:
				if mb.pressed:
					_on_left_press()
				else:
					_on_left_release()
			MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					_on_right_press()


## Left-click press handler. Branches on the active designation mode:
##   - any build/zone mode: start click-drag rectangle.
##   - no mode: try to select the pawn under the cursor.
func _on_left_press() -> void:
	_update_hover_tile(get_viewport().get_mouse_position())
	if _designation_mode != DesignationMode.NONE:
		if _hover_tile.x < 0:
			return
		_is_dragging = true
		_drag_start = _hover_tile
		_drag_current = _hover_tile
		_queue_designation_redraw()
		get_viewport().set_input_as_handled()
	else:
		_handle_select_click_at(get_global_mouse_position())
		get_viewport().set_input_as_handled()


## Left-click release handler. If a drag was in progress, commit it.
## A same-tile press+release commits a single-tile rect, so the old click-
## to-place behavior is preserved.
func _on_left_release() -> void:
	if _is_dragging:
		_commit_drag()
		get_viewport().set_input_as_handled()


## Right-click press: cancel whatever's active. Priority mirrors Esc so the
## two keys feel consistent: drag > build mode > draft move (if pawn selected)
## > deselect (only if there was a selection / stale ref).
func _on_right_press() -> void:
	if _is_dragging:
		_cancel_drag()
		get_viewport().set_input_as_handled()
		return
	if _designation_mode != DesignationMode.NONE:
		_set_designation_mode(DesignationMode.NONE)
		get_viewport().set_input_as_handled()
		return
	if is_instance_valid(_selected_pawn):
		var t: Vector2i = _world.world_to_tile(get_global_mouse_position())
		if t.x < 0:
			_set_selected_pawn(null)
			get_viewport().set_input_as_handled()
			return
		if _tile_covered_by_any_stockpile(t) or not _world.pathfinder.is_passable(t):
			get_viewport().set_input_as_handled()
			return
		_selected_pawn.draft_goto(t)
		get_viewport().set_input_as_handled()
		return
	if _selected_pawn != null:
		_set_selected_pawn(null)
		get_viewport().set_input_as_handled()
	# No selection: leave the event unhandled (camera / future UI may use it).


# ---------- drag-to-stamp: commit / cancel ----------

func _cancel_drag() -> void:
	_is_dragging = false
	_drag_start = Vector2i(-1, -1)
	_drag_current = Vector2i(-1, -1)
	_queue_designation_redraw()


## Finalize the current drag based on the active designation mode. Build
## modes stamp one job per tile in the rect; zone mode creates one Stockpile
## covering the whole rect.
func _commit_drag() -> void:
	var start: Vector2i = _drag_start
	var end: Vector2i = _drag_current
	_is_dragging = false
	_drag_start = Vector2i(-1, -1)
	_drag_current = Vector2i(-1, -1)
	if start.x < 0 or end.x < 0:
		_queue_designation_redraw()
		return
	var rect: Rect2i = _normalize_rect(start, end)
	match _designation_mode:
		DesignationMode.DESIGNATE_ZONE:
			_commit_zone_rect(rect)
		DesignationMode.BUILD_BED, DesignationMode.BUILD_WALL, DesignationMode.BUILD_DOOR:
			_commit_build_rect(rect)
	_queue_designation_redraw()


## Create a Stockpile zone from the drag rect. Skips silently if the rect
## is out-of-bounds, too big, or has no reachable tiles.
func _commit_zone_rect(rect: Rect2i) -> void:
	if rect.size.x * rect.size.y > ZONE_MAX_AREA:
		print("[Main] Zone too big (%dx%d, max area %d) -- dropped" %
			[rect.size.x, rect.size.y, ZONE_MAX_AREA])
		return
	if _count_passable_in_rect(rect) == 0:
		print("[Main] Zone has no passable tiles @%s -- dropped" % str(rect))
		return
	var sp: Stockpile = STOCKPILE_SCENE.instantiate()
	sp.set_filter(_zone_next_filter)
	sp.set_rect_tiles(rect)
	sp.position = _world.tile_to_world(rect.position)
	add_child(sp)
	StockpileManager.register(sp)
	print("[Main] Zone %s designated at %s (%dx%d)" % [
		Stockpile.FILTER_NAME.get(_zone_next_filter, "?"),
		rect.position, rect.size.x, rect.size.y
	])


## Post one build job per tile in the rect, filtered by the active build
## mode's validity predicate. Invalid tiles (mountain, water, existing
## feature, off-component) are silently skipped -- player can drag a wide
## rect without worrying about overlaps.
func _commit_build_rect(rect: Rect2i) -> void:
	var tile_count: int = rect.size.x * rect.size.y
	if tile_count > BUILD_DRAG_MAX_TILES:
		print("[Main] Build drag too big (%d tiles, max %d) -- dropped" %
			[tile_count, BUILD_DRAG_MAX_TILES])
		return
	var posted: int = 0
	var skipped: int = 0
	for dy in range(rect.size.y):
		for dx in range(rect.size.x):
			var t := Vector2i(rect.position.x + dx, rect.position.y + dy)
			if _try_apply_designation_at(t):
				posted += 1
			else:
				skipped += 1
	if posted > 0:
		print("[Main] Drag-stamped %s: %d placed%s" % [
			_designation_mode_label(_designation_mode),
			posted,
			"" if skipped == 0 else ", %d skipped" % skipped
		])
	elif skipped > 0:
		print("[Main] Drag-stamp: no valid tiles (%d skipped)" % skipped)


## Return a Rect2i with non-negative size from two corner tiles (either order).
static func _normalize_rect(a: Vector2i, b: Vector2i) -> Rect2i:
	var min_x: int = min(a.x, b.x)
	var min_y: int = min(a.y, b.y)
	var max_x: int = max(a.x, b.x)
	var max_y: int = max(a.y, b.y)
	return Rect2i(Vector2i(min_x, min_y), Vector2i(max_x - min_x + 1, max_y - min_y + 1))


func _count_passable_in_rect(rect: Rect2i) -> int:
	var count: int = 0
	for dy in range(rect.size.y):
		for dx in range(rect.size.x):
			var t := Vector2i(rect.position.x + dx, rect.position.y + dy)
			if not _world.data.in_bounds(t.x, t.y):
				continue
			if Biome.is_passable(_world.data.get_biome(t.x, t.y)) \
					and _world.data.get_feature(t.x, t.y) != TileFeature.Type.WALL:
				count += 1
	return count


## Cycle through the Stockpile.Filter enum in declaration order. Wraps.
func _cycle_zone_filter() -> void:
	# .values() is the portable way -- .size() on an enum literal works on
	# current Godot 4 but is less guaranteed across minor versions.
	var n: int = Stockpile.Filter.values().size()
	_zone_next_filter = (_zone_next_filter + 1) % n
	_push_zone_filter_label_to_toolbar()
	print("[Main] Next-zone filter: %s" %
		Stockpile.FILTER_NAME.get(_zone_next_filter, "?"))


func _push_zone_filter_label_to_toolbar() -> void:
	if _toolbar != null:
		_toolbar.set_zone_filter_label(Stockpile.FILTER_NAME.get(_zone_next_filter, "?"))


## Unregister and free every stockpile zone currently in the scene. Called
## on reroll so a fresh world starts with only the seeded zone.
func _tear_down_all_zones() -> void:
	var snapshot: Array[Stockpile] = StockpileManager.zones().duplicate()
	StockpileManager.clear_all()
	for z in snapshot:
		if is_instance_valid(z):
			z.queue_free()
	_world.stockpile = null


func _toggle_designation_mode(mode: int) -> void:
	if _designation_mode == mode:
		_set_designation_mode(DesignationMode.NONE)
	else:
		_set_designation_mode(mode)


func _set_designation_mode(mode: int) -> void:
	if _designation_mode == mode:
		return
	# Switching modes mid-drag is ambiguous (is the drag for the old mode or
	# the new one?) so we just drop the in-progress rect. Player can re-drag.
	if _is_dragging:
		_cancel_drag()
	_designation_mode = mode
	if _hud != null:
		_hud.set_designation_mode(_designation_mode_label(mode))
	if _toolbar != null:
		_toolbar.set_active_mode(mode)
	if mode == DesignationMode.NONE:
		print("[Main] Designation mode: off")
	else:
		print("[Main] Designation mode: %s  (left-click to place, right-click / Esc to cancel)" %
			_designation_mode_label(mode))
	_update_wall_path_preview()
	_queue_designation_redraw()


static func _designation_mode_label(mode: int) -> String:
	match mode:
		DesignationMode.BUILD_BED:     return "Bed"
		DesignationMode.BUILD_WALL:    return "Wall"
		DesignationMode.BUILD_DOOR:    return "Door"
		DesignationMode.DESIGNATE_ZONE: return "Zone"
	return ""


func _handle_select_click_at(world_pos: Vector2) -> void:
	# Pick the visually-closest pawn within SELECT_PICK_RADIUS_PX. We use
	# the pawn's actual global_position (not data.tile_pos) so a pawn that
	# is currently between tiles is still selectable.
	if _pawn_spawner == null:
		_set_selected_pawn(null)
		return
	var best: Pawn = null
	var best_d_sq: float = SELECT_PICK_RADIUS_PX * SELECT_PICK_RADIUS_PX
	for p in _pawn_spawner.pawns:
		if p == null or not is_instance_valid(p):
			continue
		var d_sq: float = p.global_position.distance_squared_to(world_pos)
		if d_sq <= best_d_sq:
			best = p
			best_d_sq = d_sq
	_set_selected_pawn(best)


func _set_selected_pawn(p: Pawn) -> void:
	if _selected_pawn == p:
		return
	if _selected_pawn != null and is_instance_valid(_selected_pawn):
		_selected_pawn.is_selected = false
		_selected_pawn.queue_redraw()
	_selected_pawn = p
	if _selected_pawn != null:
		_selected_pawn.is_selected = true
		_selected_pawn.queue_redraw()
		print("[Main] Selected %s" % _selected_pawn.data.describe())
	else:
		print("[Main] Selection cleared")
	if _info_panel != null:
		_info_panel.bind_pawn(_selected_pawn)


func _update_hover_tile(_screen_pos: Vector2) -> void:
	if _world == null:
		return
	# Built-in handles camera transform + zoom for us.
	var t: Vector2i = _world.world_to_tile(get_global_mouse_position())
	if t == _hover_tile:
		return
	_hover_tile = t
	_update_wall_path_preview()
	if _designation_mode != DesignationMode.NONE:
		_queue_designation_redraw()


## While wall mode is active, mark preview cells as A* solid so pawns detour
## (mirrors the wall jobs that have not been posted over invalid/red tiles).
func _update_wall_path_preview() -> void:
	if _world == null or _designation_mode != DesignationMode.BUILD_WALL:
		if _world != null and _world.pathfinder != null and _world.data != null:
			_world.pathfinder.set_preview_wall_tiles([], _world.data)
		return
	var a: Vector2i = _drag_start if _is_dragging else _hover_tile
	var b: Vector2i = _drag_current if _is_dragging else _hover_tile
	if a.x < 0 or b.x < 0:
		_world.pathfinder.set_preview_wall_tiles([], _world.data)
		return
	var rect: Rect2i = _normalize_rect(a, b)
	var main_component: int = _world.pathfinder.largest_component_id()
	var plan: Array = []
	for dy in range(rect.size.y):
		for dx in range(rect.size.x):
			var t2 := Vector2i(rect.position.x + dx, rect.position.y + dy)
			if _preview_tile_valid(t2, main_component):
				plan.append(t2)
	_world.pathfinder.set_preview_wall_tiles(plan, _world.data)


## Post a single build job at the given tile if it's a valid site for the
## current designation mode. Returns true if a job was posted, false if the
## tile was skipped. Used both by single-click stamps and by the per-tile
## loop inside drag commits; the quiet failure path is essential for drag
## stamps because a wide rect almost always includes some invalid tiles
## (mountain, water, existing features) and we don't want a log line per
## skipped tile.
func _try_apply_designation_at(tile: Vector2i) -> bool:
	if tile.x < 0:
		return false
	if not _world.data.in_bounds(tile.x, tile.y):
		return false
	var main_component: int = _world.pathfinder.largest_component_id()
	match _designation_mode:
		DesignationMode.BUILD_BED:
			if not _is_valid_bed_site(tile, main_component):
				return false
			JobManager.post(Job.Type.BUILD_BED, tile,
				BUILD_BED_PRIORITY, BUILD_BED_WORK_TICKS)
			return true
		DesignationMode.BUILD_WALL:
			var work_tile: Vector2i = _find_main_component_neighbor(tile, main_component)
			if work_tile.x < 0 or not _is_valid_build_site(tile, main_component):
				return false
			var job: Job = JobManager.post(Job.Type.BUILD_WALL, tile,
				BUILD_WALL_PRIORITY, BUILD_WALL_WORK_TICKS)
			if job == null:
				return false
			job.work_tile = work_tile
			# Treat future wall cells as blocked for A*; shove pawns who stand on them.
			_world.pathfinder.set_job_construction_reservation(
				tile.x, tile.y, true, _world.data
			)
			_world.kick_occupants_off_reserved_build_tile(tile.x, tile.y)
			_world.notify_pawns_nav_changed()
			return true
		DesignationMode.BUILD_DOOR:
			if not _is_valid_door_site(tile, main_component):
				return false
			var fdoor: int = _world.data.get_feature(tile.x, tile.y)
			var wtd: Vector2i
			if fdoor == TileFeature.Type.WALL:
				wtd = _find_main_component_neighbor(tile, main_component)
				if wtd.x < 0:
					return false
			else:
				wtd = tile
			var jdoor: Job = JobManager.post(Job.Type.BUILD_DOOR, tile,
				BUILD_DOOR_PRIORITY, BUILD_DOOR_WORK_TICKS)
			if jdoor == null:
				return false
			jdoor.work_tile = wtd
			return true
	return false


## True if a tile is inside any stockpile zone (including the 3x3 seed pile).
func _tile_covered_by_any_stockpile(t: Vector2i) -> bool:
	for z in StockpileManager.zones():
		if z.contains_tile(t):
			return true
	return false


## Same predicate used by every player-stampable build (walls, doors, ad-hoc
## beds outside the auto-placer). Tile must be on the main landmass, passable
## right now, empty of other features, and not already in the job queue.
func _is_valid_build_site(t: Vector2i, main_component: int) -> bool:
	if not _world.data.in_bounds(t.x, t.y):
		return false
	if _tile_covered_by_any_stockpile(t):
		return false
	if not _world.pathfinder.is_passable(t):
		return false
	if _world.pathfinder.component_of(t) != main_component:
		return false
	if _world.data.get_feature(t.x, t.y) != TileFeature.Type.NONE:
		return false
	if JobManager.has_job_at(t):
		return false
	return true


## Door on empty passable land, OR door-to-replace (existing WALL). Wall
## tiles read as impassable in the pathfinder, so we do NOT require
## is_passable(t) for WALL — instead we require a passable work neighbor on
## the main landmass (worker stands there), same as wall construction.
func _is_valid_door_site(t: Vector2i, main_component: int) -> bool:
	if not _world.data.in_bounds(t.x, t.y):
		return false
	if _tile_covered_by_any_stockpile(t):
		return false
	if JobManager.has_job_at(t):
		return false
	if not Biome.is_passable(_world.data.get_biome(t.x, t.y)):
		return false
	var f: int = _world.data.get_feature(t.x, t.y)
	if f == TileFeature.Type.WALL:
		return _find_main_component_neighbor(t, main_component).x >= 0
	if f != TileFeature.Type.NONE:
		return false
	if not _world.pathfinder.is_passable(t):
		return false
	if _world.pathfinder.component_of(t) != main_component:
		return false
	return true


func _queue_designation_redraw() -> void:
	if _preview_layer != null and is_instance_valid(_preview_layer):
		_preview_layer.queue_redraw()


## Called from BuildPreviewOverlay (above the world sprite) so previews show.
func draw_designation_previews_on(ci: CanvasItem) -> void:
	if _world == null or ci == null:
		return
	if _designation_mode == DesignationMode.NONE:
		return
	# Resolve the rect we're previewing. During an active drag it's
	# drag_start..drag_current; otherwise it's a 1x1 cursor hint at the
	# currently hovered tile so the player can see where a drag would start.
	var a: Vector2i = _drag_start if _is_dragging else _hover_tile
	var b: Vector2i = _drag_current if _is_dragging else _hover_tile
	if a.x < 0 or b.x < 0:
		return
	var rect: Rect2i = _normalize_rect(a, b)
	if _designation_mode == DesignationMode.DESIGNATE_ZONE:
		_draw_zone_preview(rect, ci)
	else:
		_draw_build_preview(rect, ci)


## Tinted solid rectangle for a pending Stockpile zone.
func _draw_zone_preview(rect: Rect2i, ci: CanvasItem) -> void:
	var area: Rect2 = _tiles_rect_to_world_rect(rect)
	var fill: Color = Stockpile.FILTER_FILL.get(_zone_next_filter, Color(0.9, 0.8, 0.3, 0.35))
	fill.a = 0.45
	ci.draw_rect(area, fill, true)
	ci.draw_rect(area.grow(0.5), Color(1, 1, 1, 0.90), false, 1.2)


## Per-tile blueprint preview for Bed / Wall / Door drags. We tint each tile
## individually (green if it's a valid site, red if not) so the player can
## see which squares in a wide rect will actually become jobs.
func _draw_build_preview(rect: Rect2i, ci: CanvasItem) -> void:
	var feature: int = _blueprint_feature_for_mode()
	var base_fill: Color = TileFeature.COLORS[feature]
	var main_component: int = _world.pathfinder.largest_component_id()
	var tile_size := Vector2(World.TILE_PIXELS, World.TILE_PIXELS)
	var half: Vector2 = tile_size * 0.5
	for dy in range(rect.size.y):
		for dx in range(rect.size.x):
			var t := Vector2i(rect.position.x + dx, rect.position.y + dy)
			var center: Vector2 = _world.tile_to_world(t)
			var tile_rect := Rect2(center - half, tile_size)
			var valid: bool = _preview_tile_valid(t, main_component)
			var fill: Color = base_fill if valid else Color(0.85, 0.25, 0.25)
			fill.a = 0.55 if valid else 0.35
			ci.draw_rect(tile_rect, fill, true)
	# Bright outline around the whole drag so the extents pop, plus a thin
	# outline only on the perimeter if we're dragging so the bounds are
	# readable even when every cell is tinted.
	var area: Rect2 = _tiles_rect_to_world_rect(rect)
	ci.draw_rect(area.grow(0.5), Color(1, 1, 1, 0.85), false, 1.0)


## True if a tile in a build-mode drag rect would accept a job. Mirrors the
## checks done during commit, lightweight enough to run every frame during
## a drag (we cap drag size at BUILD_DRAG_MAX_TILES).
func _preview_tile_valid(t: Vector2i, main_component: int) -> bool:
	if not _world.data.in_bounds(t.x, t.y):
		return false
	match _designation_mode:
		DesignationMode.BUILD_BED:
			return _is_valid_bed_site(t, main_component)
		DesignationMode.BUILD_WALL:
			if _find_main_component_neighbor(t, main_component).x < 0:
				return false
			return _is_valid_build_site(t, main_component)
		DesignationMode.BUILD_DOOR:
			return _is_valid_door_site(t, main_component)
	return false


## Convert a tile-space Rect2i into a world-space Rect2 bounding box. We
## subtract half a tile because World.tile_to_world returns the TILE CENTER.
func _tiles_rect_to_world_rect(rect: Rect2i) -> Rect2:
	var tile_size := Vector2(World.TILE_PIXELS, World.TILE_PIXELS)
	var half: Vector2 = tile_size * 0.5
	var top_left_world: Vector2 = _world.tile_to_world(rect.position) - half
	return Rect2(top_left_world, Vector2(rect.size.x * World.TILE_PIXELS, rect.size.y * World.TILE_PIXELS))


func _blueprint_feature_for_mode() -> int:
	match _designation_mode:
		DesignationMode.BUILD_BED:  return TileFeature.Type.BED
		DesignationMode.BUILD_WALL: return TileFeature.Type.WALL
		DesignationMode.BUILD_DOOR: return TileFeature.Type.DOOR
	return TileFeature.Type.NONE


func _reroll_world() -> void:
	JobManager.clear_all()
	_set_designation_mode(DesignationMode.NONE)
	# The current selection is about to be invalidated when pawns are freed.
	# Drop it now so the panel hides cleanly instead of poking dead nodes.
	_set_selected_pawn(null)
	# Wipe every registered zone + free the Node2Ds. Pawns holding a
	# reference to a zone via _target_zone will fall back to nearest-
	# reachable via StockpileManager on the next tick.
	_tear_down_all_zones()
	_world.generate(randi())
	var main_component: int = _world.pathfinder.largest_component_id()
	# Place the stockpile BEFORE respawning pawns, so every pawn sees a valid
	# stockpile reference the first time it ticks.
	_place_stockpile(main_component)
	_pawn_spawner.respawn(_world, main_component)
	_seed_jobs_from_world()
	_react_to_mining_progress()
	if _hud != null:
		_hud.bind(_world, _pawn_spawner)


## Walk the world's feature grid and post initial jobs. Only features on the
## main landmass are considered -- unreachable ones stay dormant until a
## future designation UI lets the player explicitly queue them.
## MINE jobs resolve a work_tile: the passable neighbor the pawn stands on
## while mining. Ore with no reachable neighbor is skipped.
func _seed_jobs_from_world() -> void:
	var main_component: int = _world.pathfinder.largest_component_id()
	var forage_tiles: Array[Vector2i] = []
	var mine_tiles: Array[Vector2i] = []
	var chop_tiles: Array[Vector2i] = []
	var hunt_tiles: Array[Vector2i] = []
	for y in range(WorldData.HEIGHT):
		for x in range(WorldData.WIDTH):
			var f: int = _world.data.get_feature(x, y)
			if f == TileFeature.Type.FERTILE_SOIL:
				forage_tiles.append(Vector2i(x, y))
			elif f == TileFeature.Type.ORE_VEIN:
				mine_tiles.append(Vector2i(x, y))
			elif f == TileFeature.Type.TREE:
				chop_tiles.append(Vector2i(x, y))
			elif TileFeature.is_wildlife(f):
				hunt_tiles.append(Vector2i(x, y))
	forage_tiles.shuffle()
	mine_tiles.shuffle()
	chop_tiles.shuffle()
	hunt_tiles.shuffle()
	var forage_posted: int = 0
	var forage_skipped: int = 0
	var mine_posted: int = 0
	var mine_skipped: int = 0
	var chop_posted: int = 0
	var chop_skipped: int = 0
	var hunt_posted: int = 0
	var hunt_skipped: int = 0
	for tile in forage_tiles:
		if forage_posted >= MAX_FORAGE_JOBS:
			break
		if _world.pathfinder.component_of(tile) != main_component:
			forage_skipped += 1
			continue
		JobManager.post(Job.Type.FORAGE, tile, FORAGE_PRIORITY, FORAGE_WORK_TICKS)
		forage_posted += 1
	for tile in mine_tiles:
		if mine_posted >= MAX_MINE_JOBS:
			break
		var work_tile: Vector2i = _world.pathfinder.find_adjacent_passable(tile)
		if work_tile.x < 0 or _world.pathfinder.component_of(work_tile) != main_component:
			mine_skipped += 1
			continue
		var job: Job = JobManager.post(Job.Type.MINE, tile, MINE_PRIORITY, MINE_WORK_TICKS)
		if job == null:
			continue
		job.work_tile = work_tile
		mine_posted += 1
	# CHOP: trees stand on passable tiles, so work_tile = the tree tile itself
	# (forage-style). The pawn walks onto the tree to chop it.
	for tile in chop_tiles:
		if chop_posted >= MAX_CHOP_JOBS:
			break
		if _world.pathfinder.component_of(tile) != main_component:
			chop_skipped += 1
			continue
		JobManager.post(Job.Type.CHOP, tile, CHOP_PRIORITY, CHOP_WORK_TICKS)
		chop_posted += 1
	# HUNT: animals also stand on passable tiles -- the pawn walks onto the
	# tile to hunt them, like CHOP. work_tile defaults to tile (Job.gd default).
	for tile in hunt_tiles:
		if hunt_posted >= MAX_HUNT_JOBS:
			break
		if _world.pathfinder.component_of(tile) != main_component:
			hunt_skipped += 1
			continue
		var feat: int = _world.data.get_feature(tile.x, tile.y)
		JobManager.post(Job.Type.HUNT, tile, HUNT_PRIORITY, _hunt_ticks_for(feat))
		hunt_posted += 1
	print("[Main] Seeded jobs: %d forage, %d mine, %d chop, %d hunt  (pool: %d fertile / %d ore / %d tree / %d wildlife; skipped: F%d M%d C%d H%d off-mainland)" %
		[forage_posted, mine_posted, chop_posted, hunt_posted,
		 forage_tiles.size(), mine_tiles.size(), chop_tiles.size(), hunt_tiles.size(),
		 forage_skipped, mine_skipped, chop_skipped, hunt_skipped])


## Work ticks for a hunt depend on how big the prey is. Anything we don't
## recognize falls back to the rabbit budget so we always return something
## sensible (defensive against future wildlife additions).
static func _hunt_ticks_for(feature: int) -> int:
	if feature == TileFeature.Type.DEER:
		return HUNT_DEER_WORK_TICKS
	return HUNT_RABBIT_WORK_TICKS


## Post hunting jobs for live animals (called each tick to keep jobs in sync with moving animals).
func _post_hunting_jobs_for_animals() -> void:
	if _animal_spawner == null or _animal_spawner.animals.is_empty():
		return
	
	var main_component: int = _world.pathfinder.largest_component_id()
	var hunt_jobs_posted: int = 0
	
	for animal in _animal_spawner.animals:
		if not is_instance_valid(animal) or animal == null:
			continue
		
		var tile: Vector2i = animal.tile_pos
		if _world.pathfinder.component_of(tile) != main_component:
			continue
		
		# Check if there's already a HUNT job for this animal's tile
		var has_job: bool = false
		for job in JobManager.jobs:
			if job != null and job.type == Job.Type.HUNT and job.tile == tile and job.state == Job.State.OPEN:
				has_job = true
				break
		
		# If no job exists, post one
		if not has_job and hunt_jobs_posted < MAX_HUNT_JOBS:
			var animal_type: int = animal.animal_type
			var work_ticks: int = HUNT_RABBIT_WORK_TICKS if animal_type == Animal.Type.RABBIT else HUNT_DEER_WORK_TICKS
			JobManager.post(Job.Type.HUNT, tile, HUNT_PRIORITY, work_ticks)
			hunt_jobs_posted += 1


## Same idea for regrowth: each species respawns on its own timer.
static func _regrow_ticks_for(feature: int) -> int:
	if feature == TileFeature.Type.DEER:
		return DEER_REGROW_TICKS
	return RABBIT_REGROW_TICKS


## Called whenever any job finishes. Rebuilds the picture of what's reachable
## now (mining can unlock sealed ore) and queues regrowth for harvested
## renewable resources.
func _on_job_completed(job: Job) -> void:
	if job == null:
		return
	match job.type:
		Job.Type.MINE, Job.Type.MINE_WALL:
			_react_to_mining_progress()
		Job.Type.FORAGE:
			_queue_regrowth(job.tile, TileFeature.Type.FERTILE_SOIL, FORAGE_REGROW_TICKS)
		Job.Type.CHOP:
			_queue_regrowth(job.tile, TileFeature.Type.TREE, TREE_REGROW_TICKS)
		Job.Type.HUNT:
			# By the time we get here Pawn._complete_current_job has already
			# cleared the feature, so we can't read the species off the tile
			# anymore. We use the job's planned work_ticks_needed as a proxy:
			# deer hunts are scheduled longer than rabbit hunts, so >= the
			# deer threshold means it was a deer. Cheap, robust, and good
			# enough until we add explicit per-job metadata.
			var species: int = TileFeature.Type.DEER \
				if job.work_ticks_needed >= HUNT_DEER_WORK_TICKS \
				else TileFeature.Type.RABBIT
			_queue_regrowth(job.tile, species, _regrow_ticks_for(species))


# ==================== regrowth ====================

func _queue_regrowth(tile: Vector2i, feature: int, delay_ticks: int) -> void:
	_regrow_queue.append({
		"tile": tile,
		"feature": feature,
		"ready_tick": GameManager.tick_count + delay_ticks,
	})


## Walk the regrow queue and resurrect any feature whose timer has expired.
## Iterating backwards so we can remove in place.
func _process_regrowth(tick: int) -> void:
	if _regrow_queue.is_empty():
		return
	var i: int = _regrow_queue.size() - 1
	while i >= 0:
		var entry: Dictionary = _regrow_queue[i]
		if entry.ready_tick <= tick:
			_restore_feature(entry.tile, entry.feature)
			_regrow_queue.remove_at(i)
		i -= 1


## Re-place a feature on its original tile, then post the matching job so a
## pawn will harvest it again. Skips silently if the tile is no longer a
## valid host (something else built there, biome was mined out, etc.).
func _restore_feature(tile: Vector2i, feature: int) -> void:
	if not _world.data.in_bounds(tile.x, tile.y):
		return
	# Tile already has something else? Drop the regrowth -- player intent
	# wins (e.g. a future bed sitting on this spot).
	if _world.data.get_feature(tile.x, tile.y) != TileFeature.Type.NONE:
		return
	# Validate biome compatibility -- e.g. trees need plains/forest, fertile
	# soil also needs plains/forest. If the biome was mined out (mountain ->
	# stone floor) we just drop the regrowth.
	var biome: int = _world.data.get_biome(tile.x, tile.y)
	if not _is_biome_compatible(feature, biome):
		return
	if not _world.set_feature(tile.x, tile.y, feature):
		return
	# Repost the matching harvest job, but only if the tile is reachable.
	var main_component: int = _world.pathfinder.largest_component_id()
	if _world.pathfinder.component_of(tile) != main_component:
		return
	if JobManager.has_job_at(tile):
		return
	match feature:
		TileFeature.Type.FERTILE_SOIL:
			JobManager.post(Job.Type.FORAGE, tile, FORAGE_PRIORITY, FORAGE_WORK_TICKS)
		TileFeature.Type.TREE:
			JobManager.post(Job.Type.CHOP, tile, CHOP_PRIORITY, CHOP_WORK_TICKS)
		TileFeature.Type.RABBIT, TileFeature.Type.DEER:
			JobManager.post(Job.Type.HUNT, tile, HUNT_PRIORITY, _hunt_ticks_for(feature))


static func _is_biome_compatible(feature: int, biome: int) -> bool:
	match feature:
		TileFeature.Type.FERTILE_SOIL:
			return biome == Biome.Type.PLAINS or biome == Biome.Type.FOREST
		TileFeature.Type.TREE:
			return biome == Biome.Type.PLAINS or biome == Biome.Type.FOREST
		TileFeature.Type.RABBIT, TileFeature.Type.DEER:
			return biome == Biome.Type.PLAINS or biome == Biome.Type.FOREST
	return false


## Re-seed jobs reactively after the map's reachability has changed (something
## was mined out). Two responsibilities:
##   1. Any ORE_VEIN that is now reachable but has no job -> post a MINE job.
##   2. If we have headroom, post one more MINE_WALL aimed at the closest
##      still-sealed ore vein, so colonies autonomously dig toward resources.
func _react_to_mining_progress() -> void:
	var pf: PathFinder = _world.pathfinder
	var main_component: int = pf.largest_component_id()
	if main_component < 0:
		return

	# 1. Newly-reachable ore -> MINE jobs.
	var newly_minable: int = 0
	for y in range(WorldData.HEIGHT):
		for x in range(WorldData.WIDTH):
			var f: int = _world.data.get_feature(x, y)
			if f != TileFeature.Type.ORE_VEIN:
				continue
			var ore_tile := Vector2i(x, y)
			if JobManager.has_job_at(ore_tile):
				continue
			var work_tile: Vector2i = pf.find_adjacent_passable(ore_tile)
			if work_tile.x < 0 or pf.component_of(work_tile) != main_component:
				continue
			var job: Job = JobManager.post(Job.Type.MINE, ore_tile, MINE_PRIORITY, MINE_WORK_TICKS)
			if job == null:
				continue
			job.work_tile = work_tile
			newly_minable += 1

	# 2. Top up MINE_WALL jobs up to the cap, each aimed at a different sealed ore.
	var active_walls: int = JobManager.active_count_of_type(Job.Type.MINE_WALL)
	var posted_walls: int = 0
	while active_walls < MAX_ACTIVE_MINE_WALL_JOBS:
		var wall_tile: Vector2i = _find_next_tunnel_target(main_component)
		if wall_tile.x < 0:
			break
		# work_tile = a passable main-component neighbor of the wall tile.
		var work_tile: Vector2i = _find_main_component_neighbor(wall_tile, main_component)
		if work_tile.x < 0:
			break
		var job: Job = JobManager.post(Job.Type.MINE_WALL, wall_tile, MINE_WALL_PRIORITY, MINE_WALL_WORK_TICKS)
		if job == null:
			break  # tile already has a job (defensive); stop to avoid an infinite loop
		job.work_tile = work_tile
		active_walls += 1
		posted_walls += 1

	if newly_minable > 0 or posted_walls > 0:
		print("[Main] React: +%d MINE  +%d MINE_WALL  (active walls=%d)" % [
			newly_minable, posted_walls, active_walls
		])


## Multi-source BFS starting from every still-sealed ORE_VEIN, expanding only
## through MOUNTAIN tiles. The first time the frontier touches a tile in
## main_component we know the previous (mountain) tile is the wall to mine
## next. Returns Vector2i(-1,-1) if there are no sealed ores or none can be
## tunneled to.
func _find_next_tunnel_target(main_component: int) -> Vector2i:
	var pf: PathFinder = _world.pathfinder
	var width: int = WorldData.WIDTH
	var height: int = WorldData.HEIGHT
	var visited: PackedByteArray = PackedByteArray()
	visited.resize(WorldData.TILE_COUNT)
	var queue: Array[Vector2i] = []

	# Seed the BFS with every ore vein that doesn't already have a passable
	# main-component neighbor. Those without an adjacent floor are the ones we
	# need to tunnel to. Skip ores that already have a job posted at their
	# tile (otherwise we'd queue redundant tunnels toward them).
	for y in range(height):
		for x in range(width):
			var i: int = y * width + x
			if _world.data.features[i] != TileFeature.Type.ORE_VEIN:
				continue
			var t := Vector2i(x, y)
			if JobManager.has_job_at(t):
				continue
			var adj: Vector2i = pf.find_adjacent_passable(t)
			if adj.x >= 0 and pf.component_of(adj) == main_component:
				continue  # already mineable; not a tunnel target
			queue.append(t)
			visited[i] = 1

	if queue.is_empty():
		return Vector2i(-1, -1)

	var head: int = 0
	var offsets := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while head < queue.size():
		var t: Vector2i = queue[head]
		head += 1
		for off in offsets:
			var n: Vector2i = t + off
			if n.x < 0 or n.x >= width or n.y < 0 or n.y >= height:
				continue
			var ni: int = n.y * width + n.x
			if visited[ni] != 0:
				continue
			var nbiome: int = _world.data.biomes[ni]
			if nbiome == Biome.Type.MOUNTAIN:
				visited[ni] = 1
				queue.append(n)
			elif Biome.is_passable(nbiome) and pf.component_of(n) == main_component:
				# Frontier touched the colony. `t` is a mountain tile bordering
				# main_component along the shortest tunnel from the closest ore.
				# But: skip if a job is already pending on `t`, and try the
				# next BFS step instead by marking visited and continuing.
				if JobManager.has_job_at(t):
					visited[ni] = 1  # don't re-discover from this side
					continue
				return t
			else:
				visited[ni] = 1  # water / wrong component / etc; don't expand
	return Vector2i(-1, -1)


## Find any 4-way passable neighbor of `tile` that belongs to `main_component`.
## Used to choose the standing tile for a MINE_WALL job. Returns (-1,-1) if
## none exists (which means the tunnel target wasn't actually on the frontier).
func _find_main_component_neighbor(tile: Vector2i, main_component: int) -> Vector2i:
	var pf: PathFinder = _world.pathfinder
	for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = tile + off
		if not _world.data.in_bounds(n.x, n.y):
			continue
		if not pf.is_passable(n):
			continue
		if pf.component_of(n) == main_component:
			return n
	return Vector2i(-1, -1)


# ==================== beds (player designation) ====================

## Hotkey B: stamp BEDS_PER_DESIGNATION new BUILD_BED jobs on the closest
## passable empty tiles to the stockpile. Skips tiles already occupied by
## the stockpile itself, an existing feature, an active job, or a bed we
## already built. Cheap O(R^2) scan -- R defaults to 6.
func _designate_beds_near_stockpile() -> void:
	if _world == null or _world.stockpile == null:
		print("[Main] Can't designate beds: no stockpile yet.")
		return
	var center: Vector2i = _world.stockpile.tile
	var main_component: int = _world.pathfinder.largest_component_id()
	# Collect candidate tiles, sorted by Chebyshev distance from the stockpile
	# so the first beds land in the closest slots.
	var candidates: Array = []
	for dy in range(-BED_SCAN_RADIUS, BED_SCAN_RADIUS + 1):
		for dx in range(-BED_SCAN_RADIUS, BED_SCAN_RADIUS + 1):
			if dx == 0 and dy == 0:
				continue
			var t := Vector2i(center.x + dx, center.y + dy)
			if not _is_valid_bed_site(t, main_component):
				continue
			candidates.append({"tile": t, "d": max(abs(dx), abs(dy))})
	candidates.sort_custom(func(a, b): return a.d < b.d)

	var posted: int = 0
	for c in candidates:
		if posted >= BEDS_PER_DESIGNATION:
			break
		var job: Job = JobManager.post(Job.Type.BUILD_BED, c.tile,
			BUILD_BED_PRIORITY, BUILD_BED_WORK_TICKS)
		if job == null:
			continue
		posted += 1
	if posted == 0:
		print("[Main] B: no eligible bed sites within %d tiles of the stockpile." %
			BED_SCAN_RADIUS)
	else:
		print("[Main] B: designated %d new bed site(s) near (%d,%d). Pawns will fetch wood (%d each) and build." %
			[posted, center.x, center.y, Pawn.BED_WOOD_COST])


func _is_valid_bed_site(t: Vector2i, main_component: int) -> bool:
	if not _world.data.in_bounds(t.x, t.y):
		return false
	# Don't plant a bed inside any stockpile zone; you wouldn't build a bunk
	# in the middle of the pantry. Scans every zone, but N is small so this
	# stays cheap.
	for z in StockpileManager.zones():
		if z.contains_tile(t):
			return false
	if not _world.pathfinder.is_passable(t):
		return false
	if _world.pathfinder.component_of(t) != main_component:
		return false
	if _world.data.get_feature(t.x, t.y) != TileFeature.Type.NONE:
		return false
	if JobManager.has_job_at(t):
		return false
	return true


func _print_stockpile() -> void:
	var zones: Array[Stockpile] = StockpileManager.zones()
	if zones.is_empty():
		print("[Stockpile] (no zones)")
		return
	print("[Stockpile] %d zone(s):" % zones.size())
	for z in zones:
		var parts: Array[String] = []
		for it in z.inventory:
			parts.append("%s=%d" % [Item.name_for(it), z.inventory[it]])
		var inv_str: String = " ".join(parts) if not parts.is_empty() else "empty"
		print("  - %s @%s (%dx%d)  %s" % [
			Stockpile.FILTER_NAME.get(z.filter, "?"),
			z.rect.position, z.rect.size.x, z.rect.size.y, inv_str
		])


# ==================== save / load (F5 / F8) ====================

func _colony_save() -> void:
	var snapshot: Dictionary = _build_save_dict()
	var err: Error = GameSave.write_file(GameSave.get_save_path(), snapshot)
	if err == OK:
		print("[Main] Saved colony -> %s" % GameSave.get_save_path())
	else:
		push_error("[Main] Save failed (code %d)" % err)


func _colony_load() -> void:
	var d: Dictionary = GameSave.read_file(GameSave.get_save_path())
	if d.is_empty():
		print("[Main] No save at %s" % GameSave.get_save_path())
		return
	if int(d.get("v", 0)) != GameSave.SAVE_VERSION:
		print("[Main] Save version mismatch: got v=%d, need v=%d" % [
			int(d.get("v", 0)), GameSave.SAVE_VERSION])
		return
	_apply_save_dict(d)
	print("[Main] Loaded colony from %s" % GameSave.get_save_path())


func _build_save_dict() -> Dictionary:
	var pawns_s: Array = []
	for p in _pawn_spawner.pawns:
		if p != null and is_instance_valid(p):
			pawns_s.append(p.data.to_save_dict())
	return {
		"v": GameSave.SAVE_VERSION,
		"tick": GameManager.tick_count,
		"game_speed": GameManager.game_speed,
		"is_paused": GameManager.is_paused,
		"world": _world.data.to_save_dict(),
		"zones": _save_stockpiles_to_array(),
		"pawns": pawns_s,
		"regrow": _save_regrow_queue(),
		"zone_filter": _zone_next_filter,
	}


func _save_stockpiles_to_array() -> Array:
	var out: Array = []
	for z in StockpileManager.zones():
		var inv: Dictionary = {}
		for it in z.inventory:
			inv[str(int(it))] = int(z.inventory[it])
		out.append({
			"x": z.rect.position.x, "y": z.rect.position.y,
			"w": z.rect.size.x, "h": z.rect.size.y,
			"filter": z.filter,
			"inv": inv,
		})
	return out


func _save_regrow_queue() -> Array:
	var out: Array = []
	for e in _regrow_queue:
		if e is Dictionary and e.has("tile"):
			var te: Vector2i = e.tile
			out.append({
				"tile_x": te.x, "tile_y": te.y,
				"feature": int(e.get("feature", 0)),
				"ready_tick": int(e.get("ready_tick", 0)),
			})
	return out


func _apply_save_dict(s: Dictionary) -> void:
	var wdata: Variant = WorldData.from_save_dict(s.get("world", {}))
	if wdata == null or not (wdata is WorldData):
		push_error("[Main] Load failed: world data missing or invalid. Colony unchanged.")
		return

	JobManager.clear_all()
	_set_designation_mode(DesignationMode.NONE)
	_cancel_drag()
	_set_selected_pawn(null)
	_regrow_queue.clear()
	_tear_down_all_zones()
	_pawn_spawner.clear_pawns()

	_world.load_world_data(wdata as WorldData)
	GameManager.set_state_from_load(
		int(s.get("tick", 0)),
		float(s.get("game_speed", 1.0)),
		bool(s.get("is_paused", false))
	)
	_zone_next_filter = int(s.get("zone_filter", 0))
	_push_zone_filter_label_to_toolbar()
	var zlist: Array = s.get("zones", [])
	if zlist is Array and not zlist.is_empty():
		_restore_stockpiles_from_save(zlist)
	else:
		_place_stockpile(_world.pathfinder.largest_component_id())
	PawnData._next_id = 1
	for pd in s.get("pawns", []):
		if pd is Dictionary:
			var pdat: PawnData = PawnData.from_save_dict(pd)
			_pawn_spawner.spawn_from_data(pdat, _world)
	_regrow_queue.clear()
	for e in s.get("regrow", []):
		if e is Dictionary:
			_regrow_queue.append({
				"tile": Vector2i(int(e.get("tile_x", 0)), int(e.get("tile_y", 0))),
				"feature": int(e.get("feature", 0)),
				"ready_tick": int(e.get("ready_tick", 0)),
			})
	_seed_jobs_from_world()
	_react_to_mining_progress()
	if _hud != null:
		_hud.bind(_world, _pawn_spawner)
	if is_instance_valid(_day_night):
		_day_night.sync_to_tick(GameManager.tick_count)


func _restore_stockpiles_from_save(zones_data: Array) -> void:
	for zd in zones_data:
		if not (zd is Dictionary):
			continue
		var d: Dictionary = zd
		var r: Rect2i = Rect2i(
			int(d.get("x", 0)), int(d.get("y", 0)),
			int(d.get("w", 1)), int(d.get("h", 1))
		)
		var sp: Stockpile = STOCKPILE_SCENE.instantiate() as Stockpile
		if sp == null:
			continue
		sp.set_filter(int(d.get("filter", Stockpile.Filter.ALL)))
		sp.set_rect_tiles(r)
		sp.position = _world.tile_to_world(r.position)
		sp.inventory = {}
		var inv: Dictionary = d.get("inv", {})
		if inv is Dictionary:
			for key in inv:
				sp.inventory[int(key)] = int(inv[key])
		add_child(sp)
		if _world.stockpile == null:
			_world.stockpile = sp
		StockpileManager.register(sp)
		sp.queue_redraw()
