
extends CharacterBody2D

enum EnemyState {
	PATROL,
	CHASE,
	ATTACK,
	DEAD
}

@export_group("Detection")
@export var detection_radius: float = 250.0
@export var lose_target_distance: float = 400.0
@export_flags_2d_physics var line_of_sight_collision_mask: int = 0xFFFFFFFF

@export_group("Movement")
@export var patrol_speed: float = 45.0
@export var chase_speed: float = 90.0
@export var patrol_enabled: bool = true
@export var rotation_offset_degrees: float = 0.0

@export_group("Combat")
@export var attack_range: float = 50.0
@export var attack_separation_distance: float = 0.0
@export var attack_damage: int = 10
@export var attack_cooldown: float = 1.0
@export var attack_windup: float = 0.25
@export var attack_active_time: float = 0.15
@export var attack_recovery: float = 0.20

@export_group("Animations")
@export var idle_animation: StringName = &"idle"
@export var move_animation: StringName = &"move"
@export var attack_animation: StringName = &"attack"

@export_group("Shield Interaction")
@export var shield_hitbox_group: StringName = &"shield_hitboxes"
@export var shield_block_method: StringName = &"block_by_shield"
@export var play_block_sound: bool = true

@export_group("Health")
@export var max_health: int = 100

@export_group("Knockback")
@export var knockback_force: float = 260.0
@export var knockback_duration: float = 0.16
@export var knockback_decay: float = 1400.0

@export_group("Damage Visuals")
@export var damage_flash_count: int = 3
@export var damage_flash_duration: float = 0.3


var state: EnemyState = EnemyState.PATROL
var player: Node2D

var patrol_follower: PathFollow2D
var patrol_direction: float = 1.0
var patrol_active: bool = true

var can_attack: bool = true
var attack_in_progress: bool = false
var attack_hit_targets: Array[Node2D] = []
var blocked_this_attack: bool = false

var original_path: Path2D
var returning_to_patrol: bool = false

var current_health: int
var is_dead: bool = false
var damage_tween: Tween
var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_timer: float = 0.0


@onready var body_sprite: Sprite2D = $BodySprite
@onready var weapon_pivot: Node2D = $WeaponPivot
@onready var spear_sprite: Sprite2D = $WeaponPivot/SpearSprite
@onready var left_hand_sprite: Sprite2D = $WeaponPivot/LeftHandSprite
@onready var right_hand_sprite: Sprite2D = $WeaponPivot/RightHandSprite

@onready var spear_hitbox: Area2D = $WeaponPivot/SpearHitbox
@onready var spear_collision: CollisionShape2D = $WeaponPivot/SpearHitbox/CollisionShape2D

@onready var detection_range: Area2D = $DetectionRange
@onready var detection_shape: CollisionShape2D = $DetectionRange/CollisionShape2D

@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var attack_audio: AudioStreamPlayer2D = $AudioStreamPlayer2D


func _ready() -> void:
	add_to_group("enemies")
	add_to_group("enemy")

	current_health = maxi(max_health, 1)
	max_health = current_health

	_setup_damage_shader()

	patrol_follower = get_parent() as PathFollow2D
	patrol_active = patrol_enabled

	if is_instance_valid(patrol_follower):
		original_path = patrol_follower.get_parent() as Path2D
		patrol_follower.loop = false
		patrol_follower.rotates = false
	elif patrol_enabled:
		push_warning(
			"SpearEnemy must be a child of PathFollow2D "
			+ "to use path patrol."
		)

	if detection_shape.shape is CircleShape2D:
		detection_shape.shape = detection_shape.shape.duplicate()
		detection_shape.shape.radius = detection_radius

	spear_hitbox.monitoring = false

	if not spear_hitbox.area_entered.is_connected(
		_on_spear_hitbox_area_entered
	):
		spear_hitbox.area_entered.connect(
			_on_spear_hitbox_area_entered
		)

	if not spear_hitbox.body_entered.is_connected(
		_on_spear_hitbox_body_entered
	):
		spear_hitbox.body_entered.connect(
			_on_spear_hitbox_body_entered
		)

	if not detection_range.body_entered.is_connected(
		_on_detection_body_entered
	):
		detection_range.body_entered.connect(
			_on_detection_body_entered
		)

	if not detection_range.body_exited.is_connected(
		_on_detection_body_exited
	):
		detection_range.body_exited.connect(
			_on_detection_body_exited
		)

	_play_animation(idle_animation)


