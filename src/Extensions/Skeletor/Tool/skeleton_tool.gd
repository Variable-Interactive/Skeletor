extends VBoxContainer

enum {NONE, DISPLACE, ROTATE, SCALE}  ## same as the one in SkeletonGizmo class
var api: Node
var tool_slot
var kname: String
var cursor_text := ""
var skeleton_manager: Node2D
var is_transforming := false
var generation_threshold: float = 20
var live_thread := Thread.new()

var _live_update := false
var _allow_chaining := false
var _include_children := true
var _displace_offset := Vector2.ZERO
var _prev_mouse_position := Vector2.INF
var _distance_to_parent: float = 0
var _chained_gizmo = null

@onready var quick_set_bones_menu: MenuButton = $QuickSetBones
@onready var rotation_reset_menu: MenuButton = $RotationReset
@onready var position_reset_menu: MenuButton = $PositionReset
@onready var copy_pose_from: MenuButton = $CopyPoseFrom
@onready var tween_skeleton_menu: MenuButton = $TweenSkeleton


func _ready() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	if api:
		skeleton_manager = api.general.get_canvas().find_child("SkeletonPreview", false, false)
		if skeleton_manager:
			skeleton_manager.active_skeleton_tools.append(self)
			skeleton_manager.queue_redraw()
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


func _on_warn_pressed() -> void:
	var warn_text = """
To avoid any quirky behavior, it is recomended to not tween between
large rotations, and have "Include bone children" enabled.
"""
	api.dialog.show_error(warn_text)


func load_config() -> void:
	var value = api.general.get_global().config_cache.get_value(tool_slot.kname, kname, {})
	set_config(value)
	update_config()


func get_config() -> Dictionary:
	var config :Dictionary
	config["live_update"] = _live_update
	config["allow_chaining"] = _allow_chaining
	config["include_children"] = _include_children
	return config


func set_config(config: Dictionary) -> void:
	_live_update = config.get("live_update", _live_update)
	_allow_chaining = config.get("allow_chaining", _allow_chaining)
	_include_children = config.get("include_children", _include_children)


func update_config() -> void:
	%LiveUpdateCheckbox.button_pressed = _live_update
	%AllowChaining.button_pressed = _allow_chaining
	%IncludeChildrenCheckbox.button_pressed = _include_children
	if skeleton_manager:
		skeleton_manager.bones_chained = _allow_chaining
		skeleton_manager.queue_redraw()


func save_config() -> void:
	var config := get_config()
	api.general.get_global().config_cache.set_value(tool_slot.kname, kname, config)


func _exit_tree() -> void:
	if skeleton_manager:
		skeleton_manager.announce_tool_removal(self)
		skeleton_manager.queue_redraw()


func draw_start(_pos: Vector2i) -> void:
	if !skeleton_manager:
		return
	# If this tool is on both sides then only allow one at a time
	if skeleton_manager.transformation_active:
		return
	skeleton_manager.transformation_active = true
	is_transforming = true
	var gizmo = skeleton_manager.selected_gizmo
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
	# Check if bone is a parent of anything (skip if it is)
	if _allow_chaining and gizmo.parent_bone_name in skeleton_manager.current_frame_bones.keys():
		var parent_bone = skeleton_manager.current_frame_bones[gizmo.parent_bone_name]
		var bone_start: Vector2i = gizmo.rel_to_global(gizmo.start_point)
		var parent_start: Vector2i = parent_bone.rel_to_global(parent_bone.start_point)
		_distance_to_parent = bone_start.distance_to(parent_start)


