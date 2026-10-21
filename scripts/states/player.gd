
extends CharacterBody2D

# Shared player systems stay here (health, equipment, damage, aim lock).
# State-specific input and movement are owned by the FSM state scripts.

# ==================================================
# MOVEMENT
# ==================================================

@export_group("Movement")
@export var SPEED: float = 300.0
@export var hand_rotation_speed: float = 12.0
@export var attack_cooldown: float = 0.35


# ==================================================
# SWORD COMBO
# ==================================================

@export_group("Sword Combo")
@export_range(0.2, 0.9, 0.05) var combo_window_start_ratio: float = 0.55
@export var combo_recovery_time: float = 0.10


# ==================================================
# AIM LOCK
# ==================================================

@export_group("Aim Lock")
@export var aim_lock_enabled: bool = true
@export var aim_lock_range: float = 160.0


# ==================================================
# BLOCK ORIENTATION
# ==================================================

@export_group("Block Orientation")
@export var shield_forward_offset_degrees: float = 90.0


# ==================================================
# HEALTH
# ==================================================

@export_group("Health")
@export var max_health: int = 100
@export var invulnerability_duration: float = 0.8
@export var hurt_state_duration: float = 0.25


# ==================================================
# DAMAGE EFFECT
# ==================================================

@export_group("Damage Effect")
@export var damage_flash_duration: float = 0.5
@export_range(1, 10, 1) var damage_flash_count: int = 3


# ==================================================
# KNOCKBACK
# ==================================================

@export_group("Knockback")
@export var knockback_force: float = 300.0
@export var knockback_duration: float = 0.18
@export var knockback_decay: float = 12.0


# ==================================================
# EQUIPMENT
# ==================================================

@export_group("Equipment")
@export var starting_right_hand_item: PackedScene
@export var starting_left_hand_item: PackedScene


# ==================================================
# PLAYER STATE
# ==================================================

var current_health: int = 100
var is_dead: bool = false
var is_invulnerable: bool = false
var is_blocking: bool = false
var block_input_active: bool = false
var can_attack: bool = true

var joystick_direction: Vector2 = Vector2.ZERO
var facing_direction: Vector2 = Vector2.DOWN
var locked_target: Node2D = null

var right_hand_item: Equipment
var left_hand_item: Equipment
var joystick_node: Node
var damage_tween: Tween

var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_timer: float = 0.0


# ==================================================
# COMBO STATE
# ==================================================

var combo_active: bool = false
var combo_step: int = 0
var combo_window_open: bool = false
var combo_input_queued: bool = false

var _body_speed_before_combo: float = 1.0
var _sword_speed_before_combo: float = 1.0
var _shield_speed_before_combo: float = 1.0

var _dead_cleanup_started: bool = false


# ==================================================
# NODE REFERENCES
# ==================================================

@onready var body_pivot: Node2D = $BodyPivot
@onready var body_sprite: Sprite2D = $BodyPivot/BodySprite
@onready var animation_player: AnimationPlayer = $BodyPivot/AnimationPlayer

@onready var left_hand_pivot: Node2D = $LeftHandPivot
@onready var right_hand_pivot: Node2D = $RightHandPivot

@onready var left_socket: Marker2D = $LeftHandPivot/EquipmentSocket
@onready var right_socket: Marker2D = $RightHandPivot/EquipmentSocket

@onready var state_machine: StateMachine = $StateMachine


signal health_changed(current_health: int, max_health: int)


# ==================================================
# INITIALIZATION
# ==================================================

func _setup_damage_shader() -> void:
	if not is_instance_valid(body_sprite):
		push_warning("Player: BodySprite node was not found.")
		return

	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material == null:
		push_warning(
			"Player: BodySprite needs a ShaderMaterial using "
			+ "player_damage.gdshader."
		)
		return

	# Give this Player its own independent flash value.
	body_sprite.material = shader_material.duplicate()

	var player_material := body_sprite.material as ShaderMaterial
	player_material.set_shader_parameter("damage_flash", 0.0)


func _ready() -> void:
	add_to_group("player")

	# Process the final rotation correction after ordinary animation updates.
	process_priority = 100

	max_health = maxi(max_health, 1)
	current_health = max_health
	health_changed.emit(current_health, max_health)

	_setup_damage_shader()

	joystick_node = get_tree().get_first_node_in_group("joystick")

	if is_instance_valid(joystick_node):
		_connect_joystick_signals()

	if starting_right_hand_item != null:
		equip_right_hand(starting_right_hand_item)

	if starting_left_hand_item != null:
		equip_left_hand(starting_left_hand_item)

	state_machine.initialize(self)


