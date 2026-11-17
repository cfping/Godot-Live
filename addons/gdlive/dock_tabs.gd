@tool
extends "res://addons/gdlive/dock_onboard.gd"

## GDLive dock — layout layer: dock chrome, support tab and dialog construction.
##
## Builds the header / quick actions / footer, the 支持 tab, every dialog and the final
## tab order.
##
## Layered dock scripts (base → top):
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs → dock.gd

## Build the dock chrome, the tab contents and every dialog.
func _build_ui() -> void:
	_init_palette()
	add_theme_constant_override("separation", 6)

	# Header ---------------------------------------------------------------
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	add_child(header)

	# Logo mark: accent rounded square with a white "G".
	var logo := PanelContainer.new()
	logo.custom_minimum_size = Vector2(22, 22)
	var logo_sb := StyleBoxFlat.new()
	logo_sb.bg_color = _ed_accent
	logo_sb.set_corner_radius_all(3)
	logo.add_theme_stylebox_override("panel", logo_sb)
	var logo_g := Label.new()
	logo_g.text = "G"
	logo_g.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	logo_g.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	logo_g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	logo_g.size_flags_vertical = Control.SIZE_EXPAND_FILL
	logo_g.add_theme_color_override("font_color", Color.WHITE)
	logo_g.add_theme_font_size_override("font_size", 14)
	logo.add_child(logo_g)
	header.add_child(logo)

	var title := Label.new()
	title.text = "GDLive"
	title.add_theme_font_size_override("font_size", 17)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var version := Label.new()
	version.text = _t("header.subtitle")
	version.add_theme_color_override("font_color", _ed_dim)
	version.add_theme_font_size_override("font_size", 11)
	header.add_child(version)

	_license_badge = Button.new()
	# Non-flat so the pill stylebox renders; all states are overridden below.
	_license_badge.flat = false
	_license_badge.focus_mode = Control.FOCUS_NONE
	_license_badge.text = "FREE"
	_license_badge.add_theme_font_size_override("font_size", 10)
	_license_badge.tooltip_text = _t("header.license_badge")
	_license_badge.pressed.connect(func(): _tabs.current_tab = _tab_support)
	header.add_child(_license_badge)

	var heart := Button.new()
	heart.text = "♥"
	heart.flat = true
	heart.tooltip_text = _t("header.donate_tooltip")
	heart.custom_minimum_size = Vector2(24, 0)
	heart.pressed.connect(func(): _tabs.current_tab = _tab_support)
	header.add_child(heart)

	var mail_quick := Button.new()
	mail_quick.text = "✉"
	mail_quick.flat = true
	mail_quick.tooltip_text = _t("header.email_tooltip")
	mail_quick.custom_minimum_size = Vector2(24, 0)
	mail_quick.pressed.connect(_open_email_dialog)
	header.add_child(mail_quick)

	var help := Button.new()
	help.text = "?"
	help.flat = true
	help.tooltip_text = _t("common.quick_start")
	help.custom_minimum_size = Vector2(24, 0)
	help.pressed.connect(_show_onboarding)
	header.add_child(help)

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.add_theme_font_size_override("font_size", 12)
	add_child(_status_label)

	# Always-visible quick actions ----------------------------------------
	var quick := HBoxContainer.new()
	quick.add_theme_constant_override("separation", 6)
	add_child(quick)

	_start_button = _button(_t("common.start"), _on_toggle)
	_start_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_primary(_start_button)
	quick.add_child(_start_button)

	_export_button = _button(_t("common.export"), _on_export)
	_export_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_primary(_export_button)
	quick.add_child(_export_button)

	_open_quick_button = _button(_t("common.open"), _on_open)
	_open_quick_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quick.add_child(_open_quick_button)

	_cert_quick_button = _button(_t("common.cert_short"), func(): _tabs.current_tab = _tab_cert)
	_cert_quick_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cert_quick_button.tooltip_text = _t("cert.title")
	quick.add_child(_cert_quick_button)

	_start_button.tooltip_text = _t("summary.start_stop")
	_export_button.tooltip_text = _t("summary.export_once")
	_open_quick_button.tooltip_text = _t("summary.open_lan")

	_export_progress = ProgressBar.new()
	_export_progress.indeterminate = true
	_export_progress.show_percentage = false
	_export_progress.custom_minimum_size = Vector2(0, 3)
	_export_progress.visible = false
	var progress_bg := StyleBoxFlat.new()
	progress_bg.bg_color = Color(_ed_dark2, 0.6)
	progress_bg.set_corner_radius_all(2)
	var progress_fill := StyleBoxFlat.new()
	progress_fill.bg_color = _ed_accent
	progress_fill.set_corner_radius_all(2)
	_export_progress.add_theme_stylebox_override("background", progress_bg)
	_export_progress.add_theme_stylebox_override("fill", progress_fill)
	add_child(_export_progress)

	_state_hint = Label.new()
	_state_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_state_hint.add_theme_font_size_override("font_size", 11)
	_state_hint.add_theme_color_override("font_color", _ed_warning)
	_state_hint.visible = false
	add_child(_state_hint)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.tab_changed.connect(_on_tab_changed)
	add_child(_tabs)
	# Five tabs must fit in the narrow dock; shrink the tab bar so the last
	# one is not pushed into the < > overflow arrows.
	_tabs.get_tab_bar().add_theme_font_size_override("font_size", 12)
	# Editor-style selected tab: accent tint + accent bottom border.
	var tab_selected := StyleBoxFlat.new()
	tab_selected.bg_color = Color(_ed_accent, 0.10)
	tab_selected.border_color = _ed_accent
	tab_selected.set_border_width_all(0)
	tab_selected.border_width_bottom = 2
	tab_selected.content_margin_left = 8
	tab_selected.content_margin_right = 8
	_tabs.get_tab_bar().add_theme_stylebox_override("tab_selected", tab_selected)

	# Start the status heartbeat BEFORE building tab contents: a runtime
	# error inside any tab block must not leave the dock without periodic
	# refresh (that once froze the remote-play status on "connecting…").
	_refresh_timer = Timer.new()
	_refresh_timer.wait_time = 2.0
	_refresh_timer.autostart = true
	_refresh_timer.timeout.connect(_refresh_status)
	add_child(_refresh_timer)

	# One-second tick while a tunnel is running, so the countdown label
	# decrements smoothly instead of jumping every 2 s.
	_remote_tick_timer = Timer.new()
	_remote_tick_timer.wait_time = 1.0
	_remote_tick_timer.timeout.connect(_refresh_remote)
	add_child(_remote_tick_timer)

	_build_tab_debug()
	_build_tab_cert()
	_build_tab_logs()
	_build_tab_remote()
	_build_tab_support()

	# Tab order follows the workflow (调试 → 远程 → 日志 → 证书安装 → 支持),
	# not the build order above.
	_reorder_tabs()

	_build_dialogs()
	_build_footer()

