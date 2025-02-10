extends Node2D

var api: Node
var global: Node
var selected_gizmo: SkeletonGizmo
## A Dictionary of bone names as keys and their "Gizmo" as values.
var current_frame_bones: Dictionary
## A Dictionary with Bone names as keys and their "Data Dictionary" as values.
var current_frame_data: Dictionary
var current_frame: int = -1
var prev_layer_count: int = 0
var prev_frame_count: int = 0
var current_frame_render: Image  # Use this to avoid altering image during undo/redo
var prev_position := Vector2.INF  ## Previous position of the mouse (used in _input())
var ignore_render := false  ## used to check if we need a new render or not (used in _input())
var queue_generate := false
# The shader is located in pixelorama
var blend_layer_shader = load("res://src/Shaders/BlendLayers.gdshader")
var rotate_shader := load("res://src/Shaders/Effects/Rotation/cleanEdge.gdshader")
var pose_layer  ## The layer in which a pose is rendered

var reset_item_id: int

class SkeletonGizmo:
	## This class is used/created to perform calculations
	enum {NONE, OFFSET, ROTATE, SCALE}  ## I planned to add scaling too but decided to give up
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
			if value < MIN_LENGTH:
				value = MIN_LENGTH
				diff = 0
			gizmo_length = value
			update_property.emit(bone_name ,"gizmo_length", false, diff)

	# Properties determined using above variables
	var end_point: Vector2:  ## This is relative to the gizmo_origin
		get():
			return Vector2(gizmo_length, 0).rotated(gizmo_rotate_origin + bone_rotation)
	var current_hover_mode = NONE
	var modify_mode := SkeletonGizmo.NONE

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

	func is_mouse_inside(mouse_position: Vector2, camera_zoom) -> bool:
		var local_mouse_pos = rel_to_origin(mouse_position)
		if (start_point).distance_to(local_mouse_pos) <= InteractionDistance / camera_zoom.x:
			current_hover_mode = OFFSET
			return true
		elif (
			(start_point + end_point).distance_to(local_mouse_pos)
			<= InteractionDistance / camera_zoom.x
		):
			current_hover_mode = SCALE
			return true
		elif is_close_to_segment(
			rel_to_start_point(local_mouse_pos), WIDTH / camera_zoom.x, Vector2.ZERO, end_point
		):
			current_hover_mode = ROTATE
			return true

		current_hover_mode = NONE
		return false

	static func is_close_to_segment(
		pos: Vector2, snapping_distance: float, s1: Vector2, s2: Vector2
	) -> bool:
		var test_line := (s2 - s1).rotated(deg_to_rad(90)).normalized()
		var from_a := pos - test_line * snapping_distance
		var from_b := pos + test_line * snapping_distance
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

	if !should_propagate or ignore_render:
		# If ignore_render is true this probably beans we are in the process of modifying
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

	manage_signals()
	manage_project_changed(true)
	global.project_about_to_switch.connect(manage_project_changed.bind(false))
	global.camera.zoom_changed.connect(queue_redraw)
	api.signals.signal_project_switched(manage_project_changed.bind(true))

	reset_item_id = api.menu.add_menu_item(api.menu.EDIT, "Auto Set Bones", self)


func menu_item_clicked():
	if current_frame_bones.is_empty():
		update_frame_data()
		queue_redraw()
	var new_data = {}
	for layer_idx: int in api.project.current_project.layers.size():
		var bone_name: StringName = api.project.current_project.layers[layer_idx].name
		if bone_name in current_frame_bones.keys():
			new_data[bone_name] = current_frame_bones[bone_name].reset_bone(
				{"gizmo_origin": Vector2(get_best_origin(layer_idx))}
			)
	current_frame_data = new_data
	save_frame_info(api.project.current_project)
	queue_redraw()
	generate_pose()


