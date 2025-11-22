class_name BoneManager
extends Node2D

signal pose_layer_changed
@warning_ignore("unused_signal")
signal sync_ui  # Used by tools

var api: Node
var global: Node
var active_tool: Control
var hover_gizmo: SkeletonGizmo
var selected_gizmo: SkeletonGizmo:
	set(value):
		if selected_gizmo != value:
			selected_gizmo = value
			for tool_node in active_skeleton_tools:
				tool_node.display_props()
var group_names_ordered: PackedStringArray
## A Dictionary of bone names as keys and their "Gizmo" as values.
var current_frame_bones: Dictionary
## A Dictionary with Bone names as keys and their "Data Dictionary" as values.
var current_frame_data: Dictionary
var bones_chained := false
var current_frame: int = -1
var prev_layer_count: int = 0
var prev_frame_count: int = 0
var assign_pose_button_id: int
var queue_generate := false
# The shader is located in pixelorama
var blend_layer_shader = load("res://src/Shaders/BlendLayers.gdshader")
var pose_layer:  ## The layer in which a pose is rendered
	set(value):
		pose_layer = value
		assign_pose_layer(value)
		pose_layer_changed.emit()
var generation_cache: Dictionary
var active_skeleton_tools := Array()
var rotation_generator: RefCounted
var blend_generator: RefCounted


## These are Gizmo related methods, that for one reason or another can't be placed in the
## SkeletonGizmo class

## Checks if the bone's parent is a valid part of the skeleton
func is_bone_parent_valid(bone: SkeletonGizmo) -> bool:
	return bone.parent_bone_name in current_frame_bones.keys()

## If a propagatable property (movement, rotation) is done on a SkeletonGizmo object, this method
## Gets called automatically to update/transform all it's children automatically as well
func update_bone_property(
	parent_name: String, property: String, should_propagate: bool, diff, project
) -> void:
	if not is_instance_valid(project):
		return
	# First we update data of parent bone
	if current_frame_data.is_empty():
		current_frame_data = load_frame_info(project)
	if not parent_name in current_frame_data.keys():  # Failsafe, makes sure everything is in order.
		update_frame_data()
	var parent: SkeletonGizmo = current_frame_bones[parent_name]
	if parent.get(property) != current_frame_data[parent_name][property]:
		current_frame_data[parent_name][property] = parent.get(property)
	# Do not proceed further if a property isn't meant to propagate
	if !should_propagate:
		return
	for layer in project.layers:  ## update first child (This will trigger a chain process)
		if layer.get_layer_type() == global.LayerTypes.GROUP and layer.parent:
			if current_frame_bones[layer.name].parent_bone_name != layer.parent.name:
				current_frame_bones[layer.name].parent_bone_name = layer.parent.name
			if layer.parent.name == parent_name:
				if current_frame_bones.has(layer.name):
					var bone: SkeletonGizmo = current_frame_bones[layer.name]
					bone.set(property, bone.get(property) + diff)
					if current_frame_bones.has(parent_name) and property == "bone_rotation":
						var parent_bone: SkeletonGizmo = current_frame_bones[parent_name]
						var displacement := parent_bone.rel_to_start_point(
							bone.rel_to_canvas(bone.start_point)
						)
						displacement = displacement.rotated(diff)
						bone.start_point = bone.rel_to_origin(
							parent_bone.rel_to_canvas(parent_bone.start_point) + displacement
						)

## Default methods

func _ready() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	global = api.general.get_global()

	await get_tree().process_frame
	await get_tree().process_frame

	# Initialize the Shader Processors
	rotation_generator = api.general.get_new_shader_image_effect()
	blend_generator = api.general.get_new_shader_image_effect()
	# Add the "Assign Pose layer" menu button
	assign_pose_button_id = api.menu.add_menu_item(api.menu.PROJECT, "Assign Pose layer", self)
	# Connect the signals to currently open project
	manage_project_signals(true)
	# Connect signal to re-draw UI
	global.camera.zoom_changed.connect(queue_redraw)
	# Initialize signal managers
	global.project_about_to_switch.connect(manage_project_signals.bind(false))
	api.signals.signal_project_switched(manage_project_signals.bind(true))
	tree_exiting.connect(manage_ui_signals.bind(true))


func _exit_tree() -> void:
	api.menu.remove_menu_item(api.menu.PROJECT, assign_pose_button_id)
	global.project_about_to_switch.disconnect(manage_project_signals)
	api.signals.signal_project_switched(manage_project_signals, true)


