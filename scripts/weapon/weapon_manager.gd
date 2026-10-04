class_name WeaponManager
extends Node
## The weapon system: firing, hitscan, recoil, spread, reloading, slots,
## switching, pickups and bullet-hole impact decals.
##
## Lives as a child of the player so its [method Node._physics_process] runs
## after the player has moved, which keeps [method CharacterBody3D.is_on_floor]
## and the velocity used for spread up to date.
##
## Recoil is written to a dedicated pivot between the head and the camera rather
## than to the camera itself. That keeps aim free of the cosmetic walk bob, so
## the recoil offset and the bob never overwrite each other.

signal weapon_changed(state: WeaponState)
signal fired(state: WeaponState)
signal dry_fired(state: WeaponState)
signal reload_started(state: WeaponState)
signal reload_finished(state: WeaponState)
signal ammo_changed(state: WeaponState)
signal state_changed(new_state: int)
## Emitted for every hitscan pellet that strikes something. [param info] is the
## hit dictionary; [code]info["decal"][/code] is true when a bullet hole was
## left on world geometry (false for flesh hits and misses).
signal impacted(info: Dictionary)

enum State {
	## Ready to fire.
	IDLE,
	## Raising a freshly switched weapon. Cannot fire.
	DRAWING,
	## Lowering the current weapon before a switch completes. Cannot fire.
	HOLSTERING,
	## Swapping magazines. Cannot fire.
	RELOADING,
}

## Recovery rate used when a weapon has no recoil pattern at all.
const DEFAULT_RECOIL_RECOVERY: float = 8.0
## Speeds at or below this count as standing still for spread purposes.
const MOVING_SPEED_THRESHOLD: float = 0.1
## Planar speed that counts as a full sprint when scaling movement spread.
const SPRINT_REFERENCE_SPEED: float = 8.0
## Cooldown after clicking with an empty magazine, so dry fire cannot spam.
const DRY_FIRE_COOLDOWN: float = 0.25

const VIEWMODEL_SCENE: PackedScene = preload("res://scenes/weapon_viewmodel.tscn")
const PICKUP_SCENE: PackedScene = preload("res://scenes/weapons/weapon_pickup.tscn")

@export_group("References")
## The player body. Defaults to the parent node.
@export var player_path: NodePath = ^".."
## Pivot the recoil offset is applied to, between the head and the camera.
@export var recoil_pivot_path: NodePath = ^"../Head/RecoilPivot"
## Camera used as the muzzle origin for hitscan.
@export var camera_path: NodePath = ^"../Head/RecoilPivot/Camera3D"
## Area used to detect weapon pickups within reach.
@export var interact_area_path: NodePath = ^"../InteractArea"

@export_group("Starting Loadout")
## Weapon equipped in the primary slot at spawn. Leave empty to start unarmed.
@export var starting_primary: WeaponData
## Weapon equipped in the secondary slot at spawn.
@export var starting_secondary: WeaponData

@export_group("Determinism")
## Seed for the spread dice roll. Fixed by default so tests can assert exact
## behaviour; change it per match if you want varied luck.
@export var rng_seed: int = 20250425

@export_group("Impacts")
## When true, pellets that strike world geometry leave a bullet-hole decal.
## Pellets that strike flesh never leave one.
@export var impact_enabled: bool = true
## Bullet-hole image, projected onto the surface. Leave empty to use the
## built-in procedural blotch. Place a PNG at
## [code]assets/textures/decals/bullet_hole.png[/code] and assign it here.
@export var impact_texture: Texture2D
## Width and height of one hole in metres.
@export_range(0.05, 0.5, 0.01, "suffix:m") var impact_size: float = 0.12
## Seconds a hole stays visible before fading out. 0 or less lasts forever.
@export_range(0.0, 120.0, 1.0, "suffix:s") var impact_lifetime: float = 25.0
## How many holes can exist at once; the oldest is recycled past this.
@export_range(8, 256, 1) var max_impact_decals: int = 64

