extends Node2D

var api: Node
var global: Node
var canvas: Node
var current_project_skeleton_info: Dictionary
var selected_gizmo: SkeletonGizmo
var current_frame_bones: Dictionary
var current_frame: int = -1
var current_frame_render: Image  # Use this to avoid altering image during undo/redo
var prev_position: Vector2
var prev_layer_count: int = 0
# The shader is located in pixelorama
var blend_layer_shader = load("res://src/Shaders/BlendLayers.gdshader")
var rotate_shader := load("res://src/Shaders/Effects/Rotation/cleanEdge.gdshader")
var offset_shader := preload("res://src/Extensions/Skeletor/Shaders/OffsetPixels.gdshader")
var pose_layer


class SkeletonGizmo:
	## This class is used/created to perform calculations
	enum {NONE, OFFSET, ROTATE}
	const InteractionDistance = 20

	signal update_property

	# Variables set using serialize()
	var bone_name: String
	var parent_bone_name: String
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
			if value < 10:
				value = 10
			gizmo_length = value

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
			"gizmo_length": 20,
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
		if (
			(start_point + end_point).distance_to(local_mouse_pos)
			<= InteractionDistance / camera_zoom.x
		):
				current_hover_mode = ROTATE
				return true
		current_hover_mode = NONE
		return false

	func rel_to_origin(pos: Vector2) -> Vector2:
		return pos - gizmo_origin

	func rel_to_start_point(pos: Vector2) -> Vector2:
		return pos - gizmo_origin - start_point

	func rel_to_global(pos: Vector2) -> Vector2:
		return pos + gizmo_origin


func update_bone_property(parent_name: String, property: String, should_propagate: bool, diff, project):
	## TODO: generally it should take skeleton info from project's metadata (fix this later)
	if not is_instance_valid(project):
		return

	# First we update data of parent bone
	if not parent_name in current_project_skeleton_info[current_frame].keys():
		update_frame_data()
		queue_redraw()
	var parent: SkeletonGizmo = current_frame_bones[parent_name]
	if parent.get(property) != current_project_skeleton_info[current_frame][parent_name][property]:
		current_project_skeleton_info[current_frame][parent_name][property] = parent.get(property)

	if not should_propagate:
		return

	for layer in project.layers:  ## update first child (This will trigger a chain process)
		if layer.get_layer_type() == 1 and layer.parent:  # GroupLayer
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
	canvas = get_parent()
	global = api.general.get_global()

	await get_tree().process_frame
	await get_tree().process_frame

	var project = api.project.current_project
	manage_signals()
	manage_project_changed(true)
	global.project_about_to_switch.connect(manage_project_changed.bind(false))
	api.signals.signal_project_switched(manage_project_changed.bind(true))

	generate_pose_layer(project)


## Adds info about any new group cels that are added to the timeline.
func update_frame_data():
	## TODO for some reason the data is not updating if group name changes
	var project = api.project.current_project
	if project.current_frame != current_frame:
		current_frame_bones.clear()
		selected_gizmo = null
		current_frame = project.current_frame

		if not current_frame in current_project_skeleton_info.keys():
			if current_frame - 1 in current_project_skeleton_info.keys():
				current_project_skeleton_info[current_frame] = current_project_skeleton_info[current_frame - 1].duplicate(true)
			else:
				current_project_skeleton_info[current_frame] = {}
			var frame_dict: Dictionary = current_project_skeleton_info[current_frame]
			generate_heirarchy(frame_dict, project)

	if project.layers.size() != prev_layer_count:
		prev_layer_count = project.layers.size()
		var frame_dict: Dictionary = current_project_skeleton_info[current_frame]
		generate_heirarchy(frame_dict, project)


func generate_heirarchy(old_data: Dictionary, project):
	var canon_layer_names = []
	for layer in project.layers:
		if !pose_layer and layer.get_layer_type() == 0:
			if "Pose Layer" in layer.name:
				pose_layer = layer
		if layer.get_layer_type() == 1:  # GroupLayer
			var parent_name = ""
			if layer.parent:
				parent_name = layer.parent.name
			canon_layer_names.append(layer.name)
			if not layer.name in old_data.keys():
				old_data[layer.name] = SkeletonGizmo.generate_empty_data(layer.name, parent_name)
		else:
			if not layer.visibility_changed.is_connected(generate_pose):
				layer.visibility_changed.connect(generate_pose)
	for layer_name in old_data.keys():
		if not layer_name in canon_layer_names:
			old_data.erase(layer_name)


