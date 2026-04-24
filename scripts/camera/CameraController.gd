extends Camera2D

@export var min_zoom: float = 0.25
@export var max_zoom: float = 4.0
@export var zoom_step: float = 1.1
@export var pan_sensitivity: float = 1.0

var _is_panning: bool = false


func _ready() -> void:
	make_current()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion and _is_panning:
		position -= event.relative * pan_sensitivity / zoom.x


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_MIDDLE:
			_is_panning = event.pressed
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_zoom_toward(zoom_step, event.position)
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_zoom_toward(1.0 / zoom_step, event.position)


func _zoom_toward(factor: float, screen_pos: Vector2) -> void:
	var new_zoom_value: float = clamp(zoom.x * factor, min_zoom, max_zoom)
	var actual_factor: float = new_zoom_value / zoom.x
	if is_equal_approx(actual_factor, 1.0):
		return
	var world_before: Vector2 = get_screen_center_to_world(screen_pos)
	zoom = Vector2(new_zoom_value, new_zoom_value)
	var world_after: Vector2 = get_screen_center_to_world(screen_pos)
	position += world_before - world_after


func get_screen_center_to_world(screen_pos: Vector2) -> Vector2:
	var viewport_size: Vector2 = get_viewport_rect().size
	var offset_from_center: Vector2 = screen_pos - viewport_size * 0.5
	return position + offset_from_center / zoom.x