## Adds info about any new group cels that are added to the timeline.
func update_frame_data():
	var project = api.project.current_project
	if project.current_frame != current_frame:  # We moved to a different frame
		current_frame_bones.clear()
		selected_gizmo = null
		current_frame_render = null
		current_frame = project.current_frame
		current_frame_data = load_frame_info(project)
		# The if the frame is new, and there is a skeleton for previous frame then
		# copy it to this frame as well.
		if current_frame_data.is_empty() and current_frame != 0:
			current_frame_data = load_frame_info(project, current_frame - 1).duplicate(true)
	# If the layer is newly added then we need to refresh the bone tree.
	if project.layers.size() != prev_layer_count:
		prev_layer_count = project.layers.size()
		generate_heirarchy(current_frame_data)
	save_frame_info(project)


func generate_heirarchy(old_data: Dictionary):
	var invalid_layer_names := old_data.keys()
	for layer in api.project.current_project.layers:
		if !pose_layer and layer.get_layer_type() == 0:  ## If user deleted a pose layer then find new one
			if "Pose Layer" in layer.name:
				assign_pose_layer(layer)
		elif layer.get_layer_type() == 1:  # GroupLayer
			var parent_name = ""
			if layer.parent:
				parent_name = layer.parent.name
			invalid_layer_names.erase(layer.name)
			if not layer.name in old_data.keys():
				old_data[layer.name] = SkeletonGizmo.generate_empty_data(layer.name, parent_name)

		## check connectivity of one of these signals and assume the result for others
		if not layer.name_changed.is_connected(layer_name_changed):
			if not layer == pose_layer and layer.get_layer_type() != 1:
				layer.visibility_changed.connect(generate_pose)
			layer.effects_added_removed.connect(generate_pose)
			layer.name_changed.connect(layer_name_changed.bind(layer, layer.name))
	for layer_name in invalid_layer_names:
		old_data.erase(layer_name)


func _input(_event: InputEvent) -> void:
	var project = api.project.current_project
	if not pose_layer:
		if Input.is_action_just_pressed("left_mouse"):
			## TODO this line may be redundant (investigate later)
			update_frame_data()  ## Checks for pose layer if present
		return
	if not project.layers[pose_layer.index].locked:
		project.layers[pose_layer.index].locked = true
	var mouse_point: Vector2 = api.general.get_canvas().current_pixel

	if selected_gizmo:
		if (
			!selected_gizmo.is_mouse_inside(mouse_point, global.camera.zoom)
			and selected_gizmo.modify_mode == SkeletonGizmo.NONE
		):
			queue_redraw()
			selected_gizmo = null
	if !selected_gizmo:
		for bone in current_frame_bones.values():
			if (
				bone.is_mouse_inside(mouse_point, global.camera.zoom)
				or bone.modify_mode != SkeletonGizmo.NONE
			):
				selected_gizmo = bone
				queue_redraw()
				update_frame_data()
				break
		prev_position = Vector2.INF
		return  # No gizmo matched our needs


	if Input.is_action_pressed("left_mouse"):
		# Check inputs
		if prev_position == Vector2.INF:
			prev_position = mouse_point
		if selected_gizmo.modify_mode == SkeletonGizmo.NONE:
			selected_gizmo.modify_mode = selected_gizmo.current_hover_mode
		else:
			selected_gizmo.current_hover_mode = selected_gizmo.modify_mode
		var offset := mouse_point - prev_position
		if selected_gizmo.modify_mode == SkeletonGizmo.OFFSET:
			if Input.is_key_pressed(KEY_CTRL):
				ignore_render = true
				selected_gizmo.gizmo_origin += offset.rotated(-selected_gizmo.bone_rotation)
				selected_gizmo.start_point = Vector2i(selected_gizmo.rel_to_origin(mouse_point))
			else:
				selected_gizmo.start_point = selected_gizmo.rel_to_origin(mouse_point)
		elif (
			selected_gizmo.modify_mode == SkeletonGizmo.ROTATE
			or selected_gizmo.modify_mode == SkeletonGizmo.SCALE
		):
			var localized_mouse_norm: Vector2 = selected_gizmo.rel_to_start_point(mouse_point).normalized()
			var localized_prev_mouse_norm: Vector2 = selected_gizmo.rel_to_start_point(prev_position).normalized()
			var diff := localized_mouse_norm.angle_to(localized_prev_mouse_norm)
			if Input.is_key_pressed(KEY_CTRL):
				ignore_render = true
				selected_gizmo.gizmo_rotate_origin -= diff
			else:
				selected_gizmo.bone_rotation -= diff
			if selected_gizmo.modify_mode == SkeletonGizmo.SCALE:
				selected_gizmo.gizmo_length = selected_gizmo.rel_to_start_point(mouse_point).length()

		#generate_pose()  ## Uncomment me for live update
		prev_position = mouse_point
	else:
		if selected_gizmo.modify_mode != SkeletonGizmo.NONE:
			generate_pose()  ## Uncomment me for only the final update
			selected_gizmo.modify_mode = SkeletonGizmo.NONE
			selected_gizmo = null


