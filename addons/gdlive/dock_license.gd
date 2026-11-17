@tool
extends "res://addons/gdlive/dock_support.gd"

## GDLive dock — license layer: tier state, activation and the support service.
##
## Refreshes the license badge, quota and machine code, activates / removes codes and
## gates Pro-only options.
##
## Layered dock scripts (base → top):
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs → dock.gd

func _set_pro_check(box: CheckBox, base_text: String, pro: bool, tip: String) -> void:
	if box == null:
		return
	box.text = base_text if pro else base_text + " · Pro"
	box.disabled = not pro
	box.tooltip_text = tip if pro else _t("common.pro_feature")

func _apply_support_result(result: Dictionary) -> void:
	if not bool(result.get("ok", false)):
		_support_base = ""
		_append_log("warn", _t("log.support_failed") % str(result.get("error", "")))
		_refresh_support_ui()
		return
	var urls: PackedStringArray = result.get("urls", PackedStringArray())
	_support_base = ""
	for url in urls:
		if str(url).contains("127.0.0.1"):
			_support_base = str(url)
			break
	if _support_base == "" and urls.size() > 0:
		_support_base = str(urls[0])
	_append_log("info", _t("log.support_running") + _support_base + "/__gdlive/")
	if _support_base != "" and not _support_base.ends_with(":31065"):
		_append_log(
			"warn",
			_t("log.support_port_busy")
			% _support_base
		)
	_refresh_support_ui()

func _refresh_support_ui() -> void:
	var ready := _support_base != ""
	if _support_open_button != null:
		_support_open_button.disabled = not ready
	if _support_copy_button != null:
		_support_copy_button.disabled = not ready

func _on_open_support() -> void:
	if _support_base == "":
		_append_log("warn", _t("status.support_off"))
		return
	OS.shell_open(_support_base + "/__gdlive/")
	_toast(_t("toast.support_page_opened"))

func _on_copy_support() -> void:
	if _support_base == "":
		return
	DisplayServer.clipboard_set(_support_base + "/__gdlive/")
	_append_log("info", _t("toast.support_addr_copied"))
	_toast(_t("toast.support_page_copied"))

func _refresh_license() -> void:
	if server == null or _license_status_label == null:
		return

	var st: Dictionary = server.license_status()
	var pro := bool(st.get("pro", false))
	_license_pro = pro
	# Trial users must keep access to the field (trial -> paid conversion);
	# hide only once a real license is active.
	if _activate_card != null:
		_activate_card.visible = not pro or bool(st.get("trial", false))
	var tier := str(st.get("tier", "free"))
	_license_tier = tier
	var days := int(st.get("days_left", 0))
	var expires := str(st.get("expires", ""))
	var used := int(st.get("exports_today", 0))
	var limit := int(st.get("export_limit", 0))
	var left := int(st.get("exports_left", 0))
	var name := str(st.get("name", ""))

	match tier:
		"pro", "studio":
			var validity := _t("support.permanent") if expires == "永久" else _t("support.valid_until") % expires
			var label := "Studio" if tier == "studio" else "Pro"
			_license_status_label.text = _t("support.status_licensed") % [
				label,
				validity,
				"（%s）" % name if name != "" else "",
			]
			var color := BRAND_VIOLET if tier == "studio" else BRAND_GOLD
			_license_status_label.add_theme_color_override("font_color", color)
			_license_badge.text = "STUDIO" if tier == "studio" else "PRO"
			_license_badge.add_theme_color_override("font_color", color)
			_style_badge(_license_badge, color)
		"trial":
			_license_status_label.text = _t("support.status_trial") % [days, expires]
			_license_status_label.add_theme_color_override("font_color", BRAND_GOLD)
			_license_badge.text = "TRIAL"
			_license_badge.add_theme_color_override("font_color", BRAND_GOLD)
			_style_badge(_license_badge, BRAND_GOLD)
		_:
			_license_status_label.text = _t("support.status_free")
			_license_status_label.add_theme_color_override("font_color", Color(0.65, 0.67, 0.7))
			_license_badge.text = "FREE"
			_license_badge.add_theme_color_override("font_color", BRAND_GREEN)
			_style_badge(_license_badge, BRAND_GREEN)

	_license_quota_label.text = (
		_t("support.quota_pro")
		if pro
		else _t("support.quota_free") % [used, limit]
	)
	var bound := str(st.get("bound_id", ""))
	_license_machine_label.text = _t("support.machine_code") + str(st.get("machine_id", ""))
	if bound != "":
		_license_machine_label.text += _t("support.bound_other_alt") + bound
	_contact_email = str(st.get("email", "")).strip_edges()
	if _contact_email == "":
		_contact_email = FALLBACK_EMAIL
	_contact_wechat = str(st.get("wechat", "")).strip_edges()
	if _contact_wechat == "":
		_contact_wechat = FALLBACK_WECHAT
	if _contact_email_label != null:
		_contact_email_label.text = _t("contact.email") + _contact_email
	if _contact_wechat_label != null:
		_contact_wechat_label.text = _t("contact.wechat") + _contact_wechat
	_license_machine_label.tooltip_text = _t("support.machine_tooltip")
	_buy_button.text = _t("support.renew") if pro else _t("buy.title")
	_remove_license_button.disabled = not pro
	# 私用（永久）授权：没有续费 / 移除授权 / 购买入口，整行隐藏。
	var permanent := pro and expires == "永久"
	if _license_row != null:
		_license_row.visible = not permanent
	if _support_row != null:
		_support_row.visible = not permanent
	if _buy_dialog != null:
		_buy_price_label.text = str(st.get("price", ""))
		_buy_machine_label.text = str(st.get("machine_id", ""))
		_buy_step3_label.text = (
			_t("buy.step3")
			% _contact_wechat
		)

	if not pro and _tls.button_pressed:
		# Avoid a trap: a disabled HTTPS checkbox would prevent starting at all.
		_tls.button_pressed = false

	_set_pro_check(_auto_export, _t("settings.auto_export"), pro, _t("settings.auto_export_tip_short"))
	_set_pro_check(_auto_reload, _t("settings.auto_reload"), pro, _t("settings.auto_reload_tip_short"))
	_set_pro_check(_tls, _t("settings.https"), pro, _t("settings.https_tip_short"))
	_set_pro_check(_debug_overlay, _t("settings.debug_overlay"), pro, _t("settings.debug_overlay_tip_short"))
	if _ca_pro_hint != null:
		_ca_pro_hint.visible = not pro
	if _log_pro_hint != null:
		_log_pro_hint.visible = not pro

	var exporting := false
	if server.has_method("is_exporting"):
		exporting = bool(server.is_exporting())
	_export_button.disabled = exporting or (not pro and left <= 0)
	if not pro and left <= 0:
		_export_button.tooltip_text = _t("tooltip.export_limit_hit")
	else:
		_export_button.tooltip_text = (
			_t("tooltip.exports_unlimited") if pro else _t("tooltip.exports_left") % left
		)

	_update_remote_limits()
	_refresh_ca_info()
	if _tabs != null and _tabs.current_tab == _tab_cert:
		_ensure_ca_for_qr()

