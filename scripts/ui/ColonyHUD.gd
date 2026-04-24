class_name ColonyHUD
extends CanvasLayer

## Always-on heads-up display rendered in screen space (CanvasLayer = doesn't
## move with the camera). Refreshes every game tick so the numbers stay live
## without paying for a per-frame UI update at high speeds.
##
## Reads pawn list from PawnSpawner, stockpile from World, time + speed from
## GameManager, and job counts from JobManager (autoload).

const REFRESH_EVERY_N_TICKS: int = 1

const PANEL_BG: Color = Color(0.05, 0.06, 0.08, 0.78)
const PANEL_BORDER: Color = Color(0.85, 0.78, 0.40, 0.70)

# Tuned to be unobtrusive: thin top-left strip, easy to read, doesn't
# eat the world.
const FONT_SIZE_BODY: int = 11
const FONT_SIZE_HOTKEYS: int = 9
const PANEL_PAD_X: int = 6
const PANEL_PAD_Y: int = 4

const HOTKEY_HINTS: String = "SPACE pause · 1-4 speed · F5 save · F8 load · M labor stance · R reroll · T pawns · J jobs · I stockpile · B beds · W walls · O doors · Z zone · F filter · Esc cancel"

@onready var _panel: PanelContainer = $Panel
@onready var _label: RichTextLabel = $Panel/Margin/VBox/Body
@onready var _hotkeys: Label = $Panel/Margin/VBox/Hotkeys

var _world: World = null
var _spawner: PawnSpawner = null
## Empty string when no designation mode is active. Otherwise "Bed" / "Wall" / etc.
var _designation_label: String = ""


func _ready() -> void:
	# Pin top-left, leave a small inset.
	layer = 100
	GameManager.game_tick.connect(_on_tick)
	GameManager.speed_changed.connect(_on_speed_changed)
	JobManager.job_posted.connect(_on_jobs_changed)
	JobManager.job_completed.connect(_on_jobs_changed)
	JobManager.job_cancelled.connect(_on_jobs_changed)
	# Phase 10: aggregated totals come from StockpileManager. Refresh on zone
	# add/remove so the HUD shows the truth instantly instead of waiting for
	# the next tick.
	StockpileManager.zone_registered.connect(_on_zones_changed)
	StockpileManager.zone_unregistered.connect(_on_zones_changed)
	ColonySimServices.demand_snapshot.connect(_on_colony_demand)
	_apply_panel_style()
	_hotkeys.text = HOTKEY_HINTS
	_refresh()


## Called by Main once it has spawned the world + spawner.
func bind(world: World, spawner: PawnSpawner) -> void:
	_world = world
	_spawner = spawner
	_refresh()


## Called by Main whenever the player's build mode changes. Empty string =
## off. Anything else shows up as a colored banner above the stats lines.
func set_designation_mode(label: String) -> void:
	_designation_label = label
	_refresh()


# ==================== refresh hooks ====================

func _on_tick(tick: int) -> void:
	if tick % REFRESH_EVERY_N_TICKS == 0:
		_refresh()


func _on_speed_changed(_s: float, _p: bool) -> void:
	_refresh()


func _on_jobs_changed(_job: Job) -> void:
	_refresh()


func _on_zones_changed(_zone: Stockpile) -> void:
	_refresh()


func _on_colony_demand(_f: float, _h: float, _m: float, _ha: float) -> void:
	_refresh()


# ==================== layout / style ====================

func _apply_panel_style() -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(3)
	style.content_margin_left = PANEL_PAD_X
	style.content_margin_right = PANEL_PAD_X
	style.content_margin_top = PANEL_PAD_Y
	style.content_margin_bottom = PANEL_PAD_Y
	_panel.add_theme_stylebox_override("panel", style)
	_label.add_theme_font_size_override("normal_font_size", FONT_SIZE_BODY)
	_label.add_theme_font_size_override("bold_font_size", FONT_SIZE_BODY)
	_hotkeys.add_theme_font_size_override("font_size", FONT_SIZE_HOTKEYS)


# ==================== text ====================

func _refresh() -> void:
	if _label == null:
		return
	var lines: Array[String] = []
	if _designation_label != "":
		lines.append("[bgcolor=#583a14][color=#ffe082]  BUILD MODE: %s   (click or click-drag to place · right-click / Esc to cancel)  [/color][/bgcolor]" %
			_designation_label)
	lines.append(_time_line())
	lines.append(_colony_state_line())
	lines.append(_pawn_line())
	lines.append(_stockpile_line())
	lines.append(_jobs_line())
	_label.text = "\n".join(lines)


func _time_line() -> String:
	var tick: int = GameManager.tick_count
	var day_len: int = DayNightCycle.TICKS_PER_DAY
	var day: int = tick / day_len + 1
	var phase: float = float(tick % day_len) / float(day_len)
	var phase_name: String = _phase_name(phase)
	var speed_str: String = "PAUSED" if GameManager.is_paused else "%dx" % int(GameManager.game_speed)
	# In-game hour estimate: 24 in-game hours per visual day cycle.
	var hour: int = int(phase * 24.0) % 24
	return "[b]Day %d[/b]  %02d:00  %s   [color=#cccccc]Speed:[/color] [b]%s[/b]   [color=#888888]tick %d[/color]" % [
		day, hour, phase_name, speed_str, tick
	]


## Labor stance (M) + key demand metrics from `ColonySimServices`.
func _colony_state_line() -> String:
	var stance: String = ColonySimServices.get_stance_display()
	var fp: float = ColonySimServices.get_food_pressure()
	var hp: float = ColonySimServices.get_housing_pressure()
	return "[color=#c9b37c]Colony:[/color]  stance [b]%s[/b]  ·  food [b]%d%%[/b] %s  ·  housing [b]%d%%[/b] %s" % [
		stance,
		int(round(fp * 100.0)), _demand_tier(fp),
		int(round(hp * 100.0)), _demand_tier(hp),
	]


