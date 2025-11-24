extends VBoxContainer

enum IKEnum { FABRIK, CCDIK }

var COLLAPSIBLE_CONTAINER = load("res://src/UI/Nodes/CollapsibleContainer.gd")

var api: Node
var tool_slot
var kname: String
var cursor_text := ""
var bone_manager: BoneManager
var live_thread := Thread.new()

# General properties
var _live_update := false
var _allow_chaining := false
var _lock_pose := false
var _include_children := true

# Inverse kinematic variables
var _use_ik := false
var _lock_root_bone := true
var _ik_protocol: int = IKEnum.FABRIK
var _chain_length: int = 2
var _max_ik_itterations: int = 20
var _ik_error_margin: float = 0.1

# Do not touch (used internally by script)
var _displace_offset := Vector2.ZERO
var _prev_mouse_position := Vector2.INF
var _chained_gizmo: SkeletonBone = null  # Used during chain mode to keep track of original selected gizmo

# Sliders that are created procedurally later
var _rot_slider: TextureProgressBar
var _pos_slider: HBoxContainer
var _chain_size_slider: TextureProgressBar
var _itteration_slider: TextureProgressBar
var _error_margin_slider: TextureProgressBar

@onready var rotation_algorithm: OptionButton = %RotationAlgorithm
@onready var copy_pose_from: MenuButton = %CopyPoseFrom
@onready var quick_set_bones_menu: MenuButton = %QuickSetBones
@onready var force_refresh_pose: MenuButton = %ForceRefreshPose
@onready var rotation_reset_menu: MenuButton = %RotationReset
@onready var position_reset_menu: MenuButton = %PositionReset
@onready var tween_skeleton_menu: MenuButton = %TweenSkeleton
@onready var ik_options: VBoxContainer = %IKOptions
@onready var bone_props: VBoxContainer = %BoneProps
@onready var sliders_container: VBoxContainer = %SlidersContainer

@onready var pose_layer_creator: VBoxContainer = %PoseLayerCreator
@onready var options_container: VBoxContainer = %OptionsContainer
@onready var skeleton_creator: VBoxContainer = %SkeletonCreator
@onready var tool_options: VBoxContainer = %ToolOptions
@onready var ik_section: VBoxContainer = %IKSection
@onready var skeleton_section: VBoxContainer = %SkeletonSection
@onready var utilities_section: VBoxContainer = %UtilitiesSection
@onready var reset_section: VBoxContainer = %ResetSection


