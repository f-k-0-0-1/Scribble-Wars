extends Node

## Custom UDP replication client for the Scribble Wars C++ server.
## Extended client packet:
## POS x y facing_x facing_y body_anim body_time combo_step
##     sword_anim sword_time shield_anim shield_time blocking dead
## Extended STATE entry:
## id x y facing_x facing_y body_anim body_time combo_step
##    sword_anim sword_time shield_anim shield_time blocking dead;

signal connection_established(player_id: int)
signal connection_failed(reason: String)
signal server_message(message: String)

const GAMEPLAY_SCENE_PATH := "res://scenes/dungeon_01.tscn"
const MAIN_MENU_SCENE_PATH := "res://scenes/main_menu.tscn"
const REMOTE_PLAYER_SCENE: PackedScene = preload("res://scenes/remote_player.tscn")

const HEARTBEAT_INTERVAL: float = 5.0
const POSITION_SEND_INTERVAL: float = 0.05
const CONNECT_TIMEOUT: float = 15.0
const JOIN_RETRY_INTERVAL: float = 2.0

var udp_peer: PacketPeerUDP = null
var connected_to_server: bool = false
var connection_in_progress: bool = false
var local_player_id: int = -1
var server_host: String = ""
var server_port: int = 0

var _heartbeat_elapsed: float = 0.0
var _position_elapsed: float = 0.0
var _connect_elapsed: float = 0.0
var _join_retry_elapsed: float = 0.0
var _remote_players: Dictionary = {}
var _latest_remote_states: Dictionary = {}
var _leaving: bool = false

# Event counter replicated with each player snapshot. It changes when local
# health decreases, allowing other clients to trigger the same hit flash.
var _hit_flash_sequence: int = 0
var _tracked_local_player: Node = null
var _last_local_health: int = -1
var _last_server_state_sequence: int = -1


func connect_to_server(host: String, port: int) -> Error:
	disconnect_from_server()
	_leaving = false

	udp_peer = PacketPeerUDP.new()
	var error: Error = udp_peer.connect_to_host(host, port)
	if error != OK:
		udp_peer.close()
		udp_peer = null
		connection_failed.emit("Could not open UDP endpoint (error %d)." % error)
		return error

	server_host = host
	server_port = port
	connected_to_server = false
	connection_in_progress = true
	local_player_id = -1
	_heartbeat_elapsed = 0.0
	_position_elapsed = 0.0
	_connect_elapsed = 0.0
	_join_retry_elapsed = 0.0
	_latest_remote_states.clear()
	_hit_flash_sequence = 0
	_last_server_state_sequence = -1
	_untrack_local_player()

	_send_packet("JOIN")
	print("NetworkClient: connecting to %s:%d" % [host, port])
	return OK


func disconnect_from_server() -> void:
	if _leaving:
		return
	_leaving = true

	# Explicit LEAVE allows the C++ server to remove this player immediately.
	if udp_peer != null:
		if connected_to_server or connection_in_progress:
			udp_peer.put_packet("LEAVE".to_utf8_buffer())
		udp_peer.close()
		udp_peer = null

	connected_to_server = false
	connection_in_progress = false
	local_player_id = -1
	server_host = ""
	server_port = 0
	_heartbeat_elapsed = 0.0
	_position_elapsed = 0.0
	_connect_elapsed = 0.0
	_join_retry_elapsed = 0.0
	_untrack_local_player()
	_clear_remote_players()
	_leaving = false
	print("NetworkClient: disconnected")


func is_connected_to_server() -> bool:
	return connected_to_server and udp_peer != null