func _input(event: InputEvent) -> void:
	var project = api.project.current_project
	if not pose_layer:
		return
	if not project.layers[pose_layer.index].locked:
		project.layers[pose_layer.index].locked = true

	## This manages the hovering mechanism of gizmo
	if (
		not is_pose_layer(project.layers[project.current_layer])
		or active_skeleton_tools.is_empty()
	):
		return
	var pos = global.canvas.current_pixel
	if hover_gizmo:  # Check if we are still hovering over the same gizmo
		# Clear the hover_gizmo if it's not being hovered or interacted with
		if (
			hover_gizmo.hover_mode(pos, global.camera.zoom) == SkeletonGizmo.NONE
			and hover_gizmo.modify_mode == SkeletonGizmo.NONE
		):
			hover_gizmo = null
		else:
			queue_redraw()
	if !hover_gizmo:  # If in the prevoius check we deselected the gizmo then search for a new one.
		if selected_gizmo and active_tool:
			# If a tool is actively using a bone then we don't need to calculate hovering
			return
		for bone: SkeletonGizmo in current_frame_bones.values():
			if bone.modify_mode != SkeletonGizmo.NONE and not bone == selected_gizmo:
				# Bones should only have an active modify_mode if it is the selected bone
				bone.modify_mode = SkeletonGizmo.NONE
			# Select the bone if it's being hovered or modified
			if (
				bone.hover_mode(pos, global.camera.zoom) != SkeletonGizmo.NONE
			):
				var skip_gizmo := false
				if (
					bones_chained
					and (
						bone.hover_mode(pos, global.camera.zoom) == SkeletonGizmo.ROTATE
					)
				):
					# In chaining mode, we only allow rotation (through gizmo) if it is
					# the last bone in the chain. Ignore bone if it is a parent of another bone
					for another_bone in current_frame_bones.values():
						if another_bone.parent_bone_name == bone.bone_name:
							skip_gizmo = true
							break
				if skip_gizmo:
					continue
				hover_gizmo = bone
				break
		queue_redraw()

	if (
		event.is_action_pressed(&"activate_left_tool")
		or event.is_action_pressed(&"activate_right_tool")
	):
		selected_gizmo = hover_gizmo


func _draw() -> void:
	if current_frame_data.is_empty():
		return
	if active_skeleton_tools.is_empty():
		return
	var project = api.project.current_project
	var group_names: Array = current_frame_data.keys()
	for bone_name: String in group_names:
		# before drawing the gizmo, we check if it needs update, or creation first
		if bone_name in current_frame_bones.keys():
			var bone = current_frame_bones[bone_name]
			bone.serialize(current_frame_data[bone_name])
			if not bone.update_property.is_connected(update_bone_property):
				bone.update_property.connect(update_bone_property.bind(project))
		else:
			var bone = SkeletonGizmo.new()
			bone.serialize(current_frame_data[bone_name])
			bone.update_property.connect(update_bone_property.bind(project))
			current_frame_bones[bone_name] = bone
	for bone_name: String in group_names:
		_draw_gizmo(current_frame_bones[bone_name], global.camera.zoom)


## Data Updaters (Directly responsible for values in current_frame_data)


## Cleans everything and starts from scratch
func reset_everything() -> void:
	selected_gizmo = null
	current_frame_data.clear()
	current_frame_bones.clear()
	current_frame = -1
	prev_layer_count = 0
	prev_frame_count = 0
	pose_layer = null


## Adds info about any new group cels that are added to the timeline.
func update_frame_data() -> void:
	var project = api.project.current_project
	if (
		# We moved to a different frame (or moved to the pose layer for the first time.
		# where we still don't yet know about a pose layer existing in the project)
		project.current_frame != current_frame
		# We added a new frame
		or project.frames.size() != prev_frame_count
	):
		prev_frame_count = project.frames.size()
		current_frame_bones.clear()
		selected_gizmo = null
		current_frame = project.current_frame
		current_frame_data = load_frame_info(project)
		# The if the frame is new, and there is a skeleton for previous frame then
		# copy it to this frame as well.
		if current_frame_data.is_empty() and current_frame != 0:
			# in cases where we added multiple frames, even the previous frame may not have data
			# so continue till we find one with data
			for frame_idx in range(current_frame, -1, -1):
				var prev_frame_data: Dictionary = load_frame_info(project, frame_idx)
				if not prev_frame_data.is_empty():
					current_frame_data = prev_frame_data.duplicate(true)
					break
	# If the layer is newly added then we need to refresh the bone tree.
	if project.layers.size() != prev_layer_count:
		prev_layer_count = project.layers.size()
		for frame in project.frames.size():
			if frame == current_frame:
				fix_skeleton_heirarchy(current_frame_data)
			else:  # Fix other frames for this missing data as well
				var frame_data := load_frame_info(project, frame)
				fix_skeleton_heirarchy(frame_data)
				save_frame_info(project, frame_data, frame)
	save_frame_info(project)


