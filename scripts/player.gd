
extends CharacterBody2D

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

var locked_target: Node2D = null


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


# ==================================================
# COMBO STATE
# ==================================================

var combo_active: bool = false
var combo_step: int = 0
var combo_window_open: bool = false
var combo_input_queued: bool = false

var _combo_run_id: int = 0

var _body_speed_before_combo: float = 1.0
var _sword_speed_before_combo: float = 1.0
var _shield_speed_before_combo: float = 1.0

# ==================================================
# NODE REFERENCES
# ==================================================

@onready var body_pivot: Node2D = $BodyPivot
@onready var body_sprite: Sprite2D = $BodyPivot/BodySprite

@onready var animation_player: AnimationPlayer = (
	$BodyPivot/AnimationPlayer
)

@onready var left_hand_pivot: Node2D = $LeftHandPivot
@onready var right_hand_pivot: Node2D = $RightHandPivot

@onready var left_socket: Marker2D = (
	$LeftHandPivot/EquipmentSocket
)

@onready var right_socket: Marker2D = (
	$RightHandPivot/EquipmentSocket
)


signal health_changed(current_health: int, max_health: int)


# ==================================================
# INITIALIZATION
# ==================================================

func _ready() -> void:
	add_to_group("player")

	# Apply shield orientation after normal animation processing.
	process_priority = 100

	max_health = maxi(max_health, 1)
	current_health = max_health

	health_changed.emit(current_health, max_health)

	_setup_damage_shader()

	joystick_node = get_tree().get_first_node_in_group("joystick")

	if is_instance_valid(joystick_node):
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


# ==================================================
# JOYSTICK INPUT
# ==================================================

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


# ==================================================
# BLOCK ORIENTATION
# ==================================================

func _process(_delta: float) -> void:
	if is_dead or not is_blocking:
		return

	_set_hand_pivots_for_facing_direction()
	_orient_blocking_shield()


func _set_hand_pivots_for_facing_direction() -> void:
	var target_angle: float = facing_direction.angle() + PI / 2.0

	left_hand_pivot.rotation = target_angle
	right_hand_pivot.rotation = target_angle


func _orient_blocking_shield() -> void:
	if not is_instance_valid(left_hand_item):
		return

	var shield_pivot := (
		left_hand_item.get_node_or_null("ShieldPivot") as Node2D
	)

	if shield_pivot == null:
		return

	shield_pivot.global_rotation = (
		facing_direction.angle()
		+ deg_to_rad(shield_forward_offset_degrees)
	)


# ==================================================
# MOVEMENT
# ==================================================

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
		knockback_timer = maxf(
			knockback_timer - delta,
			0.0
		)

		velocity = knockback_velocity

		knockback_velocity = knockback_velocity.move_toward(
			Vector2.ZERO,
			knockback_force * knockback_decay * delta
		)

		if knockback_timer <= 0.0:
			knockback_velocity = Vector2.ZERO
	else:
		velocity = direction * SPEED

	move_and_slide()

	var is_moving: bool = (
		direction.length_squared() > 0.001
		or knockback_timer > 0.0
	)

	# Aim lock controls facing during a combo.
	if combo_active and is_instance_valid(locked_target):
		_update_aim_lock()
	elif not combo_active and direction.length_squared() > 0.001:
		facing_direction = direction.normalized()

	# Idle and movement animations must continue while blocking.
	# Only the hand-pivot updates are suppressed during the block,
	# since the shield and hand pose are controlled by the block setup.
	if not combo_active:
		if is_moving:
			_play_animation("move")
		else:
			_play_animation("idle")

		if not is_blocking:
			_update_hands(delta)

	if Input.is_action_just_pressed("attack"):
		attack()

	if Input.is_action_just_pressed("block"):
		start_block()

	if Input.is_action_just_released("block"):
		stop_block()