func _on_copy_machine() -> void:
	if server == null:
		return
	var st: Dictionary = server.license_status()
	DisplayServer.clipboard_set(str(st.get("machine_id", "")))
	_append_log("info", _t("toast.machine_copied_buy"))
	_toast(_t("toast.machine_copied"))

func _on_open_pro_page() -> void:
	# Preferred: pay right here — price, machine code and payment QR codes in
	# one dialog, no browser needed. Falls back to the support page when the
	# server object is unavailable.
	if server != null and _buy_dialog != null:
		_refresh_license()
		_popup_dialog(_buy_dialog)
		return
	_on_open_pro_browser()

func _on_open_pro_browser() -> void:
	# Prefer the standalone support service: it works even when the game
	# server is stopped or its port is occupied.
	var base := _support_base
	if base == "":
		base = _selected_url()
	if base == "":
		_append_log("warn", _t("toast.support_not_running"))
		return
	OS.shell_open(base + "/pro")

func _on_license_input_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_ENTER, KEY_KP_ENTER] and (event.ctrl_pressed or event.meta_pressed):
			_license_input.accept_event()
			_on_activate_license()

func _on_activate_license() -> void:
	if server == null or _license_input == null:
		return
	# Accept codes pasted across multiple lines or with stray spaces.
	var key := _license_input.text
	key = key.replace("\r", "").replace("\n", "").replace("\t", "").replace(" ", "").strip_edges()
	if key == "":
		_append_log("warn", _t("toast.paste_code_first"))
		return
	var result: Dictionary = server.activate_license(key)
	if bool(result.get("ok", false)):
		_append_log("success", _t("toast.activated"))
		_toast(_t("toast.activated"), "success")
		_license_input.text = ""
		_refresh_license()
		_append_log("info", _t("toast.restart_for_pro"))
	else:
		_append_log("error", _t("log.activate_failed") % str(result.get("error", "")))
		_toast(_t("toast.activate_failed") + str(result.get("error", "")), "error")

func _on_remove_license() -> void:
	# Destructive and hard to undo silently, so always require an explicit
	# second confirmation instead of revoking on the first click.
	if server == null or not _license_pro:
		return
	_popup_dialog(_confirm_remove_license)

func _do_remove_license() -> void:
	if server == null:
		return
	var result: Dictionary = server.deactivate_license()
	if bool(result.get("ok", false)):
		server.stop_remote()
		_append_log("warn", _t("toast.license_removed"))
		_toast(_t("toast.license_removed_short"), "warn")
		_refresh_license()
	else:
		_append_log("error", str(result.get("error", "")))
		_toast(str(result.get("error", "")), "error")
