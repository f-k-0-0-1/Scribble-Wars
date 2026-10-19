
class_name Equipment
extends Node2D

@export var item_name: String = "Equipment"

@onready var animation_player: AnimationPlayer = $AnimationPlayer


func play_action(action: String) -> void:
	if animation_player.has_animation(action):
		animation_player.play(action)


func attack() -> void:
	play_action("attack")


func block() -> void:
	play_action("block")


func stop_action() -> void:
	animation_player.stop()
