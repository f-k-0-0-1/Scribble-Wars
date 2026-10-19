
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

@export_group("Combat")
@export var attack_range: float = 65.0
@export var attack_damage: int = 15
@export var attack_cooldown: float = 1.2
@export var attack_windup: float = 0.15
@export var attack_active_time: float = 0.55
@export var attack_recovery: float = 0.30
@export var spin_degrees: float = 360.0
@export var thrust_distance: float = 45.0
@export var attack_separation_distance: float = 20.0

@export_group("Animations")
@export var idle_animation: StringName = &"idle"
@export var move_animation: StringName = &"move"
@export var attack_animation: StringName = &"attack"

@export_group("Shield Interaction")
@export var shield_hitbox_group: StringName = &"shield_hitboxes"
@export var play_block_sound: bool = true

var state: EnemyState = EnemyState.PATROL
var player: Node2D

var patrol_follower: PathFollow2D
var original_path: Path2D
var patrol_direction: float = 1.0
var patrol_active: bool = true
var returning_to_patrol: bool = false

var can_attack: bool = true
var attack_in_progress: bool = false
var attack_hit_targets: Array[Node2D] = []
var blocked_this_attack: bool = false

var attack_elapsed: float = 0.0
var attack_direction: Vector2 = Vector2.RIGHT
var attack_start_position: Vector2 = Vector2.ZERO
var attack_thrust_velocity: float = 0.0
var attack_phase: int = 0
var hitbox_activation_pending: bool = false

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

	if not detection_range.body_entered.is_connected(_on_detection_body_entered):
		detection_range.body_entered.connect(_on_detection_body_entered)

	if not detection_range.body_exited.is_connected(_on_detection_body_exited):
		detection_range.body_exited.connect(_on_detection_body_exited)

	if not attack_hitbox.body_entered.is_connected(_on_attack_hitbox_body_entered):
		attack_hitbox.body_entered.connect(_on_attack_hitbox_body_entered)

	if not attack_hitbox.area_entered.is_connected(_on_attack_hitbox_area_entered):
		attack_hitbox.area_entered.connect(_on_attack_hitbox_area_entered)

	_play_animation(idle_animation)


func _physics_process(delta: float) -> void:
	if state == EnemyState.DEAD:
		return

	_find_player_if_needed()

	match state:
		EnemyState.PATROL:
			velocity = Vector2.ZERO

			if is_instance_valid(player):
				var distance := global_position.distance_to(player.global_position)

				if distance <= detection_radius and _has_line_of_sight(player):
					_begin_chase()
					return

			_update_patrol(delta)

		EnemyState.CHASE:
			if not is_instance_valid(player):
				_lose_player()
				return

			var distance := global_position.distance_to(player.global_position)

			if distance > lose_target_distance or not _has_line_of_sight(player):
				_lose_player()
				return

			if distance <= attack_range and can_attack:
				velocity = Vector2.ZERO
				_face_direction(player.global_position - global_position)
				_start_attack()
			else:
				_chase_player()

		EnemyState.ATTACK:
			if not is_instance_valid(player) or not _has_line_of_sight(player):
				_lose_player()
				return

			_update_attack(delta)

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

	# Support a collision body nested beneath the player group node.
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

	patrol_follower.progress += patrol_speed * delta * patrol_direction

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

	var point_a := path.curve.sample_baked(patrol_follower.progress)
	var point_b := path.curve.sample_baked(sample_distance)
	var direction := path.to_global(point_b) - path.to_global(point_a)

	if direction.length_squared() < 0.001:
		direction = Vector2.RIGHT * patrol_direction

	_face_direction(direction)
	_play_animation(move_animation)


func _begin_chase() -> void:
	if state != EnemyState.PATROL:
		return

	state = EnemyState.CHASE
	velocity = Vector2.ZERO

	if is_instance_valid(patrol_follower):
		var current_scene := get_tree().current_scene
		if current_scene != null:
			reparent(current_scene, true)

	_play_animation(move_animation)


func _chase_player() -> void:
	if not is_instance_valid(player):
		return

	var direction := (player.global_position - global_position).normalized()

	_face_direction(direction)
	velocity = direction * chase_speed
	move_and_slide()

	_play_animation(move_animation)


func _return_to_patrol() -> void:
	if returning_to_patrol:
		return

	returning_to_patrol = true
	state = EnemyState.PATROL
	velocity = Vector2.ZERO
	attack_thrust_velocity = 0.0
	hitbox_activation_pending = false

	attack_hitbox.set_deferred("monitoring", false)
	body_pivot.rotation = 0.0

	if (
		is_instance_valid(patrol_follower)
		and is_instance_valid(original_path)
		and original_path.curve != null
	):
		var local_position := original_path.to_local(global_position)

		patrol_follower.progress = original_path.curve.get_closest_offset(local_position)
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

	global_rotation = direction.angle() + deg_to_rad(rotation_offset_degrees)


