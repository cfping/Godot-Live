@tool
extends "res://addons/gdlive/dock_log.gd"

## GDLive dock — root CA layer: the 证书安装 tab and certificate lifecycle.
##
## Generates / installs / rotates the machine-local root CA and renders the mobile
## install page QR code.
##
## Layered dock scripts (base → top):
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs → dock.gd

func _on_tab_changed(index: int) -> void:
	_save_settings()
	if index == _tab_cert:
		_ca_auto_attempted = false
		_ensure_ca_for_qr()

func _ensure_ca_for_qr() -> void:
	if server == null or _ca_exists or _ca_auto_attempted:
		return
	if not _license_pro or not bool(server.is_running()):
		return
	_ca_auto_attempted = true
	var result: Dictionary = server.ensure_ca()
	if bool(result.get("ok", false)):
		_append_log("info", _t("toast.cert_generated"))
		_refresh_ca_info()
	else:
		_append_log("warn", _t("log.cert_auto_failed") % str(result.get("error", "")))

func _refresh_ca_info() -> void:
	if server == null or _ca_label == null:
		return
	var ca: Dictionary = server.ca_info()
	var exists := bool(ca.get("exists", false))
	_ca_exists = exists
	_install_urls = ca.get("install_urls", PackedStringArray())

	if not exists:
		_ca_status_label.text = _t("cert.not_generated")
		_ca_status_label.add_theme_color_override("font_color", _ed_warning)
		_ca_label.text = _t("cert.auto_hint")
		_ca_label.tooltip_text = ""
		_ca_install_button.disabled = true
		_ca_rotate_button.disabled = true
		_ca_trust_button.disabled = true
		_ca_generate_button.visible = true
		_ca_generate_button.disabled = not _license_pro
		_ca_pro_hint.visible = not _license_pro
		_update_ca_page()
		return

	var fp := str(ca.get("fingerprint", ""))
	if _ca_trust_installed:
		_ca_status_label.text = _t("cert.trusted")
		_ca_status_label.add_theme_color_override("font_color", Color(0.25, 0.73, 0.31))
	else:
		_ca_status_label.text = _t("cert.not_trusted")
		_ca_status_label.add_theme_color_override("font_color", _ed_warning)

	_ca_label.text = _t("cert.detail") % [
		str(ca.get("cn", "GDLive Local Dev CA")),
		str(ca.get("not_after", "?")),
		fp.left(23),
	]
	_ca_label.tooltip_text = (
		"SHA-256\n" + fp
		+ "\n\n" + _ca_trust_detail
		+ _t("cert.dir_label") + str(ca.get("dir", ""))
	)

	_ca_install_button.disabled = not _license_pro
	_ca_rotate_button.disabled = not _license_pro
	_ca_trust_button.disabled = not _license_pro
	_ca_generate_button.visible = false
	_ca_pro_hint.visible = not _license_pro
	_update_ca_page()

func _compute_ca_page_url() -> String:
	var base := _selected_url()
	if base != "":
		# Prefer the support-service URL on the same NIC as the selected game URL.
		var host := base.get_slice("://", 1).get_slice(":", 0)
		for url in _install_urls:
			if str(url).get_slice("://", 1).get_slice(":", 0) == host:
				return url
	if _install_urls.size() > 0:
		return _install_urls[0]
	if base != "":
		return base + "/ssl"
	return ""

func _update_ca_page() -> void:
	var url := _compute_ca_page_url()
	var changed := url != _ca_page_url
	_ca_page_url = url

	var ready := url != "" and _ca_exists
	if _ca_page_label != null:
		if url == "":
			_ca_page_label.text = _t("cert.start_first_hint")
		elif not _ca_exists:
			_ca_page_label.text = _t("cert.qr_pending_hint")
		else:
			_ca_page_label.text = url
	if _ca_qr != null:
		_ca_qr.visible = ready
	if _ca_qr_placeholder != null:
		_ca_qr_placeholder.visible = not ready
	_ca_guide_button.disabled = not ready
	_ca_copy_button.disabled = not ready

	if _ca_qr == null:
		return
	if not ready:
		_ca_qr.clear_matrix()
		_ca_qr_cache_url = ""
		return
	if not changed and _ca_qr_cache_url == url:
		return

	var matrix: Dictionary = server.qr_matrix(url, "M")
	if bool(matrix.get("ok", false)):
		_ca_qr.set_matrix(int(matrix["size"]), matrix["data"], url)
		_ca_qr_cache_url = url
	else:
		_ca_qr.clear_matrix()
		_ca_qr_cache_url = ""

func _check_ca_trust() -> void:
	if server == null:
		return
	var result: Dictionary = server.ca_trust_status()
	_ca_trust_installed = bool(result.get("installed", false))
	_ca_trust_detail = str(result.get("detail", ""))
	_refresh_ca_info()

