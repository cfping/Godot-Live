@tool
extends "res://addons/gdlive/dock_settings.gd"

## GDLive dock — log layer: the 日志 tab and log rendering.
##
## Owns the log ring buffer, filtering/autoscroll, copy/clear, the remote JS command
## line and screenshot requests from connected pages.
##
## Layered dock scripts (base → top):
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs → dock.gd

func _on_reload_clients() -> void:
	if server == null or not bool(server.is_running()):
		return
	var count: int = int(server.reload_clients())
	_append_log("info", _t("toast.refresh_pushed") % count)
	_toast(_t("toast.refresh_pushed") % count)

func _on_shot_request() -> void:
	if server == null or not bool(server.is_running()):
		_append_log("warn", _t("toast.shot_no_server"))
		return
	var result := String(server.request_shots())
	if result.begins_with("ERROR::"):
		_append_log("error", result.trim_prefix("ERROR::"))
		return
	var count := result.to_int()
	if count <= 0:
		_append_log("warn", _t("toast.shot_no_pages_hint"))
		_toast(_t("toast.no_pages"), "warn")
	else:
		_append_log("info", _t("log.shot_requested") % count)
		_toast(_t("log.shot_requested_alt") % count)

func _on_screenshot(uid: String, png_base64: String) -> void:
	var png := Marshalls.base64_to_raw(png_base64)
	if png.is_empty():
		_append_log("error", _t("log.shot_decode_failed") % uid)
		return
	var image := Image.new()
	var err := image.load_png_from_buffer(png)
	if err != OK:
		_append_log("error", _t("log.shot_not_png") % [uid, error_string(err)])
		return
	var dir_path := ProjectSettings.globalize_path("res://gdlive-shots")
	DirAccess.make_dir_recursive_absolute(dir_path)
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-")
	var file_path := "%s/gdlive-shot-%s-%s.png" % [dir_path, uid, stamp]
	err = image.save_png(file_path)
	if err != OK:
		_append_log("error", _t("log.shot_save_failed") % [file_path, error_string(err)])
		return
	_append_log("success", _t("log.shot_saved") % [file_path, image.get_width(), image.get_height()])
	_toast(_t("toast.shot_saved") % [image.get_width(), image.get_height()], "success")

func _on_cmd_submitted(text: String) -> void:
	var expr := text.strip_edges()
	if expr == "":
		return
	if server == null or not bool(server.is_running()):
		_append_log("warn", _t("toast.cmd_no_server"))
		return
	var result := String(server.send_command(expr))
	if result.begins_with("ERROR::"):
		_append_log("error", result.trim_prefix("ERROR::"))
		_toast(_t("toast.cmd_failed"), "error")
		return
	_append_log("info", _t("log.cmd_sent_detail") % [result, expr])
	_toast(_t("toast.cmd_sent") % result)
	_cmd_history.push_front(expr)
	if _cmd_history.size() > 20:
		_cmd_history.resize(20)
	_cmd_history_index = -1
	_save_settings()

func _on_cmd_gui_input(event: InputEvent) -> void:
	if _cmd_history.is_empty():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_UP:
			_cmd_history_index = mini(_cmd_history_index + 1, _cmd_history.size() - 1)
			_cmd_input.text = _cmd_history[_cmd_history_index]
			_cmd_input.caret_column = _cmd_input.text.length()
		elif event.keycode == KEY_DOWN and _cmd_history_index >= 0:
			_cmd_history_index -= 1
			if _cmd_history_index < 0:
				_cmd_input.text = ""
			else:
				_cmd_input.text = _cmd_history[_cmd_history_index]
				_cmd_input.caret_column = _cmd_input.text.length()

## Extension signals: relayed browser log lines and file-watch events.
func _on_log(level: String, text: String) -> void:
	_append_log(level, text)

func _on_browser_log(level: String, text: String, url: String) -> void:
	var source := url.get_slice("://", 1).get_slice("/", 0)
	_append_log(level, text, source)

func _on_files_changed(count: int, sample: PackedStringArray) -> void:
	var preview := ", ".join(sample)
	_append_log("debug", _t("log.files_changed") % [count, preview])

func _append_log(level: String, text: String, source := "") -> void:
	if _log_view == null:
		return

	var entry := {
		"level": level,
		"text": text,
		"source": source,
		"time": Time.get_time_string_from_system(),
	}
	_log_entries.append(entry)
	if _log_entries.size() > 1200:
		_log_entries.pop_front()
		_rebuild_log()
	elif _log_matches(entry):
		_render_log_entry(entry)

	# Mirror to Godot's Output panel (and headless logs) so relayed browser
	# console / network / export lines show up in the editor console too,
	# not only inside the dock. "debug" (file-watch noise) stays panel-only.
	if level != "debug":
		var prefix := "[GDLive][%s]" % str(entry.level).to_upper()
		if source != "":
			print(prefix, " [", source, "] ", text)
		else:
			print(prefix, " ", text)