func _update_hands(delta: float) -> void:
	var target_angle: float = facing_direction.angle() + PI / 2.0
	var weight: float = minf(hand_rotation_speed * delta, 1.0)

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

		# Ignore enemies exposing an is_dead property when it is true.
		var has_dead_property: bool = false

		for property_info in enemy.get_property_list():
			if StringName(property_info["name"]) == &"is_dead":
				has_dead_property = true
				break

		if has_dead_property and bool(enemy.get("is_dead")):
			continue

		var distance: float = global_position.distance_to(
			enemy.global_position
		)

		if distance <= nearest_distance:
			nearest_distance = distance
			nearest_enemy = enemy

	return nearest_enemy


func _update_aim_lock() -> void:
	if not is_instance_valid(locked_target):
		locked_target = null
		return

	if locked_target.is_queued_for_deletion():
		locked_target = null
		return

	var target_direction: Vector2 = (
		locked_target.global_position - global_position
	)

	if target_direction.length_squared() < 0.001:
		return

	facing_direction = target_direction.normalized()
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


func _get_item_animation_player(
	item: Equipment
) -> AnimationPlayer:
	if not is_instance_valid(item):
		return null

	return item.get_node_or_null("AnimationPlayer") as AnimationPlayer


# ==================================================
# COMBO ENTRY POINT
# ==================================================

func attack() -> void:
	if is_dead or is_blocking:
		return

	if not is_instance_valid(right_hand_item):
		return

	# A click during the combo window queues the next strike.
	if combo_active:
		if combo_window_open and combo_step < 3:
			combo_input_queued = true
		return

	if not can_attack:
		return

	# Select a target when the combo starts.
	locked_target = _acquire_aim_lock_target()

	if is_instance_valid(locked_target):
		var direction_to_target: Vector2 = (
			locked_target.global_position - global_position
		)

		if direction_to_target.length_squared() > 0.001:
			facing_direction = direction_to_target.normalized()
			_set_hand_pivots_for_facing_direction()

	combo_active = true
	can_attack = false
	combo_step = 0
	combo_window_open = false
	combo_input_queued = false

	_combo_run_id += 1

	_body_speed_before_combo = animation_player.speed_scale

	var sword_player := _get_item_animation_player(right_hand_item)

	if sword_player:
		_sword_speed_before_combo = sword_player.speed_scale

	var shield_player := _get_item_animation_player(left_hand_item)

	if shield_player:
		_shield_speed_before_combo = shield_player.speed_scale

	_run_combo_sequence(_combo_run_id)


# ==================================================
# COMBO SEQUENCE
# ==================================================

func _run_combo_sequence(run_id: int) -> void:
	for step in range(1, 4):
		if not _combo_run_is_valid(run_id):
			return

		combo_step = step
		combo_input_queued = false
		combo_window_open = false

		_play_combo_step(step)

		var animation_duration: float = _get_combo_step_duration(step)

		animation_duration = maxf(
			animation_duration,
			maxf(attack_cooldown, 0.05)
		)

		var window_start: float = clampf(
			animation_duration * combo_window_start_ratio,
			0.05,
			maxf(animation_duration - 0.02, 0.05)
		)

		await get_tree().create_timer(window_start).timeout

		if not _combo_run_is_valid(run_id):
			return

		combo_window_open = step < 3

		var remaining_time: float = maxf(
			animation_duration - window_start,
			0.02
		)

		await get_tree().create_timer(remaining_time).timeout

		if not _combo_run_is_valid(run_id):
			return

		combo_window_open = false

		if step >= 3 or not combo_input_queued:
			break

	if not _combo_run_is_valid(run_id):
		return

	if combo_recovery_time > 0.0:
		await get_tree().create_timer(
			combo_recovery_time
		).timeout

	if not _combo_run_is_valid(run_id):
		return

	_restore_combo_animation_speeds()

	combo_active = false
	combo_step = 0
	combo_window_open = false
	combo_input_queued = false
	can_attack = true

	_clear_aim_lock()

	if is_blocking:
		return

	if velocity.length_squared() > 1.0:
		_play_animation("move")
	else:
		_play_animation("idle")


