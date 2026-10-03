class_name WeaponPickup
extends Area3D
## A weapon lying in the world, waiting to be collected with the use key.
##
## Carries a [WeaponData]; the weapon manager swaps it into the matching slot
## when the player presses use nearby. The popup prompt on the HUD reads
## [member WeaponData.display_name] from here.

## The weapon this pickup grants. Set per instance in the scene or in code.
@export var weapon_data: WeaponData
## Degrees per second the pickup spins, so it is easy to spot on the ground.
@export_range(0.0, 360.0, 1.0) var spin_speed: float = 45.0
## Metres the pickup rises and falls while idle.
@export_range(0.0, 0.5, 0.005) var hover_amplitude: float = 0.05
## Hover cycles per second.
@export_range(0.0, 5.0, 0.05) var hover_speed: float = 0.8

var _start_y: float = 0.0
var _phase: float = 0.0


func _ready() -> void:
	# Configured here rather than in the scene so every pickup is detectable by
	# the player's interaction area no matter how the scene was built.
	collision_layer = 1
	collision_mask = 0
	monitoring = false
	monitorable = true
	_start_y = position.y
	if weapon_data == null:
		push_warning("WeaponPickup '%s' has no WeaponData assigned." % name)


func _process(delta: float) -> void:
	if spin_speed > 0.0:
		rotate_y(deg_to_rad(spin_speed) * delta)
	if hover_amplitude > 0.0:
		_phase = fmod(_phase + hover_speed * TAU * delta, TAU)
		position.y = _start_y + sin(_phase) * hover_amplitude


## The name to show in the pickup prompt.
func prompt_text() -> String:
	if weapon_data == null:
		return "Weapon"
	return "Pick up %s" % weapon_data.display_name


## Removes the pickup from the world once it has been collected.
func consume() -> void:
	queue_free()