func _physics_process(delta: float) -> void:
	if is_dead or state == EnemyState.DEAD:
		return

	# Knockback temporarily overrides AI movement and pauses patrol/chase.
	if knockback_timer > 0.0:
		knockback_timer = maxf(knockback_timer - delta, 0.0)
		velocity = knockback_velocity
		move_and_slide()
		knockback_velocity = knockback_velocity.move_toward(
			Vector2.ZERO,
			knockback_decay * delta
		)
		if knockback_timer <= 0.0:
			knockback_velocity = Vector2.ZERO
		return

	_find_player_if_needed()

	if not is_instance_valid(player):
		if state == EnemyState.CHASE:
			_return_to_patrol()
		elif state == EnemyState.PATROL:
			_update_patrol(delta)
		return

	var distance_to_player := global_position.distance_to(
		player.global_position
	)

	match state:
		EnemyState.PATROL:
			if (
				distance_to_player <= detection_radius
				and _has_line_of_sight(player)
			):
				_begin_chase()
			else:
				_update_patrol(delta)

		EnemyState.CHASE:
			if distance_to_player > lose_target_distance:
				_lose_player()
				return

			if not _has_line_of_sight(player):
				_lose_player()
				return

			if distance_to_player <= attack_range:
				velocity = Vector2.ZERO
				_face_direction(
					player.global_position - global_position
				)

				if can_attack and not attack_in_progress:
					_start_attack()
			else:
				_chase_player()

		EnemyState.ATTACK:
			if (
				not is_instance_valid(player)
				or not _has_line_of_sight(player)
			):
				_lose_player()
				return

			_maintain_attack_separation()

		EnemyState.DEAD:
			return


func _find_player_if_needed() -> void:
	if is_instance_valid(player):
		return

	var candidate := get_tree().get_first_node_in_group("player")

	if candidate is Node2D:
		player = candidate


func _has_line_of_sight(target: Node2D) -> bool:
	if not is_instance_valid(target):
		return false

	var query := PhysicsRayQueryParameters2D.create(
		global_position,
		target.global_position,
		line_of_sight_collision_mask
	)

	query.exclude = [get_rid()]
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var result := get_world_2d().direct_space_state.intersect_ray(query)

	if result.is_empty():
		return false

	var collider = result.get("collider")

	if not is_instance_valid(collider):
		return false

	if collider == target:
		return true

	if collider is Node and target.is_ancestor_of(collider):
		return true

	return false


func _lose_player() -> void:
	player = null
	_return_to_patrol()


func _update_patrol(delta: float) -> void:
	if not patrol_active or not is_instance_valid(patrol_follower):
		velocity = Vector2.ZERO
		_play_animation(idle_animation)
		return

	var path := patrol_follower.get_parent() as Path2D

	if path == null or path.curve == null:
		_play_animation(idle_animation)
		return

	var path_length := path.curve.get_baked_length()

	if path_length <= 0.0:
		return

	patrol_follower.progress += (
		patrol_speed * delta * patrol_direction
	)

	if patrol_follower.progress >= path_length:
		patrol_follower.progress = path_length
		patrol_direction = -1.0
	elif patrol_follower.progress <= 0.0:
		patrol_follower.progress = 0.0
		patrol_direction = 1.0

	var sample_distance := clampf(
		patrol_follower.progress + patrol_direction * 2.0,
		0.0,
		path_length
	)

	var point_a := path.curve.sample_baked(
		patrol_follower.progress
	)
	var point_b := path.curve.sample_baked(sample_distance)

	var direction := (
		path.to_global(point_b) - path.to_global(point_a)
	)

	if direction.length_squared() < 0.001:
		direction = Vector2.RIGHT * patrol_direction

	_face_direction(direction)
	_play_animation(move_animation)


