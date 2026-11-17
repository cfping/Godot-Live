@tool
extends "res://addons/gdlive/dock_cert.gd"

## GDLive dock — remote play layer: the 远程 tab and tunnel controls.
##
## Starts / stops the relay tunnel, renders its QR code, the remaining-time countdown
## and the one-shot expiry toasts.
##
## Layered dock scripts (base → top):
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs → dock.gd

# Remaining-time thresholds (seconds) that trigger one toast reminder each.
const REMOTE_REMIND_SECONDS: Array[int] = [600, 300, 60, 10]

func _refresh_remote() -> void:
	if server == null or _remote_status_label == null:
		return

	var st: Dictionary = server.remote_status()
	var phase := str(st.get("phase", "idle"))
	var url := str(st.get("url", ""))
	var expires := str(st.get("expires", ""))
	var error := str(st.get("error", ""))
	var quota := str(st.get("quota_note", ""))
	var busy := phase == "starting" or phase == "running"
	var paid := _license_tier == "pro" or _license_tier == "studio"
	var session_id := str(st.get("id", ""))
	if session_id != _remote_session_id:
		# New tunnel session: re-arm the one-shot reminder toasts.
		_remote_session_id = session_id
		_remote_toasts_fired.clear()
	var remaining := int(st.get("expires_at", 0)) - int(Time.get_unix_time_from_system())

	# Smooth 1 s countdown only while a tunnel is live.
	if phase == "running" and _remote_tick_timer.is_stopped():
		_remote_tick_timer.start()
	elif phase != "running" and not _remote_tick_timer.is_stopped():
		_remote_tick_timer.stop()

	_remote_start_button.disabled = busy
	_remote_stop_button.disabled = not busy
	_remote_start_button.tooltip_text = (
		_t("remote.limit_studio")
		if _license_tier == "studio"
		else (
			_t("remote.limit_pro")
			if paid
			else _t("remote.limit_free")
		)
	)

	match phase:
		"starting":
			_remote_status_label.text = _t("remote.establishing")
			_remote_status_label.add_theme_color_override("font_color", _ed_warning)
		"running":
			_remote_status_label.text = _t("remote.running") % _format_remaining(remaining)
			if quota != "":
				_remote_status_label.text += "\n" + quota
			_remote_status_label.tooltip_text = _t("support.valid_until") % expires
			# Color shifts as the tunnel runs out of time.
			if remaining < 60:
				_remote_status_label.add_theme_color_override("font_color", Color(0.97, 0.32, 0.29))
			elif remaining < 300:
				_remote_status_label.add_theme_color_override("font_color", Color(0.95, 0.6, 0.2))
			else:
				_remote_status_label.add_theme_color_override("font_color", Color(0.25, 0.73, 0.31))
			# One-shot toast reminders at fixed thresholds (dock log + browser).
			if remaining > 0:
				for threshold in REMOTE_REMIND_SECONDS:
					if remaining <= threshold and not _remote_toasts_fired.has(threshold):
						_remote_toasts_fired[threshold] = true
						_fire_remote_reminder(threshold)
		"error":
			_remote_status_label.text = "✗ %s" % error
			_remote_status_label.add_theme_color_override("font_color", Color(0.97, 0.32, 0.29))
		"stopped":
			_remote_status_label.text = _t("status.stopped")
			_remote_status_label.add_theme_color_override("font_color", _ed_dim)
		_:
			# 内置中继不回显地址，避免泄露基础设施信息
			_remote_status_label.text = (
				_t("status.not_started") if paid else _t("remote.not_started_free")
			)
			_remote_status_label.add_theme_color_override("font_color", _ed_dim)

	_remote_custom_input.visible = _license_tier == "studio"
	if url != _remote_last_url:
		var gained := _remote_last_url == "" and url != ""
		_remote_last_url = url
		if url == "":
			_remote_qr.clear_matrix()
		else:
			var matrix: Dictionary = server.qr_matrix(url, "M")
			if bool(matrix.get("ok", false)):
				_remote_qr.set_matrix(int(matrix["size"]), matrix["data"], url)
			else:
				_remote_qr.clear_matrix()
		if gained:
			# Hand the address over immediately: clipboard + one click opens it.
			# The URL itself is never displayed (privacy); QR + 复制/打开 suffice.
			DisplayServer.clipboard_set(url)
			_append_log("info", _t("toast.remote_copied_share_alt"))

	_remote_copy_button.disabled = url == ""
	_remote_open_button.disabled = url == ""
	_update_remote_limits()