## One entry per slot, holding a [WeaponState] or null.
var slots: Dictionary = {}
## Slot currently held, or -1 when unarmed.
var active_slot: int = -1
## What the manager is doing right now.
var state: State = State.IDLE
## Accumulated recoil in degrees. [code]x[/code] is vertical (positive is up),
## [code]y[/code] is horizontal (positive is right).
var recoil_offset_degrees: Vector2 = Vector2.ZERO
## Current cone half-angle in degrees, after stance and bloom.
var current_spread_degrees: float = 0.0
## Shots fired this session, useful for tests and telemetry.
var shots_fired: int = 0
## Result dictionary of the most recent hitscan ray.
var last_hit: Dictionary = {}

var player: CharacterBody3D
var recoil_pivot: Node3D
var camera: Camera3D
var interact_area: Area3D
var viewmodel: Viewmodel
## Pooled bullet-hole decals, created at runtime.
var impact_decals: ImpactDecals

var _pending_slot: int = -1
var _fire_timer: float = 0.0
var _state_timer: float = 0.0
var _time_since_shot: float = 1.0e9
var _time_since_recoil: float = 1.0e9
var _world_3d: World3D
var _rng := RandomNumberGenerator.new()
var _audio: AudioStreamPlayer


func _ready() -> void:
	_rng.seed = rng_seed
	_resolve_nodes()
	_world_3d = get_viewport().find_world_3d()
	_audio = AudioStreamPlayer.new()
	_audio.name = "WeaponAudio"
	add_child(_audio)
	_create_impacts()
	# This runs while the player is still adding its own children, so adding the
	# viewmodel now would fail with "parent node is busy setting up children".
	# Deferring by one idle frame lets the player finish first.
	call_deferred("_setup_deferred")


## Creates the viewmodel and equips the starting loadout, once the player has
## finished building its children.
func _setup_deferred() -> void:
	_create_viewmodel()
	_grant_starting_weapons()


func _physics_process(delta: float) -> void:
	_tick_timers(delta)
	_handle_input()
	_update_recoil(delta)
	_update_spread(delta)
	if viewmodel != null:
		viewmodel.tick(delta)


func _resolve_nodes() -> void:
	player = get_node_or_null(player_path) as CharacterBody3D
	recoil_pivot = get_node_or_null(recoil_pivot_path) as Node3D
	camera = get_node_or_null(camera_path) as Camera3D
	interact_area = get_node_or_null(interact_area_path) as Area3D
	if recoil_pivot == null:
		push_warning("WeaponManager needs a recoil pivot at '%s'." % recoil_pivot_path)


func _grant_starting_weapons() -> void:
	if starting_primary != null:
		slots[int(WeaponData.Slot.PRIMARY)] = WeaponState.from_data(starting_primary)
	if starting_secondary != null:
		slots[int(WeaponData.Slot.SECONDARY)] = WeaponState.from_data(starting_secondary)
	var initial := -1
	if slots.get(int(WeaponData.Slot.PRIMARY)) != null:
		initial = int(WeaponData.Slot.PRIMARY)
	elif slots.get(int(WeaponData.Slot.SECONDARY)) != null:
		initial = int(WeaponData.Slot.SECONDARY)
	if initial < 0:
		return
	active_slot = initial
	_sync_viewmodel(current_state())
	weapon_changed.emit(current_state())
	ammo_changed.emit(current_state())
	_set_state(State.DRAWING)
	_state_timer = current_data().draw_time


# --- queries ---------------------------------------------------------------

## The [WeaponState] currently held, or null when unarmed.
func current_state() -> WeaponState:
	if active_slot < 0:
		return null
	return slots.get(active_slot)


## The [WeaponData] currently held, or null when unarmed.
func current_data() -> WeaponData:
	var weapon_state := current_state()
	return weapon_state.data if weapon_state != null else null


## True when the trigger can actually produce a shot this instant.
func can_shoot() -> bool:
	return state == State.IDLE and current_state() != null and _fire_timer <= 0.0


## The closest pickup within reach, or null.
func nearby_pickup() -> WeaponPickup:
	if interact_area == null or player == null:
		return null
	var best: WeaponPickup = null
	var best_distance := INF
	for area in interact_area.get_overlapping_areas():
		if area is WeaponPickup:
			var pickup := area as WeaponPickup
			var distance := player.global_position.distance_to(pickup.global_position)
			if distance < best_distance:
				best_distance = distance
				best = pickup
	return best


