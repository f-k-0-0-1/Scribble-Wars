class_name StateMachine
extends Node

@export var initial_state_name: StringName = &"Idle"

var current_state: State = null
var states: Dictionary = {}
var player: Variant = null
var is_initialized: bool = false


func initialize(player_ref: Node) -> void:
	if is_initialized:
		return

	player = player_ref
	states.clear()

	for child in get_children():
		if child is State:
			var state := child as State
			var key: String = String(state.name).to_lower()

			if states.has(key):
				push_error("StateMachine has duplicate state name: %s" % state.name)
				continue

			state.state_machine = self
			state.player = player
			states[key] = state

	is_initialized = true

	var requested_key: String = String(initial_state_name).to_lower()
	var start_state: State = states.get(requested_key) as State

	if start_state == null:
		start_state = states.get("idle") as State

	if start_state == null:
		push_error("StateMachine needs an Idle state (or a valid initial_state_name).")
		is_initialized = false
		return

	current_state = start_state
	current_state.enter("", {})


func transition_to(target_state_name: String, data: Dictionary = {}) -> void:
	if not is_initialized:
		return

	var key: String = target_state_name.to_lower()
	var next_state: State = states.get(key) as State

	if next_state == null:
		push_error("StateMachine state not found: %s" % target_state_name)
		return

	if current_state == next_state:
		return

	var previous_name: String = ""
	if is_instance_valid(current_state):
		previous_name = String(current_state.name)
		current_state.exit()

	current_state = next_state
	current_state.enter(previous_name, data)


func is_in_state(state_name: String) -> bool:
	return (
		is_instance_valid(current_state)
		and String(current_state.name).to_lower() == state_name.to_lower()
	)


func update(delta: float) -> void:
	if is_initialized and is_instance_valid(current_state):
		current_state.update(delta)


func physics_update(delta: float) -> void:
	if is_initialized and is_instance_valid(current_state):
		current_state.physics_update(delta)


func handle_input(event: InputEvent) -> void:
	if is_initialized and is_instance_valid(current_state):
		current_state.handle_input(event)