# ==================================================
# FSM DISPATCH
# ==================================================

func _process(delta: float) -> void:
	if is_instance_valid(state_machine):
		state_machine.update(delta)

	if is_dead:
		return

	if is_blocking:
		# Smooth rotation rather than snapping to each new direction.
		_update_blocking_rotation(delta)


func _physics_process(delta: float) -> void:
	if is_instance_valid(state_machine):
		state_machine.physics_update(delta)


func _unhandled_input(event: InputEvent) -> void:
	if is_dead or not is_instance_valid(state_machine):
		return

	state_machine.handle_input(event)


# ==================================================
# INPUT / FSM REQUESTS
# ==================================================

func _connect_joystick_signals() -> void:
	var movement_callback := Callable(self, "_on_joystick_moved")
	var attack_callback := Callable(self, "attack")
	var block_callback := Callable(self, "start_block")
	var unblock_callback := Callable(self, "stop_block")

	if joystick_node.has_signal("joystick_moved"):
		if not joystick_node.is_connected(
			"joystick_moved",
			movement_callback
		):
			joystick_node.connect(
				"joystick_moved",
				movement_callback
			)

	if joystick_node.has_signal("sword_pressed"):
		if not joystick_node.is_connected(
			"sword_pressed",
			attack_callback
		):
			joystick_node.connect(
				"sword_pressed",
				attack_callback
			)

	if joystick_node.has_signal("shield_pressed"):
		if not joystick_node.is_connected(
			"shield_pressed",
			block_callback
		):
			joystick_node.connect(
				"shield_pressed",
				block_callback
			)

	if joystick_node.has_signal("shield_released"):
		if not joystick_node.is_connected(
			"shield_released",
			unblock_callback
		):
			joystick_node.connect(
				"shield_released",
				unblock_callback
			)


func _on_joystick_moved(direction: Vector2) -> void:
	joystick_direction = direction.limit_length(1.0)


func get_movement_direction() -> Vector2:
	var keyboard_direction := Input.get_vector(
		"left",
		"right",
		"up",
		"down"
	)

	return (
		keyboard_direction + joystick_direction
	).limit_length(1.0)


func attack() -> void:
	if is_dead or is_blocking or not can_attack:
		if (
			is_instance_valid(state_machine)
			and state_machine.is_in_state("Attack")
			and not is_dead
			and not is_blocking
		):
			var active_attack := state_machine.current_state as AttackState

			if active_attack != null:
				active_attack.queue_combo_input()

		return

	if not is_instance_valid(right_hand_item):
		return

	if (
		state_machine.is_in_state("Idle")
		or state_machine.is_in_state("Move")
	):
		state_machine.transition_to("Attack")


func start_block() -> void:
	if is_dead or is_blocking:
		return

	# Do not interrupt the combo or the death state.
	if (
		state_machine.is_in_state("Attack")
		or state_machine.is_in_state("Dead")
	):
		return

	block_input_active = true

	# A block request received during Hurt is remembered.
	if state_machine.is_in_state("Hurt"):
		return

	if (
		state_machine.is_in_state("Idle")
		or state_machine.is_in_state("Move")
	):
		state_machine.transition_to("Block")


func stop_block() -> void:
	block_input_active = false

	if not is_instance_valid(state_machine) or is_dead:
		return

	if state_machine.is_in_state("Block"):
		state_machine.transition_to(
			_get_locomotion_state_name()
		)


func _transition_to_locomotion() -> void:
	if not is_instance_valid(state_machine):
		return

	state_machine.transition_to(
		_get_locomotion_state_name()
	)


func _get_locomotion_state_name() -> StringName:
	if (
		get_movement_direction().length_squared() > 0.001
		or knockback_timer > 0.0
	):
		return &"Move"

	return &"Idle"


# ==================================================
# MOVEMENT HELPERS USED BY STATES
# ==================================================

func _apply_state_movement(
	delta: float,
	update_facing: bool = true
) -> void:
	var direction: Vector2 = get_movement_direction()

	if knockback_timer > 0.0:
		knockback_timer = maxf(
			knockback_timer - delta,
			0.0
		)

		velocity = knockback_velocity

		knockback_velocity = knockback_velocity.move_toward(
			Vector2.ZERO,
			maxf(knockback_force * knockback_decay, 0.0) * delta
		)

		if knockback_timer <= 0.0:
			knockback_velocity = Vector2.ZERO
	else:
		velocity = direction * SPEED

	if (
		update_facing
		and direction.length_squared() > 0.001
		and not combo_active
	):
		facing_direction = direction.normalized()

		if not is_blocking:
			_update_hands(delta)

	move_and_slide()


