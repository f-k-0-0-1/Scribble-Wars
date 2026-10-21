class_name State
extends Node

var state_machine: Variant = null
var player: Variant = null

func enter(_previous_state_name: String, _data: Dictionary = {}) -> void:
	pass

func exit() -> void:
	pass

func update(_delta: float) -> void:
	pass

func physics_update(_delta: float) -> void:
	pass

func handle_input(_event: InputEvent) -> void:
	pass

func transition_to(state_name: String, data: Dictionary = {}) -> void:
	if is_instance_valid(state_machine):
		state_machine.transition_to(state_name, data)
