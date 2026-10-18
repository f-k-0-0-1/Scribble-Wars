
extends Node

@onready var org_name: Label = $Label

@export var fade_duration: float = 2.0
@export var exit_wait_time: float = 1.0

var has_transitioned: bool = false


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color.BLACK)

	org_name.modulate.a = 0.0
	_play_splash()


func _play_splash() -> void:
	var tween := create_tween()

	tween.tween_property(
		org_name,
		"modulate:a",
		1.0,
		maxf(fade_duration, 0.01)
	)

	await tween.finished

	if not is_inside_tree():
		return

	await get_tree().create_timer(exit_wait_time).timeout

	if not is_inside_tree() or has_transitioned:
		return

	has_transitioned = true
	SceneManager.go_to_menu()
