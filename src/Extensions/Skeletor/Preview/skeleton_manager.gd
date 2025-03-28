extends Node2D

var api: Node
var global: Node
var selected_gizmo: SkeletonGizmo
var group_names_ordered: PackedStringArray
## A Dictionary of bone names as keys and their "Gizmo" as values.
var current_frame_bones: Dictionary
## A Dictionary with Bone names as keys and their "Data Dictionary" as values.
var current_frame_data: Dictionary
var bones_chained := false
var current_frame: int = -1
var prev_layer_count: int = 0
var prev_frame_count: int = 0
var ignore_render_once := false  ## used to check if we need a new render or not (used in _input())
var queue_generate := false
var transformation_active := false
# The shader is located in pixelorama
var blend_layer_shader = load("res://src/Shaders/BlendLayers.gdshader")
var pose_layer:  ## The layer in which a pose is rendered
	set(value):
		pose_layer = value
		assign_pose_layer(value)
var generation_cache: Dictionary
var active_skeleton_tools := Array()


class SkeletonGizmo:
	## This class is used/created to perform calculations
	enum {NONE, DISPLACE, ROTATE, SCALE}  ## I planned to add scaling too but decided to give up
	const InteractionDistance = 20
	const MIN_LENGTH: float = 10
	const START_RADIUS: float = 6
	const END_RADIUS: float = 4
	const WIDTH: float = 2
	const DESELECT_WIDTH: float = 1

	signal update_property

	# Variables set using serialize()
	var bone_name: String
	var parent_bone_name: String:
		set(value):
			parent_bone_name = value
			update_property.emit(bone_name ,"parent_bone_name", false, "")
	var gizmo_origin: Vector2:
		set(value):
			var diff = value - gizmo_origin
			gizmo_origin = value
			update_property.emit(bone_name ,"gizmo_origin", false, diff)
	var gizmo_rotate_origin: float = 0:  ## Unit is Radians
		set(value):
			var diff = value - gizmo_rotate_origin
			gizmo_rotate_origin = value
			update_property.emit(bone_name ,"gizmo_rotate_origin", false, diff)
	var start_point: Vector2:  ## This is relative to the gizmo_origin
		set(value):
			var diff = value - start_point
			start_point = value
			update_property.emit(bone_name ,"start_point", true, diff)
	var bone_rotation: float = 0:  ## This is relative to the gizmo_rotate_origin (Radians)
		set(value):
			var diff = value - bone_rotation
			bone_rotation = value
			update_property.emit(bone_name ,"bone_rotation", true, diff)
	var gizmo_length: int:
		set(value):
			var diff = value - gizmo_length
			if value < int(MIN_LENGTH):
				value = int(MIN_LENGTH)
				diff = 0
			gizmo_length = value
			update_property.emit(bone_name ,"gizmo_length", false, diff)

	# Properties determined using above variables
	var end_point: Vector2:  ## This is relative to the gizmo_origin
		get():
			return Vector2(gizmo_length, 0).rotated(gizmo_rotate_origin + bone_rotation)
	var modify_mode := SkeletonGizmo.NONE
	var ignore_rotation_hover := false

	static func generate_empty_data(
		cel_bone_name := "Invalid Name", cel_parent_bone_name := "Invalid Parent"
	) -> Dictionary:
		# Make sure the name/types are the same as the variable names/types
		return {
			"bone_name": cel_bone_name,
			"parent_bone_name": cel_parent_bone_name,
			"gizmo_origin": Vector2.ZERO,
			"gizmo_rotate_origin": 0,
			"start_point": Vector2.ZERO,
			"bone_rotation": 0,
			"gizmo_length": MIN_LENGTH,
		}

	func serialize(data: Dictionary) -> void:
		var reference_data = generate_empty_data()
		for key in reference_data.keys():
			if get(key) != data.get(key, reference_data[key]):
				set(key, data.get(key, reference_data[key]))

	func hover_mode(mouse_position: Vector2, camera_zoom) -> int:
		var local_mouse_pos = rel_to_origin(mouse_position)
		if (start_point).distance_to(local_mouse_pos) <= InteractionDistance / camera_zoom.x:
			return DISPLACE
		elif (
			(start_point + end_point).distance_to(local_mouse_pos)
			<= InteractionDistance / camera_zoom.x
		):
			if !ignore_rotation_hover:
				return SCALE
		elif is_close_to_segment(
			rel_to_start_point(mouse_position),
			InteractionDistance / camera_zoom.x,
			Vector2.ZERO, end_point
		):
			if !ignore_rotation_hover:
				return ROTATE
		return NONE

	static func is_close_to_segment(
		pos: Vector2, detect_distance: float, s1: Vector2, s2: Vector2
	) -> bool:
		var test_line := (s2 - s1).rotated(deg_to_rad(90)).normalized()
		var from_a := pos - test_line * detect_distance
		var from_b := pos + test_line * detect_distance
		if Geometry2D.segment_intersects_segment(from_a, from_b, s1, s2):
			return true
		return false

	func rel_to_origin(pos: Vector2) -> Vector2:
		return pos - gizmo_origin

	func rel_to_start_point(pos: Vector2) -> Vector2:
		return pos - gizmo_origin - start_point

	func rel_to_global(pos: Vector2) -> Vector2:
		return pos + gizmo_origin

	func reset_bone(overrides := {}) -> Dictionary:
		var reset_data = generate_empty_data(bone_name, parent_bone_name)
		var connection_array := update_property.get_connections()
		for connection: Dictionary in connection_array:
			update_property.disconnect(connection["callable"])
		for key in reset_data.keys():
			if key in overrides.keys():
				set(key, overrides[key])
				reset_data[key] = overrides[key]
			else:
				set(key, reset_data[key])
		for connection: Dictionary in connection_array:
			update_property.connect(connection["callable"])
		return reset_data


