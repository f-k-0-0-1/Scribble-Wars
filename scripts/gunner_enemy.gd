extends CharacterBody2D

@export_group("Detection and Combat")
@export var detection_radius: float = 380.0
@export var shooting_range: float = 320.0
@export var preferred_distance: float = 180.0
@export var distance_tolerance: float = 25.0
@export var approach_speed: float = 45.0
@export var retreat_speed: float = 85.0
@export var line_of_sight_collision_mask: int = 1
@export var bullet_scene: PackedScene
@export var gun_rotation_offset_degrees: float = 0.0

@export_group("Burst Shooting")
@export_range(1, 10, 1) var shots_per_burst: int = 3
@export var interval_between_shots: float = 0.16
@export var burst_cooldown: float = 1.4
@export var bullet_damage: int = 10

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
@export var damage_flash_count: int = 3
@export var damage_flash_duration: float = 0.3

var player: Node2D
var current_health: int
var is_dead: bool = false
var is_bursting: bool = false
var burst_cooldown_remaining: float = 0.0
var current_animation: StringName = &""
var knockback_velocity: Vector2 = Vector2.ZERO
var knockback_timer: float = 0.0
var damage_tween: Tween

@onready var body_sprite: Sprite2D = $BodyPivot/BodySprite
@onready var gun_pivot: Node2D = $GunPivot
@onready var muzzle: Marker2D = $GunPivot/Muzzle
@onready var detection_range: Area2D = $DetectionRange
@onready var detection_shape: CollisionShape2D = $DetectionRange/CollisionShape2D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var gun_audio_player: AudioStreamPlayer2D = $AudioStreamPlayer2D


func _ready() -> void:
	add_to_group("enemies")
	add_to_group("enemy")

	current_health = maxi(max_health, 1)
	max_health = current_health

	_setup_damage_shader()
	_setup_detection_range()

	if not detection_range.body_entered.is_connected(_on_detection_body_entered):
		detection_range.body_entered.connect(_on_detection_body_entered)
	if not detection_range.body_exited.is_connected(_on_detection_body_exited):
		detection_range.body_exited.connect(_on_detection_body_exited)

	_find_player()
	_play_animation(idle_animation)

	if bullet_scene == null:
		push_warning("GunnerEnemy: Assign bullet_scene in the Inspector.")


func _physics_process(delta: float) -> void:
	if is_dead:
		return

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

	burst_cooldown_remaining = maxf(
		burst_cooldown_remaining - delta,
		0.0
	)

	if not is_instance_valid(player):
		_find_player()

	if not is_instance_valid(player):
		velocity = Vector2.ZERO
		move_and_slide()
		if not is_bursting:
			_play_animation(idle_animation)
		return

	var to_player: Vector2 = player.global_position - global_position
	var distance_to_player := to_player.length()
	var direction_to_player := Vector2.RIGHT
	if distance_to_player > 0.001:
		direction_to_player = to_player / distance_to_player

	# Aim the gun independently of the body orientation.
	gun_pivot.global_rotation = (
		direction_to_player.angle()
		+ deg_to_rad(gun_rotation_offset_degrees)
	)

	# Keep the Gunner at a useful range and retreat when the player approaches.
	if distance_to_player > detection_radius:
		velocity = Vector2.ZERO
	elif distance_to_player < preferred_distance - distance_tolerance:
		velocity = -direction_to_player * retreat_speed
	elif distance_to_player > preferred_distance + distance_tolerance:
		velocity = direction_to_player * approach_speed
	else:
		velocity = Vector2.ZERO

	move_and_slide()

	if not is_bursting:
		if velocity.length_squared() > 4.0:
			_play_animation(move_animation)
		else:
			_play_animation(idle_animation)

	if (
		distance_to_player <= shooting_range
		and distance_to_player <= detection_radius
		and burst_cooldown_remaining <= 0.0
		and not is_bursting
		and bullet_scene != null
		and has_line_of_sight()
	):
		_fire_burst()


func _setup_detection_range() -> void:
	if detection_shape.shape is CircleShape2D:
		detection_shape.shape = detection_shape.shape.duplicate()
		var circle_shape := detection_shape.shape as CircleShape2D
		circle_shape.radius = detection_radius


