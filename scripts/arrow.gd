
extends Area2D

@export var speed: float = 450.0
@export var damage: int = 10
@export var lifetime: float = 3.0

# Assumes the arrow artwork points right at zero rotation.
@export var sprite_rotation_offset_degrees: float = 0.0

var direction: Vector2 = Vector2.RIGHT
var shooter: Node2D
var has_hit: bool = false


func _ready() -> void:
	add_to_group("enemy_projectiles")

	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)

	# Destroy the arrow if it travels too long without hitting anything.
	await get_tree().create_timer(lifetime).timeout

	if is_inside_tree():
		queue_free()


func launch(
	start_position: Vector2,
	target_position: Vector2,
	source: Node2D
) -> void:
	global_position = start_position
	shooter = source

	direction = (target_position - start_position).normalized()

	rotation = (
		direction.angle()
		+ deg_to_rad(sprite_rotation_offset_degrees)
	)


func _physics_process(delta: float) -> void:
	if has_hit:
		return

	global_position += direction * speed * delta


func block_by_shield() -> void:
	if has_hit:
		return

	has_hit = true
	queue_free()


func _on_area_entered(area: Area2D) -> void:
	if has_hit:
		return

	if area.is_in_group("shield_hitboxes"):
		# The shield decides whether blocking is currently active.
		# If blocking is inactive, this arrow continues travelling.
		if area.get_parent().has_method("_on_shield_area_entered"):
			area.get_parent()._on_shield_area_entered(self)

		return


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

	# Destroy the arrow when it hits a solid wall.
	if body is StaticBody2D or body is TileMapLayer:
		has_hit = true
		queue_free()
