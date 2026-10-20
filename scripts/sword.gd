
extends Equipment

@export var damage: int = 20

@onready var hitbox: Area2D = $GripPivot/Hitbox

var hit_targets: Array[Node2D] = []


func _ready() -> void:
	super._ready()

	hitbox.monitoring = false

	if not hitbox.body_entered.is_connected(_on_hitbox_body_entered):
		hitbox.body_entered.connect(_on_hitbox_body_entered)


func begin_damage() -> void:
	hit_targets.clear()
	hitbox.set_deferred("monitoring", true)


func end_damage() -> void:
	hitbox.set_deferred("monitoring", false)


func _on_hitbox_body_entered(body: Node2D) -> void:
	if not body.is_in_group("enemy"):
		return

	if hit_targets.has(body):
		return

	hit_targets.append(body)

	if body.has_method("take_damage"):
		body.take_damage(damage)
