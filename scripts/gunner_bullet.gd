
extends Area2D

@export var speed: float = 450.0
@export var damage: int = 10
@export var lifetime: float = 5.0
@export var sprite_rotation_offset_degrees: float = 0.0

var direction: Vector2 = Vector2.RIGHT
var shooter: Node2D
var has_hit: bool = false

# Optional: retained if your duplicated scene has this audio node.
@onready var projectile_audio_player := (
	get_node_or_null("ArrowSwooshPlayer") as AudioStreamPlayer2D
)


func _ready() -> void:
	add_to_group("enemy_projectiles")

	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

	# The shield's own area_entered signal handles projectiles.
	# Do not call the shield callback manually from this projectile.
	if lifetime > 0.0:
		get_tree().create_timer(lifetime).timeout.connect(
			_on_lifetime_timeout,
			CONNECT_ONE_SHOT
		)


func launch(
	start_position: Vector2,
	target_position: Vector2,
	source: Node2D
) -> void:
	global_position = start_position
	shooter = source

	var aim_direction := target_position - start_position

	if aim_direction.length_squared() > 0.001:
		direction = aim_direction.normalized()

	rotation = (
		direction.angle()
		+ deg_to_rad(sprite_rotation_offset_degrees)
	)

	if (
		is_instance_valid(projectile_audio_player)
		and projectile_audio_player.stream != null
	):
		projectile_audio_player.play()


func _physics_process(delta: float) -> void:
	if has_hit:
		return

	global_position += direction * speed * delta


func block_by_shield() -> void:
	if has_hit:
		return

	has_hit = true
	queue_free()


func _on_body_entered(body: Node2D) -> void:
	if has_hit:
		return

	if body == shooter:
		return

	if body.is_in_group("player"):
		has_hit = true

		if body.has_method("take_damage"):
			body.take_damage(damage)

		queue_free()
		return

	# Remove the bullet when it hits a wall.
	if body is StaticBody2D or body is TileMapLayer:
		has_hit = true
		queue_free()


func _on_lifetime_timeout() -> void:
	if not has_hit:
		has_hit = true
		queue_free()