func _build_tab_support() -> void:
	var support := _make_tab(_t("tab.support"))

	# --- 授权状态 -------------------------------------------------------
	var status_card := _card(support, _ed_dark1, Color(_ed_accent, 0.30), 3, 11)
	status_card.add_child(_section(_t("support.status_title")))
	_license_status_label = Label.new()
	_license_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_license_status_label.add_theme_font_size_override("font_size", 14)
	status_card.add_child(_license_status_label)

	_license_quota_label = Label.new()
	_license_quota_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_license_quota_label.add_theme_font_size_override("font_size", 11)
	_license_quota_label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	status_card.add_child(_license_quota_label)

	var machine_row := HBoxContainer.new()
	machine_row.add_theme_constant_override("separation", 6)
	status_card.add_child(machine_row)
	_license_machine_label = Label.new()
	_license_machine_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_license_machine_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_license_machine_label.add_theme_font_size_override("font_size", 10)
	_license_machine_label.add_theme_color_override("font_color", _ed_dim)
	if _ed_mono != null:
		_license_machine_label.add_theme_font_override("font", _ed_mono)
	machine_row.add_child(_license_machine_label)
	var copy_machine := _button(_t("common.copy_machine"), _on_copy_machine)
	copy_machine.tooltip_text = _t("support.copy_machine_tooltip")
	copy_machine.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	machine_row.add_child(copy_machine)

	var license_row := HBoxContainer.new()
	_license_row = license_row
	status_card.add_child(license_row)
	_buy_button = _button(_t("buy.title"), _on_open_pro_page)
	_buy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_gold(_buy_button)
	license_row.add_child(_buy_button)
	_remove_license_button = _button(_t("support.remove_license"), _on_remove_license)
	_remove_license_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_remove_license_button.tooltip_text = _t("support.remove_tooltip")
	license_row.add_child(_remove_license_button)

	# --- 激活授权码 -----------------------------------------------------
	# Hidden entirely once a license is active (see _refresh_license).
	_activate_card = _card(support)
	var activate_card := _activate_card
	activate_card.add_child(_section(_t("activate.title")))
	# License codes are long single-line tokens; a multi-line field makes the
	# whole code visible and lets users paste it from an email or chat without
	# horizontal scrolling. Whitespace is stripped before activation.
	_license_input = TextEdit.new()
	_license_input.placeholder_text = _t("activate.placeholder")
	_license_input.custom_minimum_size = Vector2(0, 64)
	_license_input.scroll_fit_content_height = true
	_license_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_license_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	activate_card.add_child(_license_input)
	_license_input.add_theme_font_size_override("font_size", 11)
	_license_input.add_theme_stylebox_override("normal", _card_style(_ed_dark3, _ed_dark2, 2, 10))
	var license_focus := _card_style(_ed_dark3, Color(_ed_accent, 0.60), 2, 10)
	_license_input.add_theme_stylebox_override("focus", license_focus)

	# Ctrl/Cmd+Enter activates without reaching for the button.
	_license_input.gui_input.connect(_on_license_input_gui_input)

	var license_buttons := HBoxContainer.new()
	activate_card.add_child(license_buttons)
	_license_activate_button = _button(_t("common.activate"), _on_activate_license)
	_license_activate_button.tooltip_text = _t("activate.tooltip")
	_license_activate_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_primary(_license_activate_button)
	license_buttons.add_child(_license_activate_button)
	var paste_button := _button(_t("common.paste"), func():
		var text := DisplayServer.clipboard_get().strip_edges()
		if text == "":
			_append_log("warn", _t("toast.clipboard_empty"))
			return
		_license_input.text = text
	)
	paste_button.tooltip_text = _t("activate.paste_tooltip")
	license_buttons.add_child(paste_button)

	activate_card.add_child(
		_hint(_t("activate.hint"))
	)

	# 支持服务在后台运行，面板只保留两个入口按钮，不展示地址 / 端口。
	var support_row := HBoxContainer.new()
	_support_row = support_row
	support_row.add_theme_constant_override("separation", 6)
	support.add_child(support_row)
	_support_open_button = _button(_t("support.open_page"), _on_open_support)
	_support_open_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_support_open_button.tooltip_text = _t("support.open_page_tooltip")
	_style_primary(_support_open_button)
	support_row.add_child(_support_open_button)
	_support_copy_button = _button(_t("common.copy_address"), _on_copy_support)
	_support_copy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_support_copy_button.tooltip_text = _t("support.copy_page_tooltip")
	support_row.add_child(_support_copy_button)

	# --- 联系我们 -------------------------------------------------------
	var contact_card := _card(support, _ed_dark1, Color(_ed_accent, 0.30), 3, 11)

	var contact_head := Label.new()
	contact_head.text = _t("contact.title")
	contact_head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	contact_head.add_theme_font_size_override("font_size", 11)
	contact_head.add_theme_color_override("font_color", _ed_accent)
	contact_card.add_child(contact_head)

	var site_row := HBoxContainer.new()
	site_row.add_theme_constant_override("separation", 6)
	contact_card.add_child(site_row)
	var site_label := Label.new()
	site_label.text = _t("contact.website") + WEBSITE_URL.trim_prefix("https://").trim_suffix("/")
	site_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	site_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	site_label.add_theme_font_size_override("font_size", 12)
	site_row.add_child(site_label)
	var open_site := _button(_t("common.open_website"), _open_website)
	open_site.tooltip_text = _t("contact.website_tooltip")
	site_row.add_child(open_site)

	var github_row := HBoxContainer.new()
	github_row.add_theme_constant_override("separation", 6)
	contact_card.add_child(github_row)
	var open_repo := _button(_t("contact.github"), _open_github)
	open_repo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	open_repo.tooltip_text = _t("contact.github_tooltip") % [GITHUB_REPO, GITHUB_URL]
	github_row.add_child(open_repo)
	var report_issue := _button(_t("common.report_issue"), _open_github_issues)
	report_issue.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	report_issue.tooltip_text = _t("contact.issues_tooltip") + GITHUB_ISSUES_URL
	_style_primary(report_issue)
	github_row.add_child(report_issue)

	var email_row := HBoxContainer.new()
	email_row.add_theme_constant_override("separation", 6)
	contact_card.add_child(email_row)
	_contact_email_label = Label.new()
	_contact_email_label.text = _t("contact.email") + _contact_email
	_contact_email_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_contact_email_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_contact_email_label.add_theme_font_size_override("font_size", 12)
	email_row.add_child(_contact_email_label)
	var copy_email := _button(_t("contact.copy_email"), _on_copy_contact_email)
	copy_email.tooltip_text = _t("contact.copy_email_alt")
	email_row.add_child(copy_email)
	var mail_button := _button(_t("contact.write_email"), _open_email_dialog)
	mail_button.tooltip_text = _t("contact.email_tooltip")
	_style_gold(mail_button)
	email_row.add_child(mail_button)

	var wechat_row := HBoxContainer.new()
	wechat_row.add_theme_constant_override("separation", 6)
	contact_card.add_child(wechat_row)
	_contact_wechat_label = Label.new()
	_contact_wechat_label.text = _t("contact.wechat") + _contact_wechat
	_contact_wechat_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_contact_wechat_label.add_theme_font_size_override("font_size", 12)
	wechat_row.add_child(_contact_wechat_label)
	var copy_wechat := _button(_t("contact.copy_wechat"), _on_copy_contact_wechat)
	copy_wechat.tooltip_text = _t("contact.copy_wechat_alt")
	wechat_row.add_child(copy_wechat)
	var wechat_qr_toggle := _button(_t("contact.friend_qr"), func():
		if _friend_qr.texture == null:
			_append_log("warn", _t("toast.friend_qr_loading"))
			return
		_friend_qr_panel.visible = not _friend_qr_panel.visible
	)
	wechat_qr_toggle.tooltip_text = _t("contact.friend_qr_tooltip")
	wechat_row.add_child(wechat_qr_toggle)

	_friend_qr_panel = PanelContainer.new()
	_friend_qr_panel.add_theme_stylebox_override("panel", _qr_card_style())
	_friend_qr_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_friend_qr_panel.visible = false
	contact_card.add_child(_friend_qr_panel)
	_friend_qr = TextureRect.new()
	_friend_qr.custom_minimum_size = Vector2(180, 180)
	_friend_qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_friend_qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_friend_qr_panel.add_child(_friend_qr)

	contact_card.add_child(
		_hint(
			_t("contact.hint_buy")
			+ _t("contact.hint_issues")
		)
	)

	# --- 赞赏支持 -------------------------------------------------------
	var donate_card := _card(support)
	donate_card.add_child(_section(_t("donate.title")))

	var donate_intro := Label.new()
	donate_intro.text = _t("donate.intro")
	donate_intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	donate_intro.add_theme_font_size_override("font_size", 11)
	donate_intro.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	donate_card.add_child(donate_intro)

	# One QR at a time via tabs (same pattern as the buy dialog): the dock is
	# narrow, and stacking two 250px codes makes the support tab endless.
	var donate_tabs := TabContainer.new()
	donate_tabs.custom_minimum_size = Vector2(0, 268)
	donate_card.add_child(donate_tabs)

	var donate_wx_page := CenterContainer.new()
	donate_wx_page.name = _t("donate.wechat")
	donate_tabs.add_child(donate_wx_page)
	var wechat_qr_card := PanelContainer.new()
	wechat_qr_card.add_theme_stylebox_override("panel", _qr_card_style())
	donate_wx_page.add_child(wechat_qr_card)
	_donate_qr_wechat = TextureRect.new()
	_donate_qr_wechat.custom_minimum_size = Vector2(220, 220)
	_donate_qr_wechat.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_donate_qr_wechat.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	wechat_qr_card.add_child(_donate_qr_wechat)

	var donate_ali_page := CenterContainer.new()
	donate_ali_page.name = _t("donate.alipay")
	donate_tabs.add_child(donate_ali_page)
	var alipay_qr_card := PanelContainer.new()
	alipay_qr_card.add_theme_stylebox_override("panel", _qr_card_style())
	donate_ali_page.add_child(alipay_qr_card)
	_donate_qr_alipay = TextureRect.new()
	_donate_qr_alipay.custom_minimum_size = Vector2(220, 220)
	_donate_qr_alipay.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_donate_qr_alipay.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	alipay_qr_card.add_child(_donate_qr_alipay)

	var donate_open := _button(_t("donate.open_page"), _on_open_donate)
	donate_open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	donate_card.add_child(donate_open)