func _process(delta: float) -> void:
	if udp_peer == null:
		return

	if connection_in_progress:
		_connect_elapsed += delta
		_join_retry_elapsed += delta
		if _connect_elapsed >= CONNECT_TIMEOUT:
			_fail_connection("No response from server. Check the public endpoint and Playit agent.")
			return
		if _join_retry_elapsed >= JOIN_RETRY_INTERVAL:
			_join_retry_elapsed = 0.0
			_send_packet("JOIN")

	while udp_peer != null and udp_peer.get_available_packet_count() > 0:
		var packet: PackedByteArray = udp_peer.get_packet()
		var message: String = packet.get_string_from_utf8().strip_edges()
		_handle_server_message(message)
		if udp_peer == null:
			return

	if connected_to_server:
		_heartbeat_elapsed += delta
		if _heartbeat_elapsed >= HEARTBEAT_INTERVAL:
			_heartbeat_elapsed = 0.0
			_send_packet("PING")

		_position_elapsed += delta
		if _position_elapsed >= POSITION_SEND_INTERVAL:
			_position_elapsed = 0.0
			_send_local_state_if_in_game()
			_sync_remote_players()

	# The existing single-player death flow returns to the menu. Online mode
	# also sends LEAVE as soon as the Player marks itself dead.
	if connected_to_server:
		var scene: Node = get_tree().current_scene
		if scene != null and scene.scene_file_path == MAIN_MENU_SCENE_PATH:
			disconnect_from_server()
			return
		if scene != null and scene.scene_file_path == GAMEPLAY_SCENE_PATH:
			var local_player := get_tree().get_first_node_in_group("player") as Node2D
			if is_instance_valid(local_player) and local_player.get("is_dead") == true:
				disconnect_from_server()
				return


func _handle_server_message(message: String) -> void:
	if message.is_empty():
		return
	server_message.emit(message)

	if message.begins_with("WELCOME "):
		var id_text: String = message.trim_prefix("WELCOME ").strip_edges()
		if not id_text.is_valid_int():
			return
		local_player_id = int(id_text)
		var was_connected: bool = connected_to_server
		connected_to_server = true
		connection_in_progress = false
		_connect_elapsed = 0.0
		_join_retry_elapsed = 0.0
		print("NetworkClient: connected as player %d" % local_player_id)
		if not was_connected:
			connection_established.emit(local_player_id)

	elif message.begins_with("STATE "):
		if connected_to_server:
			_parse_state(message.trim_prefix("STATE "))

	elif message == "SEND JOIN FIRST":
		connected_to_server = false
		connection_in_progress = true
		_connect_elapsed = 0.0
		_join_retry_elapsed = 0.0
		_last_server_state_sequence = -1
		_send_packet("JOIN")

	elif message == "SERVER FULL":
		_fail_connection("The server is full. Try again later.")

	elif message == "PONG":
		pass

	elif message == "INVALID POSITION":
		push_warning("The server rejected a player-state update.")


func _parse_state(payload: String) -> void:
	# The server sequence lets us discard out-of-order UDP STATE packets.
	# This avoids snapping backward if an older datagram arrives late.
	var header_end: int = payload.find(" ")
	if header_end <= 0:
		return

	var sequence_text: String = payload.substr(0, header_end)
	if not sequence_text.is_valid_int():
		return

	var state_sequence: int = int(sequence_text)
	if state_sequence <= _last_server_state_sequence:
		return

	_last_server_state_sequence = state_sequence
	var entries_payload: String = payload.substr(header_end + 1)
	var updated: Dictionary = {}

	for entry in entries_payload.split(";", false):
		var fields: PackedStringArray = entry.strip_edges().split(" ", false)
		if fields.size() < 3 or not fields[0].is_valid_int():
			continue
		if not fields[1].is_valid_float() or not fields[2].is_valid_float():
			continue

		var player_id: int = int(fields[0])
		if player_id == local_player_id:
			continue

		var state: Dictionary = {
			"position": Vector2(float(fields[1]), float(fields[2])),
			"facing": Vector2.DOWN,
			"body_animation": "idle",
			"body_time": 0.0,
			"combo_step": 0,
			"sword_animation": "none",
			"sword_time": 0.0,
			"shield_animation": "none",
			"shield_time": 0.0,
			"blocking": false,
			"dead": false,
			"hit_flash_seq": 0
		}

		# Full state: id x y fx fy body_anim body_time combo sword_anim sword_time
		#            shield_anim shield_time blocking dead
		if fields.size() >= 14:
			if fields[3].is_valid_float() and fields[4].is_valid_float():
				var facing := Vector2(float(fields[3]), float(fields[4]))
				if facing.length_squared() > 0.001:
					state["facing"] = facing.normalized()
			if fields[5] in ["idle", "move", "attack", "block", "hurt", "death"]:
				state["body_animation"] = fields[5]
			if fields[6].is_valid_float():
				state["body_time"] = maxf(float(fields[6]), 0.0)
			if fields[7].is_valid_int():
				state["combo_step"] = clampi(int(fields[7]), 0, 3)
			if fields[8] in ["none", "attack", "attack_2", "attack_3", "block"]:
				state["sword_animation"] = fields[8]
			if fields[9].is_valid_float():
				state["sword_time"] = maxf(float(fields[9]), 0.0)
			if fields[10] in ["none", "attack", "attack_2", "attack_3", "block"]:
				state["shield_animation"] = fields[10]
			if fields[11].is_valid_float():
				state["shield_time"] = maxf(float(fields[11]), 0.0)
			if fields[12].is_valid_int():
				state["blocking"] = int(fields[12]) != 0
			if fields[13].is_valid_int():
				state["dead"] = int(fields[13]) != 0
			if fields.size() >= 15 and fields[14].is_valid_int():
				state["hit_flash_seq"] = maxi(int(fields[14]), 0)
		else:
			# Backward compatibility with the earlier Step 3 packet.
			if fields.size() >= 5 and fields[3].is_valid_float() and fields[4].is_valid_float():
				var facing_old := Vector2(float(fields[3]), float(fields[4]))
				if facing_old.length_squared() > 0.001:
					state["facing"] = facing_old.normalized()
			if fields.size() >= 6 and fields[5] in ["idle", "move", "attack", "block", "hurt", "death"]:
				state["body_animation"] = fields[5]
				state["blocking"] = fields[5] == "block"

		updated[player_id] = state

	_latest_remote_states = updated
	_sync_remote_players()


