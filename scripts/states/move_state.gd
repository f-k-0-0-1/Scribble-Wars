class_name MoveState
extends State


func enter(_previous_state_name: String, _data: Dictionary = {}) -> void:
	if is_instance_valid(player):
		player._play_animation("move")


func physics_update(delta: float) -> void:
	if not is_instance_valid(player) or player.is_dead:
		return

	var direction: Vector2 = player.get_movement_direction()
	if direction.length_squared() <= 0.001 and player.knockback_timer <= 0.0:
		transition_to("Idle")
		return

	player._apply_state_movement(delta, true)
	player._play_animation("move")


func handle_input(event: InputEvent) -> void:
	if not is_instance_valid(player):
		return

	if event.is_action_pressed("attack"):
		player.attack()
	elif event.is_action_pressed("block"):
		player.start_block()
