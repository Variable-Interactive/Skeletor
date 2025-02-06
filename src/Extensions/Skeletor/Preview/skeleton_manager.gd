extends Node2D

var api: Node
var global: Node
var canvas: Node
var skeleton_info: Dictionary
var current_gizmo: SkeletonGizmo
var current_frame: int = 0
var prev_position: Vector2i
var modify_node := SkeletonGizmo.NONE
# The shader is located in pixelorama
var blend_layer_shader = load("res://src/Shaders/BlendLayers.gdshader")
var pose_layer


class SkeletonGizmo:
	## This class is used/created to perform calculations
	enum {NONE, OFFSET, ROTATE}
	const InteractionDistance = 20

	var gizmo_origin: Vector2i
	var start_point: Vector2i  ## This is relative to the gizmo_origin
	var end_point: Vector2i  ## This is relative to the gizmo_origin
	var gizmo_rotation: float
	var gizmo_length: int:
		set(value):
			gizmo_length = value
			end_point = Vector2i(Vector2(value, 0).rotated(deg_to_rad(gizmo_rotation)))
		get:
			return int(end_point.distance_to(Vector2.ZERO))
	var current_hover_mode = NONE

	func _init(_gizmo_origin, _start_point, _gizmo_length, _gizmo_rotation) -> void:
		gizmo_rotation = float(gizmo_rotation)
		gizmo_origin = Vector2i(_gizmo_origin)
		start_point = _start_point
		gizmo_length = int(_gizmo_length)

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


func _ready() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	canvas = get_parent()
	global = api.general.get_global()
	#api.project.add_new_layer(api.project.current_project.layers.size() - 1, "Skeletor Pose", 0)
	#pose_layer = api.project.current_project.layers[-1]


func _draw() -> void:
	var project = api.project.current_project
	if not project.get_current_cel().get_class_name() == "GroupCel":
		return

	_update_frame_data()
	for instance_id: int in skeleton_info[project.current_frame].keys():
		if is_instance_id_valid(instance_id):
			_generate_gizmo(
				skeleton_info[project.current_frame][instance_id],
				instance_id == project.get_current_cel().get_instance_id()
			)
		else:
			skeleton_info[project.current_frame].erase(instance_id)


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
				frame_dict[cel.get_instance_id()] = _generate_empty_data()


## Generates a gizmo (for preview) based on the given data
func _generate_gizmo(data: Dictionary, is_current_cel) -> void:
	var gizmo_origin = data.get("gizmo_origin", Vector2i.ZERO)
	var start_point = data.get("start_point", Vector2i.ZERO)
	var gizmo_length = data.get("gizmo_length", 20)
	var gizmo_rotation = data.get("gizmo_rotation", 0.0)
	var gizmo = SkeletonGizmo.new(gizmo_origin, start_point, gizmo_length, gizmo_rotation)
	if is_current_cel:
		current_gizmo = gizmo
	var color := Color.WHITE if is_current_cel else Color.GRAY
	var width: float = (2.0 if is_current_cel else 1.0) / global.camera.zoom.x
	var radius: float = 4.0 / global.camera.zoom.x

	# Offset Gizmo
	draw_set_transform(gizmo_origin)
	draw_circle(gizmo.start_point, radius, color, false, width)
	#draw_circle(gizmo.get_global_coordinates()[1], radius * 2, color, false, width)
	#draw_line(
		#gizmo.get_global_coordinates()[0],
		#gizmo.get_global_coordinates()[1],
		#color,
		#width
	#)


func _generate_empty_data() -> Dictionary:
	return {
		"gizmo_origin": Vector2i.ZERO,
		"start_point": Vector2i.ZERO,
		"gizmo_length": 20,
		"gizmo_rotation": 0
	}


func _input(_event: InputEvent) -> void:
	if not api.project.get_current_cel().get_class_name() == "GroupCel":
		return
	var mouse_point := Vector2i(canvas.current_pixel)
	var current_cel_id: int = api.project.get_current_cel().get_instance_id()

	if (
		current_gizmo.is_mouse_inside(mouse_point, global.camera.zoom)
		or modify_node != SkeletonGizmo.NONE
	):
		if prev_position == Vector2i.MAX:
			prev_position = mouse_point
		if Input.is_action_pressed("left_mouse"):
			if modify_node == SkeletonGizmo.NONE:
				modify_node = current_gizmo.current_hover_mode
			var cel_info = skeleton_info[current_frame][current_cel_id]
			var offset := mouse_point - prev_position

			match modify_node:
				SkeletonGizmo.OFFSET:
					if Input.is_key_pressed(KEY_CTRL):
						cel_info["gizmo_origin"] += offset
					else:
						cel_info["start_point"] = current_gizmo.localize(mouse_point)
				SkeletonGizmo.OFFSET:
					var angle = Vector2.RIGHT.angle_to(offset)
					current_gizmo.end_point += offset
					cel_info["gizmo_length"] = current_gizmo.gizmo_length
					cel_info["gizmo_rotation"] = angle
			prev_position = mouse_point
			#generate_pose()
			queue_redraw()
		else:
			modify_node = SkeletonGizmo.NONE
	else:
		prev_position = Vector2i.MAX


## Blends canvas layers into passed image starting from the origin position
func generate_pose() -> void:
	var project = api.project.current_project
	var frame = project.frames[current_frame]
	var previous_ordered_layers: Array[int] = project.ordered_layers
	project.order_layers(current_frame)
	var textures: Array[Image] = []
	# Nx4 texture, where N is the number of layers and the first row are the blend modes,
	# the second are the opacities, the third are the origins and the fourth are the
	# clipping mask booleans.
	var metadata_image := Image.create(project.layers.size(), 4, false, Image.FORMAT_R8)
	for i in project.layers.size():
		var ordered_index = project.ordered_layers[i]
		var layer = project.layers[ordered_index]
		if layer == pose_layer:
			continue
		var include := true if layer.is_visible_in_hierarchy() else false
		print(layer.name)
		var cel = frame.cels[ordered_index]
		if layer.is_blender():
			var cel_image = layer.blend_children(frame)
			textures.append(cel_image)
		else:
			var cel_image = layer.display_effects(cel)
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
	var gen = api.general.get_new_shader_image_effect()
	gen.generate_image(blended, blend_layer_shader, params, project.size)
	image.blend_rect(blended, Rect2i(Vector2i.ZERO, project.size), Vector2i.ZERO)
	# Re-order the layers again to ensure correct canvas drawing
	project.ordered_layers = previous_ordered_layers


func set_layer_metadata_image(
	layer, cel, image, index, include := true
) -> void:
	# Store the blend mode
	image.set_pixel(index, 0, Color(layer.blend_mode / 255.0, 0.0, 0.0, 0.0))
	# Store the opacity
	if layer.is_visible_in_hierarchy() and include:
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
