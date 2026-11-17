@tool
extends "res://addons/gdlive/dock_core.gd"

## GDLive dock — settings layer: persistence and server configuration.
##
## Loads / saves `user://gdlive.cfg`, keeps the settings summary in sync and pushes
## the current options into the Rust extension.
##
## Layered dock scripts (base → top):
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs → dock.gd

func _toggle_settings() -> void:
	if _settings_box == null:
		return
	_settings_box.visible = not _settings_box.visible
	_update_settings_ui()
	_save_settings()

func _update_settings_ui() -> void:
	if _settings_box == null:
		return
	var expanded := _settings_box.visible
	_settings_toggle.text = ("▾ " if expanded else "▸ ") + _t("settings.title")
	_settings_summary.visible = not expanded
	_update_settings_summary()

func _update_settings_summary() -> void:
	if _settings_summary == null:
		return
	var host := "0.0.0.0" if _host.selected == 0 else "127.0.0.1"
	var flags: Array[String] = []
	if _auto_export.button_pressed:
		flags.append(_t("settings.auto_export"))
	if _auto_reload.button_pressed:
		flags.append(_t("settings.auto_reload"))
	if _watch.button_pressed:
		flags.append(_t("settings.watch_short"))
	if _tls.button_pressed:
		flags.append("HTTPS")
	var mode := " / ".join(flags) if not flags.is_empty() else _t("settings.manual")
	_settings_summary.text = "%s:%d · %s" % [host, int(_port.value), mode]

func _apply_config() -> void:
	if server == null:
		return
	server.configure(
		_godot_bin,
		_project_dir,
		_preset,
		_out_dir,
		_auto_export.button_pressed,
		_auto_reload.button_pressed,
		_watch.button_pressed,
		400
	)
	if server.has_method("set_overlay"):
		server.set_overlay(_debug_overlay.button_pressed)

func _on_option_changed() -> void:
	_apply_config()
	_update_settings_summary()
	_save_settings()

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		# Migrate settings from the pre-rename gtlive.cfg once.
		if cfg.load(LEGACY_CFG_PATH) == OK:
			cfg.save(CFG_PATH)
		else:
			return
	var saved_port := int(cfg.get_value("gtlive", "port", 31060))
	if not bool(cfg.get_value("gtlive", "port_migrated", false)) and saved_port == LEGACY_DEFAULT_PORT:
		saved_port = 31060
		cfg.set_value("gtlive", "port_migrated", true)
		cfg.save(CFG_PATH)
	_port.value = float(saved_port)
	_host.selected = int(cfg.get_value("gtlive", "host_index", 0))
	var lang := str(cfg.get_value("gtlive", "language", "auto"))
	if _language_option != null:
		_language_option.selected = maxi(["auto", "zh", "en"].find(lang), 0)
	_auto_export.button_pressed = bool(cfg.get_value("gtlive", "auto_export", true))
	_auto_reload.button_pressed = bool(cfg.get_value("gtlive", "auto_reload", true))
	_watch.button_pressed = bool(cfg.get_value("gtlive", "watch", true))
	_tls.button_pressed = bool(cfg.get_value("gtlive", "tls", false))
	_auto_start.button_pressed = bool(cfg.get_value("gtlive", "auto_start", true))
	_debug_overlay.button_pressed = bool(cfg.get_value("gtlive", "debug_overlay", true))
	_ca_prompt_check.button_pressed = bool(cfg.get_value("gtlive", "ca_prompt", true))
	_onboarded = int(cfg.get_value("gtlive", "onboard_version", 0)) >= ONBOARD_VERSION
	_tabs.current_tab = clampi(int(cfg.get_value("gtlive", "tab_index", 0)), 0, _tabs.get_tab_count() - 1)
	_settings_box.visible = bool(cfg.get_value("gtlive", "settings_open", true))
	_update_settings_ui()
	_log_filter = int(cfg.get_value("gtlive", "log_filter", 0))
	_log_filter_option.selected = _log_filter
	_log_autoscroll = bool(cfg.get_value("gtlive", "log_autoscroll", true))
	_log_autoscroll_check.button_pressed = _log_autoscroll
	_log_view.scroll_following = _log_autoscroll
	_show_v6.button_pressed = bool(cfg.get_value("gtlive", "show_v6", false))
	_cmd_history.clear()
	for item in PackedStringArray(cfg.get_value("gtlive", "cmd_history", PackedStringArray())):
		_cmd_history.append(str(item))
	_cmd_history_index = -1
	if _remote_ttl != null:
		_remote_ttl.selected = clampi(int(cfg.get_value("gtlive", "remote_ttl", 0)), 0, _remote_ttl.item_count - 1)
	if _remote_custom_input != null:
		_remote_custom_input.text = str(cfg.get_value("gtlive", "remote_custom_domain", ""))

func _save_settings() -> void:
	if _port == null:
		return
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)
	cfg.set_value("gtlive", "port", int(_port.value))
	cfg.set_value("gtlive", "port_migrated", true)
	cfg.set_value("gtlive", "host_index", _host.selected)
	if _language_option != null:
		cfg.set_value("gtlive", "language", ["auto", "zh", "en"][_language_option.selected])
	cfg.set_value("gtlive", "auto_export", _auto_export.button_pressed)
	cfg.set_value("gtlive", "auto_reload", _auto_reload.button_pressed)
	cfg.set_value("gtlive", "watch", _watch.button_pressed)
	cfg.set_value("gtlive", "tls", _tls.button_pressed)
	cfg.set_value("gtlive", "auto_start", _auto_start.button_pressed)
	cfg.set_value("gtlive", "debug_overlay", _debug_overlay.button_pressed)
	cfg.set_value("gtlive", "ca_prompt", _ca_prompt_check.button_pressed)
	cfg.set_value("gtlive", "onboard_version", ONBOARD_VERSION if _onboarded else 0)
	cfg.set_value("gtlive", "settings_open", _settings_box.visible)
	cfg.set_value("gtlive", "tab_index", _tabs.current_tab)
	cfg.set_value("gtlive", "log_filter", _log_filter)
	cfg.set_value("gtlive", "log_autoscroll", _log_autoscroll)
	cfg.set_value("gtlive", "show_v6", _show_v6.button_pressed)
	cfg.set_value("gtlive", "cmd_history", PackedStringArray(_cmd_history))
	if _remote_ttl != null:
		cfg.set_value("gtlive", "remote_ttl", _remote_ttl.selected)
	if _remote_custom_input != null:
		cfg.set_value("gtlive", "remote_custom_domain", _remote_custom_input.text.strip_edges())
	cfg.save(CFG_PATH)
