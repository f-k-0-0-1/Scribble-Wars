
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
@export var chase_speed: float = 85.0
@export var patrol_enabled: bool = true
@export var rotation_offset_degrees: float = 0.0
@export var body_collision_radius: float = 22.0

@export_group("Combat")
@export var attack_range: float = 65.0
@export var attack_damage: int = 15
@export var attack_cooldown: float = 1.2
@export var attack_windup: float = 0.1
@export var attack_active_time: float = 0.75
@export var attack_recovery: float = 0.15
@export var attack_animation_repeats: int = 1
@export var thrust_distance: float = 45.0
@export var attack_separation_distance: float = 5.0

@export_group("Spin Damage")
@export_range(1, 10, 1) var spin_damage_hit_count: int = 5

@export_group("Animations")
@export var idle_animation: StringName = &"idle"
@export var move_animation: StringName = &"move"
@export var attack_animation: StringName = &"attack"

@export_group("Shield Interaction")
@export var shield_hitbox_group: StringName = &"shield_hitboxes"
@export var play_block_sound: bool = true
@export var shield_block_repeat_interval: float = 0.18

@export_group("Health")
@export var max_health: int = 100

@export_group("Knockback")
@export var knockback_force: float = 280.0
@export var knockback_duration: float = 0.16
@export var knockback_decay: float = 1500.0

@export_group("Damage Visuals")
@export var damage_flash_count: int = 3
@export var damage_flash_duration: float = 0.3


var state: EnemyState = EnemyState.PATROL
var player: Node2D

var patrol_follower: PathFollow2D
var original_path: Path2D
var patrol_direction: float = 1.0
var patrol_active: bool = true
var returning_to_patrol: bool = false

var can_attack: bool = true
var attack_in_progress: bool = false
var last_shield_impact_elapsed: float = -999.0
var spin_hits_applied_to_player: int = 0
var last_player_spin_hit_elapsed: float = -999.0

var attack_direction: Vector2 = Vector2.RIGHT
var attack_thrust_velocity: float = 0.0
var attack_thrust_distance_remaining: float = 0.0
var attack_phase: int = 0
var attack_elapsed: float = 0.0
var hitbox_activation_pending: bool = false
var attack_token: int = 0

var current_health: int
var is_dead: bool = false
var damage_tween: Tween
var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_timer: float = 0.0


@onready var enemy_collision_shape: CollisionShape2D = $CollisionShape2D
@onready var body_pivot: Node2D = $BodyPivot
@onready var body_sprite: Sprite2D = $BodyPivot/BodySprite

@onready var left_hand_pivot: Node2D = $BodyPivot/LeftHandPivot
@onready var left_hand_sprite: Sprite2D = $BodyPivot/LeftHandPivot/LeftHandSprite
@onready var left_axe_pivot: Node2D = $BodyPivot/LeftHandPivot/LeftAxePivot
@onready var left_axe_sprite: Sprite2D = $BodyPivot/LeftHandPivot/LeftAxePivot/LeftAxeSprite

@onready var right_hand_pivot: Node2D = $BodyPivot/RightHandPivot
@onready var right_hand_sprite: Sprite2D = $BodyPivot/RightHandPivot/RightHandSprite
@onready var right_axe_pivot: Node2D = $BodyPivot/RightHandPivot/RightAxePivot
@onready var right_axe_sprite: Sprite2D = $BodyPivot/RightHandPivot/RightAxePivot/RightAxeSprite

@onready var detection_range: Area2D = $DetectionRange
@onready var detection_shape: CollisionShape2D = $DetectionRange/CollisionShape2D

@onready var attack_hitbox: Area2D = $AttackHitbox
@onready var attack_collision: CollisionShape2D = $AttackHitbox/CollisionShape2D

@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var attack_audio: AudioStreamPlayer2D = $AudioStreamPlayer2D


