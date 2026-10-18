
extends Node

signal scene_changed(scene_path: String)

const MAIN_MENU_PATH: String = "res://scenes/main_menu.tscn"
const LOADING_SCREEN_PATH: String = "res://scenes/loading_screen.tscn"
const FIRST_DUNGEON_PATH: String = "res://scenes/dungeon_01.tscn"

var target_level_path: String = ""
var is_transitioning: bool = false


func go_to_menu() -> void:
	change_scene(MAIN_MENU_PATH)


func start_new_game() -> void:
	change_scene(FIRST_DUNGEON_PATH)


func change_scene(scene_path: String) -> void:
	if is_transitioning:
		return

	if not ResourceLoader.exists(scene_path):
		push_error("Destination scene not found: " + scene_path)
		return

	if not ResourceLoader.exists(LOADING_SCREEN_PATH):
		push_error("Loading screen not found: " + LOADING_SCREEN_PATH)
		return

	target_level_path = scene_path
	is_transitioning = true

	var error := get_tree().change_scene_to_file(LOADING_SCREEN_PATH)

	if error != OK:
		push_error("Could not open loading screen. Error: " + str(error))
		cancel_transition()


func finish_transition(packed_scene: PackedScene) -> Error:
	if not is_transitioning or packed_scene == null:
		return ERR_INVALID_PARAMETER

	var completed_path := target_level_path

	var error := get_tree().change_scene_to_packed(packed_scene)

	if error != OK:
		push_error("Failed to activate scene: " + completed_path)
		cancel_transition()
		return error

	target_level_path = ""
	is_transitioning = false

	scene_changed.emit(completed_path)
	return OK


func cancel_transition() -> void:
	target_level_path = ""
	is_transitioning = false


func restart_current_scene() -> void:
	var current_scene := get_tree().current_scene

	if current_scene == null:
		push_error("There is no current scene to restart.")
		return

	var path := current_scene.scene_file_path

	if path.is_empty():
		push_error("Current scene has no file path.")
		return

	change_scene(path)