## The recoil pattern index the next shot will use.
func current_shot_index() -> int:
	var weapon_state := current_state()
	return weapon_state.shot_index if weapon_state != null else 0


func is_busy() -> bool:
	return state != State.IDLE


func _set_state(new_state: State) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(state)


func _tick_timers(delta: float) -> void:
	_fire_timer = maxf(_fire_timer - delta, 0.0)
	if state == State.IDLE:
		return
	_state_timer -= delta
	if _state_timer > 0.0:
		return
	match state:
		State.DRAWING:
			_set_state(State.IDLE)
		State.HOLSTERING:
			_complete_switch()
		State.RELOADING:
			_finish_reload()


# --- input -----------------------------------------------------------------

func _handle_input() -> void:
	# Use and drop are checked before anything else so an unarmed player can
	# still pick a weapon up off the ground.
	if Input.is_action_just_pressed("use"):
		try_use()
	if Input.is_action_just_pressed("drop"):
		try_drop()
	if Input.is_action_just_pressed("slot_primary"):
		switch_to(int(WeaponData.Slot.PRIMARY))
	if Input.is_action_just_pressed("slot_secondary"):
		switch_to(int(WeaponData.Slot.SECONDARY))
	if Input.is_action_just_pressed("reload"):
		start_reload()
	_update_fire_input()


func _update_fire_input() -> void:
	var weapon_state := current_state()
	if weapon_state == null or not can_shoot():
		return
	# Automatic weapons fire for as long as the trigger is held; everything else
	# fires once per click.
	var wants_fire := (
		Input.is_action_pressed("fire")
		if weapon_state.data.automatic
		else Input.is_action_just_pressed("fire")
	)
	if wants_fire:
		_do_shot(weapon_state)


# --- slots and switching ---------------------------------------------------

## The other of the two slots.
func _other_slot(slot: int) -> int:
	return (
		int(WeaponData.Slot.SECONDARY)
		if slot == int(WeaponData.Slot.PRIMARY)
		else int(WeaponData.Slot.PRIMARY)
	)


## Begins a switch to [param slot] if it holds a weapon. Holsters first, so the
## player cannot fire mid-swap.
func switch_to(slot: int) -> bool:
	if slot == active_slot or slots.get(slot) == null:
		return false
	_pending_slot = slot
	var weapon_state := current_state()
	var holster := weapon_state.data.holster_time if weapon_state != null else 0.0
	# A lowered weapon is not aiming, so the recoil offset clears with it.
	recoil_offset_degrees = Vector2.ZERO
	_apply_recoil_to_pivot()
	_set_state(State.HOLSTERING)
	_state_timer = holster
	return true


func _complete_switch() -> void:
	active_slot = _pending_slot
	_pending_slot = -1
	var weapon_state := current_state()
	_sync_viewmodel(weapon_state)
	weapon_changed.emit(weapon_state)
	ammo_changed.emit(weapon_state)
	if weapon_state == null:
		_set_state(State.IDLE)
		return
	_fire_timer = 0.0
	_set_state(State.DRAWING)
	_state_timer = weapon_state.data.draw_time


## Puts a weapon into its slot without holstering, for spawn and pickups.
func _equip_direct(data: WeaponData) -> WeaponState:
	var weapon_state := WeaponState.from_data(data)
	slots[int(data.slot)] = weapon_state
	return weapon_state


## Swaps to [param slot] immediately, skipping the holster delay. Used when the
## weapon in hand has just been dropped and something else is ready to come up.
func _swap_immediately(slot: int) -> void:
	active_slot = slot
	_pending_slot = -1
	recoil_offset_degrees = Vector2.ZERO
	_apply_recoil_to_pivot()
	var weapon_state := current_state()
	_sync_viewmodel(weapon_state)
	weapon_changed.emit(weapon_state)
	ammo_changed.emit(weapon_state)
	if weapon_state == null:
		_set_state(State.IDLE)
		return
	_fire_timer = 0.0
	_set_state(State.DRAWING)
	_state_timer = weapon_state.data.draw_time