func generate_pose():
	# Do we even need to generate a pose?
	if ignore_render:  # We had set to ignore generation in this cycle.
		ignore_render = false
		return
	var project = api.project.current_project
	if project.layers.find(pose_layer) == -1:  # There is no Pose Layer to render to!!!
		pose_layer = null
		return
	if not pose_layer.visible:  # Pose Layer is invisible (So generating is a waste of time)
		return
	var image = Image.create_empty(project.size.x, project.size.y, false, Image.FORMAT_RGBA8)
	if current_frame_data.is_empty():  # No pose to generate (This is a kind of failsafe)
		project.layers[pose_layer.index].locked = false
		_render_image(project, image)
		project.layers[pose_layer.index].locked = true
		return

	# Start generating
	# (Group visibility is completely ignored while the visibility of other layer types is respected)
	var frame = project.frames[current_frame]
	var previous_ordered_layers: Array[int] = project.ordered_layers
	project.order_layers(current_frame)
	var textures: Array[Image] = []
	var gen = api.general.get_new_shader_image_effect()
	# Nx4 texture, where N is the number of layers and the first row are the blend modes,
	# the second are the opacities, the third are the origins and the fourth are the
	# clipping mask booleans.
	var metadata_image := Image.create_empty(project.layers.size(), 4, false, Image.FORMAT_R8)
	for i in project.layers.size():
		var ordered_index = project.ordered_layers[i]
		var layer = project.layers[ordered_index]
		if layer == pose_layer:
			continue
		# Ignore visibility for group layers
		var include := false if (!layer.visible and layer.get_layer_type() != 1) else true
		var cel = frame.cels[ordered_index]
		var cel_image: Image
		if layer.is_blender():
			cel_image = layer.blend_children(frame)
		else:
			cel_image = layer.display_effects(cel)

		var group_layer = layer.parent
		if is_instance_valid(group_layer):
			_apply_bone(gen, group_layer.name, cel_image)
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
	current_frame_render = image
	_render_image(project, image)
	project.layers[pose_layer.index].locked = true


func _exit_tree() -> void:
	current_frame_render = null
	global.project_about_to_switch.disconnect(manage_project_changed)
	api.signals.signal_project_switched(manage_project_changed, true)
	api.menu.remove_menu_item(api.menu.EDIT, reset_item_id)
	manage_signals(true)


## UPDATERS  (methods that are called through signals)

func manage_signals(is_disconnecting := false):
	api.signals.signal_cel_switched(cel_switched, is_disconnecting)
	api.signals.signal_project_data_changed(project_data_changed, is_disconnecting)
	api.signals.signal_current_cel_texture_changed(texture_changed, is_disconnecting)