static func _demand_tier(p: float) -> String:
	# 0 = low pressure (good), 1 = high (bad) — show a one-word tag for scanability.
	if p < 0.25:
		return "[color=#8bc34a]ok[/color]"
	if p < 0.55:
		return "[color=#ffcc80]watch[/color]"
	return "[color=#e57373]high[/color]"


static func _phase_name(p: float) -> String:
	if p < 0.20:    return "Night"
	if p < 0.30:    return "Dawn"
	if p < 0.45:    return "Morning"
	if p < 0.55:    return "Noon"
	if p < 0.70:    return "Afternoon"
	if p < 0.80:    return "Dusk"
	return "Night"


func _pawn_line() -> String:
	if _spawner == null or _spawner.pawns.is_empty():
		return "[color=#cccccc]Pawns:[/color] (none)"
	var n: int = _spawner.pawns.size()
	var sum_h: float = 0.0
	var sum_r: float = 0.0
	var sum_m: float = 0.0
	var hungry: int = 0
	var tired: int = 0
	var sad: int = 0
	var sleeping: int = 0
	for p in _spawner.pawns:
		var d := p.data
		sum_h += d.hunger
		sum_r += d.rest
		sum_m += d.mood
		if d.hunger <= Pawn.THRESHOLD_WARN: hungry += 1
		if d.rest   <= Pawn.THRESHOLD_WARN: tired  += 1
		if d.mood   <= Pawn.THRESHOLD_WARN: sad    += 1
		if p.get_state() == Pawn.State.SLEEPING: sleeping += 1
	var avg_h: float = sum_h / float(n)
	var avg_r: float = sum_r / float(n)
	var avg_m: float = sum_m / float(n)
	return "[color=#cccccc]Pawns:[/color] [b]%d[/b]   H %s  R %s  M %s   %s%s%s%s" % [
		n,
		_color_value(avg_h), _color_value(avg_r), _color_value(avg_m),
		_alert_chip("hungry",  hungry,   "#e57373"),
		_alert_chip("tired",   tired,    "#ffd54f"),
		_alert_chip("sad",     sad,      "#90caf9"),
		_alert_chip("asleep",  sleeping, "#b39ddb"),
	]


func _stockpile_line() -> String:
	var zones: Array[Stockpile] = StockpileManager.zones()
	if zones.is_empty():
		return "[color=#cccccc]Stockpiles:[/color] (none)"
	# Sum item counts across every registered zone. We build a small dict of
	# type -> qty and render a chip for each non-zero entry.
	var totals: Dictionary = {}
	for z in zones:
		for t in z.inventory:
			totals[t] = totals.get(t, 0) + z.inventory[t]
	var parts: Array[String] = []
	# Keep the render order stable so the HUD doesn't flicker as the dict
	# hash ordering changes. Item.Type enum values are dense so iterating
	# over the enum keeps this cheap.
	for t in Item.Type.values():
		if t == Item.Type.NONE:
			continue
		var qty: int = totals.get(t, 0)
		if qty <= 0:
			continue
		parts.append("[color=%s]%s[/color] [b]%d[/b]" % [
			Item.color_for(t).to_html(false), Item.name_for(t), qty
		])
	var inv_text: String = " · ".join(parts) if not parts.is_empty() else "[color=#888888]empty[/color]"
	return "[color=#cccccc]Stockpiles (%d zone%s):[/color] %s" % [
		zones.size(), "" if zones.size() == 1 else "s", inv_text
	]


func _jobs_line() -> String:
	var s: Dictionary = JobManager.stats()
	var fw: int = JobManager.active_count_of_type(Job.Type.FORAGE)
	var mn: int = JobManager.active_count_of_type(Job.Type.MINE)
	var mw: int = JobManager.active_count_of_type(Job.Type.MINE_WALL)
	var ch: int = JobManager.active_count_of_type(Job.Type.CHOP)
	var hu: int = JobManager.active_count_of_type(Job.Type.HUNT)
	var bd: int = JobManager.active_count_of_type(Job.Type.BUILD_BED)
	var bw: int = JobManager.active_count_of_type(Job.Type.BUILD_WALL)
	var bo: int = JobManager.active_count_of_type(Job.Type.BUILD_DOOR)
	var beds_built: int = _world.bed_count() if _world != null else 0
	return "[color=#cccccc]Jobs:[/color] [b]%d[/b] open  [b]%d[/b] claimed   F %d · M %d · TM %d · C %d · H %d · B %d · W %d · D %d   [color=#dcb478]Beds[/color] [b]%d[/b]   [color=#888888](done %d)[/color]" % [
		s.open, s.claimed, fw, mn, mw, ch, hu, bd, bw, bo, beds_built, s.completed
	]


# ==================== formatting helpers ====================

static func _color_value(v: float) -> String:
	# Same thresholds the pawn AI uses, so the HUD agrees with the warn / crit
	# print spam.
	if v <= Pawn.THRESHOLD_CRIT:
		return "[color=#e57373][b]%2.0f[/b][/color]" % v   # red
	if v <= Pawn.THRESHOLD_WARN:
		return "[color=#ffd54f][b]%2.0f[/b][/color]" % v   # amber
	return "[color=#a5d6a7]%2.0f[/color]" % v               # green


static func _alert_chip(label: String, count: int, color_hex: String) -> String:
	if count <= 0:
		return ""
	return "[color=%s]%dx %s[/color]  " % [color_hex, count, label]
