@tool
extends "res://addons/gdlive/dock_remote.gd"

## GDLive dock — support layer: contact info, donate QR codes, email + purchase dialogs.
##
## Builds the mail template, decodes the embedded donate/friend QR images and opens
## the support pages.
##
## Layered dock scripts (base → top):
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs → dock.gd

# The embedded payment images are 600x900 posters (branding around the code).
# Crop the white QR card before displaying so the code itself stays large and
# crisp in the narrow editor dock. Values are fractions of the source image.
const DONATE_QR_CROPS := {
	"alipay": Rect2(0.220, 0.260, 0.555, 0.425),
	"wechat": Rect2(0.195, 0.190, 0.605, 0.477),
}

func _contact_info() -> Dictionary:
	var st: Dictionary = {}
	if server != null:
		st = server.license_status()
	var email := str(st.get("email", "")).strip_edges()
	if email == "":
		email = FALLBACK_EMAIL
	var wechat := str(st.get("wechat", "")).strip_edges()
	if wechat == "":
		wechat = FALLBACK_WECHAT
	return {
		"email": email,
		"wechat": wechat,
		"machine": str(st.get("machine_id", "")),
		"tier": str(st.get("tier", "free")),
		"days_left": int(st.get("days_left", 0)),
		"version": str(st.get("version", "")),
	}

func _license_summary(info: Dictionary) -> String:
	match str(info.get("tier", "free")):
		"pro":
			return _t("support.pro_licensed")
		"studio":
			return _t("support.studio_licensed")
		"trial":
			return _t("support.trial_days") % int(info.get("days_left", 0))
		_:
			return _t("support.free")

func _mail_template() -> Dictionary:
	var info := _contact_info()
	var machine := str(info.get("machine", ""))
	var short := machine.substr(0, 12) if machine.length() > 12 else machine
	var subject := _t("email.subject_line")
	if short != "":
		subject += " - " + short
	var version := str(info.get("version", ""))
	if version == "":
		version = _t("common.unknown")
	var body := (
		_t("email.body_hello")
		+ _t("email.body_intro")
		+ _t("email.body_machine") % machine
		+ _t("email.body_version") % version
		+ _t("email.body_license") % _license_summary(info)
		+ _t("email.body_payment")
		+ _t("email.body_proof")
		+ _t("email.body_notes")
		+ _t("email.body_footer")
	)
	return {
		"to": info.get("email", ""),
		"subject": subject,
		"body": body,
	}

func _open_email_dialog() -> void:
	# Remember when this was opened from the buy dialog so it can be restored
	# after the email dialog closes (both are exclusive dock windows).
	_email_over_buy = _buy_dialog != null and _buy_dialog.visible
	var mail := _mail_template()
	if _email_to_input != null:
		_email_to_input.text = str(mail.get("to", ""))
	if _email_subject_input != null:
		_email_subject_input.text = str(mail.get("subject", ""))
	if _email_body_edit != null:
		_email_body_edit.text = str(mail.get("body", ""))
	if _email_status_label != null:
		_email_status_label.text = ""
	if _email_dialog != null:
		_popup_dialog(_email_dialog, Vector2i(560, 560))

func _send_email() -> void:
	if _email_to_input == null or _email_subject_input == null or _email_body_edit == null:
		return
	var to := _email_to_input.text.strip_edges()
	if to == "":
		_set_email_status(_t("toast.email_no_recipient"), false)
		return
	var url := "mailto:%s?subject=%s&body=%s" % [
		to,
		_email_subject_input.text.uri_encode(),
		_email_body_edit.text.uri_encode(),
	]
	var err := OS.shell_open(url)
	if err == OK:
		_append_log("info", _t("toast.email_app_opened") % to)
		if _email_dialog != null:
			_email_dialog.hide()
	else:
		DisplayServer.clipboard_set(_email_compose_text())
		_set_email_status(_t("toast.email_app_missing"), false)
		_append_log("warn", _t("toast.email_app_missing_alt"))

func _email_compose_text() -> String:
	var to := _email_to_input.text if _email_to_input != null else ""
	var subject := _email_subject_input.text if _email_subject_input != null else ""
	var body := _email_body_edit.text if _email_body_edit != null else ""
	return _t("email.compose_text") % [to, subject, body]

func _set_email_status(message: String, ok: bool) -> void:
	if _email_status_label == null:
		return
	_email_status_label.text = message
	_email_status_label.add_theme_color_override(
		"font_color", BRAND_GREEN if ok else BRAND_GOLD
	)