func _input(_event: InputEvent) -> void:
	var project = api.project.current_project
	if not pose_layer:
		if Input.is_action_just_pressed("left_mouse"):
			## TODO this line may be redundant (investigate later)
			update_frame_data()  ## Checks for pose layer if present
		return
	if not project.layers[project.current_layer].locked:
		project.layers[project.current_layer].locked = true
	var mouse_point: Vector2 = canvas.current_pixel

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
		var offset := mouse_point - prev_position
		match selected_gizmo.modify_mode:
			SkeletonGizmo.OFFSET:
				if Input.is_key_pressed(KEY_CTRL):
					selected_gizmo.gizmo_origin += offset.rotated(-selected_gizmo.bone_rotation)
					selected_gizmo.start_point = Vector2i(selected_gizmo.rel_to_origin(mouse_point))
				else:
					selected_gizmo.start_point = selected_gizmo.rel_to_origin(mouse_point)
			SkeletonGizmo.ROTATE:
				var localized_mouse_norm: Vector2 = selected_gizmo.rel_to_start_point(mouse_point).normalized()
				var localized_prev_mouse_norm: Vector2 = selected_gizmo.rel_to_start_point(prev_position).normalized()
				var diff := localized_mouse_norm.angle_to(localized_prev_mouse_norm)
				if Input.is_key_pressed(KEY_CTRL):
					selected_gizmo.gizmo_rotate_origin -= diff
				else:
					selected_gizmo.bone_rotation -= diff

		prev_position = mouse_point
		generate_pose()
	else:
		if selected_gizmo.modify_mode != SkeletonGizmo.NONE:
			selected_gizmo.modify_mode = SkeletonGizmo.NONE
			selected_gizmo = null
	queue_redraw()


## Blends canvas layers into passed image starting from the origin position
func generate_pose():
	## TODO I noticed that sometimes the area of image gets cropped... (Investigate Why)
	var project = api.project.current_project
	if project.layers.find(pose_layer) == -1:
		pose_layer = null
		return
	if not pose_layer.visible:
		return
	var image = Image.create_empty(project.size.x, project.size.x, false, Image.FORMAT_RGBA8)

	if current_project_skeleton_info.get(0, {}).keys().size() == 0:  # No pose to generate
		project.layers[project.current_layer].locked = false
		_add_pose(project, image)
		project.layers[project.current_layer].locked = true
		return

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
	project.layers[project.current_layer].locked = false
	current_frame_render = image
	_add_pose(project, image)
	project.layers[project.current_layer].locked = true


func _exit_tree() -> void:
	current_frame_render = null
	global.project_about_to_switch.disconnect(manage_project_changed)
	api.signals.signal_project_switched(manage_project_changed, true)
	manage_signals(true)


## UPDATERS  (methods that are called through signals)

func manage_signals(is_disconnecting := false):
	## TODO: fix signal_current_cel_texture_changed later (currently it live updates)
	api.signals.signal_cel_switched(cel_switched, is_disconnecting)
	api.signals.signal_project_data_changed(project_data_changed, is_disconnecting)
	api.signals.signal_current_cel_texture_changed(texture_changed, is_disconnecting)


# Manages connections of signals that have to be re-determined everytime project switches
func manage_project_changed(should_connect := false) -> void:
	var project = api.project.current_project
	var undo_redo: UndoRedo = project.undo_redo
	if should_connect:
		## Add stuff which connects on project changed
		undo_redo.version_changed.connect(_reverse_alteration)
		for layer in api.project.current_project.layers:
			if not layer == pose_layer and layer.get_layer_type() != 1:
				layer.visibility_changed.connect(generate_pose)
			layer.effects_added_removed.connect(generate_pose)
			layer.name_changed.connect(update_frame_data)
		return
	## Add stuff which disconnects on project changed
	undo_redo.version_changed.disconnect(_reverse_alteration)
	for layer in api.project.current_project.layers:
		if not layer == pose_layer and layer.get_layer_type() != 1:
			layer.visibility_changed.disconnect(generate_pose)
		layer.effects_added_removed.disconnect(generate_pose)
		layer.name_changed.disconnect(update_frame_data)

func texture_changed():
	var project = api.project.current_project
	if not "Pose Layer" in project.layers[project.current_layer].name:
		generate_pose()

func cel_switched():
	queue_redraw()
	var queue_generate := false
	if not current_frame in current_project_skeleton_info.keys():
		queue_generate = true
	update_frame_data()
	if queue_generate:
		generate_pose()

func project_data_changed(project):
	if project == api.project.current_project:
		if (
			project.frames.size() != current_project_skeleton_info.keys().size()
			or project.layers.size() != prev_layer_count
		):
			update_frame_data()
			prev_layer_count = project.layers.size()
			manage_signals(true)  # Trmporarily disconnect signals
			queue_redraw()
			generate_pose()
			manage_signals()  # Reconnect signals

