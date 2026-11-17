@tool
extends "res://addons/gdlive/dock_license.gd"

## GDLive dock — server layer: the 调试 tab, server lifecycle and LAN URLs.
##
## Starts / stops the game server, refreshes status, URLs and QR codes, and detects
## or creates the Web export preset.
##
## Layered dock scripts (base → top):
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs → dock.gd

func _start_server() -> void:
	if server == null:
		return
	_apply_config()
	var host := "0.0.0.0" if _host.selected == 0 else "127.0.0.1"
	var use_tls := _tls.button_pressed
	if use_tls and not _license_pro:
		use_tls = false
		_append_log("warn", _t("toast.free_https_off"))
	# Empty cert dir => machine-wide PKI (one root CA for every project).
	var result: Dictionary = server.start(
		host,
		int(_port.value),
		_out_dir,
		use_tls,
		""
	)
	if not bool(result.get("ok", false)):
		_append_log("error", _t("log.start_failed") % str(result.get("error", _t("common.unknown_error"))))
		_refresh_status()
		return

	_append_log("success", _t("log.server_started") % [host, int(_port.value)])
	if _tls.button_pressed:
		_append_log(
			"info",
			_t("log.https_signed")
		)
	_refresh_status()
	if not bool(server.has_build()):
		_append_log("info", _t("log.no_build"))

func _on_toggle() -> void:
	if server == null:
		return
	if bool(server.is_running()):
		server.stop()
		_append_log("info", _t("status.server_stopped"))
		_toast(_t("status.server_stopped"))
		_refresh_status()
	else:
		_start_server()

func _on_export() -> void:
	if server == null:
		return
	if _preset == "":
		_refresh_preset_label()
	if _preset == "":
		_append_log("error", _t("log.no_preset"))
		return
	if not bool(server.export_now()):
		_append_log("warn", _t("log.export_busy"))
		return
	_export_button.disabled = true
	_refresh_status()

func _refresh_status() -> void:
	if server == null:
		return
	# Periodic license revalidation: the editor polls every 2 s, but a full
	# signature re-check every 2 s is wasteful — 30 s is plenty for catching
	# expired/tampered licenses, clock fixes and activations made elsewhere.
	if Time.get_ticks_msec() - _license_last_check_ms > 30_000:
		_license_last_check_ms = Time.get_ticks_msec()
		_refresh_license()
	var status: Dictionary = server.status()
	var running := bool(status.get("running", false))
	var port := int(status.get("port", 0))
	var clients := int(status.get("clients", 0))
	var exporting := bool(status.get("exporting", false))
	var tls := bool(status.get("tls", false))

	_start_button.text = _t("common.stop") if running else _t("common.start")
	_export_button.disabled = exporting
	_export_button.text = _t("status.exporting") if exporting else _t("common.export")
	_open_quick_button.disabled = not running
	_export_progress.visible = exporting
	if exporting and _export_started_ms == 0:
		_export_started_ms = Time.get_ticks_msec()
	elif not exporting:
		_export_started_ms = 0

	if not running:
		_set_state_hint(_t("status.not_running"))
	elif not bool(status.get("has_build", false)):
		_set_state_hint(_t("status.no_build"))
	else:
		_set_state_hint("")

	if running:
		var scheme := "https" if tls else "http"
		var urls: PackedStringArray = status.get("urls", PackedStringArray())
		var v6_urls: PackedStringArray = status.get("urls_v6", PackedStringArray())
		var first := urls[0].replace("http://", "").replace("https://", "") if urls.size() > 0 else "?"
		var text := _t("status.running") % [first, clients]
		if exporting:
			var secs := int((Time.get_ticks_msec() - _export_started_ms) / 1000)
			text += _t("status.exporting_secs") % maxi(secs, 0)
		_status_label.add_theme_color_override("font_color", _ed_positive)
		_status_label.text = text
		_status_label.tooltip_text = "%s://%s/__gdlive/" % [scheme, first]
		_refresh_urls(urls, v6_urls)
	else:
		_status_label.add_theme_color_override("font_color", _ed_dim)
		_status_label.text = _t("status.stopped")
		_status_label.tooltip_text = ""
		_refresh_urls(PackedStringArray(), PackedStringArray())
	_refresh_license()
	_refresh_remote()

func _set_state_hint(text: String) -> void:
	if _state_hint == null:
		return
	_state_hint.visible = text != ""
	_state_hint.text = text

