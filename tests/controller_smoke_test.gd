extends SceneTree
## Headless smoke test for the first-person controller and the main scene.
##
## It is not referenced by any scene and never runs as part of the game, so it
## is safe to keep (or delete) without affecting the project or its export.
##
## Run it with:
## [codeblock lang=text]
## godot --headless --path <project> --script res://tests/controller_smoke_test.gd
## [/codeblock]
## Exits with code 0 when every check passes, 1 otherwise.
##
## NOTE: the player is intentionally held in an untyped variable so that the
## script methods (is_crouching, ...) can be called on the instanced scene.

const PLAYER_SCENE := "res://scenes/player.tscn"
const MAIN_SCENE := "res://scenes/main.tscn"
const ACTIONS := ["move_forward", "move_back", "move_left", "move_right", "jump", "sprint", "crouch"]

var _failures: int = 0


func _initialize() -> void:
	check_project_settings()
	check_main_scene()
	await check_controller()
	print("\n=== %s ===" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)


func check_project_settings() -> void:
	_expect(ProjectSettings.get_setting("application/run/main_scene") == MAIN_SCENE, "main scene is set to %s" % MAIN_SCENE)
	for action in ACTIONS:
		var exists := InputMap.has_action(action)
		_expect(exists, "input action '%s' exists" % action)
		if exists:
			var keys := PackedStringArray()
			for event in InputMap.action_get_events(action):
				if event is InputEventKey:
					keys.append(OS.get_keycode_string(event.physical_keycode))
			print("   %-13s -> %s" % [action, ", ".join(keys)])
	# ui_cancel is a built-in action, used to free the mouse cursor.
	_expect(InputMap.has_action("ui_cancel"), "built-in 'ui_cancel' action is available")


func check_main_scene() -> void:
	var packed := load(MAIN_SCENE)
	_expect(packed != null, "main scene loads")
	if packed == null:
		return
	var world = packed.instantiate()
	_expect(world.get_node_or_null("Player") != null, "main scene instances the player")
	_expect(world.get_node_or_null("Player/Head/Camera3D") != null, "player has a Camera3D under Head")
	_expect(world.get_node_or_null("Ground/Shape") != null, "main scene has ground collision")
	_expect(world.get_node_or_null("Sun") != null, "main scene has a DirectionalLight3D")
	world.free()