func draw_move(_pos: Vector2i) -> void:
	# Another tool is already active
	if not is_transforming:
		return
	if !skeleton_manager:
		return
	# We need mouse_point to be a Vector2 in order for rotation to work properly.
	var mouse_point: Vector2 = api.general.get_canvas().current_pixel
	var offset := mouse_point - _prev_mouse_position
	var gizmo = skeleton_manager.selected_gizmo
	if !gizmo:
		return
	if _allow_chaining and gizmo.parent_bone_name in skeleton_manager.current_frame_bones.keys():
		match gizmo.modify_mode:  # This manages chaining
			DISPLACE:
				_chained_gizmo = gizmo
				gizmo = skeleton_manager.current_frame_bones[gizmo.parent_bone_name]
				gizmo.modify_mode = ROTATE
				skeleton_manager.selected_gizmo = gizmo
				_chained_gizmo.modify_mode = NONE
	if gizmo.modify_mode == DISPLACE:
		if Input.is_key_pressed(KEY_CTRL):
			skeleton_manager.ignore_render_once = true
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
			skeleton_manager.ignore_render_once = true
			gizmo.gizmo_rotate_origin -= diff
			if gizmo.modify_mode == SCALE:
				gizmo.gizmo_length = gizmo.rel_to_start_point(mouse_point).length()
		else:
			gizmo.bone_rotation -= diff
			if _allow_chaining and _chained_gizmo:
				_chained_gizmo.bone_rotation += diff
	if _live_update:
		if ProjectSettings.get_setting("rendering/driver/threads/thread_model") != 2:
			skeleton_manager.generate_pose()
		else:  # Multi-threaded mode (Currently pixelorama is single threaded)
			if not live_thread.is_alive():
				var error := live_thread.start(skeleton_manager.generate_pose)
				if error != OK:  # Thread failed, so do this the hard way.
					skeleton_manager.generate_pose()
	_prev_mouse_position = mouse_point


func draw_end(_pos: Vector2i) -> void:
	_prev_mouse_position = Vector2.INF
	_displace_offset = Vector2.ZERO
	_chained_gizmo = null
	if skeleton_manager:
		# Another tool is already active
		if not is_transforming:
			return
		is_transforming = false
		skeleton_manager.transformation_active = false
		var gizmo = skeleton_manager.selected_gizmo
		if gizmo:
			if gizmo.modify_mode != NONE:
				skeleton_manager.generate_pose()
				skeleton_manager.selected_gizmo.modify_mode = NONE
			if (
				_allow_chaining
				and gizmo.parent_bone_name in skeleton_manager.current_frame_bones.keys()
			):
				if gizmo.modify_mode == DISPLACE:
					skeleton_manager.current_frame_bones[gizmo.parent_bone_name].modify_mode = NONE


func quick_set_bones(bone_id: int):
	if skeleton_manager:
		var bone_names = get_selected_bone_names(quick_set_bones_menu.get_popup(), bone_id)
		var new_data = skeleton_manager.current_frame_data.duplicate(true)
		for layer_idx: int in api.project.current_project.layers.size():
			var bone_name: StringName = api.project.current_project.layers[layer_idx].name
			if bone_name in bone_names:
				new_data[bone_name] = skeleton_manager.current_frame_bones[bone_name].reset_bone(
					{"gizmo_origin": Vector2(skeleton_manager.get_best_origin(layer_idx))}
				)
		skeleton_manager.current_frame_data = new_data
		skeleton_manager.save_frame_info(api.project.current_project)
		skeleton_manager.queue_redraw()
		skeleton_manager.generate_pose()


func copy_bone_data(bone_id: int, from_frame: int, popup: PopupMenu, old_current_frame: int):
	if skeleton_manager:
		if old_current_frame != skeleton_manager.current_frame:
			return
		var bone_names := get_selected_bone_names(popup, bone_id)
		var new_data = skeleton_manager.current_frame_data.duplicate(true)
		var copy_data: Dictionary = skeleton_manager.load_frame_info(
			api.project.current_project, from_frame
		)
		for bone_name in bone_names:
			if bone_name in skeleton_manager.current_frame_bones.keys():
				new_data[bone_name] = skeleton_manager.current_frame_bones[bone_name].reset_bone(
					copy_data.get(bone_name, {})
				)
		skeleton_manager.current_frame_data = new_data
		skeleton_manager.save_frame_info(api.project.current_project)
		skeleton_manager.queue_redraw()
		skeleton_manager.generate_pose()
		copy_pose_from.get_popup().hide()
		copy_pose_from.get_popup().clear(true)  # To save Memory


