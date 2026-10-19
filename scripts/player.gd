
extends CharacterBody2D

@export var SPEED: float = 300.0
@export var hand_rotation_speed: float = 12.0

# Assign equipment scenes here in the Inspector.
@export var starting_right_hand_item: PackedScene
@export var starting_left_hand_item: PackedScene

var joystick_direction: Vector2 = Vector2.ZERO
var facing_direction: Vector2 = Vector2.DOWN

var right_hand_item: Equipment
var left_hand_item: Equipment

@onready var body_pivot: Node2D = $BodyPivot
@onready var animation_player: AnimationPlayer = $BodyPivot/AnimationPlayer
@onready var left_hand_pivot: Node2D = $LeftHandPivot
@onready var right_hand_pivot: Node2D = $RightHandPivot
@onready var left_socket: Marker2D = $LeftHandPivot/EquipmentSocket
@onready var right_socket: Marker2D = $RightHandPivot/EquipmentSocket


func _ready() -> void:
	# Connect to the mobile joystick.
	var joystick = get_tree().get_first_node_in_group("joystick")

	if joystick:
		if not joystick.joystick_moved.is_connected(_on_joystick_moved):
			joystick.joystick_moved.connect(_on_joystick_moved)
	else:
		push_warning("Joystick node not found in the 'joystick' group.")

	# Equip starting items, if assigned.
	if starting_right_hand_item:
		equip_right_hand(starting_right_hand_item)

	if starting_left_hand_item:
		equip_left_hand(starting_left_hand_item)

	_play_animation("idle")


func _on_joystick_moved(direction: Vector2) -> void:
	joystick_direction = direction


func _physics_process(delta: float) -> void:
	var keyboard_direction := Input.get_vector(
		"left",
		"right",
		"up",
		"down"
	)

	# Combine keyboard and joystick input.
	var direction := (
		keyboard_direction + joystick_direction
	).limit_length(1.0)

	velocity = direction * SPEED
	move_and_slide()

	var is_moving := direction.length_squared() > 0.001

	if is_moving:
		facing_direction = direction.normalized()
		_play_animation("move")
	else:
		_play_animation("idle")

	_update_hands(delta)

	# Uses the existing AudioManager Autoload.
	#AudioManager.update_footsteps(is_moving, delta)


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
		push_error("Right-hand item must extend the Equipment class.")
		return

	right_socket.add_child(item)
	right_hand_item = item


func equip_left_hand(scene: PackedScene) -> void:
	if left_hand_item:
		left_hand_item.queue_free()
		left_hand_item = null

	if scene == null:
		return

	var item := scene.instantiate() as Equipment

	if item == null:
		push_error("Left-hand item must extend the Equipment class.")
		return

	left_socket.add_child(item)
	left_hand_item = item


func attack() -> void:
	if right_hand_item:
		right_hand_item.attack()


func block() -> void:
	if left_hand_item:
		left_hand_item.block()


func stop_equipment_action() -> void:
	if right_hand_item:
		right_hand_item.stop_action()

	if left_hand_item:
		left_hand_item.stop_action()


func _play_animation(animation_name: String) -> void:
	if animation_player.has_animation(animation_name):
		if animation_player.current_animation != animation_name:
			animation_player.play(animation_name)


func get_facing_direction() -> Vector2:
	return facing_direction
