
extends CharacterBody2D

@export_group("Movement")
@export var SPEED: float = 300.0
@export var hand_rotation_speed: float = 12.0
@export var attack_cooldown: float = 0.35

@export_group("Health")
@export var max_health: int = 100
@export var invulnerability_duration: float = 0.8

@export_group("Damage Effect")
@export var damage_flash_duration: float = 0.5
@export_range(1, 10, 1) var damage_flash_count: int = 3

@export_group("Knockback")
@export var knockback_force: float = 300.0
@export var knockback_duration: float = 0.18
@export var knockback_decay: float = 12.0

@export_group("Equipment")
@export var starting_right_hand_item: PackedScene
@export var starting_left_hand_item: PackedScene

var current_health: int = 100
var is_dead: bool = false
var is_invulnerable: bool = false

var joystick_direction: Vector2 = Vector2.ZERO
var facing_direction: Vector2 = Vector2.DOWN

var right_hand_item: Equipment
var left_hand_item: Equipment

var can_attack: bool = true
var is_blocking: bool = false

var joystick_node: Node
var damage_tween: Tween

var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_timer: float = 0.0

signal health_changed(current_health: int, max_health: int)

@onready var body_pivot: Node2D = $BodyPivot
@onready var body_sprite: Sprite2D = $BodyPivot/BodySprite
@onready var animation_player: AnimationPlayer = $BodyPivot/AnimationPlayer

@onready var left_hand_pivot: Node2D = $LeftHandPivot
@onready var right_hand_pivot: Node2D = $RightHandPivot

@onready var left_socket: Marker2D = $LeftHandPivot/EquipmentSocket
@onready var right_socket: Marker2D = $RightHandPivot/EquipmentSocket


func _ready() -> void:
	add_to_group("player")

	$AudioListener2D.make_current()

	current_health = max_health
	health_changed.emit(current_health, max_health)

	_setup_damage_shader()

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


func _setup_damage_shader() -> void:
	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material == null:
		push_warning(
			"BodySprite needs a ShaderMaterial using player_damage.gdshader."
		)
		return

	body_sprite.material = shader_material.duplicate()
	body_sprite.material.set_shader_parameter("damage_flash", 0.0)


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
		push_warning("JoystickControl is missing sword_pressed.")

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
	if is_dead:
		velocity = Vector2.ZERO
		return

	var keyboard_direction := Input.get_vector(
		"left",
		"right",
		"up",
		"down"
	)

	var direction := (
		keyboard_direction + joystick_direction
	).limit_length(1.0)

	if knockback_timer > 0.0:
		knockback_timer = maxf(knockback_timer - delta, 0.0)

		# Knockback takes priority over normal movement.
		velocity = knockback_velocity

		# Gradually reduce the knockback speed.
		knockback_velocity = knockback_velocity.move_toward(
			Vector2.ZERO,
			knockback_force * knockback_decay * delta
		)

		if knockback_timer <= 0.0:
			knockback_velocity = Vector2.ZERO
	else:
		velocity = direction * SPEED

	move_and_slide()

	var is_moving := (
		direction.length_squared() > 0.001
		or knockback_timer > 0.0
	)

	if direction.length_squared() > 0.001:
		facing_direction = direction.normalized()

	if not _is_attacking():
		if is_moving:
			_play_animation("move")
		else:
			_play_animation("idle")

	_update_hands(delta)

	if Input.is_action_just_pressed("attack"):
		attack()

	if Input.is_action_just_pressed("block"):
		start_block()

	if Input.is_action_just_released("block"):
		stop_block()


func _update_hands(delta: float) -> void:
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
	item.reset_pose()


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
	item.reset_pose()


func attack() -> void:
	if is_dead or not can_attack or is_blocking:
		return

	if right_hand_item == null:
		return

	can_attack = false
	right_hand_item.attack()

	await get_tree().create_timer(attack_cooldown).timeout

	if is_inside_tree() and not is_dead:
		can_attack = true


func start_block() -> void:
	if is_dead or is_blocking:
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

	if left_hand_item:
		left_hand_item.stop_action()

	if right_hand_item:
		right_hand_item.stop_action()


func stop_equipment_action() -> void:
	if right_hand_item:
		right_hand_item.stop_action()

	if left_hand_item:
		left_hand_item.stop_action()


