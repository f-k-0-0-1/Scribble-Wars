class_name HurtState
extends State

var hurt_timer: float = 0.25


func enter(_previous_state_name: String, data: Dictionary = {}) -> void:
	if not is_instance_valid(player):
		return

	hurt_timer = maxf(float(data.get("duration", 0.25)), 0.0)

	# A hurt animation is optional; if absent, return to locomotion clips.
	if player.animation_player.has_animation(&"hurt"):
		player.play_hurt_animation_if_available()
	else:
		player._play_current_locomotion_animation()


func physics_update(delta: float) -> void:
	if not is_instance_valid(player) or player.is_dead:
		return

	player._apply_knockback_movement(delta)
	hurt_timer = maxf(hurt_timer - delta, 0.0)

	if hurt_timer > 0.0 or player.knockback_timer > 0.0:
		return

	if player.block_input_active:
		transition_to("Block")
	elif player.get_movement_direction().length_squared() > 0.001:
		transition_to("Move")
	else:
		transition_to("Idle")


func handle_input(event: InputEvent) -> void:
	if not is_instance_valid(player):
		return

	# Remember button state so a held shield can resume after recovery.
	if event.is_action_pressed("block"):
		player.block_input_active = true
	elif event.is_action_released("block"):
		player.block_input_active = false
