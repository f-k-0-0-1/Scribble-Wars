
extends CharacterBody2D

# ==================================================
# DETECTION AND COMBAT
# ==================================================

@export_group("Detection and Combat")
@export var detection_radius: float = 380.0
@export var shooting_range: float = 320.0
@export var preferred_distance: float = 180.0
@export var distance_tolerance: float = 25.0
@export var approach_speed: float = 45.0
@export var retreat_speed: float = 85.0
@export_flags_2d_physics var line_of_sight_collision_mask: int = 0xFFFFFFFF
@export var bullet_scene: PackedScene
@export var gun_rotation_offset_degrees: float = 0.0


# ==================================================
# PATH2D PATROL
# ==================================================

@export_group("Patrol")
@export var patrol_enabled: bool = true
@export var patrol_speed: float = 50.0
@export var pause_patrol_while_aiming: bool = true
@export var patrol_rotation_offset_degrees: float = 0.0


# ==================================================
# BURST SHOOTING
# ==================================================

@export_group("Burst Shooting")
@export_range(1, 10, 1) var shots_per_burst: int = 3
@export_range(0.01, 2.0, 0.01) var interval_between_shots: float = 0.16
@export_range(0.0, 10.0, 0.05) var burst_cooldown: float = 1.4
@export var bullet_damage: int = 10


# ==================================================
# ANIMATIONS
# ==================================================

@export_group("Animations")
@export var idle_animation: StringName = &"idle"
@export var move_animation: StringName = &"move"
@export var shoot_animation: StringName = &"shoot"
@export var play_shoot_animation_at_normal_speed: bool = true


# ==================================================
# HEALTH
# ==================================================

@export_group("Health")
@export var max_health: int = 100


# ==================================================
# KNOCKBACK
# ==================================================

@export_group("Knockback")
@export var knockback_force: float = 260.0
@export var knockback_duration: float = 0.16
@export var knockback_decay: float = 1400.0


# ==================================================
# DAMAGE VISUALS
# ==================================================

@export_group("Damage Visuals")
@export var damage_flash_count: int = 3
@export var damage_flash_duration: float = 0.3


# ==================================================
# INTERNAL VARIABLES
# ==================================================

var player: Node2D

var current_health: int = 100
var is_dead: bool = false
var is_bursting: bool = false

var burst_cooldown_remaining: float = 0.0
var current_animation: StringName = &""

var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_timer: float = 0.0

var damage_tween: Tween

var patrol_follower: PathFollow2D
var patrol_direction: float = 1.0

var uses_path_follow: bool = false
var patrol_active: bool = false

var _missing_animation_warnings: Dictionary = {}


# ==================================================
# NODE REFERENCES
# ==================================================

@onready var body_collision_shape: CollisionShape2D = $CollisionShape2D
@onready var body_sprite: Sprite2D = $BodyPivot/BodySprite

@onready var gun_pivot: Node2D = $GunPivot
@onready var muzzle: Marker2D = $GunPivot/Muzzle

@onready var detection_range: Area2D = $DetectionRange
@onready var detection_shape: CollisionShape2D = $DetectionRange/CollisionShape2D

@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var gun_audio_player: AudioStreamPlayer2D = $AudioStreamPlayer2D


# ==================================================
# INITIALIZATION
# ==================================================

func _ready() -> void:
	add_to_group("enemies")
	add_to_group("enemy")

	max_health = maxi(max_health, 1)
	current_health = max_health

	_setup_damage_shader()
	_setup_detection_range()
	_setup_path_patrol()

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

	_find_player()

	if uses_path_follow:
		_update_patrol_facing()

	_play_animation(idle_animation)

	if bullet_scene == null:
		push_warning(
			"GunnerEnemy: Assign GunnerBullet.tscn "
			+ "to Bullet Scene in the Inspector."
		)


