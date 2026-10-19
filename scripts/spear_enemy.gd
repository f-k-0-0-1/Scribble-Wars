
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

@export_group("Movement")
@export var patrol_speed: float = 45.0
@export var chase_speed: float = 90.0
@export var patrol_enabled: bool = true
@export var rotation_offset_degrees: float = 0.0

@export_group("Combat")
@export var attack_range: float = 70.0
@export var attack_separation_distance: float = 20.0
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
	if state == EnemyState.DEAD:
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
			if distance_to_player <= detection_radius:
				_begin_chase()
			else:
				_update_patrol(delta)

		EnemyState.CHASE:
			if distance_to_player > lose_target_distance:
				_return_to_patrol()
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
			_maintain_attack_separation()

		EnemyState.DEAD:
			return


func _find_player_if_needed() -> void:
	if is_instance_valid(player):
		return

	var candidate := get_tree().get_first_node_in_group("player")

	if candidate is Node2D:
		player = candidate


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

	var direction := (
		player.global_position - global_position
	).normalized()

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
	spear_hitbox.set_deferred("monitoring", false)

	if is_instance_valid(patrol_follower) and is_instance_valid(original_path):
		if original_path.curve != null:
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
	if state != EnemyState.CHASE:
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

	if not is_inside_tree() or state == EnemyState.DEAD:
		_finish_attack_early()
		return

	_maintain_attack_separation()
	spear_hitbox.set_deferred("monitoring", true)

	await get_tree().physics_frame

	if not is_inside_tree() or state == EnemyState.DEAD:
		_finish_attack_early()
		return

	# Check shields first so a blocking shield can prevent body damage.
	for area in spear_hitbox.get_overlapping_areas():
		_handle_shield_collision(area)

	for body in spear_hitbox.get_overlapping_bodies():
		_apply_spear_hit(body)

	await get_tree().create_timer(attack_active_time).timeout

	if not is_inside_tree():
		return

	spear_hitbox.set_deferred("monitoring", false)

	await get_tree().create_timer(attack_recovery).timeout

	if not is_inside_tree() or state == EnemyState.DEAD:
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

	if is_inside_tree() and state != EnemyState.DEAD:
		can_attack = true


func _on_spear_hitbox_area_entered(area: Area2D) -> void:
	if state != EnemyState.ATTACK or not spear_hitbox.monitoring:
		return

	_handle_shield_collision(area)


func _handle_shield_collision(area: Area2D) -> void:
	if not is_instance_valid(area):
		return

	if not area.is_in_group(shield_hitbox_group):
		return

	if blocked_this_attack:
		return

	var shield_owner: Node = area
	while is_instance_valid(shield_owner) and shield_owner != player:
		if _has_property(shield_owner, "blocking_active"):
			if not bool(shield_owner.get("blocking_active")):
				return

			blocked_this_attack = true
			attack_hit_targets.append(player)
			_play_shield_block_sound()
			return

		shield_owner = shield_owner.get_parent()

	# A shield hitbox without a blocking_active property is not
	# automatically treated as a successful block.


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


func _on_spear_hitbox_body_entered(body: Node2D) -> void:
	if state != EnemyState.ATTACK or not spear_hitbox.monitoring:
		return

	if blocked_this_attack:
		return

	_apply_spear_hit(body)


func _apply_spear_hit(body: Node2D) -> void:
	if not body.is_in_group("player"):
		return

	if blocked_this_attack:
		return

	if body in attack_hit_targets:
		return

	attack_hit_targets.append(body)

	if body.has_method("take_damage"):
		body.take_damage(attack_damage)
	else:
		push_warning("Player needs a take_damage(amount) method.")


func _on_detection_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		player = body


func _on_detection_body_exited(body: Node2D) -> void:
	if body == player and global_position.distance_to(body.global_position) > lose_target_distance:
		player = null


func _play_animation(animation_name: StringName) -> void:
	if not animation_player.has_animation(animation_name):
		push_warning("Missing animation: " + String(animation_name))
		return

	if animation_player.current_animation == animation_name:
		return

	animation_player.play(animation_name)