func fix_skeleton_heirarchy(data: Dictionary) -> void:
	var invalid_layer_names := data.keys()  # Initially treat all old names as invalid
	group_names_ordered.clear()
	for layer in api.project.current_project.layers:
		# Attempt to fix Pose Layer if it isn't present
		if !pose_layer and layer.get_layer_type() == global.LayerTypes.PIXEL:
			if "Pose Layer" in layer.name.capitalize():
				pose_layer = layer
		# Find names of all Group layers in order
		elif layer.get_layer_type() == global.LayerTypes.GROUP:
			group_names_ordered.insert(0, layer.name)
			invalid_layer_names.erase(layer.name)  # Layer is a valid Group Layer
			var parent_name = ""
			if layer.parent:
				parent_name = layer.parent.name
			if layer.name in data.keys():
				var real_parent_bone_name = data[layer.name].get("parent_bone_name", "")
				# If it's parent turns out to be different then it is an impostor
				# and we should change it's name. This is a crude methadology but it gets
				# the job done in most cases
				if parent_name != real_parent_bone_name:
					layer.name = get_valid_name(layer.name, data.keys())
			# A new Group layer is discovered. Catalogue it!
			if not layer.name in data.keys():
				data[layer.name] = SkeletonGizmo.generate_empty_data(layer.name, parent_name)

		# check connectivity of one of these signals and assume the result for others
		# (if one signal isn't connected, it's likely other signals aren't as well)
		if not layer.name_changed.is_connected(_on_layer_name_changed):
			if layer != pose_layer:
				if layer.get_layer_type() != global.LayerTypes.GROUP:
					layer.visibility_changed.connect(generate_pose)
				layer.effects_added_removed.connect(generate_pose)
				layer.name_changed.connect(_on_layer_name_changed.bind(layer, layer.name))
	for layer_name in invalid_layer_names:
		data.erase(layer_name)


func generate_pose(for_frame: int = current_frame) -> void:
	var project = api.project.current_project
	if not is_sane(project):  # There is no Pose Layer to render to!!!
		return
	if not pose_layer.visible:  # Pose Layer is invisible (So generating is a waste of time)
		return
	if for_frame == -1:  # for_frame is not defined
		return
	save_frame_info(project)
	manage_ui_signals(true)  # Trmporarily disconnect UI signals to prevent undesired effects
	var image = Image.create_empty(project.size.x, project.size.y, false, Image.FORMAT_RGBA8)
	if current_frame_data.is_empty():  # No pose to generate (This is a kind of failsafe)
		project.layers[pose_layer.index].locked = false
		_render_image(image)
		project.layers[pose_layer.index].locked = true
		manage_ui_signals()  # Reconnect signals
		return

	# Start generating
	# (Group visibility is completely ignored while the visibility of other layer types is respected)
	var frame = project.frames[for_frame]
	var previous_ordered_layers: Array[int] = project.ordered_layers
	project.order_layers(for_frame)
	var textures: Array[Image] = []
	# Nx4 texture, where N is the number of layers and the first row are the blend modes,
	# the second are the opacities, the third are the origins and the fourth are the
	# clipping mask booleans.
	var metadata_image := Image.create_empty(project.layers.size(), 4, false, Image.FORMAT_R8)
	for i in project.layers.size():
		var ordered_index = project.ordered_layers[i]
		var layer = project.layers[ordered_index]
		var group_layer = layer.parent
		# Ignore visibility for group layers
		var cel = frame.cels[ordered_index]
		var cel_image: Image
		if layer == pose_layer or not is_instance_valid(group_layer):
			_set_layer_metadata_image(layer, cel, metadata_image, ordered_index, false)
			continue

		var include := false if (
			!layer.visible and layer.get_layer_type() != global.LayerTypes.GROUP
		) else true
		if layer.is_blender():
			cel_image = layer.blend_children(frame)
		else:
			cel_image = layer.display_effects(cel)

		if is_instance_valid(group_layer):
			_apply_bone(group_layer.name, cel_image, for_frame)

		textures.append(cel_image)
		if (
			layer.is_blended_by_ancestor()
		):
			include = false
		_set_layer_metadata_image(layer, cel, metadata_image, ordered_index, include)

	var texture_array := Texture2DArray.new()
	if textures.is_empty():
		manage_ui_signals()
		return
	texture_array.create_from_images(textures)
	var params := {
		"layers": texture_array,
		"metadata": ImageTexture.create_from_image(metadata_image),
	}
	var blended := Image.create_empty(project.size.x, project.size.y, false, image.get_format())
	blend_generator.generate_image(blended, blend_layer_shader, params, project.size, true, false)
	image.blend_rect(blended, Rect2i(Vector2.ZERO, project.size), Vector2.ZERO)
	# Re-order the layers again to ensure correct canvas drawing
	project.ordered_layers = previous_ordered_layers
	project.layers[pose_layer.index].locked = false
	_render_image(image, for_frame)
	project.layers[pose_layer.index].locked = true
	manage_ui_signals()  # Reconnect signals