func _on_check_trust() -> void:
	_check_ca_trust()
	_append_log(
		"success" if _ca_trust_installed else "warn",
		_t("cert.trust_check") % _ca_trust_detail
	)
	_toast(
		_t("cert.trust_check") % _ca_trust_detail,
		"success" if _ca_trust_installed else "warn"
	)

func check_ca_on_startup() -> void:
	if server == null:
		return

	var ca: Dictionary = server.ca_info()
	if not bool(ca.get("exists", false)) and _tls.button_pressed:
		server.ensure_ca()
		ca = server.ca_info()

	_check_ca_trust()

	if not bool(ca.get("exists", false)):
		_append_log("info", _t("cert.not_generated_hint"))
		return

	if _ca_trust_installed:
		_append_log("success", _t("log.cert_trusted"))
		return

	_append_log("warn", _t("log.cert_not_trusted") % _ca_trust_detail)

	# First run: the onboarding dialog explains/offers certificate setup.
	if not _onboarded:
		return
	if not _ca_prompt_check.button_pressed:
		return
	_show_ca_prompt()

func _show_ca_prompt() -> void:
	var ca: Dictionary = server.ca_info()
	var fp := str(ca.get("fingerprint", ""))
	_ca_prompt.dialog_text = (
		_t("ca_prompt.text1")
		+ _t("ca_prompt.text2")
		+ _t("ca_prompt.text3")
		+ _t("ca_prompt.text4")
	) % [
		str(ca.get("cn", "GDLive Local Dev CA")),
		fp.left(23),
		_ca_trust_detail,
	]
	# Height is a hint, not a target: the window grows to fit the label, so
	# keep it small and let content size the dialog (no dead space).
	_popup_dialog(_ca_prompt, Vector2i(560, 200))

func _on_ca_prompt_install() -> void:
	_on_install_ca()

func _on_ca_prompt_action(action: StringName) -> void:
	if action == &"guide":
		_on_open_ca_guide()

func _on_generate_ca() -> void:
	if server == null:
		return
	var result: Dictionary = server.ensure_ca()
	if bool(result.get("ok", false)):
		_append_log("success", _t("log.cert_generated") % str(result.get("fingerprint", "")))
		_append_log("info", _t("log.cert_next_step"))
		_toast(_t("log.cert_next_step_alt"), "success")
	else:
		_append_log("error", _t("log.cert_failed") % str(result.get("error", "")))
		_toast(_t("toast.cert_failed"), "error")
	_ca_trust_installed = false
	_ca_trust_detail = _t("cert.not_installed")
	_refresh_ca_info()

func _on_install_ca() -> void:
	if server == null:
		return
	if not server.install_ca():
		_append_log("warn", _t("toast.cert_manual_phone"))
		_toast(_t("toast.cert_manual"), "warn")
		return
	_append_log("info", _t("log.cert_installing"))
	_toast(_t("log.cert_installing_alt"))

func _on_ca_installed(ok: bool, message: String) -> void:
	if ok:
		_append_log("success", _t("log.cert_installed_detail") + message)
		_toast(_t("toast.cert_installed"), "success")
	else:
		_append_log("error", _t("toast.cert_auto_incomplete") + message)
		_toast(_t("toast.cert_auto_incomplete") + message, "error")
	_check_ca_trust()

func _on_open_ca_guide() -> void:
	if _ca_page_url == "":
		_append_log("warn", _t("toast.start_first_install"))
		_toast(_t("toast.start_first"), "warn")
		return
	OS.shell_open(_ca_page_url)
	_toast(_t("toast.install_page_opened"))

func _on_copy_ca_page() -> void:
	if _ca_page_url == "":
		return
	DisplayServer.clipboard_set(_ca_page_url)
	_append_log("info", _t("toast.install_addr_copied_detail") + _ca_page_url)
	_toast(_t("toast.install_addr_copied"))

func _on_open_ca_dir() -> void:
	var ca: Dictionary = server.ca_info()
	var dir := str(ca.get("dir", ""))
	if dir == "":
		dir = str(server.pki_dir())
	DirAccess.make_dir_recursive_absolute(dir)
	OS.shell_show_in_file_manager(dir, true)
	_append_log("info", _t("toast.cert_dir_opened"))
	_toast(_t("toast.cert_dir_opened"))

func _on_rotate_ca() -> void:
	if server == null:
		return
	_popup_dialog(_confirm_rotate)

func _do_rotate_ca() -> void:
	if server == null:
		return
	var result: Dictionary = server.rotate_ca()
	if bool(result.get("ok", false)):
		_append_log("warn", _t("log.cert_rotated") % str(result.get("cn", "")))
		_toast(_t("toast.cert_rotated"), "warn")
	else:
		_append_log("error", _t("log.rotate_failed") % str(result.get("error", "")))
		_toast(_t("toast.rotate_failed") + str(result.get("error", "")), "error")
	_ca_trust_installed = false
	_ca_trust_detail = _t("cert.new_not_installed")
	_refresh_ca_info()

