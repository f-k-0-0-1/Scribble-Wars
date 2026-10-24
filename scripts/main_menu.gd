extends Control

@onready var offline_button: Button = $VBoxContainer/Button
@onready var online_button: Button = $VBoxContainer/OnlineButton
@onready var quit_button: Button = $VBoxContainer/Button2


func _ready() -> void:
	offline_button.text = "OFFLINE PLAY"
	online_button.text = "ONLINE MULTIPLAYER"
	quit_button.text = "QUIT"

	offline_button.pressed.connect(_on_offline_pressed)
	online_button.pressed.connect(_on_online_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	offline_button.grab_focus()


func _on_offline_pressed() -> void:
	_set_buttons_disabled(true)
	AudioManager.play_button_click()
	NetworkClient.disconnect_from_server()
	SceneManager.start_new_game()


func _on_online_pressed() -> void:
	_set_buttons_disabled(true)
	AudioManager.play_button_click()
	NetworkClient.disconnect_from_server()
	SceneManager.change_scene("res://scenes/server_list.tscn")


func _on_quit_pressed() -> void:
	AudioManager.play_button_click()
	get_tree().quit()


func _set_buttons_disabled(value: bool) -> void:
	offline_button.disabled = value
	online_button.disabled = value
	quit_button.disabled = value