func _setup_path_patrol() -> void:
	patrol_follower = get_parent() as PathFollow2D
	uses_path_follow = is_instance_valid(patrol_follower)

	patrol_active = patrol_enabled and uses_path_follow

	if patrol_enabled and not uses_path_follow:
		push_warning(
			"GunnerEnemy: For Path2D patrol, place the enemy "
			+ "under Path2D > PathFollow2D > GunnerEnemy."
		)

	if not uses_path_follow:
		return

	# PathFollow2D controls the Gunner's position.
	# Disable inherited path rotation because the script
	# handles the body's facing direction itself.
	patrol_follower.rotates = false
	patrol_follower.loop = false

	var path := patrol_follower.get_parent() as Path2D

	if path == null or path.curve == null:
		push_warning(
			"GunnerEnemy: PathFollow2D needs a valid Path2D "
			+ "parent with a Curve2D resource."
		)
		return

	var path_length: float = path.curve.get_baked_length()

	if path_length > 0.0:
		patrol_follower.progress = clampf(
			patrol_follower.progress,
			0.0,
			path_length
		)


func _setup_detection_range() -> void:
	if detection_shape.shape is CircleShape2D:
		detection_shape.shape = detection_shape.shape.duplicate()

		var circle_shape := (
			detection_shape.shape as CircleShape2D
		)

		circle_shape.radius = maxf(detection_radius, 1.0)

	detection_range.monitoring = true


# ==================================================
# MAIN PHYSICS LOOP
# ==================================================

func _physics_process(delta: float) -> void:
	if is_dead:
		return

	if knockback_timer > 0.0:
		_process_knockback(delta)
		return

	burst_cooldown_remaining = maxf(
		burst_cooldown_remaining - delta,
		0.0
	)

	if not is_instance_valid(player):
		player = null
		_find_player()

	var player_distance: float = INF
	var can_see_player: bool = false
	var can_aim_at_player: bool = false

	if is_instance_valid(player):
		player_distance = global_position.distance_to(
			player.global_position
		)

		# The player must be within detection range and
		# have a clear line of sight to be detected.
		can_see_player = (
			player_distance <= detection_radius
			and has_line_of_sight()
		)

		# Do not aim at the player while they are outside
		# the actual firing range.
		can_aim_at_player = (
			can_see_player
			and player_distance <= shooting_range
		)

	# --------------------------------------------------
	# PATH2D MOVEMENT
	# --------------------------------------------------

	if uses_path_follow:
		var should_pause_patrol: bool = (
			patrol_active
			and pause_patrol_while_aiming
			and can_aim_at_player
		)

		if patrol_active and not should_pause_patrol:
			_update_patrol(delta)
			_update_patrol_facing()

		# Don't use move_and_slide() for normal movement
		# when PathFollow2D controls the enemy's position.
		velocity = Vector2.ZERO

	else:
		# Fallback for a Gunner placed outside a PathFollow2D.
		_update_free_movement(
			player_distance,
			can_see_player
		)

	# --------------------------------------------------
	# GUN AIMING
	# --------------------------------------------------

	if can_aim_at_player:
		_aim_at_player()
	else:
		# When the player is hidden or out of range, face
		# the direction the Gunner is currently facing.
		_aim_forward()

	# --------------------------------------------------
	# MOVEMENT ANIMATION
	# --------------------------------------------------

	if not is_bursting:
		if uses_path_follow:
			var is_patrolling: bool = (
				patrol_active
				and patrol_speed > 0.0
				and not (
					pause_patrol_while_aiming
					and can_aim_at_player
				)
			)

			if is_patrolling:
				_play_animation(move_animation)
			else:
				_play_animation(idle_animation)

		else:
			if velocity.length_squared() > 4.0:
				_play_animation(move_animation)
			else:
				_play_animation(idle_animation)

	# --------------------------------------------------
	# SHOOTING
	# --------------------------------------------------

	if (
		can_aim_at_player
		and burst_cooldown_remaining <= 0.0
		and not is_bursting
		and bullet_scene != null
	):
		_fire_burst()


# ==================================================
# PLAYER DETECTION
# ==================================================

func _find_player() -> void:
	var candidate := get_tree().get_first_node_in_group("player")

	if candidate is Node2D:
		player = candidate


