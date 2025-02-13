extends VBoxContainer

enum {NONE, DISPLACE, ROTATE, SCALE}  ## same as the one in SkeletonGizmo class
## every draw_move there is (value)% posibility of pose generation
const MAX_GENERATION_FREQ_PERCENT = 70
var api: Node
var tool_slot
var kname: String
var cursor_text := ""
var skeleton_preview: Node2D
var is_transforming := false
var generation_threshold: float = 20
var live_thread := Thread.new()

var _live_update := true
var _include_children := false
var _generation_count: float = 0
var _interval_count: int = 0
var _displace_offset := Vector2.ZERO
var _prev_mouse_position := Vector2.INF

@onready var quick_set_bones_menu: MenuButton = $QuickSetBones
@onready var rotation_reset_menu: MenuButton = $RotationReset
@onready var position_reset_menu: MenuButton = $PositionReset
@onready var copy_pose_from: MenuButton = $CopyPoseFrom


func _ready() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	if api:
		skeleton_preview = api.general.get_canvas().find_child("SkeletonPreview", false, false)
		if skeleton_preview:
			skeleton_preview.active_skeleton_tools.append(self)
			skeleton_preview.queue_redraw()
		if tool_slot.name == "Left tool":
			$ColorRect.color = api.general.get_global().left_tool_color
		else:
			$ColorRect.color = api.general.get_global().right_tool_color
		$Label.text = "Skeleton Options"
	quick_set_bones_menu.get_popup().id_pressed.connect(quick_set_bones)
	rotation_reset_menu.get_popup().id_pressed.connect(reset_bone_angle)
	position_reset_menu.get_popup().id_pressed.connect(reset_bone_position)
	kname = name.replace(" ", "_").to_lower()
	load_config()


func load_config() -> void:
	var value = api.general.get_global().config_cache.get_value(tool_slot.kname, kname, {})
	set_config(value)
	update_config()


func get_config() -> Dictionary:
	var config :Dictionary
	config["live_update"] = _live_update
	config["include_children"] = _include_children
	return config


func set_config(config: Dictionary) -> void:
	_live_update = config.get("live_update", _live_update)
	_include_children = config.get("include_children", _include_children)


func update_config() -> void:
	%LiveUpdateCheckbox.button_pressed = _live_update
	%IncludeChildrenCheckbox.button_pressed = _include_children


func save_config() -> void:
	var config := get_config()
	api.general.get_global().config_cache.set_value(tool_slot.kname, kname, config)


func _exit_tree() -> void:
	if skeleton_preview:
		skeleton_preview.announce_tool_removal(self)
		skeleton_preview.queue_redraw()


func draw_start(_pos: Vector2i) -> void:
	if !skeleton_preview:
		return
	# If this tool is on both sides then only allow one at a time
	if skeleton_preview.transformation_active:
		return
	skeleton_preview.transformation_active = true
	is_transforming = true
	var gizmo = skeleton_preview.selected_gizmo
	var mouse_point: Vector2 = api.general.get_canvas().current_pixel
	if !gizmo:
		return
	if gizmo.modify_mode == NONE:
		# When moving mouse we may stop hovering but we are still modifying that gizmo.
		# this is why we need a sepatate modify_mode variable
		gizmo.modify_mode = gizmo.hover_mode(
			Vector2(mouse_point), api.general.get_global().camera.zoom
		)
	if _prev_mouse_position == Vector2.INF:
		_displace_offset = gizmo.rel_to_start_point(mouse_point)
		_prev_mouse_position = mouse_point
	_generation_count = 0
	_interval_count = 0


