
extends CanvasLayer

@export var joystick_radius: float = 55.0
@export var deadzone: float = 0.2

@onready var touch_zone: Control = $LeftTouchZone
@onready var base: Control = $LeftTouchZone/Base
@onready var tip: Control = $LeftTouchZone/Base/Tip

var touch_index: int = -1
var direction: Vector2 = Vector2.ZERO
var tip_start_position: Vector2


func _ready() -> void:
	tip_start_position = tip.position


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if touch_index == -1 and touch_zone.get_global_rect().has_point(event.position):
				touch_index = event.index
				_update_joystick(event.position)
		elif event.index == touch_index:
			_reset_joystick()

	elif event is InputEventScreenDrag and event.index == touch_index:
		_update_joystick(event.position)


func _update_joystick(screen_position: Vector2) -> void:
	var center_global := base.global_position + base.size / 2.0
	var offset := screen_position - center_global

	if offset.length() > joystick_radius:
		offset = offset.normalized() * joystick_radius

	tip.global_position = center_global + offset - tip.size / 2.0

	direction = offset / joystick_radius
	_apply_movement_actions()


func _apply_movement_actions() -> void:
	_set_action("left", direction.x < -deadzone)
	_set_action("right", direction.x > deadzone)
	_set_action("up", direction.y < -deadzone)
	_set_action("down", direction.y > deadzone)


func _set_action(action_name: String, active: bool) -> void:
	if active:
		if not Input.is_action_pressed(action_name):
			Input.action_press(action_name)
	elif Input.is_action_pressed(action_name):
		Input.action_release(action_name)


func _reset_joystick() -> void:
	touch_index = -1
	direction = Vector2.ZERO
	tip.position = tip_start_position

	for action_name in [
		"up",
		"down",
		"left",
        "right"
	]:
		Input.action_release(action_name)