func _on_detection_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		player = body


func _on_detection_body_exited(body: Node2D) -> void:
	# Keep the reference so the Gunner can detect the player
	# again without depending on another group search.
	if body == player:
		pass


func has_line_of_sight() -> bool:
	if not is_instance_valid(player):
		return false

	var query := PhysicsRayQueryParameters2D.create(
		global_position,
		player.global_position,
		line_of_sight_collision_mask
	)

	query.exclude = [get_rid()]
	query.collide_with_bodies = true
	query.collide_with_areas = false

	var result: Dictionary = (
		get_world_2d().direct_space_state.intersect_ray(query)
	)

	# The first collision must be the player.
	# A wall or another physical body blocks visibility.
	return (
		not result.is_empty()
		and result.get("collider") == player
	)


# ==================================================
# PATH2D PATROL
# ==================================================

func _get_parent_path() -> Path2D:
	if not is_instance_valid(patrol_follower):
		return null

	return patrol_follower.get_parent() as Path2D


func _update_patrol(delta: float) -> void:
	if not is_instance_valid(patrol_follower):
		return

	var path := _get_parent_path()

	if path == null or path.curve == null:
		return

	var path_length: float = path.curve.get_baked_length()

	if path_length <= 0.0 or patrol_speed <= 0.0:
		return

	var next_progress: float = (
		patrol_follower.progress
		+ patrol_speed * delta * patrol_direction
	)

	# Reverse at either end of the path instead of
	# allowing PathFollow2D to run past the endpoint.
	if next_progress >= path_length:
		patrol_follower.progress = path_length
		patrol_direction = -1.0

	elif next_progress <= 0.0:
		patrol_follower.progress = 0.0
		patrol_direction = 1.0

	else:
		patrol_follower.progress = next_progress


func _get_path_tangent() -> Vector2:
	if not is_instance_valid(patrol_follower):
		return Vector2.ZERO

	var path := _get_parent_path()

	if path == null or path.curve == null:
		return Vector2.ZERO

	var curve := path.curve
	var path_length: float = curve.get_baked_length()

	if path_length <= 0.0:
		return Vector2.ZERO

	var sample_distance: float = 3.0

	var start_distance: float = maxf(
		patrol_follower.progress - sample_distance,
		0.0
	)

	var end_distance: float = minf(
		patrol_follower.progress + sample_distance,
		path_length
	)

	if is_equal_approx(start_distance, end_distance):
		return Vector2.ZERO

	var start_local: Vector2 = curve.sample_baked(start_distance)
	var end_local: Vector2 = curve.sample_baked(end_distance)

	var start_world: Vector2 = path.to_global(start_local)
	var end_world: Vector2 = path.to_global(end_local)

	var tangent: Vector2 = end_world - start_world

	if tangent.length_squared() < 0.001:
		return Vector2.ZERO

	return tangent.normalized()


func _update_patrol_facing() -> void:
	var tangent: Vector2 = _get_path_tangent()

	if tangent == Vector2.ZERO:
		return

	# Reverse the facing direction when travelling backwards.
	tangent *= patrol_direction

	global_rotation = (
		tangent.angle()
		+ deg_to_rad(patrol_rotation_offset_degrees)
	)


# ==================================================
# FALLBACK MOVEMENT OUTSIDE A PATH
# ==================================================

func _update_free_movement(
	player_distance: float,
	can_see_player: bool
) -> void:
	if not can_see_player or not is_instance_valid(player):
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var direction: Vector2 = (
		player.global_position - global_position
	).normalized()

	if player_distance < preferred_distance - distance_tolerance:
		velocity = -direction * retreat_speed

	elif player_distance > preferred_distance + distance_tolerance:
		velocity = direction * approach_speed

	else:
		velocity = Vector2.ZERO

	move_and_slide()


# ==================================================
# GUN AIMING
# ==================================================

func _aim_at_player() -> void:
	if not is_instance_valid(player):
		return

	var direction: Vector2 = (
		player.global_position - gun_pivot.global_position
	)

	if direction.length_squared() < 0.001:
		return

	gun_pivot.global_rotation = (
		direction.angle()
		+ deg_to_rad(gun_rotation_offset_degrees)
	)