func _start_attack() -> void:
	if state != EnemyState.CHASE or attack_in_progress or not can_attack:
		return

	if not is_instance_valid(player) or not _has_line_of_sight(player):
		_lose_player()
		return

	state = EnemyState.ATTACK
	attack_in_progress = true
	can_attack = false

	attack_elapsed = 0.0
	attack_phase = 0
	blocked_this_attack = false
	attack_hit_targets.clear()
	attack_thrust_velocity = 0.0
	hitbox_activation_pending = false

	body_pivot.rotation = 0.0

	attack_direction = (player.global_position - global_position).normalized()
	if attack_direction.length_squared() < 0.001:
		attack_direction = Vector2.RIGHT

	_face_direction(attack_direction)
	_play_animation(attack_animation)

	if attack_audio.stream != null:
		attack_audio.play()


func _update_attack(delta: float) -> void:
	attack_elapsed += delta

	var windup_end := attack_windup
	var active_end := attack_windup + attack_active_time
	var recovery_end := windup_end + attack_active_time + attack_recovery

	if attack_elapsed < windup_end:
		attack_phase = 0
		attack_thrust_velocity = 0.0

		body_pivot.rotation = lerpf(
			0.0,
			deg_to_rad(-25.0),
			attack_elapsed / maxf(windup_end, 0.001)
		)

	elif attack_elapsed < active_end:
		if attack_phase != 1:
			attack_phase = 1
			hitbox_activation_pending = true
			attack_hitbox.set_deferred("monitoring", true)

		var active_elapsed := attack_elapsed - windup_end
		var active_progress := clampf(
			active_elapsed / maxf(attack_active_time, 0.001),
			0.0,
			1.0
		)

		body_pivot.rotation = lerpf(
			deg_to_rad(-25.0),
			deg_to_rad(-25.0 - spin_degrees),
			active_progress
		)

		attack_thrust_velocity = thrust_distance / maxf(attack_active_time, 0.001)

		if hitbox_activation_pending:
			if attack_hitbox.monitoring:
				hitbox_activation_pending = false
				_check_overlapping_shields()
				_check_overlapping_bodies()
		else:
			_check_overlapping_shields()
			_check_overlapping_bodies()

	elif attack_elapsed < recovery_end:
		if attack_phase != 2:
			attack_phase = 2
			hitbox_activation_pending = false
			attack_hitbox.set_deferred("monitoring", false)

		attack_thrust_velocity = 0.0

		var recovery_progress := clampf(
			(attack_elapsed - active_end) / maxf(attack_recovery, 0.001),
			0.0,
			1.0
		)

		body_pivot.rotation = lerpf(
			deg_to_rad(-25.0 - spin_degrees),
			0.0,
			recovery_progress
		)

	else:
		_finish_attack()


func _finish_attack() -> void:
	attack_hitbox.set_deferred("monitoring", false)

	hitbox_activation_pending = false
	attack_thrust_velocity = 0.0
	body_pivot.rotation = 0.0
	attack_in_progress = false
	attack_phase = 0

	if state == EnemyState.DEAD:
		return

	state = EnemyState.CHASE
	_play_animation(move_animation)
	_reset_attack_cooldown()


func _reset_attack_cooldown() -> void:
	await get_tree().create_timer(attack_cooldown).timeout

	if is_inside_tree() and state != EnemyState.DEAD:
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
	if state != EnemyState.ATTACK or attack_phase != 1:
		return

	_handle_shield_collision(area)


func _handle_shield_collision(area: Area2D) -> void:
	if not is_instance_valid(area):
		return

	if not area.is_in_group(shield_hitbox_group) or blocked_this_attack:
		return

	var current_node: Node = area

	while is_instance_valid(current_node):
		if _has_property(current_node, &"blocking_active"):
			if not bool(current_node.get("blocking_active")):
				return

			blocked_this_attack = true
			_play_shield_block_sound()
			return

		if current_node == player:
			break

		current_node = current_node.get_parent()


func _has_property(object: Object, property_name: StringName) -> bool:
	for property_info in object.get_property_list():
		if StringName(property_info["name"]) == property_name:
			return true

	return false


func _play_shield_block_sound() -> void:
	if not play_block_sound:
		return

	var audio_manager := get_node_or_null("/root/AudioManager")

	if audio_manager != null and audio_manager.has_method("play_shield_impact"):
		audio_manager.call("play_shield_impact")


func _on_attack_hitbox_body_entered(body: Node2D) -> void:
	if state != EnemyState.ATTACK or attack_phase != 1:
		return

	_apply_attack_damage(body)


func _apply_attack_damage(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return

	if blocked_this_attack or body in attack_hit_targets:
		return

	if not _has_line_of_sight(body):
		return

	attack_hit_targets.append(body)

	if body.has_method("take_damage"):
		body.take_damage(attack_damage)
	else:
		push_warning("Player needs a take_damage(amount) method.")


func _on_detection_body_entered(body: Node2D) -> void:
	if body.is_in_group("player") and _has_line_of_sight(body):
		player = body


func _on_detection_body_exited(body: Node2D) -> void:
	pass


func _play_animation(animation_name: StringName) -> void:
	if not animation_player.has_animation(animation_name):
		push_warning("Missing animation: " + String(animation_name))
		return

	if animation_player.current_animation == animation_name:
		return

	animation_player.play(animation_name)
