@tool
extends "res://addons/gdlive/dock_tabs.gd"

## GDLive dock: lives in the right-hand editor panel.
##
## Entry point: builds the UI, boots the settings and connects the Rust extension
## signals. The heavy lifting (HTTP server, watcher, exporter) is the Rust
## GDExtension; this script is a thin UI around it.
##
## The dock is split into layered scripts to keep each file small; each layer
## extends the previous one (base → top):
##
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs
##
## A layer may only call methods from itself or a lower layer, so the chain can be
## reordered / split further without touching plugin.gd (which only loads this file).

func _ready() -> void:
	# UI language: Chinese only for Chinese system locales; every other
	# locale gets English. The saved `language` setting (auto/zh/en) overrides
	# the OS locale. Must run before `_build_ui` creates labels.
	_zh = OS.get_locale().to_lower().begins_with("zh")
	var lang_cfg := ConfigFile.new()
	if lang_cfg.load(CFG_PATH) == OK:
		match str(lang_cfg.get_value("gtlive", "language", "auto")):
			"zh":
				_zh = true
			"en":
				_zh = false
	# Fallback for editor versions that name the dock after adding it.
	name = "GDLive"
	_build_ui()
	_connect_server()

func boot() -> void:
	_project_dir = ProjectSettings.globalize_path("res://")
	_out_dir = _project_dir.path_join(".gdlive/web")
	_godot_bin = OS.get_executable_path()

	_load_settings()
	_refresh_preset_label()
	_apply_config()

	_apply_support_result(server.start_support())
	_refresh_license()
	_load_donate_images()

	_append_log("info", _t("header.ready"))
	_append_log("debug", _t("header.project") % _project_dir)
	_append_log("debug", _t("header.export_dir") % _out_dir)
	if _godot_bin == "":
		_append_log("warn", _t("log.no_godot_bin"))

	if _auto_start.button_pressed:
		_start_server()
	else:
		_refresh_status()

	check_ca_on_startup.call_deferred()
	maybe_show_onboarding.call_deferred()

func _exit_tree() -> void:
	if server != null:
		server.stop_remote()
	_save_settings()
	if is_instance_valid(_toast_panel):
		_toast_panel.queue_free()

## Connect the Rust extension signals (one handler per event).
func _connect_server() -> void:
	if server == null:
		return
	server.log.connect(_on_log)
	server.browser_log.connect(_on_browser_log)
	server.screenshot.connect(_on_screenshot)
	server.clients_changed.connect(_on_clients_changed)
	server.files_changed.connect(_on_files_changed)
	server.export_started.connect(_on_export_started)
	server.export_output.connect(_on_export_output)
	server.export_finished.connect(_on_export_finished)
	server.server_state.connect(_on_server_state)
	server.ca_installed.connect(_on_ca_installed)

func _on_clients_changed(_count: int) -> void:
	_refresh_status()

func _on_server_state(_running: bool) -> void:
	_refresh_status()

func _on_export_started() -> void:
	_export_started_ms = Time.get_ticks_msec()
	_append_log("export", _t("log.export_started"))
	_export_button.disabled = true
	_refresh_status()

func _on_export_output(line: String) -> void:
	if line.strip_edges() == "":
		return
	_append_log("export", line)

func _on_export_finished(ok: bool, summary: String) -> void:
	_export_started_ms = 0
	_export_button.disabled = false
	if ok:
		_append_log("success", summary)
	else:
		_append_log("error", summary)
	_refresh_status()
