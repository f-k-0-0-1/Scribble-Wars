class_name AttackState
extends State

var _run_id: int = 0


func enter(_previous_state_name: String, _data: Dictionary = {}) -> void:
	if not is_instance_valid(player) or player.is_dead:
		transition_to("Idle")
		return

	if not is_instance_valid(player.right_hand_item):
		player.can_attack = true
		transition_to("Idle")
		return

	_run_id += 1
	player.combo_active = true
	player.can_attack = false
	player.combo_step = 0
	player.combo_window_open = false
	player.combo_input_queued = false
	player._capture_combo_animation_speeds()

	player.locked_target = player._acquire_aim_lock_target()
	if is_instance_valid(player.locked_target):
		var toward_target: Vector2 = (
			player.locked_target.global_position - player.global_position
		)
		if toward_target.length_squared() > 0.001:
			player.facing_direction = toward_target.normalized()
			player._set_hand_pivots_for_facing_direction()

	_run_combo_sequence(_run_id)


func handle_input(event: InputEvent) -> void:
	if not is_instance_valid(player):
		return

	if event.is_action_pressed("attack"):
		queue_combo_input()


func queue_combo_input() -> void:
	if (
		is_instance_valid(player)
		and player.combo_active
		and player.combo_window_open
		and player.combo_step < 3
	):
		player.combo_input_queued = true


func physics_update(delta: float) -> void:
	if not is_instance_valid(player) or player.is_dead:
		return

	if is_instance_valid(player.locked_target):
		player._update_aim_lock()
	else:
		var direction: Vector2 = player.get_movement_direction()
		if direction.length_squared() > 0.001:
			player.facing_direction = direction.normalized()
			player._set_hand_pivots_for_facing_direction()

	player._apply_state_movement(delta, false)


func _run_combo_sequence(run_id: int) -> void:
	for step in range(1, 4):
		if not _is_run_valid(run_id):
			return

		player.combo_step = step
		player.combo_window_open = false
		player.combo_input_queued = false
		player._play_combo_step(step)

		var duration: float = player._get_combo_step_duration(step)
		duration = maxf(duration, maxf(player.attack_cooldown, 0.05))

		var window_start: float = clampf(
			duration * player.combo_window_start_ratio,
			0.05,
			maxf(duration - 0.02, 0.05)
		)

		await get_tree().create_timer(window_start).timeout
		if not _is_run_valid(run_id):
			return

		player.combo_window_open = step < 3

		var remaining: float = maxf(duration - window_start, 0.02)
		await get_tree().create_timer(remaining).timeout
		if not _is_run_valid(run_id):
			return

		player.combo_window_open = false
		if step >= 3 or not player.combo_input_queued:
			break

	if not _is_run_valid(run_id):
		return

	if player.combo_recovery_time > 0.0:
		await get_tree().create_timer(player.combo_recovery_time).timeout
	if not _is_run_valid(run_id):
		return

	player._restore_combo_animation_speeds()
	player.combo_window_open = false
	player.combo_input_queued = false
	player.combo_step = 0
	player.can_attack = true
	player._clear_aim_lock()

	var direction: Vector2 = player.get_movement_direction()
	if player.block_input_active:
		transition_to("Block")
	elif direction.length_squared() > 0.001:
		transition_to("Move")
	else:
		transition_to("Idle")


func _is_run_valid(run_id: int) -> bool:
	return (
		is_inside_tree()
		and is_instance_valid(player)
		and not player.is_dead
		and player.combo_active
		and _run_id == run_id
		and state_machine.current_state == self
	)


func exit() -> void:
	_run_id += 1

	if not is_instance_valid(player):
		return

	player.combo_active = false
	player.combo_window_open = false
	player.combo_input_queued = false
	player.combo_step = 0
	player.can_attack = true
	player._clear_aim_lock()
	player._restore_combo_animation_speeds()

	# Ensure a cancelled attack cannot leave the sword hitbox enabled.
	if is_instance_valid(player.right_hand_item):
		player.right_hand_item.stop_action()

	# On interruption, stop the finisher animation too; on normal completion
	# this simply returns the shield to its resting pose.
	if is_instance_valid(player.left_hand_item):
		var shield_player: AnimationPlayer = (
			player._get_item_animation_player(player.left_hand_item)
		)
		if shield_player and shield_player.current_animation == "attack_3":
			player.left_hand_item.stop_action()
