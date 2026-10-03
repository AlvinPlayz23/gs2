class_name WeaponHud
extends CanvasLayer
## Draws the weapon readout: current weapon, ammo, handling state and the
## context-sensitive pickup prompt.
##
## Listens to [WeaponManager] signals rather than polling, so it stays cheap and
## automatically correct for any weapon.

## The weapon manager to report on. Defaults to the sibling node.
@export var manager_path: NodePath = ^"../WeaponManager"
@export var weapon_label_path: NodePath = ^"Weapon"
@export var ammo_label_path: NodePath = ^"Ammo"
@export var state_label_path: NodePath = ^"State"
@export var prompt_label_path: NodePath = ^"Prompt"

var _manager: WeaponManager
var _weapon_label: Label
var _ammo_label: Label
var _state_label: Label
var _prompt_label: Label


func _ready() -> void:
	_manager = get_node_or_null(manager_path) as WeaponManager
	_weapon_label = get_node_or_null(weapon_label_path) as Label
	_ammo_label = get_node_or_null(ammo_label_path) as Label
	_state_label = get_node_or_null(state_label_path) as Label
	_prompt_label = get_node_or_null(prompt_label_path) as Label
	if _manager == null:
		push_warning("WeaponHud could not find its WeaponManager at '%s'." % manager_path)
		return
	_manager.weapon_changed.connect(_on_weapon_changed)
	_manager.ammo_changed.connect(_on_ammo_changed)
	_manager.state_changed.connect(_on_state_changed)
	_manager.fired.connect(_on_ammo_changed)
	_refresh_all()


func _process(_delta: float) -> void:
	if _manager == null or _prompt_label == null:
		return
	# The prompt depends on what is under the player's nose right now, so it is
	# polled rather than event driven.
	var pickup := _manager.nearby_pickup()
	_prompt_label.text = "[%s] %s" % [_use_key_text(), pickup.prompt_text()] if pickup != null else ""


func _refresh_all() -> void:
	_on_weapon_changed(_manager.current_state())
	_on_ammo_changed(_manager.current_state())
	_on_state_changed(_manager.state)


func _on_weapon_changed(state: WeaponState) -> void:
	if _weapon_label == null:
		return
	if state == null:
		_weapon_label.text = "UNARMED"
		return
	_weapon_label.text = "%s  [%s]" % [
		state.data.display_name.to_upper(),
		WeaponData.Slot.keys()[state.data.slot],
	]


func _on_ammo_changed(state: WeaponState) -> void:
	if _ammo_label == null:
		return
	if state == null:
		_ammo_label.text = ""
		return
	_ammo_label.text = "%d / %d" % [state.ammo_in_magazine, state.reserve_ammo]


func _on_state_changed(new_state: int) -> void:
	if _state_label == null:
		return
	if new_state == WeaponManager.State.IDLE:
		_state_label.text = ""
		return
	_state_label.text = WeaponManager.State.keys()[new_state]


## Human-readable name of the use key, read straight from the input map so the
## prompt stays correct if the binding is changed.
func _use_key_text() -> String:
	for event in InputMap.action_get_events("use"):
		if event is InputEventKey:
			return OS.get_keycode_string(event.physical_keycode)
	return "E"