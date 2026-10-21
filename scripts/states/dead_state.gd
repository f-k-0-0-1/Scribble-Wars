class_name DeadState
extends State


func enter(_previous_state_name: String, _data: Dictionary = {}) -> void:
	if not is_instance_valid(player):
		return
	player._enter_dead_state()


func physics_update(_delta: float) -> void:
	if not is_instance_valid(player):
		return
	player.velocity = Vector2.ZERO
	player.move_and_slide()


func handle_input(_event: InputEvent) -> void:
	pass