## Checks (boolean check used frequently throughout the script)


## Checks if the provided layer is a PoseLayer
func is_pose_layer(layer: RefCounted) -> bool:
	return layer.get_meta("SkeletorPoseLayer", false)


## This only searches for an "Existing" pose layer.
## The assignment of pose layers are done in update_frame_data()
func is_sane(project: RefCounted) -> bool:
	if pose_layer:
		if pose_layer.index != project.layers.find(pose_layer):
			pose_layer = null
	if not pose_layer in project.layers:
		pose_layer = find_pose_layer(project)
		if pose_layer:
			return true
		reset_everything()
		return false
	return true


## Calculators


## Checks the group heirarchy and comes up with a valid name
func get_valid_name(initial_name: String, existing_names: Array) -> String:
	## Remove any previous suffixes
	#initial_name = get_name_without_suffix(initial_name)
	var new_name := initial_name
	var suffix := ""
	while new_name in existing_names:
		suffix += "_"
		new_name = initial_name + suffix
	return new_name


func find_pose_layer(project: RefCounted) -> RefCounted:
	for layer_idx in range(project.layers.size() - 1, -1, -1):  # The pose layer is likely near top.
		if is_pose_layer(project.layers[layer_idx]):
			if project.layers[layer_idx].index != layer_idx:
				# Index mismatch detected, Fixing...
				project.layers[layer_idx].index = layer_idx  # update the idx of the layer
			return project.layers[layer_idx]
	return


func get_best_origin(layer_idx: int) -> Vector2i:
	var project = api.project.current_project
	if current_frame >= 0 and current_frame < project.frames.size():
		if layer_idx >= 0 and layer_idx < project.layers.size():
			if project.layers[layer_idx].get_layer_type() == global.LayerTypes.GROUP:
				var used_rect := Rect2i()
				for child_layer in project.layers[layer_idx].get_children(false):
					if project.frames[current_frame].cels[child_layer.index].get_class_name() == "PixelCel":
						var cel_rect = (
								project.frames[current_frame].cels[child_layer.index].get_image()
							).get_used_rect()
						if cel_rect.has_area():
							used_rect = used_rect.merge(cel_rect) if used_rect.has_area() else cel_rect
				return used_rect.position + (used_rect.size / 2)
	return Vector2i.ZERO


## Signal managers (Provides easy connecting/disconnecting throughout the script)


## Manages connections of UI and API signals that don't depend on project switching. Used to connect
## signals related to UI elements that are cruitial for updating skeleton data. We also use this to
## occasionaly disconnect signals as well at places where we don't want any undesired stuff to
## happen (e.g see manage_project_signals() and generate_pose())
func manage_ui_signals(is_disconnecting := false) -> void:
	api.signals.signal_cel_switched(_on_cel_switched, is_disconnecting)
	api.signals.signal_project_data_changed(_on_project_data_changed, is_disconnecting)
	api.signals.signal_current_cel_texture_changed(
		_on_pixel_layers_texture_changed, is_disconnecting
	)
	if is_disconnecting:
		if global.layer_vbox.child_order_changed.is_connected(_on_project_layers_moved):
			global.layer_vbox.child_order_changed.disconnect(_on_project_layers_moved)
	else:
		if not global.layer_vbox.child_order_changed.is_connected(_on_project_layers_moved):
			global.layer_vbox.child_order_changed.connect(_on_project_layers_moved)