# Manages connections of signals that have to be re-determined everytime project switches
func manage_project_changed(should_connect := false) -> void:
	var project = api.project.current_project
	var undo_redo: UndoRedo = project.undo_redo
	if should_connect:
		## Add stuff which connects on project changed
		clean_data()
		undo_redo.version_changed.connect(_reverse_alteration)
		for layer in api.project.current_project.layers:
			if not layer == pose_layer and layer.get_layer_type() != 1:
				layer.visibility_changed.connect(generate_pose)
			layer.effects_added_removed.connect(generate_pose)
			layer.name_changed.connect(layer_name_changed.bind(layer, layer.name))
		return
	## Add stuff which disconnects on project changed
	undo_redo.version_changed.disconnect(_reverse_alteration)
	for layer in api.project.current_project.layers:
		if not layer == pose_layer and layer.get_layer_type() != 1:
			layer.visibility_changed.disconnect(generate_pose)
		layer.effects_added_removed.disconnect(generate_pose)
		layer.name_changed.disconnect(layer_name_changed)


func clean_data():
	selected_gizmo = null
	current_frame_render = null
	current_frame_data.clear()
	current_frame_bones.clear()
	current_frame = -1
	prev_layer_count = 0
	prev_frame_count = 0
	prev_position = Vector2.INF
	ignore_render = false
	pose_layer = null


func texture_changed():
	if not is_pose_layer(
		api.project.current_project.layers[api.project.current_project.current_layer]
	):
		current_frame_render == null
		queue_generate = true


func cel_switched():
	if current_frame_data.is_empty():
		queue_generate = true
	update_frame_data()
	var pose_layer_visible = (api.project.current_project.current_layer == pose_layer.index)
	pose_layer.visible = pose_layer_visible
	if api.project.current_project.current_layer == pose_layer.index:
		if queue_generate:
			queue_generate = false
			generate_pose()
	# Also disable the first root folder
	for layer_idx in range(api.project.current_project.layers.size() - 1, -1, -1):
		var layer = api.project.current_project.layers[layer_idx]
		if layer.get_layer_type() == 1 and not layer.parent:
			api.project.current_project.layers[layer_idx].visible = !pose_layer_visible


func project_data_changed(project):
	if project == api.project.current_project:
		if (
			project.frames.size() != prev_frame_count
			or project.layers.size() != prev_layer_count
		):
			update_frame_data()
			prev_frame_count = project.frames.size()
			prev_layer_count = project.layers.size()
			manage_signals(true)  # Trmporarily disconnect signals
			generate_pose()
			manage_signals()  # Reconnect signals


func layer_name_changed(layer, old_name: String) -> void:
	if layer.get_layer_type() == 1:
		if old_name in current_frame_data.keys():
			var rename_bone: SkeletonGizmo = current_frame_bones[old_name]
			rename_bone.bone_name = layer.name
			var rename_data: Dictionary = current_frame_data[old_name]
			current_frame_data.erase(old_name)
			rename_data["bone_name"] = layer.name
			if layer.parent:
				rename_data["parent_bone_name"] = layer.parent.name
			current_frame_data[layer.name] = rename_data
		else: ## It's a new bone
			current_frame_data[layer.name] = SkeletonGizmo.generate_empty_data(
				layer.name, layer.parent.name
			)
		save_frame_info(api.project.current_project)


