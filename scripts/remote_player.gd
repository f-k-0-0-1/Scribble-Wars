extends Node2D

## Visual-only player replica. It reuses the real player body, hand animations,
## sword scene, shield scene and AnimationPlayers, but never runs local input,
## collision, damage, or the Player state machine.

const SWORD_SCENE: PackedScene = preload("res://scenes/Sword.tscn")
const SHIELD_SCENE: PackedScene = preload("res://scenes/Shield.tscn")
const REMOTE_EQUIPMENT_SCRIPT: Script = preload(
	"res://scripts/remote_equipment_visual.gd"
)

@export var interpolation_delay: float = 0.14
@export var max_extrapolation_time: float = 0.05
@export var max_extrapolation_speed: float = 1200.0
@export var facing_rotation_speed: float = 20.0
@export var damage_flash_duration: float = 0.5
@export_range(1, 10, 1) var damage_flash_count: int = 3
@export var shield_forward_offset_degrees: float = 90.0
@export var idle_move_speed_scale: float = 1.5
@export var action_speed_scale: float = 1.0

var player_id: int = -1
var target_position: Vector2 = Vector2.ZERO
var target_facing: Vector2 = Vector2.DOWN
var has_target: bool = false
var is_blocking: bool = false
var is_dead: bool = false

# Position snapshots are interpolated slightly in the past. This absorbs UDP
# packet jitter instead of chasing each packet immediately with exponential lerp.
var _position_snapshots: Array[Dictionary] = []
var _position_initialized: bool = false
var _last_hit_flash_sequence: int = -1
var damage_tween: Tween = null

var _last_body_key: String = ""
var _last_sword_key: String = ""
var _last_shield_key: String = ""

var sword_visual: Node2D = null
var shield_visual: Node2D = null
var sword_animation_player: AnimationPlayer = null
var shield_animation_player: AnimationPlayer = null

@onready var body_pivot: Node2D = $BodyPivot
@onready var body_sprite: Sprite2D = $BodyPivot/BodySprite
@onready var body_animation_player: AnimationPlayer = $BodyPivot/AnimationPlayer
@onready var left_hand_pivot: Node2D = $LeftHandPivot
@onready var right_hand_pivot: Node2D = $RightHandPivot
@onready var left_socket: Marker2D = $LeftHandPivot/EquipmentSocket
@onready var right_socket: Marker2D = $RightHandPivot/EquipmentSocket
@onready var name_label: Label = get_node_or_null("NameLabel") as Label


func _ready() -> void:
	# Position is interpolated manually in _process(); avoid a second transform
	# interpolation pass if Godot's global physics interpolation is enabled.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	# Apply orientation after AnimationPlayer modifies hand transforms.
	process_priority = 100
	_setup_damage_flash_material()
	_add_visual_equipment()
	_disable_collision_nodes(self)
	if is_instance_valid(name_label):
		name_label.text = "Player"


func configure(id: int) -> void:
	player_id = id
	if is_instance_valid(name_label):
		name_label.text = "Player %d" % player_id
	target_position = global_position
	has_target = false
	_position_snapshots.clear()
	# The first real server snapshot initializes position and timeline.
	_position_initialized = false


func set_target_position(value: Vector2) -> void:
	_record_position_snapshot(value)


func set_network_state(position: Vector2, facing: Vector2, animation: String) -> void:
	# Compatibility helper for the previous simplified client.
	var snapshot := {
		"position": position,
		"facing": facing,
		"body_animation": animation if animation in ["idle", "move", "attack", "block", "hurt", "death"] else "idle",
		"body_time": 0.0,
		"combo_step": 0,
		"sword_animation": "none",
		"sword_time": 0.0,
		"shield_animation": "block" if animation == "block" else "none",
		"shield_time": 0.0,
		"blocking": animation == "block",
		"dead": animation == "death",
		"hit_flash_seq": 0
	}
	set_network_snapshot(snapshot)


func set_network_snapshot(state: Dictionary) -> void:
	var position_value: Variant = state.get("position", global_position)
	var snapshot_time: float = float(state.get("snapshot_time", _now_seconds()))
	if position_value is Vector2:
		_record_position_snapshot(position_value, snapshot_time)

	var hit_sequence: int = int(state.get("hit_flash_seq", 0))
	if _last_hit_flash_sequence < 0:
		# Initialise silently; don't flash just because a remote player joined.
		_last_hit_flash_sequence = hit_sequence
	elif hit_sequence > _last_hit_flash_sequence:
		_last_hit_flash_sequence = hit_sequence
		_play_damage_flash()

	var facing_value: Variant = state.get("facing", target_facing)
	if facing_value is Vector2 and facing_value.length_squared() > 0.001:
		target_facing = facing_value.normalized()

	is_blocking = bool(state.get("blocking", false))
	is_dead = bool(state.get("dead", false))

	var body_name: String = String(state.get("body_animation", "idle"))
	var body_time: float = float(state.get("body_time", 0.0))
	var combo_step: int = int(state.get("combo_step", 0))
	var sword_name: String = String(state.get("sword_animation", "none"))
	var sword_time: float = float(state.get("sword_time", 0.0))
	var shield_name: String = String(state.get("shield_animation", "none"))
	var shield_time: float = float(state.get("shield_time", 0.0))

	# The local character restarts its generic body "attack" clip at each combo
	# step; include combo step in the key so remote playback also restarts.
	var body_key := body_name
	if body_name == "attack":
		body_key += ":%d" % combo_step

	_apply_body_animation(body_name, body_time, body_key)
	_apply_item_animation(sword_visual, sword_animation_player, sword_name, sword_time, "sword", combo_step)
	_apply_item_animation(shield_visual, shield_animation_player, shield_name, shield_time, "shield", combo_step)