func update_bone_property(parent_name: String, property: String, should_propagate: bool, diff, project):
	if not is_instance_valid(project):
		return
	# First we update data of parent bone
	current_frame_data = load_frame_info(project)
	if not parent_name in current_frame_data.keys():
		update_frame_data()
	var parent: SkeletonGizmo = current_frame_bones[parent_name]
	if parent.get(property) != current_frame_data[parent_name][property]:
		current_frame_data[parent_name][property] = parent.get(property)
		save_frame_info(project)

	if !should_propagate or ignore_render_once:
		# If ignore_render_once is true this probably beans we are in the process of modifying
		# "Individual" properties of the bone and don't want them to propagate down the
		# chain.
		return
	for layer in project.layers:  ## update first child (This will trigger a chain process)
		if layer.get_layer_type() == 1 and layer.parent:  # GroupLayer
			if current_frame_bones[layer.name].parent_bone_name != layer.parent.name:
				current_frame_bones[layer.name].parent_bone_name = layer.parent.name
			if layer.parent.name == parent_name:
				if current_frame_bones.has(layer.name):
					var bone: SkeletonGizmo = current_frame_bones[layer.name]
					bone.set(property, bone.get(property) + diff)
					if current_frame_bones.has(parent_name) and property == "bone_rotation":
						var parent_bone: SkeletonGizmo = current_frame_bones[parent_name]
						var displacement := parent_bone.rel_to_start_point(
							bone.rel_to_global(bone.start_point)
						)
						displacement = displacement.rotated(diff)
						bone.start_point = bone.rel_to_origin(
							parent_bone.rel_to_global(parent_bone.start_point) + displacement
						)


func _ready() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	global = api.general.get_global()

	await get_tree().process_frame
	await get_tree().process_frame

	manage_project_changed(true)
	global.project_about_to_switch.connect(manage_project_changed.bind(false))
	global.camera.zoom_changed.connect(queue_redraw)
	api.signals.signal_project_switched(manage_project_changed.bind(true))


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
		generate_heirarchy(current_frame_data)
	save_frame_info(project)


