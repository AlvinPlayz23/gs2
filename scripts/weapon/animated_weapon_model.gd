class_name AnimatedWeaponModel
extends Node3D
## Wrapper for an imported animated viewmodel rig (the 9mm pistol, the M4).
##
## Every rig ships a different set of clips, so each one is named by an export
## and every play request is guarded by [method _has_animation]. The 9mm pistol
## carries an [code]Idle[/code] / [code]Walk[/code] / [code]Run[/code] set and
## eight other clips that are ignored on purpose; the M4 ships only
## [code]Draw[/code] / [code]Reload[/code] / [code]Fire[/code] /
## [code]Reload_Empty[/code] / [code]Holster[/code] and has no idle loop, so it
## rests in its bind pose (which is its authored held pose) and plays its draw
## clip when raised. Whichever clips exist are used:
## [code]Fire[/code] on every shot, [code]Reload[/code] /
## [code]Reload_Empty[/code] on reload (time-scaled to the weapon's reload
## duration so the mag seats exactly as ammo transfers), and
## [code]Idle[/code] / [code]Walk[/code] / [code]Run[/code] as the resting and
## locomotion loops driven every tick from the player's real movement.
##
## The rig also carries its own head anchor ([member head_anchor_name], bound
## to the asset's eye node). [method match_eye_to_camera] moves the viewmodel
## camera to that anchor, so the framing is the artist's authored FPS framing
## rather than a hand-tuned offset. A small [member eye_offset] nudge stays
## available for taste (a touch down and to the side is the classic look).
##
## Also hides any Skybox backdrop cube the asset ships (the 9mm pistol has one,
## the M4 does not), so only the arms and the weapon render inside the
## viewmodel's isolated SubViewport.

## Clip names requested from the imported player. Rigs differ in which of these
## they actually carry, so every request is checked before it is played.
@export var fire_anim: StringName = &"Fire"
@export var reload_anim: StringName = &"Reload"
@export var reload_empty_anim: StringName = &"Reload_Empty"
@export var idle_anim: StringName = &"Idle"
## Authored locomotion loops, driven every tick from the player's movement.
@export var walk_anim: StringName = &"Walk"
@export var run_anim: StringName = &"Run"
## One-shot clip played when the weapon is raised, for rigs that ship a draw
## pose instead of an idle loop (the M4). Ignored when the rig has an idle.
@export var draw_anim: StringName = &""


@export_group("Eye Anchor")
## Node inside the imported rig to treat as the head. Each rig authors its own
## eye joint at about eye height (the 9mm pistol's eye_common_877, the M4's
## FPS_Camera_j_01). [method match_eye_to_camera] copies that joint's transform
## straight onto the camera, so the weapon frames itself the way the artist
## posed it instead of through a hand-tuned offset.
@export var head_anchor_name: StringName = &"eye_common_877"
## Extra nudge applied to the camera after snapping to the anchor, in the
## camera's own space. Positive x moves the gun left on screen.
@export var eye_offset: Vector3 = Vector3(0.015, -0.012, 0.0)

var model_root: Node3D
var _player: AnimationPlayer
var _head: Node3D
## Currently playing locomotion loop. Empty while a one-shot owns the player,
## so the loop resumes by itself once the shot or reload lands.
var _loop: StringName = &""
## Blend time for switching locomotion loops, so Idle/Walk/Run hand off
## without a snap.
const LOOP_BLEND: float = 0.15


func _ready() -> void:
	_resolve_rig()
	_hide_skybox()
	play_idle()


## Finds the instanced glTF, its AnimationPlayer and the head anchor.
func _resolve_rig() -> void:
	model_root = null
	_player = null
	_head = null
	for child in get_children():
		if child is Node3D and model_root == null:
			model_root = child as Node3D
	if model_root == null:
		return
	for node in model_root.find_children("*", "AnimationPlayer", true, false):
		_player = node as AnimationPlayer
		break
	_head = model_root.find_child(head_anchor_name, true, false) as Node3D


