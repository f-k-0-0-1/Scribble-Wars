extends Node

signal connection_established(player_id: int)
signal connection_failed(reason: String)
signal server_message(message: String)

const GAMEPLAY_SCENE_PATH := "res://scenes/dungeon_01.tscn"
const MAIN_MENU_SCENE_PATH := "res://scenes/main_menu.tscn"

const REMOTE_PLAYER_SCENE: PackedScene = preload(
	"res://scenes/remote_player.tscn"
)

const HEARTBEAT_INTERVAL: float = 5.0
const POSITION_SEND_INTERVAL: float = 0.10
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
var _latest_remote_positions: Dictionary = {}


# =========================================================
# CONNECTION
# =========================================================

func connect_to_server(host: String, port: int) -> Error:
	disconnect_from_server()

	udp_peer = PacketPeerUDP.new()

	var error: Error = udp_peer.connect_to_host(host, port)

	if error != OK:
		udp_peer.close()
		udp_peer = null

		connection_failed.emit(
			"Could not open UDP endpoint. Error: %d" % error
		)
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

	_latest_remote_positions.clear()

	_send_packet("JOIN")

	print("NetworkClient: connecting to %s:%d" % [host, port])
	return OK


func disconnect_from_server() -> void:
	# Send LEAVE before closing the socket.
	if udp_peer != null:
		if connected_to_server or connection_in_progress:
			var send_error: Error = udp_peer.put_packet(
				"LEAVE".to_utf8_buffer()
			)

			if send_error != OK:
				push_warning(
					"Could not send LEAVE packet. Error: %d"
					% send_error
				)

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

	_clear_remote_players()

	print("NetworkClient: disconnected")


func is_connected_to_server() -> bool:
	return connected_to_server and udp_peer != null


# =========================================================
# PROCESS
# =========================================================

func _process(delta: float) -> void:
	if udp_peer == null:
		return

	# Retry JOIN while waiting for registration.
	if connection_in_progress:
		_connect_elapsed += delta
		_join_retry_elapsed += delta

		if _connect_elapsed >= CONNECT_TIMEOUT:
			_fail_connection(
				"No response from server. Check the endpoint and Playit agent."
			)
			return

		if _join_retry_elapsed >= JOIN_RETRY_INTERVAL:
			_join_retry_elapsed = 0.0
			_send_packet("JOIN")

	# Receive incoming server packets.
	while (
		udp_peer != null
		and udp_peer.get_available_packet_count() > 0
	):
		var packet: PackedByteArray = udp_peer.get_packet()
		var message: String = packet.get_string_from_utf8().strip_edges()

		_handle_server_message(message)

		if udp_peer == null:
			return

	# Send heartbeats and player positions.
	if connected_to_server:
		_heartbeat_elapsed += delta

		if _heartbeat_elapsed >= HEARTBEAT_INTERVAL:
			_heartbeat_elapsed = 0.0
			_send_packet("PING")

		_position_elapsed += delta

		if _position_elapsed >= POSITION_SEND_INTERVAL:
			_position_elapsed = 0.0
			_send_local_position_if_in_game()
			_sync_remote_players()

	# Detect death before the player node is freed.
	if connected_to_server:
		var current_scene: Node = get_tree().current_scene

		if current_scene != null:
			if current_scene.scene_file_path == MAIN_MENU_SCENE_PATH:
				disconnect_from_server()
				return

			if current_scene.scene_file_path == GAMEPLAY_SCENE_PATH:
				var local_player := (
					get_tree().get_first_node_in_group("player")
					as Node2D
				)

				if is_instance_valid(local_player):
					if local_player.get("is_dead") == true:
						disconnect_from_server()
						return


# =========================================================
# APPLICATION EXIT
# =========================================================

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Send LEAVE before the application closes.
		disconnect_from_server()
		get_tree().quit()


# =========================================================
# SERVER MESSAGES
# =========================================================

func _handle_server_message(message: String) -> void:
	if message.is_empty():
		return

	server_message.emit(message)

	if message.begins_with("WELCOME "):
		var id_text: String = (
			message.trim_prefix("WELCOME ").strip_edges()
		)

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
		# The server may have restarted or removed this client.
		connected_to_server = false
		connection_in_progress = true
		_connect_elapsed = 0.0
		_join_retry_elapsed = 0.0
		_send_packet("JOIN")

	elif message == "SERVER FULL":
		_fail_connection("The server is full. Try again later.")

	elif message == "PONG":
		pass

	elif message == "INVALID POSITION":
		push_warning("The server rejected the player position update.")


# =========================================================
# PARSE SERVER STATE
# =========================================================