func generate_heirarchy(old_data: Dictionary) -> void:
	var invalid_layer_names := old_data.keys()
	group_names_ordered.clear()
	for layer in api.project.current_project.layers:
		if !pose_layer and layer.get_layer_type() == 0:  ## If user deleted a pose layer then find new one
			if "Pose Layer" in layer.name.capitalize():
				pose_layer = layer
		elif layer.get_layer_type() == 1:  # GroupLayer
			group_names_ordered.insert(0, layer.name)
			var parent_name = ""
			if layer.parent:
				parent_name = layer.parent.name
			invalid_layer_names.erase(layer.name)
			if not layer.name in old_data.keys():
				old_data[layer.name] = SkeletonGizmo.generate_empty_data(layer.name, parent_name)

		## check connectivity of one of these signals and assume the result for others
		if not layer.name_changed.is_connected(layer_name_changed):
			if layer != pose_layer:
				if layer.get_layer_type() != 1:
					layer.visibility_changed.connect(generate_pose)
				layer.effects_added_removed.connect(generate_pose)
				layer.name_changed.connect(layer_name_changed.bind(layer, layer.name))
	for layer_name in invalid_layer_names:
		old_data.erase(layer_name)


func _input(_event: InputEvent) -> void:
	var project = api.project.current_project
	if not pose_layer:
		return
	if not project.layers[pose_layer.index].locked:
		project.layers[pose_layer.index].locked = true


func generate_pose(for_frame := current_frame) -> void:
	# Do we even need to generate a pose?
	if ignore_render_once:  # We had set to ignore generation in this cycle.
		ignore_render_once = false
		return
	var project = api.project.current_project
	if not is_sane(project):  # There is no Pose Layer to render to!!!
		return
	if not pose_layer.visible:  # Pose Layer is invisible (So generating is a waste of time)
		return
	if for_frame == -1:  # for_frame is not defined
		return
	manage_signals(true)  # Trmporarily disconnect signals
	var image = Image.create_empty(project.size.x, project.size.y, false, Image.FORMAT_RGBA8)
	if current_frame_data.is_empty():  # No pose to generate (This is a kind of failsafe)
		project.layers[pose_layer.index].locked = false
		_render_image(image)
		project.layers[pose_layer.index].locked = true
		manage_signals()  # Reconnect signals
		return

	# Start generating
	# (Group visibility is completely ignored while the visibility of other layer types is respected)
	var frame = project.frames[for_frame]
	var previous_ordered_layers: Array[int] = project.ordered_layers
	project.order_layers(for_frame)
	var textures: Array[Image] = []
	var gen = api.general.get_new_shader_image_effect()
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

		var include := false if (!layer.visible and layer.get_layer_type() != 1) else true
		if layer.is_blender():
			cel_image = layer.blend_children(frame)
		else:
			cel_image = layer.display_effects(cel)

		if is_instance_valid(group_layer):
			_apply_bone(gen, group_layer.name, cel_image, for_frame)

		textures.append(cel_image)
		if (
			layer.is_blended_by_ancestor()
		):
			include = false
		_set_layer_metadata_image(layer, cel, metadata_image, ordered_index, include)

	var texture_array := Texture2DArray.new()
	texture_array.create_from_images(textures)
	var params := {
		"layers": texture_array,
		"metadata": ImageTexture.create_from_image(metadata_image),
	}
	var blended := Image.create_empty(project.size.x, project.size.y, false, image.get_format())
	gen.generate_image(blended, blend_layer_shader, params, project.size)
	image.blend_rect(blended, Rect2i(Vector2.ZERO, project.size), Vector2.ZERO)
	# Re-order the layers again to ensure correct canvas drawing
	project.ordered_layers = previous_ordered_layers
	project.layers[pose_layer.index].locked = false
	_render_image(image, for_frame)
	project.layers[pose_layer.index].locked = true
	manage_signals()  # Reconnect signals