func _ready() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	if api:  # Api loading Successful
		# Find the Skeleton Manager/Preview. It should be a child of canvas.
		bone_manager = api.general.get_canvas().find_child("SkeletonPreview", false, false)
		if bone_manager:
			# If we found it then let the manager know we selected this tool
			bone_manager.active_skeleton_tools.append(self)
			bone_manager.queue_redraw()
		# Assign colors to the tools for Left/Right indication, and give it a name
		# (This is something Pixelorama does) automatically to it's tools
		if tool_slot.name == "Left tool":
			$ColorRect.color = api.general.get_global().left_tool_color
		else:
			$ColorRect.color = api.general.get_global().right_tool_color
		$Label.text = "Skeleton Options"

		# Add some Slider UI that can only be created through api
		_pos_slider = api.general.create_value_slider_v2()
		_pos_slider.allow_greater = true
		_pos_slider.allow_lesser = true
		_pos_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_pos_slider.suffix_x = "px"
		_pos_slider.suffix_y = "px"
		_pos_slider.min_value = Vector2.ZERO
		_pos_slider.max_value = Vector2(100, 100)
		_pos_slider.name = "BonePositionSlider"
		sliders_container.add_child(_pos_slider)

		_rot_slider = api.general.create_value_slider()
		_rot_slider.allow_greater = true
		_rot_slider.allow_lesser = true
		_rot_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_rot_slider.prefix = tr("Rotation:")
		_rot_slider.suffix = "°"
		_rot_slider.min_value = 0
		_rot_slider.max_value = 360
		_rot_slider.step = 0.01
		_rot_slider.name = "BoneRotationSlider"
		_rot_slider.custom_minimum_size.y = 24.0
		sliders_container.add_child(_rot_slider)

		_chain_size_slider = api.general.create_value_slider()
		_chain_size_slider.allow_greater = true
		_chain_size_slider.allow_lesser = false
		_chain_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_chain_size_slider.prefix = tr("Chain Size:")
		_chain_size_slider.min_value = 2
		_chain_size_slider.max_value = 10
		_chain_size_slider.step = 1
		_chain_size_slider.name = "ChainSize"
		_chain_size_slider.custom_minimum_size.y = 24.0
		ik_options.add_child(_chain_size_slider)

		_itteration_slider = api.general.create_value_slider()
		_itteration_slider.allow_greater = true
		_itteration_slider.allow_lesser = false
		_itteration_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_itteration_slider.prefix = tr("Itterations:")
		_itteration_slider.min_value = 1
		_itteration_slider.max_value = 100
		_itteration_slider.step = 1
		_itteration_slider.name = "IKIterations"
		_itteration_slider.custom_minimum_size.y = 24.0
		ik_options.add_child(_itteration_slider)

		_error_margin_slider = api.general.create_value_slider()
		_error_margin_slider.allow_greater = true
		_error_margin_slider.allow_lesser = false
		_error_margin_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_error_margin_slider.prefix = tr("Error Margin:")
		_error_margin_slider.min_value = 0
		_error_margin_slider.max_value = 10
		_error_margin_slider.step = 0.1
		_error_margin_slider.name = "ErrorMargin"
		_error_margin_slider.custom_minimum_size.y = 24.0
		ik_options.add_child(_error_margin_slider)

		# Add Collapsible Containers
		skeleton_section.set_script(COLLAPSIBLE_CONTAINER)
		skeleton_section.text = "Skeleton"
		skeleton_section.set_visible_children(false)
		skeleton_section.call("_ready")

		bone_props.set_script(COLLAPSIBLE_CONTAINER)
		bone_props.set_visible_children(false)
		bone_props.call("_ready")
		bone_props.visible = false

		utilities_section.set_script(COLLAPSIBLE_CONTAINER)
		utilities_section.text = "Utilities"
		utilities_section.set_visible_children(false)
		utilities_section.call("_ready")

		reset_section.set_script(COLLAPSIBLE_CONTAINER)
		reset_section.text = "Reset"
		reset_section.set_visible_children(false)
		reset_section.call("_ready")

		ik_section.set_script(COLLAPSIBLE_CONTAINER)
		ik_section.text = "Inverse Kinematics"
		ik_section.set_visible_children(false)
		ik_section.call("_ready")

		# Connect signals for Sliders
		_chain_size_slider.value_changed.connect(_on_chain_size_value_changed)
		_itteration_slider.value_changed.connect(_on_ik_iterations_value_changed)
		_error_margin_slider.value_changed.connect(_on_ik_error_margin_value_changed)
		# Connect signals to be notified of some important actions
		api.signals.signal_cel_switched(display_props)
		api.signals.signal_project_switched(display_props)
		api.signals.signal_project_data_changed(_on_project_data_changed)
		bone_manager.pose_layer_changed.connect(_on_pose_layer_changed)
		# Connect signals for MenuButtons
		quick_set_bones_menu.get_popup().index_pressed.connect(quick_set_bones)
		rotation_reset_menu.get_popup().index_pressed.connect(reset_bone_angle)
		position_reset_menu.get_popup().index_pressed.connect(reset_bone_position)
		force_refresh_pose.get_popup().index_pressed.connect(refresh_pose)

	# Loading finished, Assign name to Node and load configuration
	rotation_algorithm.add_item("cleanEdge", SkeletonBone.RotationAlgorithm.CLEANEDGE)
	rotation_algorithm.add_item("OmniScale", SkeletonBone.RotationAlgorithm.OMNISCALE)
	rotation_algorithm.add_item("Nearest neighbor", SkeletonBone.RotationAlgorithm.NNS)
	rotation_algorithm.select(0)
	bone_manager.sync_ui.connect(_sync_ui)
	kname = name.replace(" ", "_").to_lower()
	pose_layer_creator.visible = (bone_manager.pose_layer == null)
	options_container.visible = !pose_layer_creator.visible
	skeleton_creator.visible = bone_manager.current_frame_bones.is_empty()
	tool_options.visible = !skeleton_creator.visible
	if bone_manager.pose_layer:
		%PoseVisibilityAlert.visible = not bone_manager.pose_layer.get_ancestors().is_empty()

	load_config()


# UI "updating" signals
func _sync_ui(from_idx: int, data: Dictionary):
	if tool_slot.button != from_idx:
		bone_manager.sync_ui.disconnect(_sync_ui)
		set_config(data)
		update_config()
		save_config()
		bone_manager.sync_ui.connect(_sync_ui)


## Loads, Sets and Updates the UI
func load_config() -> void:
	var value = api.general.get_global().config_cache.get_value(tool_slot.kname, kname, {})
	set_config(value)
	update_config()


## Serializes the current script variables. Used by save_config method
func get_config() -> Dictionary:
	var config :Dictionary
	config["live_update"] = _live_update
	config["allow_chaining"] = _allow_chaining
	config["use_ik"] = _use_ik
	config["ik_protocol"] = _ik_protocol
	config["lock_root_bone"] = _lock_root_bone
	config["chain_length"] = _chain_length
	config["max_ik_itterations"] = _max_ik_itterations
	config["ik_error_margin"] = _ik_error_margin
	config["include_children"] = _include_children
	config["lock_pose"] = _lock_pose
	return config