func _send_local_state_if_in_game() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null or scene.scene_file_path != GAMEPLAY_SCENE_PATH:
		return

	var local_player := get_tree().get_first_node_in_group("player") as Node2D
	if not is_instance_valid(local_player):
		return

	_track_local_player(local_player)

	var pos: Vector2 = local_player.global_position
	var facing := Vector2.DOWN
	var facing_value: Variant = local_player.get("facing_direction")
	if facing_value is Vector2 and facing_value.length_squared() > 0.001:
		facing = Vector2(facing_value).normalized()
	elif local_player is CharacterBody2D:
		var velocity: Vector2 = (local_player as CharacterBody2D).velocity
		if velocity.length_squared() > 0.001:
			facing = velocity.normalized()

	var body_animator := local_player.get_node_or_null("BodyPivot/AnimationPlayer") as AnimationPlayer
	var body_state: Dictionary = _read_animation_state(
		body_animator,
		["idle", "move", "attack", "block", "hurt", "death"],
		"idle"
	)

	if body_state["animation"] == "idle" or body_state["animation"] == "move":
		if local_player is CharacterBody2D:
			var body: CharacterBody2D = local_player as CharacterBody2D
			var knockback: Variant = local_player.get("knockback_timer")
			if body.velocity.length_squared() > 25.0 or (knockback != null and float(knockback) > 0.0):
				body_state["animation"] = "move"
			else:
				body_state["animation"] = "idle"

	var combo_value: Variant = local_player.get("combo_step")
	var combo_step: int = clampi(int(combo_value) if combo_value != null else 0, 0, 3)
	var blocking: bool = local_player.get("is_blocking") == true
	var dead: bool = local_player.get("is_dead") == true

	var right_item: Variant = local_player.get("right_hand_item")
	var left_item: Variant = local_player.get("left_hand_item")
	var sword_state: Dictionary = _read_item_animation_state(right_item)
	var shield_state: Dictionary = _read_item_animation_state(left_item)

	var packet := "POS %.2f %.2f %.3f %.3f %s %.3f %d %s %.3f %s %.3f %d %d %d" % [
		pos.x, pos.y, facing.x, facing.y,
		body_state["animation"], float(body_state["time"]), combo_step,
		sword_state["animation"], float(sword_state["time"]),
		shield_state["animation"], float(shield_state["time"]),
		1 if blocking else 0, 1 if dead else 0, _hit_flash_sequence
	]
	_send_packet(packet)


func _track_local_player(player: Node) -> void:
	if is_instance_valid(_tracked_local_player) and _tracked_local_player == player:
		return

	_untrack_local_player()
	_tracked_local_player = player

	var health_value: Variant = player.get("current_health")
	_last_local_health = int(health_value) if health_value != null else -1

	if player.has_signal("health_changed"):
		var callback := Callable(self, "_on_local_health_changed")
		if not player.is_connected("health_changed", callback):
			player.connect("health_changed", callback)