# --- firing and hitscan ----------------------------------------------------

## Fires one shot: consumes a round, kicks the view, blooms the cone and traces
## a ray per pellet. Everything about the shot is deterministic given the same
## trigger timing, which is what makes the recoil pattern learnable.
func _do_shot(weapon_state: WeaponState) -> void:
	if not weapon_state.consume_round():
		dry_fire()
		return
	var data := weapon_state.data
	_fire_timer = data.shot_interval()
	weapon_state.add_bloom()
	_apply_recoil_for_shot(weapon_state)
	shots_fired += 1
	var origin := _muzzle_origin()
	var aim := _aim_direction()
	for i in data.pellets:
		last_hit = _fire_ray(origin, aim)
	_play(data.fire_sound)
	if viewmodel != null:
		viewmodel.play_fire_animation()
	fired.emit(weapon_state)
	ammo_changed.emit(weapon_state)


## Called when the trigger is pulled with an empty magazine.
func dry_fire() -> void:
	_fire_timer = DRY_FIRE_COOLDOWN
	dry_fired.emit(current_state())


## Traces one pellet and applies damage to whatever it hits.
##
## Uses [method PhysicsDirectSpaceState3D.intersect_ray] rather than a
## [RayCast3D] node on purpose: a RayCast3D node needs a physics frame to pick up
## a transform change, so a shot fired immediately after a mouse flick would
## still be aimed along the previous frame's direction.
func _fire_ray(origin: Vector3, aim: Vector3) -> Dictionary:
	var data := current_data()
	if data == null or _world_3d == null:
		return {}
	var direction := _spread_direction(aim, current_spread_degrees)
	var query := PhysicsRayQueryParameters3D.create(
		origin, origin + direction * data.max_range
	)
	# Never shoot the shooter. Areas are included in the query so Hitbox nodes
	# are reachable, which also means the player's own interact area would block
	# shots, so both of the player's colliders are excluded.
	var excluded: Array[RID] = []
	if player != null:
		excluded.append(player.get_rid())
	if interact_area != null:
		excluded.append(interact_area.get_rid())
	query.exclude = excluded
	query.collide_with_areas = true
	query.collide_with_bodies = true
	var hit := _world_3d.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return hit
	var distance := origin.distance_to(hit["position"])
	var info := {
		"position": hit["position"],
		"normal": hit["normal"],
		"direction": direction,
		"origin": origin,
		"distance": distance,
		"shooter": player,
		"weapon": data,
		"armor_penetration": data.armor_penetration,
	}
	var collider = hit.get("collider")
	var struck_flesh := false
	if collider != null and collider.has_method("apply_damage"):
		collider.apply_damage(data.damage_at_distance(distance), info)
		struck_flesh = true
	# Holes go on walls, crates and the floor — never on the thing you shot.
	var left_decal := false
	if impact_enabled and not struck_flesh and impact_decals != null:
		var surface_normal: Vector3 = hit.get("normal", -direction)
		impact_decals.spawn_impact(hit["position"], surface_normal)
		left_decal = true
	info["decal"] = left_decal
	impacted.emit(info)
	return hit


## Where rays start: the camera, so impacts line up with what the player sees.
func _muzzle_origin() -> Vector3:
	if camera != null:
		return camera.global_position
	if recoil_pivot != null:
		return recoil_pivot.global_position
	if player != null:
		return player.global_position
	return Vector3.ZERO


## Where rays point: the recoil pivot, which carries the player's yaw and pitch
## plus the accumulated recoil, but not the cosmetic walk bob.
func _aim_direction() -> Vector3:
	if recoil_pivot != null:
		return -recoil_pivot.global_transform.basis.z
	if player != null:
		return -player.global_transform.basis.z
	return Vector3.FORWARD