func draw_move(_pos: Vector2i) -> void:
	# Another tool is already active
	if not is_transforming:
		return
	if !skeleton_preview:
		return
	# We need mouse_point to be a Vector2 in order for rotation to work properly.
	var mouse_point: Vector2 = api.general.get_canvas().current_pixel
	var offset := mouse_point - _prev_mouse_position
	var gizmo = skeleton_preview.selected_gizmo
	if !gizmo:
		return
	if gizmo.modify_mode == DISPLACE:
		if Input.is_key_pressed(KEY_CTRL):
			skeleton_preview.ignore_render_once = true
			gizmo.gizmo_origin += offset.rotated(-gizmo.bone_rotation)
		gizmo.start_point = Vector2i(gizmo.rel_to_origin(mouse_point) - _displace_offset)
	elif (
		gizmo.modify_mode == ROTATE
		or gizmo.modify_mode == SCALE
	):
		var localized_mouse_norm: Vector2 = gizmo.rel_to_start_point(mouse_point).normalized()
		var localized_prev_mouse_norm: Vector2 = gizmo.rel_to_start_point(
			_prev_mouse_position
		).normalized()
		var diff := localized_mouse_norm.angle_to(localized_prev_mouse_norm)
		if Input.is_key_pressed(KEY_CTRL):
			skeleton_preview.ignore_render_once = true
			gizmo.gizmo_rotate_origin -= diff
			if gizmo.modify_mode == SCALE:
				gizmo.gizmo_length = gizmo.rel_to_start_point(mouse_point).length()
		else:
			gizmo.bone_rotation -= diff
	if _live_update:
		# A Smart system to optimize generation frequency
		if _interval_count >= 10:
			var max_updates_allowed = float(MAX_GENERATION_FREQ_PERCENT) / 10
			if (_generation_count) < max_updates_allowed:
				# Low generation counts detected, likely because user doesn't care about
				# small movements. Assist by decreasing the frequency further
				generation_threshold -= 0.5 * (_generation_count - max_updates_allowed)
			else:
				# High generation counts detected, likely because user cares about
				# small movements. Assist by increasing the frequency further
				generation_threshold += 0.5 * (max_updates_allowed - _generation_count)
			generation_threshold = clampf(generation_threshold, 1, 20)
			_generation_count = 0
			_interval_count = 0
		if ProjectSettings.get_setting("rendering/driver/threads/thread_model") != 2:
			# Generate Image if we are moving slower than generation_threshold
			if (mouse_point - _prev_mouse_position).length() <= generation_threshold:
				_generation_count += 1
				skeleton_preview.generate_pose()
			else:  # This may seem trivial but it's actually important
				skeleton_preview.generate_timer.start()
		else:  # Multi-threaded mode (Currently pixelorama is single threaded)
			if not live_thread.is_alive():
				var error := live_thread.start(skeleton_preview.generate_pose)
				if error != OK:  # Thread failed, so do this the hard way.
					# Generate Image if we are moving slower than generation_threshold
					if (mouse_point - _prev_mouse_position).length() <= generation_threshold:
						_generation_count += 1
						skeleton_preview.generate_pose()
					else:  # This may seem trivial but it's actually important
						# NOTE: We don't need _generation_count here.
						skeleton_preview.generate_timer.start()
		_interval_count += 1
	_prev_mouse_position = mouse_point


func draw_end(_pos: Vector2i) -> void:
	_prev_mouse_position = Vector2.INF
	_displace_offset = Vector2.ZERO
	if skeleton_preview:
		# Another tool is already active
		if not is_transforming:
			return
		is_transforming = false
		skeleton_preview.transformation_active = false
		if skeleton_preview.selected_gizmo:
			if skeleton_preview.selected_gizmo.modify_mode != NONE:
				skeleton_preview.generate_pose()
				skeleton_preview.selected_gizmo.modify_mode = NONE


func quick_set_bones(bone_id: int):
	if skeleton_preview:
		var bone_names = get_selected_bone_names(quick_set_bones_menu.get_popup(), bone_id)
		var new_data = skeleton_preview.current_frame_data.duplicate(true)
		for layer_idx: int in api.project.current_project.layers.size():
			var bone_name: StringName = api.project.current_project.layers[layer_idx].name
			if bone_name in bone_names:
				new_data[bone_name] = skeleton_preview.current_frame_bones[bone_name].reset_bone(
					{"gizmo_origin": Vector2(skeleton_preview.get_best_origin(layer_idx))}
				)
		skeleton_preview.current_frame_data = new_data
		skeleton_preview.save_frame_info(api.project.current_project)
		skeleton_preview.queue_redraw()
		skeleton_preview.generate_pose()


func copy_bone_data(bone_id: int, from_frame: int, popup: PopupMenu, old_current_frame: int):
	if skeleton_preview:
		if old_current_frame != skeleton_preview.current_frame:
			return
		var bone_names := get_selected_bone_names(popup, bone_id)
		var new_data = skeleton_preview.current_frame_data.duplicate(true)
		var copy_data: Dictionary = skeleton_preview.load_frame_info(
			api.project.current_project, from_frame
		)
		for bone_name in bone_names:
			if bone_name in skeleton_preview.current_frame_bones.keys():
				new_data[bone_name] = skeleton_preview.current_frame_bones[bone_name].reset_bone(
					copy_data.get(bone_name, {})
				)
		skeleton_preview.current_frame_data = new_data
		skeleton_preview.save_frame_info(api.project.current_project)
		skeleton_preview.queue_redraw()
		skeleton_preview.generate_pose()
		copy_pose_from.get_popup().hide()
		copy_pose_from.get_popup().clear(true)  # To save Memory