## Deserializes the current script variables. Used by load_config method
func set_config(config: Dictionary) -> void:
	_live_update = config.get("live_update", _live_update)
	_allow_chaining = config.get("allow_chaining", _allow_chaining)
	_use_ik = config.get("use_ik", _use_ik)
	_ik_protocol = config.get("ik_protocol", _ik_protocol)
	_lock_root_bone = config.get("lock_root_bone", _lock_root_bone)
	_chain_length = config.get("chain_length", _chain_length)
	_max_ik_itterations = config.get("max_ik_itterations", _max_ik_itterations)
	_ik_error_margin = config.get("ik_error_margin", _ik_error_margin)
	_include_children = config.get("include_children", _include_children)
	_lock_pose = config.get("lock_pose", _lock_pose)


## Updates th UI based on the current values of Script variables
func update_config() -> void:
	%LiveUpdateCheckbox.button_pressed = _live_update
	%AllowChaining.button_pressed = _allow_chaining
	%AlgorithmOption.select(_ik_protocol)
	%InverseKinematics.set_pressed_no_signal(_use_ik)
	%LockRootBoneCheckbox.set_pressed_no_signal(_lock_root_bone)
	%IncludeChildrenCheckbox.set_pressed_no_signal(_include_children)
	%LockPoseCheckbox.set_pressed_no_signal(_lock_pose)
	_chain_size_slider.set_value_no_signal_update_display(_chain_length)
	_itteration_slider.set_value_no_signal_update_display(_max_ik_itterations)
	_error_margin_slider.set_value_no_signal_update_display(_ik_error_margin)
	# Update Visibility of some UI options
	%InverseKinematics.visible = _allow_chaining
	ik_section.visible = _use_ik and _allow_chaining
	%LockPoseInfo.visible = _lock_pose
	_rot_slider.visible = !_lock_pose
	_pos_slider.visible = !_lock_pose
	if bone_manager:
		# Update properties ofthe manager
		bone_manager.bones_chained = _allow_chaining
		bone_manager.sync_ui.emit(tool_slot.button, get_config())
		bone_manager.queue_redraw()


## Saves the current script variables as a dictionary
func save_config() -> void:
	var config := get_config()
	api.general.get_global().config_cache.set_value(tool_slot.kname, kname, config)


func _on_create_pose_layer_pressed() -> void:
	var project = api.project.current_project
	project.current_layer = 0  # Layer above which the PoseLayer should be added
	api.general.get_global().animation_timeline.on_add_layer_list_id_pressed(
		api.general.get_global().LayerTypes.PIXEL
	)
	# Move down twice to avoid being part of any Groups
	api.general.get_global().animation_timeline.change_layer_order(false)
	api.general.get_global().animation_timeline.change_layer_order(false)
	if project.layers.size() > 0:  # Failsafe
		# Check if addition was successful project.current_layer is auto changed
		# to point to pose layer
		if (
			project.layers[project.current_layer].get_layer_type()
			== api.general.get_global().LayerTypes.PIXEL
		):
			project.layers[project.current_layer].name = "Pose Layer"
			bone_manager.pose_layer = project.layers[project.current_layer]
			bone_manager.call("_on_cel_switched")


func _on_create_first_bone_pressed() -> void:
	var project = api.project.current_project
	if not bone_manager.pose_layer:
		return
	api.project.add_new_layer(
		project.layers.size() - 1, "", api.general.get_global().LayerTypes.GROUP
	)
	# User likely wants it disabled here
	_lock_pose = true
	update_config()
	save_config()
	api.project.select_cels([[project.current_frame, bone_manager.pose_layer.index]])
	bone_manager.call("_on_cel_switched")


func _on_pose_layer_changed():
	pose_layer_creator.visible = (bone_manager.pose_layer == null)
	options_container.visible = !pose_layer_creator.visible
	await get_tree().process_frame
	await get_tree().process_frame
	skeleton_creator.visible = bone_manager.current_frame_bones.is_empty()
	tool_options.visible = !skeleton_creator.visible


func _on_project_data_changed(_project):
	if bone_manager.pose_layer:
		%PoseVisibilityAlert.visible = not bone_manager.pose_layer.get_ancestors().is_empty()
	pose_layer_creator.visible = (bone_manager.pose_layer == null)
	options_container.visible = !pose_layer_creator.visible
	skeleton_creator.visible = bone_manager.current_frame_bones.is_empty()
	tool_options.visible = !skeleton_creator.visible
	display_props()


## This is an info warning for the tween feature
func _on_warn_pressed() -> void:
	var warn_text = """
To avoid any quirky behavior, it is recomended to not tween between
large rotations, and have "Include bone children" enabled.
"""
	api.dialog.show_error(warn_text)


