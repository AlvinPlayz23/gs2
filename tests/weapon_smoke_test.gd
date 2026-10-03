extends SceneTree
## Headless smoke test for the weapon system.
##
## Run it with:
## [codeblock lang=text]
## godot --headless --path <project> --script res://tests/weapon_smoke_test.gd
## [/codeblock]
## Exits with code 0 when every check passes, 1 otherwise.
##
## Each section builds its own throwaway world so ammo, positions and recoil from
## one check can never leak into another. Weapon data is duplicated and given
## deliberately extreme recovery values where a check needs the recoil offset to
## stay put, so the assertions can be exact rather than approximate.

const PLAYER_SCENE := "res://scenes/player.tscn"
const DUMMY_SCENE := "res://scenes/targets/target_dummy.tscn"
const PICKUP_SCENE := "res://scenes/weapons/weapon_pickup.tscn"
const RIFLE_RESOURCE := "res://resources/weapons/rifle_placeholder.tres"
const PISTOL_RESOURCE := "res://resources/weapons/pistol_placeholder.tres"

const ACTIONS := [
	"fire", "reload", "use", "drop", "slot_primary", "slot_secondary",
]

var _failures: int = 0


func _initialize() -> void:
	check_input_map()
	check_resources()
	await check_firing_and_recoil()
	await check_spread()
	await check_hitscan()
	await check_handling()
	await check_slots_and_pickups()
	await check_viewmodel_isolation()
	print("\n=== %s ===" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)


# --- helpers ---------------------------------------------------------------

func check_input_map() -> void:
	for action in ACTIONS:
		_expect(InputMap.has_action(action), "input action '%s' exists" % action)


func check_resources() -> void:
	var rifle: WeaponData = load(RIFLE_RESOURCE)
	var pistol: WeaponData = load(PISTOL_RESOURCE)
	for data in [rifle, pistol]:
		var problems := data.validation_problems()
		_expect(problems.is_empty(), "'%s' config is valid%s" % [
			data.display_name, "" if problems.is_empty() else ": " + ", ".join(problems)
		])
		_expect(data.shot_interval() > 0.0, "'%s' has a positive shot interval" % data.display_name)
		# CS-style falloff: decays from the first metre, never rises.
		var near := data.damage_at_distance(1.0)
		var mid := data.damage_at_distance(30.0)
		var far := data.damage_at_distance(data.max_range)
		print("   %-20s damage %.1f @1m -> %.1f @30m -> %.1f @%.0fm" % [
			data.display_name, near, mid, far, data.max_range
		])
		_expect(near <= data.damage, "'%s' never deals more than base damage" % data.display_name)
		_expect(mid < near and far < mid, "'%s' damage decays with distance" % data.display_name)
		_expect(data.recoil_at_shot(0) == data.recoil_pattern[0], "'%s' pattern starts at index 0" % data.display_name)
		_expect(
			data.recoil_at_shot(data.recoil_pattern.size() + 50) == data.recoil_pattern[data.recoil_pattern.size() - 1],
			"'%s' pattern clamps past the end" % data.display_name
		)
	_expect(rifle.slot == WeaponData.Slot.PRIMARY, "the rifle claims the primary slot")
	_expect(pistol.slot == WeaponData.Slot.SECONDARY, "the pistol claims the secondary slot")
	_expect(rifle.automatic and not pistol.automatic, "the rifle is automatic and the pistol is not")


## Duplicated rifle with recovery effectively disabled, so a burst's recoil can
## be compared against the pattern exactly.
func _make_rifle(recovery_delay := 999.0, reset_time := 999.0) -> WeaponData:
	var data: WeaponData = (load(RIFLE_RESOURCE) as WeaponData).duplicate()
	data.recoil_recovery = 0.0
	data.recoil_recovery_delay = recovery_delay
	data.recoil_reset_time = reset_time
	return data


func _make_pistol() -> WeaponData:
	var data: WeaponData = (load(PISTOL_RESOURCE) as WeaponData).duplicate()
	data.recoil_recovery = 0.0
	data.recoil_recovery_delay = 999.0
	data.recoil_reset_time = 999.0
	return data


func _make_ground(size := 400.0) -> StaticBody3D:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, 2.0, size)
	shape.shape = box
	body.add_child(shape)
	body.position = Vector3(0.0, -1.0, 0.0)
	return body


## Builds an isolated world with a player in it. Returns a dictionary with the
## world, the player and its weapon manager.
func _build_world(primary: WeaponData = null, secondary: WeaponData = null) -> Dictionary:
	var world := Node3D.new()
	root.add_child(world)
	world.add_child(_make_ground())
	var player = load(PLAYER_SCENE).instantiate()
	var manager: WeaponManager = player.get_node("WeaponManager")
	# Assigned before the player enters the tree, so the manager's _ready picks
	# these up as its starting loadout.
	manager.starting_primary = primary if primary != null else _make_rifle()
	manager.starting_secondary = secondary if secondary != null else _make_pistol()
	world.add_child(player)
	player.global_position = Vector3(0.0, 0.1, 0.0)
	return {"world": world, "player": player, "manager": manager}


func _teardown(world: Dictionary) -> void:
	(world["world"] as Node).free()


func _spawn_dummy(world: Dictionary, at: Vector3) -> Node3D:
	var dummy := (load(DUMMY_SCENE) as PackedScene).instantiate() as Node3D
	(world["world"] as Node).add_child(dummy)
	dummy.global_position = at
	return dummy


## Points the player's body yaw and head pitch at a world position. The head is
## what carries pitch and the body carries yaw, matching the controller.
func _aim_at(player: CharacterBody3D, target: Vector3) -> void:
	var head: Node3D = player.get_node("Head")
	var origin := player.global_position + Vector3(0.0, head.position.y, 0.0)
	var delta := target - origin
	player.rotation.y = atan2(-delta.x, -delta.z)
	head.rotation.x = atan2(delta.y, sqrt(delta.x * delta.x + delta.z * delta.z))


func wait_frames(count: int) -> void:
	for i in count:
		await physics_frame


## Waits out the spawn draw so the weapon is ready to fire.
func _settle() -> void:
	await wait_frames(30)


func _expect(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		_failures += 1
		print("FAIL: %s" % description)