func _on_email_dialog_visibility_changed() -> void:
	# Restore the buy dialog once the email dialog opened on top of it closes.
	# Deferred: exclusivity from the closing dialog is released on the next
	# frame, popping immediately would hit "already has another exclusive
	# child".
	if _email_over_buy and _email_dialog != null and not _email_dialog.visible:
		_email_over_buy = false
		if _buy_dialog != null:
			_popup_dialog.call_deferred(_buy_dialog)

func _on_email_dialog_action(action: StringName) -> void:
	if action == &"copy":
		DisplayServer.clipboard_set(_email_compose_text())
		_set_email_status(_t("toast.email_copied_paste"), true)
		_append_log("info", _t("toast.email_copied"))

func _on_copy_email_recipient() -> void:
	DisplayServer.clipboard_set(_email_to_input.text if _email_to_input != null else _contact_email)
	_append_log("info", _t("toast.contact_email_copied_detail") % _contact_email)
	_toast(_t("toast.contact_email_copied"))

func _on_copy_contact_email() -> void:
	DisplayServer.clipboard_set(_contact_email)
	_append_log("info", _t("toast.contact_email_copied_detail") % _contact_email)
	_toast(_t("toast.contact_email_copied"))

func _on_copy_contact_wechat() -> void:
	DisplayServer.clipboard_set(_contact_wechat)
	_append_log("info", _t("toast.wechat_copied_detail") % _contact_wechat)
	_toast(_t("toast.wechat_copied"))

func _open_website() -> void:
	OS.shell_open(WEBSITE_URL)
	_append_log("info", _t("toast.website_opened") + WEBSITE_URL)

func _open_github() -> void:
	OS.shell_open(GITHUB_URL)
	_append_log("info", _t("toast.github_opened") + GITHUB_URL)

func _open_github_issues() -> void:
	OS.shell_open(GITHUB_ISSUES_URL)
	_append_log("info", _t("toast.issues_opened") + GITHUB_ISSUES_URL)

func _load_donate_images() -> void:
	if _donate_loaded or server == null:
		return
	_donate_loaded = true
	if not server.has_method("donate_image_base64"):
		return
	_set_donate_texture(_donate_qr_wechat, "wechat")
	_set_donate_texture(_donate_qr_alipay, "alipay")
	_set_donate_texture(_buy_qr_wechat, "wechat")
	_set_donate_texture(_buy_qr_alipay, "alipay")
	if server.has_method("wechat_qr_base64"):
		var encoded: String = server.wechat_qr_base64()
		if encoded != "":
			var bytes := Marshalls.base64_to_raw(encoded)
			var image := Image.new()
			if image.load_jpg_from_buffer(bytes) == OK:
				_friend_qr.texture = ImageTexture.create_from_image(image)

func _buy_qr(min_height: int) -> TextureRect:
	var rect := TextureRect.new()
	rect.custom_minimum_size = Vector2(0, min_height)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	return rect

func _set_donate_texture(rect: TextureRect, kind: String) -> void:
	if rect == null:
		return
	var encoded: String = server.donate_image_base64(kind)
	if encoded == "":
		return
	var bytes := Marshalls.base64_to_raw(encoded)
	var image := Image.new()
	if image.load_jpg_from_buffer(bytes) != OK:
		_append_log("warn", _t("log.donate_qr_failed") + kind)
		return
	# Crop the branded poster down to its white QR card so the code can be
	# rendered large enough to scan inside the narrow dock.
	if DONATE_QR_CROPS.has(kind):
		var crop: Rect2 = DONATE_QR_CROPS[kind]
		var size := Vector2(image.get_width(), image.get_height())
		var region := Rect2i(
			int(crop.position.x * size.x),
			int(crop.position.y * size.y),
			int(crop.size.x * size.x),
			int(crop.size.y * size.y)
		)
		var bounds := Rect2i(Vector2i.ZERO, image.get_size())
		region = region.intersection(bounds)
		if region.size.x > 0 and region.size.y > 0:
			image = image.get_region(region)
	rect.texture = ImageTexture.create_from_image(image)

func _on_open_donate() -> void:
	var base := _support_base
	if base == "":
		base = _selected_url()
	if base == "":
		_append_log("warn", _t("toast.donate_offline"))
		return
	OS.shell_open(base + "/__gdlive/donate")
	_toast(_t("toast.donate_opened"))