func _log_matches(entry: Dictionary) -> bool:
	match _log_filter:
		1:
			return entry.level == "warn" or entry.level == "error"
		2:
			return entry.level == "export"
		3:
			return entry.level == "net"
		_:
			return true

func _render_log_entry(entry: Dictionary) -> void:
	var color: String = LEVEL_COLORS.get(entry.level, "#c9d1d9")
	var line := "[color=#6e7681]%s[/color] [color=%s]%s[/color] " % [
		entry.time,
		color,
		str(entry.level).to_upper(),
	]
	if entry.source != "":
		line += "[color=#a371f7][%s][/color] " % entry.source
	line += str(entry.text).replace("[", "[lb]") + "\n"
	_log_view.append_text(line)

func _rebuild_log() -> void:
	if _log_view == null:
		return
	_log_view.clear()
	for entry in _log_entries:
		if _log_matches(entry):
			_render_log_entry(entry)
	_log_view.scroll_following = _log_autoscroll

func _on_log_filter_changed(index: int) -> void:
	_log_filter = index
	_rebuild_log()
	_save_settings()

func _on_log_autoscroll(pressed: bool) -> void:
	_log_autoscroll = pressed
	if _log_view != null:
		_log_view.scroll_following = pressed
	_save_settings()

func _copy_log() -> void:
	var lines := PackedStringArray()
	for entry in _log_entries:
		if _log_matches(entry):
			lines.append("%s [%s] %s" % [entry.time, entry.level, entry.text])
	DisplayServer.clipboard_set("\n".join(lines))
	_append_log("info", _t("toast.logs_copied") % lines.size())
	_toast(_t("toast.logs_copied") % lines.size())

func _clear_log() -> void:
	_log_entries.clear()
	if _log_view != null:
		_log_view.clear()
	_toast(_t("toast.logs_cleared"))

func _build_tab_logs() -> void:
	var logs := VBoxContainer.new()
	logs.name = "tab_logs"
	logs.add_theme_constant_override("separation", 6)
	_tabs.add_child(logs)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, _t("tab.logs"))

	_log_pro_hint = Label.new()
	_log_pro_hint.text = _t("hint.overlay_pro")
	_log_pro_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log_pro_hint.add_theme_font_size_override("font_size", 10)
	_log_pro_hint.add_theme_color_override("font_color", _ed_warning)
	logs.add_child(_log_pro_hint)

	_log_toolbar = HBoxContainer.new()
	logs.add_child(_log_toolbar)
	var log_title := _label(_t("tab.logs"))
	log_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log_toolbar.add_child(log_title)

	_log_filter_option = OptionButton.new()
	_log_filter_option.add_item(_t("logs.filter_all"), 0)
	_log_filter_option.add_item(_t("logs.filter_warnings"), 1)
	_log_filter_option.add_item(_t("common.export"), 2)
	_log_filter_option.add_item(_t("logs.filter_network"), 3)
	_log_filter_option.item_selected.connect(_on_log_filter_changed)
	_log_toolbar.add_child(_log_filter_option)
	_log_toolbar.add_child(_button(_t("logs.screenshot"), _on_shot_request))
	_log_toolbar.add_child(_button(_t("common.copy"), _copy_log))
	_log_toolbar.add_child(_button(_t("common.clear"), func(): _clear_log()))

	var log_row2 := HBoxContainer.new()
	logs.add_child(log_row2)
	_log_autoscroll_check = _check(_t("logs.autoscroll"), true)
	_log_autoscroll_check.toggled.connect(_on_log_autoscroll)
	log_row2.add_child(_log_autoscroll_check)
	var log_spacer := Control.new()
	log_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_row2.add_child(log_spacer)
	log_row2.add_child(_button(_t("logs.refresh_pages"), _on_reload_clients))

	_log_view = RichTextLabel.new()
	_log_view.bbcode_enabled = true
	_log_view.scroll_following = true
	_log_view.selection_enabled = true
	_log_view.custom_minimum_size = Vector2(0, 180)
	_log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_view.add_theme_font_size_override("normal_font_size", 11)
	_log_view.add_theme_stylebox_override("normal", _card_style(_ed_base, _ed_dark2, 2, 10))
	if _ed_mono != null:
		_log_view.add_theme_font_override("normal_font", _ed_mono)
	_log_view.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	logs.add_child(_log_view)

	# Remote command row: evaluate a JS expression in every connected page.
	var cmd_row := HBoxContainer.new()
	logs.add_child(cmd_row)
	_cmd_input = LineEdit.new()
	_cmd_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cmd_input.placeholder_text = _t("logs.cmd_placeholder")
	_cmd_input.text_submitted.connect(_on_cmd_submitted)
	_cmd_input.gui_input.connect(_on_cmd_gui_input)
	cmd_row.add_child(_cmd_input)
	var cmd_button := _button(_t("common.run"), func(): _on_cmd_submitted(_cmd_input.text))
	cmd_row.add_child(cmd_button)
