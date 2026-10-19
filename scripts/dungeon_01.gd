
extends Node2D

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		SceneManager.go_to_menu()

func _on_back_button_pressed() -> void:
	SceneManager.go_to_menu()