func _ready() -> void:
	add_to_group("enemies")
	add_to_group("enemy")

	current_health = maxi(max_health, 1)
	max_health = current_health

	# Give the large visual sprite a compact physical body. Duplicate the shape
	# first so changing this enemy does not modify a shared CircleShape2D resource.
	if enemy_collision_shape.shape is CircleShape2D:
		var adjusted_shape := enemy_collision_shape.shape.duplicate() as CircleShape2D
		adjusted_shape.radius = maxf(body_collision_radius, 1.0)
		enemy_collision_shape.shape = adjusted_shape

	_setup_damage_shader()

	patrol_follower = get_parent() as PathFollow2D
	patrol_active = patrol_enabled

	if is_instance_valid(patrol_follower):
		original_path = patrol_follower.get_parent() as Path2D
		patrol_follower.loop = false
		patrol_follower.rotates = false
	elif patrol_enabled:
		push_warning(
			"DualAxeEnemy must be a child of PathFollow2D "
			+ "to use path patrol."
		)

	if detection_shape.shape is CircleShape2D:
		detection_shape.shape = detection_shape.shape.duplicate()
		detection_shape.shape.radius = detection_radius

	attack_hitbox.monitoring = false

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

	if not attack_hitbox.body_entered.is_connected(
		_on_attack_hitbox_body_entered
	):
		attack_hitbox.body_entered.connect(
			_on_attack_hitbox_body_entered
		)

	if not attack_hitbox.area_entered.is_connected(
		_on_attack_hitbox_area_entered
	):
		attack_hitbox.area_entered.connect(
			_on_attack_hitbox_area_entered
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

	match state:
		EnemyState.PATROL:
			velocity = Vector2.ZERO

			if is_instance_valid(player):
				var distance := global_position.distance_to(
					player.global_position
				)

				if (
					distance <= detection_radius
					and _has_line_of_sight(player)
				):
					_begin_chase()
					return

			_update_patrol(delta)

		EnemyState.CHASE:
			if not is_instance_valid(player):
				_lose_player()
				return

			var distance := global_position.distance_to(
				player.global_position
			)

			if (
				distance > lose_target_distance
				or not _has_line_of_sight(player)
			):
				_lose_player()
				return

			if distance <= attack_range and can_attack:
				velocity = Vector2.ZERO
				_face_direction(
					player.global_position - global_position
				)
				_start_attack()
			else:
				_chase_player(delta)

		EnemyState.ATTACK:
			if (
				not is_instance_valid(player)
				or not _has_line_of_sight(player)
			):
				_lose_player()
				return

			_update_attack(delta)

			if state != EnemyState.ATTACK:
				return

			if attack_thrust_velocity != 0.0:
				velocity = attack_direction * attack_thrust_velocity
				move_and_slide()
			else:
				velocity = Vector2.ZERO

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

	var collider: Object = result.get("collider")

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


func _chase_player(delta: float) -> void:
	if not is_instance_valid(player) or is_dead:
		return

	var offset := player.global_position - global_position
	var distance := offset.length()
	if distance < 0.001:
		velocity = Vector2.ZERO
		return

	var direction := offset / distance
	_face_direction(direction)

	# Once within attack range, hold position during the cooldown instead of
	# continuously pushing into the player's body or shield.
	if distance <= attack_range:
		velocity = Vector2.ZERO
		_play_animation(idle_animation)
		return

	# Clamp each chase step at a safe distance based on both collision shapes.
	# This prevents the enemy from becoming wedged against the player.
	var distance_to_move := maxf(
		distance - _minimum_player_separation(),
		0.0
	)
	var step_speed := minf(
		maxf(chase_speed, 0.0),
		distance_to_move / maxf(delta, 0.001)
	)
	velocity = direction * step_speed
	move_and_slide()

	_play_animation(move_animation)


func _minimum_player_separation() -> float:
	# The distance between character centres needed to keep the circular body
	# collision shapes separate, plus a small spacing buffer.
	return (
		_get_circle_radius(enemy_collision_shape)
		+ _get_circle_radius(_get_player_collision_shape())
		+ maxf(attack_separation_distance, 0.0)
	)


func _get_player_collision_shape() -> CollisionShape2D:
	if not is_instance_valid(player):
		return null

	return player.get_node_or_null("CollisionShape2D") as CollisionShape2D


func _get_circle_radius(collision_shape: CollisionShape2D) -> float:
	if not is_instance_valid(collision_shape) or collision_shape.disabled:
		return 0.0

	if collision_shape.shape is CircleShape2D:
		var circle := collision_shape.shape as CircleShape2D
		var shape_scale := collision_shape.global_scale.abs()
		return circle.radius * maxf(shape_scale.x, shape_scale.y)

	# For non-circular shapes, rely on the body's collision solver rather than
	# guessing a radius from a rectangle or capsule.
	return 0.0


func _return_to_patrol() -> void:
	if returning_to_patrol or is_dead:
		return

	returning_to_patrol = true

	attack_token += 1

	state = EnemyState.PATROL
	velocity = Vector2.ZERO
	attack_thrust_velocity = 0.0
	attack_thrust_distance_remaining = 0.0
	hitbox_activation_pending = false
	attack_in_progress = false
	attack_phase = 0
	attack_elapsed = 0.0

	attack_hitbox.set_deferred("monitoring", false)
	animation_player.stop()
	body_pivot.position = Vector2.ZERO
	body_pivot.rotation = 0.0

	if (
		is_instance_valid(patrol_follower)
		and is_instance_valid(original_path)
		and original_path.curve != null
	):
		var local_position := original_path.to_local(
			global_position
		)

		patrol_follower.progress = (
			original_path.curve.get_closest_offset(local_position)
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


func _start_attack() -> void:
	if (
		state != EnemyState.CHASE
		or attack_in_progress
		or not can_attack
		or is_dead
	):
		return

	if (
		not is_instance_valid(player)
		or not _has_line_of_sight(player)
	):
		_lose_player()
		return

	if not animation_player.has_animation(attack_animation):
		push_warning(
			"Missing attack animation: " + String(attack_animation)
		)
		return

	state = EnemyState.ATTACK
	attack_in_progress = true
	can_attack = false

	attack_token += 1
	var current_attack_token := attack_token

	attack_elapsed = 0.0
	attack_phase = 0
	last_shield_impact_elapsed = -999.0
	spin_hits_applied_to_player = 0
	last_player_spin_hit_elapsed = -999.0
	attack_thrust_velocity = 0.0
	hitbox_activation_pending = false

	var player_offset := player.global_position - global_position
	var player_distance := player_offset.length()
	attack_direction = player_offset.normalized()

	if attack_direction.length_squared() < 0.001:
		attack_direction = Vector2.RIGHT

	# The spin may include a short wind-up lunge, but never let that lunge
	# drive the enemy into the player's physical collision shape.
	attack_thrust_distance_remaining = minf(
		maxf(thrust_distance, 0.0),
		maxf(player_distance - _minimum_player_separation(), 0.0)
	)

	_face_direction(attack_direction)

	body_pivot.position = Vector2.ZERO
	body_pivot.rotation = 0.0

	attack_hitbox.set_deferred("monitoring", false)
	animation_player.play(attack_animation)

	if attack_audio.stream != null:
		attack_audio.play()

	_wait_for_attack_animation(current_attack_token)


func _wait_for_attack_animation(current_attack_token: int) -> void:
	await animation_player.animation_finished

	if not is_inside_tree() or is_dead:
		return

	if current_attack_token != attack_token:
		return

	if state != EnemyState.ATTACK:
		return

	_finish_attack()


func _update_attack(delta: float) -> void:
	attack_elapsed += delta

	var windup_end := attack_windup
	var active_end := attack_windup + attack_active_time
	var recovery_end := (
		attack_windup + attack_active_time + attack_recovery
	)

	if attack_elapsed < windup_end:
		if attack_phase != 0:
			attack_phase = 0
			attack_hitbox.set_deferred("monitoring", false)

		attack_thrust_velocity = (
			attack_thrust_distance_remaining
			/ maxf(attack_windup, 0.001)
		)

	elif attack_elapsed < active_end:
		if attack_phase != 1:
			attack_phase = 1
			hitbox_activation_pending = true
			attack_hitbox.set_deferred("monitoring", true)

		attack_thrust_velocity = 0.0

		if hitbox_activation_pending and attack_hitbox.monitoring:
			hitbox_activation_pending = false

		_check_overlapping_shields()
		_check_overlapping_bodies()

	elif attack_elapsed < recovery_end:
		if attack_phase != 2:
			attack_phase = 2
			hitbox_activation_pending = false
			attack_hitbox.set_deferred("monitoring", false)

		attack_thrust_velocity = 0.0

	else:
		_finish_attack()


func _finish_attack() -> void:
	if not attack_in_progress:
		return

	attack_hitbox.set_deferred("monitoring", false)

	hitbox_activation_pending = false
	attack_thrust_velocity = 0.0
	attack_thrust_distance_remaining = 0.0
	attack_in_progress = false
	attack_phase = 0
	attack_elapsed = 0.0
	velocity = Vector2.ZERO

	# Reset BodyPivot after the full attack animation has completed.
	body_pivot.position = Vector2.ZERO
	body_pivot.rotation = 0.0

	if is_dead or state == EnemyState.DEAD:
		return

	state = EnemyState.CHASE
	_play_animation(move_animation)
	_reset_attack_cooldown()


func _reset_attack_cooldown() -> void:
	await get_tree().create_timer(attack_cooldown).timeout

	if is_inside_tree() and not is_dead:
		can_attack = true


func _check_overlapping_shields() -> void:
	if not attack_hitbox.monitoring:
		return

	for area in attack_hitbox.get_overlapping_areas():
		_handle_shield_collision(area)


func _check_overlapping_bodies() -> void:
	if not attack_hitbox.monitoring:
		return

	for body in attack_hitbox.get_overlapping_bodies():
		_apply_attack_damage(body)


func _on_attack_hitbox_area_entered(area: Area2D) -> void:
	if is_dead or state != EnemyState.ATTACK or attack_phase != 1:
		return

	_handle_shield_collision(area)


func _handle_shield_collision(area: Area2D) -> void:
	if not is_instance_valid(area):
		return

	if (
		not area.is_in_group(shield_hitbox_group)
		or state != EnemyState.ATTACK
		or attack_phase != 1
	):
		return

	# The axe spin remains active when it meets a blocking shield. While the
	# attack hitbox overlaps the shield, register another shield impact at a
	# controlled interval rather than ending the attack on the first contact.
	var impact_interval := maxf(shield_block_repeat_interval, 0.05)
	if attack_elapsed - last_shield_impact_elapsed < impact_interval:
		return

	# ShieldHitbox is nested below ShieldPivot and its Equipment node. Walk up
	# the hierarchy to find the shield that owns blocking_active.
	var current_node: Node = area

	while is_instance_valid(current_node):
		if _has_property(current_node, &"blocking_active"):
			if not bool(current_node.get("blocking_active")):
				return

			var shield_node := current_node as Node2D
			var is_blocked := false

			if current_node.has_method("try_block_melee_attack"):
				is_blocked = bool(
					current_node.call("try_block_melee_attack", self)
				)
			else:
				# Compatibility with shield scripts lacking the helper method.
				is_blocked = true
				_play_shield_block_sound()

			if is_blocked and is_instance_valid(shield_node):
				last_shield_impact_elapsed = attack_elapsed
				on_blocked_by_shield(shield_node)
			return

		if is_instance_valid(player) and current_node == player:
			break

		current_node = current_node.get_parent()


func on_blocked_by_shield(_shield: Node2D) -> void:
	# A blocked axe-spin hit is negated, but it does NOT cancel the spin. The
	# attack hitbox and animation continue, allowing repeated shield impacts.
	# Player.take_damage() may call this before the shield overlap callback, so
	# keep this function safe to call multiple times during the same attack.
	if is_dead or state != EnemyState.ATTACK:
		return

	# Do not mark the player as permanently hit: each spin hit gets its own
	# damage opportunity, and Player.take_damage() decides whether that specific
	# hit is blocked by the shield.

	# Deliberately do not disable AttackHitbox, apply knockback, or call
	# _finish_attack() here. The animation completes normally and shield overlap
	# checks continue to play impact feedback at shield_block_repeat_interval.


func _apply_block_knockback(source: Node2D) -> void:
	if is_dead:
		return

	# Use the player's body centre for the push direction. The shield's grip/socket
	# is offset from the body and can otherwise push the enemy sideways into it.
	var push_origin: Node2D = source
	if is_instance_valid(player):
		push_origin = player

	var direction := Vector2.ZERO
	if is_instance_valid(push_origin):
		direction = global_position - push_origin.global_position

	if direction.length_squared() < 0.001:
		direction = -attack_direction
	if direction.length_squared() < 0.001:
		direction = Vector2.RIGHT.rotated(global_rotation)

	knockback_velocity = direction.normalized() * maxf(knockback_force, 0.0)
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


func _on_attack_hitbox_body_entered(body: Node2D) -> void:
	if is_dead or state != EnemyState.ATTACK or attack_phase != 1:
		return

	_apply_attack_damage(body)


func _apply_attack_damage(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return

	if state != EnemyState.ATTACK or attack_phase != 1:
		return

	var max_spin_hits := maxi(spin_damage_hit_count, 1)
	if spin_hits_applied_to_player >= max_spin_hits:
		return

	if attack_damage <= 0 or not _has_line_of_sight(body):
		return

	# The attack hitbox is checked every physics frame, but damage is only
	# attempted at evenly spaced intervals during the spin. With the defaults,
	# one spin has five hit opportunities, each worth 3 damage (15 total).
	var hit_interval := maxf(
		maxf(attack_active_time, 0.0) / float(max_spin_hits + 1),
		0.05
	)
	if attack_elapsed - last_player_spin_hit_elapsed < hit_interval:
		return

	var hit_index := spin_hits_applied_to_player
	var hit_damage := _get_spin_hit_damage(hit_index, max_spin_hits)
	spin_hits_applied_to_player += 1
	last_player_spin_hit_elapsed = attack_elapsed

	# Count each timed hit opportunity even if the shield blocks it. This keeps
	# the five-hit sequence consistent and lets Player.take_damage() apply the
	# existing shield logic separately for every hit.
	if body.has_method("take_damage"):
		if hit_damage > 0:
			body.take_damage(hit_damage, self)
	else:
		push_warning("Player needs a take_damage(amount, attacker) method.")


func _get_spin_hit_damage(hit_index: int, hit_count: int) -> int:
	# Split attack_damage across the spin and distribute any remainder to the
	# earliest hits, so all hit values add up to attack_damage exactly.
	var total_damage := maxi(attack_damage, 0)
	var safe_hit_count := maxi(hit_count, 1)
	var base_damage := floori(float(total_damage) / float(safe_hit_count))
	var extra_damage := total_damage % safe_hit_count

	if hit_index < extra_damage:
		return base_damage + 1

	return base_damage


func _on_detection_body_entered(body: Node2D) -> void:
	if is_dead:
		return

	if body.is_in_group("player") and _has_line_of_sight(body):
		player = body


func _on_detection_body_exited(_body: Node2D) -> void:
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
		push_warning("DualAxeEnemy: BodySprite was not found.")
		return

	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material == null:
		push_warning(
			"DualAxeEnemy: Assign the player's damage "
			+ "ShaderMaterial to BodySprite."
		)
		return

	# Give this enemy its own material instance.
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
		"Dual axe enemy health: ",
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

	# Invalidate any pending attack-animation coroutine.
	attack_token += 1

	velocity = Vector2.ZERO
	can_attack = false
	attack_in_progress = false
	patrol_active = false
	player = null

	attack_thrust_velocity = 0.0
	attack_thrust_distance_remaining = 0.0
	hitbox_activation_pending = false
	attack_phase = 0
	attack_elapsed = 0.0

	attack_hitbox.set_deferred("monitoring", false)
	detection_range.set_deferred("monitoring", false)

	animation_player.stop()

	if attack_audio.playing:
		attack_audio.stop()

	if damage_tween and damage_tween.is_valid():
		damage_tween.kill()

	_set_damage_flash(0.0)

	set_collision_layer_value(1, false)
	set_collision_mask_value(1, false)

	print("Dual axe enemy defeated.")

	queue_free()