## Manages connections of signals that have to be re-determined everytime project switches.
## Used to connect to incoming Project signals cruitial for updating skeleton data.
## Automatically called when project switches
func manage_project_signals(should_connect := false) -> void:
	var project = api.project.current_project
	if should_connect:
		## Add stuff which connects on project changed
		reset_everything()
		for layer in api.project.current_project.layers:
			if layer != pose_layer:
				# Treatment for simple layers (all BaseLayers except Group Layers)
				if layer.get_layer_type() != global.LayerTypes.GROUP:
					if !layer.visibility_changed.is_connected(generate_pose):
						layer.visibility_changed.connect(generate_pose)
				# Treatment for group layers
				if !layer.name_changed.is_connected(_on_layer_name_changed):
					layer.name_changed.connect(_on_layer_name_changed.bind(layer, layer.name))
					layer.effects_added_removed.connect(generate_pose)
		# Wait two frames for the project to adjust
		await get_tree().process_frame
		await get_tree().process_frame
		manage_ui_signals()
		# NOTE: we need to call _on_cel_switched() here manually becaues the signal we used to
		# trigger it was disconnected by us during project switching and was reconnected just
		# recently through manage_ui_signals().
		_on_cel_switched()
		global.canvas.update_all_layers = true
		global.canvas.queue_redraw()
	else:
		### Add stuff which disconnects on project changed
		# NOTE: we disconnect manage_ui_signals here because while project is switching, the
		# _on_project_layers_moved signal, (which is managed by manage_ui_signals) is spammed multiple
		# times as layers are being updated, which results in spamming generate_pose,
		# causing useless delays.
		manage_ui_signals(true)
		for layer in api.project.current_project.layers:
			if layer != pose_layer:
				# Treatment for simple layers (all BaseLayers except Group Layers)
				if layer.get_layer_type() != global.LayerTypes.GROUP:
					if layer.visibility_changed.is_connected(generate_pose):
						layer.visibility_changed.disconnect(generate_pose)
				 # Treatment for group layers
				if layer.name_changed.is_connected(_on_layer_name_changed):
					layer.name_changed.disconnect(_on_layer_name_changed)
					layer.effects_added_removed.disconnect(generate_pose)


## Signal recievers


## Signal to the "Assign Pose Layer" menu button
func menu_item_clicked() -> void:
	var project = api.project.current_project
	var current_layer = project.layers[project.current_layer]
	if !pose_layer and current_layer.get_layer_type() == global.LayerTypes.PIXEL:
		pose_layer = current_layer
		update_frame_data()


func _on_pixel_layers_texture_changed() -> void:
	if not is_pose_layer(
		api.project.current_project.layers[api.project.current_project.current_layer]
	):
		queue_generate = true


func _on_cel_switched() -> void:
	if current_frame_data.is_empty():
		queue_generate = true
	update_frame_data()
	if !is_sane(api.project.current_project):  ## Do nothing more if pose layer doesn't exist
		return
	manage_layer_visibility()


func _on_project_data_changed(project: RefCounted) -> void:
	if project == api.project.current_project:
		if (
			project.frames.size() != prev_frame_count
			or project.layers.size() != prev_layer_count
		):
			update_frame_data()
			generate_pose()


func _on_project_layers_moved() -> void:
	await get_tree().process_frame  # Wait for the project to adjust
	if is_sane(api.project.current_project):
		update_frame_data()
		if api.project.current_project.current_layer == pose_layer.index:
			generate_pose()
		else:
			queue_generate = true


