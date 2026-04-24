class_name PawnInfoPanel
extends CanvasLayer

## Right-side info panel that shows the currently selected pawn's vitals,
## skills and current task. Hidden when nothing is selected.
##
## Built programmatically (no .tscn) to mirror the BuildToolbar style and so
## tweaks live in one place. Refreshes once per game tick instead of every
## frame to keep the cost trivial even with lots of UI labels.

const PANEL_BG:     Color = Color(0.05, 0.06, 0.08, 0.90)
const PANEL_BORDER: Color = Color(0.85, 0.78, 0.40, 0.65)
const TEXT_DIM:     Color = Color(0.70, 0.70, 0.75)
const TEXT_BRIGHT:  Color = Color(0.96, 0.96, 0.98)
const ACCENT:       Color = Color8(255, 209, 102)

const FONT_TITLE: int = 14
const FONT_BODY:  int = 11
const FONT_SMALL: int = 10

const PANEL_WIDTH:    float = 230.0
const RIGHT_INSET:    float = 8.0
const TOP_INSET:      float = 8.0

const NEED_BARS: Array = [
	# (label, accessor name on PawnData, color)
	{"label": "Hunger", "field": "hunger", "color": Color8(230, 130, 100)},
	{"label": "Rest",   "field": "rest",   "color": Color8(140, 170, 235)},
	{"label": "Mood",   "field": "mood",   "color": Color8(180, 220, 130)},
	{"label": "Health", "field": "health", "color": Color8(220, 220, 220)},
]

const SKILLS_ORDER: Array = [
	# (label, PawnData.Skill enum value)
	{"label": "Foraging", "skill": 0},
	{"label": "Mining",   "skill": 1},
	{"label": "Chopping", "skill": 2},
	{"label": "Building", "skill": 3},
	{"label": "Hunting",  "skill": 4},
]

## (field on PawnData, checkbox label) — maps queue job categories to human text.
const WORK_CHECKS: Array = [
	{"field": "work_forage", "text": "Forage / gather"},
	{"field": "work_mine",   "text": "Mine / tunnel"},
	{"field": "work_chop",   "text": "Chop wood"},
	{"field": "work_hunt",   "text": "Hunt animals"},
	{"field": "work_build",  "text": "Build (bed/wall/door)"},
]


# ---- nodes built once in _ready, then rebound per pawn ----
var _panel: PanelContainer
var _root_vbox: VBoxContainer
var _title_label: Label
var _state_label: Label
var _need_bars: Dictionary = {}    # field name -> {bar: ProgressBar, label: Label}
var _skill_lines: Dictionary = {}  # skill enum -> Label
var _carry_label: Label
var _tile_label: Label
var _hint_label: Label
## field name (e.g. "work_mine") -> CheckBox, kept in sync from PawnData.
var _work_checkboxes: Dictionary = {}

var _pawn: Pawn = null
var _traits_label: Label = null


func _ready() -> void:
	layer = 100
	_build_ui()
	GameManager.game_tick.connect(_on_game_tick)
	get_viewport().size_changed.connect(_reposition)
	_set_visible(false)


# ==================== external API ====================

## Bind the panel to a specific pawn. Pass null to hide it.
func bind_pawn(p: Pawn) -> void:
	_pawn = p
	if _pawn == null:
		_set_visible(false)
		return
	_set_visible(true)
	_refresh()


# ==================== layout ====================

func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", _make_panel_style())
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   10)
	margin.add_theme_constant_override("margin_right",  10)
	margin.add_theme_constant_override("margin_top",     8)
	margin.add_theme_constant_override("margin_bottom",  8)
	_panel.add_child(margin)

	_root_vbox = VBoxContainer.new()
	_root_vbox.add_theme_constant_override("separation", 4)
	margin.add_child(_root_vbox)

	# title row
	_title_label = _make_label("", FONT_TITLE, TEXT_BRIGHT)
	_root_vbox.add_child(_title_label)

	# current activity
	_state_label = _make_label("", FONT_BODY, ACCENT)
	_state_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_root_vbox.add_child(_state_label)

	# traits
	_traits_label = _make_label("", FONT_SMALL, TEXT_DIM)
	_traits_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_root_vbox.add_child(_traits_label)

	_root_vbox.add_child(_make_section_header("Needs"))
	for entry in NEED_BARS:
		_add_need_row(entry.label, entry.field, entry.color)

	_root_vbox.add_child(_make_section_header("Skills"))
	for entry in SKILLS_ORDER:
		_add_skill_row(entry.label, entry.skill)

	_root_vbox.add_child(_make_section_header("Work"))
	_root_vbox.add_child(_make_work_hint())
	for w in WORK_CHECKS:
		_add_work_checkbox(String(w.field), String(w.text))

	_root_vbox.add_child(_make_section_header("Misc"))
	_carry_label = _make_label("", FONT_SMALL, TEXT_DIM)
	_root_vbox.add_child(_carry_label)
	_tile_label = _make_label("", FONT_SMALL, TEXT_DIM)
	_root_vbox.add_child(_tile_label)

	_hint_label = _make_label("[Esc] deselect", FONT_SMALL, Color(0.55, 0.55, 0.60))
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_root_vbox.add_child(_hint_label)

	call_deferred("_reposition")


