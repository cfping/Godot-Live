@tool
extends EditorPlugin

## Entry point of the GDLive editor plugin.
##
## The heavy lifting (HTTP server, watcher, exporter) is a Rust GDExtension;
## this script only instantiates it, forwards events once per frame and hosts
## the dock UI.

const DOCK_SCRIPT := preload("res://addons/gdlive/dock.gd")

var _server
var _dock
var _fallback


func _enter_tree() -> void:
	set_process(true)
	_bootstrap.call_deferred()


func _bootstrap() -> void:
	# The editor may still be finishing GDExtension setup during _enter_tree;
	# creating instances before that yields placeholder objects.
	await get_tree().process_frame
	await get_tree().process_frame

	var attempts := 0
	while not ClassDB.class_exists("GDLiveServer") and attempts < 10:
		await get_tree().process_frame
		attempts += 1

	if not ClassDB.class_exists("GDLiveServer"):
		_show_missing_extension()
		return

	_server = ClassDB.instantiate("GDLiveServer")
	if _server == null:
		_show_missing_extension()
		return

	_dock = DOCK_SCRIPT.new()
	# The dock tab title comes from the control's node name; without this it
	# shows the auto-generated "@VBoxContainer@123" instead of "GDLive".
	_dock.name = "GDLive"
	_dock.setup(self, _server)
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _dock)
	_dock.boot()


func _process(_delta: float) -> void:
	# Worker threads push events into a queue; converting them to signals must
	# happen on the main thread.
	if _server != null:
		_server.poll_events()


func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _fallback != null:
		remove_control_from_docks(_fallback)
		_fallback.queue_free()
		_fallback = null
	if _server != null:
		_server.stop()
		_server.stop_support()
		_server = null
	set_process(false)


func _show_missing_extension() -> void:
	push_error(
		"[GDLive] 找不到 GDLiveServer：GDExtension 未编译或路径不正确。"
		+ " 请在项目根目录运行 `bash scripts/build.sh`，然后重启 Godot。"
	)

	_fallback = VBoxContainer.new()
	_fallback.name="GDLive"
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.text = (
		"[b]GDLive · 扩展未加载[/b]\n\n"
		+ "没有找到 [code]GDLiveServer[/code] 类。\n\n"
		+ "1. 在项目根目录执行 [code]bash scripts/build.sh[/code]\n"
		+ "2. 确认 [code]addons/gdlive/bin/libgdlive.dylib[/code] 存在\n"
		+ "3. 重启 Godot 编辑器\n\n"
		+ "首次运行需要安装 Rust 工具链（rustup.rs）。"
	)
	label.custom_minimum_size = Vector2(200, 0)
	_fallback.add_child(label)
	
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _fallback)
