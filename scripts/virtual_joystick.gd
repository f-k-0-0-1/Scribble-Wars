
extends CanvasLayer

signal joystick_moved(direction: Vector2)
signal sword_pressed
signal shield_pressed
signal shield_released

@export var max_distance: float = 50.0

@onready var left_touch_zone: Control = $LeftTouchZone
@onready var base: Control = $LeftTouchZone/Base
@onready var tip: Control = $LeftTouchZone/Base/Tip
@onready var sword_button: TextureButton = $SwordButton
@onready var shield_button: TextureButton = $ShieldButton

var touch_index: int = -1
var joystick_dir: Vector2 = Vector2.ZERO


func _ready() -> void:
	add_to_group("joystick")

	base.visible = false
	tip.visible = false

	left_touch_zone.mouse_filter = Control.MOUSE_FILTER_STOP

	# Connect mobile combat buttons.
	sword_button.pressed.connect(_on_sword_pressed)
	shield_button.button_down.connect(_on_shield_pressed)
	shield_button.button_up.connect(_on_shield_released)


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if (
				touch_index == -1
				and left_touch_zone.get_global_rect().has_point(event.position)
			):
				touch_index = event.index
				base.visible = true
				tip.visible = true
				update_joystick(event.position)
		elif event.index == touch_index:
			reset_joystick()

	elif event is InputEventScreenDrag:
		if event.index == touch_index:
			update_joystick(event.position)

	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				if (
					touch_index == -1
					and left_touch_zone.get_global_rect().has_point(event.position)
				):
					touch_index = 0
					base.visible = true
					tip.visible = true
					update_joystick(event.position)
			elif touch_index == 0:
				reset_joystick()

	elif event is InputEventMouseMotion:
		if (
			touch_index == 0
			and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		):
			update_joystick(event.position)


func update_joystick(touch_pos: Vector2) -> void:
	var base_center: Vector2 = base.global_position + base.size / 2.0
	var diff: Vector2 = touch_pos - base_center

	if max_distance <= 0.0:
		return

	diff = diff.limit_length(max_distance)

	tip.global_position = base_center + diff - tip.size / 2.0

	joystick_dir = diff / max_distance
	joystick_moved.emit(joystick_dir)


func reset_joystick() -> void:
	touch_index = -1
	joystick_dir = Vector2.ZERO

	var base_center: Vector2 = base.global_position + base.size / 2.0
	tip.global_position = base_center - tip.size / 2.0

	base.visible = false
	tip.visible = false

	joystick_moved.emit(Vector2.ZERO)


func _on_sword_pressed() -> void:
	sword_pressed.emit()


func _on_shield_pressed() -> void:
	shield_pressed.emit()


func _on_shield_released() -> void:
	shield_released.emit()
