extends Window

var api: Node
var item_id: int
var skeleton_manager: Node2D

@onready var rotation_algs: OptionButton = %RotationAlgs

# This script acts as a setup for the extension
func _enter_tree() -> void:
	api = get_node_or_null("/root/ExtensionsApi")
	var menu_type = api.menu.EDIT
	item_id = api.menu.add_menu_item(menu_type, "Skeletor", self)
	skeleton_manager = preload(
		"res://src/Extensions/Skeletor/Preview/skeleton_manager.tscn"
	).instantiate()
	api.general.get_canvas().add_child(skeleton_manager)
	api.signals.signal_cel_switched(skeleton_manager.queue_redraw)


func menu_item_clicked():
	popup_centered()


func _exit_tree() -> void:  # Extension is being uninstalled or disabled
	# remember to remove things that you added using this extension
	api.menu.remove_menu_item(api.menu.EDIT, item_id)
	api.signals.signal_cel_switched(skeleton_manager.queue_redraw, true)
	skeleton_manager.queue_free()


func _on_close_requested() -> void:
	hide()
