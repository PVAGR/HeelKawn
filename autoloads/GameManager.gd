extends Node

## Emitted once per simulation tick. All simulation systems should listen to this
## instead of running on _process, so pause/speed affects everything uniformly.
signal game_tick(tick_count: int)

## Emitted whenever the speed or pause state changes. UI can listen to update icons.
signal speed_changed(new_speed: float, is_paused: bool)

## Real seconds per tick at 1x speed. Your brief: 0.1s real = 1 in-game hour.
const TICK_INTERVAL_SECONDS: float = 0.1

## Allowed speed multipliers. Index into this with set_speed_index(). 12x is the
## "overnight farming" tier -- fine for running an established colony, but at
## this rate a single _process frame can queue many sim ticks so any per-tick
## work (pathing, allocations) amplifies. Keep hot paths cheap.
const SPEED_STEPS: Array[float] = [1.0, 3.0, 6.0, 12.0]

var game_speed: float = 1.0
var is_paused: bool = false
var tick_count: int = 0

var _tick_accumulator: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if is_paused:
		return
	_tick_accumulator += delta * game_speed
	while _tick_accumulator >= TICK_INTERVAL_SECONDS:
		_tick_accumulator -= TICK_INTERVAL_SECONDS
		tick_count += 1
		game_tick.emit(tick_count)


func set_speed(new_speed: float) -> void:
	game_speed = max(new_speed, 0.0001)
	is_paused = false
	speed_changed.emit(game_speed, is_paused)


func set_speed_index(i: int) -> void:
	if i < 0 or i >= SPEED_STEPS.size():
		return
	set_speed(SPEED_STEPS[i])


func pause() -> void:
	if is_paused:
		return
	is_paused = true
	speed_changed.emit(game_speed, is_paused)


func resume() -> void:
	if not is_paused:
		return
	is_paused = false
	speed_changed.emit(game_speed, is_paused)


func toggle_pause() -> void:
	if is_paused:
		resume()
	else:
		pause()


## Used by `GameSave` on load. Preserves the loaded tick; resets accumulator
## so a save mid-frame doesn't double-fire the next sim step.
func set_state_from_load(tick: int, speed: float, paused: bool) -> void:
	tick_count = max(0, tick)
	_tick_accumulator = 0.0
	game_speed = max(speed, 0.0001)
	is_paused = paused
	speed_changed.emit(game_speed, is_paused)
