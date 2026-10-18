
extends Control

@onready var status_label: Label = get_node_or_null("StatusLabel")
@onready var progress_bar: ProgressBar = get_node_or_null("ProgressBar")

var loading_path: String = ""
var loading_started: bool = false
var activation_started: bool = false


func _ready() -> void:
	loading_path = SceneManager.target_level_path

	if loading_path.is_empty():
		_show_error("No destination scene was specified.")
		return

	if progress_bar:
		progress_bar.min_value = 0.0
		progress_bar.max_value = 100.0
		progress_bar.value = 0.0

	if status_label:
		status_label.text = "Entering the dungeon..."

	var error := ResourceLoader.load_threaded_request(loading_path)

	if error != OK:
		_show_error("Could not start loading: " + loading_path)
		return

	loading_started = true


func _process(_delta: float) -> void:
	if not loading_started or activation_started:
		return

	var progress: Array = []

	var status := ResourceLoader.load_threaded_get_status(
		loading_path,
		progress
	)

	if not progress.is_empty():
		var percent := float(progress[0]) * 100.0

		if progress_bar:
			progress_bar.value = percent

		if status_label:
			status_label.text = "Loading... %d%%" % int(percent)

	match status:
		ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			pass

		ResourceLoader.THREAD_LOAD_LOADED:
			_activate_destination()

		ResourceLoader.THREAD_LOAD_FAILED:
			_show_error("Failed to load: " + loading_path)

		ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			_show_error("Invalid scene resource: " + loading_path)


func _activate_destination() -> void:
	if activation_started:
		return

	activation_started = true
	loading_started = false

	var packed_scene := ResourceLoader.load_threaded_get(
		loading_path
	) as PackedScene

	if packed_scene == null:
		activation_started = false
		_show_error("The loaded resource is not a PackedScene.")
		return

	var error := SceneManager.finish_transition(packed_scene)

	if error != OK:
		activation_started = false
		_show_error("Could not activate the destination scene.")


func _show_error(message: String) -> void:
	loading_started = false

	if status_label:
		status_label.text = "Error: " + message

	push_error(message)
	SceneManager.cancel_transition()
