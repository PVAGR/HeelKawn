class_name DayNightCycle
extends CanvasModulate

## Tints the entire canvas layer based on in-game time. Drives off
## GameManager.game_tick so pause and speed multipliers behave automatically.
##
## NOTE ON UNITS: your brief said 1 tick ~ 1 in-game hour. A 24-tick day would
## be 2.4 real seconds at 1x, which is way too fast to see. We decouple visual
## day length from the tick-semantics value here: TICKS_PER_DAY controls the
## cycle's visual period. Tune this later once pawn schedules exist.
const TICKS_PER_DAY: int = 600   # 60s real at 1x, 10s at 6x

## Four key colors around the clock.
## Phase 0.00 = midnight, 0.25 = dawn, 0.50 = noon, 0.75 = dusk.
const COLOR_MIDNIGHT: Color = Color(0.32, 0.38, 0.58)
const COLOR_DAWN:     Color = Color(1.00, 0.75, 0.60)
const COLOR_NOON:     Color = Color(1.00, 1.00, 1.00)
const COLOR_DUSK:     Color = Color(1.00, 0.55, 0.42)

var _last_day: int = -1


func _ready() -> void:
	GameManager.game_tick.connect(_on_tick)
	_apply_for_tick(GameManager.tick_count)


func _on_tick(tick: int) -> void:
	_apply_for_tick(tick)
	var day: int = tick / TICKS_PER_DAY
	if day != _last_day:
		_last_day = day
		print("[DayNight] Day %d begins" % (day + 1))


## After loading a save: snap visuals + day counter to `tick` without re-printing
## spurious "Day 1" lines.
func sync_to_tick(tick: int) -> void:
	_last_day = tick / TICKS_PER_DAY
	_apply_for_tick(tick)


func _apply_for_tick(tick: int) -> void:
	var phase: float = float(tick % TICKS_PER_DAY) / float(TICKS_PER_DAY)
	color = _color_for_phase(phase)


## Phase boundaries used by gameplay (sleep schedule, future: nocturnal mobs).
## Anything in [NIGHT_START, 1) ∪ [0, NIGHT_END) is considered nighttime.
const NIGHT_START: float = 0.78  # late dusk
const NIGHT_END:   float = 0.22  # pre-dawn / early morning


## Static convenience: is the given tick during nighttime?
static func is_night_for_tick(tick: int) -> bool:
	var phase: float = float(tick % TICKS_PER_DAY) / float(TICKS_PER_DAY)
	return phase >= NIGHT_START or phase < NIGHT_END


## Instance accessor: is "right now" nighttime, according to GameManager's clock?
func is_night() -> bool:
	return is_night_for_tick(GameManager.tick_count)


static func _color_for_phase(t: float) -> Color:
	if t < 0.25:
		return COLOR_MIDNIGHT.lerp(COLOR_DAWN, t / 0.25)
	if t < 0.50:
		return COLOR_DAWN.lerp(COLOR_NOON, (t - 0.25) / 0.25)
	if t < 0.75:
		return COLOR_NOON.lerp(COLOR_DUSK, (t - 0.50) / 0.25)
	return COLOR_DUSK.lerp(COLOR_MIDNIGHT, (t - 0.75) / 0.25)
