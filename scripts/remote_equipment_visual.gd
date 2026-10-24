extends Node2D

## Visual-only replacement script for Sword/Shield instances on remote players.
## It preserves animation method-track compatibility but never deals damage.

var animation_player: AnimationPlayer = null
var _resting_position: Vector2 = Vector2.ZERO
var _resting_rotation: float = 0.0
var _resting_scale: Vector2 = Vector2.ONE


func _ready() -> void:
	animation_player = get_node_or_null("AnimationPlayer") as AnimationPlayer
	_resting_position = position
	_resting_rotation = rotation
	_resting_scale = scale


func apply_network_animation(animation_name: String, animation_time: float, force_restart: bool) -> void:
	if animation_player == null:
		return

	if animation_name == "none" or animation_name.is_empty():
		stop_action()
		return

	if not animation_player.has_animation(animation_name):
		return

	if force_restart or animation_player.current_animation != animation_name:
		animation_player.play(animation_name, 0.02)
		var length: float = animation_player.current_animation_length
		animation_player.seek(clampf(animation_time, 0.0, length), true)
		return

	# Avoid resetting animation every network packet; correct only significant drift
	# for non-looping action clips. Looping idle/block clips are allowed to run.
	var animation := animation_player.get_animation(animation_name)
	if animation != null and animation.loop_mode == Animation.LOOP_NONE:
		var expected: float = clampf(animation_time, 0.0, animation.length)
		var actual: float = animation_player.current_animation_position
		if absf(expected - actual) > 0.28:
			animation_player.seek(expected, true)


func stop_action() -> void:
	if animation_player != null:
		if animation_player.has_animation("RESET"):
			animation_player.play("RESET")
			animation_player.seek(0.0, true)
			animation_player.stop()
		else:
			animation_player.stop()

	position = _resting_position
	rotation = _resting_rotation
	scale = _resting_scale


# Animation resources call these methods. They are deliberately visual-only.
func begin_damage() -> void:
	pass


func end_damage() -> void:
	pass


func set_combo_step(_step: int) -> void:
	pass


func play_slash_sound() -> void:
	# Remote action sounds can be added later as one-shot network events.
	pass


func play_shield_slide_sound() -> void:
	pass


func play_action(action: String) -> void:
	apply_network_animation(action, 0.0, true)


func attack() -> void:
	play_action("attack")


func block() -> void:
	play_action("block")
