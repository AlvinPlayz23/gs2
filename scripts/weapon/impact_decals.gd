class_name ImpactDecals
extends Node
## Pooled bullet-hole decals projected onto world geometry.
##
## One pool per weapon manager, created at runtime. Decals are [Decal] nodes,
## which render in the Forward+ renderer this project uses, so impacts show up
## with no shader tricks and no clipping hacks.
##
## Slots are reused round-robin, so spraying a wall never allocates: the oldest
## hole is recycled once the pool is full. Each decal is top-level, so it stays
## pinned to the world even though the pool lives under the moving player.
##
## Drop a transparent PNG at [code]assets/textures/decals/bullet_hole.png[/code]
## (256x256 recommended, dark irregular ring with a soft alpha edge) and assign
## it to [member WeaponManager.impact_texture]. Until then a procedural fallback
## texture is generated, so impacts work out of the box.

const FALLBACK_SIZE := 64
const PROJECTION_DEPTH := 0.35
const SURFACE_OFFSET := 0.015

var _texture: Texture2D
var _hole_size: float = 0.12
var _lifetime: float = 25.0
var _pool: Array[Decal] = []
var _ages: Array[float] = []
var _cursor: int = 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()


## (Re)builds the pool. Called once by the weapon manager.
func configure(texture: Texture2D, hole_size: float, lifetime: float, max_decals: int) -> void:
	_texture = texture if texture != null else _make_fallback_texture()
	_hole_size = maxf(hole_size, 0.01)
	_lifetime = lifetime
	for child in _pool:
		child.queue_free()
	_pool.clear()
	_ages.clear()
	_cursor = 0
	for i in maxi(max_decals, 1):
		var decal := Decal.new()
		decal.name = "Impact%d" % i
		decal.top_level = true
		decal.visible = false
		decal.texture_albedo = _texture
		decal.size = Vector3(_hole_size, _hole_size, PROJECTION_DEPTH)
		add_child(decal)
		_pool.append(decal)
		_ages.append(INF)


## Pins a bullet hole onto the surface at [param position] facing [param normal].
func spawn_impact(position: Vector3, normal: Vector3) -> void:
	if _pool.is_empty():
		return
	var n := normal.normalized() if normal.length_squared() > 0.000001 else Vector3.UP
	var up := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var basis := Basis.looking_at(-n, up) * Basis(Vector3.BACK, _rng.randf() * TAU)
	var slot := _cursor
	_cursor = (_cursor + 1) % _pool.size()
	var decal := _pool[slot]
	decal.global_transform = Transform3D(basis, position + n * SURFACE_OFFSET)
	decal.modulate = Color(1, 1, 1, 1)
	decal.visible = true
	_ages[slot] = 0.0 if _lifetime > 0.0 else -1.0


## Hides every hole immediately.
func clear() -> void:
	for i in _pool.size():
		_pool[i].visible = false
		_ages[i] = INF


## How many holes are currently visible. Handy for tests.
func active_count() -> int:
	var count := 0
	for decal in _pool:
		if decal.visible:
			count += 1
	return count


func _process(delta: float) -> void:
	if _lifetime <= 0.0:
		return
	var fade := minf(2.0, _lifetime * 0.25)
	for i in _pool.size():
		if not _pool[i].visible or _ages[i] < 0.0:
			continue
		_ages[i] += delta
		if _ages[i] >= _lifetime:
			_pool[i].visible = false
			_ages[i] = INF
		elif _ages[i] > _lifetime - fade:
			var colour := _pool[i].modulate
			colour.a = 1.0 - (_ages[i] - (_lifetime - fade)) / fade
			_pool[i].modulate = colour


## Dark scorched blotch with a feathered rim, used until a real PNG is assigned.
func _make_fallback_texture() -> Texture2D:
	var image := Image.create(FALLBACK_SIZE, FALLBACK_SIZE, false, Image.FORMAT_RGBA8)
	var center := Vector2(FALLBACK_SIZE, FALLBACK_SIZE) * 0.5
	var radius := float(FALLBACK_SIZE) * 0.5
	for y in FALLBACK_SIZE:
		for x in FALLBACK_SIZE:
			var dist := Vector2(x + 0.5, y + 0.5).distance_to(center) / radius
			var alpha := clampf(1.0 - dist, 0.0, 1.0)
			alpha = alpha * alpha
			var shade := 0.02 + 0.05 * dist
			image.set_pixel(x, y, Color(shade, shade, shade * 1.1, alpha))
	return ImageTexture.create_from_image(image)
