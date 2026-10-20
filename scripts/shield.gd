extends Equipment

signal melee_attack_blocked(attacker: Node2D)

@onready var shield_hitbox: Area2D = $ShieldPivot/ShieldHitbox

var blocking_active: bool = false


func _ready() -> void:
	super._ready()

	shield_hitbox.add_to_group("shield_hitboxes")
	shield_hitbox.monitoring = true

	if not shield_hitbox.area_entered.is_connected(
		_on_shield_area_entered
	):
		shield_hitbox.area_entered.connect(
			_on_shield_area_entered
		)


func block() -> void:
	blocking_active = true
	super.block()


func stop_action() -> void:
	blocking_active = false
	super.stop_action()


func is_blocking() -> bool:
	return blocking_active


func try_block_melee_attack(attacker: Node2D) -> bool:
	if not blocking_active or not is_instance_valid(attacker):
		return false

	# Only block attacks from the shield's forward-facing half.
	# Assumes the shield's local +X direction points outward.
	var to_attacker := attacker.global_position - global_position

	if to_attacker.length_squared() < 0.001:
		return false

	var shield_forward := Vector2.RIGHT.rotated(global_rotation)

	if shield_forward.dot(to_attacker.normalized()) < 0.0:
		return false

	melee_attack_blocked.emit(attacker)
	_play_block_impact()
	return true


func _on_shield_area_entered(area: Area2D) -> void:
	if not blocking_active:
		return

	if not area.is_in_group("enemy_projectiles"):
		return

	if area.has_method("block_by_shield"):
		area.block_by_shield()
	else:
		area.queue_free()

	_play_block_impact()


func _play_block_impact() -> void:
	AudioManager.play_shield_impact()