## Bone property
func _on_rotation_algorithm_item_selected(index: int) -> void:
	var id := rotation_algorithm.get_item_id(index)
	## This rotation will also rotate the child bones as the parent bone's angle is changed.
	if bone_manager.selected_gizmo:
		if bone_manager.selected_gizmo in bone_manager.current_frame_bones.values():
			bone_manager.selected_gizmo.should_update_silently = not _include_children
			bone_manager.selected_gizmo.transformation_algorithm = id
			bone_manager.generate_pose()
			bone_manager.selected_gizmo.should_update_silently = false


## Bone property
func _on_rotation_changed(value: float):
	## This rotation will also rotate the child bones as the parent bone's angle is changed.
	if bone_manager.selected_gizmo:
		if bone_manager.selected_gizmo in bone_manager.current_frame_bones.values():
			bone_manager.selected_gizmo.should_update_silently = not _include_children
			bone_manager.selected_gizmo.bone_rotation = deg_to_rad(value)
			bone_manager.generate_pose()
			bone_manager.selected_gizmo.should_update_silently = false


## Bone property
func _on_position_changed(value: Vector2):
	if bone_manager.selected_gizmo:
		if bone_manager.selected_gizmo in bone_manager.current_frame_bones.values():
			bone_manager.selected_gizmo.should_update_silently = not _include_children
			bone_manager.selected_gizmo.start_point = (
				bone_manager.selected_gizmo.rel_to_origin(value).ceil()
			)
			bone_manager.generate_pose()
			bone_manager.selected_gizmo.should_update_silently = false


func _on_include_children_checkbox_toggled(toggled_on: bool) -> void:
	_include_children = toggled_on
	update_config()
	save_config()


func _on_lock_pose_checkbox_toggled(toggled_on: bool) -> void:
	_lock_pose = toggled_on
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


## Toggles the Inverse Kinematics feature
func _on_inverse_kinematics_toggled(toggled_on: bool) -> void:
	_use_ik = toggled_on
	update_config()
	save_config()


func _on_lock_root_bone_checkbox_toggled(toggled_on: bool) -> void:
	_lock_root_bone = toggled_on
	update_config()
	save_config()


## Selects the Inverse Kinematics algorithm
func _on_algorithm_selected(index: int) -> void:
	_ik_protocol = index
	update_config()
	save_config()


## Sets the chain size required for IK calculations
func _on_chain_size_value_changed(value: float) -> void:
	@warning_ignore("narrowing_conversion")
	_chain_length = value
	update_config()
	save_config()


## Sets the itteration count required for IK algorithms
func _on_ik_iterations_value_changed(value: float) -> void:
	@warning_ignore("narrowing_conversion")
	_max_ik_itterations = value
	update_config()
	save_config()


## Sets the error margin required for IK algorithms
func _on_ik_error_margin_value_changed(value: float) -> void:
	_ik_error_margin = value
	update_config()
	save_config()


## Triggered when the tool is exiting (pixelorama closing, tool changing, extension disabling).
## Used to reverse stuff done in _ready or _enter_tree methods
func _exit_tree() -> void:
	if bone_manager:  # Let the manager know this tool is no longer present
		bone_manager.active_skeleton_tools.erase(self)
		bone_manager.queue_redraw()
		bone_manager.pose_layer_changed.disconnect(_on_pose_layer_changed)
	if api:  # Disconnect any remaining rogue signals
		api.signals.signal_cel_switched(display_props, true)
		api.signals.signal_project_switched(display_props, true)
		api.signals.signal_project_data_changed(_on_project_data_changed, true)


func draw_start(_pos: Vector2i) -> void:
	# Do basic check before proceding
	if !bone_manager:  # Failure at detecting manager
		return
	if bone_manager.active_tool != null:  # Manager already in use by another tool
		return

	# Checks passed, mark the manager as being used by this tool
	bone_manager.active_tool = self
	# Mark this tool as active as well
	var mouse_point: Vector2 = api.general.get_canvas().current_pixel
	if !bone_manager.selected_gizmo:
		display_props()
		return
	if bone_manager.selected_gizmo.modify_mode == SkeletonBone.NONE:
		# When moving mouse we may stop hovering but we are still modifying that bone.
		# this is why we need a sepatate modify_mode variable
		bone_manager.selected_gizmo.modify_mode = bone_manager.selected_gizmo.hover_mode(
			Vector2(mouse_point), api.general.get_global().camera.zoom
		)
	if _prev_mouse_position == Vector2.INF:
		_displace_offset = bone_manager.selected_gizmo.rel_to_start_point(mouse_point)
		_prev_mouse_position = mouse_point
	display_props()


