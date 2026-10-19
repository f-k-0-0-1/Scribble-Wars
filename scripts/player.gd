
extends CharacterBody2D

@export var SPEED: float = 300.0
@export var hand_rotation_speed: float = 12.0
@export var attack_cooldown: float = 0.35

@export var starting_right_hand_item: PackedScene
@export var starting_left_hand_item: PackedScene

var joystick_direction: Vector2 = Vector2.ZERO
var facing_direction: Vector2 = Vector2.DOWN

var right_hand_item: Equipment
var left_hand_item: Equipment

var can_attack: bool = true
var is_blocking: bool = false

var joystick_node: Node


@onready var body_pivot: Node2D = $BodyPivot
@onready var animation_player: AnimationPlayer = $BodyPivot/AnimationPlayer
@onready var left_hand_pivot: Node2D = $LeftHandPivot
@onready var right_hand_pivot: Node2D = $RightHandPivot
@onready var left_socket: Marker2D = $LeftHandPivot/EquipmentSocket
@onready var right_socket: Marker2D = $RightHandPivot/EquipmentSocket


func _ready() -> void:
	add_to_group("player")

	joystick_node = get_tree().get_first_node_in_group("joystick")

	if joystick_node:
		_connect_joystick_signals()
	else:
		push_warning(
			"JoystickControl not found. Check the 'joystick' group."
		)

	if starting_right_hand_item:
		equip_right_hand(starting_right_hand_item)

	if starting_left_hand_item:
		equip_left_hand(starting_left_hand_item)

	_play_animation("idle")


func _connect_joystick_signals() -> void:
	var movement_callback := Callable(self, "_on_joystick_moved")
	var attack_callback := Callable(self, "attack")
	var block_callback := Callable(self, "start_block")
	var unblock_callback := Callable(self, "stop_block")

	if joystick_node.has_signal("joystick_moved"):
		if not joystick_node.is_connected(
			"joystick_moved", movement_callback
		):
			joystick_node.connect(
				"joystick_moved", movement_callback
			)

	if joystick_node.has_signal("sword_pressed"):
		if not joystick_node.is_connected(
			"sword_pressed", attack_callback
		):
			joystick_node.connect(
				"sword_pressed", attack_callback
			)
	else:
		push_warning(
			"JoystickControl is missing sword_pressed."
		)

	if joystick_node.has_signal("shield_pressed"):
		if not joystick_node.is_connected(
			"shield_pressed", block_callback
		):
			joystick_node.connect(
				"shield_pressed", block_callback
			)

	if joystick_node.has_signal("shield_released"):
		if not joystick_node.is_connected(
			"shield_released", unblock_callback
		):
			joystick_node.connect(
				"shield_released", unblock_callback
			)


func _on_joystick_moved(direction: Vector2) -> void:
	joystick_direction = direction.limit_length(1.0)


func _physics_process(delta: float) -> void:
	# Keyboard movement on PC and joystick movement on mobile.
	var keyboard_direction := Input.get_vector(
		"left",
		"right",
		"up",
		"down"
	)

	var direction := (
		keyboard_direction + joystick_direction
	).limit_length(1.0)

	velocity = direction * SPEED
	move_and_slide()

	var is_moving := direction.length_squared() > 0.001

	if is_moving:
		facing_direction = direction.normalized()

	# Update the body animation without interrupting a sword attack.
	if not _is_attacking():
		if is_moving:
			_play_animation("move")
		else:
			_play_animation("idle")

	_update_hands(delta)

	# Keyboard attack on PC.
	if Input.is_action_just_pressed("attack"):
		attack()

	# Keyboard blocking on PC.
	# Mobile blocking is handled through ShieldButton signals.
	if Input.is_action_just_pressed("block"):
		start_block()

	if Input.is_action_just_released("block"):
		stop_block()


func _update_hands(delta: float) -> void:
	# Assumes the hand artwork points UP at zero rotation.
	var target_angle := facing_direction.angle() + PI / 2.0
	var weight := minf(hand_rotation_speed * delta, 1.0)

	left_hand_pivot.rotation = lerp_angle(
		left_hand_pivot.rotation,
		target_angle,
		weight
	)

	right_hand_pivot.rotation = lerp_angle(
		right_hand_pivot.rotation,
		target_angle,
		weight
	)


func equip_right_hand(scene: PackedScene) -> void:
	if right_hand_item:
		right_hand_item.queue_free()
		right_hand_item = null

	if scene == null:
		return

	var item := scene.instantiate() as Equipment

	if item == null:
		push_error(
			"Right-hand item must extend the Equipment class."
		)
		return

	right_socket.add_child(item)
	right_hand_item = item
	item.reset_pose()


func equip_left_hand(scene: PackedScene) -> void:
	if left_hand_item:
		left_hand_item.queue_free()
		left_hand_item = null

	if scene == null:
		return

	var item := scene.instantiate() as Equipment

	if item == null:
		push_error(
			"Left-hand item must extend the Equipment class."
		)
		return

	left_socket.add_child(item)
	left_hand_item = item
	item.reset_pose()


func attack() -> void:
	if not can_attack or is_blocking:
		return

	if right_hand_item == null:
		return

	can_attack = false
	right_hand_item.attack()

	await get_tree().create_timer(attack_cooldown).timeout

	can_attack = true


func start_block() -> void:
	if is_blocking:
		return

	is_blocking = true

	if left_hand_item:
		left_hand_item.block()
	
	if right_hand_item:
		right_hand_item.block()


func stop_block() -> void:
	if not is_blocking:
		return

	is_blocking = false

	# Restore only the left-hand equipment.
	if left_hand_item:
		left_hand_item.stop_action()
	
	if right_hand_item:
		right_hand_item.stop_action()


func stop_equipment_action() -> void:
	if right_hand_item:
		right_hand_item.stop_action()

	if left_hand_item:
		left_hand_item.stop_action()


func _is_attacking() -> bool:
	if right_hand_item == null:
		return false

	var item_animation_player := (
		right_hand_item.get_node_or_null("AnimationPlayer")
		as AnimationPlayer
	)

	return (
		item_animation_player != null
		and item_animation_player.current_animation == "attack"
		and item_animation_player.is_playing()
	)


func _play_animation(animation_name: String) -> void:
	if animation_player.has_animation(animation_name):
		if animation_player.current_animation != animation_name:
			animation_player.play(animation_name)


func get_facing_direction() -> Vector2:
	return facing_direction
