class_name SkeletonBone
extends RefCounted
## This class is used/created to perform calculations

enum RotationAlgorithm { CLEANEDGE, OMNISCALE, NNS }
enum {NONE, DISPLACE, ROTATE, EXTEND}  ## I planned to add scaling too but decided to give up

const InteractionDistance = 20
const MIN_LENGTH: float = 10
const START_RADIUS: float = 6
const END_RADIUS: float = 4
const WIDTH: float = 2
const DESELECT_WIDTH: float = 1

signal bone_set_updated

# Variables set using serialize()
var bone_name: String
var parent_bone_name: String:
	set(value):
		parent_bone_name = value
		update_bone_property("parent_bone_name", false, "")
var gizmo_origin: Vector2:
	set(value):
		var diff = value - gizmo_origin
		if not diff.is_equal_approx(Vector2.ZERO):
			gizmo_origin = value
			update_bone_property("gizmo_origin", false, diff)
var gizmo_rotate_origin: float = 0:  ## Unit is Radians
	set(value):
		var diff = value - gizmo_rotate_origin
		if not is_equal_approx(diff, 0):
			gizmo_rotate_origin = wrapf(value, -PI, PI)
			update_bone_property("gizmo_rotate_origin", false, diff)
var start_point: Vector2:  ## This is relative to the gizmo_origin
	set(value):
		var diff = value - start_point
		if not diff.is_equal_approx(Vector2.ZERO):
			start_point = value
			update_bone_property("start_point", !should_update_silently, diff)
var bone_rotation: float = 0:  ## This is relative to the gizmo_rotate_origin (Radians)
	set(value):
		var diff = value - bone_rotation
		if not is_equal_approx(diff, 0):
			bone_rotation = wrapf(value, -PI, PI)
			update_bone_property("bone_rotation", !should_update_silently, diff)
var transformation_algorithm: int = 0:  ## points to DrawingAlgos.RotationAlgorithm
	set(value):
		if value != transformation_algorithm:
			transformation_algorithm = value
			update_bone_property("transformation_algorithm", !should_update_silently, value)
var gizmo_length: int = int(MIN_LENGTH):
	set(value):
		var diff = value - gizmo_length
		if diff != 0:
			if value < int(MIN_LENGTH):
				value = int(MIN_LENGTH)
				diff = 0
			gizmo_length = value
			update_bone_property("gizmo_length", false, diff)

# Properties determined using above variables
var end_point: Vector2:  ## This is relative to the gizmo_origin
	get():
		return Vector2(gizmo_length, 0).rotated(gizmo_rotate_origin + bone_rotation)

var modify_mode: int = SkeletonBone.NONE:
	set(value):
		modify_mode = value
		bone_set_updated.emit()
var ignore_rotation_hover := false
var should_update_silently := false
var _bone_set: Dictionary[String, SkeletonBone]  # Influence of the bone
var _old_hover := NONE


func _init(
	bone_set: Dictionary[String, SkeletonBone], data := {}
) -> void:
	deserialize(data, true)
	_bone_set = bone_set


func get_interaction_distance(zoom_level: float) -> float:
	return clampf(InteractionDistance / zoom_level, 0, gizmo_length * 0.2)


## Checks if the bone's parent is a valid part of the skeleton
func is_bone_parent_valid() -> bool:
	return parent_bone_name in _bone_set.keys()


## If a propagatable property (movement, rotation) is done on a SkeletonBone object, this method
## Gets called automatically to update/transform all it's children automatically as well
func update_bone_property(property: String, should_propagate: bool, diff) -> void:
	if not _bone_set:
		return
	if not _bone_set.values().has(self):  # Haven been added to the set yet
		return
	# Do not proceed further if a property isn't meant to propagate
	if !should_propagate:
		bone_set_updated.emit()
		return
	for bone: SkeletonBone in _bone_set.values():  ## update first child (This will trigger a chain process)
		if bone.parent_bone_name == bone_name:
			bone.set(property, bone.get(property) + diff)
			if property == "transformation_algorithm":
				bone.transformation_algorithm = diff
				continue
			if _bone_set.has(bone_name) and property == "bone_rotation":
				var displacement := rel_to_start_point(
					bone.rel_to_canvas(bone.start_point)
				)
				displacement = displacement.rotated(diff)
				bone.start_point = bone.rel_to_origin(
					rel_to_canvas(start_point) + displacement
				)
	bone_set_updated.emit()


