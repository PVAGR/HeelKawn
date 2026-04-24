extends Node2D

## Renders build/zone drag previews above the world map, below pawns. Main’s
## own _draw would sort under the World child sprite; a sibling after World
## fixes the draw order without covering units.

func _draw() -> void:
	var m: Node = get_parent()
	if m != null and m.has_method("draw_designation_previews_on"):
		m.call("draw_designation_previews_on", self)