func _reorder_tabs() -> void:
	# The tabs are built in whatever order is convenient; shuffle the
	# containers once so the visual order follows the workflow instead:
	# 调试（every run) → 远程（share the build) → 日志（iterate) →
	# 证书安装（one-time setup) → 支持（rare).
	var order: Array[String] = [_t("tab.debug"), _t("tab.remote"), _t("tab.logs"), _t("tab.cert"), _t("tab.support")]
	var by_title: Dictionary = {}
	for i in range(_tabs.get_tab_count()):
		by_title[_tabs.get_tab_title(i)] = _tabs.get_tab_control(i)
	var target := 0
	for tab_title in order:
		if by_title.has(tab_title):
			_tabs.move_child(by_title[tab_title], target)
			target += 1
	_tab_support = _tabs.get_tab_idx_from_control(by_title[_t("tab.support")])
	_tab_cert = _tabs.get_tab_idx_from_control(by_title[_t("tab.cert")])

func _build_dialogs() -> void:
	_confirm_rotate = ConfirmationDialog.new()
	_confirm_rotate.title = _t("rotate.title")
	_confirm_rotate.dialog_text = (
		_t("rotate.text")
		+ _t("rotate.confirm")
	)
	_confirm_rotate.confirmed.connect(_do_rotate_ca)
	add_child(_confirm_rotate)

	_confirm_remove_license = ConfirmationDialog.new()
	_confirm_remove_license.title = _t("support.remove_license")
	_confirm_remove_license.ok_button_text = _t("remove.title")
	_confirm_remove_license.cancel_button_text = _t("common.cancel")
	_confirm_remove_license.dialog_text = (
		_t("remove.text1")
		+ _t("remove.text2")
		+ _t("remove.text3")
		+ _t("remove.text4")
		+ _t("remove.text5")
	)
	_confirm_remove_license.confirmed.connect(_do_remove_license)
	add_child(_confirm_remove_license)

	_ca_prompt = AcceptDialog.new()
	_ca_prompt.title = _t("ca_prompt.title")
	_ca_prompt.ok_button_text = _t("ca_prompt.install")
	_ca_prompt.add_cancel_button(_t("ca_prompt.later"))
	_ca_prompt.add_button(_t("ca_prompt.guide"), true, "guide")
	_ca_prompt.confirmed.connect(_on_ca_prompt_install)
	_ca_prompt.custom_action.connect(_on_ca_prompt_action)
	add_child(_ca_prompt)

	_onboard = AcceptDialog.new()
	_onboard.title = _t("onboard.title")
	_onboard.ok_button_text = _t("onboard.start")
	_onboard.add_cancel_button(_t("onboard.close"))
	_onboard.add_button(_t("onboard.open_website"), true, "site")
	_onboard.add_button(_t("onboard.install_ca"), true, "cert")
	_onboard.confirmed.connect(_mark_onboarded)
	_onboard.canceled.connect(_mark_onboarded)
	_onboard.custom_action.connect(_on_onboard_action)
	add_child(_onboard)

	# --- Purchase dialog -----------------------------------------------
	# Buy flow in one place: price + machine code + payment QR codes, so the
	# user can scan and pay without leaving the editor.
	_buy_dialog = AcceptDialog.new()
	_buy_dialog.title = _t("buy.title")
	_buy_dialog.ok_button_text = _t("buy.done")
	_buy_dialog.min_size = Vector2i(360, 0)
	var buy_box := VBoxContainer.new()
	buy_box.add_theme_constant_override("separation", 8)
	buy_box.custom_minimum_size = Vector2(320, 0)
	_buy_dialog.add_child(buy_box)

	_buy_price_label = Label.new()
	_buy_price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_buy_price_label.add_theme_font_size_override("font_size", 24)
	_buy_price_label.add_theme_color_override("font_color", BRAND_GOLD)
	buy_box.add_child(_buy_price_label)

	buy_box.add_child(_section(_t("buy.step1")))
	_buy_machine_label = Label.new()
	_buy_machine_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_buy_machine_label.add_theme_font_size_override("font_size", 12)
	buy_box.add_child(_buy_machine_label)
	var buy_copy_row := HBoxContainer.new()
	buy_box.add_child(buy_copy_row)
	var buy_copy := _button(_t("common.copy_machine"), _on_copy_machine)
	buy_copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buy_copy_row.add_child(buy_copy)

	buy_box.add_child(_section(_t("buy.step2")))
	var buy_tabs := TabContainer.new()
	buy_tabs.custom_minimum_size = Vector2(0, 272)
	buy_box.add_child(buy_tabs)

	var buy_wx_page := CenterContainer.new()
	buy_wx_page.name = _t("buy.wechat_pay")
	buy_tabs.add_child(buy_wx_page)
	_buy_qr_wechat = _buy_qr(220)
	# CenterContainer sizes children to their minimum: without an explicit
	# width the TextureRect collapses to (0, 220) and the QR never renders.
	_buy_qr_wechat.custom_minimum_size = Vector2(220, 220)
	buy_wx_page.add_child(_buy_qr_wechat)

	var buy_ali_page := CenterContainer.new()
	buy_ali_page.name = _t("buy.alipay")
	buy_tabs.add_child(buy_ali_page)
	_buy_qr_alipay = _buy_qr(220)
	_buy_qr_alipay.custom_minimum_size = Vector2(220, 220)
	buy_ali_page.add_child(_buy_qr_alipay)

	_buy_step3_label = Label.new()
	_buy_step3_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_buy_step3_label.add_theme_font_size_override("font_size", 11)
	_buy_step3_label.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	buy_box.add_child(_buy_step3_label)

	var buy_contact_row := HBoxContainer.new()
	buy_contact_row.add_theme_constant_override("separation", 6)
	buy_box.add_child(buy_contact_row)
	var buy_mail := _button(_t("buy.email_us"), _open_email_dialog)
	buy_mail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buy_mail.tooltip_text = _t("buy.email_tooltip")
	_style_gold(buy_mail)
	buy_contact_row.add_child(buy_mail)
	var buy_copy_wechat := _button(_t("contact.copy_wechat"), _on_copy_contact_wechat)
	buy_copy_wechat.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buy_contact_row.add_child(buy_copy_wechat)

	var buy_browser := _button(_t("buy.open_page"), _on_open_pro_browser)
	buy_browser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buy_box.add_child(buy_browser)
	add_child(_buy_dialog)

	# --- Contact / email dialog ----------------------------------------
	# Pre-filled template so users never have to assemble the machine code,
	# version and payment details by hand.
	_email_dialog = AcceptDialog.new()
	_email_dialog.title = _t("email.title")
	_email_dialog.ok_button_text = _t("email.open_app")
	_email_dialog.add_cancel_button(_t("onboard.close"))
	_email_dialog.add_button(_t("email.copy_content"), true, "copy")
	_email_dialog.dialog_hide_on_ok = false
	_email_dialog.min_size = Vector2i(460, 0)
	_email_dialog.confirmed.connect(_send_email)
	_email_dialog.custom_action.connect(_on_email_dialog_action)
	_email_dialog.visibility_changed.connect(_on_email_dialog_visibility_changed)
	add_child(_email_dialog)

	var mail_box := VBoxContainer.new()
	mail_box.custom_minimum_size = Vector2(420, 0)
	mail_box.add_theme_constant_override("separation", 8)
	_email_dialog.add_child(mail_box)

	var mail_intro := Label.new()
	mail_intro.text = _t("email.intro")
	mail_intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mail_intro.add_theme_font_size_override("font_size", 11)
	mail_intro.add_theme_color_override("font_color", Color(0.62, 0.66, 0.72))
	mail_box.add_child(mail_intro)

	mail_box.add_child(_section(_t("email.to")))
	var to_row := HBoxContainer.new()
	mail_box.add_child(to_row)
	_email_to_input = LineEdit.new()
	_email_to_input.editable = false
	_email_to_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	to_row.add_child(_email_to_input)
	var copy_to := _button(_t("contact.copy_email"), _on_copy_email_recipient)
	copy_to.tooltip_text = _t("email.copy_to")
	to_row.add_child(copy_to)

	mail_box.add_child(_section(_t("email.subject")))
	_email_subject_input = LineEdit.new()
	_email_subject_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mail_box.add_child(_email_subject_input)

	mail_box.add_child(_section(_t("email.body")))
	_email_body_edit = TextEdit.new()
	_email_body_edit.custom_minimum_size = Vector2(0, 190)
	_email_body_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_email_body_edit.add_theme_font_size_override("font_size", 12)
	mail_box.add_child(_email_body_edit)

	_email_status_label = Label.new()
	_email_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_email_status_label.add_theme_font_size_override("font_size", 10)
	_email_status_label.add_theme_color_override("font_color", BRAND_GREEN)
	mail_box.add_child(_email_status_label)

	var mail_hint := Label.new()
	mail_hint.text = _t("email.hint")
	mail_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mail_hint.add_theme_font_size_override("font_size", 10)
	mail_hint.add_theme_color_override("font_color", _ed_dim)
	mail_box.add_child(mail_hint)