func _process(delta: float) -> void:
	_update_interpolated_position()

	var facing_weight: float = 1.0 - exp(-maxf(facing_rotation_speed, 0.0) * delta)
	var target_angle: float = target_facing.angle() + PI / 2.0
	left_hand_pivot.rotation = lerp_angle(left_hand_pivot.rotation, target_angle, facing_weight)
	right_hand_pivot.rotation = lerp_angle(right_hand_pivot.rotation, target_angle, facing_weight)

	if is_blocking and is_instance_valid(shield_visual):
		var shield_pivot := shield_visual.get_node_or_null("ShieldPivot") as Node2D
		if is_instance_valid(shield_pivot):
			var shield_angle: float = target_facing.angle() + deg_to_rad(shield_forward_offset_degrees)
			shield_pivot.global_rotation = lerp_angle(
				shield_pivot.global_rotation,
				shield_angle,
				facing_weight
			)


func _now_seconds() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0


func _record_position_snapshot(value: Vector2, source_time: float = -1.0) -> void:
	# source_time is estimated from the server's fixed snapshot tick. Do not
	# timestamp every packet at local receipt time: packets can arrive in bursts.
	var snapshot_time: float = source_time if source_time >= 0.0 else _now_seconds()

	if _position_snapshots.size() > 0:
		var last_time: float = float(_position_snapshots[-1]["time"])
		# Keep time strictly increasing even if two UDP packets arrive in the
		# same microsecond on an unusually fast local system.
		if snapshot_time <= last_time:
			snapshot_time = last_time + 0.000001

	target_position = value
	has_target = true

	if not _position_initialized:
		global_position = value
		_position_initialized = true

	_position_snapshots.append({
		"time": snapshot_time,
		"position": value
	})

	# 32 samples cover about 1.6 seconds at 20 Hz, enough for a short jitter
	# burst without allowing the buffer to grow indefinitely.
	while _position_snapshots.size() > 32:
		_position_snapshots.pop_front()


func _update_interpolated_position() -> void:
	if _position_snapshots.is_empty():
		return

	var render_time: float = _now_seconds() - maxf(interpolation_delay, 0.0)

	# Discard samples that are well behind the render time, while preserving a
	# pair for interpolation/extrapolation.
	while _position_snapshots.size() > 2 and float(_position_snapshots[1]["time"]) < render_time:
		_position_snapshots.pop_front()

	if _position_snapshots.size() == 1:
		global_position = _position_snapshots[0]["position"]
		return

	var first: Dictionary = _position_snapshots[0]
	var last: Dictionary = _position_snapshots[-1]
	var first_time: float = float(first["time"])
	var last_time: float = float(last["time"])
	var first_position: Vector2 = first["position"]
	var last_position: Vector2 = last["position"]

	if render_time <= first_time:
		global_position = first_position
		return

	# If a packet is late, extrapolate briefly from the last two samples rather
	# than freezing immediately. The cap prevents large teleports after a stall.
	if render_time >= last_time:
		var previous: Dictionary = _position_snapshots[-2]
		var previous_time: float = float(previous["time"])
		var previous_position: Vector2 = previous["position"]
		var sample_delta: float = last_time - previous_time
		var extra_time: float = clampf(
			render_time - last_time,
			0.0,
			maxf(max_extrapolation_time, 0.0)
		)

		if sample_delta > 0.001 and extra_time > 0.0:
			var velocity: Vector2 = (last_position - previous_position) / sample_delta
			velocity = velocity.limit_length(max_extrapolation_speed)
			global_position = last_position + velocity * extra_time
		else:
			global_position = last_position
		return

	# Normal interpolation between the two snapshots surrounding render_time.
	for index in range(_position_snapshots.size() - 1):
		var a: Dictionary = _position_snapshots[index]
		var b: Dictionary = _position_snapshots[index + 1]
		var a_time: float = float(a["time"])
		var b_time: float = float(b["time"])

		if render_time >= a_time and render_time <= b_time:
			var span: float = maxf(b_time - a_time, 0.0001)
			var weight: float = clampf((render_time - a_time) / span, 0.0, 1.0)
			var a_position: Vector2 = a["position"]
			var b_position: Vector2 = b["position"]
			global_position = a_position.lerp(b_position, weight)
			return

	global_position = last_position