func deserialize(data: Dictionary, silent_update := false) -> void:
	should_update_silently = silent_update
	# These need conversion before setting
	if typeof(data.get("gizmo_origin", gizmo_origin)) == TYPE_STRING:
		data["gizmo_origin"] = str_to_var(data.get("gizmo_origin", var_to_str(gizmo_origin)))

	if typeof(data.get("start_point", start_point)) == TYPE_STRING:
		data["start_point"] = str_to_var(data.get("start_point", start_point))

	if typeof(data.get("gizmo_rotate_origin", gizmo_rotate_origin)) == TYPE_STRING:
		data["gizmo_rotate_origin"] = str_to_var(
			data.get("gizmo_rotate_origin", gizmo_rotate_origin)
		)
	bone_name = data.get("bone_name", bone_name)
	parent_bone_name = data.get("parent_bone_name", parent_bone_name)
	gizmo_origin = data.get("gizmo_origin", gizmo_origin)
	gizmo_rotate_origin = data.get("gizmo_rotate_origin", gizmo_rotate_origin)
	start_point = data.get("start_point", start_point)
	bone_rotation = data.get("bone_rotation", bone_rotation)
	transformation_algorithm = data.get("transformation_algorithm", transformation_algorithm)
	gizmo_length = data.get("gizmo_length", gizmo_length)
	should_update_silently = false
	bone_set_updated.emit()


func serialize(vector_to_string := true) -> Dictionary:
	# Make sure the name/types are the same as the variable names/types
	var data := {}
	if vector_to_string:
		data["gizmo_origin"] = var_to_str(gizmo_origin)
		data["gizmo_rotate_origin"] = var_to_str(gizmo_rotate_origin)
		data["start_point"] = var_to_str(start_point)
	else:
		data["gizmo_origin"] = gizmo_origin
		data["gizmo_rotate_origin"] = gizmo_rotate_origin
		data["start_point"] = start_point
	data["bone_name"] = bone_name
	data["parent_bone_name"] = parent_bone_name
	data["bone_rotation"] = bone_rotation
	data["transformation_algorithm"] = transformation_algorithm
	data["gizmo_length"] = gizmo_length
	return data


func hover_mode(mouse_position: Vector2, camera_zoom) -> int:
	var local_mouse_pos = rel_to_origin(mouse_position)
	var hover_type := NONE
	var interaction_distance := get_interaction_distance(camera_zoom.x)
	# Mouse close to position circle
	if (start_point).distance_to(local_mouse_pos) <= interaction_distance:
		hover_type = DISPLACE
	elif (
		(start_point + end_point).distance_to(local_mouse_pos)
		<= interaction_distance
	):
		# Mouse close to end circle
		if !ignore_rotation_hover:
			hover_type = EXTEND
	elif is_close_to_segment(
		rel_to_start_point(mouse_position),
		interaction_distance,
		Vector2.ZERO, end_point
	):
		# Mouse close joining line
		if !ignore_rotation_hover:
			hover_type = ROTATE
	if _old_hover != hover_type:
		bone_set_updated.emit()
	return hover_type


static func is_close_to_segment(
	pos: Vector2, detect_distance: float, s1: Vector2, s2: Vector2
) -> bool:
	var test_line := (s2 - s1).rotated(deg_to_rad(90)).normalized()
	var from_a := pos - test_line * detect_distance
	var from_b := pos + test_line * detect_distance
	if Geometry2D.segment_intersects_segment(from_a, from_b, s1, s2):
		return true
	return false


## Converts coordinates that are relative to canvas get converted to position relative to
## gizmo_origin.
func rel_to_origin(pos: Vector2) -> Vector2:
	return pos - gizmo_origin


## Converts coordinates that are relative to canvas get converted to position relative to
## start point (the bigger circle).
func rel_to_start_point(pos: Vector2) -> Vector2:
	return pos - gizmo_origin - start_point


## Converts coordinates that are relative to gizmo_origin get converted to position relative to
## canvas.
func rel_to_canvas(pos: Vector2, is_rel_to_start_point := false) -> Vector2:
	var diff = start_point if is_rel_to_start_point else Vector2.ZERO
	return pos + gizmo_origin + diff