func draw_move(_pos: Vector2i) -> void:
	# Do basic check before proceding
	if !bone_manager:  # Failure at detecting manager
		return
	if bone_manager.active_tool != self:  # Manager already in use by another tool
		return
	if !bone_manager.selected_gizmo:  # If no bone is selected then do not proceed further
		return

	# Checks if user intends of transform bone or just move the gizmo only
	var is_transforming = not (Input.is_key_pressed(KEY_CTRL) or _lock_pose)
	# We need mouse_point to be a Vector2 in order for rotation to work properly.
	var mouse_point: Vector2 = api.general.get_canvas().current_pixel
	# Mouse offset between this frame and previous frame
	var offset := mouse_point - _prev_mouse_position
	# Determines if our movement this time waranted a new render
	var ignore_render_this_frame := false

	# If user wants to transform, has chaining enabled and the bone has a valid parent.
	if (
		_allow_chaining
		and bone_manager.selected_gizmo.is_bone_parent_valid()
		and is_transforming
	):
		match bone_manager.selected_gizmo.modify_mode:  # This manages chaining
			SkeletonBone.DISPLACE:
				if _use_ik:
					var update_canvas := true  # Keeps track if the Algorithm was successful
					var ik_chain := IKAlgorithms.get_ik_cels(
						bone_manager.selected_gizmo, _chain_length, bone_manager.current_frame_bones
					)
					match _ik_protocol:
						IKEnum.FABRIK:
							update_canvas = IKAlgorithms.FABRIK.calculate(
								ik_chain,
								mouse_point,
								_max_ik_itterations,
								_ik_error_margin
							)
						IKEnum.CCDIK:
							update_canvas = IKAlgorithms.CCDIK.calculate(
								ik_chain,
								mouse_point,
								_max_ik_itterations,
								_ik_error_margin
							)
					if not _lock_root_bone:
						var last_gizmo := bone_manager.selected_gizmo
						var end_point := last_gizmo.rel_to_canvas(last_gizmo.start_point)
						if end_point.distance_to(mouse_point) > _ik_error_margin:
							# Translate the root bone to compensate for error
							if not bone_manager.group_names_ordered.is_empty():
								var first_bone_name := bone_manager.group_names_ordered[0]
								if first_bone_name in bone_manager.current_frame_bones.keys():
									var first_bone: SkeletonBone = bone_manager.current_frame_bones[
										first_bone_name
									]
									first_bone.start_point += mouse_point - end_point
					if _live_update and update_canvas:
						manage_threading_generate_pose(false)
					_prev_mouse_position = mouse_point
					display_props()
					return  # We don't need to do anything further
				else:
					_chained_gizmo = bone_manager.selected_gizmo
					bone_manager.selected_gizmo = bone_manager.current_frame_bones[
						bone_manager.selected_gizmo.parent_bone_name
					]
					bone_manager.selected_gizmo.modify_mode = SkeletonBone.ROTATE
					_chained_gizmo.modify_mode = SkeletonBone.NONE
	if bone_manager.selected_gizmo.modify_mode == SkeletonBone.DISPLACE:
		if not is_transforming:
			ignore_render_this_frame = true
			# Pause chain propagation for the start_point property that will be changed after this
			bone_manager.selected_gizmo.should_update_silently = true
			bone_manager.selected_gizmo.gizmo_origin += offset.rotated(
				-bone_manager.selected_gizmo.bone_rotation
			)
		bone_manager.selected_gizmo.start_point = Vector2i(
			bone_manager.selected_gizmo.rel_to_origin(mouse_point) - _displace_offset
		)
		bone_manager.selected_gizmo.should_update_silently = false  # Reset this property here
	elif (
		bone_manager.selected_gizmo.modify_mode == SkeletonBone.ROTATE
		or bone_manager.selected_gizmo.modify_mode == SkeletonBone.EXTEND
	):
		var localized_mouse_norm: Vector2 = bone_manager.selected_gizmo.rel_to_start_point(
			mouse_point
		).normalized()
		var localized_prev_mouse_norm: Vector2 = bone_manager.selected_gizmo.rel_to_start_point(
			_prev_mouse_position
		).normalized()
		var diff := localized_mouse_norm.angle_to(localized_prev_mouse_norm)
		if not is_transforming:
			ignore_render_this_frame = true
			bone_manager.selected_gizmo.gizmo_rotate_origin -= diff
			if bone_manager.selected_gizmo.modify_mode == SkeletonBone.EXTEND:
				bone_manager.selected_gizmo.gizmo_length = int(
					bone_manager.selected_gizmo.rel_to_start_point(mouse_point).length()
				)
		else:
			bone_manager.selected_gizmo.bone_rotation -= diff
			if _allow_chaining and _chained_gizmo:
				_chained_gizmo.bone_rotation += diff
	if _live_update and not ignore_render_this_frame:
		manage_threading_generate_pose(false)
	_prev_mouse_position = mouse_point
	display_props()


