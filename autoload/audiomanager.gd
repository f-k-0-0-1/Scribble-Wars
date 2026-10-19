
extends Node

# Audio file paths.
const MUSIC_PATH: String = "res://audio/old city theme.ogg"
const WALK_LEFT_PATH: String = "res://audio/sfx_step_grass_l.ogg"
const WALK_RIGHT_PATH: String = "res://audio/sfx_step_grass_r.ogg"
const SWORD_SLASH_PATH: String = "res://audio/swod_slash_sfx.ogg"
const SHIELD_SLIDE_PATH: String = "res://audio/slide_sfx.ogg"
const SHIELD_IMPACT_PATH: String = "res://audio/shield_impact_sfx.ogg"
const BUTTON_CLICK_PATH: String = "res://audio/button_click.ogg"

# Audio levels.
const MUSIC_VOLUME_DB: float = -10.0
const FOOTSTEPS_VOLUME_DB: float = -18.0
const SWORD_SLASH_VOLUME_DB: float = -5.0
const SHIELD_SLIDE_VOLUME_DB: float = -2.0
const SHIELD_IMPACT_VOLUME_DB: float = -8.0
const BUTTON_CLICK_VOLUME_DB: float = -5.0

# Footstep timing.
const FOOTSTEP_INTERVAL: float = 0.38

var music_player: AudioStreamPlayer
var walk_left: AudioStreamPlayer
var walk_right: AudioStreamPlayer
var sword_slash_player: AudioStreamPlayer
var shield_slide_player: AudioStreamPlayer
var shield_impact_player: AudioStreamPlayer
var button_click_player: AudioStreamPlayer

var footstep_timer: float = 0.0
var left_foot_next: bool = true
var was_moving: bool = false


func _ready() -> void:
	music_player = _create_player("MusicPlayer", MUSIC_VOLUME_DB)
	walk_left = _create_player("WalkLeft", FOOTSTEPS_VOLUME_DB)
	walk_right = _create_player("WalkRight", FOOTSTEPS_VOLUME_DB)

	sword_slash_player = _create_player(
		"SwordSlash",
		SWORD_SLASH_VOLUME_DB
	)

	shield_slide_player = _create_player(
		"ShieldSlide",
		SHIELD_SLIDE_VOLUME_DB
	)

	shield_impact_player = _create_player(
		"ShieldImpact",
		SHIELD_IMPACT_VOLUME_DB
	)

	button_click_player = _create_player(
		"ButtonClick",
		BUTTON_CLICK_VOLUME_DB
	)

	# Load audio files.
	music_player.stream = _load_audio(MUSIC_PATH)
	walk_left.stream = _load_audio(WALK_LEFT_PATH)
	walk_right.stream = _load_audio(WALK_RIGHT_PATH)
	sword_slash_player.stream = _load_audio(SWORD_SLASH_PATH)
	shield_slide_player.stream = _load_audio(SHIELD_SLIDE_PATH)
	shield_impact_player.stream = _load_audio(SHIELD_IMPACT_PATH)
	button_click_player.stream = _load_audio(BUTTON_CLICK_PATH)

	if music_player.stream:
		music_player.play()


func _create_player(
	player_name: String,
	volume_db: float
) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.name = player_name
	player.volume_db = volume_db
	add_child(player)
	return player


func _load_audio(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		push_warning("Audio file not found: " + path)
		return null

	var audio := load(path) as AudioStream

	if audio == null:
		push_warning("Failed to load audio file: " + path)

	return audio


func update_footsteps(is_moving: bool, delta: float) -> void:
	if not is_moving:
		footstep_timer = 0.0
		was_moving = false
		return

	if not was_moving:
		footstep_timer = 0.0

	was_moving = true
	footstep_timer -= delta

	if footstep_timer <= 0.0:
		_play_footstep()
		footstep_timer = FOOTSTEP_INTERVAL


func _play_footstep() -> void:
	var player: AudioStreamPlayer

	if left_foot_next:
		player = walk_left
	else:
		player = walk_right

	if player.stream:
		player.pitch_scale = randf_range(0.96, 1.04)
		player.play()

	left_foot_next = not left_foot_next


func play_sword_slash() -> void:
	if sword_slash_player == null:
		return

	if sword_slash_player.stream == null:
		return

	sword_slash_player.pitch_scale = randf_range(0.95, 1.05)
	sword_slash_player.play()


func play_shield_slide() -> void:
	if shield_slide_player == null:
		return

	if shield_slide_player.stream == null:
		return

	shield_slide_player.pitch_scale = randf_range(0.97, 1.03)
	shield_slide_player.play()


func play_shield_impact() -> void:
	if shield_impact_player == null:
		return

	if shield_impact_player.stream == null:
		return

	shield_impact_player.pitch_scale = randf_range(0.95, 1.05)
	shield_impact_player.play()


func play_button_click() -> void:
	if button_click_player == null:
		return

	if button_click_player.stream == null:
		return

	button_click_player.pitch_scale = randf_range(0.98, 1.02)
	button_click_player.play()


func set_music_volume(value: float) -> void:
	if music_player:
		music_player.volume_db = linear_to_db(
			clampf(value, 0.0, 1.0)
		)


func set_footsteps_volume(value: float) -> void:
	var volume := linear_to_db(clampf(value, 0.0, 1.0))

	if walk_left:
		walk_left.volume_db = volume

	if walk_right:
		walk_right.volume_db = volume


func set_sword_slash_volume(value: float) -> void:
	if sword_slash_player:
		sword_slash_player.volume_db = linear_to_db(
			clampf(value, 0.0, 1.0)
		)


func set_shield_slide_volume(value: float) -> void:
	if shield_slide_player:
		shield_slide_player.volume_db = linear_to_db(
			clampf(value, 0.0, 1.0)
		)


func set_shield_impact_volume(value: float) -> void:
	if shield_impact_player:
		shield_impact_player.volume_db = linear_to_db(
			clampf(value, 0.0, 1.0)
		)


func set_button_click_volume(value: float) -> void:
	if button_click_player:
		button_click_player.volume_db = linear_to_db(
			clampf(value, 0.0, 1.0)
		)


func stop_music() -> void:
	if music_player:
		music_player.stop()


func resume_music() -> void:
	if (
		music_player
		and music_player.stream
		and not music_player.playing
	):
		music_player.play()