func _apply_knockback_movement(delta: float) -> void:
	if knockback_timer > 0.0:
		knockback_timer = maxf(
			knockback_timer - delta,
			0.0
		)

		velocity = knockback_velocity

		knockback_velocity = knockback_velocity.move_toward(
			Vector2.ZERO,
			maxf(knockback_force * knockback_decay, 0.0) * delta
		)

		if knockback_timer <= 0.0:
			knockback_velocity = Vector2.ZERO
	else:
		velocity = Vector2.ZERO

	move_and_slide()


func _play_current_locomotion_animation() -> void:
	if combo_active or is_dead:
		return

	var direction: Vector2 = get_movement_direction()

	if direction.length_squared() > 0.001 or knockback_timer > 0.0:
		_play_animation("move")
	else:
		_play_animation("idle")


# ==================================================
# SMOOTH HAND ROTATION
# ==================================================

func _get_rotation_weight(delta: float) -> float:
	# Frame-rate-independent smoothing. This prevents abrupt snapping
	# and produces consistent rotation at different frame rates.
	return 1.0 - exp(-maxf(hand_rotation_speed, 0.0) * delta)


func _update_hands(delta: float) -> void:
	var target_angle: float = facing_direction.angle() + PI / 2.0
	var weight: float = _get_rotation_weight(delta)

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


func _set_hand_pivots_for_facing_direction() -> void:
	# Retained for compatibility with existing state scripts that use
	# this helper when they explicitly need an immediate orientation.
	var target_angle: float = facing_direction.angle() + PI / 2.0

	left_hand_pivot.rotation = target_angle
	right_hand_pivot.rotation = target_angle


func _update_blocking_rotation(delta: float) -> void:
	# Rotate the hands smoothly using the same method as normal movement.
	_update_hands(delta)

	# Then smoothly align the Shield with the current facing direction.
	_orient_blocking_shield(delta)


# ==================================================
# AIM LOCK
# ==================================================

func _acquire_aim_lock_target() -> Node2D:
	if not aim_lock_enabled:
		return null

	var nearest_enemy: Node2D = null
	var nearest_distance: float = maxf(aim_lock_range, 0.0)

	for candidate in get_tree().get_nodes_in_group("enemy"):
		if not candidate is Node2D:
			continue

		var enemy := candidate as Node2D

		if enemy == self or enemy.is_queued_for_deletion():
			continue

		if not enemy.has_method("take_damage"):
			continue

		var enemy_is_dead: bool = false

		for property_info in enemy.get_property_list():
			if StringName(property_info["name"]) == &"is_dead":
				enemy_is_dead = bool(enemy.get("is_dead"))
				break

		if enemy_is_dead:
			continue

		var distance: float = global_position.distance_to(
			enemy.global_position
		)

		if distance <= nearest_distance:
			nearest_distance = distance
			nearest_enemy = enemy

	return nearest_enemy


func _update_aim_lock() -> void:
	if (
		not is_instance_valid(locked_target)
		or locked_target.is_queued_for_deletion()
	):
		locked_target = null
		return

	var target_direction: Vector2 = (
		locked_target.global_position - global_position
	)

	if target_direction.length_squared() < 0.001:
		return

	facing_direction = target_direction.normalized()

	# During a combo, maintain aim while allowing the animation to
	# control local hand/sword poses.
	if not is_blocking:
		_set_hand_pivots_for_facing_direction()


func _clear_aim_lock() -> void:
	locked_target = null


# ==================================================
# EQUIPMENT
# ==================================================

func equip_right_hand(scene: PackedScene) -> void:
	if is_instance_valid(right_hand_item):
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
	if is_instance_valid(left_hand_item):
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


func _get_item_animation_player(item: Equipment) -> AnimationPlayer:
	if not is_instance_valid(item):
		return null

	return item.get_node_or_null("AnimationPlayer") as AnimationPlayer


func _capture_combo_animation_speeds() -> void:
	_body_speed_before_combo = animation_player.speed_scale

	var sword_player := _get_item_animation_player(right_hand_item)

	if sword_player != null:
		_sword_speed_before_combo = sword_player.speed_scale

	var shield_player := _get_item_animation_player(left_hand_item)

	if shield_player != null:
		_shield_speed_before_combo = shield_player.speed_scale


func _restore_combo_animation_speeds() -> void:
	if is_instance_valid(animation_player):
		animation_player.speed_scale = _body_speed_before_combo

	var sword_player := _get_item_animation_player(right_hand_item)

	if sword_player != null:
		sword_player.speed_scale = _sword_speed_before_combo

	var shield_player := _get_item_animation_player(left_hand_item)

	if shield_player != null:
		shield_player.speed_scale = _shield_speed_before_combo


