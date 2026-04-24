class_name BuildToolbar
extends CanvasLayer

## Bottom-of-screen control bar so the player can play with the mouse instead
## of memorizing a wall of hotkeys. Two clusters:
##   - game speed: pause / 1x / 3x / 6x
##   - build mode: bed / wall / door / cancel
## Hotkeys still work; the toolbar just mirrors their state.

## Emitted when the player picks a build mode (including "0 = none/cancel").
## Main listens and routes through its own _set_designation_mode.
signal mode_requested(mode: int)

## Emitted when the player clicks a speed button. Index into SPEED_STEPS.
signal speed_index_requested(idx: int)

## Emitted when the player clicks pause. Main routes to GameManager.toggle_pause.
signal pause_toggled()

## Emitted when the player clicks the reroll button. Confirms via Main.
signal reroll_requested()

## Emitted when the player clicks the "Filter: X" cycle button. Main keeps
## the authoritative filter state (so keyboard F and button click agree) and
## pushes the new label back via set_zone_filter_label().
signal zone_filter_cycle_requested()

## Persist colony (F5) / restore last save (F8). Mirrors keyboard shortcuts.
signal save_requested()
signal load_requested()


# Keep these mode ints in sync with Main.DesignationMode.
const MODE_NONE: int = 0
const MODE_BED:  int = 1
const MODE_WALL: int = 2
const MODE_DOOR: int = 3
const MODE_ZONE: int = 4

const PANEL_BG:     Color = Color(0.05, 0.06, 0.08, 0.88)
const PANEL_BORDER: Color = Color(0.85, 0.78, 0.40, 0.65)
const ACCENT_BUILD: Color = Color8(255, 209, 102)  # warm amber for build cluster
const ACCENT_TIME:  Color = Color8(120, 200, 255)  # cool blue for time cluster
const ACCENT_ZONE:  Color = Color8(255, 180, 100)  # warm "pile" amber
const ACCENT_SAVE:  Color = Color8(100, 200, 140)  # save (disk)
const ACCENT_LOAD:  Color = Color8(200, 160, 100)  # load / recall

const FONT_SIZE_BUTTON: int = 12
const FONT_SIZE_LABEL:  int = 10

# ---- build mode entries ----
const BUILD_ENTRIES: Array = [
	{"label": "Bed",  "mode": MODE_BED,  "hotkey": "B", "swatch": Color8(220, 180, 120)},
	{"label": "Wall", "mode": MODE_WALL, "hotkey": "W", "swatch": Color8( 90,  60,  35)},
	{"label": "Door", "mode": MODE_DOOR, "hotkey": "O", "swatch": Color8(160, 100,  45)},
	{"label": "Zone", "mode": MODE_ZONE, "hotkey": "Z", "swatch": Color8(240, 200,  90)},
]


var _panel: PanelContainer = null
var _build_buttons: Dictionary = {}   # mode -> Button
var _cancel_button: Button = null
var _speed_buttons: Array = []        # parallel to GameManager.SPEED_STEPS
var _pause_button: Button = null
var _reroll_button: Button = null
var _filter_button: Button = null     # "Filter: All" cycle button for new zones

var _active_mode: int = MODE_NONE


func _ready() -> void:
	layer = 100  # above the world, in line with ColonyHUD
	_build_ui()
	GameManager.speed_changed.connect(_on_speed_changed)
	get_viewport().size_changed.connect(_recenter)
	_refresh_speed_buttons(GameManager.game_speed, GameManager.is_paused)


# ==================== layout ====================

func _build_ui() -> void:
	# Full-rect Control as anchor surface, doesn't eat input itself.
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	# STOP so clicks on the bar don't fall through and place a tile underneath.
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", _make_panel_style())
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",  10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top",   6)
	margin.add_theme_constant_override("margin_bottom", 6)
	_panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	margin.add_child(row)

	_build_speed_cluster(row)
	row.add_child(_make_separator())
	_build_build_cluster(row)
	row.add_child(_make_separator())
	_build_save_load_cluster(row)
	row.add_child(_make_separator())
	_reroll_button = _make_button("Reroll [R]", ACCENT_BUILD)
	_reroll_button.pressed.connect(func(): reroll_requested.emit())
	row.add_child(_reroll_button)

	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# Defer position so layout settles and we can read the actual minimum size.
	call_deferred("_recenter")