func _add_need_row(label_text: String, field: String, color: Color) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_root_vbox.add_child(row)

	var name_lbl := _make_label(label_text, FONT_SMALL, TEXT_DIM)
	name_lbl.custom_minimum_size = Vector2(54, 0)
	row.add_child(name_lbl)

	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 100.0
	bar.value = 100.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 10)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Tint via stylebox so each bar reads at a glance.
	var fill := StyleBoxFlat.new()
	fill.bg_color = color
	fill.set_corner_radius_all(2)
	bar.add_theme_stylebox_override("fill", fill)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.13, 0.16, 1.0)
	bg.set_corner_radius_all(2)
	bar.add_theme_stylebox_override("background", bg)
	row.add_child(bar)

	var num_lbl := _make_label("100", FONT_SMALL, TEXT_BRIGHT)
	num_lbl.custom_minimum_size = Vector2(28, 0)
	num_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(num_lbl)

	_need_bars[field] = {"bar": bar, "label": num_lbl}


func _make_work_hint() -> Label:
	var l := _make_label(
		"Uncheck to stop this pawn claiming that job type. Eating & hauling always allowed.",
		FONT_SMALL,
		Color(0.55, 0.56, 0.62)
	)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _add_work_checkbox(field: String, label_text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	_root_vbox.add_child(row)
	var cb := CheckBox.new()
	cb.text = label_text
	cb.add_theme_font_size_override("font_size", FONT_SMALL)
	cb.add_theme_color_override("font_color", TEXT_BRIGHT)
	# Tighter hit target than default for this dense panel.
	cb.custom_minimum_size = Vector2(0, 18)
	var f := field
	cb.toggled.connect(func(pressed: bool): _on_work_toggled(f, pressed))
	row.add_child(cb)
	_work_checkboxes[field] = cb


func _on_work_toggled(field: String, pressed: bool) -> void:
	if _pawn == null or not is_instance_valid(_pawn) or _pawn.data == null:
		return
	var d: PawnData = _pawn.data
	match field:
		"work_forage":
			d.work_forage = pressed
		"work_mine":
			d.work_mine = pressed
		"work_chop":
			d.work_chop = pressed
		"work_hunt":
			d.work_hunt = pressed
		"work_build":
			d.work_build = pressed


static func _read_work_field(d: PawnData, field: String) -> bool:
	match field:
		"work_forage":
			return d.work_forage
		"work_mine":
			return d.work_mine
		"work_chop":
			return d.work_chop
		"work_hunt":
			return d.work_hunt
		"work_build":
			return d.work_build
	return true


func _add_skill_row(label_text: String, skill: int) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_root_vbox.add_child(row)

	var name_lbl := _make_label(label_text, FONT_SMALL, TEXT_DIM)
	name_lbl.custom_minimum_size = Vector2(54, 0)
	row.add_child(name_lbl)

	var data_lbl := _make_label("0 (0/100)", FONT_SMALL, TEXT_BRIGHT)
	data_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(data_lbl)

	_skill_lines[skill] = data_lbl


func _make_section_header(text: String) -> Label:
	var l := _make_label(text.to_upper(), FONT_SMALL, ACCENT)
	# A little vertical breathing room above each section.
	l.add_theme_constant_override("line_spacing", 2)
	return l


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	return l


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


func _reposition() -> void:
	if _panel == null:
		return
	# Anchor top-right with a small inset, just inside the viewport edge.
	var view: Vector2 = get_viewport().get_visible_rect().size
	var size: Vector2 = _panel.get_combined_minimum_size()
	# Force the configured width regardless of label intrinsic widths.
	size.x = max(size.x, PANEL_WIDTH)
	_panel.position = Vector2(view.x - size.x - RIGHT_INSET, TOP_INSET)
	_panel.size = size


func _set_visible(v: bool) -> void:
	if _panel == null:
		return
	_panel.visible = v


# ==================== refresh ====================

func _on_game_tick(_tick: int) -> void:
	if _pawn == null:
		return
	# If the pawn was removed (e.g. world reroll wiped it), drop the binding
	# silently so we don't keep poking a freed object.
	if not is_instance_valid(_pawn):
		_pawn = null
		_set_visible(false)
		return
	_refresh()


func _refresh() -> void:
	if _pawn == null or _pawn.data == null:
		return
	var d: PawnData = _pawn.data
	_title_label.text = "%s  (age %d)" % [d.display_name, d.age]
	_state_label.text = _pawn.describe_state()
	_traits_label.text = "Traits: %s" % d.traits_display()

	for field in _need_bars:
		var entry: Dictionary = _need_bars[field]
		var v: float = float(d.get(field))
		entry.bar.value = clampf(v, 0.0, 100.0)
		entry.label.text = "%d" % int(round(v))

	for skill in _skill_lines:
		var lbl: Label = _skill_lines[skill]
		var lvl: int = d.get_skill_level(skill)
		var xp: float = d.get_skill_xp(skill)
		var into_level: float = xp - float(lvl) * PawnData.XP_PER_LEVEL
		lbl.text = "Lv %d  (%d/%d)" % [
			lvl,
			int(into_level),
			int(PawnData.XP_PER_LEVEL),
		]

	if d.is_carrying():
		_carry_label.text = "Carrying: %s x%d" % [
			Item.name_for(d.carrying),
			d.carrying_qty,
		]
	else:
		_carry_label.text = "Carrying: nothing"

	_tile_label.text = "Tile: (%d, %d)" % [d.tile_pos.x, d.tile_pos.y]

	# Work toggles: reflect PawnData without re-emitting toggled (avoid feedback).
	for w in WORK_CHECKS:
		var f: String = String(w.field)
		if not _work_checkboxes.has(f):
			continue
		var cb: CheckBox = _work_checkboxes[f]
		cb.set_pressed_no_signal(_read_work_field(d, f))

	# Reposition each tick because the panel can grow/shrink with carry text.
	_reposition()
