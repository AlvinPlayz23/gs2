class_name WeaponState
extends RefCounted
## Mutable per-holder state for one weapon.
##
## Deliberately a [RefCounted] rather than a [Resource]: resources are shared
## between everything that loads them, so storing ammo on [WeaponData] would give
## every holder the same magazine. One [WeaponState] exists per weapon per holder.

## The shared, immutable tuning this state belongs to.
var data: WeaponData
## Rounds currently in the magazine.
var ammo_in_magazine: int = 0
## Rounds carried outside the magazine.
var reserve_ammo: int = 0
## Which entry of the recoil pattern the next shot will use.
var shot_index: int = 0
## Extra spread accumulated by consecutive shots, in degrees.
var bloom: float = 0.0


## Builds fresh state for a weapon, filling the magazine from the reserve.
static func from_data(weapon_data: WeaponData) -> WeaponState:
	var state := WeaponState.new()
	state.data = weapon_data
	state.ammo_in_magazine = weapon_data.magazine_size
	state.reserve_ammo = weapon_data.starting_reserve_ammo
	return state


## Total rounds this holder is carrying, magazine included.
func total_ammo() -> int:
	return ammo_in_magazine + reserve_ammo


func is_magazine_empty() -> bool:
	return ammo_in_magazine <= 0


func is_magazine_full() -> bool:
	return ammo_in_magazine >= data.magazine_size


## True when there is a round ready to fire.
func can_fire() -> bool:
	return not is_magazine_empty()


## True when a reload would actually move rounds.
func can_reload() -> bool:
	return not is_magazine_full() and reserve_ammo > 0


## How many rounds a reload would move at its current ammo counts.
func reload_amount() -> int:
	return mini(data.magazine_size - ammo_in_magazine, reserve_ammo)


## Consumes one round. Returns false when the magazine was already empty.
func consume_round() -> bool:
	if is_magazine_empty():
		return false
	ammo_in_magazine -= 1
	return true


## Advances the recoil pattern index, clamped to the last entry.
func advance_shot_index() -> void:
	var last := maxi(data.recoil_pattern.size() - 1, 0)
	shot_index = mini(shot_index + 1, last)


## Returns the pattern index to the start. Called once the weapon has been idle
## for [member WeaponData.recoil_reset_time].
func reset_shot_index() -> void:
	shot_index = 0


## Moves rounds from the reserve into the magazine, returning how many moved.
func finish_reload() -> int:
	var moved := reload_amount()
	ammo_in_magazine += moved
	reserve_ammo -= moved
	return moved


## Adds bloom for a shot, capped so spread cannot exceed the weapon's maximum.
func add_bloom() -> void:
	bloom = minf(bloom + data.spread_per_shot, data.spread_max)