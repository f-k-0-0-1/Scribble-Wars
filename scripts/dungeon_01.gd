extends Node2D

@onready var health_bar: ProgressBar = $HUD/HealthBar


func _ready() -> void:
	# Wait until the Player has entered the scene tree.
	call_deferred("_connect_to_player")


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("back"):
		_return_to_menu()


func _on_back_button_pressed() -> void:
	_return_to_menu()


func _return_to_menu() -> void:
	if NetworkClient.is_connected_to_server():
		NetworkClient.disconnect_from_server()
	AudioManager.play_button_click()
	SceneManager.go_to_menu()


func _connect_to_player() -> void:
	var player := get_tree().get_first_node_in_group("player")

	if player == null:
		push_warning("HUD: Player node not found.")
		return

	if not player.has_signal("health_changed"):
		push_warning("HUD: Player does not have a health_changed signal.")
		return

	var callback := Callable(self, "_on_health_changed")

	if not player.is_connected("health_changed", callback):
		player.connect("health_changed", callback)

	# Initialize the health bar with the player's current health.
	var current_health: int = int(player.get("current_health"))
	var max_health: int = int(player.get("max_health"))

	_on_health_changed(current_health, max_health)


func _on_health_changed(
	current_health: int,
	max_health: int
) -> void:
	health_bar.max_value = max_health
	health_bar.value = current_health