func _draw() -> void:
	var project = api.project.current_project
	if current_frame_data.is_empty():
		return
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

	draw_set_transform(gizmo.gizmo_origin)
	draw_circle(
		gizmo.start_point,
		gizmo.START_RADIUS / camera_zoom.x,
		main_color if (gizmo.current_hover_mode == gizmo.OFFSET) else dim_color, false,
		width
	)
	draw_line(
		gizmo.start_point,
		gizmo.start_point + gizmo.end_point,
		main_color if (gizmo.current_hover_mode == gizmo.ROTATE) else dim_color,
		width if (gizmo.current_hover_mode == gizmo.ROTATE) else gizmo.DESELECT_WIDTH / camera_zoom.x
	)
	draw_circle(
		gizmo.start_point + gizmo.end_point,
		gizmo.END_RADIUS / camera_zoom.x,
		main_color if (gizmo.current_hover_mode == gizmo.SCALE) else dim_color,
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
		draw_string(font, Vector2.ZERO, gizmo.bone_name)

func _apply_bone(gen, bone_name: String, cel_image: Image):
	var bone_info: Dictionary = current_frame_data.get(bone_name, {})
	var offset_amount: Vector2i = bone_info.get("start_point", Vector2i.ZERO)
	var pivot := Vector2i(bone_info.get("gizmo_origin", Vector2.ZERO))
	if bone_info.get("bone_rotation", 0) == 0 and offset_amount == Vector2i.ZERO:
		return

	var used_region := cel_image.get_used_rect()
	if used_region.size == Vector2i.ZERO:
		return
	var used_region_with_p := used_region.merge(Rect2i(pivot, Vector2i.ONE))
	var image_to_rotate = cel_image.get_region(used_region)
	## Imprint on a square for rotation (We are doing this so that the image doesn't get clipped as)
	## a result of rotation.
	var diagonal_length := ceili((used_region_with_p.size).length() * 2)
	if diagonal_length % 2 == 0:
		diagonal_length += 1
	var square_image = Image.create_empty(diagonal_length, diagonal_length, false, Image.FORMAT_RGBA8)
	var s_offset: Vector2i = (Vector2(square_image.get_size()) / 2).ceil() + Vector2(used_region.position) - Vector2(pivot)
	square_image.blit_rect(image_to_rotate, Rect2i(Vector2i.ZERO, image_to_rotate.get_size()), s_offset)
	var added_rect = square_image.get_used_rect()

	## Apply Rotation To this Image
	if bone_info.get("bone_rotation", 0) != 0:
		var transformation_matrix := Transform2D(bone_info.get("bone_rotation", 0), Vector2.ZERO)
		var rotate_params := {
			"transformation_matrix": transformation_matrix,
			"pivot": Vector2(0.5, 0.5),
			"ending_angle": bone_info.get("bone_rotation", 0),
			"tolerance": 0,
			"preview": false
		}
		gen.generate_image(square_image, rotate_shader, rotate_params, square_image.get_size())

	cel_image.fill(Color(0, 0, 0, 0))
	cel_image.blit_rect(
		square_image,
		square_image.get_used_rect(),
		(
			used_region.position
			+ (square_image.get_used_rect().position - added_rect.position)
			+ offset_amount
		)
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

func _render_image(project, image: Image):
	var cel_image: Image = project.frames[current_frame].cels[pose_layer.index].get_image()
	cel_image.blit_rect(image, Rect2i(Vector2.ZERO, image.get_size()), Vector2.ZERO)

	if pose_layer.index == project.current_layer:
		project.selected_cels = []
		project.change_cel(current_frame, pose_layer.index)


func _reverse_alteration():
	if api.project.current_project.layers.find(pose_layer) == -1:
		pose_layer = null
		return
	if current_frame_render:
		manage_signals(true)
		_render_image(api.project.current_project, current_frame_render)
		manage_signals()


func is_pose_layer(layer) -> bool:
	return layer.get_meta("SkeletorPoseLayer", false)


func assign_pose_layer(layer):
	layer.set_meta("SkeletorPoseLayer", true)
	pose_layer = layer
	if pose_layer.visibility_changed.is_connected(generate_pose):
		pose_layer.visibility_changed.disconnect(generate_pose)


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


func save_frame_info(project):
	if project:
		if current_frame >= 0 and current_frame < project.frames.size():
			project.frames[current_frame].set_meta("SkeletorBone", var_to_str(current_frame_data))
			queue_redraw()


func load_frame_info(project, frame_number:= current_frame) -> Dictionary:
	if project:
		if current_frame >= 0 and current_frame < project.frames.size():
			var data = project.frames[frame_number].get_meta("SkeletorBone", {})
			if typeof(data) == TYPE_STRING:
				data = str_to_var(data)
			if typeof(data) == TYPE_DICTIONARY:  ## Successful conversion
				for bone in data.keys():
					for bone_data in data[bone].keys():
						if typeof(data[bone][bone_data]) == TYPE_STRING:
							if str_to_var(data[bone][bone_data]):  ## Succesful sub-data conversion
								data[bone][bone_data] = str_to_var(data[bone][bone_data])
				return data
	return {}
