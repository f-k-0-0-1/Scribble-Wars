
extends CharacterBody2D

@export_group("Detection and Combat")
@export var detection_radius: float = 350.0
@export var fire_interval: float = 1.5
@export var minimum_shoot_distance: float = 80.0
@export var bow_rotation_offset_degrees: float = 115.0
@export var arrow_scene: PackedScene

@export_flags_2d_physics var line_of_sight_collision_mask: int = 1

@export_group("Patrol")
@export var patrol_speed: float = 50.0
@export var patrol_enabled: bool = true
@export var pause_patrol_while_aiming: bool = true
@export var patrol_rotation_offset_degrees: float = 0.0

@export_group("Animations")
@export var idle_animation: StringName = &"idle"
@export var move_animation: StringName = &"move"
@export var shoot_animation: StringName = &"shoot"

@export_group("Health")
@export var max_health: int = 100

@export_group("Knockback")
@export var knockback_force: float = 260.0
@export var knockback_duration: float = 0.16
@export var knockback_decay: float = 1400.0

@export_group("Damage Visuals")
@export var body_sprite_path: NodePath = ^"BodyPivot/BodySprite"
@export var damage_flash_count: int = 3
@export var damage_flash_duration: float = 0.3


var player: Node2D
var can_shoot: bool = true
var player_in_range: bool = false

var shot_pending: bool = false
var shot_target_position: Vector2 = Vector2.ZERO
var shot_cooldown_running: bool = false

var patrol_follower: PathFollow2D
var patrol_direction: float = 1.0
var patrol_active: bool = true

var is_shooting: bool = false
var current_movement_animation: StringName = &""

var current_health: int
var is_dead: bool = false
var damage_tween: Tween
var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_timer: float = 0.0


@onready var bow_pivot: Node2D = $BowPivot
@onready var arrow_spawn: Marker2D = $BowPivot/Marker2D
@onready var bow_with_arrow: Sprite2D = $BowPivot/BowWithArrow
@onready var bow_without_arrow: Sprite2D = $BowPivot/BowWithoutArrow

@onready var right_hand_pivot: Node2D = $BowPivot/RightHandPivot
@onready var left_hand_pivot: Node2D = $BowPivot/LeftHandPivot

@onready var detection_range: Area2D = $DetectionRange
@onready var detection_shape: CollisionShape2D = $DetectionRange/CollisionShape2D
@onready var animation_player: AnimationPlayer = $AnimationPlayer

@onready var body_sprite: Sprite2D = get_node_or_null(body_sprite_path)


func _ready() -> void:
	add_to_group("enemies")
	add_to_group("enemy")

	current_health = maxi(max_health, 1)
	max_health = current_health

	_setup_damage_shader()

	patrol_follower = get_parent() as PathFollow2D
	patrol_active = patrol_enabled

	if patrol_enabled and patrol_follower == null:
		push_warning(
			"ArcherEnemy must be a child of PathFollow2D "
			+ "to use path patrol."
		)

	if is_instance_valid(patrol_follower):
		patrol_follower.loop = false
		patrol_follower.rotates = false

		var path := patrol_follower.get_parent() as Path2D

		if path and path.curve:
			patrol_follower.progress = clampf(
				patrol_follower.progress,
				0.0,
				path.curve.get_baked_length()
			)

	if detection_shape.shape is CircleShape2D:
		detection_shape.shape = detection_shape.shape.duplicate()
		detection_shape.shape.radius = detection_radius

	if not detection_range.body_entered.is_connected(_on_body_entered):
		detection_range.body_entered.connect(_on_body_entered)

	if not detection_range.body_exited.is_connected(_on_body_exited):
		detection_range.body_exited.connect(_on_body_exited)

	if not animation_player.animation_finished.is_connected(
		_on_animation_finished
	):
		animation_player.animation_finished.connect(
			_on_animation_finished
		)

	bow_with_arrow.visible = true
	bow_without_arrow.visible = false

	_update_patrol_facing()
	_update_movement_animation()

	call_deferred("_find_existing_player")