func _try_block_incoming_damage(attacker: Node2D = null) -> bool:
	if not is_blocking or not is_instance_valid(left_hand_item):
		return false

	if not left_hand_item.has_method("try_block_melee_attack"):
		return false

	# The shield script checks its active state and protected direction.
	var blocked := bool(
		left_hand_item.call("try_block_melee_attack", attacker)
	)
	if not blocked:
		return false

	# Notify the attacker immediately so its active hitbox/attack is cancelled
	# and it recoils. This is idempotent on the SpearEnemy side.
	if is_instance_valid(attacker) and attacker.has_method("on_blocked_by_shield"):
		attacker.call("on_blocked_by_shield", left_hand_item)

	return true


func take_damage(
	amount: int,
	attacker: Node2D = null,
	bypass_invulnerability: bool = false,
	apply_hit_knockback: bool = true
) -> bool:
	if is_dead or amount <= 0:
		return false

	# Always resolve the shield first. The Dual Axe spin may bypass normal
	# invulnerability frames for its five timed hits, but it must never bypass
	# a successful shield block.
	if _try_block_incoming_damage(attacker):
		return false

	if is_invulnerable and not bypass_invulnerability:
		return false

	# Do not restart the invulnerability timer for each multi-hit spin tick.
	# It begins on the first accepted hit, as it does for ordinary damage.
	var was_invulnerable := is_invulnerable

	current_health = maxi(current_health - amount, 0)
	health_changed.emit(current_health, max_health)

	print(
		"Player took ",
		amount,
		" damage. Health: ",
		current_health,
		"/",
		max_health
	)

	_play_damage_flash()

	if current_health <= 0:
		_die()
		return true

	if apply_hit_knockback:
		_apply_knockback(attacker)

	if not was_invulnerable:
		_start_invulnerability()

	return true


func _apply_knockback(attacker: Node2D = null) -> void:
	var knockback_direction: Vector2

	if is_instance_valid(attacker):
		# Push the player away from the attacker.
		knockback_direction = (
			global_position - attacker.global_position
		).normalized()
	else:
		# Fallback when no attacker reference is provided.
		knockback_direction = -facing_direction

	if knockback_direction.length_squared() < 0.001:
		knockback_direction = -facing_direction

	knockback_velocity = knockback_direction * knockback_force
	knockback_timer = maxf(knockback_duration, 0.0)


func _play_damage_flash() -> void:
	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material == null:
		return

	if damage_tween and damage_tween.is_valid():
		damage_tween.kill()

	damage_tween = create_tween()

	var single_flash_duration := (
		damage_flash_duration
		/ float(maxi(damage_flash_count * 2, 1))
	)

	shader_material.set_shader_parameter("damage_flash", 0.0)

	for i in range(damage_flash_count):
		damage_tween.tween_method(
			_set_damage_flash,
			0.0,
			1.0,
			single_flash_duration
		)

		damage_tween.tween_method(
			_set_damage_flash,
			1.0,
			0.0,
			single_flash_duration
		)

	damage_tween.tween_callback(
		func() -> void:
			_set_damage_flash(0.0)
	)


func _set_damage_flash(value: float) -> void:
	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material:
		shader_material.set_shader_parameter("damage_flash", value)


func _start_invulnerability() -> void:
	is_invulnerable = true

	await get_tree().create_timer(invulnerability_duration).timeout

	if is_inside_tree() and not is_dead:
		is_invulnerable = false


func _die() -> void:
	if is_dead:
		return

	is_dead = true
	velocity = Vector2.ZERO
	knockback_velocity = Vector2.ZERO
	knockback_timer = 0.0

	stop_equipment_action()
	is_blocking = false
	is_invulnerable = true

	if damage_tween and damage_tween.is_valid():
		damage_tween.kill()

	_set_damage_flash(0.0)

	set_collision_layer_value(1, false)
	set_collision_mask_value(1, false)

	if is_instance_valid(right_hand_item):
		right_hand_item.queue_free()
		right_hand_item = null

	if is_instance_valid(left_hand_item):
		left_hand_item.queue_free()
		left_hand_item = null

	print("Player died.")

	await get_tree().create_timer(0.75).timeout

	if not is_inside_tree():
		return

	queue_free()

	get_tree().call_deferred(
		"change_scene_to_file",
		"res://scenes/main_menu.tscn"
	)


func heal(amount: int) -> void:
	if is_dead or amount <= 0:
		return

	current_health = mini(current_health + amount, max_health)
	health_changed.emit(current_health, max_health)

	print(
		"Player healed. Health: ",
		current_health,
		"/",
		max_health
	)


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
