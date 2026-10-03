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
	var forward_delta: Vector3 = player.global_position - start
	print("   forward delta %s" % forward_delta)
	_expect(forward_delta.z < -1.0, "W walks the player towards -Z")
	_expect(absf(forward_delta.y) < 0.1, "the player stays on the floor while walking")

	# --- releasing W must brake, not slide --------------------------------
	var speed_at_release := Vector2(player.velocity.x, player.velocity.z).length()
	var release_position: Vector3 = player.global_position
	Input.action_release("move_forward")
	await wait_frames(30)
	var slide_distance := Vector2(
		player.global_position.x - release_position.x,
		player.global_position.z - release_position.z).length()
	var speed_after_stop := Vector2(player.velocity.x, player.velocity.z).length()
	print("   released at %.2f m/s, slid %.3f m before stopping" % [speed_at_release, slide_distance])
	_expect(speed_at_release > 4.5, "the key was released at walking speed")
	_expect(slide_distance < 0.35, "releasing W brakes instead of sliding (%.3f m)" % slide_distance)
	_expect(speed_after_stop < 0.05, "the player is stopped half a second later (%.3f m/s)" % speed_after_stop)

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

	# --- walking camera shake (must only move the camera) ------------------
	var camera: Camera3D = player.get_node("Head/Camera3D")
	await wait_frames(60)
	_expect(camera.position.length() < 0.001, "the camera is perfectly still while standing")
	var body_before_shake: Vector3 = player.global_position
	var peak_up := 0.0
	var peak_down := 0.0
	var peak_sway := 0.0
	var peak_roll := 0.0
	Input.action_press("move_forward")
	for i in 90:
		await physics_frame
		peak_up = maxf(peak_up, camera.position.y)
		peak_down = minf(peak_down, camera.position.y)
		peak_sway = maxf(peak_sway, absf(camera.position.x))
		peak_roll = maxf(peak_roll, absf(camera.rotation.z))
	Input.action_release("move_forward")
	var travel: float = (player.global_position - body_before_shake).z
	print("   shake: up %.4f m, down %.4f m, sway %.4f m, roll %.3f deg" % [
		peak_up, peak_down, peak_sway, rad_to_deg(peak_roll)])
	print("   body travelled %.2f m during the shake" % travel)
	_expect(peak_up > 0.005, "the camera bobs up while walking")
	_expect(peak_down < -0.005, "the camera dips down while walking (once per footstep)")
	_expect(peak_sway > 0.005, "the camera sways side to side while walking")
	_expect(peak_roll > 0.001, "the camera tilts slightly while walking")
	_expect(travel < -4.0, "the player walks normally and is not slowed by the shake")

	# --- the shake stops cleanly and never drifts --------------------------
	await wait_frames(60)
	print("   after stopping: offset %.5f m, roll %.4f deg" % [
		camera.position.length(), rad_to_deg(absf(camera.rotation.z))])
	_expect(camera.position.length() < 0.0005, "the camera returns exactly to neutral when stopped")
	_expect(absf(camera.rotation.x) < 0.0001 and absf(camera.rotation.z) < 0.0001, "the camera rotation returns to neutral")

	# --- sprinting, then a quick mouse flick, must not slide ---------------
	# The exact reported scenario: sprint, let go of the keys and whip the view
	# around. Move to open floor first so nothing else interferes.
	player.global_position = Vector3(0, 0.1, 20)
	player.velocity = Vector3.ZERO
	await wait_frames(10)
	Input.action_press("move_forward")
	Input.action_press("sprint")
	await wait_frames(60)
	var sprint_release_speed := Vector2(player.velocity.x, player.velocity.z).length()
	var flick_position: Vector3 = player.global_position
	Input.action_release("move_forward")
	Input.action_release("sprint")
	player.rotate_y(PI * 0.5)
	await wait_frames(30)
	var flick_slide := Vector2(
		player.global_position.x - flick_position.x,
		player.global_position.z - flick_position.z).length()
	print("   sprint release at %.2f m/s, slid %.3f m after a 90 degree flick" % [sprint_release_speed, flick_slide])
	_expect(sprint_release_speed > 7.0, "the player was sprinting when the keys were released")
	_expect(flick_slide < 0.7, "sprinting then turning with the mouse does not slide (%.3f m)" % flick_slide)
	_expect(Vector2(player.velocity.x, player.velocity.z).length() < 0.05, "the player is fully stopped after the flick")
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