func _combo_run_is_valid(run_id: int) -> bool:
	return (
		is_inside_tree()
		and not is_dead
		and combo_active
		and _combo_run_id == run_id
	)


func _restore_combo_animation_speeds() -> void:
	animation_player.speed_scale = _body_speed_before_combo

	var sword_player := _get_item_animation_player(right_hand_item)

	if sword_player:
		sword_player.speed_scale = _sword_speed_before_combo

	var shield_player := _get_item_animation_player(left_hand_item)

	if shield_player:
		shield_player.speed_scale = _shield_speed_before_combo


# ==================================================
# COMBO ANIMATION PLAYBACK
# ==================================================

func _play_combo_step(step: int) -> void:
	var animation_name: StringName = _get_combo_animation_name(step)

	# The body uses the generic attack clip if a separate combo clip
	# has not been authored for it. This fallback is intentionally silent.
	var body_animation: StringName = animation_name

	if not animation_player.has_animation(body_animation):
		body_animation = &"attack"

	if animation_player.has_animation(body_animation):
		animation_player.speed_scale = 1.0
		animation_player.play(body_animation, 0.025)

	# The Sword has separate clips for the combo.
	_play_equipment_animation(
		right_hand_item,
		animation_name,
		&"attack"
	)

	# The Shield participates only in the third finisher.
	if step == 3:
		_play_equipment_animation(
			left_hand_item,
			&"attack_3",
			&""
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
	fallback_animation: StringName
) -> void:
	if not is_instance_valid(item):
		return

	var item_player := _get_item_animation_player(item)

	if item_player == null:
		push_warning(
            "Equipment '%s' has no AnimationPlayer."
			% item.name
		)
		return

	var animation_to_play: StringName = preferred_animation

	if not item_player.has_animation(animation_to_play):
		if (
			fallback_animation != &""
			and item_player.has_animation(fallback_animation)
		):
			animation_to_play = fallback_animation
		else:
			push_warning(
                "Animation '%s' is missing from equipment '%s'."
				% [String(preferred_animation), item.name]
			)
			return

	# Match playback speed across each participating scene.
	item_player.speed_scale = 1.0
	item_player.play(animation_to_play, 0.025)

	if item.has_method("set_combo_step"):
		var combo_number: int = 1

		match preferred_animation:
			&"attack_2":
				combo_number = 2
			&"attack_3":
				combo_number = 3

		item.call("set_combo_step", combo_number)


# ==================================================
# COMBO ANIMATION DURATION
# ==================================================

func _get_combo_step_duration(step: int) -> float:
	var animation_name: StringName = _get_combo_animation_name(step)
	var duration: float = 0.05

	# Player body: use the matching animation or the generic attack.
	var body_animation: StringName = animation_name

	if not animation_player.has_animation(body_animation):
		body_animation = &"attack"

	if animation_player.has_animation(body_animation):
		duration = maxf(
			duration,
			animation_player.get_animation(body_animation).length
		)

	# Sword duration.
	var sword_player := _get_item_animation_player(right_hand_item)

	if sword_player:
		var sword_animation: StringName = animation_name

		if not sword_player.has_animation(sword_animation):
			sword_animation = &"attack"

		if sword_player.has_animation(sword_animation):
			duration = maxf(
				duration,
				sword_player.get_animation(sword_animation).length
			)

	# The finisher also waits for the Shield's attack_3 animation.
	if step == 3:
		var shield_player := _get_item_animation_player(left_hand_item)

		if shield_player and shield_player.has_animation(&"attack_3"):
			duration = maxf(
				duration,
				shield_player.get_animation(&"attack_3").length
			)

	return duration


# ==================================================
# SHIELD BLOCK
# ==================================================

