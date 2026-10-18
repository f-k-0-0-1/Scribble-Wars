
extends Control

@onready var play_button: Button = $VBoxContainer/Button
@onready var quit_button: Button = $VBoxContainer/Button2


func _ready() -> void:
	play_button.pressed.connect(_on_play_pressed)
	quit_button.pressed.connect(_on_quit_pressed)

	play_button.grab_focus()


func _on_play_pressed() -> void:
	play_button.disabled = true
	quit_button.disabled = true

	SceneManager.start_new_game()


func _on_quit_pressed() -> void:
	get_tree().quit()