func _find_player() -> void:
	var candidate := get_tree().get_first_node_in_group("player")
	if candidate is Node2D:
		player = candidate


func _on_detection_body_entered(body: Node2D) -> void:
	if body.is_in_group("player"):
		player = body


func _on_detection_body_exited(body: Node2D) -> void:
	if body == player:
		# Keep the reference; distance checks decide when the player is in range.
		pass


func has_line_of_sight() -> bool:
	if not is_instance_valid(player):
		return false

	var query := PhysicsRayQueryParameters2D.create(
		muzzle.global_position,
		player.global_position,
		line_of_sight_collision_mask
	)
	query.exclude = [get_rid(), detection_range.get_rid()]

	var result: Dictionary = (
		get_world_2d().direct_space_state.intersect_ray(query)
	)

	if result.is_empty():
		return true

	return result.get("collider") == player


func _fire_burst() -> void:
	if is_dead or is_bursting or bullet_scene == null:
		return

	is_bursting = true
	_play_animation(shoot_animation)

	for shot_index in range(maxi(shots_per_burst, 1)):
		if is_dead or not is_inside_tree() or not is_instance_valid(player):
			break
		if not has_line_of_sight():
			break

		_shoot_bullet()

		if shot_index < maxi(shots_per_burst, 1) - 1:
			await get_tree().create_timer(maxf(interval_between_shots, 0.01)).timeout

	if is_inside_tree() and not is_dead:
		burst_cooldown_remaining = maxf(burst_cooldown, 0.0)
		is_bursting = false
		if velocity.length_squared() > 4.0:
			_play_animation(move_animation)
		else:
			_play_animation(idle_animation)


func _shoot_bullet() -> void:
	if bullet_scene == null or not is_instance_valid(player):
		return

	var bullet := bullet_scene.instantiate()
	if not bullet.has_method("launch"):
		push_error("GunnerBullet scene must have a launch(start_position, target_position, source) method.")
		bullet.free()
		return

	var current_scene := get_tree().current_scene
	if current_scene == null:
		bullet.free()
		return

	current_scene.add_child(bullet)
	# GunnerBullet exposes an exported `damage` property.
	bullet.set("damage", bullet_damage)
	bullet.call("launch", muzzle.global_position, player.global_position, self)

	if is_instance_valid(gun_audio_player) and gun_audio_player.stream != null:
		gun_audio_player.play()


func _play_animation(animation_name: StringName) -> void:
	if is_dead or not is_instance_valid(animation_player):
		return
	if animation_name == &"" or current_animation == animation_name:
		return
	if not animation_player.has_animation(animation_name):
		return

	current_animation = animation_name
	animation_player.play(animation_name)


# --------------------------------------------------
# HEALTH AND DAMAGE
# --------------------------------------------------

func take_damage(amount: int, attacker: Node2D = null) -> void:
	if is_dead or amount <= 0:
		return

	current_health = maxi(current_health - amount, 0)
	_apply_knockback(attacker)
	_play_damage_flash()

	print("Gunner health: %d/%d" % [current_health, max_health])

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

	knockback_velocity = direction.normalized() * knockback_force
	knockback_timer = maxf(knockback_duration, 0.0)


func _setup_damage_shader() -> void:
	if not is_instance_valid(body_sprite):
		return

	var shader_material := body_sprite.material as ShaderMaterial
	if shader_material == null:
		return

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
	var half_flash_duration := (
		maxf(damage_flash_duration, 0.01)
		/ float(maxi(damage_flash_count * 2, 1))
	)

	shader_material.set_shader_parameter("damage_flash", 0.0)

	for _flash_index in range(maxi(damage_flash_count, 1)):
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

	damage_tween.tween_callback(func() -> void: _set_damage_flash(0.0))


func _set_damage_flash(value: float) -> void:
	if not is_instance_valid(body_sprite):
		return

	var shader_material := body_sprite.material as ShaderMaterial
	if shader_material != null:
		shader_material.set_shader_parameter("damage_flash", value)


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

	set_collision_layer_value(1, false)
	set_collision_mask_value(1, false)

	if is_instance_valid(detection_range):
		detection_range.set_deferred("monitoring", false)

	queue_free()