## Generates a gizmo (for preview). Called by _draw() of manager
func draw_gizmo(
	camera_zoom: Vector2, mouse_point: Vector2, manager: BoneManager, with_transform := true
) -> void:
	var highlight = (self == manager.hover_gizmo or self == manager.selected_gizmo)
	var primary_color := Color.WHITE
	var secondary_color := Color(1, 1, 1, 0.8)
	var highlight_color := primary_color if (highlight) else secondary_color

	# Get the appropriate hover mode
	var true_hover_mode = SkeletonBone.NONE
	if highlight:
		var hover := hover_mode(mouse_point, camera_zoom)
		true_hover_mode = max(modify_mode, hover)
		if true_hover_mode == SkeletonBone.EXTEND:
			true_hover_mode = SkeletonBone.ROTATE
		if hover == SkeletonBone.NONE:
			true_hover_mode = SkeletonBone.NONE

		manager.cursor_reset_delay = 10
		match true_hover_mode:
			SkeletonBone.DISPLACE:
				if DisplayServer.cursor_get_shape() != Input.CURSOR_MOVE:
					Input.set_default_cursor_shape(Input.CURSOR_MOVE)
			SkeletonBone.ROTATE:
				if DisplayServer.cursor_get_shape() != Input.CURSOR_POINTING_HAND:
					Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND)

	var transform_start := start_point
	var bone_end := end_point
	if not with_transform:
		transform_start = Vector2.ZERO
		bone_end = end_point.rotated(-bone_rotation)

	# Lambdha func to get width
	var get_width := func(for_hover_mode):
		var initial_width: float = (WIDTH if (highlight) else DESELECT_WIDTH) / camera_zoom.x
		var hover_width_diff: float = (
			initial_width / 2 if (true_hover_mode != SkeletonBone.NONE) else 0.0
		)
		var net_width := (
			initial_width + hover_width_diff
			if true_hover_mode == for_hover_mode or self == manager.selected_gizmo
			else SkeletonBone.DESELECT_WIDTH / camera_zoom.x
		)
		return net_width

	# Draw the position circle
	manager.draw_set_transform(gizmo_origin)
	# Joint circle at start
	manager.draw_circle(
		transform_start,
		START_RADIUS / camera_zoom.x,
		highlight_color,
		false,
		get_width.call(SkeletonBone.DISPLACE)
	)

	manager.draw_set_transform(Vector2.ZERO)
	ignore_rotation_hover = manager.bones_chained
	var skip_rotation_gizmo := false
	if manager.bones_chained:
		var names = []
		for other_gizmo: SkeletonBone in _bone_set.values():
			names.append(other_gizmo.parent_bone_name)
			if other_gizmo.parent_bone_name == bone_name:
				skip_rotation_gizmo = true
				break
	ignore_rotation_hover = skip_rotation_gizmo
	if !skip_rotation_gizmo:
		manager.draw_set_transform(gizmo_origin)
		if with_transform:
			# Increase width slightly in order to indicate highlight
			# Draw the line joining the start and end points
			var split := 0.1 * bone_end
			var perp := bone_end.normalized().rotated(-(PI / 2))
			var w1 := START_RADIUS / camera_zoom.x   # start thickness
			var w2 := END_RADIUS / camera_zoom.x   # end thickness
			var start := transform_start + (bone_end.normalized() * w1)
			var end := transform_start + end_point  - (bone_end.normalized() * w2)
			var p1 := start + split + perp * get_interaction_distance(camera_zoom.x)
			var p2 := end + (perp / 2) * w2
			var p3 := end - (perp / 2) * w2
			var p4 := start + split - perp * get_interaction_distance(camera_zoom.x)
			manager.draw_polyline(
				PackedVector2Array([start, p1, p2, p3, p4, start, end]),
				highlight_color,
				get_width.call(SkeletonBone.ROTATE)
			)
		else:
			# Draw the line joining the position and rotation circles
			manager.draw_line(
				transform_start,
				transform_start + bone_end,
				highlight_color,
				get_width.call(SkeletonBone.ROTATE)
			)
		# Draw rotation circle (pose mode)
		manager.draw_circle(
			transform_start + bone_end,
			SkeletonBone.END_RADIUS / camera_zoom.x,
			highlight_color,
			false,
			get_width.call(SkeletonBone.ROTATE)
		)
	manager.draw_set_transform(Vector2.ZERO)
	if with_transform:
		## Show connection to parent and write bone name
		var parent: SkeletonBone = _bone_set.get(parent_bone_name, null)
		if parent:
			var p_start := parent.start_point
			var p_end := Vector2.ZERO if manager.bones_chained else parent.end_point
			var parent_start = (
				rel_to_origin(parent.rel_to_canvas(p_start)) + p_end
			)
			manager.draw_set_transform(gizmo_origin)
			# NOTE: start_point is coordinate of tail of bone, parent_start is head of parent
			# (or tail in chained mode)
			manager.draw_dashed_line(
				start_point,
				parent_start,
				highlight_color,
				SkeletonBone.DESELECT_WIDTH / camera_zoom.x
			)
			manager.draw_set_transform(Vector2.ZERO)

		var font = manager.get_node_or_null("/root/Themes").get_font()
		var line_size = gizmo_length
		var fade_ratio = (line_size * camera_zoom.x) / (font.get_string_size(bone_name).x)
		if manager.bones_chained:
			fade_ratio = max(0.3, fade_ratio)
		if fade_ratio >= 0.4 and !manager.active_tool:  # Hide names if we have zoomed far
			manager.draw_set_transform(
				gizmo_origin + start_point, manager.rotation, Vector2.ONE / camera_zoom.x
			)
			manager.draw_string(
				font, Vector2(3, -3), bone_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, highlight_color
			)