func reset_bone_angle(bone_id: int):
	## This rotation will also rotate the child bones as the parent bone's angle is changed.
	var bone_names := get_selected_bone_names(rotation_reset_menu.get_popup(), bone_id)
	for bone_name in bone_names:
		if bone_name in skeleton_preview.current_frame_bones.keys():
			skeleton_preview.current_frame_bones[bone_name].bone_rotation = 0
	skeleton_preview.queue_redraw()
	skeleton_preview.generate_pose()


func reset_bone_position(bone_id: int):
	## This rotation will also rotate the child bones as the parent bone's angle is changed.
	var bone_names := get_selected_bone_names(position_reset_menu.get_popup(), bone_id)
	for bone_name in bone_names:
		if bone_name in skeleton_preview.current_frame_bones.keys():
			skeleton_preview.current_frame_bones[bone_name].start_point = Vector2.ZERO
	skeleton_preview.queue_redraw()
	skeleton_preview.generate_pose()


func _on_quick_set_bones_menu_about_to_popup() -> void:
	if skeleton_preview:
		populate_popup(quick_set_bones_menu.get_popup())


func _on_rotation_reset_menu_about_to_popup() -> void:
	if skeleton_preview:
		populate_popup(rotation_reset_menu.get_popup(), {"bone_rotation": 0})


func _on_position_reset_menu_about_to_popup() -> void:
	if skeleton_preview:
		populate_popup(position_reset_menu.get_popup(), {"start_point": Vector2.ZERO})


func _on_copy_pose_from_about_to_popup() -> void:
	var popup := copy_pose_from.get_popup()
	popup.clear(true)
	for frame_idx in api.project.current_project.frames.size():
		if skeleton_preview.current_frame == frame_idx:
			continue
		var popup_submenu = PopupMenu.new()
		populate_popup(popup_submenu)
		popup.add_submenu_node_item(str("Frame ", frame_idx + 1), popup_submenu)
		popup_submenu.id_pressed.connect(
			copy_bone_data.bind(frame_idx, popup_submenu, skeleton_preview.current_frame)
		)


func _on_include_children_checkbox_toggled(toggled_on: bool) -> void:
	_include_children = toggled_on


func _on_live_update_pressed(toggled_on: bool) -> void:
	_live_update = toggled_on
	update_config()
	save_config()


func populate_popup(popup: PopupMenu, reset_properties := {}):
	popup.clear()
	if skeleton_preview.current_frame_bones.is_empty():
		return
	popup.add_item("All Bones")
	var items_added_after_prev_separator := true
	for bone in skeleton_preview.current_frame_bones.values():
		if bone.parent_bone_name == "" and items_added_after_prev_separator:  ## Root nodes
			popup.add_separator(str("Root:", bone.bone_name))
			items_added_after_prev_separator = false
		if reset_properties.is_empty():
			popup.add_item(bone.bone_name)
		else:
			for property: String in reset_properties.keys():
				if bone.get(property) != reset_properties[property]:
					popup.add_item(bone.bone_name)
					items_added_after_prev_separator = true
					break


func get_selected_bone_names(popup: PopupMenu, bone_id: int) -> PackedStringArray:
	var bone_names = PackedStringArray()
	if bone_id == 0: # All bones
		bone_names = skeleton_preview.current_frame_bones.keys()
	else:
		var bone_name: String = popup.get_item_text(bone_id)
		bone_names.append(bone_name)
		if _include_children:
			for bone in skeleton_preview.current_frame_bones.values():
				if bone.parent_bone_name in bone_names:
					bone_names.append(bone.bone_name)
	return bone_names


## This manages the hovering mechanism of gizmo
func cursor_move(pos: Vector2i) -> void:
	var global = api.general.get_global()
	if skeleton_preview.selected_gizmo:  # Check if we are still hovering over the same gizmo
		if (
			skeleton_preview.selected_gizmo.hover_mode(pos, global.camera.zoom) == NONE
			and skeleton_preview.selected_gizmo.modify_mode == NONE
		):
			skeleton_preview.selected_gizmo = null
	if !skeleton_preview.selected_gizmo:  # If in the prevoius check we deselected the gizmo then search for a new one.
		for bone in skeleton_preview.current_frame_bones.values():
			if (
				bone.hover_mode(pos, global.camera.zoom) != NONE
				or bone.modify_mode != NONE
			):
				skeleton_preview.selected_gizmo = bone
				skeleton_preview.update_frame_data()
				break
		skeleton_preview.queue_redraw()


## Placeholder functions that are a necessity to be here
func draw_indicator(_left: bool) -> void:
	return
func draw_preview() -> void:
	pass