func _build_tab_cert() -> void:
	var cert := _make_tab(_t("tab.cert"))

	cert.add_child(_section(_t("cert.subtitle")))

	_ca_pro_hint = Label.new()
	_ca_pro_hint.text = _t("hint.https_pro")
	_ca_pro_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ca_pro_hint.add_theme_font_size_override("font_size", 10)
	_ca_pro_hint.add_theme_color_override("font_color", _ed_warning)
	cert.add_child(_ca_pro_hint)

	_ca_status_label = Label.new()
	_ca_status_label.add_theme_font_size_override("font_size", 12)
	cert.add_child(_ca_status_label)

	_ca_label = Label.new()
	_ca_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ca_label.add_theme_font_size_override("font_size", 11)
	_ca_label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	cert.add_child(_ca_label)

	var ca_scope := Label.new()
	ca_scope.text = _t("cert.install_hint")
	ca_scope.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ca_scope.add_theme_font_size_override("font_size", 10)
	ca_scope.add_theme_color_override("font_color", _ed_dim)
	cert.add_child(ca_scope)

	_ca_mobile_box = VBoxContainer.new()
	_ca_mobile_box.add_theme_constant_override("separation", 6)
	cert.add_child(_ca_mobile_box)

	var ca_qr_hint := Label.new()
	ca_qr_hint.text = _t("cert.scan_hint")
	ca_qr_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ca_qr_hint.add_theme_font_size_override("font_size", 10)
	ca_qr_hint.add_theme_color_override("font_color", _ed_dim)
	_ca_mobile_box.add_child(ca_qr_hint)

	var ca_qr_panel := PanelContainer.new()
	ca_qr_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ca_qr_panel.add_theme_stylebox_override("panel", _qr_card_style())
	_ca_mobile_box.add_child(ca_qr_panel)
	var ca_qr_box := CenterContainer.new()
	ca_qr_box.custom_minimum_size = Vector2(0, 150)
	ca_qr_panel.add_child(ca_qr_box)
	_ca_qr = QR_VIEW.new()
	ca_qr_box.add_child(_ca_qr)
	_ca_qr_placeholder = Label.new()
	_ca_qr_placeholder.text = _t("cert.qr_pending")
	_ca_qr_placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ca_qr_placeholder.add_theme_font_size_override("font_size", 11)
	_ca_qr_placeholder.add_theme_color_override("font_color", _ed_dim)
	ca_qr_box.add_child(_ca_qr_placeholder)

	_ca_page_label = Label.new()
	_ca_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ca_page_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_ca_page_label.add_theme_font_size_override("font_size", 10)
	_ca_page_label.add_theme_color_override("font_color", _ed_dim)
	_ca_mobile_box.add_child(_ca_page_label)

	var ca_row_a := HBoxContainer.new()
	cert.add_child(ca_row_a)
	_ca_guide_button = _button(_t("cert.open_full_page"), _on_open_ca_guide)
	_ca_guide_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ca_row_a.add_child(_ca_guide_button)
	_ca_copy_button = _button(_t("common.copy_address"), _on_copy_ca_page)
	_ca_copy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ca_row_a.add_child(_ca_copy_button)

	var ca_row_b := HBoxContainer.new()
	cert.add_child(ca_row_b)
	_ca_install_button = _button(_t("cert.install_local"), _on_install_ca)
	_ca_install_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ca_install_button.tooltip_text = _t("cert.stores")
	ca_row_b.add_child(_ca_install_button)
	_ca_trust_button = _button(_t("cert.recheck"), _on_check_trust)
	_ca_trust_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ca_row_b.add_child(_ca_trust_button)

	var ca_row_c := HBoxContainer.new()
	cert.add_child(ca_row_c)
	_ca_dir_button = _button(_t("cert.folder"), _on_open_ca_dir)
	_ca_dir_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ca_row_c.add_child(_ca_dir_button)
	_ca_rotate_button = _button(_t("cert.regenerate"), _on_rotate_ca)
	_ca_rotate_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ca_row_c.add_child(_ca_rotate_button)

	_ca_generate_button = _button(_t("cert.generate"), _on_generate_ca)
	_ca_generate_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cert.add_child(_ca_generate_button)

	_ca_prompt_check = _check(_t("cert.check_on_start"), true)
	cert.add_child(_ca_prompt_check)
	_ca_prompt_check.toggled.connect(func(_pressed): _save_settings())

	var web_hint := Label.new()
	web_hint.text = (
		_t("cert.full_hint")
	)
	web_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	web_hint.add_theme_font_size_override("font_size", 10)
	web_hint.add_theme_color_override("font_color", _ed_dim)
	cert.add_child(web_hint)

	var ca_warn := Label.new()
	ca_warn.text = _t("cert.private_key_warning")
	ca_warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ca_warn.add_theme_font_size_override("font_size", 10)
	ca_warn.add_theme_color_override("font_color", _ed_warning)
	cert.add_child(ca_warn)
