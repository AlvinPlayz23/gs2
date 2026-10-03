class_name WeaponData
extends Resource
## Immutable tuning for one weapon.
##
## This is a [Resource], which Godot [b]caches and shares[/b] between every node
## that loads it. That is why nothing here may change at runtime: a magazine that
## lived on this object would be shared between every holder. All mutable values
## live in [WeaponState] instead, one per holder.
##
## Create these as [code].tres[/code] files under [code]res://resources/weapons/[/code].

enum Slot {
	## Held in the primary slot (rifles, SMGs, shotguns).
	PRIMARY,
	## Held in the secondary slot (pistols, knives, equipment).
	SECONDARY,
}

## Distance in metres after which the damage decay exponent advances by one.
## 12.7 m is roughly 500 Source units, the unit the CS damage formula uses.
const RANGE_DECAY_METRES: float = 12.7

@export_group("Identity")
## Name shown in the HUD and in the buy menu.
@export var display_name: String = "Weapon"
## Which slot this weapon occupies when picked up.
@export var slot: Slot = Slot.PRIMARY
## Cost in the buy menu. Purely data for now.
@export var price: int = 0

@export_group("Damage")
## Damage dealt at point blank range, before falloff, hitbox and armour.
@export var damage: float = 25.0
## How much armour this weapon ignores, 0.0 to 1.0. At 0.0 a fully armoured
## target still applies all of its reduction; at 1.0 armour is ignored entirely.
@export_range(0.0, 1.0, 0.01) var armor_penetration: float = 0.5
## CS-style range falloff. Damage decays smoothly from the first metre using
## [code]damage * pow(range_modifier, distance / 12.7)[/code]. Keep this at or
## below 1.0: rifles sit around 0.98, the AWP 0.99, the Deagle 0.81.
@export_range(0.1, 1.0, 0.001) var range_modifier: float = 0.98
## Hard cutoff for the hitscan ray in metres. This does not affect damage, which
## falls off continuously via [member range_modifier].
@export_range(1.0, 1000.0, 1.0) var max_range: float = 100.0
## Number of rays fired per trigger pull. Greater than 1 makes a shotgun.
@export_range(1, 32, 1) var pellets: int = 1

@export_group("Fire")
## True to keep firing while the trigger is held, false for one shot per click.
@export var automatic: bool = true
## Rounds per minute. The fire loop is gated on the derived shot interval.
@export_range(30.0, 1500.0, 1.0) var fire_rate: float = 600.0

@export_group("Ammo")
## Rounds held in one magazine.
@export_range(1, 200, 1) var magazine_size: int = 30
## Rounds carried at spawn, not counting the magazine.
@export_range(0, 999, 1) var starting_reserve_ammo: int = 90

@export_group("Recoil")
## Deterministic spray pattern, indexed by shot number. [code]x[/code] is a
## vertical kick in degrees (positive kicks the view up) and [code]y[/code] is a
## horizontal kick in degrees (positive kicks the view right). Because the kicks
## are fixed rather than random, a player can learn to pull the mouse down
## through the pattern - which is what makes spraying a skill.
@export var recoil_pattern: Array[Vector2] = [
	Vector2(0.85, 0.0), Vector2(0.9, 0.05), Vector2(0.9, -0.05), Vector2(0.95, 0.1),
	Vector2(0.95, -0.1), Vector2(0.9, 0.15), Vector2(0.9, -0.15), Vector2(0.85, 0.22),
]
## Seconds without firing before the pattern index returns to 0.
@export_range(0.05, 2.0, 0.01) var recoil_reset_time: float = 0.35
## Degrees per second the view settles back to the centre.
@export_range(0.0, 60.0, 0.1) var recoil_recovery: float = 6.0
## Seconds after a shot before recovery starts, so the view stays steady while
## the player is still spraying.
@export_range(0.0, 1.0, 0.01) var recoil_recovery_delay: float = 0.15

@export_group("Spread")
## Minimum cone half-angle in degrees while standing still. Kept small so the
## first shot is pinpoint accurate.
@export_range(0.0, 20.0, 0.01) var spread_base: float = 0.05
## Degrees of bloom added per shot.
@export_range(0.0, 5.0, 0.01) var spread_per_shot: float = 0.15
## Cap on total spread in degrees.
@export_range(0.1, 30.0, 0.1) var spread_max: float = 4.0
## Degrees per second the bloom recovers.
@export_range(0.1, 60.0, 0.1) var spread_recovery: float = 8.0
## Spread multiplier at full sprint speed.
@export_range(1.0, 20.0, 0.1) var spread_move_multiplier: float = 3.0
## Spread multiplier while airborne.
@export_range(1.0, 40.0, 0.1) var spread_jump_multiplier: float = 8.0
## Spread multiplier while crouched. Below 1.0 tightens the cone.
@export_range(0.05, 1.0, 0.01) var spread_crouch_multiplier: float = 0.5

@export_group("Handling")
## Seconds to raise the weapon after switching to it.
@export_range(0.0, 2.0, 0.01) var draw_time: float = 0.4
## Seconds to lower the weapon before switching away.
@export_range(0.0, 2.0, 0.01) var holster_time: float = 0.25
## Seconds to complete a reload.
@export_range(0.1, 10.0, 0.05) var reload_time: float = 1.6
## Extra seconds added when reloading with an empty chamber.
@export_range(0.0, 5.0, 0.05) var reload_empty_extra: float = 0.4

@export_group("Assets")
## Scene rendered in the viewmodel. Instanced under the viewmodel's mount point.
@export var viewmodel_scene: PackedScene
## Offset applied to the viewmodel when it is instanced.
@export var viewmodel_transform: Transform3D = Transform3D.IDENTITY
## Played once per shot.
@export var fire_sound: AudioStream
## Played when a reload starts.
@export var reload_sound: AudioStream


## Seconds between shots, derived from [member fire_rate].
func shot_interval() -> float:
	return 60.0 / maxf(fire_rate, 1.0)


## Damage remaining after CS-style exponential falloff.
## Decays continuously from the first metre; [member max_range] is not involved.
func damage_at_distance(distance: float) -> float:
	return damage * pow(range_modifier, maxf(distance, 0.0) / RANGE_DECAY_METRES)


## The recoil kick for a given shot index. Indices past the end of the pattern
## repeat its final entry, so a full magazine keeps kicking at the pattern's last
## value instead of decaying to nothing.
func recoil_at_shot(shot_index: int) -> Vector2:
	if recoil_pattern.is_empty():
		return Vector2.ZERO
	return recoil_pattern[clampi(shot_index, 0, recoil_pattern.size() - 1)]


## Returns a list of configuration problems, empty when the weapon is sane.
## Used by the weapon smoke test and handy as an inspector sanity check.
func validation_problems() -> PackedStringArray:
	var problems := PackedStringArray()
	if fire_rate <= 0.0:
		problems.append("fire_rate must be greater than 0")
	if magazine_size <= 0:
		problems.append("magazine_size must be greater than 0")
	if max_range <= 0.0:
		problems.append("max_range must be greater than 0")
	if damage <= 0.0:
		problems.append("damage must be greater than 0")
	if range_modifier <= 0.0 or range_modifier > 1.0:
		problems.append("range_modifier must be greater than 0 and at most 1")
	if recoil_pattern.is_empty():
		problems.append("recoil_pattern must have at least one entry")
	if spread_max < spread_base:
		problems.append("spread_max must be at least spread_base")
	return problems