func _update_remote_limits() -> void:
	if _remote_ttl == null:
		return
	var studio := _license_tier == "studio"
	var paid := _license_tier == "pro" or studio
	var previous := _remote_ttl.selected
	_remote_ttl.clear()
	if paid:
		_remote_ttl.add_item(_t("remote.ttl_5m"), 0)
		_remote_ttl.add_item(_t("remote.ttl_10m"), 1)
		_remote_ttl.add_item(_t("remote.ttl_15m"), 2)
		_remote_ttl.add_item(_t("remote.ttl_30m"), 3)
		_remote_ttl.add_item(_t("remote.ttl_45m"), 4)
		_remote_ttl.add_item(_t("remote.ttl_60m"), 5)
		_remote_ttl.add_item(_t("remote.ttl_6h"), 6)
		_remote_ttl.add_item(_t("remote.ttl_12h"), 7)
		_remote_ttl.add_item(_t("remote.ttl_24h"), 8)
		if studio:
			_remote_ttl.add_item(_t("remote.ttl_7d"), 9)
		_remote_ttl.disabled = false
		_remote_ttl.selected = clampi(previous, 0, _remote_ttl.item_count - 1)
	else:
		_remote_ttl.add_item(_t("remote.ttl_15m"), 2)
		_remote_ttl.disabled = true
		_remote_ttl.selected = 2
	_remote_custom_input.visible = studio

func _on_remote_start() -> void:
	if server == null:
		return
	# The relay address is baked into the plugin; an empty string selects
	# the built-in production relay (https://gdlive.iowk.com).
	# Free / trial is always a single 15-minute session.
	var ttl := 900
	if _license_tier == "pro" or _license_tier == "studio":
		match _remote_ttl.selected:
			0:
				ttl = 5 * 60
			1:
				ttl = 10 * 60
			2:
				ttl = 15 * 60
			3:
				ttl = 30 * 60
			4:
				ttl = 45 * 60
			5:
				ttl = 60 * 60
			6:
				ttl = 6 * 3600
			7:
				ttl = 12 * 3600
			8:
				ttl = 24 * 3600
			9:
				ttl = 7 * 86400

	var custom_domain := ""
	if _license_tier == "studio" and _remote_custom_input != null:
		custom_domain = _remote_custom_input.text.strip_edges()

	var result: Dictionary = server.start_remote(
		"",
		_remote_password_input.text,
		ttl,
		custom_domain
	)
	if bool(result.get("ok", false)):
		_append_log("info", _t("log.remote_requesting"))
		_toast(_t("log.remote_requesting"))
	else:
		_append_log("error", _t("log.remote_start_failed") % str(result.get("error", "")))
		_toast(_t("toast.remote_start_failed") + str(result.get("error", "")), "error")
	_refresh_remote()

func _on_remote_stop() -> void:
	if server == null:
		return
	server.stop_remote()
	_toast(_t("toast.remote_stopping"))
	_refresh_remote()

func _on_remote_copy() -> void:
	if _remote_last_url == "":
		return
	DisplayServer.clipboard_set(_remote_last_url)
	_append_log("info", _t("toast.remote_copied_share"))
	_toast(_t("toast.remote_copied"))
	# Flash the button so the user gets visual feedback even without the log.
	_remote_copy_token += 1
	var token := _remote_copy_token
	_remote_copy_button.text = _t("toast.copied")
	await get_tree().create_timer(1.5).timeout
	if token == _remote_copy_token and is_instance_valid(_remote_copy_button):
		_remote_copy_button.text = _t("common.copy_address")