func _on_layer_name_changed(layer: RefCounted, old_name: String) -> void:
	if (
		layer.get_layer_type() == global.LayerTypes.PIXEL
		and not is_sane(api.project.current_project)
	):
		if "Pose Layer" in layer.name.capitalize():
			pose_layer = layer
			update_frame_data()
			return
	elif layer.get_layer_type() == global.LayerTypes.GROUP:
		if is_sane(api.project.current_project):
			if old_name in current_frame_data.keys():
				# Disconnect and later re-connect with new "old_name"
				layer.name_changed.disconnect(_on_layer_name_changed)
				if layer.name in current_frame_data.keys():  # Conflict Detected
					layer.name = get_valid_name(layer.name, current_frame_data.keys())
				if old_name in current_frame_bones.keys():
					# Needed if bones have been generated for this frame
					var rename_bone: SkeletonGizmo = current_frame_bones[old_name]
					rename_bone.bone_name = layer.name
				var rename_data: Dictionary = current_frame_data[old_name]
				current_frame_data.erase(old_name)
				rename_data["bone_name"] = layer.name
				if layer.parent:
					rename_data["parent_bone_name"] = layer.parent.name
				current_frame_data[layer.name] = rename_data
				layer.name_changed.connect(_on_layer_name_changed.bind(layer, layer.name))
			else: ## It's a new bone
				var layer_parent_name = ""
				if layer.parent:
					layer_parent_name = layer.parent.name
				current_frame_data[layer.name] = SkeletonGizmo.generate_empty_data(
					layer.name, layer_parent_name
				)
		save_frame_info(api.project.current_project)


## Misclenious helper methods (methods that are part of other methods but don't have a category)


func manage_layer_visibility() -> void:
	var pose_layer_visible = (api.project.current_project.current_layer == pose_layer.index)
	if pose_layer_visible != pose_layer.visible:
		pose_layer.visible = pose_layer_visible
		if not pose_layer.visible:  # Clear gizmos when we leave PoseLayer
			selected_gizmo = null
		if api.project.current_project.current_layer == pose_layer.index:
			# generate_pose if we qued it and are now back on PoseLayer
			if queue_generate and pose_layer.visible:
				queue_generate = false
				generate_pose()
		# Also change visibility of all the root folders
		for layer_idx in api.project.current_project.layers.size():
			var layer = api.project.current_project.layers[layer_idx]
			if layer.get_layer_type() == global.LayerTypes.GROUP and not layer.parent:
				api.project.current_project.layers[layer_idx].visible = !pose_layer_visible


func assign_pose_layer(layer: RefCounted) -> void:
	if layer:
		layer.set_meta("SkeletorPoseLayer", true)
		layer.set("ui_color", Color(0, 1, 0, 0.5))
		if pose_layer.visibility_changed.is_connected(generate_pose):
			pose_layer.visibility_changed.disconnect(generate_pose)


## Saves the current_frame_data to the given frame of project
func save_frame_info(
	project: RefCounted,
	frame_data: Dictionary = current_frame_data,
	at_frame: int = current_frame
) -> void:
	if project and is_sane(project):
		if at_frame >= 0 and at_frame < project.frames.size():
			project.frames[at_frame].cels[pose_layer.index].set_meta(
				"SkeletorSkeleton", var_to_str(frame_data)
			)
			queue_redraw()


## loads frame data from the given frame of project
func load_frame_info(project: RefCounted, frame_number: int = current_frame) -> Dictionary:
	if !pose_layer:
		pose_layer = find_pose_layer(project)
	if project and pose_layer:
		if frame_number >= 0 and frame_number < project.frames.size():
			var data = project.frames[frame_number].cels[pose_layer.index].get_meta(
				"SkeletorSkeleton", {}
			)
			if typeof(data) == TYPE_STRING:
				data = str_to_var(data)
			if typeof(data) == TYPE_DICTIONARY:  # Successful conversion
				# At the cost of some performance, go through a failsafe first
				for bone in data.keys():
					if data.get(bone, null) == null:
						data.erase(bone)
						continue
					for bone_data in data.get(bone, {}).keys():
						if typeof(data[bone][bone_data]) == TYPE_STRING:
							if str_to_var(data[bone][bone_data]):  # Succesful sub-data conversion
								data[bone][bone_data] = str_to_var(data[bone][bone_data])
				return data
	return {}