func _physics_process(delta: float) -> void:
	if is_dead:
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

	if not is_instance_valid(player):
		player = null
		player_in_range = false
		_find_player()

	if is_instance_valid(player):
		player_in_range = (
			global_position.distance_to(player.global_position)
			<= detection_radius
		)
	else:
		player_in_range = false

	var can_see_player := (
		_has_valid_shooting_target()
		and has_line_of_sight()
	)

	var should_pause_patrol := (
		pause_patrol_while_aiming
		and can_see_player
	)

	if patrol_active and not should_pause_patrol:
		_update_patrol(delta)
		_update_patrol_facing()

	_update_movement_animation(should_pause_patrol)

	if not can_see_player:
		return

	var aim_direction: Vector2 = (
		player.global_position - bow_pivot.global_position
	)

	var desired_bow_global_rotation := (
		aim_direction.angle()
		+ deg_to_rad(bow_rotation_offset_degrees)
	)

	bow_pivot.rotation = (
		desired_bow_global_rotation - global_rotation
	)

	var distance_to_player := global_position.distance_to(
		player.global_position
	)

	if distance_to_player < minimum_shoot_distance:
		return

	if can_shoot and not shot_cooldown_running:
		shoot_arrow()


func _update_patrol(delta: float) -> void:
	if not is_instance_valid(patrol_follower):
		return

	var path := patrol_follower.get_parent() as Path2D

	if path == null or path.curve == null:
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


func _update_patrol_facing() -> void:
	if not is_instance_valid(patrol_follower):
		return

	var path := patrol_follower.get_parent() as Path2D

	if path == null or path.curve == null:
		return

	var curve := path.curve
	var path_length := curve.get_baked_length()

	if path_length <= 0.0:
		return

	var current_distance := patrol_follower.progress
	var sample_distance := 2.0

	var next_distance := clampf(
		current_distance + sample_distance * patrol_direction,
		0.0,
		path_length
	)

	var current_point := curve.sample_baked(current_distance)
	var next_point := curve.sample_baked(next_distance)
	var local_direction := next_point - current_point

	if local_direction.length_squared() < 0.001:
		next_distance = clampf(
			current_distance - sample_distance * patrol_direction,
			0.0,
			path_length
		)

		next_point = curve.sample_baked(next_distance)
		local_direction = next_point - current_point

	if local_direction.length_squared() < 0.001:
		return

	var world_current := path.to_global(current_point)
	var world_next := path.to_global(
		current_point + local_direction
	)

	var world_direction := world_next - world_current

	if world_direction.length_squared() < 0.001:
		return

	global_rotation = (
		world_direction.angle()
		+ deg_to_rad(patrol_rotation_offset_degrees)
	)


func _update_movement_animation(
	should_pause_patrol: bool = false
) -> void:
	if is_dead or is_shooting:
		return

	var is_moving := (
		patrol_active
		and is_instance_valid(patrol_follower)
		and patrol_speed > 0.0
		and not should_pause_patrol
	)

	var desired_animation: StringName

	if is_moving:
		desired_animation = move_animation
	else:
		desired_animation = idle_animation

	if current_movement_animation == desired_animation:
		return

	if not animation_player.has_animation(desired_animation):
		push_warning(
			"Missing animation: " + String(desired_animation)
		)
		return

	current_movement_animation = desired_animation
	animation_player.play(desired_animation)


func _has_valid_shooting_target() -> bool:
	return (
		is_instance_valid(player)
		and player_in_range
	)


func has_line_of_sight() -> bool:
	if not is_instance_valid(player):
		return false

	var query := PhysicsRayQueryParameters2D.create(
		bow_pivot.global_position,
		player.global_position,
		line_of_sight_collision_mask
	)

	query.exclude = [get_rid()]

	var result: Dictionary = (
		get_world_2d().direct_space_state.intersect_ray(query)
	)

	if result.is_empty():
		return true

	return result.get("collider") == player


func _find_player() -> void:
	var candidate := get_tree().get_first_node_in_group("player")

	if candidate is Node2D:
		player = candidate