func _begin_chase() -> void:
	if state != EnemyState.PATROL or is_dead:
		return

	state = EnemyState.CHASE
	velocity = Vector2.ZERO

	if is_instance_valid(patrol_follower):
		var current_scene := get_tree().current_scene

		if current_scene != null:
			reparent(current_scene, true)

	_play_animation(move_animation)


func _chase_player() -> void:
	if not is_instance_valid(player) or is_dead:
		return

	var direction := (
		player.global_position - global_position
	).normalized()

	_face_direction(direction)
	velocity = direction * chase_speed
	move_and_slide()

	_play_animation(move_animation)


func _return_to_patrol() -> void:
	if returning_to_patrol or is_dead:
		return

	returning_to_patrol = true
	state = EnemyState.PATROL
	velocity = Vector2.ZERO
	spear_hitbox.set_deferred("monitoring", false)

	if (
		is_instance_valid(patrol_follower)
		and is_instance_valid(original_path)
		and original_path.curve != null
	):
		var local_position := original_path.to_local(
			global_position
		)

		patrol_follower.progress = (
			original_path.curve.get_closest_offset(
				local_position
			)
		)

		reparent(patrol_follower, false)
		position = Vector2.ZERO
		rotation = 0.0

		var path_length := original_path.curve.get_baked_length()

		if patrol_follower.progress >= path_length * 0.5:
			patrol_direction = -1.0
		else:
			patrol_direction = 1.0

	_play_animation(idle_animation)
	returning_to_patrol = false


func _face_direction(direction: Vector2) -> void:
	if direction.length_squared() < 0.001:
		return

	global_rotation = (
		direction.angle()
		+ deg_to_rad(rotation_offset_degrees)
	)


func _maintain_attack_separation() -> void:
	if not is_instance_valid(player):
		return

	var offset := global_position - player.global_position
	var distance := offset.length()

	if distance < attack_separation_distance:
		var direction := Vector2.RIGHT

		if distance > 0.001:
			direction = offset / distance

		global_position = (
			player.global_position
			+ direction * attack_separation_distance
		)

	velocity = Vector2.ZERO
	_face_direction(player.global_position - global_position)


func _start_attack() -> void:
	if state != EnemyState.CHASE or is_dead:
		return

	if attack_in_progress or not can_attack:
		return

	state = EnemyState.ATTACK
	attack_in_progress = true
	can_attack = false
	blocked_this_attack = false
	attack_hit_targets.clear()

	velocity = Vector2.ZERO

	if is_instance_valid(player):
		_face_direction(player.global_position - global_position)

	_maintain_attack_separation()
	_play_animation(attack_animation)

	if attack_audio.stream != null:
		attack_audio.play()

	await get_tree().create_timer(attack_windup).timeout

	if not is_inside_tree() or is_dead or blocked_this_attack:
		_finish_attack_early()
		return

	if not is_instance_valid(player) or not _has_line_of_sight(player):
		_finish_attack_early()
		if not is_dead:
			_lose_player()
		return

	_maintain_attack_separation()
	spear_hitbox.set_deferred("monitoring", true)

	await get_tree().physics_frame

	if not is_inside_tree() or is_dead or blocked_this_attack:
		_finish_attack_early()
		return

	if not is_instance_valid(player) or not _has_line_of_sight(player):
		_finish_attack_early()
		if not is_dead:
			_lose_player()
		return

	if spear_hitbox.monitoring:
		for area in spear_hitbox.get_overlapping_areas():
			_handle_shield_collision(area)

		for body in spear_hitbox.get_overlapping_bodies():
			_apply_spear_hit(body)

	await get_tree().create_timer(attack_active_time).timeout

	if not is_inside_tree() or is_dead or blocked_this_attack:
		_finish_attack_early()
		return

	spear_hitbox.set_deferred("monitoring", false)

	await get_tree().create_timer(attack_recovery).timeout

	if not is_inside_tree() or is_dead:
		_finish_attack_early()
		return

	attack_in_progress = false
	state = EnemyState.CHASE
	_play_animation(move_animation)

	_reset_attack_cooldown()