func _draw() -> void:
	var project = api.project.current_project
	if current_project_skeleton_info.is_empty():
		return
	var group_names: Array = current_project_skeleton_info[project.current_frame].keys()
	for bone_name: String in group_names:
		if bone_name in current_frame_bones.keys():
			var bone = current_frame_bones[bone_name]
			bone.serialize(current_project_skeleton_info[project.current_frame][bone_name])
			if not bone.update_property.is_connected(update_bone_property):
				bone.update_property.connect(update_bone_property.bind(project))
		else:
			var bone = SkeletonGizmo.new()
			bone.serialize(current_project_skeleton_info[project.current_frame][bone_name])
			bone.update_property.connect(update_bone_property.bind(project))
			current_frame_bones[bone_name] = bone
		_draw_gizmo(current_frame_bones[bone_name], global.camera.zoom)


## Helper methods (methods that are part of other methods)

## Generates a gizmo (for preview) based on the given data
func _draw_gizmo(gizmo: SkeletonGizmo, camera_zoom: Vector2) -> void:
	if not "Pose Layer" in api.project.current_project.layers[api.project.current_project.current_layer].name:
		return
	if !pose_layer:
		pose_layer = api.project.current_project.layers[api.project.current_project.current_layer]
	var color := Color.WHITE if (gizmo == selected_gizmo) else Color.GRAY
	var width: float = (2.0 if (gizmo == selected_gizmo) else 1.0) / camera_zoom.x
	var radius: float = 4.0 / camera_zoom.x
	# Offset Gizmo
	draw_set_transform(gizmo.gizmo_origin)
	draw_circle(gizmo.start_point, radius, color, false, width)
	draw_circle(gizmo.start_point + gizmo.end_point, radius * 2, color, false, width)
	draw_line(
		gizmo.start_point,
		gizmo.start_point + gizmo.end_point,
		color,
		width
	)
	if gizmo.parent_bone_name in current_frame_bones.keys():
		var parent_bone: SkeletonGizmo = current_frame_bones[gizmo.parent_bone_name]
		draw_dashed_line(
			gizmo.start_point,
			gizmo.rel_to_origin(parent_bone.rel_to_global(parent_bone.start_point)),
			color,
			width,
		)

func _apply_bone(gen, bone_name: String, cel_image: Image):
	var bone_info: Dictionary = current_project_skeleton_info[current_frame].get(bone_name, {})

	var offset_amount: Vector2i = bone_info.get("start_point", Vector2.ZERO)
	var offset_params := {"offset": offset_amount, "wrap_around": false}
	gen.generate_image(cel_image, offset_shader, offset_params, cel_image.get_size())

	var transformation_matrix := Transform2D(bone_info.get("bone_rotation", 0), Vector2.ZERO)
	var pivot = Vector2(bone_info.get("gizmo_origin", Vector2.ZERO)) + Vector2(offset_amount)
	var rotate_params := {
		"transformation_matrix": transformation_matrix,
		"pivot": pivot / Vector2(cel_image.get_size()),
		"ending_angle": bone_info.get("bone_rotation", 0),
		"tolerance": 0,
		"preview": false
	}
	gen.generate_image(cel_image, rotate_shader, rotate_params, cel_image.get_size())

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

func _add_pose(project, image: Image):
	var cel_image: Image = project.frames[current_frame].cels[pose_layer.index].get_image()
	cel_image.blit_rect(image, Rect2i(Vector2.ZERO, image.get_size()), Vector2.ZERO)
	project.selected_cels = []
	project.change_cel(current_frame, pose_layer.index)


func _reverse_alteration():
	if current_frame_render:
		_add_pose(api.project.current_project, current_frame_render)


func generate_pose_layer(project):
	if project.layers.size() > 0:
		if project.layers[-1].get_layer_type() == 1: # GroupLayer
			# There is a slight bug in the layer addition api (name gets assigned to wrong layer),
			# this compensates for it
			var group_name = project.layers[-1].name
			api.project.add_new_layer(project.layers.size() - 1, group_name)
			# select the GroupLayer and move it down
			api.project.select_cels([[0, project.layers.size() - 2]])
			global.animation_timeline.change_layer_order(true)
		else:
			if (
				project.layers[-1].get_layer_type() == 0  # PixelLayer
				and "Pose Layer" in project.layers[-1].name
			):
				pose_layer = project.layers[-1]
				project_data_changed(project)
				# generate initial pose
				generate_pose()
				return
			api.project.add_new_layer(project.layers.size() - 1)
		pose_layer = project.layers[-1]
		pose_layer.name = "Pose Layer (DO NOT CHANGE)"
		project_data_changed(project)

		# generate initial pose
		generate_pose()