func _refresh_urls(v4_urls: PackedStringArray, v6_urls: PackedStringArray) -> void:
	var urls := PackedStringArray(v4_urls)
	if _show_v6.button_pressed:
		urls.append_array(v6_urls)
	if urls == _last_urls:
		return
	_last_urls = urls
	_url_list.clear()
	for url in urls:
		_url_list.add_item("%s/" % url)
	_open_button.disabled = urls.is_empty()
	_copy_button.disabled = urls.is_empty()
	_debug_page_button.disabled = urls.is_empty()

	if urls.is_empty():
		_qr.clear_matrix()
	else:
		_url_list.select(0)
		_update_qr(urls[0])

func _on_url_selected(_index: int) -> void:
	_update_qr(_selected_url())

func _update_qr(url: String) -> void:
	if _qr_url_label != null:
		_qr_url_label.text = "" if url == "" else url + "/"
	if url == "":
		_qr.clear_matrix()
		return
	if _qr_cache.has(url):
		var cached: Dictionary = _qr_cache[url]
		_qr.set_matrix(int(cached["size"]), cached["data"], url)
		return
	var matrix: Dictionary = server.qr_matrix(url + "/", "M")
	if not bool(matrix.get("ok", false)):
		_qr.clear_matrix()
		return
	_qr_cache[url] = matrix
	_qr.set_matrix(int(matrix["size"]), matrix["data"], url)

func _on_open() -> void:
	var url := _selected_url()
	if url != "":
		OS.shell_open(url + "/")
		_toast(_t("toast.game_opened"))

func _on_open_qr_page() -> void:
	var base := _selected_url()
	if base == "":
		_append_log("warn", _t("toast.start_first_qr"))
		return
	OS.shell_open(base + "/__gdlive/qr")
	_toast(_t("toast.qr_page_opened"))

func _on_open_debug_page() -> void:
	var url := _selected_url()
	if url != "":
		OS.shell_open(url + "/__gdlive/")
		_toast(_t("toast.debug_page_opened"))

func _on_copy_url() -> void:
	var url := _selected_url()
	if url != "":
		DisplayServer.clipboard_set(url + "/")
		_append_log("info", _t("toast.url_copied") % url)
		_toast(_t("toast.game_url_copied"))

## Find the Web export preset, or "" when `export_presets.cfg` has none.
func _find_web_preset() -> String:
	var cfg := ConfigFile.new()
	if cfg.load("res://export_presets.cfg") != OK:
		return ""
	for section in cfg.get_sections():
		if section.begins_with("preset.") and not section.ends_with(".options"):
			if str(cfg.get_value(section, "platform", "")) == "Web":
				return str(cfg.get_value(section, "name", "Web"))
	return ""

func _refresh_preset_label() -> void:
	_preset = _find_web_preset()
	if server != null:
		server.set_preset(_preset)
	if _preset == "":
		_preset_label.text = _t("log.preset_missing")
		_preset_button.visible = true
	else:
		_preset_label.text = _t("log.preset") % _preset
		_preset_button.visible = false

func _on_create_preset() -> void:
	var path := "res://export_presets.cfg"
	var cfg := ConfigFile.new()
	cfg.load(path)

	var index := 0
	while cfg.has_section("preset.%d" % index):
		index += 1
	var section := "preset.%d" % index

	cfg.set_value(section, "name", "Web")
	cfg.set_value(section, "platform", "Web")
	cfg.set_value(section, "runnable", true)
	cfg.set_value(section, "advanced_options", false)
	cfg.set_value(section, "dedicated_server", false)
	cfg.set_value(section, "custom_features", "")
	cfg.set_value(section, "export_filter", "all_resources")
	cfg.set_value(section, "include_filter", "")
	cfg.set_value(section, "exclude_filter", "addons/gdlive/*,license-keys/*")
	cfg.set_value(section, "export_path", "")
	cfg.set_value(section, "patches", PackedStringArray())
	cfg.set_value(section, "encryption_include_filters", "")
	cfg.set_value(section, "encryption_exclude_filters", "")
	cfg.set_value(section, "seed", 0)
	cfg.set_value(section, "encrypt_pck", false)
	cfg.set_value(section, "encrypt_directory", false)
	cfg.set_value(section, "script_export_mode", 2)

	var options := section + ".options"
	cfg.set_value(options, "custom_template/debug", "")
	cfg.set_value(options, "custom_template/release", "")
	cfg.set_value(options, "variant/extensions_support", false)
	# 内网 HTTP 下没有 SharedArrayBuffer，默认关闭线程以兼容手机。
	cfg.set_value(options, "variant/thread_support", false)
	cfg.set_value(options, "vram_texture_compression/for_desktop", true)
	cfg.set_value(options, "vram_texture_compression/for_mobile", false)
	cfg.set_value(options, "html/export_icon", true)
	cfg.set_value(options, "html/custom_html_shell", "")
	cfg.set_value(options, "html/head_include", "")
	cfg.set_value(options, "html/canvas_resize_policy", 2)
	cfg.set_value(options, "html/focus_canvas_on_start", true)
	cfg.set_value(options, "html/experimental_virtual_keyboard", false)
	cfg.set_value(options, "progressive_web_app/enabled", false)

	var err := cfg.save(path)
	if err != OK:
		_append_log("error", _t("log.preset_write_failed") % error_string(err))
		return
	_append_log("success", _t("log.preset_created_http"))
	_toast(_t("log.preset_created"), "success")
	_refresh_preset_label()
	_apply_config()

	_apply_support_result(server.start_support())
	_refresh_license()
	_load_donate_images()