func _finish_attack_early() -> void:
	spear_hitbox.set_deferred("monitoring", false)
	attack_in_progress = false


func _reset_attack_cooldown() -> void:
	await get_tree().create_timer(attack_cooldown).timeout

	if is_inside_tree() and not is_dead:
		can_attack = true


func _on_spear_hitbox_area_entered(area: Area2D) -> void:
	if is_dead or state != EnemyState.ATTACK:
		return

	if not spear_hitbox.monitoring:
		return

	_handle_shield_collision(area)


func _handle_shield_collision(area: Area2D) -> void:
	if not is_instance_valid(area):
		return

	if not area.is_in_group(shield_hitbox_group):
		return

	if blocked_this_attack or not is_instance_valid(player):
		return

	# Find the Equipment node that owns the shield hitbox.
	var shield_node: Node = area
	while is_instance_valid(shield_node) and shield_node != player:
		if _has_property(shield_node, &"blocking_active"):
			if not bool(shield_node.get("blocking_active")):
				return

			var blocked := false
			if shield_node.has_method("try_block_melee_attack"):
				blocked = bool(shield_node.call("try_block_melee_attack", self))
			else:
				# Fallback for shield scripts without the helper method.
				blocked = true

			if not blocked:
				return

			on_blocked_by_shield(shield_node as Node2D)
			return

		shield_node = shield_node.get_parent()


func on_blocked_by_shield(shield: Node2D) -> void:
	# This can be called from either the shield overlap callback or Player's
	# damage guard. Ignore duplicate notifications for the same attack.
	if is_dead or state != EnemyState.ATTACK or blocked_this_attack:
		return

	blocked_this_attack = true
	if is_instance_valid(player) and player not in attack_hit_targets:
		attack_hit_targets.append(player)

	spear_hitbox.set_deferred("monitoring", false)
	_apply_block_knockback(shield)
	_finish_attack_early()

	state = EnemyState.CHASE
	_play_animation(move_animation)
	# A blocked attack ends before the normal cooldown reset point.
	_reset_attack_cooldown()


func _apply_block_knockback(source: Node2D) -> void:
	if not is_instance_valid(source) or is_dead:
		return

	var direction := global_position - source.global_position
	if direction.length_squared() < 0.001:
		direction = Vector2.RIGHT.rotated(global_rotation)

	knockback_velocity = direction.normalized() * knockback_force
	knockback_timer = maxf(knockback_duration, 0.0)


func _has_property(
	object: Object,
	property_name: StringName
) -> bool:
	for property_info in object.get_property_list():
		if StringName(property_info["name"]) == property_name:
			return true

	return false


func _play_shield_block_sound() -> void:
	if not play_block_sound:
		return

	var audio_manager := get_node_or_null("/root/AudioManager")

	if (
		audio_manager != null
		and audio_manager.has_method("play_shield_impact")
	):
		audio_manager.call("play_shield_impact")


func _on_spear_hitbox_body_entered(body: Node2D) -> void:
	if is_dead or state != EnemyState.ATTACK:
		return

	if not spear_hitbox.monitoring or blocked_this_attack:
		return

	_apply_spear_hit(body)


func _apply_spear_hit(body: Node2D) -> void:
	if is_dead or not body.is_in_group("player"):
		return

	if blocked_this_attack or body in attack_hit_targets:
		return

	if not _has_line_of_sight(body):
		return

	attack_hit_targets.append(body)

	if body.has_method("take_damage"):
		body.take_damage(attack_damage, self)
	else:
		push_warning("Player needs a take_damage(amount, attacker) method.")