func _parse_state(payload: String) -> void:
	var updated_positions: Dictionary = {}

	for entry in payload.split(";", false):
		var fields: PackedStringArray = (
			entry.strip_edges().split(" ", false)
		)

		if fields.size() < 3:
			continue

		if not fields[0].is_valid_int():
			continue

		if (
			not fields[1].is_valid_float()
			or not fields[2].is_valid_float()
		):
			continue

		var player_id: int = int(fields[0])

		# Exclude this client's own avatar.
		if player_id == local_player_id:
			continue

		var position := Vector2(
			float(fields[1]),
			float(fields[2])
		)

		updated_positions[player_id] = position

	# Players missing from the latest state are removed locally.
	_latest_remote_positions = updated_positions
	_sync_remote_players()


# =========================================================
# LOCAL POSITION
# =========================================================

func _send_local_position_if_in_game() -> void:
	var scene: Node = get_tree().current_scene

	if scene == null:
		return

	if scene.scene_file_path != GAMEPLAY_SCENE_PATH:
		return

	var local_player := (
		get_tree().get_first_node_in_group("player") as Node2D
	)

	if not is_instance_valid(local_player):
		return

	var position: Vector2 = local_player.global_position

	_send_packet("POS %.2f %.2f" % [position.x, position.y])


# =========================================================
# REMOTE PLAYERS
# =========================================================

func _sync_remote_players() -> void:
	var scene: Node = get_tree().current_scene

	if scene == null:
		return

	if scene.scene_file_path != GAMEPLAY_SCENE_PATH:
		return

	var local_player := (
		get_tree().get_first_node_in_group("player") as Node2D
	)

	if not is_instance_valid(local_player):
		return

	var remote_container := (
		scene.get_node_or_null("RemotePlayers") as Node2D
	)

	if not is_instance_valid(remote_container):
		remote_container = Node2D.new()
		remote_container.name = "RemotePlayers"
		scene.add_child(remote_container)

	# Remove players missing from the server state.
	for key in _remote_players.keys():
		var player_id: int = int(key)

		if _latest_remote_positions.has(player_id):
			continue

		var old_value: Variant = _remote_players[player_id]

		if is_instance_valid(old_value) and old_value is Node2D:
			var old_node: Node2D = old_value

			if not old_node.is_queued_for_deletion():
				old_node.queue_free()

		_remote_players.erase(player_id)

	# Create or update current remote avatars.
	for key in _latest_remote_positions.keys():
		var player_id: int = int(key)
		var target: Vector2 = _latest_remote_positions[player_id]

		var remote_value: Variant = _remote_players.get(player_id, null)
		var remote_node: Node2D = null

		if is_instance_valid(remote_value) and remote_value is Node2D:
			var candidate: Node2D = remote_value

			if not candidate.is_queued_for_deletion():
				remote_node = candidate

		# Discard stale references left by scene changes.
		if remote_node == null:
			_remote_players.erase(player_id)

			remote_node = (
				REMOTE_PLAYER_SCENE.instantiate() as Node2D
			)

			if not is_instance_valid(remote_node):
				push_error("Could not instantiate RemotePlayer scene.")
				continue

			remote_node.name = "RemotePlayer_%d" % player_id
			remote_container.add_child(remote_node)
			remote_node.global_position = target

			if remote_node.has_method("configure"):
				remote_node.call("configure", player_id)

			_remote_players[player_id] = remote_node

		if (
			is_instance_valid(remote_node)
			and not remote_node.is_queued_for_deletion()
			and remote_node.has_method("set_target_position")
		):
			remote_node.call("set_target_position", target)


# =========================================================
# SEND PACKETS
# =========================================================

func _send_packet(message: String) -> void:
	if udp_peer == null:
		return

	var error: Error = udp_peer.put_packet(
		message.to_utf8_buffer()
	)

	if error != OK:
		push_warning("UDP send failed. Error: %d" % error)


# =========================================================
# CONNECTION FAILURE
# =========================================================

func _fail_connection(reason: String) -> void:
	print("NetworkClient: connection failed: ", reason)

	disconnect_from_server()
	connection_failed.emit(reason)


# =========================================================
# SAFE CLEANUP
# =========================================================

func _clear_remote_players() -> void:
	# Clear dictionaries before freeing nodes. The scene may already
	# have destroyed some of these objects.
	var nodes_to_clear: Array = _remote_players.values()

	_remote_players.clear()
	_latest_remote_positions.clear()

	for value in nodes_to_clear:
		if not is_instance_valid(value):
			continue

		if not value is Node:
			continue

		var remote_node: Node = value

		if not remote_node.is_queued_for_deletion():
			remote_node.queue_free()