func start_block() -> void:
	if is_dead or is_blocking or combo_active:
		return

	is_blocking = true

	_set_hand_pivots_for_facing_direction()

	# Let Player idle/move keep running. Equipment animations handle
	# the defensive poses without replacing the player's locomotion clip.
	if is_instance_valid(left_hand_item):
		left_hand_item.block()

	if is_instance_valid(right_hand_item):
		right_hand_item.block()

	_orient_blocking_shield()


func stop_block() -> void:
	if not is_blocking:
		return

	is_blocking = false

	if is_instance_valid(left_hand_item):
		left_hand_item.stop_action()

	if is_instance_valid(right_hand_item):
		right_hand_item.stop_action()

	if velocity.length_squared() > 1.0:
		_play_animation("move")
	else:
		_play_animation("idle")


func stop_equipment_action() -> void:
	if is_instance_valid(right_hand_item):
		right_hand_item.stop_action()

	if is_instance_valid(left_hand_item):
		left_hand_item.stop_action()


# ==================================================
# SHIELD DAMAGE CHECK
# ==================================================

func _try_block_incoming_damage(
	attacker: Node2D = null
) -> bool:
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


# ==================================================
# DAMAGE
# ==================================================

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

	if not bypass_invulnerability:
		_start_invulnerability()

	return true


func _apply_knockback(attacker: Node2D = null) -> void:
	var knockback_direction: Vector2

	if is_instance_valid(attacker):
		knockback_direction = (
			global_position - attacker.global_position
		).normalized()
	else:
		knockback_direction = -facing_direction

	if knockback_direction.length_squared() < 0.001:
		knockback_direction = -facing_direction

	knockback_velocity = knockback_direction * knockback_force
	knockback_timer = maxf(knockback_duration, 0.0)


# ==================================================
# DAMAGE FLASH
# ==================================================

func _play_damage_flash() -> void:
	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material == null:
		return

	if damage_tween and damage_tween.is_valid():
		damage_tween.kill()

	damage_tween = create_tween()

	var single_flash_duration: float = (
		damage_flash_duration
		/ float(maxi(damage_flash_count * 2, 1))
	)

	shader_material.set_shader_parameter("damage_flash", 0.0)

	for _index in range(damage_flash_count):
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


# ==================================================
# INVULNERABILITY
# ==================================================

func _start_invulnerability() -> void:
	is_invulnerable = true

	await get_tree().create_timer(
		invulnerability_duration
	).timeout

	if is_inside_tree() and not is_dead:
		is_invulnerable = false


# ==================================================
# DEATH
# ==================================================

func _die() -> void:
	if is_dead:
		return

	is_dead = true

	_combo_run_id += 1
	combo_active = false
	combo_window_open = false
	combo_input_queued = false
	_clear_aim_lock()

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


# ==================================================
# HEALING
# ==================================================

func heal(amount: int) -> void:
	if is_dead or amount <= 0:
		return

	current_health = mini(
		current_health + amount,
		max_health
	)

	health_changed.emit(current_health, max_health)

	print(
		"Player healed. Health: ",
		current_health,
		"/",
		max_health
	)


# ==================================================
# ATTACK STATE
# ==================================================

func _is_attacking() -> bool:
	if combo_active:
		return true

	var attack_names: Array[StringName] = [
		&"attack",
		&"attack_2",
		&"attack_3"
	]

	if (
		attack_names.has(animation_player.current_animation)
		and animation_player.is_playing()
	):
		return true

	if not is_instance_valid(right_hand_item):
		return false

	var sword_player := _get_item_animation_player(right_hand_item)

	if sword_player == null:
		return false

	return (
		attack_names.has(sword_player.current_animation)
		and sword_player.is_playing()
	)


# ==================================================
# ANIMATION HELPER
# ==================================================

func _play_animation(animation_name: String) -> void:
	if not is_instance_valid(animation_player):
		return

	# Combo takes priority, but blocking does not suppress locomotion.
	if combo_active:
		return

	if not animation_player.has_animation(animation_name):
		return

	if animation_player.current_animation != animation_name:
		animation_player.play(animation_name)


func get_facing_direction() -> Vector2:
	return facing_direction