# ==================================================
# COMBO ANIMATION HELPERS USED BY ATTACK STATE
# ==================================================

func _play_combo_step(step: int) -> void:
	var animation_name: StringName = _get_combo_animation_name(step)

	# The Player body may use the generic attack animation for steps 2 and 3.
	# The Sword and Shield have their own combo-specific animations.
	var body_animation: StringName = animation_name

	if not animation_player.has_animation(body_animation):
		body_animation = &"attack"

	if animation_player.has_animation(body_animation):
		animation_player.speed_scale = 1.0
		animation_player.play(body_animation, 0.025)

	_play_equipment_animation(
		right_hand_item,
		animation_name,
		&"attack",
		step
	)

	if step == 3:
		_play_equipment_animation(
			left_hand_item,
			&"attack_3",
			&"",
			3
		)


func _get_combo_animation_name(step: int) -> StringName:
	match step:
		1:
			return &"attack"
		2:
			return &"attack_2"
		3:
			return &"attack_3"
		_:
			return &""


func _play_equipment_animation(
	item: Equipment,
	preferred_animation: StringName,
	fallback_animation: StringName,
	combo_number: int
) -> void:
	if not is_instance_valid(item):
		return

	var item_player := _get_item_animation_player(item)

	if item_player == null:
		return

	var animation_to_play: StringName = preferred_animation

	if not item_player.has_animation(animation_to_play):
		if (
			fallback_animation != &""
			and item_player.has_animation(fallback_animation)
		):
			animation_to_play = fallback_animation
		else:
			return

	item_player.speed_scale = 1.0

	if item.has_method("set_combo_step"):
		item.call("set_combo_step", combo_number)

	item_player.play(animation_to_play, 0.025)


func _get_combo_step_duration(step: int) -> float:
	var animation_name: StringName = _get_combo_animation_name(step)
	var duration: float = 0.05

	var body_animation: StringName = animation_name

	if not animation_player.has_animation(body_animation):
		body_animation = &"attack"

	if animation_player.has_animation(body_animation):
		duration = maxf(
			duration,
			animation_player.get_animation(body_animation).length
		)

	var sword_player := _get_item_animation_player(right_hand_item)

	if sword_player != null:
		var sword_animation: StringName = animation_name

		if not sword_player.has_animation(sword_animation):
			sword_animation = &"attack"

		if sword_player.has_animation(sword_animation):
			duration = maxf(
				duration,
				sword_player.get_animation(sword_animation).length
			)

	if step == 3:
		var shield_player := _get_item_animation_player(left_hand_item)

		if (
			shield_player != null
			and shield_player.has_animation(&"attack_3")
		):
			duration = maxf(
				duration,
				shield_player.get_animation(&"attack_3").length
			)

	return duration


# ==================================================
# SHIELD BLOCK / ORIENTATION
# ==================================================

func _orient_blocking_shield(delta: float = 0.016) -> void:
	if not is_instance_valid(left_hand_item):
		return

	var shield_pivot := (
		left_hand_item.get_node_or_null("ShieldPivot") as Node2D
	)

	if shield_pivot == null:
		return

	var target_rotation: float = (
		facing_direction.angle()
		+ deg_to_rad(shield_forward_offset_degrees)
	)

	var weight: float = _get_rotation_weight(delta)

	shield_pivot.global_rotation = lerp_angle(
		shield_pivot.global_rotation,
		target_rotation,
		weight
	)


func stop_equipment_action() -> void:
	if is_instance_valid(right_hand_item):
		right_hand_item.stop_action()

	if is_instance_valid(left_hand_item):
		left_hand_item.stop_action()


# ==================================================
# DAMAGE / SHIELD CHECK
# ==================================================

func _try_block_incoming_damage(attacker: Node2D = null) -> bool:
	if not is_blocking or not is_instance_valid(left_hand_item):
		return false

	if not left_hand_item.has_method("try_block_melee_attack"):
		return false

	var blocked: bool = bool(
		left_hand_item.call(
			"try_block_melee_attack",
			attacker
		)
	)

	if not blocked:
		return false

	if (
		is_instance_valid(attacker)
		and attacker.has_method("on_blocked_by_shield")
	):
		attacker.call(
			"on_blocked_by_shield",
			left_hand_item
		)

	return true