## Rotates [param aim] to a random point inside a cone of
## [param spread_degrees] half-angle. Uses the seeded generator, so a fixed seed
## always produces the same spray.
func _spread_direction(aim: Vector3, spread_degrees: float) -> Vector3:
	var forward := aim.normalized()
	if spread_degrees <= 0.0001:
		return forward
	var reference_up := (
		Vector3.UP if absf(forward.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	)
	var right := forward.cross(reference_up).normalized()
	var up := right.cross(forward).normalized()
	# sqrt() spreads the samples evenly over the disc rather than clustering
	# them in the middle.
	var angle := _rng.randf() * TAU
	var radius := sqrt(_rng.randf()) * tan(deg_to_rad(spread_degrees))
	return (forward + right * (cos(angle) * radius) + up * (sin(angle) * radius)).normalized()


# --- recoil ----------------------------------------------------------------

## Adds this shot's kick from the pattern. The horizontal component is negated
## because +rotation.y turns left in Godot's Y-up space, while a positive
## pattern value means "kick right".
func _apply_recoil_for_shot(weapon_state: WeaponState) -> void:
	var kick := weapon_state.data.recoil_at_shot(weapon_state.shot_index)
	recoil_offset_degrees += kick
	weapon_state.advance_shot_index()
	_time_since_shot = 0.0
	_time_since_recoil = 0.0


func _update_recoil(delta: float) -> void:
	_time_since_shot += delta
	_time_since_recoil += delta
	var weapon_state := current_state()
	if weapon_state == null:
		recoil_offset_degrees = recoil_offset_degrees.move_toward(
			Vector2.ZERO, DEFAULT_RECOIL_RECOVERY * delta
		)
		_apply_recoil_to_pivot()
		return
	# Idle long enough and the pattern starts again from the first entry.
	if _time_since_shot >= weapon_state.data.recoil_reset_time:
		weapon_state.reset_shot_index()
	# Recovery waits out the delay, so the view holds where it was kicked to for
	# the duration of a burst and only settles once the player stops.
	if _time_since_recoil >= weapon_state.data.recoil_recovery_delay:
		recoil_offset_degrees = recoil_offset_degrees.move_toward(
			Vector2.ZERO, weapon_state.data.recoil_recovery * delta
		)
	_apply_recoil_to_pivot()


func _apply_recoil_to_pivot() -> void:
	if recoil_pivot == null:
		return
	recoil_pivot.rotation.x = deg_to_rad(recoil_offset_degrees.x)
	recoil_pivot.rotation.y = -deg_to_rad(recoil_offset_degrees.y)


# --- spread ----------------------------------------------------------------

func _update_spread(delta: float) -> void:
	var weapon_state := current_state()
	if weapon_state == null:
		current_spread_degrees = 0.0
		return
	weapon_state.bloom = move_toward(
		weapon_state.bloom, 0.0, weapon_state.data.spread_recovery * delta
	)
	current_spread_degrees = _compute_spread(weapon_state)


func _compute_spread(weapon_state: WeaponState) -> float:
	var stance_base := weapon_state.data.spread_base * _stance_multiplier(weapon_state.data)
	return clampf(
		stance_base + weapon_state.bloom,
		stance_base,
		weapon_state.data.spread_max
	)


## Combined spread multiplier for how the player is currently standing. Moving,
## jumping and crouching each scale the cone.
func _stance_multiplier(data: WeaponData) -> float:
	if player == null:
		return 1.0
	var multiplier := 1.0
	var speed := Vector2(player.velocity.x, player.velocity.z).length()
	if speed > MOVING_SPEED_THRESHOLD:
		multiplier *= lerpf(
			1.0,
			data.spread_move_multiplier,
			clampf(speed / SPRINT_REFERENCE_SPEED, 0.0, 1.0)
		)
	if not player.is_on_floor():
		multiplier *= data.spread_jump_multiplier
	if player.has_method("is_crouching") and player.is_crouching():
		multiplier *= data.spread_crouch_multiplier
	return multiplier


# --- reloading -------------------------------------------------------------

## Starts a reload if the magazine is not full and there is ammo in reserve.
## Reloading an empty weapon takes longer, as the chamber has to be filled too.
func start_reload() -> bool:
	var weapon_state := current_state()
	if weapon_state == null or state != State.IDLE or not weapon_state.can_reload():
		return false
	var duration := weapon_state.data.reload_time
	if weapon_state.is_magazine_empty():
		duration += weapon_state.data.reload_empty_extra
	_set_state(State.RELOADING)
	_state_timer = duration
	if viewmodel != null:
		viewmodel.play_reload_animation(weapon_state.is_magazine_empty(), duration)
	reload_started.emit(weapon_state)
	_play(weapon_state.data.reload_sound)
	return true


## Moves rounds from the reserve into the magazine. Ammo is only transferred at
## the end, so abandoning a reload by switching weapons costs nothing.
func _finish_reload() -> void:
	var weapon_state := current_state()
	if weapon_state != null:
		weapon_state.finish_reload()
		ammo_changed.emit(weapon_state)
	reload_finished.emit(weapon_state)
	_set_state(State.IDLE)


# --- pickup and drop -------------------------------------------------------

## Picks up whatever is in reach. Bound to the use key, which is also the
## interact key for things like planting and defusing.
func try_use() -> bool:
	var pickup := nearby_pickup()
	if pickup == null or pickup.weapon_data == null:
		return false
	_equip_from_pickup(pickup)
	return true


func _equip_from_pickup(pickup: WeaponPickup) -> void:
	var data := pickup.weapon_data
	var slot := int(data.slot)
	var previous: WeaponState = slots.get(slot)
	if previous != null:
		# The weapon being replaced goes back into the world, as in CS.
		_spawn_pickup(previous.data, _drop_position())
	var equipped := _equip_direct(data)
	pickup.consume()
	if slot == active_slot:
		# Already holding this slot, so refresh it in place rather than going
		# through a pointless holster cycle.
		_sync_viewmodel(equipped)
		weapon_changed.emit(equipped)
		ammo_changed.emit(equipped)
		_fire_timer = 0.0
		_set_state(State.DRAWING)
		_state_timer = equipped.data.draw_time
	else:
		switch_to(slot)


## Drops the held weapon into the world and brings up the other slot if it holds
## something. Bound to its own key rather than sharing the use key, so a drop can
## never be mistaken for a pickup.
func try_drop() -> bool:
	var weapon_state := current_state()
	if weapon_state == null:
		return false
	var slot := active_slot
	_spawn_pickup(weapon_state.data, _drop_position())
	slots[slot] = null
	var other := _other_slot(slot)
	if slots.get(other) != null:
		_swap_immediately(other)
	else:
		_swap_immediately(-1)
	return true


## Spawns a weapon lying in the world that can be picked up again.
func _spawn_pickup(data: WeaponData, at: Vector3) -> WeaponPickup:
	if data == null:
		return null
	var pickup := PICKUP_SCENE.instantiate() as WeaponPickup
	if pickup == null:
		return null
	pickup.weapon_data = data
	_world_parent().add_child(pickup)
	pickup.global_position = at
	return pickup


## In front of the player's feet, so a dropped weapon is visible and reachable.
func _drop_position() -> Vector3:
	if player == null:
		return Vector3.UP * 0.3
	var forward := -player.global_transform.basis.z
	return player.global_position + forward * 1.0 + Vector3.UP * 0.3


func _world_parent() -> Node:
	if player != null and player.get_parent() != null:
		return player.get_parent()
	return self


# --- viewmodel and audio ---------------------------------------------------

## Builds the pooled bullet-hole decals from the impact settings.
func _create_impacts() -> void:
	var fx := ImpactDecals.new()
	fx.name = "ImpactDecals"
	add_child(fx)
	fx.configure(impact_texture, impact_size, impact_lifetime, max_impact_decals)
	impact_decals = fx


func _create_viewmodel() -> void:
	var rig := VIEWMODEL_SCENE.instantiate() as Viewmodel
	if rig == null:
		return
	var parent: Node = player if player != null else self
	parent.add_child(rig)
	rig.setup(camera, player)
	viewmodel = rig


func _sync_viewmodel(weapon_state: WeaponState) -> void:
	if viewmodel == null:
		return
	if weapon_state == null:
		viewmodel.set_weapon(null, Transform3D.IDENTITY)
		return
	viewmodel.set_weapon(weapon_state.data.viewmodel_scene, weapon_state.data.viewmodel_transform)


func _play(stream: AudioStream) -> void:
	if stream == null or _audio == null:
		return
	_audio.stream = stream
	_audio.play()
