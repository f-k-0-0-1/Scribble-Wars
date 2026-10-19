
class_name Equipment
extends Node2D

@export var item_name: String = "Equipment"

@onready var animation_player: AnimationPlayer = get_node_or_null("AnimationPlayer")

var resting_position: Vector2
var resting_rotation: float
var resting_scale: Vector2


func _ready() -> void:
	# Save the default local transform after the item is attached.
	resting_position = position
	resting_rotation = rotation
	resting_scale = scale

	# Ensure the equipment starts in its resting pose.
	reset_pose()


func play_action(action: String) -> void:
	if animation_player == null:
		return

	if animation_player.has_animation(action):
		animation_player.play(action)

func play_slash_sound() -> void:
	AudioManager.play_sword_slash()
	
func play_shield_slide_sound() -> void:
	AudioManager.play_shield_slide()

func attack() -> void:
	play_action("attack")


func block() -> void:
	play_action("block")


func stop_action() -> void:
	if animation_player:
		animation_player.stop()

	reset_pose()


func reset_pose() -> void:
	position = resting_position
	rotation = resting_rotation
	scale = resting_scale