func _exit_tree() -> void:
	global.project_about_to_switch.disconnect(manage_project_changed)
	api.signals.signal_project_switched(manage_project_changed, true)
	manage_signals(true)


## UPDATERS  (methods that are called through signals)

func manage_signals(is_disconnecting := false) -> void:
	api.signals.signal_cel_switched(cel_switched, is_disconnecting)
	api.signals.signal_project_data_changed(project_data_changed, is_disconnecting)
	api.signals.signal_current_cel_texture_changed(texture_changed, is_disconnecting)
	if is_disconnecting:
		global.layer_vbox.child_order_changed.disconnect(project_layers_moved)
	else:
		global.layer_vbox.child_order_changed.connect(project_layers_moved)


# Manages connections of signals that have to be re-determined everytime project switches
func manage_project_changed(should_connect := false) -> void:
	var project = api.project.current_project
	if should_connect:
		## Add stuff which connects on project changed
		clean_data()
		for layer in api.project.current_project.layers:
			if layer != pose_layer:
				if layer.get_layer_type() != 1:  # Treatment for simple layers
					if !layer.visibility_changed.is_connected(generate_pose):
						layer.visibility_changed.connect(generate_pose)
				if !layer.name_changed.is_connected(layer_name_changed):  # Treatment for group layers
					layer.name_changed.connect(layer_name_changed.bind(layer, layer.name))
					layer.effects_added_removed.connect(generate_pose)
		await get_tree().process_frame  # Wait for the project to adjust
		manage_signals()
		cel_switched()
		global.canvas.update_all_layers = true
		global.canvas.queue_redraw()
	else:
		## Add stuff which disconnects on project changed
		manage_signals(true)
		for layer in api.project.current_project.layers:
			if layer != pose_layer:
				if layer.get_layer_type() != 1:  # Treatment for simple layers
					if layer.visibility_changed.is_connected(generate_pose):
						layer.visibility_changed.disconnect(generate_pose)
				if layer.name_changed.is_connected(layer_name_changed):  # Treatment for group layers
					layer.name_changed.disconnect(layer_name_changed)
					layer.effects_added_removed.disconnect(generate_pose)


func clean_data() -> void:
	selected_gizmo = null
	current_frame_data.clear()
	current_frame_bones.clear()
	current_frame = -1
	prev_layer_count = 0
	prev_frame_count = 0
	ignore_render_once = false
	pose_layer = null


func texture_changed() -> void:
	if not is_pose_layer(
		api.project.current_project.layers[api.project.current_project.current_layer]
	):
		queue_generate = true


func cel_switched() -> void:
	if current_frame_data.is_empty():
		queue_generate = true
	update_frame_data()
	if !is_sane(api.project.current_project):  ## Do nothing more if pose layer doesn't exist
		return
	manage_layer_visibility()


func project_data_changed(project) -> void:
	if project == api.project.current_project:
		if (
			project.frames.size() != prev_frame_count
			or project.layers.size() != prev_layer_count
		):
			update_frame_data()
			generate_pose()


func project_layers_moved() -> void:
	await get_tree().process_frame  # Wait for the project to adjust
	if is_sane(api.project.current_project):
		update_frame_data()
		if api.project.current_project.current_layer == pose_layer.index:
			generate_pose()
		else:
			queue_generate = true


func layer_name_changed(layer, old_name: String) -> void:
	if layer.get_layer_type() == 0 and not is_sane(api.project.current_project):
		if "Pose Layer" in layer.name.capitalize():
			pose_layer = layer
			update_frame_data()
			return
	elif layer.get_layer_type() == 1:
		if is_sane(api.project.current_project):
			if old_name in current_frame_data.keys():
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
			else: ## It's a new bone
				var layer_parent_name = ""
				if layer.parent:
					layer_parent_name = layer.parent.name
				current_frame_data[layer.name] = SkeletonGizmo.generate_empty_data(
					layer.name, layer_parent_name
				)
		save_frame_info(api.project.current_project)