func take_damage(
	amount: int,
	attacker: Node2D = null,
	bypass_invulnerability: bool = false,
	apply_hit_knockback: bool = true
) -> bool:
	if is_dead or amount <= 0:
		return false

	if _try_block_incoming_damage(attacker):
		return false

	if is_invulnerable and not bypass_invulnerability:
		return false

	current_health = maxi(current_health - amount, 0)

	health_changed.emit(current_health, max_health)

	print(
		"Player took %d damage. Health: %d/%d"
		% [amount, current_health, max_health]
	)

	_play_damage_flash()

	if current_health <= 0:
		_die()
		return true

	if apply_hit_knockback:
		_apply_knockback(attacker)

	if not bypass_invulnerability:
		_start_invulnerability()

	# Only enter Hurt if a real damaging hit was applied.
	if (
		is_instance_valid(state_machine)
		and not state_machine.is_in_state("Hurt")
	):
		state_machine.transition_to(
			"Hurt",
			{"duration": hurt_state_duration}
		)

	return true


func _apply_knockback(attacker: Node2D = null) -> void:
	var direction: Vector2

	if is_instance_valid(attacker):
		direction = (
			global_position - attacker.global_position
		).normalized()
	else:
		direction = -facing_direction

	if direction.length_squared() < 0.001:
		direction = -facing_direction

	knockback_velocity = direction * knockback_force
	knockback_timer = maxf(knockback_duration, 0.0)


# ==================================================
# DAMAGE FLASH
# ==================================================

func _play_damage_flash() -> void:
	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material == null:
		return

	if damage_tween != null and damage_tween.is_valid():
		damage_tween.kill()

	damage_tween = create_tween()

	var single_duration: float = (
		damage_flash_duration
		/ float(maxi(damage_flash_count * 2, 1))
	)

	shader_material.set_shader_parameter("damage_flash", 0.0)

	for _index in range(damage_flash_count):
		damage_tween.tween_method(
			_set_damage_flash,
			0.0,
			1.0,
			single_duration
		)

		damage_tween.tween_method(
			_set_damage_flash,
			1.0,
			0.0,
			single_duration
		)

	damage_tween.tween_callback(
		func() -> void:
			_set_damage_flash(0.0)
	)


func _set_damage_flash(value: float) -> void:
	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material != null:
		shader_material.set_shader_parameter("damage_flash", value)


func _start_invulnerability() -> void:
	is_invulnerable = true

	await get_tree().create_timer(
		invulnerability_duration
	).timeout

	if is_inside_tree() and not is_dead:
		is_invulnerable = false


# ==================================================
# HURT / DEATH STATE HELPERS
# ==================================================

func play_hurt_animation_if_available() -> void:
	if animation_player.has_animation(&"hurt"):
		animation_player.play(&"hurt", 0.02)


func _die() -> void:
	if is_dead:
		return

	if (
		is_instance_valid(state_machine)
		and state_machine.is_initialized
	):
		state_machine.transition_to("Dead")
	else:
		_enter_dead_state()


func _enter_dead_state() -> void:
	if _dead_cleanup_started:
		return

	_dead_cleanup_started = true
	is_dead = true
	is_invulnerable = true
	block_input_active = false
	is_blocking = false
	combo_active = false
	combo_window_open = false
	combo_input_queued = false
	can_attack = false

	_clear_aim_lock()

	velocity = Vector2.ZERO
	knockback_velocity = Vector2.ZERO
	knockback_timer = 0.0

	stop_equipment_action()

	if animation_player.has_animation(&"death"):
		animation_player.play(&"death", 0.02)

	if damage_tween != null and damage_tween.is_valid():
		damage_tween.kill()

	_set_damage_flash(0.0)

	collision_layer = 0
	collision_mask = 0

	if is_instance_valid(right_hand_item):
		right_hand_item.queue_free()
		right_hand_item = null

	if is_instance_valid(left_hand_item):
		left_hand_item.queue_free()
		left_hand_item = null

	_finish_death_after_delay()


func _finish_death_after_delay() -> void:
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

	current_health = mini(
		current_health + amount,
		max_health
	)

	health_changed.emit(current_health, max_health)

	print(
		"Player healed. Health: %d/%d"
		% [current_health, max_health]
	)


# ==================================================
# ANIMATION HELPERS
# ==================================================

func _play_animation(animation_name: String) -> void:
	if (
		not is_instance_valid(animation_player)
		or combo_active
		or is_dead
	):
		return

	if not animation_player.has_animation(animation_name):
		return

	if (
		animation_player.current_animation != animation_name
		or not animation_player.is_playing()
	):
		animation_player.play(animation_name)


func get_facing_direction() -> Vector2:
	return facing_direction
