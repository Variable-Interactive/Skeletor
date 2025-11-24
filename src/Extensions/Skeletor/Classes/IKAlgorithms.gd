class_name IKAlgorithms
extends RefCounted


## Returns the SkeletonBones in the IK chain in order, with the last bone at the end
static func get_ik_cels(
	start_bone: SkeletonBone, chain_length, from_bones: Dictionary
) -> Array[SkeletonBone]:
	var bone_chain: Array[SkeletonBone] = []
	var b_names := []
	var i = 0
	var p = start_bone
	while p:
		bone_chain.push_front(p)
		b_names.push_front(p.parent_bone_name)
		p = from_bones.get(p.parent_bone_name, null)
		i += 1
		if i > chain_length:
			break
	return bone_chain


class IKAlgorithmBase:
	static func calculate(
		_bone_chain: Array[SkeletonBone],
		_target_pos: Vector2,
		_max_itterations: int,
		_error_margin: float
	) -> bool:
		return true

	static func _get_global_start(bone_gizmo: SkeletonBone) -> Vector2:
		return bone_gizmo.rel_to_canvas(bone_gizmo.start_point)


class FABRIK:
	extends IKAlgorithmBase
	# Initial Implementation by:
	# https://github.com/nezvers/Godot_Public_Examples/blob/master/Nature_code/Kinematics/FABRIK.gd
	# see https://www.youtube.com/watch?v=Ihp6tOCYHug for an intuitive explanation.
	static func calculate(
		bone_chain: Array[SkeletonBone],
		target_pos: Vector2,
		max_itterations: int,
		error_margin: float
	) -> bool:
		var pos_list := PackedVector2Array()
		var lenghts := PackedFloat32Array()
		var total_length: float = 0
		for i in bone_chain.size() - 1:
			var p_1 := _get_global_start(bone_chain[i])
			var p_2 := _get_global_start(bone_chain[i + 1])
			pos_list.append(p_1)
			if i == bone_chain.size() - 2:
				pos_list.append(p_2)
			var l = p_2.distance_to(p_1)
			lenghts.append(l)
			total_length += l
		var old_points = pos_list.duplicate()
		var start_global = pos_list[0]
		var end_global = pos_list[pos_list.size() - 1]
		var distance: float = (target_pos - start_global).length()
		# out of reach, no point of IK
		if distance >= total_length or pos_list.size() <= 2:
			for i in bone_chain.size():
				var cel := bone_chain[i]
				if i < bone_chain.size() - 1:
					# find how much to rotate to bring next start point to mach the one in poslist
					var cel_start = _get_global_start(cel)
					var look_old = _get_global_start(bone_chain[i + 1])
					var look_new = target_pos  # what we should look at
					# Rotate to look at the next point
					var angle_diff = (
						cel_start.angle_to_point(look_new) - cel_start.angle_to_point(look_old)
					)
					if !is_equal_approx(angle_diff, 0.0):
						cel.bone_rotation += angle_diff
			return true
		else:
			var error_dist: float = (target_pos - end_global).length()
			var itterations := 0
			# limit the itteration count
			while error_dist > error_margin && itterations < max_itterations:
				_backward_reach(pos_list, target_pos, lenghts)  # start at endPos
				_forward_reach(pos_list, start_global, lenghts)  # start at pinPos
				error_dist = (target_pos - pos_list[pos_list.size() - 1]).length()
				itterations += 1
			if old_points == pos_list:
				return false
			for i in bone_chain.size():
				var cel := bone_chain[i]
				if i < bone_chain.size() - 1:
					# find how much to rotate to bring next start point to mach the one in poslist
					var cel_start = _get_global_start(cel)
					var next_start_old = _get_global_start(bone_chain[i + 1])  # current situation
					var next_start_new = pos_list[i + 1]  # what should have been
					# Rotate to look at the next point
					var angle_diff = (
						cel_start.angle_to_point(next_start_new)
						- cel_start.angle_to_point(next_start_old)
					)
					if !is_equal_approx(angle_diff, 0.0):
						cel.bone_rotation += angle_diff
			return true

	static func _backward_reach(pos_list: PackedVector2Array, ending: Vector2, lenghts) -> void:
		var last := pos_list.size() - 1
		pos_list[last] = ending  # Place the tail of last vector at ending
		for i in last:
			var head_of_last: Vector2 = pos_list[last - i]
			var tail_of_next: Vector2 = pos_list[last - i - 1]
			var dir: Vector2 = (tail_of_next - head_of_last).normalized()
			tail_of_next = head_of_last + (dir * lenghts[i - 1])
			pos_list[last - 1 - i] = tail_of_next

	static func _forward_reach(pos_list: PackedVector2Array, starting: Vector2, lenghts) -> void:
		pos_list[0] = starting  # Place the tail of first vector at starting
		for i in pos_list.size() - 1:
			var head_of_last: Vector2 = pos_list[i]
			var tail_of_next: Vector2 = pos_list[i + 1]
			var dir: Vector2 = (tail_of_next - head_of_last).normalized()
			tail_of_next = head_of_last + (dir * lenghts[i])
			pos_list[i + 1] = tail_of_next


class CCDIK:
	extends IKAlgorithmBase
	# Inspired from:
	# https://github.com/chFleschutz/inverse-kinematics-algorithms/blob/main/src/CCD.h
	static func calculate(
		bone_chain: Array[SkeletonBone],
		target_pos: Vector2,
		max_iterations: int,
		error_margin: float
	) -> bool:
		var lenghts := PackedFloat32Array()
		var total_length: float = 0
		for i in bone_chain.size() - 1:
			var p_1 := _get_global_start(bone_chain[i])
			var p_2 := _get_global_start(bone_chain[i + 1])
			var l = p_2.distance_to(p_1)
			lenghts.append(l)
			total_length += l
		var distance: float = (target_pos - _get_global_start(bone_chain[0])).length()
		# Check if the target is reachable
		if total_length < distance:
			# Stretch
			for i in bone_chain.size():
				var cel := bone_chain[i]
				if i < bone_chain.size() - 1:
					# find how much to rotate to bring next start point to mach the one in poslist
					var cel_start = _get_global_start(cel)
					var look_old = _get_global_start(bone_chain[i + 1])
					var look_new = target_pos  # what we should look at
					# Rotate to look at the next point
					var angle_diff = (
						cel_start.angle_to_point(look_new) - cel_start.angle_to_point(look_old)
					)
					if !is_equal_approx(angle_diff, 0.0):
						cel.bone_rotation += angle_diff
			return true
		for _i in range(max_iterations):
			# Adjust rotation of each bone in the skeleton
			for i in range(bone_chain.size() - 2, -1, -1):
				var pivot_pos = _get_global_start(bone_chain[-1])
				var current_base_pos = _get_global_start(bone_chain[i])
				var base_pivot_vec = pivot_pos - current_base_pos
				var base_target_vec = target_pos - current_base_pos

				# Normalize vectors
				base_pivot_vec = base_pivot_vec.normalized()
				base_target_vec = base_target_vec.normalized()

				var dot = base_pivot_vec.dot(base_target_vec)
				var det = (
					base_pivot_vec.x * base_target_vec.y - base_pivot_vec.y * base_target_vec.x
				)
				var angle_delta = atan2(det, dot)
				if !is_equal_approx(angle_delta, 0.0):
					bone_chain[i].bone_rotation += angle_delta

			# Check for convergence
			var last_cel = bone_chain[bone_chain.size() - 1]
			if (target_pos - last_cel.rel_to_canvas(last_cel.start_point)).length() < error_margin:
				return true
		return true
