class_name IdleState
extends State


func enter(_previous_state_name: String, _data: Dictionary = {}) -> void:
	if not is_instance_valid(player):
		return

	player._play_animation("idle")
	if player.knockback_timer <= 0.0:
		player.velocity = Vector2.ZERO


func physics_update(delta: float) -> void:
	if not is_instance_valid(player) or player.is_dead:
		return

	if player.get_movement_direction().length_squared() > 0.001:
		transition_to("Move")
		return

	player._apply_state_movement(delta, false)
	player._play_animation("idle")


func handle_input(event: InputEvent) -> void:
	if not is_instance_valid(player):
		return

	if event.is_action_pressed("attack"):
		player.attack()
	elif event.is_action_pressed("block"):
		player.start_block()