func _build_speed_cluster(row: HBoxContainer) -> void:
	var label := _make_cluster_label("Time")
	row.add_child(label)
	_pause_button = _make_button("Pause [Space]", ACCENT_TIME)
	_pause_button.toggle_mode = true
	_pause_button.pressed.connect(func(): pause_toggled.emit())
	row.add_child(_pause_button)
	_speed_buttons.clear()
	for i in range(GameManager.SPEED_STEPS.size()):
		var s: float = GameManager.SPEED_STEPS[i]
		var btn := _make_button("%dx [%d]" % [int(s), i + 1], ACCENT_TIME)
		btn.toggle_mode = true
		btn.pressed.connect(_on_speed_pressed.bind(i))
		_speed_buttons.append(btn)
		row.add_child(btn)


func _build_build_cluster(row: HBoxContainer) -> void:
	var label := _make_cluster_label("Build")
	row.add_child(label)
	_build_buttons.clear()
	for entry in BUILD_ENTRIES:
		var btn := _make_button("%s [%s]" % [entry.label, entry.hotkey], entry.swatch)
		_apply_build_tool_style(btn, entry.swatch)
		btn.toggle_mode = true
		btn.pressed.connect(_on_build_pressed.bind(entry.mode))
		_build_buttons[entry.mode] = btn
		row.add_child(btn)
	# Filter cycle button: shows what filter the next zone will get. Clickable
	# or press F to cycle. Disabled when not in Zone mode.
	_filter_button = _make_button("Filter: All [F]", ACCENT_ZONE)
	_filter_button.pressed.connect(func(): zone_filter_cycle_requested.emit())
	_filter_button.disabled = true
	row.add_child(_filter_button)
	_cancel_button = _make_button("Cancel [Esc]", Color8(180, 180, 180))
	_cancel_button.disabled = true
	_cancel_button.pressed.connect(func(): mode_requested.emit(MODE_NONE))
	row.add_child(_cancel_button)


func _build_save_load_cluster(row: HBoxContainer) -> void:
	var label := _make_cluster_label("Colony")
	row.add_child(label)
	var save_btn := _make_button("Save [F5]", ACCENT_SAVE)
	_apply_persist_button_style(save_btn, ACCENT_SAVE)
	save_btn.pressed.connect(func(): save_requested.emit())
	row.add_child(save_btn)
	var load_btn := _make_button("Load [F8]", ACCENT_LOAD)
	_apply_persist_button_style(load_btn, ACCENT_LOAD)
	load_btn.pressed.connect(func(): load_requested.emit())
	row.add_child(load_btn)


## Background + border so the active Bed/Wall/Door/Zone is as obvious as the speed row.
func _apply_build_tool_style(btn: Button, swatch: Color) -> void:
	var off := StyleBoxFlat.new()
	off.bg_color = Color(0.10, 0.11, 0.15, 0.88)
	off.set_border_width_all(1)
	off.border_color = Color(0.32, 0.33, 0.38, 0.55)
	off.set_corner_radius_all(3)
	var on := StyleBoxFlat.new()
	on.bg_color = Color(
		swatch.r * 0.22 + 0.04,
		swatch.g * 0.22 + 0.04,
		swatch.b * 0.22 + 0.04,
		0.95
	)
	on.set_border_width_all(2)
	on.border_color = swatch
	on.set_corner_radius_all(3)
	var hover := StyleBoxFlat.new()
	hover.bg_color = off.bg_color.lerp(swatch, 0.18)
	hover.set_border_width_all(1)
	hover.border_color = swatch.lerp(Color.WHITE, 0.3)
	hover.set_corner_radius_all(3)
	btn.add_theme_stylebox_override("normal", off)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", on)
	btn.add_theme_stylebox_override("hover_pressed", on)
	btn.add_theme_stylebox_override("focus", off)
	btn.add_theme_color_override("font_color", Color(0.9, 0.91, 0.94))
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_pressed_color", Color.WHITE)


