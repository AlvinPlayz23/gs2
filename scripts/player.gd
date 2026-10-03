extends CharacterBody3D
## First-person player controller.
##
## Controls:
## [codeblock lang=text]
## Move    W / A / S / D
## Look    Mouse
## Jump    Space
## Sprint  Shift
## Crouch  Ctrl or C
## Escape  Release the mouse cursor (click the window to capture it again)
## [/codeblock]
##
## The camera also bobs and sways while walking, imitating how a real head moves
## with each footstep. This is purely cosmetic: it never changes where the player
## walks, what they collide with, or where they are looking.

## Horizontal speed in metres per second while walking.
@export var walk_speed: float = 5.0
## Horizontal speed in metres per second while sprinting.
@export var sprint_speed: float = 8.0
## Horizontal speed in metres per second while crouching.
@export var crouch_speed: float = 2.5
## Upward velocity applied when jumping, in metres per second. Combined with the
## project gravity of 20 m/s² this clears a little over one metre.
@export var jump_velocity: float = 6.6
## How fast the player speeds up and changes direction while on the ground.
## Higher values make the controls feel more direct and less "icy".
@export var ground_acceleration: float = 30.0
## How fast the player reaches the desired speed while airborne.
@export var air_acceleration: float = 3.0
## How fast the player slows to a stop when no movement key is held. Raise this
## if the floor still feels slippery after letting go of the movement keys.
@export var ground_friction: float = 60.0
## Mouse look sensitivity in radians per pixel of mouse movement.
@export var mouse_sensitivity: float = 0.0025
## Maximum camera pitch, in degrees.
@export var max_look_angle: float = 89.0
## Seconds spent blending between the standing and the crouched pose.
@export var crouch_transition_time: float = 0.15

@export_group("Camera Shake")
## When disabled the camera stays perfectly still, even while walking.
@export var camera_shake_enabled: bool = true
## Distance in metres covered during one full shake cycle (a left step plus a
## right step). Smaller values make the shake faster and busier.
@export_range(0.5, 10.0, 0.1, "suffix:m") var bob_stride_length: float = 3.4
## How far the camera rises and dips, in metres. Humans bob twice per cycle, so
## the camera dips once per footstep.
@export_range(0.0, 0.2, 0.005, "suffix:m") var bob_vertical_amount: float = 0.035
## How far the camera sways from side to side, in metres.
@export_range(0.0, 0.2, 0.005, "suffix:m") var bob_lateral_amount: float = 0.025
## How far the camera tilts left and right, in degrees.
@export_range(0.0, 5.0, 0.05, "suffix:°") var bob_roll_amount: float = 0.4
## How far the camera nods up and down, in degrees.
@export_range(0.0, 5.0, 0.05, "suffix:°") var bob_pitch_amount: float = 0.12
## How quickly the shake fades in and out, so it never pops when starting or
## stopping. Higher values snap faster.
@export_range(0.5, 30.0, 0.5) var bob_fade_speed: float = 5.0

## Movement slower than this does not shake the camera at all.
const MIN_SHAKE_SPEED: float = 0.1
## The shake never gets stronger than this multiple, so sprinting shakes 1.6x
## as hard as walking at [member walk_speed].
const MAX_SHAKE_WEIGHT: float = 1.6

## Full height of the collision capsule while standing, in metres.
const STAND_HEIGHT: float = 1.8
## Full height of the collision capsule while crouching, in metres.
const CROUCH_HEIGHT: float = 1.1
## Distance between the top of the capsule and the camera, in metres.
const EYE_OFFSET_FROM_TOP: float = 0.2

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

## How far the current pose is between standing (0.0) and crouched (1.0).
var _crouch_amount: float = 0.0
var _capsule: CapsuleShape3D
## Stride phase in radians, advanced by the distance the player travels.
var _bob_phase: float = 0.0
## How strongly the shake is applied right now (0.0 still, 1.0 walking).
var _bob_weight: float = 0.0
## The camera transform with no shake, restored whenever the player is still.
var _camera_rest_position: Vector3
var _camera_rest_rotation: Vector3


func _ready() -> void:
	if collision_shape.shape is CapsuleShape3D:
		_capsule = collision_shape.shape
	else:
		push_warning("Player expects a CapsuleShape3D on its CollisionShape3D.")
	_apply_pose()
	# Remember where the camera sits so the shake can always return to neutral.
	_camera_rest_position = camera.position
	_camera_rest_rotation = camera.rotation
	# Grab the mouse right away so looking around works without clicking first.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# Yaw rotates the whole body, pitch only tilts the head.
		rotate_y(-event.relative.x * mouse_sensitivity)
		head.rotate_x(-event.relative.y * mouse_sensitivity)
		var pitch_limit := deg_to_rad(max_look_angle)
		head.rotation.x = clampf(head.rotation.x, -pitch_limit, pitch_limit)
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			# Clicking back into the window hands the mouse to the game again.
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
	_update_crouch(delta)
	_apply_gravity(delta)
	_apply_movement(delta)
	move_and_slide()
	# Run last so the shake uses this step's floor state and final speed.
	_update_camera_shake(delta)


