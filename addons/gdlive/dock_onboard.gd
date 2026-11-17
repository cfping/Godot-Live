@tool
extends "res://addons/gdlive/dock_server.gd"

## GDLive dock — onboarding layer: the first-run quick start dialog.
##
## Shows the quick-start text once per install and offers the one-click HTTPS setup.
##
## Layered dock scripts (base → top):
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs → dock.gd

## First-run quick start; shown once per install version.
func maybe_show_onboarding() -> void:
	if _onboarded or server == null:
		return
	_show_onboarding()

func _show_onboarding() -> void:
	print(_t("log.onboard_shown"))
	_onboard.dialog_text = (
		_t("onboard.text1")
		+ _t("onboard.bullet1")
		+ _t("onboard.bullet2")
		+ _t("onboard.bullet3")
		+ _t("onboard.steps_title")
		+ _t("onboard.step1")
		+ _t("onboard.step2")
		+ _t("onboard.step3")
		+ _t("onboard.website")
		+ _t("onboard.feedback")
		+ _t("onboard.reopen_hint")
	) % [int(_port.value), WEBSITE_URL, GITHUB_ISSUES_URL]
	_popup_dialog(_onboard, Vector2i(620, 320))

func _on_onboard_action(action: StringName) -> void:
	if action == &"site":
		_open_website()
		return
	if action == &"cert":
		_onboard.hide()
		_mark_onboarded()
		_on_onboard_install()

func _mark_onboarded() -> void:
	_onboarded = true
	_save_settings()

func _on_onboard_install() -> void:
	if server == null:
		return
	if not bool(server.license_status().get("pro", false)):
		_tabs.current_tab = _tab_support
		_append_log("warn", _t("toast.https_needs_pro"))
		return

	_tls.button_pressed = true
	_apply_config()

	var ca: Dictionary = server.ca_info()
	if not bool(ca.get("exists", false)):
		server.ensure_ca()

	_start_server()
	_tabs.current_tab = _tab_cert
	_check_ca_trust()

	if _ca_trust_installed:
		_append_log("success", _t("log.https_ready"))
	else:
		_on_install_ca()
		_append_log(
			"info",
			_t("log.cert_qr_ready")
		)