func _find_existing_player() -> void:
	_find_player()

	if is_instance_valid(player):
		player_in_range = (
			global_position.distance_to(player.global_position)
			<= detection_radius
		)


func _on_body_entered(body: Node2D) -> void:
	if is_dead:
		return

	if body.is_in_group("player"):
		player = body
		player_in_range = true


func _on_body_exited(body: Node2D) -> void:
	if body == player:
		player_in_range = false


func shoot_arrow() -> void:
	if is_dead or not can_shoot or not player_in_range:
		return

	if not is_instance_valid(player):
		return

	if not has_line_of_sight():
		return

	if arrow_scene == null:
		push_warning(
			"Assign arrow_scene in the ArcherEnemy Inspector."
		)
		return

	if not animation_player.has_animation(shoot_animation):
		push_warning(
			"Missing shooting animation: "
			+ String(shoot_animation)
		)
		return

	can_shoot = false
	shot_cooldown_running = true
	shot_pending = true
	is_shooting = true
	current_movement_animation = &""

	shot_target_position = player.global_position

	bow_with_arrow.visible = true
	bow_without_arrow.visible = false

	animation_player.play(shoot_animation)


# Call this from the shoot animation's method-call track
# at the frame when the arrow should leave the bow.
func _release_arrow() -> void:
	if is_dead or not shot_pending:
		return

	shot_pending = false

	if not is_instance_valid(player):
		return

	if not player_in_range or not has_line_of_sight():
		return

	if arrow_scene == null:
		return

	var arrow := arrow_scene.instantiate()

	if not arrow.has_method("launch"):
		push_error("Arrow scene must have a launch() method.")
		arrow.free()
		return

	var current_scene := get_tree().current_scene

	if current_scene == null:
		arrow.free()
		return

	current_scene.add_child(arrow)

	# Pass this archer to the arrow so it can pass the attacker
	# into player.take_damage(amount, attacker) on impact.
	arrow.launch(
		arrow_spawn.global_position,
		shot_target_position,
		self
	)


func _on_animation_finished(animation_name: StringName) -> void:
	if animation_name != shoot_animation:
		return

	if is_dead:
		return

	bow_with_arrow.visible = true
	bow_without_arrow.visible = false

	shot_pending = false
	is_shooting = false
	current_movement_animation = &""

	_start_shoot_cooldown()

	_update_movement_animation(
		pause_patrol_while_aiming
		and _has_valid_shooting_target()
		and has_line_of_sight()
	)


func _start_shoot_cooldown() -> void:
	if is_dead or not shot_cooldown_running:
		return

	await get_tree().create_timer(fire_interval).timeout

	if is_inside_tree() and not is_dead:
		shot_cooldown_running = false
		can_shoot = true


# --------------------------------------------------
# HEALTH AND DAMAGE
# --------------------------------------------------

func _setup_damage_shader() -> void:
	if body_sprite == null:
		push_warning(
			"ArcherEnemy: BodySprite not found. "
			+ "Check body_sprite_path in the Inspector."
		)
		return

	var shader_material := (
		body_sprite.material as ShaderMaterial
	)

	if shader_material == null:
		push_warning(
			"ArcherEnemy: Assign the player's damage "
			+ "ShaderMaterial to BodySprite."
		)
		return

	# Duplicate the material so each archer flashes independently.
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
		"Archer health: ",
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

	var shader_material := (
		body_sprite.material as ShaderMaterial
	)

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

	var shader_material := (
		body_sprite.material as ShaderMaterial
	)

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
	velocity = Vector2.ZERO

	shot_pending = false
	is_shooting = false
	can_shoot = false
	shot_cooldown_running = false
	patrol_active = false

	if damage_tween and damage_tween.is_valid():
		damage_tween.kill()

	_set_damage_flash(0.0)

	# Disable collision layer 1 and mask 1.
	# Adjust these if your project uses different layers.
	set_collision_layer_value(1, false)
	set_collision_mask_value(1, false)

	if is_instance_valid(detection_range):
		detection_range.set_deferred("monitoring", false)

	print("Archer defeated.")

	queue_free()
