class_name Damageable
extends Node3D
## Health and armour for anything that can be shot.
##
## Any collider carrying this script (or a [Hitbox] that forwards to one) can
## receive damage from a weapon via [method apply_damage]. Attach it directly to
## a [StaticBody3D], [CharacterBody3D] or [RigidBody3D] - the script only needs a
## [Node3D] ancestor, so it works on any of them.

## Emitted after damage is applied, with the final amount and the hit info.
signal damaged(amount: float, info: Dictionary)
## Emitted once health reaches zero.
signal died(info: Dictionary)
## Emitted whenever health changes, for HUD binding.
signal health_changed(health: float, max_health: float)

## Health at full strength.
@export var max_health: float = 100.0
## Armour reduction, 0.0 for none and 1.0 for full. A weapon's
## [member WeaponData.armor_penetration] scales this down before it is applied.
@export_range(0.0, 1.0, 0.01) var armor: float = 0.0
## When true the node is treated as already dead and ignores further damage.
@export var start_dead: bool = false
## When true, destroys this node shortly after it dies.
@export var queue_free_on_death: bool = false

## Current health. Readable so tests and HUDs can inspect it.
var health: float = 0.0


func _ready() -> void:
	health = 0.0 if start_dead else max_health
	health_changed.emit(health, max_health)


func is_alive() -> bool:
	return health > 0.0


## Applies damage from a weapon hit.
##
## [param amount] is the weapon damage after range falloff and hitbox
## multipliers, but before armour. Armour is resolved here because armour belongs
## to the target while penetration belongs to the weapon, carried in
## [code]info["armor_penetration"][/code].
func apply_damage(amount: float, info: Dictionary = {}) -> void:
	if not is_alive():
		return
	var penetration := clampf(float(info.get("armor_penetration", 0.0)), 0.0, 1.0)
	var effective_armor := armor * (1.0 - penetration)
	var final_damage := maxf(amount * (1.0 - effective_armor), 0.0)
	health = maxf(health - final_damage, 0.0)
	info["damage"] = final_damage
	info["remaining_health"] = health
	damaged.emit(final_damage, info)
	health_changed.emit(health, max_health)
	if not is_alive():
		died.emit(info)
		if queue_free_on_death:
			queue_free()


## Restores health without exceeding [member max_health].
func heal(amount: float) -> void:
	if not is_alive():
		return
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)


## Returns the target to full health, ready for another test run.
func revive() -> void:
	health = max_health
	health_changed.emit(health, max_health)