func check_controller() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var floor_body := StaticBody3D.new()
	var floor_shape := CollisionShape3D.new()
	var floor_box := BoxShape3D.new()
	floor_box.size = Vector3(64, 2, 64)
	floor_shape.shape = floor_box
	floor_body.add_child(floor_shape)
	floor_body.position = Vector3(0, -1, 0)
	world.add_child(floor_body)

	var player = load(PLAYER_SCENE).instantiate()
	player.position = Vector3(0, 0.1, 0)
	world.add_child(player)
	var head: Node3D = player.get_node("Head")
	var shape_node: CollisionShape3D = player.get_node("CollisionShape3D")
	await wait_frames(10)
	_expect(player.is_on_floor(), "the player settles on the floor")

	# --- W: forward movement ---------------------------------------------
	var start: Vector3 = player.global_position
	Input.action_press("move_forward")
	await wait_frames(30)
	Input.action_release("move_forward")
	var forward_delta: Vector3 = player.global_position - start
	print("   forward delta %s" % forward_delta)
	_expect(forward_delta.z < -1.0, "W walks the player towards -Z")
	_expect(absf(forward_delta.y) < 0.1, "the player stays on the floor while walking")

	# --- friction ---------------------------------------------------------
	await wait_frames(30)
	var speed_after_stop := Vector2(player.velocity.x, player.velocity.z).length()
	_expect(speed_after_stop < 0.05, "the player stops with no key held (%.3f m/s)" % speed_after_stop)

	# --- D: strafing ------------------------------------------------------
	start = player.global_position
	Input.action_press("move_right")
	await wait_frames(30)
	Input.action_release("move_right")
	var strafe_delta: Vector3 = player.global_position - start
	print("   strafe delta %s" % strafe_delta)
	_expect(strafe_delta.x > 1.0, "D strafes the player towards +X")

	# --- S / A: the remaining axes ---------------------------------------
	# Let the leftover momentum from the previous test bleed off first.
	await wait_frames(45)
	start = player.global_position
	Input.action_press("move_back")
	await wait_frames(30)
	Input.action_release("move_back")
	_expect((player.global_position - start).z > 0.5, "S walks the player towards +Z")
	await wait_frames(45)
	start = player.global_position
	Input.action_press("move_left")
	await wait_frames(30)
	Input.action_release("move_left")
	_expect((player.global_position - start).x < -0.5, "A strafes the player towards -X")

	# --- Shift: sprinting -------------------------------------------------
	await wait_frames(45)
	Input.action_press("move_forward")
	await wait_frames(40)
	var walk_speed := Vector2(player.velocity.x, player.velocity.z).length()
	Input.action_press("sprint")
	await wait_frames(30)
	var sprint_speed := Vector2(player.velocity.x, player.velocity.z).length()
	Input.action_release("sprint")
	Input.action_release("move_forward")
	print("   walk %.2f m/s -> sprint %.2f m/s" % [walk_speed, sprint_speed])
	_expect(walk_speed > 4.0, "walking speed is around 5 m/s")
	_expect(sprint_speed > walk_speed + 1.0, "Shift raises the movement speed")

	# --- Space: jumping ---------------------------------------------------
	await wait_frames(30)
	var ground_height: float = player.global_position.y
	var jumped := false
	Input.action_press("jump")
	await wait_frames(1)
	Input.action_release("jump")
	var peak := ground_height
	for i in 20:
		await physics_frame
		peak = maxf(peak, player.global_position.y)
		jumped = jumped or not player.is_on_floor()
	print("   jump height %.2f m" % (peak - ground_height))
	_expect(jumped, "Space leaves the floor")
	_expect(peak - ground_height > 0.5, "the jump clears more than half a metre")
	await wait_frames(60)
	_expect(player.is_on_floor(), "the player lands again")

	# --- Ctrl / C: crouching ---------------------------------------------
	var stand_head_y: float = head.position.y
	var stand_capsule: float = (shape_node.shape as CapsuleShape3D).height
	Input.action_press("crouch")
	await wait_frames(30)
	var crouch_head_y: float = head.position.y
	var crouch_capsule: float = (shape_node.shape as CapsuleShape3D).height
	print("   head %.2f -> %.2f, capsule %.2f -> %.2f" % [stand_head_y, crouch_head_y, stand_capsule, crouch_capsule])
	_expect(player.is_crouching(), "the player reports being crouched")
	_expect(crouch_capsule < stand_capsule - 0.4, "crouching shortens the collision capsule")
	_expect(crouch_head_y < stand_head_y - 0.4, "crouching lowers the camera")
	_expect(absf(shape_node.position.y - crouch_capsule * 0.5) < 0.01, "the crouched capsule stays centred on the feet")
	await wait_frames(30)
	Input.action_release("crouch")
	_expect(player.is_crouching(), "the player stays crouched while the key is held")
	await wait_frames(30)
	_expect(not player.is_crouching(), "the player stands up when the key is released")
	_expect(absf(shape_node.position.y - stand_capsule * 0.5) < 0.01, "the standing capsule is centred on the feet")

	# --- the player must not fall through the floor -----------------------
	_expect(player.is_on_floor() and player.global_position.y > -1.0, "the player is still above the floor")
	world.free()


func wait_frames(count: int) -> void:
	for i in count:
		await physics_frame


func _expect(condition: bool, description: String) -> void:
	if condition:
		print("PASS: %s" % description)
	else:
		_failures += 1
		print("FAIL: %s" % description)