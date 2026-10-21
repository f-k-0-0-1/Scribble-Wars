class_name BlockState
extends State


func enter(_previous_state_name: String, _data: Dictionary = {}) -> void:
	if not is_instance_valid(player) or player.is_dead:
		return

	player.is_blocking = true
	player._set_hand_pivots_for_facing_direction()

	# Keep Player idle/move animation active. Equipment owns its own block pose.
	if is_instance_valid(player.left_hand_item):
		player.left_hand_item.block()
	if is_instance_valid(player.right_hand_item):
		player.right_hand_item.block()

	player._orient_blocking_shield()
	player._play_current_locomotion_animation()


func physics_update(delta: float) -> void:
	if not is_instance_valid(player) or player.is_dead:
		return

	if not player.block_input_active:
		_transition_to_locomotion()
		return

	player._apply_state_movement(delta, true)
	player._play_current_locomotion_animation()
	player._orient_blocking_shield()


func handle_input(event: InputEvent) -> void:
	if not is_instance_valid(player):
		return

	if event.is_action_released("block"):
		player.stop_block()


func exit() -> void:
	if not is_instance_valid(player):
		return

	player.is_blocking = false
	if is_instance_valid(player.left_hand_item):
		player.left_hand_item.stop_action()
	if is_instance_valid(player.right_hand_item):
		player.right_hand_item.stop_action()


func _transition_to_locomotion() -> void:
	if not is_instance_valid(player):
		return

	if player.get_movement_direction().length_squared() > 0.001:
		transition_to("Move")
	else:
		transition_to("Idle")