func _on_detection_body_entered(body: Node2D) -> void:
	if is_dead:
		return

	if body.is_in_group("player") and _has_line_of_sight(body):
		player = body


func _on_detection_body_exited(body: Node2D) -> void:
	if body == player:
		# Physics processing handles range and line-of-sight checks.
		pass


func _play_animation(animation_name: StringName) -> void:
	if is_dead:
		return

	if not animation_player.has_animation(animation_name):
		push_warning(
			"Missing animation: " + String(animation_name)
		)
		return

	if animation_player.current_animation == animation_name:
		return

	animation_player.play(animation_name)


# --------------------------------------------------
# HEALTH AND DAMAGE
# --------------------------------------------------

func _setup_damage_shader() -> void:
	if body_sprite == null:
		push_warning("SpearEnemy: BodySprite was not found.")
		return

	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material == null:
		push_warning(
			"SpearEnemy: Assign the player's damage ShaderMaterial "
			+ "to BodySprite."
		)
		return

	# Each enemy gets an independent material instance.
	body_sprite.material = shader_material.duplicate()

	shader_material = body_sprite.material as ShaderMaterial
	shader_material.set_shader_parameter("damage_flash", 0.0)


func take_damage(amount: int, attacker: Node2D = null) -> void:
	if is_dead or amount <= 0:
		return

	current_health = maxi(current_health - amount, 0)

	_apply_knockback(attacker)
	_play_damage_flash()

	print(
		"Spear enemy health: ",
		current_health,
		"/",
		max_health
	)

	if current_health <= 0:
		_die()


func _apply_knockback(attacker: Node2D = null) -> void:
	var source := attacker

	if not is_instance_valid(source):
		var candidate := get_tree().get_first_node_in_group("player")
		if candidate is Node2D:
			source = candidate

	var direction := Vector2.ZERO
	if is_instance_valid(source):
		direction = global_position - source.global_position

	if direction.length_squared() < 0.001:
		# Fallback: push opposite the enemy's current facing direction.
		direction = Vector2.RIGHT.rotated(global_rotation)

	knockback_velocity = direction.normalized() * knockback_force
	knockback_timer = maxf(knockback_duration, 0.0)


func _play_damage_flash() -> void:
	if body_sprite == null:
		return

	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material == null:
		return

	if damage_tween and damage_tween.is_valid():
		damage_tween.kill()

	damage_tween = create_tween()

	var half_flash_duration := (
		maxf(damage_flash_duration, 0.01)
		/ float(maxi(damage_flash_count * 2, 1))
	)

	shader_material.set_shader_parameter("damage_flash", 0.0)

	for i in range(damage_flash_count):
		damage_tween.tween_method(
			_set_damage_flash,
			0.0,
			1.0,
			half_flash_duration
		)

		damage_tween.tween_method(
			_set_damage_flash,
			1.0,
			0.0,
			half_flash_duration
		)

	damage_tween.tween_callback(
		func() -> void:
			_set_damage_flash(0.0)
	)


func _set_damage_flash(value: float) -> void:
	if body_sprite == null:
		return

	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material:
		shader_material.set_shader_parameter(
			"damage_flash",
			value
		)


func _die() -> void:
	if is_dead:
		return

	is_dead = true
	knockback_velocity = Vector2.ZERO
	knockback_timer = 0.0
	state = EnemyState.DEAD

	velocity = Vector2.ZERO
	can_attack = false
	attack_in_progress = false
	patrol_active = false
	player = null

	spear_hitbox.set_deferred("monitoring", false)
	detection_range.set_deferred("monitoring", false)

	if attack_audio.playing:
		attack_audio.stop()

	if damage_tween and damage_tween.is_valid():
		damage_tween.kill()

	_set_damage_flash(0.0)

	set_collision_layer_value(1, false)
	set_collision_mask_value(1, false)

	print("Spear enemy defeated.")

	queue_free()