func draw_end(_pos: Vector2i) -> void:
	_prev_mouse_position = Vector2.INF
	_displace_offset = Vector2.ZERO
	_chained_gizmo = null

	# Do basic check before proceding
	if !bone_manager:  # Failure at detecting manager
		return
	if bone_manager.active_tool != self:  # Manager already in use by another tool
		return
	# Release the manager.
	bone_manager.active_tool = null
	if !bone_manager.selected_gizmo:  # If no bone is selected then do not proceed further
		return

	# Render the new pose
	if bone_manager.selected_gizmo.modify_mode != SkeletonBone.NONE:
		manage_threading_generate_pose()
		bone_manager.selected_gizmo.modify_mode = SkeletonBone.NONE
	# In chaining mode, during movement (modify_mode == SkeletonBone.DISPLACE), we rotate the
	# parent mode as well, so we should set the parent's modify_mode to SkeletonBone.NONE as well.
	if (
		_allow_chaining
		and bone_manager.selected_gizmo.is_bone_parent_valid()
	):
		if bone_manager.selected_gizmo.modify_mode == SkeletonBone.DISPLACE:
			bone_manager.current_frame_bones[
				bone_manager.selected_gizmo.parent_bone_name
			].modify_mode = SkeletonBone.NONE

	# Set project as changed and display bone properties. This auto triggers display_props()
	api.project.current_project.has_changed = true
	bone_manager.save_frame_info(api.project.current_project)


func _on_add_bone_pressed() -> void:
	if bone_manager.selected_gizmo:
		var project = api.project.current_project
		for layer_idx: int in project.layers.size():
			if (
				project.layers[layer_idx].get_layer_type()
				== api.general.get_global().LayerTypes.GROUP
			):
				var bone_name: StringName = project.layers[layer_idx].name
				if bone_name == bone_manager.selected_gizmo.bone_name:
					api.project.add_new_layer(
						layer_idx, "", api.general.get_global().LayerTypes.GROUP
					)
					# User likely wants it disabled here
					_lock_pose = true
					update_config()
					save_config()
					var l_index = 0 if !bone_manager.pose_layer else bone_manager.pose_layer.index
					api.project.select_cels([[project.current_frame, l_index]])
					break


func _on_add_texture_pressed():
	if bone_manager.selected_gizmo:
		var project = api.project.current_project
		for layer_idx: int in project.layers.size():
			if (
				project.layers[layer_idx].get_layer_type()
				== api.general.get_global().LayerTypes.GROUP
			):
				var bone_name: StringName = project.layers[layer_idx].name
				if bone_name == bone_manager.selected_gizmo.bone_name:
					api.project.add_new_layer(layer_idx)
					api.project.select_cels([[project.current_frame, layer_idx]])
					break


## Feature to quickly set bones to the center of their assigned textures
func quick_set_bones(bone_id: int):
	if bone_manager:
		var bone_names = get_selected_bone_names(quick_set_bones_menu.get_popup(), bone_id)
		var bone_set = bone_manager.current_frame_bones
		for layer_idx: int in api.project.current_project.layers.size():
			var bone_name: StringName = api.project.current_project.layers[layer_idx].name
			if bone_names.has(bone_name) and bone_set.has(bone_name):
				var bone: SkeletonBone = bone_set[bone_name]
				bone.should_update_silently = true
				bone.gizmo_origin = Vector2(bone_manager.get_best_origin(layer_idx))
				bone.should_update_silently = false
		bone_manager.save_frame_info(api.project.current_project)


## Feature to copy the bone information from one frame to another.
func copy_bone_data(bone_id: int, from_frame: int, popup: PopupMenu, old_current_frame: int):
	if bone_manager:
		if old_current_frame != bone_manager.current_frame:
			return
		var bone_names := get_selected_bone_names(popup, bone_id)
		var bone_set = bone_manager.current_frame_bones
		var copy_data := bone_manager.load_frame_bones(
			api.project.current_project, from_frame
		)
		for bone_name in bone_names:
			if bone_set.has(bone_name) and copy_data.has(bone_name):
				var bone: SkeletonBone = bone_set[bone_name]
				bone.deserialize(copy_data[bone_name].serialize(false), true)
		bone_manager.save_frame_info(api.project.current_project)
		bone_manager.generate_pose()
		copy_pose_from.get_popup().hide()
		copy_pose_from.get_popup().clear(true)  # To save Memory


## Refreshes the bone's pose
func refresh_pose(refresh_mode: int):
	if bone_manager:
		var frames := [bone_manager.current_frame]
		if refresh_mode == 0:  # All frames
			frames = range(0, api.project.current_project.frames.size())
		for frame_idx in frames:
			bone_manager.generate_pose(frame_idx)


