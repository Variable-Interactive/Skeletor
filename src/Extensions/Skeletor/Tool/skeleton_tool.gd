extends VBoxContainer

enum {NONE, OFFSET, ROTATE, SCALE}  ## same as the one in SkeletonGizmo class

var api: Node
var tool_slot
var cursor_text := ""
var skeleton_preview: Node2D
var prev_mouse_position := Vector2.INF
var is_transforming := false

@onready var rotation_reset_menu: MenuButton = $RotationReset
@onready var quick_set_bones_menu: MenuButton = $QuickSetBones


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
	rotation_reset_menu.get_popup().id_pressed.connect(reset_bone_angle)
	quick_set_bones_menu.get_popup().id_pressed.connect(quick_set_bones)


func _exit_tree() -> void:
	if skeleton_preview:
		skeleton_preview.announce_removal(self)
		skeleton_preview.queue_redraw()


func draw_start(_pos: Vector2i) -> void:
	if !skeleton_preview:
		return
	# If this tool is on both sides then only allow one at a time
	if skeleton_preview.transformation_active:
		return
	skeleton_preview.transformation_active = true
	is_transforming = true
	var mouse_point: Vector2 = api.general.get_canvas().current_pixel
	var gizmo = skeleton_preview.selected_gizmo
	if !gizmo:
		return
	if gizmo.modify_mode == NONE:
		# When moving mouse we may stop hovering but we are still modifying that gizmo.
		# this is why we need a sepatate modify_mode variable
		gizmo.modify_mode = gizmo.hover_mode(mouse_point, api.general.get_global().camera.zoom)
	if prev_mouse_position == Vector2.INF:
		prev_mouse_position = mouse_point


func draw_move(_pos: Vector2i) -> void:
	# Another tool is already active
	if not is_transforming:
		return
	if !skeleton_preview:
		return
	# We need mouse_point to be a Vector2 in order for rotation to work properly
	var mouse_point: Vector2 = api.general.get_canvas().current_pixel
	var offset := mouse_point - prev_mouse_position
	var gizmo = skeleton_preview.selected_gizmo
	if gizmo.modify_mode == OFFSET:
		if Input.is_key_pressed(KEY_CTRL):
			skeleton_preview.ignore_render_once = true
			gizmo.gizmo_origin += offset.rotated(-gizmo.bone_rotation)
			gizmo.start_point = Vector2i(gizmo.rel_to_origin(mouse_point))
		else:
			gizmo.start_point = gizmo.rel_to_origin(mouse_point)
	elif (
		gizmo.modify_mode == ROTATE
		or gizmo.modify_mode == SCALE
	):
		var localized_mouse_norm: Vector2 = gizmo.rel_to_start_point(mouse_point).normalized()
		var localized_prev_mouse_norm: Vector2 = gizmo.rel_to_start_point(prev_mouse_position).normalized()
		var diff := localized_mouse_norm.angle_to(localized_prev_mouse_norm)
		if Input.is_key_pressed(KEY_CTRL):
			skeleton_preview.ignore_render_once = true
			gizmo.gizmo_rotate_origin -= diff
			if gizmo.modify_mode == SCALE:
				gizmo.gizmo_length = gizmo.rel_to_start_point(mouse_point).length()
		else:
			gizmo.bone_rotation -= diff
	prev_mouse_position = mouse_point
	#skeleton_preview.generate_pose()  ## Uncomment me for live update


func draw_end(_pos: Vector2i) -> void:
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
	prev_mouse_position = Vector2.INF


func quick_set_bones(bone_id: int):
	if skeleton_preview:
		var bone_names = Array()
		if bone_id == 0: # All bones
			bone_names = skeleton_preview.current_frame_bones.keys()
		else:
			bone_names.append(quick_set_bones_menu.get_popup().get_item_text(bone_id))
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


func reset_bone_angle(bone_id: int):
	## This rotation will also rotate the child bones as the parent bone's angle is changed.
	var bone_names = Array()
	if bone_id == 0: # All bones
		bone_names = skeleton_preview.current_frame_bones.keys()
	else:
		bone_names.append(rotation_reset_menu.get_popup().get_item_text(bone_id))
	for bone_name in bone_names:
		if bone_name in skeleton_preview.current_frame_bones.keys():
			skeleton_preview.current_frame_bones[bone_name].bone_rotation = 0
	skeleton_preview.queue_redraw()
	skeleton_preview.generate_pose()


func _on_rotation_reset_menu_about_to_popup() -> void:
	if skeleton_preview:
		populate_popup(rotation_reset_menu.get_popup())


func _on_quick_set_bones_menu_about_to_popup() -> void:
	if skeleton_preview:
		populate_popup(quick_set_bones_menu.get_popup())


func populate_popup(popup: PopupMenu):
	popup.clear()
	if skeleton_preview.current_frame_bones.is_empty():
		return
	popup.add_item("All Bones")
	for bone_name in skeleton_preview.current_frame_bones.keys():
		popup.add_item(bone_name)


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