func tween_skeleton_data(bone_id: int, from_frame: int, popup: PopupMenu, current_frame: int):
	if skeleton_manager:
		if current_frame != skeleton_manager.current_frame:
			return
		var bone_names := get_selected_bone_names(popup, bone_id)
		var start_data: Dictionary = skeleton_manager.load_frame_info(
			api.project.current_project, from_frame
		)
		var end_data: Dictionary = skeleton_manager.load_frame_info(
			api.project.current_project, current_frame
		)
		for frame_idx in range(from_frame + 1, current_frame):
			var frame_info: Dictionary = skeleton_manager.load_frame_info(
				api.project.current_project, frame_idx
			)
			for bone_name in bone_names:
				if (
					bone_name in frame_info.keys()
					and bone_name in start_data.keys()
					and bone_name in end_data.keys()
				):
					var bone_dict: Dictionary = frame_info[bone_name]
					for data_key: String in bone_dict.keys():
						if typeof(bone_dict[data_key]) != TYPE_STRING:
							bone_dict[data_key] = Tween.interpolate_value(
								start_data[bone_name][data_key],
								end_data[bone_name][data_key] - start_data[bone_name][data_key],
								frame_idx - from_frame,
								current_frame - from_frame,
								Tween.TRANS_LINEAR,
								Tween.EASE_IN
							)
			skeleton_manager.save_frame_info(api.project.current_project, frame_info, frame_idx)
			skeleton_manager.generate_pose(frame_idx)
		copy_pose_from.get_popup().hide()
		copy_pose_from.get_popup().clear(true)  # To save Memory


func reset_bone_angle(bone_id: int):
	## This rotation will also rotate the child bones as the parent bone's angle is changed.
	var bone_names := get_selected_bone_names(rotation_reset_menu.get_popup(), bone_id)
	for bone_name in bone_names:
		if bone_name in skeleton_manager.current_frame_bones.keys():
			skeleton_manager.current_frame_bones[bone_name].bone_rotation = 0
	skeleton_manager.queue_redraw()
	skeleton_manager.generate_pose()


func reset_bone_position(bone_id: int):
	## This rotation will also rotate the child bones as the parent bone's angle is changed.
	var bone_names := get_selected_bone_names(position_reset_menu.get_popup(), bone_id)
	for bone_name in bone_names:
		if bone_name in skeleton_manager.current_frame_bones.keys():
			skeleton_manager.current_frame_bones[bone_name].start_point = Vector2.ZERO
	skeleton_manager.queue_redraw()
	skeleton_manager.generate_pose()


func _on_quick_set_bones_menu_about_to_popup() -> void:
	if skeleton_manager:
		populate_popup(quick_set_bones_menu.get_popup())


func _on_rotation_reset_menu_about_to_popup() -> void:
	if skeleton_manager:
		populate_popup(rotation_reset_menu.get_popup(), {"bone_rotation": 0})


func _on_position_reset_menu_about_to_popup() -> void:
	if skeleton_manager:
		populate_popup(position_reset_menu.get_popup(), {"start_point": Vector2.ZERO})


func _on_copy_pose_from_about_to_popup() -> void:
	var popup := copy_pose_from.get_popup()
	popup.clear(true)
	for frame_idx in api.project.current_project.frames.size():
		if skeleton_manager.current_frame == frame_idx:
			continue
		var popup_submenu = PopupMenu.new()
		populate_popup(popup_submenu)
		popup.add_submenu_node_item(str("Frame ", frame_idx + 1), popup_submenu)
		popup_submenu.id_pressed.connect(
			copy_bone_data.bind(frame_idx, popup_submenu, skeleton_manager.current_frame)
		)

