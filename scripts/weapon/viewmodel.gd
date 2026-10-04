class_name Viewmodel
extends CanvasLayer
## Drives the first-person weapon rig rendered in its own [SubViewport].
##
## The weapon lives in a separate [World3D], so it physically cannot intersect
## level geometry - it will never clip through a wall, no matter how close the
## player stands. It also means the world's rays are blind to it, so the player
## can never shoot their own arms.
##
## The tradeoff is that the weapon does not receive level lighting, so the rig
## carries its own light setup. If that ever becomes a problem, the alternative
## is a single-camera approach using a custom FOV in a vertex shader plus a depth
## hack - simpler to reason about in some ways, but far more fragile.
##
## The weapon is held fixed to the screen, which is what a first-person weapon
## should do: turning the player's view must not swing the gun across the screen.
## [member camera_pitch_influence] can blend in some of the player's pitch if you
## want the weapon to foreshorten as you look down.

@export_group("Camera")
## Field of view of the viewmodel camera. Lower than the world camera so the
## weapon keeps a stable, less distorted silhouette.
@export_range(30.0, 120.0, 1.0) var viewmodel_fov: float = 65.0
## How much of the player's pitch to copy. 0.0 keeps the weapon fixed to the
## screen, which is the correct default for a separate-world viewmodel; 1.0
## fully syncs it to the view.
@export_range(0.0, 1.0, 0.05) var camera_pitch_influence: float = 0.0

@export_group("Bob")
## Metres travelled per full bob cycle, matching the world camera's stride.
@export_range(0.5, 10.0, 0.1, "suffix:m") var bob_stride_length: float = 3.4
## Peak weapon movement in metres: x is side to side, y is up and down.
@export var bob_amount: Vector2 = Vector2(0.014, 0.011)
## How quickly the bob fades in and out.
@export_range(0.5, 30.0, 0.5) var bob_fade_speed: float = 7.0

@export_group("Sway")
## Metres of weapon lag per pixel of mouse movement.
@export_range(0.0, 0.02, 0.0001) var sway_amount: float = 0.0006
## Cap on the lag offset in metres, so a fast flick cannot throw the weapon.
@export_range(0.0, 0.2, 0.005) var sway_max: float = 0.015
## How quickly the lag settles back to centre.
@export_range(0.5, 30.0, 0.5) var sway_smoothing: float = 9.0
## Degrees of roll applied against the sideways lag.
@export_range(0.0, 20.0, 0.1) var sway_roll_degrees: float = 1.5

@export_group("Kick")
## Offset applied per unit of kick: positive z is backwards, towards the camera.
@export var kick_position: Vector3 = Vector3(0.0, 0.006, 0.045)
## Degrees the weapon pitches up per unit of kick.
@export_range(0.0, 30.0, 0.1) var kick_pitch_degrees: float = 3.0
## How quickly the kick settles.
@export_range(1.0, 60.0, 0.5) var kick_recovery: float = 15.0

@export_group("Locomotion")
## Planar speed above which the rig's Run loop replaces Walk. The player walks
## at 5 m/s and sprints at 8 m/s, so this sits between the two.
@export_range(0.0, 12.0, 0.1, "suffix:m/s") var sprint_threshold: float = 6.5

@onready var _viewport: SubViewport = $SubViewportContainer/SubViewport
@onready var _viewmodel_camera: Camera3D = $SubViewportContainer/SubViewport/ViewmodelCamera
@onready var _mount: Node3D = $SubViewportContainer/SubViewport/Mount

var _player_camera: Camera3D
var _player: Node3D
var _mount_rest: Transform3D
var _phase: float = 0.0
var _bob_weight: float = 0.0
var _sway: Vector2 = Vector2.ZERO
var _kick: float = 0.0
var _moving: bool = false
var _move_speed: float = 0.0
## The current weapon instance, when it exposes animation hooks
## ([method AnimatedWeaponModel.play_fire] and friends). Null for the
## procedural placeholder weapons.
var _weapon_anim: Node = null


func _ready() -> void:
	_mount_rest = _mount.transform
	_apply_fov()


## Called by the weapon manager once the rig is in the tree.
func setup(main_camera: Camera3D, player_body: Node3D) -> void:
	_player_camera = main_camera
	_player = player_body
	if is_node_ready():
		_apply_fov()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		# The weapon lags behind the view rather than snapping with it.
		_sway = (_sway - event.relative * sway_amount).limit_length(sway_max)


