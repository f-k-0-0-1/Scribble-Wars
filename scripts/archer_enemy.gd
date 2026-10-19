
extends CharacterBody2D

@export var detection_radius: float = 350.0
@export var fire_interval: float = 1.5
@export var minimum_shoot_distance: float = 80.0
@export var bow_rotation_offset_degrees: float = 115.0
@export var arrow_scene: PackedScene

# Physics layers used by walls and the player must be included here.
@export_flags_2d_physics var line_of_sight_collision_mask: int = 1

var player: Node2D
var can_shoot: bool = true
var player_in_range: bool = false

@onready var bow_pivot: Node2D = $BowPivot
@onready var arrow_spawn: Marker2D = $BowPivot/Marker2D
@onready var detection_range: Area2D = $DetectionRange
@onready var detection_shape: CollisionShape2D = (
	$DetectionRange/CollisionShape2D
)


func _ready() -> void:
	add_to_group("enemies")

	if detection_shape.shape is CircleShape2D:
		detection_shape.shape = detection_shape.shape.duplicate()
		detection_shape.shape.radius = detection_radius

	detection_range.body_entered.connect(_on_body_entered)
	detection_range.body_exited.connect(_on_body_exited)

	call_deferred("_find_existing_player")


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(player):
		player = null
		player_in_range = false
		_find_player()

	if not is_instance_valid(player):
		return

	var distance: float = global_position.distance_to(
		player.global_position
	)

	if distance > detection_radius:
		player_in_range = false
		return

	player_in_range = true

	if distance < minimum_shoot_distance:
		return

	# Walls must not block detection of the player, only the shooting ray.
	if not has_line_of_sight():
		return

	# Aim the bow at the player.
	var aim_direction: Vector2 = (
		player.global_position - bow_pivot.global_position
	)

	bow_pivot.global_rotation = (
		aim_direction.angle()
		+ deg_to_rad(bow_rotation_offset_degrees)
	)

	if can_shoot:
		shoot_arrow()


func has_line_of_sight() -> bool:
	if not is_instance_valid(player):
		return false

	var space_state := get_world_2d().direct_space_state

	var query := PhysicsRayQueryParameters2D.create(
		bow_pivot.global_position,
		player.global_position,
		line_of_sight_collision_mask
	)

	# Ignore the archer's own collision.
	query.exclude = [get_rid()]

	var result: Dictionary = space_state.intersect_ray(query)

	# Nothing obstructs the path.
	if result.is_empty():
		return true

	# The first collision must be the player.
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
	if body.is_in_group("player"):
		player = body
		player_in_range = true


func _on_body_exited(body: Node2D) -> void:
	if body == player:
		player_in_range = false


func shoot_arrow() -> void:
	if not can_shoot or not player_in_range:
		return

	if not is_instance_valid(player):
		return

	# Recheck visibility immediately before firing.
	if not has_line_of_sight():
		return

	if arrow_scene == null:
		push_warning(
            "Assign arrow_scene in the ArcherEnemy Inspector."
		)
		return

	can_shoot = false

	var arrow := arrow_scene.instantiate()

	if not arrow.has_method("launch"):
		push_error("Arrow scene must have a launch() method.")
		arrow.free()
		can_shoot = true
		return

	get_tree().current_scene.add_child(arrow)

	arrow.launch(
		arrow_spawn.global_position,
		player.global_position,
		self
	)

	await get_tree().create_timer(fire_interval).timeout

	if is_inside_tree():
		can_shoot = true