## Returns [code]true[/code] while the player is not fully standing.
func is_crouching() -> bool:
	return _crouch_amount > 0.5


func _apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y += get_gravity().y * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity
	else:
		# Drop any leftover downward speed so the body stays glued to the floor.
		velocity.y = 0.0


func _apply_movement(delta: float) -> void:
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	# Turn the input into a world-space direction using the body's yaw only, so
	# looking up or down never changes where the player walks.
	var body_basis := global_transform.basis
	var direction := body_basis.x * input_dir.x + body_basis.z * input_dir.y
	direction.y = 0.0
	if not direction.is_zero_approx():
		direction = direction.normalized()

	var planar_velocity := Vector3(velocity.x, 0.0, velocity.z)
	if direction.is_zero_approx():
		# Out of air control: momentum is kept while airborne.
		if is_on_floor():
			planar_velocity = planar_velocity.move_toward(Vector3.ZERO, ground_friction * delta)
	else:
		var acceleration := ground_acceleration if is_on_floor() else air_acceleration
		if is_on_floor() and planar_velocity.dot(direction) < 0.0:
			# Pushing against the direction we are already travelling brakes as
			# hard as releasing the keys does, so a quick turnaround with the
			# mouse (a 180° flick while still holding W, say) snaps around
			# instead of carving a wide, slippery arc.
			acceleration = maxf(acceleration, ground_friction)
		var target_velocity := direction * _target_speed()
		planar_velocity = planar_velocity.move_toward(target_velocity, acceleration * delta)

	velocity.x = planar_velocity.x
	velocity.z = planar_velocity.z


func _target_speed() -> float:
	if is_crouching():
		return crouch_speed
	if Input.is_action_pressed("sprint"):
		return sprint_speed
	return walk_speed


func _update_crouch(delta: float) -> void:
	var step := delta / maxf(crouch_transition_time, 0.01)
	if Input.is_action_pressed("crouch"):
		_crouch_amount = minf(_crouch_amount + step, 1.0)
	elif _has_headroom():
		# Only stand back up when nothing is blocking the capsule.
		_crouch_amount = maxf(_crouch_amount - step, 0.0)
	_apply_pose()


## Reshapes the collision capsule and moves the camera to match the current pose.
func _apply_pose() -> void:
	var height := lerpf(STAND_HEIGHT, CROUCH_HEIGHT, _crouch_amount)
	if _capsule != null:
		_capsule.height = height
	# Keep the capsule centred on its own middle so the feet never leave the body
	# origin, which also keeps [method CharacterBody3D.is_on_floor] reliable.
	collision_shape.position.y = height * 0.5
	head.position.y = height - EYE_OFFSET_FROM_TOP


## Returns [code]true[/code] when nothing blocks the capsule from standing up.
func _has_headroom() -> bool:
	var motion := Vector3.UP * (STAND_HEIGHT * 0.5 - collision_shape.position.y)
	if motion.is_zero_approx():
		return true
	return not test_move(global_transform, motion)


## Shakes the camera the way a real head moves while walking. It only ever
## touches the [Camera3D] transform, so movement, collision and aiming are
## completely unaffected.
func _update_camera_shake(delta: float) -> void:
	if not camera_shake_enabled:
		_bob_weight = 0.0
		camera.position = _camera_rest_position
		camera.rotation = _camera_rest_rotation
		return

	var planar_speed := Vector2(velocity.x, velocity.z).length()
	var walking := is_on_floor() and planar_speed > MIN_SHAKE_SPEED

	var target_weight := 0.0
	if walking:
		# Sprinting shakes harder than walking, but only up to MAX_SHAKE_WEIGHT.
		target_weight = clampf(planar_speed / walk_speed, 0.0, MAX_SHAKE_WEIGHT)
	# Fade in and out so the shake never pops when the player starts or stops.
	_bob_weight = move_toward(_bob_weight, target_weight, bob_fade_speed * delta)

	if walking:
		# Drive the stride from distance travelled rather than time, so the
		# rhythm always matches the real speed and stops the instant the player
		# does, instead of running on like a timer.
		var stride_length := maxf(bob_stride_length, 0.01)
		_bob_phase = fmod(_bob_phase + (planar_speed / stride_length) * TAU * delta, TAU)

	# A human head dips twice per stride (once per footstep) and sways from side
	# to side once per stride, tilting slightly as the weight shifts between legs.
	var dip := -cos(_bob_phase * 2.0)
	var sway := sin(_bob_phase)
	var weight := _bob_weight

	camera.position = _camera_rest_position + Vector3(
		sway * bob_lateral_amount * weight,
		dip * bob_vertical_amount * weight,
		0.0)
	camera.rotation = _camera_rest_rotation + Vector3(
		sin(_bob_phase * 2.0) * deg_to_rad(bob_pitch_amount) * weight,
		0.0,
		-sway * deg_to_rad(bob_roll_amount) * weight)