func _setup_damage_flash_material() -> void:
	if not is_instance_valid(body_sprite):
		return

	var shader_material := body_sprite.material as ShaderMaterial
	if shader_material == null:
		return

	# Every remote player's shader must be unique, otherwise one player's hit
	# flash may affect all characters that share the same material resource.
	body_sprite.material = shader_material.duplicate()
	(body_sprite.material as ShaderMaterial).set_shader_parameter("damage_flash", 0.0)


func _play_damage_flash() -> void:
	var shader_material := body_sprite.material as ShaderMaterial
	if shader_material == null:
		return

	if damage_tween != null and damage_tween.is_valid():
		damage_tween.kill()

	damage_tween = create_tween()
	var single_duration: float = damage_flash_duration / float(maxi(damage_flash_count * 2, 1))
	shader_material.set_shader_parameter("damage_flash", 0.0)

	for _index in range(damage_flash_count):
		damage_tween.tween_method(_set_damage_flash, 0.0, 1.0, single_duration)
		damage_tween.tween_method(_set_damage_flash, 1.0, 0.0, single_duration)

	damage_tween.tween_callback(func() -> void: _set_damage_flash(0.0))


func _set_damage_flash(value: float) -> void:
	var shader_material := body_sprite.material as ShaderMaterial
	if shader_material != null:
		shader_material.set_shader_parameter("damage_flash", value)


func _add_visual_equipment() -> void:
	if not is_instance_valid(sword_visual):
		sword_visual = _instantiate_visual_item(SWORD_SCENE, right_socket, "RemoteSword")
	if is_instance_valid(sword_visual):
		sword_animation_player = sword_visual.get_node_or_null("AnimationPlayer") as AnimationPlayer

	if not is_instance_valid(shield_visual):
		shield_visual = _instantiate_visual_item(SHIELD_SCENE, left_socket, "RemoteShield")
	if is_instance_valid(shield_visual):
		shield_animation_player = shield_visual.get_node_or_null("AnimationPlayer") as AnimationPlayer


func _instantiate_visual_item(scene: PackedScene, socket: Node, item_name: String) -> Node2D:
	if scene == null or socket == null:
		return null
	var item := scene.instantiate() as Node2D
	if not is_instance_valid(item):
		return null
	# Replace Sword.gd/Shield.gd with a non-combat visual adapter before ready.
	item.set_script(REMOTE_EQUIPMENT_SCRIPT)
	item.name = item_name
	socket.add_child(item)
	return item


func _disable_collision_nodes(root: Node) -> void:
	for child in root.get_children():
		if child is CollisionShape2D:
			(child as CollisionShape2D).set_deferred("disabled", true)
		elif child is CollisionPolygon2D:
			(child as CollisionPolygon2D).set_deferred("disabled", true)
		elif child is Area2D:
			(child as Area2D).set_deferred("monitoring", false)
			(child as Area2D).set_deferred("monitorable", false)
		_disable_collision_nodes(child)


func _apply_body_animation(animation_name: String, animation_time: float, state_key: String) -> void:
	var chosen: String = animation_name
	if not body_animation_player.has_animation(chosen):
		if body_animation_player.has_animation("idle"):
			chosen = "idle"
		else:
			return

	if state_key != _last_body_key:
		body_animation_player.speed_scale = action_speed_scale if chosen == "attack" else idle_move_speed_scale
		body_animation_player.play(chosen, 0.02)
		body_animation_player.seek(
			clampf(animation_time, 0.0, body_animation_player.current_animation_length),
			true
		)
		_last_body_key = state_key
		return

	# Keep non-looping body actions aligned without restarting them every packet.
	var clip := body_animation_player.get_animation(chosen)
	if clip != null and clip.loop_mode == Animation.LOOP_NONE:
		var expected: float = clampf(animation_time, 0.0, clip.length)
		if absf(body_animation_player.current_animation_position - expected) > 0.28:
			body_animation_player.seek(expected, true)


func _apply_item_animation(item: Node2D, animator: AnimationPlayer, animation_name: String, animation_time: float, item_kind: String, combo_step: int) -> void:
	if not is_instance_valid(item) or animator == null:
		return

	var state_key: String = animation_name
	if animation_name.begins_with("attack"):
		state_key += ":%d" % combo_step

	var previous_key: String = _last_sword_key if item_kind == "sword" else _last_shield_key
	var state_changed: bool = state_key != previous_key

	var adapter: Node = item
	if not adapter.has_method("apply_network_animation"):
		return

	if animation_name == "none":
		if state_changed:
			adapter.call("apply_network_animation", "none", 0.0, true)
	else:
		adapter.call(
			"apply_network_animation",
			animation_name,
			animation_time,
			state_changed or animator.current_animation != animation_name
		)

	_set_item_key(item_kind, state_key)


func _set_item_key(item_kind: String, key: String) -> void:
	if item_kind == "sword":
		_last_sword_key = key
	else:
		_last_shield_key = key