func _on_remote_open() -> void:
	if _remote_last_url != "":
		OS.shell_open(_remote_last_url)
		_toast(_t("toast.remote_opened"))

func _format_remaining(seconds: int) -> String:
	if seconds <= 0:
		return _t("remote.expiring_soon")
	var hours := seconds / 3600
	var mins := (seconds % 3600) / 60
	var secs := seconds % 60
	if hours > 0:
		return _t("remote.remaining_hours") % [hours, mins]
	return "%02d:%02d" % [mins, secs]

func _fire_remote_reminder(threshold: int) -> void:
	var text := _t("toast.remote_ending")
	match threshold:
		600:
			text = _t("toast.remote_10m")
		300:
			text = _t("toast.remote_5m")
		60:
			text = _t("toast.remote_1m")
	_append_log("warn", text)
	# Also pops a toast on every open browser page, including phones on
	# the tunnel — the game server relays it through the same channel as
	# page reloads.
	if server != null:
		server.toast(text)

func _build_tab_remote() -> void:
	var remote := _make_tab(_t("tab.remote"))

	remote.add_child(_section(_t("remote.title")))

	# The relay address is baked into the plugin; only the duration is
	# user-selectable here.
	var ttl_row := HBoxContainer.new()
	remote.add_child(ttl_row)
	_remote_ttl = OptionButton.new()
	# Durations are rebuilt per tier in _update_remote_limits(); kept in
	# sync with the ttl mapping in _on_remote_start.
	_remote_ttl.add_item(_t("remote.ttl_15m"), 2)
	_remote_ttl.selected = 2
	ttl_row.add_child(_remote_ttl)

	var remote_pw_row := HBoxContainer.new()
	remote.add_child(remote_pw_row)
	_remote_password_input = LineEdit.new()
	_remote_password_input.placeholder_text = _t("remote.password")
	_remote_password_input.secret = true
	_remote_password_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_remote_password_input.add_theme_stylebox_override("normal", _card_style(_ed_dark3, _ed_dark2, 2, 10))
	remote_pw_row.add_child(_remote_password_input)

	_remote_custom_input = LineEdit.new()
	_remote_custom_input.placeholder_text = _t("remote.custom_domain")
	_remote_custom_input.visible = false
	_remote_custom_input.add_theme_stylebox_override("normal", _card_style(_ed_dark3, _ed_dark2, 2, 10))
	remote.add_child(_remote_custom_input)

	var remote_buttons := HBoxContainer.new()
	remote.add_child(remote_buttons)
	_remote_start_button = _button(_t("remote.start"), _on_remote_start)
	_remote_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_primary(_remote_start_button)
	remote_buttons.add_child(_remote_start_button)
	_remote_stop_button = _button(_t("common.stop"), _on_remote_stop)
	_remote_stop_button.disabled = true
	remote_buttons.add_child(_remote_stop_button)

	_remote_status_label = Label.new()
	_remote_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_remote_status_label.add_theme_font_size_override("font_size", 11)
	remote.add_child(_remote_status_label)

	var remote_qr_panel := PanelContainer.new()
	remote_qr_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	remote_qr_panel.add_theme_stylebox_override("panel", _qr_card_style())
	remote.add_child(remote_qr_panel)
	var remote_qr_box := CenterContainer.new()
	remote_qr_box.custom_minimum_size = Vector2(0, 150)
	remote_qr_panel.add_child(remote_qr_box)
	_remote_qr = QR_VIEW.new()
	remote_qr_box.add_child(_remote_qr)

	var remote_action_row := HBoxContainer.new()
	remote.add_child(remote_action_row)
	_remote_copy_button = _button(_t("common.copy_address"), _on_remote_copy)
	_remote_copy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_remote_copy_button.disabled = true
	remote_action_row.add_child(_remote_copy_button)
	_remote_open_button = _button(_t("common.open_browser"), _on_remote_open)
	_remote_open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_remote_open_button.disabled = true
	remote_action_row.add_child(_remote_open_button)