## Feature to tween the skeleton
func tween_skeleton_data(bone_id: int, from_frame: int, popup: PopupMenu, current_frame: int):
	if bone_manager:
		if current_frame != bone_manager.current_frame:
			return
		var project = api.project.current_project
		# Get the bone names to animate
		var bone_names := get_selected_bone_names(popup, bone_id)
		# Get data of starting frame
		var start_data: Dictionary = bone_manager.load_frame_data(project, from_frame)
		# Get data of ending frame
		var end_data: Dictionary = bone_manager.load_frame_data(project, current_frame)
		for frame_idx in range(from_frame + 1, current_frame):
			var frame_bones := bone_manager.load_frame_bones(project, frame_idx)
			for bone_name in bone_names:
				# Go through some failsafes (Not necessary but it's good practice where possible)
				if (
					bone_name in frame_bones.keys()  # is valid part of frame bone
					and bone_name in start_data.keys()  # is valid part of start data
					and bone_name in end_data.keys()  # is valid part of end data
				):
					var bone: SkeletonBone = frame_bones[bone_name]
					for data_key: String in start_data[bone_name].keys():
						var property = bone.get(data_key)
						if typeof(property) != TYPE_STRING and property != null:
							bone.set(
								data_key, Tween.interpolate_value(
									start_data[bone_name][data_key],
									end_data[bone_name][data_key] - start_data[bone_name][data_key],
									frame_idx - from_frame,
									current_frame - from_frame,
									Tween.TRANS_LINEAR,
									Tween.EASE_IN
								)
							)
			bone_manager.save_frame_info(project, frame_bones, frame_idx)
			bone_manager.generate_pose(frame_idx)
		copy_pose_from.get_popup().hide()
		copy_pose_from.get_popup().clear(true)  # To save Memory


## Resets the bone angle
func reset_bone_angle(bone_id: int):
	## This rotation will also rotate the child bones as the parent bone's angle is changed.
	var bone_names := get_selected_bone_names(rotation_reset_menu.get_popup(), bone_id)
	for bone_name in bone_names:
		if bone_name in bone_manager.current_frame_bones.keys():
			bone_manager.current_frame_bones[bone_name].bone_rotation = 0
	bone_manager.generate_pose()


## Resets the bone position
func reset_bone_position(bone_id: int):
	var bone_names := get_selected_bone_names(position_reset_menu.get_popup(), bone_id)
	for bone_name in bone_names:
		if bone_name in bone_manager.current_frame_bones.keys():
			bone_manager.current_frame_bones[bone_name].start_point = Vector2.ZERO
	bone_manager.generate_pose()


## Popup Handlers


func _on_quick_set_bones_menu_about_to_popup() -> void:
	if bone_manager:
		populate_popup(quick_set_bones_menu.get_popup())


func _on_rotation_reset_menu_about_to_popup() -> void:
	if bone_manager:
		populate_popup(rotation_reset_menu.get_popup(), {"bone_rotation": 0})


func _on_position_reset_menu_about_to_popup() -> void:
	if bone_manager:
		populate_popup(position_reset_menu.get_popup(), {"start_point": Vector2.ZERO})


func _on_copy_pose_from_about_to_popup() -> void:
	var popup := copy_pose_from.get_popup()
	popup.clear(true)
	if !bone_manager:
		return
	var project = api.project.current_project
	var current_bone_data := bone_manager.load_frame_data(project)
	var last_unique_pose: Dictionary = current_bone_data
	for frame_idx in api.project.current_project.frames.size():
		if bone_manager.current_frame == frame_idx:
			# It won't make a difference if we skip it or not (as the system will autoatically
			# skip it anyway) but it's bet to skip it ourselves to avoid unnecessary calculations)
			continue
		var frame_data := bone_manager.load_frame_data(project, frame_idx)
		if (
			frame_data != current_bone_data  # Different pose detected
		):
			if last_unique_pose != frame_data:  # Checks if this pose is already added to list
				last_unique_pose = frame_data  # Mark this pose as seen
				var popup_submenu = PopupMenu.new()
				popup_submenu.about_to_popup.connect(
					populate_popup.bind(popup_submenu, frame_data)
				)
				popup.add_submenu_node_item(str("Frame ", frame_idx + 1), popup_submenu)
				popup_submenu.index_pressed.connect(
					copy_bone_data.bind(frame_idx, popup_submenu, bone_manager.current_frame)
				)


func _on_force_refresh_pose_about_to_popup() -> void:
	var popup := force_refresh_pose.get_popup()
	popup.clear(true)
	popup.add_item("All Frames")
	popup.add_separator()
	popup.add_item(str("Current Frame"))


