extends Node2D

@export var interpolation_speed: float = 14.0

var player_id: int = -1
var target_position: Vector2 = Vector2.ZERO
var has_target: bool = false

@onready var name_label: Label = $NameLabel


func configure(id: int) -> void:
	player_id = id
	if is_instance_valid(name_label):
		name_label.text = "Player %d" % player_id
	target_position = global_position
	has_target = true


func set_target_position(value: Vector2) -> void:
	target_position = value
	if not has_target:
		global_position = target_position
		has_target = true


func _process(delta: float) -> void:
	if not has_target:
		return
	var weight: float = 1.0 - exp(-interpolation_speed * delta)
	global_position = global_position.lerp(target_position, weight)
