
extends Control

@onready var play_button: Button = $VBoxContainer/Button
@onready var server_button: Button = $VBoxContainer/Button3
@onready var quit_button: Button = $VBoxContainer/Button2


func _ready() -> void:
	play_button.pressed.connect(_on_play_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	server_button.pressed.connect(_on_server_pressed)

	play_button.grab_focus()


func _on_play_pressed() -> void:
	play_button.disabled = true
	quit_button.disabled = true
	AudioManager.play_button_click()
	SceneManager.start_new_game()

func _on_server_pressed() -> void:
	AudioManager.play_button_click()
	SceneManager.go_to_server_list()

func _on_quit_pressed() -> void:
	AudioManager.play_button_click()
	get_tree().quit()
