extends Node2D

var api: Node
var global: Node
var canvas: Node
var skeleton_info: Dictionary
var selected_gizmo: SkeletonGizmo
var bones: Array[SkeletonGizmo]
var current_frame: int = 0
var prev_position: Vector2i
# The shader is located in pixelorama
var blend_layer_shader = load("res://src/Shaders/BlendLayers.gdshader")
var offset_shader := preload("res://src/Extensions/Skeletor/Shaders/OffsetPixels.gdshader")
var pose_layer


class SkeletonGizmo:
	## This class is used/created to perform calculations
	enum {NONE, OFFSET, ROTATE}
	const InteractionDistance = 20

	signal update_property

	var bone_id: int
	var parent_bone_id: int
	var gizmo_origin: Vector2i:
		set(value):
			var diff = value - gizmo_origin
			gizmo_origin = value
			update_property.emit(bone_id ,"gizmo_origin", diff)
	var start_point: Vector2i:  ## This is relative to the gizmo_origin
		set(value):
			var diff = value - start_point
			start_point = value
			update_property.emit(bone_id ,"start_point", diff)
	var end_point: Vector2i  ## This is relative to the gizmo_origin
	var gizmo_rotation: float
	var gizmo_length: int:
		set(value):
			gizmo_length = value
			end_point = Vector2i(Vector2(value, 0).rotated(deg_to_rad(gizmo_rotation)))
		get:
			return int(end_point.distance_to(Vector2.ZERO))
	var current_hover_mode = NONE
	var modify_mode := SkeletonGizmo.NONE

	func serialize(data: Dictionary):
		gizmo_origin = data.get("gizmo_origin", Vector2i.ZERO)
		start_point = data.get("start_point", Vector2i.ZERO)
		gizmo_length = data.get("gizmo_length", 20)
		gizmo_rotation = data.get("gizmo_rotation", 0.0)
		bone_id = data.get("bone_id", -1)
		parent_bone_id = data.get("parent_bone_id", -1)

	func is_mouse_inside(mouse_position: Vector2i, camera_zoom) -> bool:
		if (start_point + gizmo_origin).distance_to(mouse_position) <= InteractionDistance / camera_zoom.x:
				current_hover_mode = OFFSET
				return true
		#if (
			#(start_point + end_point).distance_to(correct_mouse_pos)
			#<= InteractionDistance / camera_zoom.x
		#):
				#current_hover_mode = ROTATE
				#return true
		current_hover_mode = NONE
		return false

	func localize(pos: Vector2i):
		return pos - gizmo_origin


func update_first_child(parent_id ,property , diff):
	for bone: SkeletonGizmo in bones:
		if is_instance_valid(bone):
			if bone.parent_bone_id == parent_id:
				skeleton_info[current_frame][bone.bone_id][property] += diff
				bone.set(property, skeleton_info[current_frame][bone.bone_id][property])


func _ready() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	canvas = get_parent()
	global = api.general.get_global()
	await get_tree().process_frame
	await get_tree().process_frame
	var project = api.project.current_project
	if project.layers.size() > 0:
		_update_frame_data()
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
				# generate initial pose
				api.project.set_pixelcel_image(generate_pose(), current_frame, pose_layer.index)
				project.layers[project.current_layer].locked = true
				return
			api.project.add_new_layer(project.layers.size() - 1)
		pose_layer = project.layers[-1]
		pose_layer.name = "Pose Layer (DO NOT CHANGE)"

		# generate initial pose
		api.project.set_pixelcel_image(generate_pose(), current_frame, pose_layer.index)
		project.layers[project.current_layer].locked = true


func _draw() -> void:
	var project = api.project.current_project
	if not "Pose Layer" in project.layers[project.current_layer].name:
		return

	_update_frame_data()
	var group_ids: Array = skeleton_info[project.current_frame].keys()
	bones.resize(group_ids.size())
	for instance_id: int in group_ids:
		var bone_idx = group_ids.find(instance_id)
		if is_instance_id_valid(instance_id):
			if bones[bone_idx] != null:
				bones[bone_idx].serialize(skeleton_info[project.current_frame][instance_id])
				if not bones[bone_idx].update_property.is_connected(update_first_child):
					bones[bone_idx].update_property.connect(update_first_child)
			else:
				var bone = SkeletonGizmo.new()
				bone.serialize(skeleton_info[project.current_frame][instance_id])
				bone.update_property.connect(update_first_child)
				bones[bone_idx] = bone
			draw_gizmo(bones[bone_idx], global.camera.zoom)
		else:
			skeleton_info[project.current_frame].erase(instance_id)


## Generates a gizmo (for preview) based on the given data
func draw_gizmo(gizmo: SkeletonGizmo, camera_zoom: Vector2) -> void:
	var color := Color.WHITE if (gizmo == selected_gizmo) else Color.GRAY
	var width: float = (2.0 if (gizmo == selected_gizmo) else 1.0) / camera_zoom.x
	var radius: float = 4.0 / camera_zoom.x

	# Offset Gizmo
	draw_set_transform(gizmo.gizmo_origin)
	draw_circle(gizmo.start_point, radius, color, false, width)
	#draw_circle(gizmo.get_global_coordinates()[1], radius * 2, color, false, width)
	#draw_line(
		#gizmo.get_global_coordinates()[0],
		#gizmo.get_global_coordinates()[1],
		#color,
		#width
	#)