func _apply_persist_button_style(btn: Button, accent: Color) -> void:
	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.09, 0.1, 0.13, 0.9)
	n.set_border_width_all(1)
	n.border_color = Color(accent.r, accent.g, accent.b, 0.45)
	n.set_corner_radius_all(3)
	var h := StyleBoxFlat.new()
	h.bg_color = n.bg_color.lerp(accent, 0.15)
	h.set_border_width_all(1)
	h.border_color = Color(accent.r, accent.g, accent.b, 0.8)
	h.set_corner_radius_all(3)
	var p := StyleBoxFlat.new()
	p.bg_color = n.bg_color.lerp(accent, 0.28)
	p.set_border_width_all(2)
	p.border_color = accent
	p.set_corner_radius_all(3)
	btn.add_theme_stylebox_override("normal", n)
	btn.add_theme_stylebox_override("hover", h)
	btn.add_theme_stylebox_override("pressed", p)
	btn.add_theme_color_override("font_color", Color(0.88, 0.9, 0.92))
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)


func _make_cluster_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", FONT_SIZE_LABEL)
	l.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	# Right padding via a margin container would be heavier than just spacing.
	return l


func _make_separator() -> VSeparator:
	var s := VSeparator.new()
	s.custom_minimum_size = Vector2(2, 0)
	return s


func _make_button(text: String, accent: Color) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", FONT_SIZE_BUTTON)
	# Subtle accent on the toggled-on state by recoloring the font when pressed.
	btn.add_theme_color_override("font_pressed_color", accent)
	btn.add_theme_color_override("font_focus_color", accent)
	btn.focus_mode = Control.FOCUS_NONE  # don't let TAB bounce around the bar
	return btn


func _make_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.border_color = PANEL_BORDER
	style.set_border_width_all(1)
	style.set_corner_radius_all(4)
	style.content_margin_left = 4
	style.content_margin_right = 4
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	return style


func _recenter() -> void:
	if _panel == null:
		return
	# Position the panel at bottom-center with an 8px inset.
	var view: Vector2 = get_viewport().get_visible_rect().size
	var size: Vector2 = _panel.get_combined_minimum_size()
	_panel.position = Vector2((view.x - size.x) * 0.5, view.y - size.y - 8)
	_panel.size = size


# ==================== signals out ====================

func _on_build_pressed(mode: int) -> void:
	# Toggle: clicking the active build mode cancels.
	if mode == _active_mode:
		mode_requested.emit(MODE_NONE)
	else:
		mode_requested.emit(mode)


func _on_speed_pressed(idx: int) -> void:
	speed_index_requested.emit(idx)


# ==================== external sync ====================

## Called by Main whenever the build mode changes (key press, mouse, reroll).
func set_active_mode(mode: int) -> void:
	_active_mode = mode
	for m in _build_buttons:
		_build_buttons[m].set_pressed_no_signal(m == mode)
	if _cancel_button != null:
		_cancel_button.disabled = (mode == MODE_NONE)
	# Only relevant while the player is placing zones -- otherwise the label
	# is just decoration, so dim it to show it's currently inert.
	if _filter_button != null:
		_filter_button.disabled = (mode != MODE_ZONE)


## Called by Main when the player cycles filters (keyboard F or toolbar click).
## Passing the human label keeps Main the source of truth for the filter enum.
func set_zone_filter_label(label_text: String) -> void:
	if _filter_button != null:
		_filter_button.text = "Filter: %s [F]" % label_text


func _on_speed_changed(speed: float, paused: bool) -> void:
	_refresh_speed_buttons(speed, paused)


func _refresh_speed_buttons(speed: float, paused: bool) -> void:
	if _pause_button != null:
		_pause_button.set_pressed_no_signal(paused)
	for i in range(_speed_buttons.size()):
		var s: float = GameManager.SPEED_STEPS[i]
		var is_active: bool = (not paused) and is_equal_approx(speed, s)
		_speed_buttons[i].set_pressed_no_signal(is_active)
