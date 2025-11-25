extends Node

var api: Node
var skeleton_manager: Node2D
var exporter_id: int
var menu_id: int
var load_dialog: FileDialog

# This script acts as a setup for the extension
func _enter_tree() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	skeleton_manager = preload(
		"res://src/Extensions/Skeletor/Manager/skeleton_manager.tscn"
	).instantiate()
	api.general.get_canvas().add_child(skeleton_manager)

	api.tools.add_tool(
		"skeleton",
		"Skeleton",
		"res://src/Extensions/Skeletor/Tool/skeleton_tool.tscn",
		[],
		"Mouse Left/Right to transform bones \n Ctrl + Mouse Left/Right to displace bones",
		)

	load_dialog = FileDialog.new()
	load_dialog.add_filter("*.skeletor", "Skeletor skeleton")
	load_dialog.title = "Load Skeleton"
	load_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	load_dialog.access = FileDialog.ACCESS_FILESYSTEM
	load_dialog.size = Vector2i(675, 400)
	load_dialog.file_selected.connect(load_skeleton)
	api.dialog.get_dialogs_parent_node().add_child(load_dialog)
	menu_id = api.menu.add_menu_item(api.menu.PROJECT, "Load Skeleton", self)

	var format_info = {"extension": ".skeletor", "description": "Skeletor skeleton"}
	exporter_id = api.export.add_export_option(format_info, self)


func _exit_tree() -> void:  # Extension is being uninstalled or disabled
	api.tools.remove_tool("skeleton")
	skeleton_manager.queue_free()
	api.export.remove_export_option(exporter_id)
	api.menu.remove_menu_item(api.menu.PROJECT, menu_id)


func menu_item_clicked() -> void:
	load_dialog.popup_centered()


func override_export(export_info: Dictionary) -> bool:
	var project = export_info.get("project", null)
	if not project:
		return false
	var pose_layer = skeleton_manager.find_pose_layer(project)
	if not pose_layer:
		api.dialog.show_error("ERROR: This project has no pose layer!")
		return false
	var path: String = export_info.get("export_paths", [])[0]
	path = path.get_base_dir().path_join(str(project.name, ".skeletor"))
	var save_file := ConfigFile.new()
	for frame_id in project.frames.size():
		var frame_data = skeleton_manager.load_frame_info(project, frame_id)
		save_file.set_value(str(frame_id), "skeleton", frame_data)
	var code = save_file.save(path)
	return code == OK


func load_skeleton(path: String):
	var file := ConfigFile.new()
	var error = file.load(path)
	if error != OK:
		return
	var project = api.project.current_project
	if not project:
		return
	var reparent_names: Dictionary[String, String]
	for layer_idx in project.layers.size():
		var layer = project.layers[layer_idx]
		if layer.get_layer_type() == 1:  # GroupLayer
			var parent_name = "" if not layer.parent else layer.parent.name
			reparent_names[layer.name] = parent_name

	var has_scanned_for_useless := false
	var useless_bones := PackedStringArray()
	for frame_str in file.get_sections():
		var frame_idx = str_to_var(frame_str)
		if typeof(frame_idx) != TYPE_INT:
			return
		if frame_idx >= project.frames.size():
			return
		for key in file.get_section_keys(frame_str):  # there's always only one key
			var frame_skeleton: Dictionary = file.get_value(frame_str, key, {})
			if !has_scanned_for_useless:
				has_scanned_for_useless = true
				for bone_name in frame_skeleton.keys():
					if reparent_names.has(bone_name):
						var bone_parent = frame_skeleton[bone_name].get("parent_bone_name", "")
						if bone_parent != reparent_names.get(bone_name, ""):
							frame_skeleton[bone_name]["parent_bone_name"] = reparent_names[bone_name]
						else:
							reparent_names.erase(bone_name)  # We know it is safe
					else:
						frame_skeleton.erase(bone_name)
						useless_bones.append(bone_name)
			else:
				for b_name in useless_bones:
					frame_skeleton.erase(b_name)
				for b_name in reparent_names.keys():
					frame_skeleton[b_name]["parent_bone_name"] = reparent_names[b_name]
			var old_data: Dictionary = skeleton_manager.load_frame_info(project, frame_idx)
			old_data.merge(frame_skeleton, true)
			skeleton_manager.save_frame_info(project, old_data, frame_idx)
			if frame_idx != project.current_frame:
				skeleton_manager.generate_pose(frame_idx)
	skeleton_manager.current_frame_data = skeleton_manager.load_frame_info(project)
	skeleton_manager.generate_pose()
