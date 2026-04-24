## MoodEvent.gd — Discrete mood event system for triggers and feedback.
## Pawns emit mood events (joy, sorrow, stress, etc.) which stack and decay.
extends Resource
class_name MoodEvent

enum Type {
	JOY,          # +15 mood: ate quality food, completed important work
	SORROW,       # -20 mood: pawn died nearby, personal injury
	STRESS,       # -10 mood: hazard, close call, combat
	TRIUMPH,      # +20 mood: killed enemy, major accomplishment
	DESPAIR,      # -30 mood: starvation nearby, colony crisis
	BOREDOM,      # -5 mood: repetitive work
	CONTENTMENT,  # +8 mood: peaceful day, good health
	DREAD,        # -15 mood: impending conflict, enemy sighting
}

var type: Type
var intensity: float  # 0..100, higher = stronger effect
var remaining_ticks: int  # How many ticks until this event fades
var description: String

func _init(p_type: Type = Type.JOY, p_intensity: float = 50.0, p_duration_ticks: int = 300) -> void:
	type = p_type
	intensity = p_intensity
	remaining_ticks = p_duration_ticks
	_set_description()


func _set_description() -> void:
	match type:
		Type.JOY: description = "Joyful"
		Type.SORROW: description = "Sorrowful"
		Type.STRESS: description = "Stressed"
		Type.TRIUMPH: description = "Triumphant"
		Type.DESPAIR: description = "Despairing"
		Type.BOREDOM: description = "Bored"
		Type.CONTENTMENT: description = "Content"
		Type.DREAD: description = "Dreadful"
	description += " (%d%%)" % int(intensity)


func mood_impact() -> float:
	"""Returns the mood delta this event contributes per tick."""
	var base_impact: float = 0.0
	match type:
		Type.JOY: base_impact = 0.05
		Type.SORROW: base_impact = -0.08
		Type.STRESS: base_impact = -0.04
		Type.TRIUMPH: base_impact = 0.10
		Type.DESPAIR: base_impact = -0.15
		Type.BOREDOM: base_impact = -0.02
		Type.CONTENTMENT: base_impact = 0.03
		Type.DREAD: base_impact = -0.06
	return base_impact * (intensity / 50.0)  # Stronger events = stronger impact


func decay_tick() -> bool:
	"""Decrement duration. Returns true if event should be removed."""
	remaining_ticks -= 1
	intensity = max(0.0, intensity - 1.0)  # Fade intensity over time
	return remaining_ticks <= 0 or intensity <= 0.0