func _aim_forward() -> void:
	# Do not preserve a stale aim toward a hidden player.
	# Return the gun to the direction the body is facing.
	gun_pivot.global_rotation = (
		global_rotation
		+ deg_to_rad(gun_rotation_offset_degrees)
	)


# ==================================================
# BURST SHOOTING
# ==================================================

func _fire_burst() -> void:
	if (
		is_dead
		or is_bursting
		or bullet_scene == null
		or not _can_aim_at_player()
	):
		return

	is_bursting = true

	var shots_to_fire: int = maxi(shots_per_burst, 1)
	var original_speed_scale: float = animation_player.speed_scale
	var burst_start_msec: int = Time.get_ticks_msec()

	if (
		play_shoot_animation_at_normal_speed
		and animation_player.has_animation(shoot_animation)
	):
		animation_player.speed_scale = 1.0

	_play_animation(shoot_animation)

	for shot_index in range(shots_to_fire):
		if (
			is_dead
			or not is_inside_tree()
			or not _can_aim_at_player()
		):
			break

		# Recheck the player's position before every shot.
		_aim_at_player()
		_shoot_bullet()

		if shot_index < shots_to_fire - 1:
			await get_tree().create_timer(
				maxf(interval_between_shots, 0.01)
			).timeout

	# Let the shoot animation complete its recoil and recovery.
	if (
		is_inside_tree()
		and not is_dead
		and animation_player.has_animation(shoot_animation)
	):
		var shoot_resource: Animation = (
			animation_player.get_animation(shoot_animation)
		)

		var speed_scale: float = maxf(
			animation_player.speed_scale,
			0.01
		)

		var animation_duration: float = (
			shoot_resource.length / speed_scale
		)

		var elapsed_seconds: float = (
			float(Time.get_ticks_msec() - burst_start_msec)
			/ 1000.0
		)

		var remaining_time: float = (
			animation_duration - elapsed_seconds
		)

		if remaining_time > 0.0:
			await get_tree().create_timer(remaining_time).timeout

	if not is_inside_tree() or is_dead:
		return

	animation_player.speed_scale = original_speed_scale
	is_bursting = false

	burst_cooldown_remaining = maxf(burst_cooldown, 0.0)


func _can_aim_at_player() -> bool:
	if not is_instance_valid(player):
		return false

	var distance_to_player: float = global_position.distance_to(
		player.global_position
	)

	if distance_to_player > detection_radius:
		return false

	if distance_to_player > shooting_range:
		return false

	return has_line_of_sight()


func _shoot_bullet() -> void:
	if (
		is_dead
		or bullet_scene == null
		or not is_instance_valid(player)
	):
		return

	var bullet: Node = bullet_scene.instantiate()

	if not bullet.has_method("launch"):
		push_error(
			"GunnerBullet must implement "
			+ "launch(start_position, target_position, source)."
		)
		bullet.free()
		return

	var current_scene := get_tree().current_scene

	if current_scene == null:
		bullet.free()
		return

	bullet.set("damage", maxi(bullet_damage, 0))

	current_scene.add_child(bullet)

	bullet.call(
		"launch",
		muzzle.global_position,
		player.global_position,
		self
	)

	if (
		is_instance_valid(gun_audio_player)
		and gun_audio_player.stream != null
	):
		gun_audio_player.play()


# ==================================================
# ANIMATIONS
# ==================================================

func _play_animation(animation_name: StringName) -> void:
	if is_dead or not is_instance_valid(animation_player):
		return

	if animation_name == &"":
		return

	if not animation_player.has_animation(animation_name):
		if not _missing_animation_warnings.has(animation_name):
			_missing_animation_warnings[animation_name] = true

			push_warning(
				"GunnerEnemy: Missing animation '%s'."
				% String(animation_name)
			)

		return

	if (
		current_animation == animation_name
		and animation_player.is_playing()
	):
		return

	current_animation = animation_name
	animation_player.play(animation_name)