func _draw() -> void:
	if current_frame_data.is_empty():
		return
	if active_skeleton_tools.is_empty():
		return
	var project = api.project.current_project
	var group_names: Array = current_frame_data.keys()
	for bone_name: String in group_names:
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
		_draw_gizmo(current_frame_bones[bone_name], global.camera.zoom)


## Helper methods (methods that are part of other methods)

## Generates a gizmo (for preview) based on the given data
func _draw_gizmo(gizmo: SkeletonGizmo, camera_zoom: Vector2) -> void:
	var project = api.project.current_project
	if not is_pose_layer(project.layers[project.current_layer]):
		return
	var width: float = (gizmo.WIDTH if (gizmo == selected_gizmo) else gizmo.DESELECT_WIDTH) / camera_zoom.x
	var main_color := Color.WHITE if (gizmo == selected_gizmo) else Color.GRAY
	var dim_color := Color(main_color.r, main_color.g, main_color.b, 0.8)
	var mouse_point: Vector2 = api.general.get_canvas().current_pixel
	var hover_mode = max(gizmo.modify_mode, gizmo.hover_mode(mouse_point, camera_zoom))
	draw_set_transform(gizmo.gizmo_origin)
	draw_circle(
		gizmo.start_point,
		gizmo.START_RADIUS / camera_zoom.x,
		main_color if (hover_mode == gizmo.DISPLACE) else dim_color, false,
		width
	)
	var skip_rotation_gizmo := false
	if bones_chained:
		for other_gizmo: SkeletonGizmo in current_frame_bones.values():
			if other_gizmo.parent_bone_name == gizmo.bone_name:
				skip_rotation_gizmo = true
				break
	gizmo.ignore_rotation_hover = skip_rotation_gizmo
	if !skip_rotation_gizmo:
		draw_line(
			gizmo.start_point,
			gizmo.start_point + gizmo.end_point,
			main_color if (hover_mode == gizmo.ROTATE) else dim_color,
			width if (hover_mode == gizmo.ROTATE) else gizmo.DESELECT_WIDTH / camera_zoom.x
		)
		draw_circle(
			gizmo.start_point + gizmo.end_point,
			gizmo.END_RADIUS / camera_zoom.x,
			main_color if (hover_mode == gizmo.SCALE) else dim_color,
			false,
			width
		)
	## Show connection to parent
	if gizmo.parent_bone_name in current_frame_bones.keys():
		var parent_bone: SkeletonGizmo = current_frame_bones[gizmo.parent_bone_name]
		draw_dashed_line(
			gizmo.start_point,
			gizmo.rel_to_origin(parent_bone.rel_to_global(parent_bone.start_point)),
			main_color,
			width,
		)
	if get_node_or_null("/root/Themes"):
		var font = get_node_or_null("/root/Themes").get_font()
		draw_set_transform(gizmo.gizmo_origin + gizmo.start_point, rotation, Vector2.ONE / camera_zoom.x)
		var line_size = gizmo.gizmo_length
		var fade_ratio = (line_size/font.get_string_size(gizmo.bone_name).x) * camera_zoom.x
		var alpha = clampf(fade_ratio, 0.6, 1)
		if fade_ratio < 0.3:
			alpha = 0
		draw_string(
			font, Vector2.ZERO, gizmo.bone_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(1, 1, 1, alpha)
		)