func _on_open_export_dir() -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	OS.shell_show_in_file_manager(_out_dir, true)
	_append_log("info", _t("toast.export_dir_opened"))
	_toast(_t("toast.export_dir_opened"))

func _build_tab_debug() -> void:
	var run := _make_tab(_t("tab.debug"))

	var settings_head := HBoxContainer.new()
	run.add_child(settings_head)

	_settings_toggle = Button.new()
	_settings_toggle.flat = true
	_settings_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_settings_toggle.text = _t("settings.toggle")
	_settings_toggle.tooltip_text = _t("summary.settings_tooltip")
	_settings_toggle.pressed.connect(_toggle_settings)
	settings_head.add_child(_settings_toggle)

	_settings_summary = Label.new()
	_settings_summary.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_settings_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_settings_summary.add_theme_font_size_override("font_size", 10)
	_settings_summary.add_theme_color_override("font_color", _ed_dim)
	settings_head.add_child(_settings_summary)

	var settings_panel := PanelContainer.new()
	settings_panel.add_theme_stylebox_override("panel", _card_style())
	run.add_child(settings_panel)
	_settings_box = VBoxContainer.new()
	_settings_box.add_theme_constant_override("separation", 6)
	settings_panel.add_child(_settings_box)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	_settings_box.add_child(grid)

	grid.add_child(_label(_t("settings.port")))
	_port = SpinBox.new()
	_port.min_value = 1
	_port.max_value = 65535
	_port.step = 1
	_port.value = 31060
	_port.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_port.value_changed.connect(func(_value):
		_save_settings()
		_update_settings_summary()
	)
	grid.add_child(_port)

	grid.add_child(_label(_t("settings.listen_addr")))
	_host = OptionButton.new()
	_host.add_item(_t("settings.host_lan"), 0)
	_host.add_item(_t("settings.host_local"), 1)
	_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host.item_selected.connect(func(_index):
		_save_settings()
		_update_settings_summary()
	)
	grid.add_child(_host)

	# Bilingual by design so the setting stays readable no matter which
	# language the UI is currently in. Takes effect after plugin reload.
	grid.add_child(_label("界面语言 / Language"))
	_language_option = OptionButton.new()
	_language_option.add_item("自动 · Auto", 0)
	_language_option.add_item("中文", 1)
	_language_option.add_item("English", 2)
	_language_option.selected = 0
	_language_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_language_option.item_selected.connect(func(_index):
		_save_settings()
		_toast(_t("lang.changed_toast"))
	)
	grid.add_child(_language_option)

	_settings_box.add_child(_section(_t("settings.options")))

	_auto_export = _check(_t("settings.auto_export"), true)
	_auto_export.tooltip_text = _t("settings.auto_export_tip")
	_auto_reload = _check(_t("settings.auto_reload"), true)
	_auto_reload.tooltip_text = _t("settings.auto_reload_tip")
	_watch = _check(_t("settings.watch"), true)
	_watch.tooltip_text = _t("settings.watch_tip")
	_tls = _check(_t("settings.https"), false)
	_tls.tooltip_text = _t("settings.https_tip")
	_auto_start = _check(_t("settings.auto_start"), true)
	_auto_start.tooltip_text = _t("settings.auto_start_tip")
	_debug_overlay = _check(_t("settings.debug_overlay"), true)
	_debug_overlay.tooltip_text = _t("settings.debug_overlay_tip")
	for box in [_auto_export, _auto_reload, _watch, _tls, _auto_start, _debug_overlay]:
		_settings_box.add_child(box)
		box.toggled.connect(func(_pressed): _on_option_changed())
	_debug_overlay.toggled.connect(
		func(pressed: bool):
			_toast(_t("toast.debug_overlay_prefix") + (_t("toast.debug_overlay_on") if pressed else _t("onboard.close")))
	)

	run.add_child(_section(_t("debug.lan_addrs")))

	var ip_filter_row := HBoxContainer.new()
	run.add_child(ip_filter_row)
	var ip_filter_spacer := Control.new()
	ip_filter_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ip_filter_row.add_child(ip_filter_spacer)
	_show_v6 = _check(_t("settings.show_v6"), false)
	_show_v6.tooltip_text = _t("settings.show_v6_tip")
	_show_v6.toggled.connect(func(_pressed): _save_settings(); _refresh_status())
	ip_filter_row.add_child(_show_v6)

	_url_list = ItemList.new()
	_url_list.custom_minimum_size = Vector2(0, 58)
	_url_list.item_selected.connect(_on_url_selected)
	_url_list.add_theme_stylebox_override("panel", _card_style(_ed_base, _ed_dark2, 2, 6))
	_url_list.add_theme_stylebox_override("bg", StyleBoxEmpty.new())
	_url_list.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_url_list.add_theme_stylebox_override("selected", _selected_row_style())
	_url_list.add_theme_stylebox_override("selected_focus", _selected_row_style())
	_url_list.add_theme_color_override("font_color", _ed_dim)
	_url_list.add_theme_color_override("font_selected_color", _ed_text)
	if _ed_mono != null:
		_url_list.add_theme_font_override("font", _ed_mono)
	run.add_child(_url_list)

	var qr_hint := Label.new()
	qr_hint.text = _t("debug.scan_hint")
	qr_hint.add_theme_font_size_override("font_size", 10)
	qr_hint.add_theme_color_override("font_color", _ed_dim)
	run.add_child(qr_hint)

	var qr_box_panel := PanelContainer.new()
	qr_box_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	qr_box_panel.add_theme_stylebox_override("panel", _qr_card_style())
	run.add_child(qr_box_panel)
	var qr_box := CenterContainer.new()
	qr_box.custom_minimum_size = Vector2(0, 150)
	qr_box_panel.add_child(qr_box)
	_qr = QR_VIEW.new()
	qr_box.add_child(_qr)

	_qr_url_label = Label.new()
	_qr_url_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_qr_url_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_qr_url_label.add_theme_font_size_override("font_size", 10)
	_qr_url_label.add_theme_color_override("font_color", _ed_dim)
	run.add_child(_qr_url_label)

	var open_row := HBoxContainer.new()
	run.add_child(open_row)
	_open_button = _button(_t("debug.open_browser"), _on_open)
	_open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_row.add_child(_open_button)
	_copy_button = _button(_t("common.copy_address"), _on_copy_url)
	_copy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_row.add_child(_copy_button)
	_debug_page_button = _button(_t("debug.open_debug_page"), _on_open_debug_page)
	_debug_page_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_row.add_child(_debug_page_button)
	var qr_page_button := _button(_t("debug.qr_button"), _on_open_qr_page)
	qr_page_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	qr_page_button.tooltip_text = _t("debug.qr_tooltip")
	open_row.add_child(qr_page_button)

	run.add_child(_section(_t("debug.preset")))
	var preset_row := HBoxContainer.new()
	run.add_child(preset_row)
	_preset_label = Label.new()
	_preset_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_label.add_theme_font_size_override("font_size", 12)
	_preset_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preset_row.add_child(_preset_label)
	_preset_button = _button(_t("debug.create_preset"), _on_create_preset)
	preset_row.add_child(_preset_button)
	var export_dir_button := _button(_t("debug.folder"), _on_open_export_dir)
	export_dir_button.tooltip_text = _t("debug.open_export_dir")
	preset_row.add_child(export_dir_button)

	var hint := Label.new()
	hint.text = _t("debug.first_phone_hint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", _ed_dim)
	run.add_child(hint)