# ==================================================
# HEALTH AND DAMAGE
# ==================================================

func take_damage(
	amount: int,
	attacker: Node2D = null
) -> void:
	if is_dead or amount <= 0:
		return

	current_health = maxi(current_health - amount, 0)

	_apply_knockback(attacker)
	_play_damage_flash()

	print(
		"Gunner health: %d/%d"
		% [current_health, max_health]
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
		direction = Vector2.RIGHT.rotated(global_rotation)

	knockback_velocity = (
		direction.normalized() * maxf(knockback_force, 0.0)
	)

	knockback_timer = maxf(knockback_duration, 0.0)


func _process_knockback(delta: float) -> void:
	knockback_timer = maxf(knockback_timer - delta, 0.0)

	if uses_path_follow:
		# A PathFollow2D owns the Gunner's position.
		# Project knockback onto the path so the enemy
		# does not fight the path follower's transform.
		var tangent: Vector2 = _get_path_tangent()

		if tangent != Vector2.ZERO:
			var path_speed: float = knockback_velocity.dot(tangent)

			var path := _get_parent_path()

			if path != null and path.curve != null:
				var path_length: float = (
					path.curve.get_baked_length()
				)

				patrol_follower.progress = clampf(
					patrol_follower.progress + path_speed * delta,
					0.0,
					path_length
				)

	else:
		velocity = knockback_velocity
		move_and_slide()

	knockback_velocity = knockback_velocity.move_toward(
		Vector2.ZERO,
		maxf(knockback_decay, 0.0) * delta
	)

	if knockback_timer <= 0.0:
		knockback_velocity = Vector2.ZERO
		velocity = Vector2.ZERO


# ==================================================
# DAMAGE FLASH
# ==================================================

func _setup_damage_shader() -> void:
	if not is_instance_valid(body_sprite):
		return

	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material == null:
		push_warning(
			"GunnerEnemy: BodySprite needs a ShaderMaterial "
			+ "with a 'damage_flash' parameter."
		)
		return

	# Give every Gunner an independent material instance.
	body_sprite.material = shader_material.duplicate()

	shader_material = body_sprite.material as ShaderMaterial
	shader_material.set_shader_parameter("damage_flash", 0.0)


func _play_damage_flash() -> void:
	if not is_instance_valid(body_sprite):
		return

	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material == null:
		return

	if damage_tween and damage_tween.is_valid():
		damage_tween.kill()

	damage_tween = create_tween()

	var flash_count: int = maxi(damage_flash_count, 1)
	var half_duration: float = (
		maxf(damage_flash_duration, 0.01)
		/ float(flash_count * 2)
	)

	shader_material.set_shader_parameter("damage_flash", 0.0)

	for _index in range(flash_count):
		damage_tween.tween_method(
			_set_damage_flash,
			0.0,
			1.0,
			half_duration
		)

		damage_tween.tween_method(
			_set_damage_flash,
			1.0,
			0.0,
			half_duration
		)

	damage_tween.tween_callback(
		func() -> void:
			_set_damage_flash(0.0)
	)


func _set_damage_flash(value: float) -> void:
	if not is_instance_valid(body_sprite):
		return

	var shader_material := body_sprite.material as ShaderMaterial

	if shader_material != null:
		shader_material.set_shader_parameter(
			"damage_flash",
			value
		)


# ==================================================
# DEATH
# ==================================================

func _die() -> void:
	if is_dead:
		return

	is_dead = true

	velocity = Vector2.ZERO
	knockback_velocity = Vector2.ZERO
	knockback_timer = 0.0
	is_bursting = false

	if damage_tween and damage_tween.is_valid():
		damage_tween.kill()

	_set_damage_flash(0.0)

	collision_layer = 0
	collision_mask = 0

	if is_instance_valid(body_collision_shape):
		body_collision_shape.set_deferred("disabled", true)

	if is_instance_valid(detection_range):
		detection_range.set_deferred("monitoring", false)
		detection_range.set_deferred("monitorable", false)

	queue_free()
