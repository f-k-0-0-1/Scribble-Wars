extends Control




func _on_back_button_pressed() -> void:
	AudioManager.play_button_click()
	SceneManager.go_to_menu()