func _build_footer() -> void:
	var footer_row := HBoxContainer.new()
	footer_row.add_theme_constant_override("separation", 6)
	add_child(footer_row)

	var footer := Label.new()
	footer.text = _t("qr.game_title")
	footer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	footer.tooltip_text = _t("qr.game_hint")
	footer.add_theme_color_override("font_color", _ed_dim)
	footer.add_theme_font_size_override("font_size", 10)
	footer_row.add_child(footer)

	var footer_site := _button(_t("qr.website"), _open_website)
	footer_site.flat = true
	footer_site.tooltip_text = _t("qr.website_tooltip") + WEBSITE_URL
	footer_site.add_theme_font_size_override("font_size", 10)
	footer_row.add_child(footer_site)

	var footer_issues := _button(_t("common.report_issue"), _open_github_issues)
	footer_issues.flat = true
	footer_issues.tooltip_text = _t("qr.issues_tooltip") + GITHUB_ISSUES_URL
	footer_issues.add_theme_font_size_override("font_size", 10)
	footer_row.add_child(footer_issues)

	var footer_contact := _button(_t("qr.contact"), _open_email_dialog)
	footer_contact.flat = true
	footer_contact.tooltip_text = _t("qr.contact_tooltip")
	footer_contact.add_theme_font_size_override("font_size", 10)
	footer_row.add_child(footer_contact)