## Generates a gizmo (for preview) based on the given data
func _draw_gizmo(gizmo: SkeletonGizmo, camera_zoom: Vector2) -> void:
	var project = api.project.current_project
	if not is_pose_layer(project.layers[project.current_layer]):
		return
	#var frame_cels = project.frames[project.current_frame].cels
	#var bone_cel: BoneCel = frame_cels[bone.index]
	var mouse_point: Vector2 = api.general.get_canvas().current_pixel
	var highlight = (gizmo == hover_gizmo or gizmo == selected_gizmo)

	var width: float = (
		(gizmo.WIDTH if (highlight) else gizmo.DESELECT_WIDTH) / camera_zoom.x
	)
	var net_width = width
	var bone_color := Color.WHITE if (highlight) else Color.GRAY
	var hover_mode = max(gizmo.modify_mode, gizmo.hover_mode(mouse_point, camera_zoom))
	if hover_mode == SkeletonGizmo.EXTEND:
		hover_mode = SkeletonGizmo.ROTATE
	if gizmo.hover_mode(mouse_point, camera_zoom) == SkeletonGizmo.NONE:
		hover_mode = SkeletonGizmo.NONE

	# Draw the position circle
	draw_set_transform(gizmo.gizmo_origin)
	net_width = width + (width / 2 if (hover_mode == SkeletonGizmo.DISPLACE) else 0.0)
	draw_circle(
		gizmo.start_point,
		gizmo.START_RADIUS / camera_zoom.x,
		bone_color,
		false,
		(
			net_width
			if (hover_mode == SkeletonGizmo.DISPLACE)
			else SkeletonGizmo.DESELECT_WIDTH / camera_zoom.x
		)
	)
	draw_set_transform(Vector2.ZERO)
	gizmo.ignore_rotation_hover = bones_chained
	var skip_rotation_gizmo := false
	if bones_chained:
		var names = []
		for other_gizmo: SkeletonGizmo in current_frame_bones.values():
			names.append(other_gizmo.parent_bone_name)
			if other_gizmo.parent_bone_name == gizmo.bone_name:
				skip_rotation_gizmo = true
				break
	gizmo.ignore_rotation_hover = skip_rotation_gizmo
	if !skip_rotation_gizmo:
		net_width = width + (width / 2 if (hover_mode == SkeletonGizmo.ROTATE) else 0.0)
		draw_set_transform(gizmo.gizmo_origin)
		# Draw the line joining the position and rotation circles
		draw_line(
			gizmo.start_point,
			gizmo.start_point + gizmo.end_point,
			bone_color,
			(
				net_width
				if (hover_mode == SkeletonGizmo.ROTATE)
				else SkeletonGizmo.DESELECT_WIDTH / camera_zoom.x
			)
		)
		# Draw rotation circle (pose mode)
		draw_circle(
			gizmo.start_point + gizmo.end_point,
			SkeletonGizmo.END_RADIUS / camera_zoom.x,
			bone_color,
			false,
			(
				net_width
				if (hover_mode == SkeletonGizmo.ROTATE)
				else SkeletonGizmo.DESELECT_WIDTH / camera_zoom.x
			)
		)
	draw_set_transform(Vector2.ZERO)
	## Show connection to parent
	var parent: SkeletonGizmo = current_frame_bones.get(gizmo.parent_bone_name, null)
	if parent:
		var p_start := parent.start_point
		var p_end := Vector2.ZERO if bones_chained else parent.end_point
		var parent_start = (
			gizmo.rel_to_origin(parent.rel_to_canvas(p_start)) + p_end
		)
		draw_set_transform(gizmo.gizmo_origin)
		# NOTE: gizmo.start_point is coordinate of tail of bone, parent_start is head of parent
		# (or tail in chained mode)
		draw_dashed_line(
			gizmo.start_point,
			parent_start,
			bone_color,
			SkeletonGizmo.DESELECT_WIDTH / camera_zoom.x
		)
		draw_set_transform(Vector2.ZERO)
	var font = get_node_or_null("/root/Themes").get_font()
	var line_size = gizmo.gizmo_length
	var fade_ratio = (line_size * camera_zoom.x) / (font.get_string_size(gizmo.bone_name).x)
	if bones_chained:
		fade_ratio = max(0.3, fade_ratio)
	if fade_ratio >= 0.4 and !active_tool:  # Hide names if we have zoomed far
		draw_set_transform(
			gizmo.gizmo_origin + gizmo.start_point, rotation, Vector2.ONE / camera_zoom.x
		)
		draw_string(font, Vector2(3, -3), gizmo.bone_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, bone_color)