## Moves [param camera] to the rig's head anchor, so the framing matches the
## artist's authored first-person view. The glTF importer already converts
## Blender's Z-up axes to Godot's Y-up, so the anchor's own -Z is the look
## direction and the transform is copied verbatim. (Adding a half-turn here is
## what used to leave the arms pointing the wrong way down the screen.) Call
## this after equipping and whenever an animation changes, then leave the
## camera alone — bob and sway are applied to the mount, not the eye.
func match_eye_to_camera(camera: Camera3D) -> bool:
	if model_root == null or camera == null:
		_resolve_rig()
		if model_root == null or camera == null:
			return false
	if _head == null:
		_head = model_root.find_child(head_anchor_name, true, false) as Node3D
		if _head == null:
			return false
	# The camera must live in the same space as the anchor. In practice it is
	# a sibling of the mount (both under the viewmodel SubViewport), so a
	# global transform copy lands it on the eye exactly.
	camera.global_transform = _head.global_transform
	camera.translate_object_local(eye_offset)
	return true


## Restarts the fire animation. Falls back to nothing when the rig lacks it.
## Clears the locomotion loop so it resumes on its own once the shot lands.
func play_fire() -> void:
	_play_only(fire_anim, 1.0)
	_loop = &""


## Plays the reload animation, stretched or squeezed to last [param duration]
## seconds so the motion finishes exactly when the ammo transfers.
func play_reload(empty: bool, duration: float) -> void:
	var anim := reload_empty_anim if empty else reload_anim
	var speed := 1.0
	if _player != null and _player.has_animation(anim):
		var length := _player.get_animation(anim).length
		if length > 0.001 and duration > 0.001:
			speed = length / duration
	_play_only(anim, speed)
	_loop = &""


## Returns to the resting pose. Called on equip and as the default locomotion.
## Rigs with an Idle clip (the 9mm pistol) resume that loop; rigs with only a
## Draw clip (the M4) play it once and then hold, which is their authored
## resting pose.
func play_idle() -> void:
	if _has_animation(idle_anim):
		_play_only(idle_anim, 1.0)
		_loop = idle_anim
		return
	# No idle loop authored, so fall through to the draw clip when the rig has
	# one and otherwise simply hold the bind pose.
	_loop = &""
	_play_only(draw_anim, 1.0)


## Switches the looping locomotion clip (Idle/Walk/Run) from per-frame movement
## state. One-shot fire/reload clips are never interrupted: while one is still
## playing the request is ignored, and the loop resumes by itself afterwards.
func set_locomotion(moving: bool, sprinting: bool) -> void:
	if model_root == null:
		_resolve_rig()
		if model_root == null:
			return
	# A rig with no Idle clip has no Walk/Run either, so there is nothing to
	# hand off between.
	if not _has_animation(idle_anim):
		return
	var target := idle_anim
	if moving:
		target = run_anim if sprinting else walk_anim
	if target == _loop:
		return
	if _player != null and _player.is_playing():
		var current: StringName = _player.current_animation
		if current == fire_anim or current == reload_anim or current == reload_empty_anim:
			return
		if current == target:
			# Clip is already live but its loop flag does not survive import or
			# a one-shot that replaced it, so reuse the playing state instead
			# of restarting it.
			_loop = target
			return
	_play_only(target, 1.0, LOOP_BLEND)
	_loop = target


## True when the imported rig actually carries [param anim]. Rigs differ in
## which clips they ship, so every play request is checked against this.
func _has_animation(anim: StringName) -> bool:
	if anim.is_empty():
		return false
	if _player == null:
		_resolve_rig()
	return _player != null and _player.has_animation(anim)


func _play_only(anim: StringName, speed: float, blend: float = -1.0) -> void:
	if model_root == null:
		_resolve_rig()
	if not _has_animation(anim):
		return
	# Loops are flagged in code on every play, because imported glTF clips do
	# not reliably carry a loop mode — without this, Walk/Run stop after one
	# pass and the weapon freezes mid-stride.
	if anim == idle_anim or anim == walk_anim or anim == run_anim:
		var stored := _player.get_animation(anim) as Animation
		if stored != null:
			stored.loop_mode = Animation.LOOP_LINEAR
	_player.play(anim, blend, speed, false)


## The asset packs a 2m Skybox cube for its Sketchfab preview. It must not
## render inside the weapon viewport, so hide any mesh using that material.
func _hide_skybox() -> void:
	if model_root == null:
		return
	for node in model_root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := node as MeshInstance3D
		if mesh_instance == null:
			continue
		var material := mesh_instance.get_active_material(0)
		if material != null and "skybox" in material.resource_name.to_lower():
			mesh_instance.visible = false
