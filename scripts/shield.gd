
extends Equipment

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


func _on_shield_area_entered(area: Area2D) -> void:
	if not blocking_active:
		return

	if not area.is_in_group("enemy_projectiles"):
		return

	# Destroy the projectile so it cannot damage the player.
	if area.has_method("block_by_shield"):
		area.block_by_shield()
	else:
		area.queue_free()

	# Play the impact sound.
	AudioManager.play_shield_impact()