func _on_tween_skeleton_about_to_popup() -> void:
	var popup := tween_skeleton_menu.get_popup()
	var project = api.project.current_project
	popup.clear(true)
	popup.add_separator("Start From")
	var current_bone_data: Dictionary = bone_manager.load_frame_data(project)
	var last_unique_pose: Dictionary = current_bone_data
	for frame_idx in api.project.current_project.frames.size():
		if frame_idx >= bone_manager.current_frame - 1:
			break
		var frame_data: Dictionary = bone_manager.load_frame_data(project, frame_idx)
		if (
			frame_data != current_bone_data  # Different pose detected
		):
			if last_unique_pose != frame_data:  # Checks if this pose is already added to list
				last_unique_pose = frame_data  # Mark this pose as seen
				var popup_submenu = PopupMenu.new()
				popup_submenu.about_to_popup.connect(
					populate_popup.bind(popup_submenu, frame_data)
				)
				popup.add_submenu_node_item(str("Frame ", frame_idx + 1), popup_submenu)
				popup_submenu.index_pressed.connect(
					tween_skeleton_data.bind(frame_idx, popup_submenu, bone_manager.current_frame)
				)


## Helper methods


func populate_popup(popup: PopupMenu, reference_properties := {}):
	popup.clear()
	if !bone_manager:
		return
	if bone_manager.group_names_ordered.is_empty():
		return
	popup.add_item("All Bones")
	var items_added_after_prev_separator := true
	for bone_key in bone_manager.group_names_ordered:
		var bone_reset_reference = reference_properties
		if bone_key in bone_manager.current_frame_bones.keys():
			var bone = bone_manager.current_frame_bones[bone_key]
			if bone.parent_bone_name == "" and items_added_after_prev_separator:  ## Root nodes
				popup.add_separator(str("Root:", bone.bone_name))
				items_added_after_prev_separator = false
			# NOTE: root node may or may not get added to list but we still need a separator
			if bone_reset_reference.is_empty():
				popup.add_item(bone.bone_name)
				items_added_after_prev_separator = true
			else:
				if bone_key in reference_properties.keys():
					bone_reset_reference = reference_properties[bone_key]
				for property: String in bone_reset_reference.keys():
					if bone.get(property) != bone_reset_reference[property]:
						popup.add_item(bone.bone_name)
						items_added_after_prev_separator = true
						break
	if popup.is_item_separator(popup.item_count - 1):
		popup.remove_item(popup.item_count - 1)


func get_selected_bone_names(popup: PopupMenu, bone_index: int) -> PackedStringArray:
	var frame_bones: Array = bone_manager.group_names_ordered
	var bone_names = PackedStringArray()
	if bone_index == 0: # All bones
		bone_names = frame_bones
	else:
		var bone_name: String = popup.get_item_text(bone_index)
		bone_names.append(bone_name)
		if _include_children:
			for bone_key: String in frame_bones:
				if bone_key in bone_manager.current_frame_bones.keys():
					var bone = bone_manager.current_frame_bones[bone_key]
					if bone.parent_bone_name in bone_names:
						bone_names.append(bone.bone_name)
	return bone_names


func display_props():
	if _rot_slider.value_changed.is_connected(_on_rotation_changed):  # works for both signals
		_rot_slider.value_changed.disconnect(_on_rotation_changed)
		_pos_slider.value_changed.disconnect(_on_position_changed)
	if (
		bone_manager.selected_gizmo in bone_manager.current_frame_bones.values()
		and bone_manager.current_frame == api.project.current_project.current_frame
	):
		%BoneInfo.visible = false
		bone_props.visible = true
		bone_props.text = tr("Bone:") + " " + bone_manager.selected_gizmo.bone_name
		_rot_slider.value = rad_to_deg(bone_manager.selected_gizmo.bone_rotation)
		_pos_slider.value = bone_manager.selected_gizmo.rel_to_canvas(
			bone_manager.selected_gizmo.start_point
		)
		_rot_slider.value_changed.connect(_on_rotation_changed)
		_pos_slider.value_changed.connect(_on_position_changed)
		rotation_algorithm.select(bone_manager.selected_gizmo.transformation_algorithm)
	else:
		bone_props.visible = false
		%BoneInfo.visible = true


func manage_threading_generate_pose(save_bones_before_render := true):
	if ProjectSettings.get_setting("rendering/driver/threads/thread_model") != 2:
		bone_manager.generate_pose(bone_manager.current_frame, save_bones_before_render)
	else:  # Multi-threaded mode (Currently pixelorama is single threaded)
		if not live_thread.is_alive():
			var error := live_thread.start(
				bone_manager.generate_pose.bind(
					bone_manager.current_frame, save_bones_before_render
				)
			)
			if error != OK:  # Thread failed, so do this the hard way.
				bone_manager.generate_pose(bone_manager.current_frame, save_bones_before_render)


## Placeholder functions that are a necessity to be here
func draw_indicator(_left: bool) -> void:
	return
func draw_preview() -> void:
	pass
func cursor_move(_pos: Vector2i) -> void:
	pass
