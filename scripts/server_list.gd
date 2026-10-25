extends Control

const TEST_SERVER_NAME := "Scribble Wars Test Server"
const TEST_SERVER_IP := "147.185.221.218"
const TEST_SERVER_PORT := 29983

@onready var server_1: Button = $VBoxContainer/Button
@onready var server_2: Button = $VBoxContainer/Button3
@onready var server_3: Button = $VBoxContainer/Button2
@onready var back_button: Button = $VBoxContainer/BackButton
@onready var title_label: Label = $Label

var status_label: Label


func _ready() -> void:
	title_label.text = "Browse Servers"

	server_1.text = "%s | Join test server" % TEST_SERVER_NAME
	server_2.text = "More servers coming soon"
	server_3.text = "More servers coming soon"

	server_2.disabled = true
	server_3.disabled = true

	status_label = Label.new()
	status_label.name = "ConnectionStatus"
	status_label.text = "Select a server to connect."
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.add_theme_color_override(
		"font_color",
		Color(0.2, 0.2, 0.2)
	)

	$VBoxContainer.add_child(status_label)
	$VBoxContainer.move_child(
		status_label,
		$VBoxContainer.get_child_count() - 2
	)

	if not server_1.pressed.is_connected(_on_test_server_pressed):
		server_1.pressed.connect(_on_test_server_pressed)

	if not back_button.pressed.is_connected(_on_back_button_pressed):
		back_button.pressed.connect(_on_back_button_pressed)

	if not NetworkClient.connection_established.is_connected(
		_on_connection_established
	):
		NetworkClient.connection_established.connect(
			_on_connection_established
		)

	if not NetworkClient.connection_failed.is_connected(
		_on_connection_failed
	):
		NetworkClient.connection_failed.connect(
			_on_connection_failed
	)


func _exit_tree() -> void:
	if NetworkClient.connection_established.is_connected(
		_on_connection_established
	):
		NetworkClient.connection_established.disconnect(
			_on_connection_established
		)

	if NetworkClient.connection_failed.is_connected(
		_on_connection_failed
	):
		NetworkClient.connection_failed.disconnect(
			_on_connection_failed
		)


func _on_test_server_pressed() -> void:
	# Prevent duplicate connection attempts.
	if (
		NetworkClient.connection_in_progress
		or NetworkClient.connected_to_server
	):
		return

	server_1.disabled = true
	status_label.text = "Connecting to %s..." % TEST_SERVER_NAME

	var error: Error = NetworkClient.connect_to_server(
		TEST_SERVER_IP,
		TEST_SERVER_PORT
	)

	if error != OK:
		status_label.text = "Could not connect. Error: %d" % error
		server_1.disabled = false


func _on_connection_established(player_id: int) -> void:
	status_label.text = "Connected! Joining dungeon..."

	print("Connected as player ", player_id)

	# Defer the scene change until the current signal finishes.
	get_tree().call_deferred(
		"change_scene_to_file",
		"res://scenes/dungeon_01.tscn"
	)


func _on_connection_failed(reason: String) -> void:
	status_label.text = reason
	server_1.disabled = false

func _on_back_button_pressed() -> void:
	NetworkClient.disconnect_from_server()
	AudioManager.play_button_click()
	SceneManager.go_to_menu()
