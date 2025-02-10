extends Node

var api: Node
var skeleton_manager: Node2D


# This script acts as a setup for the extension
func _enter_tree() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	skeleton_manager = preload(
		"res://src/Extensions/Skeletor/Preview/skeleton_manager.tscn"
	).instantiate()
	api.general.get_canvas().add_child(skeleton_manager)

	api.tools.add_tool(
		"skeleton",
		"Skeleton",
		"res://src/Extensions/Skeletor/Tool/skeleton_tool.tscn",
		[0],
		"Hint",
		)

func _exit_tree() -> void:  # Extension is being uninstalled or disabled
	api.tools.remove_tool("skeleton")
	skeleton_manager.queue_free()