## Swaps in a weapon model. Passing null leaves the mount empty, which is what an
## unarmed player should see.
func set_weapon(scene: PackedScene, weapon_transform: Transform3D) -> void:
	for child in _mount.get_children():
		_mount.remove_child(child)
		child.queue_free()
	_weapon_anim = null
	if scene == null:
		return
	var instance := scene.instantiate()
	if instance is Node3D:
		(instance as Node3D).transform = weapon_transform
	_mount.add_child(instance)
	# Animated rigs (like the 9mm pistol) drive their own motion on top of the
	# procedural bob/sway/kick this node applies to the mount.
	if instance.has_method("play_fire"):
		_weapon_anim = instance
		if _weapon_anim.has_method("play_idle"):
			_weapon_anim.call("play_idle")
		# Animated rigs bring their own eye: snap the viewmodel camera to the
		# head anchor so the framing is the artist's, then ignore the weapon
		# resource offset entirely.
		if _weapon_anim.has_method("match_eye_to_camera"):
			_weapon_anim.call("match_eye_to_camera", _viewmodel_camera)


## Adds a visual recoil impulse. The manager calls this once per shot.
func kick(strength: float = 1.0) -> void:
	_kick = clampf(_kick + strength, 0.0, 3.0)


## Fire animation plus the procedural mount kick. Called by the manager once
## per shot; weapons without an animated rig just get the kick.
func play_fire_animation() -> void:
	kick(1.0)
	if _weapon_anim != null and is_instance_valid(_weapon_anim):
		_weapon_anim.call("play_fire")


## Reload animation, time-scaled so it lands exactly when ammo transfers.
## [param empty] selects the empty-chamber variant when one exists.
func play_reload_animation(empty: bool, duration: float) -> void:
	if _weapon_anim != null and is_instance_valid(_weapon_anim):
		_weapon_anim.call("play_reload", empty, duration)
		# Reloads move the hands through space; keep the eye glued to the
		# head anchor while the mag outs and back in.
		if _weapon_anim.has_method("match_eye_to_camera"):
			_weapon_anim.call("match_eye_to_camera", _viewmodel_camera)


## Advances the viewmodel animation. Called from the manager's physics step so
## the weapon moves in step with the player rather than on a separate clock.
func tick(delta: float) -> void:
	_update_bob(delta)
	_update_locomotion_anim()
	_sway = _sway.lerp(Vector2.ZERO, clampf(sway_smoothing * delta, 0.0, 1.0))
	_kick = move_toward(_kick, 0.0, kick_recovery * delta)
	_apply_transform()


## Drives the rig's own locomotion loop (Idle/Walk/Run) from the player's real
## movement. Procedural placeholders have no clips, so they keep the manual
## bob handled in [_apply_transform].
func _update_locomotion_anim() -> void:
	if _weapon_anim == null or not is_instance_valid(_weapon_anim):
		return
	if not _weapon_anim.has_method("set_locomotion"):
		return
	_weapon_anim.call("set_locomotion", _moving, _move_speed > sprint_threshold)


func _update_bob(delta: float) -> void:
	var speed := 0.0
	var walking := false
	if _player is CharacterBody3D:
		var body := _player as CharacterBody3D
		speed = Vector2(body.velocity.x, body.velocity.z).length()
		walking = body.is_on_floor() and speed > 0.05
	_bob_weight = move_toward(_bob_weight, 1.0 if walking else 0.0, bob_fade_speed * delta)
	if walking:
		# Driven by distance travelled, so the rhythm matches the real speed and
		# stops the moment the player does.
		_phase = fmod(
			_phase + (speed / maxf(bob_stride_length, 0.01)) * TAU * delta, TAU
		)
	_moving = walking
	_move_speed = speed


func _apply_transform() -> void:
	# Same shape as the world camera bob: twice per stride vertically, once per
	# stride sideways. Animated rigs play their own authored Walk/Run loops
	# instead, so the manual bob is skipped for them to avoid doubling up.
	var bob_weight := _bob_weight
	if _weapon_anim != null and is_instance_valid(_weapon_anim):
		bob_weight = 0.0
	var bob := Vector3(
		sin(_phase) * bob_amount.x,
		-cos(_phase * 2.0) * bob_amount.y,
		0.0
	) * bob_weight
	var offset := bob + Vector3(_sway.x, _sway.y, 0.0) + kick_position * _kick
	_mount.position = _mount_rest.origin + offset
	_mount.rotation = _mount_rest.basis.get_euler() + Vector3(
		deg_to_rad(kick_pitch_degrees) * _kick,
		0.0,
		deg_to_rad(sway_roll_degrees) * _sway.x
	)
	if camera_pitch_influence > 0.0 and _player_camera != null:
		_viewmodel_camera.rotation.x = _player_camera.rotation.x * camera_pitch_influence


func _apply_fov() -> void:
	if _viewmodel_camera != null:
		_viewmodel_camera.fov = viewmodel_fov