func _untrack_local_player() -> void:
	if is_instance_valid(_tracked_local_player):
		var callback := Callable(self, "_on_local_health_changed")
		if _tracked_local_player.has_signal("health_changed") and _tracked_local_player.is_connected("health_changed", callback):
			_tracked_local_player.disconnect("health_changed", callback)

	_tracked_local_player = null
	_last_local_health = -1


func _on_local_health_changed(current_health: int, _max_health: int) -> void:
	if _last_local_health >= 0 and current_health < _last_local_health:
		_hit_flash_sequence += 1
		print("NetworkClient: replicated hit flash event %d" % _hit_flash_sequence)

	_last_local_health = current_health


func _read_animation_state(animator: AnimationPlayer, allowed: Array, fallback: String) -> Dictionary:
	if not is_instance_valid(animator) or not animator.is_playing():
		return {"animation": fallback, "time": 0.0}
	var animation_name: String = String(animator.current_animation)
	if not allowed.has(animation_name):
		return {"animation": fallback, "time": 0.0}
	return {"animation": animation_name, "time": maxf(animator.current_animation_position, 0.0)}


func _read_item_animation_state(item_value: Variant) -> Dictionary:
	if not is_instance_valid(item_value) or not item_value is Node:
		return {"animation": "none", "time": 0.0}
	var item: Node = item_value
	var animator := item.get_node_or_null("AnimationPlayer") as AnimationPlayer
	return _read_animation_state(animator, ["attack", "attack_2", "attack_3", "block"], "none")


func _sync_remote_players() -> void:
	var scene: Node = get_tree().current_scene
	if scene == null or scene.scene_file_path != GAMEPLAY_SCENE_PATH:
		return

	var local_player := get_tree().get_first_node_in_group("player") as Node2D
	if not is_instance_valid(local_player):
		return

	var remote_container := scene.get_node_or_null("RemotePlayers") as Node2D
	if not is_instance_valid(remote_container):
		remote_container = Node2D.new()
		remote_container.name = "RemotePlayers"
		scene.add_child(remote_container)

	for key in _remote_players.keys():
		var player_id: int = int(key)
		if _latest_remote_states.has(player_id):
			continue
		var old_value: Variant = _remote_players[player_id]
		if is_instance_valid(old_value) and old_value is Node:
			var old_node: Node = old_value
			if not old_node.is_queued_for_deletion():
				old_node.queue_free()
		_remote_players.erase(player_id)

	for key in _latest_remote_states.keys():
		var player_id: int = int(key)
		var state: Dictionary = _latest_remote_states[player_id]
		var remote_node: Node2D = null
		var stored: Variant = _remote_players.get(player_id, null)
		if is_instance_valid(stored) and stored is Node2D:
			var candidate: Node2D = stored
			if not candidate.is_queued_for_deletion():
				remote_node = candidate

		if remote_node == null:
			_remote_players.erase(player_id)
			remote_node = REMOTE_PLAYER_SCENE.instantiate() as Node2D
			if not is_instance_valid(remote_node):
				push_error("Could not instantiate remote_player.tscn")
				continue
			remote_node.name = "RemotePlayer_%d" % player_id
			remote_container.add_child(remote_node)
			remote_node.global_position = state["position"]
			if remote_node.has_method("configure"):
				remote_node.call("configure", player_id)
			_remote_players[player_id] = remote_node

		if is_instance_valid(remote_node) and not remote_node.is_queued_for_deletion():
			if remote_node.has_method("set_network_snapshot"):
				remote_node.call("set_network_snapshot", state)


func _send_packet(message: String) -> void:
	if udp_peer == null:
		return
	var error: Error = udp_peer.put_packet(message.to_utf8_buffer())
	if error != OK:
		push_warning("UDP send failed (error %d)." % error)


func _fail_connection(reason: String) -> void:
	print("NetworkClient: connection failed: ", reason)
	disconnect_from_server()
	connection_failed.emit(reason)


func _clear_remote_players() -> void:
	var nodes_to_clear: Array = _remote_players.values()
	_remote_players.clear()
	_latest_remote_states.clear()
	for value in nodes_to_clear:
		if not is_instance_valid(value) or not value is Node:
			continue
		var node: Node = value
		if not node.is_queued_for_deletion():
			node.queue_free()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		disconnect_from_server()