## Adds info about any new group cels that are added to the timeline.
## Old info is overwritten, not re-written
func _update_frame_data():
	var project = api.project.current_project
	current_frame = project.current_frame
	if not current_frame in skeleton_info.keys():
		skeleton_info[current_frame] = {}

	# It is expected for garbage keys to be present in this dictionary.
	# They will be removed later in _draw()
	var frame_dict: Dictionary = skeleton_info[current_frame]
	for cel: RefCounted in project.frames[current_frame].cels:
		if cel.get_class_name() == "GroupCel":
			if not cel.get_instance_id() in frame_dict.keys():
				var layer = project.layers[project.frames[current_frame].cels.find(cel)]
				var parent_bone_id = -1
				if layer.parent:
					parent_bone_id = project.frames[current_frame].cels[layer.parent.index].get_instance_id()
				frame_dict[cel.get_instance_id()] = _generate_empty_data(cel.get_instance_id(), parent_bone_id)


func _generate_empty_data(bone_id: int, parent_bone_id: int) -> Dictionary:
	return {
		"gizmo_origin": Vector2i.ZERO,
		"start_point": Vector2i.ZERO,
		"gizmo_length": 20,
		"gizmo_rotation": 0,
		"bone_id": bone_id,
		"parent_bone_id": parent_bone_id
	}


func _input(_event: InputEvent) -> void:
	var project = api.project.current_project
	if not "Pose Layer" in project.layers[project.current_layer].name:
		return
	if not project.layers[project.current_layer].locked:
		project.layers[project.current_layer].locked = true
	var mouse_point := Vector2i(canvas.current_pixel)

	if selected_gizmo:
		if (
			(
				!selected_gizmo.is_mouse_inside(mouse_point, global.camera.zoom)
				and selected_gizmo.modify_mode == SkeletonGizmo.NONE
			)
		):
			selected_gizmo = null
	if !selected_gizmo:
		for bone in bones:
			if (
				bone.is_mouse_inside(mouse_point, global.camera.zoom)
				or bone.modify_mode != SkeletonGizmo.NONE
			):
				selected_gizmo = bone
				break
		prev_position = Vector2i.MAX
		return  # No gizmo matched our needs

	# Check inputs
	if prev_position == Vector2i.MAX:
		prev_position = mouse_point
	if Input.is_action_pressed("left_mouse"):
		if selected_gizmo.modify_mode == SkeletonGizmo.NONE:
			selected_gizmo.modify_mode = selected_gizmo.current_hover_mode
		var cel_info = skeleton_info[current_frame][selected_gizmo.bone_id]
		var offset := mouse_point - prev_position

		match selected_gizmo.modify_mode:
			SkeletonGizmo.OFFSET:
				if Input.is_key_pressed(KEY_CTRL):
					cel_info["gizmo_origin"] += offset
					selected_gizmo.gizmo_origin = cel_info["gizmo_origin"]
				else:
					cel_info["start_point"] = selected_gizmo.localize(mouse_point)
					selected_gizmo.start_point = cel_info["start_point"]
			SkeletonGizmo.OFFSET:
				var angle = Vector2.RIGHT.angle_to(offset)
				selected_gizmo.end_point += offset
				cel_info["gizmo_length"] = selected_gizmo.gizmo_length
				cel_info["gizmo_rotation"] = angle
		prev_position = mouse_point
		queue_redraw()
	else:
		if selected_gizmo.modify_mode != SkeletonGizmo.NONE:
			project.layers[project.current_layer].locked = false
			api.project.set_pixelcel_image(generate_pose(), current_frame, pose_layer.index)
			selected_gizmo.modify_mode = SkeletonGizmo.NONE
			project.layers[project.current_layer].locked = true



func apply_bone(gen, cel_id: int, cel_image: Image):
	var bone_info: Dictionary = skeleton_info[current_frame].get(cel_id, {})
	var offset_amount = bone_info.get("start_point", Vector2i.ZERO)
	var params := {"offset": offset_amount, "wrap_around": false}
	gen.generate_image(cel_image, offset_shader, params, cel_image.get_size())


## Blends canvas layers into passed image starting from the origin position
func generate_pose() -> Image:
	var project = api.project.current_project
	var frame = project.frames[current_frame]
	var previous_ordered_layers: Array[int] = project.ordered_layers
	project.order_layers(current_frame)
	var textures: Array[Image] = []
	var gen = api.general.get_new_shader_image_effect()
	# Nx4 texture, where N is the number of layers and the first row are the blend modes,
	# the second are the opacities, the third are the origins and the fourth are the
	# clipping mask booleans.
	var metadata_image := Image.create(project.layers.size(), 4, false, Image.FORMAT_R8)
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
			var bone_id: int = project.frames[current_frame].cels[group_layer.index].get_instance_id()
			apply_bone(gen, bone_id, cel_image)
		textures.append(cel_image)
		if (
			layer.is_blended_by_ancestor()
		):
			include = false
		set_layer_metadata_image(layer, cel, metadata_image, ordered_index, include)

	var image = Image.create(project.size.x, project.size.x, false, Image.FORMAT_RGBA8)
	var texture_array := Texture2DArray.new()
	texture_array.create_from_images(textures)
	var params := {
		"layers": texture_array,
		"metadata": ImageTexture.create_from_image(metadata_image),
	}
	var blended := Image.create(project.size.x, project.size.y, false, image.get_format())
	gen.generate_image(blended, blend_layer_shader, params, project.size)
	image.blend_rect(blended, Rect2i(Vector2i.ZERO, project.size), Vector2i.ZERO)
	# Re-order the layers again to ensure correct canvas drawing
	project.ordered_layers = previous_ordered_layers
	return image


func set_layer_metadata_image(
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
