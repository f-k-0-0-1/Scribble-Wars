
extends Equipment

# ==================================================
# DAMAGE
# ==================================================

@export_group("Combo Damage")
@export var damage: int = 20
@export var attack_2_damage: int = 26
@export var attack_3_damage: int = 35

@onready var hitbox: Area2D = $GripPivot/Hitbox

var hit_targets: Array[Node2D] = []
var current_combo_step: int = 1
var _base_damage: int = 20


# ==================================================
# INITIALIZATION
# ==================================================

func _ready() -> void:
	super._ready()

	_base_damage = damage
	current_combo_step = 1

	hitbox.monitoring = false

	if not hitbox.body_entered.is_connected(
		_on_hitbox_body_entered
	):
		hitbox.body_entered.connect(
			_on_hitbox_body_entered
		)


# ==================================================
# COMBO DAMAGE
# ==================================================

func set_combo_step(step: int) -> void:
	current_combo_step = clampi(step, 1, 3)

	match current_combo_step:
		1:
			damage = _base_damage

		2:
			damage = attack_2_damage

		3:
			damage = attack_3_damage


# ==================================================
# DAMAGE WINDOW
# ==================================================

func begin_damage() -> void:
	# Allow each enemy to be hit once per individual slash.
	hit_targets.clear()

	# Defer monitoring changes to avoid physics-query conflicts.
	hitbox.set_deferred("monitoring", true)


func end_damage() -> void:
	hitbox.set_deferred("monitoring", false)


# ==================================================
# HIT DETECTION
# ==================================================

func _on_hitbox_body_entered(body: Node2D) -> void:
	if not is_instance_valid(body):
		return

	if not body.is_in_group("enemy"):
		return

	if hit_targets.has(body):
		return

	if not body.has_method("take_damage"):
		return

	# Record the target before dealing damage to prevent duplicate hits.
	hit_targets.append(body)

	body.call("take_damage", damage)


# ==================================================
# SLASH SOUND
# ==================================================

func play_slash_sound() -> void:
	# Preserve compatibility with existing AnimationPlayer method tracks.
	if AudioManager.has_method("play_sword_slash"):
		AudioManager.play_sword_slash()


# ==================================================
# ACTION CLEANUP
# ==================================================

func stop_action() -> void:
	end_damage()
	super.stop_action()
