class_name Hitbox
extends Area3D
## A shootable region belonging to a [Damageable].
##
## Add one of these wherever a body part should take different damage - a head
## sphere with [member damage_multiplier] of 2.0, for example. The weapon ray is
## traced with [code]collide_with_areas = true[/code], so hitboxes are hit before
## any body collider behind them.
##
## The parent [Damageable] is found automatically by walking up the tree, so in
## the usual case you only need to set [member damage_multiplier].

## Multiplier applied to incoming damage. 1.0 is a body shot, 2.0 a headshot.
@export_range(0.0, 20.0, 0.05) var damage_multiplier: float = 1.0
## Optional explicit link to the [Damageable]. Left empty, the first ancestor
## that is a [Damageable] is used.
@export var damageable_path: NodePath
## When true the hitbox stops forwarding damage once its target has died.
@export var ignore_when_dead: bool = true
## Labelled in the hit info so tests and HUDs can tell which region was struck.
@export var hitbox_name: String = "body"

var damageable: Damageable


func _ready() -> void:
	damageable = _resolve_damageable()
	if damageable == null:
		push_warning("Hitbox '%s' could not find a Damageable ancestor." % name)


## Forwards damage to the owning [Damageable], scaled by this hitbox's
## multiplier. Called by the weapon's hitscan.
func apply_damage(amount: float, info: Dictionary = {}) -> void:
	if damageable == null:
		damageable = _resolve_damageable()
	if damageable == null:
		return
	if ignore_when_dead and not damageable.is_alive():
		return
	var scaled := amount * damage_multiplier
	info["hitbox"] = hitbox_name
	info["hitbox_multiplier"] = damage_multiplier
	damageable.apply_damage(scaled, info)


func _resolve_damageable() -> Damageable:
	if not damageable_path.is_empty():
		var linked := get_node_or_null(damageable_path)
		if linked is Damageable:
			return linked
	var node := get_parent()
	while node != null:
		if node is Damageable:
			return node
		node = node.get_parent()
	return null