func _apply_bone(gen, bone_name: String, cel_image: Image, at_frame := current_frame) -> void:
	var frame_data = current_frame_data
	if at_frame != current_frame:
		frame_data = load_frame_info(api.project.current_project, at_frame)
	var used_region := cel_image.get_used_rect()
	var bone_info: Dictionary = frame_data.get(bone_name, {})
	var start_point: Vector2i = bone_info.get("start_point", Vector2i.ZERO)
	var gizmo_origin := Vector2i(bone_info.get("gizmo_origin", Vector2.ZERO))
	var angle: float = bone_info.get("bone_rotation", 0)
	if bone_info.get("bone_rotation", 0) == 0 and start_point == Vector2i.ZERO:
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
	if bone_info.get("bone_rotation", 0) != 0:
		var transformation_matrix := Transform2D(bone_info.get("bone_rotation", 0), Vector2.ZERO)
		var rotate_params := {
			"transformation_matrix": transformation_matrix,
			"pivot": Vector2(0.5, 0.5),
			"ending_angle": bone_info.get("bone_rotation", 0),
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
			gen.generate_image(
				square_image,
				api.general.get_drawing_algos().nn_shader,
				rotate_params, square_image.get_size()
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
	layer, cel, image, index, include := true
) -> void:
	# Store the blend mode
	image.set_pixel(index, 0, Color(layer.blend_mode / 255.0, 0.0, 0.0, 0.0))
	# Store the opacity
	if layer.visible or layer.get_layer_type() == 1:
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


func _render_image(image: Image, at_frame := current_frame) -> void:
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


func is_pose_layer(layer) -> bool:
	return layer.get_meta("SkeletorPoseLayer", false)


func manage_layer_visibility() -> void:
	var pose_layer_visible = (api.project.current_project.current_layer == pose_layer.index)
	pose_layer.visible = pose_layer_visible
	if api.project.current_project.current_layer == pose_layer.index:
		if queue_generate:
			queue_generate = false
			generate_pose()
	# Also disable the root folders
	for layer_idx in api.project.current_project.layers.size():
		var layer = api.project.current_project.layers[layer_idx]
		if layer.get_layer_type() == 1 and not layer.parent:
			api.project.current_project.layers[layer_idx].visible = !pose_layer_visible


func assign_pose_layer(layer) -> void:
	if layer:
		layer.set_meta("SkeletorPoseLayer", true)
		if pose_layer.visibility_changed.is_connected(generate_pose):
			pose_layer.visibility_changed.disconnect(generate_pose)


func find_pose_layer(project) -> RefCounted:
	for layer_idx in range(project.layers.size() - 1, -1, -1):  # The pose layer is likely near top.
		if is_pose_layer(project.layers[layer_idx]):
			if project.layers[layer_idx].index != layer_idx:
				# Index mismatch detected, Fixing...
				project.layers[layer_idx].index = layer_idx  # update the isx of the layer
			return project.layers[layer_idx]
	return


## This only searchec for an "Existing" pose layer.
## The assignment of pose layers are done in update_frame_data()
func is_sane(project) -> bool:
	if pose_layer:
		if pose_layer.index != project.layers.find(pose_layer):
			pose_layer = null
	if not pose_layer in project.layers:
		pose_layer = find_pose_layer(project)
		if pose_layer:
			return true
		clean_data()
		return false
	return true


func get_best_origin(layer_idx: int) -> Vector2i:
	var project = api.project.current_project
	if current_frame >= 0 and current_frame < project.frames.size():
		if layer_idx >= 0 and layer_idx < project.layers.size():
			if project.layers[layer_idx].get_layer_type() == 1:
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


func save_frame_info(project, frame_data := current_frame_data, at_frame := current_frame) -> void:
	if project and is_sane(project):
		if at_frame >= 0 and at_frame < project.frames.size():
			project.frames[at_frame].cels[pose_layer.index].set_meta(
				"SkeletorSkeleton", var_to_str(frame_data)
			)
			queue_redraw()


func load_frame_info(project, frame_number:= current_frame) -> Dictionary:
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
					for bone_data in data[bone].keys():
						if typeof(data[bone][bone_data]) == TYPE_STRING:
							if str_to_var(data[bone][bone_data]):  # Succesful sub-data conversion
								data[bone][bone_data] = str_to_var(data[bone][bone_data])
				return data
	return {}


func announce_tool_removal(tool_node):
	active_skeleton_tools.erase(tool_node)