## Applies the transformations done by bone_name to the given cel_image
func _apply_bone(bone_name: String, cel_image: Image, at_frame := current_frame) -> void:
	var frame_data = current_frame_data
	if at_frame != current_frame:
		frame_data = load_frame_info(api.project.current_project, at_frame)
	var used_region := cel_image.get_used_rect()
	var bone_info: Dictionary = frame_data.get(bone_name, {})
	var start_point: Vector2i = bone_info.get("start_point", Vector2i.ZERO)
	var gizmo_origin := Vector2i(bone_info.get("gizmo_origin", Vector2.ZERO))
	var angle: float = bone_info.get("bone_rotation", 0)
	if angle == 0 and start_point == Vector2i.ZERO:
		return
	if used_region.size == Vector2i.ZERO:
		return

	# Imprint on a square for rotation
	# (We are doing this so that the image doesn't get clipped as a result of rotation.)
	var diagonal_length := floori(used_region.size.length())
	if diagonal_length % 2 == 0:
		diagonal_length += 1
	var s_offset: Vector2i = (
		0.5 * (Vector2i(diagonal_length, diagonal_length)
		- used_region.size)
	).floor()
	var square_image = cel_image.get_region(
		Rect2i(used_region.position - s_offset, Vector2i(diagonal_length, diagonal_length))
	)
	# Apply Rotation To this Image
	if angle != 0:
		var transformation_matrix := Transform2D(angle, Vector2.ZERO)
		var rotate_params := {
			"transformation_matrix": transformation_matrix.affine_inverse(),
			"pivot": Vector2(0.5, 0.5),
			"ending_angle": angle,
			"tolerance": 0,
			"preview": false
		}
		# Detects if the rotation is changed for this generation or not
		# (useful if bone is moved arround while having some rotation)
		# NOTE: I tried cacheing entire poses (that remain same) as well. It was faster than this
		# approach but only by a few milliseconds. I don't think straining the memory for only
		# a boost of a few millisec was worth it so i declare this the most optimal approach.
		var bone_key := {
				"bone_name" : bone_name,
				"parent_bone_name" : bone_info.get("parent_bone_name", "")
			}
		var cache_key := {"angle": angle, "cel_content": cel_image.get_data()}
		var bone_cache: Dictionary = generation_cache.get_or_add(bone_key, {})
		if cache_key in bone_cache.keys():
			square_image = bone_cache[cache_key]
		else:
			rotation_generator.generate_image(
				square_image,
				api.general.get_drawing_algos().clean_edge_shader,
				rotate_params, square_image.get_size(),
				true,
				false
			)
			bone_cache.clear()
			bone_cache[cache_key] = square_image
	var pivot: Vector2i = gizmo_origin
	var bone_start_global: Vector2i = gizmo_origin + start_point
	var square_image_start: Vector2i = used_region.position - s_offset
	var global_square_centre: Vector2 = square_image_start + (square_image.get_size() / 2)
	var global_rotated_new_centre = (
		(global_square_centre - Vector2(pivot)).rotated(angle)
		+ Vector2(bone_start_global)
	)
	var new_start: Vector2i = (
		square_image_start
		+ Vector2i((global_rotated_new_centre - global_square_centre).floor())
	)
	cel_image.fill(Color(0, 0, 0, 0))
	cel_image.blit_rect(
		square_image,
		Rect2i(Vector2.ZERO, square_image.get_size()),
		Vector2i(new_start)
	)


func _set_layer_metadata_image(
	layer: RefCounted, cel: RefCounted, image: Image, index: int, include := true
) -> void:
	# Store the blend mode
	image.set_pixel(index, 0, Color(layer.blend_mode / 255.0, 0.0, 0.0, 0.0))
	# Store the opacity
	if layer.visible or layer.get_layer_type() == global.LayerTypes.GROUP:
		var opacity = cel.get_final_opacity(layer)
		image.set_pixel(index, 1, Color(opacity, 0.0, 0.0, 0.0))
	else:
		image.set_pixel(index, 1, Color())
	# Store the clipping mask boolean
	if layer.clipping_mask:
		image.set_pixel(index, 3, Color.RED)
	else:
		image.set_pixel(index, 3, Color.BLACK)
	if not include:
		# Store a small red value as a way to indicate that this layer should be skipped
		# Used for layers such as child layers of a group, so that the group layer itself can
		# successfully be used as a clipping mask with the layer below it.
		image.set_pixel(index, 3, Color(0.2, 0.0, 0.0, 0.0))


func _render_image(image: Image, at_frame: int = current_frame) -> void:
	var project = api.project.current_project
	var pixel_cel = project.frames[at_frame].cels[pose_layer.index]
	var cel_image: Image = pixel_cel.get_image()
	if pixel_cel.get_class_name() != "PixelCel":  # Failsafe
		return
	cel_image.blit_rect(image, Rect2i(Vector2.ZERO, image.get_size()), Vector2.ZERO)
	pixel_cel.image_changed(cel_image)
	if at_frame == current_frame and pose_layer.index == project.current_layer:
		project.selected_cels = []
		project.change_cel(at_frame, pose_layer.index)