func _on_tween_skeleton_about_to_popup() -> void:
	var popup := tween_skeleton_menu.get_popup()
	var project = api.project.current_project
	popup.clear(true)
	popup.add_separator("Start From")
	var reference_point_data: Dictionary = skeleton_manager.current_frame_data
	for frame_idx in api.project.current_project.frames.size():
		if frame_idx >= skeleton_manager.current_frame - 1:
			break
		var frame_data: Dictionary = skeleton_manager.load_frame_info(project, frame_idx)
		if (
			frame_data != skeleton_manager.current_frame_data
		):
			if reference_point_data != frame_data:
				reference_point_data = frame_data
				var popup_submenu = PopupMenu.new()
				populate_popup(popup_submenu)
				popup.add_submenu_node_item(str("Frame ", frame_idx + 1), popup_submenu)
				popup_submenu.id_pressed.connect(
					tween_skeleton_data.bind(frame_idx, popup_submenu, skeleton_manager.current_frame)
				)

func _on_include_children_checkbox_toggled(toggled_on: bool) -> void:
	_include_children = toggled_on
	update_config()
	save_config()


func _on_allow_chaining_toggled(toggled_on: bool) -> void:
	_allow_chaining = toggled_on
	update_config()
	save_config()


func _on_live_update_pressed(toggled_on: bool) -> void:
	_live_update = toggled_on
	update_config()
	save_config()


func populate_popup(popup: PopupMenu, reset_properties := {}):
	popup.clear()
	if skeleton_manager.group_names_ordered.is_empty():
		return
	popup.add_item("All Bones")
	var items_added_after_prev_separator := true
	for bone_key in skeleton_manager.group_names_ordered:
		if bone_key in skeleton_manager.current_frame_bones.keys():
			var bone = skeleton_manager.current_frame_bones[bone_key]
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
	var frame_bones: Array = skeleton_manager.group_names_ordered
	var bone_names = PackedStringArray()
	if bone_id == 0: # All bones
		bone_names = frame_bones
	else:
		var bone_name: String = popup.get_item_text(bone_id)
		bone_names.append(bone_name)
		if _include_children:
			for bone_key: String in frame_bones:
				if bone_key in skeleton_manager.current_frame_bones.keys():
					var bone = skeleton_manager.current_frame_bones[bone_key]
					if bone.parent_bone_name in bone_names:
						bone_names.append(bone.bone_name)
	return bone_names


## This manages the hovering mechanism of gizmo
func cursor_move(pos: Vector2i) -> void:
	var global = api.general.get_global()
	if skeleton_manager.selected_gizmo:  # Check if we are still hovering over the same gizmo
		if (
			skeleton_manager.selected_gizmo.hover_mode(pos, global.camera.zoom) == NONE
			and skeleton_manager.selected_gizmo.modify_mode == NONE
		):
			skeleton_manager.selected_gizmo = null
	if !skeleton_manager.selected_gizmo:  # If in the prevoius check we deselected the gizmo then search for a new one.
		for bone in skeleton_manager.current_frame_bones.values():
			if (
				bone.hover_mode(pos, global.camera.zoom) != NONE
				or bone.modify_mode != NONE
			):
				var skip_gizmo := false
				if (
					_allow_chaining
					and (
						bone.modify_mode == ROTATE
						or bone.hover_mode(pos, global.camera.zoom) == ROTATE
						)
				):
					# Check if bone is a parent of anything (if it has, skip it)
					for other_gizmo in skeleton_manager.current_frame_bones.values():
						if other_gizmo.bone_name == bone.parent_bone_name:
							skip_gizmo = true
							break
				if skip_gizmo:
					continue
				skeleton_manager.selected_gizmo = bone
				skeleton_manager.update_frame_data()
				break
		skeleton_manager.queue_redraw()


## Placeholder functions that are a necessity to be here
func draw_indicator(_left: bool) -> void:
	return
func draw_preview() -> void:
	pass
