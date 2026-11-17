@tool
extends VBoxContainer

## GDLive dock: lives in the right-hand editor panel.
##
## All real work happens in the Rust extension. This script is a thin UI that
## configures the server, displays LAN URLs/QR codes, and streams logs.

const CFG_PATH := "user://gdlive.cfg"
const LEGACY_CFG_PATH := "user://gtlive.cfg"
const ONBOARD_VERSION := 1
const QR_VIEW := preload("res://addons/gdlive/qr_view.gd")
const LEGACY_DEFAULT_PORT := 8060
# Fallbacks used until the server reports its license status (or when the
# extension is missing). Keep in sync with `license::PRO_*` in Rust.
const FALLBACK_EMAIL := "chping@iowk.com"
const FALLBACK_WECHAT := "thingbox"
const WEBSITE_URL := "https://gdlive.iowk.com/"
const GITHUB_REPO := "cfping/Godot-Live"
const GITHUB_URL := "https://github.com/cfping/Godot-Live"
const GITHUB_ISSUES_URL := "https://github.com/cfping/Godot-Live/issues/new"

const LEVEL_COLORS := {
	"error": "#ef6161",
	"warn": "#e5a83c",
	"info": "#8fb8d9",
	"debug": "#6e7681",
	"export": "#5fb2e8",
	"browser": "#a685f5",
	"net": "#79b8ff",
	"success": "#37d0a0",
}

# Brand palette — keep in sync with the GDLive website (website/assets/style.css).
const BRAND_BLUE := Color(0.278, 0.549, 0.749) # #478cbf
const BRAND_BLUE_BRIGHT := Color(0.373, 0.698, 0.910) # #5fb2e8
const BRAND_BLUE_DARK := Color(0.216, 0.427, 0.604)
const BRAND_GREEN := Color(0.216, 0.816, 0.627) # #37d0a0
const BRAND_GOLD := Color(0.941, 0.714, 0.298) # #f0b64c
const BRAND_VIOLET := Color(0.718, 0.616, 0.961) # #b79df5

# The embedded payment images are 600x900 posters (branding around the code).
# Crop the white QR card before displaying so the code itself stays large and
# crisp in the narrow editor dock. Values are fractions of the source image.
const DONATE_QR_CROPS := {
	"alipay": Rect2(0.220, 0.260, 0.555, 0.425),
	"wechat": Rect2(0.195, 0.190, 0.605, 0.477),
}

# Editor-derived palette: sampled from the live editor theme by
# `_init_palette()` so the panel follows the host editor (dark, light or a
# custom theme) instead of imposing its own colors. The initial values are
# Godot's default dark theme and act as fallbacks outside the editor.
var _ed_accent := Color(0.278, 0.549, 0.749) # accent_color
var _ed_base := Color(0.106, 0.106, 0.106) # base_color
var _ed_dark1 := Color(0.145, 0.157, 0.169) # dark_color_1 (cards)
var _ed_dark2 := Color(0.165, 0.180, 0.196) # dark_color_2 (borders)
var _ed_dark3 := Color(0.180, 0.196, 0.212) # dark_color_3 (buttons/inputs)
var _ed_text := Color(0.88, 0.88, 0.88) # font_color
var _ed_dim := Color(0.50, 0.50, 0.50) # font_disabled_color
var _ed_positive := Color(0.45, 0.82, 0.55) # positive_color
var _ed_warning := Color(0.90, 0.72, 0.25) # warning_color
var _ed_error := Color(1.0, 0.37, 0.37) # error_color
var _ed_mono: Font # "source" editor font


func _init_palette() -> void:
	if not Engine.is_editor_hint():
		return
	var e := EditorInterface.get_base_control()
	if e == null:
		return
	var color_map := {
		"accent_color": "_ed_accent",
		"base_color": "_ed_base",
		"dark_color_1": "_ed_dark1",
		"dark_color_2": "_ed_dark2",
		"dark_color_3": "_ed_dark3",
		"font_color": "_ed_text",
		"font_disabled_color": "_ed_dim",
		"positive_color": "_ed_positive",
		"warning_color": "_ed_warning",
		"error_color": "_ed_error",
	}
	for color_name in color_map:
		if e.has_theme_color(color_name, "Editor"):
			set(color_map[color_name], e.get_theme_color(color_name, "Editor"))
	_ed_mono = e.get_theme_font("source", "EditorFonts")

var plugin
var server

var _project_dir := ""
var _out_dir := ""
var _godot_bin := ""
var _preset := ""

var _status_label: Label
var _port: SpinBox
var _host: OptionButton
var _auto_export: CheckBox
var _auto_reload: CheckBox
var _watch: CheckBox
var _tls: CheckBox
var _auto_start: CheckBox
var _debug_overlay: CheckBox
var _start_button: Button
var _export_button: Button
var _url_list: ItemList
var _show_v6: CheckBox
var _qr
var _preset_label: Label
var _preset_button: Button
var _log_view: RichTextLabel
var _log_toolbar: HBoxContainer
var _open_button: Button
var _copy_button: Button
var _debug_page_button: Button
var _qr_url_label: Label
var _refresh_timer: Timer
var _tabs: TabContainer
var _tab_support := 3
var _tab_cert := 1
var _ca_qr
var _ca_qr_placeholder: Label
var _ca_mobile_box: VBoxContainer
var _ca_page_label: Label
var _ca_page_url := ""
var _ca_qr_cache_url := ""
var _ca_auto_attempted := false
var _ca_exists := false
var _ca_copy_button: Button
var _ca_status_label: Label
var _ca_label: Label
var _ca_generate_button: Button
var _ca_install_button: Button
var _ca_guide_button: Button
var _ca_dir_button: Button
var _ca_rotate_button: Button
var _ca_trust_button: Button
var _ca_prompt_check: CheckBox
var _ca_prompt: AcceptDialog
var _onboard: AcceptDialog
var _onboarded := false
var _open_quick_button: Button
var _cert_quick_button: Button
var _settings_box: VBoxContainer
var _settings_toggle: Button
var _settings_summary: Label
# UI language selector: auto (follow OS locale) / Chinese / English.
var _language_option: OptionButton
var _state_hint: Label
var _export_progress: ProgressBar
var _export_started_ms := 0
var _log_entries: Array = []
var _log_filter := 0
var _log_autoscroll := true
var _log_filter_option: OptionButton
var _log_autoscroll_check: CheckBox
var _cmd_input: LineEdit
var _cmd_history: Array[String] = []
var _cmd_history_index := -1
var _donate_qr_wechat: TextureRect
var _donate_qr_alipay: TextureRect
var _donate_loaded := false
var _buy_dialog: AcceptDialog
var _buy_price_label: Label
var _buy_machine_label: Label
var _buy_step3_label: Label
var _buy_qr_wechat: TextureRect
var _buy_qr_alipay: TextureRect
var _license_status_label: Label
var _license_quota_label: Label
var _license_machine_label: Label
var _license_input: TextEdit
var _contact_email_label: Label
var _contact_wechat_label: Label
var _contact_email := FALLBACK_EMAIL
var _contact_wechat := FALLBACK_WECHAT
var _friend_qr: TextureRect
var _friend_qr_panel: PanelContainer
var _email_dialog: AcceptDialog
# True when the email dialog was opened on top of the buy dialog; the buy
# dialog is hidden while the email one is up (exclusive windows) and popped
# again when the email dialog closes.
var _email_over_buy := false
var _email_to_input: LineEdit
var _email_subject_input: LineEdit
var _email_body_edit: TextEdit
var _email_status_label: Label
var _license_badge: Button
var _license_activate_button: Button
var _buy_button: Button
var _remove_license_button: Button
# License / support-server button rows. Both stay hidden for a permanently
# licensed (private) build: nothing to renew, remove or purchase.
var _license_row: HBoxContainer
var _support_row: HBoxContainer
var _activate_card: VBoxContainer
var _ca_pro_hint: Label
var _log_pro_hint: Label
var _license_pro := false
var _license_tier := "free"
var _license_last_check_ms := 0
var _support_base := ""
var _support_open_button: Button
var _support_copy_button: Button

var _remote_status_label: Label
var _remote_qr
var _remote_password_input: LineEdit
var _remote_custom_input: LineEdit
var _remote_ttl: OptionButton
var _remote_start_button: Button
var _remote_stop_button: Button
var _remote_copy_button: Button
var _remote_open_button: Button
var _remote_last_url := ""
# Floating toast overlay (child of the editor root viewport, so it shows
# above every dock tab); auto-fades after a few seconds.
var _toast_panel: PanelContainer
var _toast_label: Label
var _toast_tween: Tween
var _remote_copy_token := 0
var _remote_tick_timer: Timer
var _remote_session_id := ""
var _remote_toasts_fired: Dictionary = {}

# Remaining-time thresholds (seconds) that trigger one toast reminder each.
const REMOTE_REMIND_SECONDS: Array[int] = [600, 300, 60, 10]

var _confirm_rotate: ConfirmationDialog
var _confirm_remove_license: ConfirmationDialog
var _install_urls: PackedStringArray = PackedStringArray()
var _ca_trust_installed := false
var _ca_trust_detail := ""

var _last_urls: PackedStringArray = PackedStringArray()
var _qr_cache := {}


func setup(editor_plugin, live_server) -> void:
	plugin = editor_plugin
	server = live_server


# true = Chinese UI, false = English UI (see `_t`).
var _zh := false


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


# ---------------------------------------------------------------------------
# boot
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# toast — visible feedback for actions whose log lines land on another tab
# ---------------------------------------------------------------------------

func _toast(text: String, level := "info") -> void:
	_ensure_toast()
	_toast_label.text = text
	var color: String = LEVEL_COLORS.get(level, LEVEL_COLORS["info"])
	_toast_label.add_theme_color_override("font_color", Color(color))
	_toast_panel.visible = true
	_toast_panel.modulate = Color(1, 1, 1, 1)
	if _toast_tween != null:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(2.4)
	_toast_tween.tween_property(_toast_panel, "modulate:a", 0.0, 0.4)
	_toast_tween.tween_callback(_hide_toast)


func _hide_toast() -> void:
	if is_instance_valid(_toast_panel):
		_toast_panel.hide()


func _ensure_toast() -> void:
	if is_instance_valid(_toast_panel):
		return
	_toast_panel = PanelContainer.new()
	_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.086, 0.106, 0.134, 0.96)
	style.border_color = Color(0.22, 0.26, 0.32)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	_toast_panel.add_theme_stylebox_override("panel", style)
	_toast_label = Label.new()
	_toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_label.add_theme_font_size_override("font_size", 13)
	_toast_panel.add_child(_toast_label)
	# Anchor bottom-center of the editor window, slightly above the status bar.
	_toast_panel.set_anchor(SIDE_LEFT, 0.5, false)
	_toast_panel.set_anchor(SIDE_RIGHT, 0.5, false)
	_toast_panel.set_anchor(SIDE_TOP, 1.0, false)
	_toast_panel.set_anchor(SIDE_BOTTOM, 1.0, false)
	_toast_panel.offset_left = -220
	_toast_panel.offset_right = 220
	_toast_panel.offset_top = -64
	_toast_panel.offset_bottom = -28
	_toast_panel.visible = false
	get_tree().root.add_child(_toast_panel)


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

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

	# ===================== tab: 调试 ======================================
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

	# ===================== tab: 证书安装 ==================================
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

	# ===================== tab: 日志 ======================================
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

	# ===================== tab: 远程 ======================================
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

	# ===================== tab: 支持 / 授权 ===============================
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

	# ===================== tab order =====================================
	# Blocks above are kept in their historical build order; shuffle the
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

	# ===================== dialogs / footer ==============================
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

	# ===================== purchase dialog ================================
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

	# ===================== contact / email dialog ========================
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


func _make_tab(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = "tab_%d" % _tabs.get_tab_count()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	_tabs.set_tab_title(_tabs.get_tab_count() - 1, title)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	scroll.add_child(box)
	return box


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


func _label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	return label


## Bordered card with a themed inner VBox (spacing tuned for dense docks).
## The returned VBox is already attached under a new PanelContainer in
## `parent`, so callers only add their content to the returned box.
func _card(
	parent: Control,
	fill: Variant = null,
	border: Variant = null,
	radius := 3,
	margins := 10
) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _card_style(fill, border, radius, margins))
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	panel.add_child(box)
	return box


## Small dim explanatory line used under controls.
func _hint(text: String, font_size := 10) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", _ed_dim)
	return label


## Flat editor-style panel: opaque `dark_color_1` fill + `dark_color_2`
## hairline border with 2 px corners — the same look Godot uses for its own
## docks and panels. Pass explicit colors to override; `null` (default)
## picks the editor palette, so the panel follows dark / light / custom
## editor themes.
func _card_style(fill: Variant = null, border: Variant = null, radius := 2, margins := 8) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill if fill is Color else _ed_dark1
	sb.border_color = border if border is Color else _ed_dark2
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = margins
	sb.content_margin_right = margins
	sb.content_margin_top = maxi(margins - 2, 0)
	sb.content_margin_bottom = maxi(margins - 2, 0)
	return sb


## Selected-row highlight used by the URL list (editor accent, low alpha).
func _selected_row_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(_ed_accent, 0.18)
	sb.set_corner_radius_all(2)
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	return sb


## White card used behind QR codes (kept white: QR codes need contrast).
func _qr_card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.WHITE
	sb.border_color = _ed_dark2
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb


## Flat editor button: `dark_color_3` fill with subtle hover / pressed
## states — matches the buttons in Godot's own docks.
func _style_editor_button(button: Button) -> void:
	button.add_theme_stylebox_override("normal", _card_style(_ed_dark3, _ed_dark2, 3, 8))
	button.add_theme_stylebox_override("hover", _card_style(_ed_dark3.lightened(0.08), _ed_dark2.lightened(0.12), 3, 8))
	button.add_theme_stylebox_override("pressed", _card_style(_ed_dark3.darkened(0.10), _ed_dark2, 3, 8))
	button.add_theme_stylebox_override("disabled", _card_style(Color(_ed_dark3, 0.55), Color(_ed_dark2, 0.55), 3, 8))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", _ed_text)
	button.add_theme_color_override("font_hover_color", _ed_text)
	button.add_theme_color_override("font_pressed_color", _ed_text)
	button.add_theme_color_override("font_disabled_color", _ed_dim)


## Primary action button: same flat editor-gray base as every other button,
## distinguished by an accent-colored label and an accent-tinted hover
## border — accent is used as an accent, not a fill.
func _style_primary(button: Button) -> void:
	_style_editor_button(button)
	button.add_theme_stylebox_override("hover", _card_style(_ed_dark3.lightened(0.08), Color(_ed_accent, 0.55), 3, 8))
	button.add_theme_color_override("font_color", _ed_accent)
	button.add_theme_color_override("font_hover_color", _ed_accent.lightened(0.12))
	button.add_theme_color_override("font_pressed_color", _ed_accent.darkened(0.10))


## Pill badge for the license tier (the website's `.price-tag` / tier badge).
func _style_badge(badge: Button, tint: Color) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(tint.r, tint.g, tint.b, 0.13)
	sb.border_color = Color(tint.r, tint.g, tint.b, 0.50)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 9
	sb.content_margin_right = 9
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	badge.add_theme_stylebox_override("normal", sb)
	badge.add_theme_stylebox_override("hover", sb)
	badge.add_theme_stylebox_override("pressed", sb)
	badge.add_theme_stylebox_override("focus", StyleBoxEmpty.new())


## Gold CTA button (the website's `.btn-gold`).
func _style_gold(button: Button) -> void:
	var normal := _card_style(BRAND_GOLD, BRAND_GOLD.lightened(0.05), 3, 8)
	var hover := _card_style(BRAND_GOLD.lightened(0.05), BRAND_GOLD.lightened(0.10), 3, 8)
	var pressed := _card_style(BRAND_GOLD.darkened(0.10), BRAND_GOLD.darkened(0.05), 3, 8)
	var disabled := _card_style(Color(BRAND_GOLD, 0.35), Color(BRAND_GOLD, 0.20), 3, 8)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", pressed)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_color_override("font_color", Color(0.10, 0.08, 0.03))
	button.add_theme_color_override("font_hover_color", Color(0.10, 0.08, 0.03))
	button.add_theme_color_override("font_pressed_color", Color(0.10, 0.08, 0.03))
	button.add_theme_color_override("font_disabled_color", Color(0.10, 0.08, 0.03, 0.55))


func _check(text: String, pressed: bool) -> CheckBox:
	var box := CheckBox.new()
	box.text = text
	box.button_pressed = pressed
	return box


func _button(text: String, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(handler)
	_style_editor_button(button)
	return button


## Section header styled like an inspector category: small dim capital
## letters over a hairline separator.
func _section(text: String) -> Label:
	var label := Label.new()
	label.text = text.to_upper()
	label.add_theme_color_override("font_color", _ed_dim)
	label.add_theme_font_size_override("font_size", 10)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = _ed_dark2
	sb.border_width_bottom = 1
	sb.content_margin_bottom = 3
	label.add_theme_stylebox_override("normal", sb)
	return label


## Pop a dock dialog as the ONLY visible exclusive child of the editor window.
## AcceptDialogs default to exclusive; opening a second one while another is
## showing makes Godot refuse (window.cpp "already has another exclusive
## child") and the new dialog renders at a stale size with dead space. Hide
## the sibling dialogs first so only one is ever visible.
## Translate a UI string. Chinese source text doubles as the lookup key;
## unknown keys fall back to the Chinese text so a missing translation
## degrades gracefully instead of hiding the label.
func _t(key: String) -> String:
	var entry: Dictionary = I18N.get(key, {})
	return entry.get("zh" if _zh else "en", key)


func _popup_dialog(dialog: Window, minsize := Vector2i(0, 0)) -> void:
	for other in [_confirm_rotate, _confirm_remove_license, _ca_prompt, _onboard, _buy_dialog, _email_dialog]:
		if other != null and other != dialog:
			other.hide()
	if minsize == Vector2i(0, 0):
		dialog.popup_centered()
	else:
		dialog.popup_centered(minsize)


# ---------------------------------------------------------------------------
# server wiring
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# status / URLs
# ---------------------------------------------------------------------------

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


func _selected_url() -> String:
	var selected := _url_list.get_selected_items()
	if selected.is_empty():
		return ""
	var index: int = selected[0]
	if index < 0 or index >= _url_list.item_count:
		return ""
	return _last_urls[index]


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


# ---------------------------------------------------------------------------
# preset detection / creation
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# onboarding / help
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# license / pro
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# remote play
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# root CA helpers
# ---------------------------------------------------------------------------

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


func _on_open_export_dir() -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	OS.shell_show_in_file_manager(_out_dir, true)
	_append_log("info", _t("toast.export_dir_opened"))
	_toast(_t("toast.export_dir_opened"))


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
	_refresh_status()


# ---------------------------------------------------------------------------
# signals from Rust
# ---------------------------------------------------------------------------

func _on_log(level: String, text: String) -> void:
	_append_log(level, text)


func _on_browser_log(level: String, text: String, url: String) -> void:
	var source := url.get_slice("://", 1).get_slice("/", 0)
	_append_log(level, text, source)


func _on_clients_changed(_count: int) -> void:
	_refresh_status()


func _on_files_changed(count: int, sample: PackedStringArray) -> void:
	var preview := ", ".join(sample)
	_append_log("debug", _t("log.files_changed") % [count, preview])


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


# ---------------------------------------------------------------------------
# log rendering
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# settings
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# English UI strings (source keys are the Chinese source text). See `_t`.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# UI strings: semantic key -> {zh, en}. See `_t`; `_zh` picks the language.
# ---------------------------------------------------------------------------

const I18N: Dictionary = {
	"activate.hint": {"zh": "授权码与机器码绑定；换机请联系我们重新签发。激活后重启 GDLive 服务器生效。", "en": "The license code is bound to the machine code; contact us to reissue it when transferring machines. Restart the GDLive server after activation to apply."},
	"activate.paste_tooltip": {"zh": "从剪贴板粘贴授权码", "en": "Paste the license code from clipboard"},
	"activate.placeholder": {"zh": "粘贴授权码 GTL1....（可整段粘贴，自动忽略空格和换行）", "en": "Paste the license code GTL1.... (paste the whole block; spaces and newlines are ignored)"},
	"activate.title": {"zh": "激活授权码", "en": "Activate License Code"},
	"activate.tooltip": {"zh": "激活授权（Ctrl/Cmd+Enter）", "en": "Activate (Ctrl/Cmd+Enter)"},
	"buy.alipay": {"zh": "支付宝", "en": "Alipay"},
	"buy.done": {"zh": "完成，去激活", "en": "Done, Activate"},
	"buy.email_tooltip": {"zh": "自动生成含机器码的邮件", "en": "Auto-generate an email with the machine code"},
	"buy.email_us": {"zh": "✉ 邮件联系我们", "en": "✉ Email Us"},
	"buy.open_page": {"zh": "在浏览器打开购买页", "en": "Open Purchase Page in Browser"},
	"buy.step1": {"zh": "① 复制机器码（付款时备注）", "en": "① Copy the machine code (note it when paying)"},
	"buy.step2": {"zh": "② 选择支付方式，扫码付款", "en": "② Pick a payment method and scan to pay"},
	"buy.step3": {"zh": "③ 付款后把「机器码 + 支付截图」发给我们（微信 %s，或点下方「✉ 邮件联系我们」），\n收到授权码后在「支持」页下方粘贴激活。", "en": "③ After paying, send us the \"machine code + payment screenshot\" (WeChat %s, or tap \"✉ Email Us\" below),\nthen paste the license code on the Support tab once you receive it."},
	"buy.title": {"zh": "购买 / 升级 Pro", "en": "Buy / Upgrade Pro"},
	"buy.wechat_pay": {"zh": "微信支付", "en": "WeChat Pay"},
	"ca_prompt.guide": {"zh": "打开安装引导", "en": "Open Install Guide"},
	"ca_prompt.install": {"zh": "立即安装", "en": "Install Now"},
	"ca_prompt.later": {"zh": "稍后", "en": "Later"},
	"ca_prompt.text1": {"zh": "GDLive 用本机根证书给 HTTPS 调试地址签名。\n\n", "en": "GDLive signs the HTTPS debug address with a local root CA.\n\n"},
	"ca_prompt.text2": {"zh": "证书：%s\n指纹：%s…\n状态：%s\n\n", "en": "Certificate: %s\nFingerprint: %s…\nStatus: %s\n\n"},
	"ca_prompt.text3": {"zh": "安装一次即可：所有项目、所有 IP 共用，以后换 IP 也不需要重装。\n", "en": "Install once: shared across all projects and IPs — no reinstall even when your IP changes.\n"},
	"ca_prompt.text4": {"zh": "手机端请点「打开安装引导」，按页面提示安装。", "en": "On a phone, tap \"Open Install Guide\" and follow the page prompts."},
	"ca_prompt.title": {"zh": "GDLive · 建议安装根证书", "en": "GDLive · Install Root CA Recommended"},
	"cert.auto_hint": {"zh": "启用 HTTPS 时自动生成；安装一次后，所有项目、所有 IP 共用。", "en": "Generated automatically when HTTPS is enabled; install once and it's shared across all projects and IPs."},
	"cert.check_on_start": {"zh": "启动时检查并提示安装根证书", "en": "Check and prompt for root CA install on startup"},
	"cert.detail": {"zh": "%s\n有效期至 %s · %s…", "en": "%s\nValid until %s · %s…"},
	"cert.dir_label": {"zh": "\n\n目录：\n", "en": "\n\nFolder:\n"},
	"cert.folder": {"zh": "证书目录", "en": "Certificate Folder"},
	"cert.full_hint": {"zh": "所有平台的下载、安装步骤、验证与移除说明都在安装页里：手机扫码或点「打开完整安装页」。", "en": "Download, install, verify and removal instructions for all platforms are on the install page: scan with your phone or tap \"Open Full Install Page.\""},
	"cert.generate": {"zh": "生成根证书", "en": "Generate Root CA"},
	"cert.install_hint": {"zh": "「安装到本机」只影响这台电脑；手机 / 平板请扫下方二维码打开安装页。", "en": "\"Install to this machine\" only affects this computer; scan the QR code below to open the install page on a phone or tablet."},
	"cert.install_local": {"zh": "安装到本机", "en": "Install to This Machine"},
	"cert.new_not_installed": {"zh": "新证书尚未安装", "en": "New certificate not installed yet"},
	"cert.not_generated": {"zh": "○ 尚未生成", "en": "○ Not generated"},
	"cert.not_generated_hint": {"zh": "根证书尚未生成：启用 HTTPS 或点「生成根证书」", "en": "Root CA not generated yet: enable HTTPS or click \"Generate Root CA\""},
	"cert.not_installed": {"zh": "尚未安装", "en": "Not installed"},
	"cert.not_trusted": {"zh": "⚠ 未安装到本机信任库", "en": "⚠ Not installed to this machine's trust store"},
	"cert.open_full_page": {"zh": "打开完整安装页", "en": "Open Full Install Page"},
	"cert.private_key_warning": {"zh": "仅用于受控开发机；私钥 ca-key.pem 不要分享。", "en": "For controlled dev machines only; never share the private key ca-key.pem."},
	"cert.qr_pending": {"zh": "二维码待生成", "en": "QR code pending"},
	"cert.qr_pending_hint": {"zh": "根证书尚未生成 · 点「生成根证书」后显示二维码", "en": "Root CA not generated yet · click \"Generate Root CA\" to show the QR code"},
	"cert.recheck": {"zh": "重新检测信任", "en": "Recheck Trust"},
	"cert.regenerate": {"zh": "重新生成 CA", "en": "Regenerate CA"},
	"cert.scan_hint": {"zh": "手机扫码打开安装页（HTTP，免证书警告）", "en": "Scan to open the install page (HTTP, no cert warning)"},
	"cert.start_first_hint": {"zh": "启动服务器后显示安装页地址和二维码", "en": "Start the server to show the install page address and QR code"},
	"cert.stores": {"zh": "macOS 登录钥匙串 / Windows 用户 Root / Linux p11-kit", "en": "macOS Login Keychain / Windows user Root store / Linux p11-kit"},
	"cert.subtitle": {"zh": "本机根 CA · 所有项目共用", "en": "Local root CA · shared across all projects"},
	"cert.title": {"zh": "根证书安装 / 手机扫码", "en": "Install Root CA / Scan with Phone"},
	"cert.trust_check": {"zh": "根证书信任检测：%s", "en": "Root CA trust check: %s"},
	"cert.trusted": {"zh": "✓ 已安装到本机信任库", "en": "✓ Installed to this machine's trust store"},
	"common.activate": {"zh": "激活", "en": "Activate"},
	"common.cancel": {"zh": "取消", "en": "Cancel"},
	"common.cert_short": {"zh": "证书", "en": "Cert"},
	"common.clear": {"zh": "清空", "en": "Clear"},
	"common.copy": {"zh": "复制", "en": "Copy"},
	"common.copy_address": {"zh": "复制地址", "en": "Copy Address"},
	"common.copy_machine": {"zh": "复制机器码", "en": "Copy Machine Code"},
	"common.export": {"zh": "导出", "en": "Export"},
	"common.open": {"zh": "打开", "en": "Open"},
	"common.open_browser": {"zh": "打开浏览器", "en": "Open in Browser"},
	"common.open_website": {"zh": "打开官网", "en": "Open Website"},
	"common.paste": {"zh": "粘贴", "en": "Paste"},
	"common.pro_feature": {"zh": "Pro 功能，激活授权后生效", "en": "Pro feature, enabled after activation"},
	"common.quick_start": {"zh": "使用引导", "en": "Quick Start"},
	"common.report_issue": {"zh": "问题反馈", "en": "Report Issue"},
	"common.run": {"zh": "执行", "en": "Run"},
	"common.start": {"zh": "启动", "en": "Start"},
	"common.stop": {"zh": "停止", "en": "Stop"},
	"common.unknown": {"zh": "未知", "en": "Unknown"},
	"common.unknown_error": {"zh": "未知错误", "en": "Unknown error"},
	"contact.copy_email": {"zh": "复制邮箱", "en": "Copy Email"},
	"contact.copy_email_alt": {"zh": "复制联系邮箱", "en": "Copy Contact Email"},
	"contact.copy_wechat": {"zh": "复制微信", "en": "Copy WeChat"},
	"contact.copy_wechat_alt": {"zh": "复制微信号", "en": "Copy WeChat ID"},
	"contact.email": {"zh": "邮箱：", "en": "Email:"},
	"contact.email_tooltip": {"zh": "自动生成含机器码与版本的邮件", "en": "Auto-generate an email with the machine code and version"},
	"contact.friend_qr": {"zh": "好友二维码", "en": "Friend QR Code"},
	"contact.friend_qr_tooltip": {"zh": "展开 / 收起微信好友二维码，扫码即可添加", "en": "Show / hide the WeChat friend QR code; scan to add us"},
	"contact.github": {"zh": "GitHub 仓库", "en": "GitHub Repo"},
	"contact.github_tooltip": {"zh": "打开 GitHub 仓库（%s）\n%s", "en": "Open the GitHub repo (%s)\n%s"},
	"contact.hint_buy": {"zh": "购买 / 续费 / 发票 / 换机请邮件或微信（通常 1 个工作日内回复）；", "en": "For purchases / renewals / invoices / machine transfers, email or WeChat us (usually replies within 1 business day);"},
	"contact.hint_issues": {"zh": "Bug 与功能建议请走 GitHub Issues。付款后附上支付截图即可。", "en": "For bugs and feature suggestions use GitHub Issues. Attach a payment screenshot after paying."},
	"contact.issues_tooltip": {"zh": "在 GitHub Issues 反馈 Bug / 功能建议：", "en": "Report bugs / feature requests on GitHub Issues:"},
	"contact.title": {"zh": "联系我们 · 购买 / 续费 / 发票 / 换机", "en": "Contact · Buy / Renew / Invoice / Machine Transfer"},
	"contact.website": {"zh": "官网：", "en": "Website:"},
	"contact.website_tooltip": {"zh": "在浏览器打开 GDLive 官网（文档 / 下载 / 更新日志）", "en": "Open the GDLive website (docs / downloads / changelog)"},
	"contact.wechat": {"zh": "微信：", "en": "WeChat:"},
	"contact.write_email": {"zh": "✉ 写邮件", "en": "✉ Write Email"},
	"debug.create_preset": {"zh": "创建 Web 预设", "en": "Create Web Preset"},
	"debug.first_phone_hint": {"zh": "手机首次调试：切到「证书安装」标签页，扫描安装二维码。", "en": "First time debugging on a phone: switch to the Certificate tab and scan the install QR code."},
	"debug.folder": {"zh": "目录", "en": "Folder"},
	"debug.lan_addrs": {"zh": "局域网地址", "en": "LAN Addresses"},
	"debug.open_browser": {"zh": "浏览器打开", "en": "Open in Browser"},
	"debug.open_debug_page": {"zh": "调试页", "en": "Debug Page"},
	"debug.open_export_dir": {"zh": "打开导出目录", "en": "Open Export Folder"},
	"debug.preset": {"zh": "导出预设", "en": "Export Preset"},
	"debug.qr_button": {"zh": "二维码", "en": "QR Code"},
	"debug.qr_tooltip": {"zh": "打开大图二维码页面（游戏 / 证书 / 赞赏）", "en": "Open the large QR page (game / cert / donate)"},
	"debug.scan_hint": {"zh": "手机扫码打开游戏", "en": "Scan to open the game on your phone"},
	"donate.alipay": {"zh": "支付宝赞赏", "en": "Alipay Donate"},
	"donate.intro": {"zh": "如果 GDLive 帮到了你，欢迎赞助一杯咖啡 ☕\n赞赏完全自愿，不影响授权与功能。", "en": "If GDLive helped you, buy us a coffee ☕\nDonations are entirely voluntary and don't affect licensing or features."},
	"donate.open_page": {"zh": "在浏览器打开赞赏页", "en": "Open Donate Page in Browser"},
	"donate.title": {"zh": "赞赏支持", "en": "Donate"},
	"donate.wechat": {"zh": "微信赞赏", "en": "WeChat Donate"},
	"email.body": {"zh": "正文（可编辑）", "en": "Body (editable)"},
	"email.body_footer": {"zh": "（付款后请附上支付截图；收到授权码后，在插件「支持」页粘贴激活。）\n", "en": "(Attach a payment screenshot after paying; once you receive the license code, paste it on the plugin's Support tab to activate.)\n"},
	"email.body_hello": {"zh": "你好，\n\n", "en": "Hello,\n\n"},
	"email.body_intro": {"zh": "我想咨询 GDLive Pro 授权（购买 / 续费 / 发票 / 换机 / Studio 团队版）。\n\n", "en": "I'd like to ask about a GDLive Pro license (purchase / renewal / invoice / machine transfer / Studio team plan).\n\n"},
	"email.body_license": {"zh": "- 当前授权：%s\n", "en": "- Current license: %s\n"},
	"email.body_machine": {"zh": "- 机器码：%s\n", "en": "- Machine code: %s\n"},
	"email.body_notes": {"zh": "补充说明：\n\n\n", "en": "Notes:\n\n\n"},
	"email.body_payment": {"zh": "- 支付方式：微信 / 支付宝\n", "en": "- Payment: WeChat / Alipay\n"},
	"email.body_proof": {"zh": "- 支付凭证：见附件截图\n\n", "en": "- Payment proof: see attached screenshot\n\n"},
	"email.body_version": {"zh": "- 当前版本：GDLive %s\n", "en": "- Current version: GDLive %s\n"},
	"email.compose_text": {"zh": "收件人：%s\n主题：%s\n\n%s", "en": "To: %s\nSubject: %s\n\n%s"},
	"email.copy_content": {"zh": "复制邮件内容", "en": "Copy Email Content"},
	"email.copy_to": {"zh": "复制收件人邮箱", "en": "Copy Recipient Email"},
	"email.hint": {"zh": "未配置邮件客户端时，可用「复制邮件内容」粘贴到网页邮箱。", "en": "No mail client configured? Use \"Copy Email Content\" and paste it into a webmail."},
	"email.intro": {"zh": "主题与正文已自动填好（含机器码与版本），也可以先修改再发送。付款后请附上支付截图。", "en": "Subject and body are pre-filled (with machine code and version); edit before sending if needed. Attach a payment screenshot after paying."},
	"email.open_app": {"zh": "打开邮件应用", "en": "Open Mail App"},
	"email.subject": {"zh": "主题", "en": "Subject"},
	"email.subject_line": {"zh": "[GDLive] 授权咨询", "en": "[GDLive] License Inquiry"},
	"email.title": {"zh": "邮件联系我们", "en": "Email Us"},
	"email.to": {"zh": "收件人", "en": "To"},
	"header.donate_tooltip": {"zh": "赞赏支持 GDLive", "en": "Donate to GDLive"},
	"header.email_tooltip": {"zh": "邮件联系我们（购买 / 续费 / 发票 / 换机）", "en": "Email us (buy / renew / invoice / machine transfer)"},
	"header.export_dir": {"zh": "导出: %s", "en": "Export: %s"},
	"header.license_badge": {"zh": "授权状态 / 升级 Pro", "en": "License / Upgrade Pro"},
	"header.project": {"zh": "项目: %s", "en": "Project: %s"},
	"header.ready": {"zh": "GDLive 就绪", "en": "GDLive ready"},
	"header.subtitle": {"zh": "web 内网调试", "en": "Web LAN debugging"},
	"hint.https_pro": {"zh": "HTTPS / 根证书是 Pro 功能，激活后可用。", "en": "HTTPS / root CA is a Pro feature, available after activation."},
	"hint.overlay_pro": {"zh": "浏览器日志回传 / 页面内调试面板是 Pro 功能，激活后重启服务器生效。", "en": "Browser log relay / in-page debug console is a Pro feature; restart the server after activation to apply."},
	"lang.changed_toast": {"zh": "界面语言已切换，重新加载插件后生效", "en": "Language changed — reload the plugin to apply"},
	"log.activate_failed": {"zh": "激活失败: %s", "en": "Activation failed: %s"},
	"log.cert_auto_failed": {"zh": "自动生成根证书失败: %s", "en": "Automatic root CA generation failed: %s"},
	"log.cert_failed": {"zh": "生成根证书失败: %s", "en": "Failed to generate root CA: %s"},
	"log.cert_generated": {"zh": "根证书已生成：%s", "en": "Root CA generated: %s"},
	"log.cert_installed_detail": {"zh": "根证书安装完成：", "en": "Root CA installed:"},
	"log.cert_installing": {"zh": "正在安装根证书到系统信任库…", "en": "Installing root CA into the system trust store…"},
	"log.cert_installing_alt": {"zh": "正在安装根证书…", "en": "Installing root CA…"},
	"log.cert_next_step": {"zh": "下一步：点「安装根证书」加入本机信任库", "en": "Next: click \"Install Root CA\" to add it to this machine's trust store"},
	"log.cert_next_step_alt": {"zh": "根证书已生成，下一步：安装到本机", "en": "Root CA generated; next step: install it on this machine"},
	"log.cert_not_trusted": {"zh": "根证书未安装到本机信任库：%s", "en": "Root CA not in this machine's trust store: %s"},
	"log.cert_qr_ready": {"zh": "已生成根证书安装二维码：手机扫码按提示安装；桌面可点「安装到本机」", "en": "Root CA install QR code generated: scan with your phone and follow the prompts; on desktop, click \"Install to This Machine\""},
	"log.cert_rotated": {"zh": "已生成新的根证书：%s（所有设备需要重新信任）", "en": "New root CA generated: %s (all devices must re-trust)"},
	"log.cert_trusted": {"zh": "根证书已安装到本机信任库", "en": "Root CA installed to this machine's trust store"},
	"log.cmd_sent_detail": {"zh": "[cmd] 已发送到 %s 个页面：%s", "en": "[cmd] sent to %s page(s): %s"},
	"log.donate_qr_failed": {"zh": "赞赏二维码解码失败: ", "en": "Failed to decode donate QR code: "},
	"log.export_busy": {"zh": "无法开始导出（可能已有任务在运行）", "en": "Can't start export (a task may already be running)"},
	"log.export_started": {"zh": "开始导出 Web 构建…", "en": "Starting Web export…"},
	"log.files_changed": {"zh": "文件变更 %d 个: %s", "en": "%d file(s) changed: %s"},
	"log.https_ready": {"zh": "HTTPS 已启用，根证书已在本机信任库中", "en": "HTTPS enabled; the root CA is in this machine's trust store"},
	"log.https_signed": {"zh": "HTTPS 由本机根证书签发；手机首次使用请到「证书安装」标签页扫码安装根证书", "en": "HTTPS is signed by the local root CA; on first phone use, switch to the Certificate tab and scan to install the root CA"},
	"log.no_build": {"zh": "还没有 Web 构建，点「立即导出」生成", "en": "No Web build yet — click \"Export Now\" to generate one"},
	"log.no_godot_bin": {"zh": "无法获取 Godot 可执行文件路径，导出可能失败", "en": "Can't locate the Godot executable; export may fail"},
	"log.no_preset": {"zh": "没有 Web 导出预设：先点「创建 Web 预设」", "en": "No Web export preset — click \"Create Web Preset\" first"},
	"log.onboard_shown": {"zh": "[GDLive] 显示首次使用引导", "en": "[GDLive] Showing the first-run guide"},
	"log.preset": {"zh": "预设：%s", "en": "Preset: %s"},
	"log.preset_created": {"zh": "已创建 Web 预设", "en": "Web preset created"},
	"log.preset_created_http": {"zh": "已创建 Web 预设（线程支持关闭，兼容局域网 HTTP）", "en": "Web preset created (threading off, compatible with LAN HTTP)"},
	"log.preset_missing": {"zh": "预设：未找到 Web 预设", "en": "Preset: no Web preset found"},
	"log.preset_write_failed": {"zh": "写入 export_presets.cfg 失败: %s", "en": "Failed to write export_presets.cfg: %s"},
	"log.remote_requesting": {"zh": "正在申请远程试玩会话…", "en": "Requesting remote play session…"},
	"log.remote_start_failed": {"zh": "启动远程试玩失败：%s", "en": "Failed to start Remote Play: %s"},
	"log.rotate_failed": {"zh": "重新生成失败: %s", "en": "Regeneration failed: %s"},
	"log.server_started": {"zh": "服务器已启动，监听 %s:%d", "en": "Server started, listening on %s:%d"},
	"log.shot_decode_failed": {"zh": "截图 %s 解码失败", "en": "Screenshot %s failed to decode"},
	"log.shot_not_png": {"zh": "截图 %s 不是有效的 PNG（%s）", "en": "Screenshot %s is not a valid PNG (%s)"},
	"log.shot_requested": {"zh": "已向 %d 个页面请求截图，等待回传…", "en": "Screenshot requested from %d page(s), waiting…"},
	"log.shot_requested_alt": {"zh": "已向 %d 个页面请求截图…", "en": "Screenshot requested from %d page(s)…"},
	"log.shot_save_failed": {"zh": "截图保存失败：%s（%s）", "en": "Failed to save screenshot: %s (%s)"},
	"log.shot_saved": {"zh": "已保存截图 → %s（%d×%d）", "en": "Screenshot saved → %s (%d×%d)"},
	"log.start_failed": {"zh": "启动失败: %s", "en": "Start failed: %s"},
	"log.support_failed": {"zh": "支持服务启动失败: %s", "en": "Support service failed to start: %s"},
	"log.support_port_busy": {"zh": "支持服务 31065 被占用（可能是旧的 Godot 实例），当前使用 %s；关闭旧实例后重新加载插件即可恢复 31065", "en": "Support service port 31065 is in use (possibly by an old Godot instance); currently using %s. Close the old instance and reload the plugin to restore 31065."},
	"log.support_running": {"zh": "支持服务（独立端口）: ", "en": "Support service (dedicated port): "},
	"logs.autoscroll": {"zh": "自动滚动", "en": "Auto-scroll"},
	"logs.cmd_placeholder": {"zh": "远程指令：输入 JavaScript 表达式发送到已连接的页面（↑↓ 翻历史）", "en": "Remote command: enter a JavaScript expression to send to connected pages (↑↓ for history)"},
	"logs.filter_all": {"zh": "全部", "en": "All"},
	"logs.filter_network": {"zh": "网络", "en": "Network"},
	"logs.filter_warnings": {"zh": "警告+错误", "en": "Warnings + Errors"},
	"logs.refresh_pages": {"zh": "刷新页面", "en": "Refresh Pages"},
	"logs.screenshot": {"zh": "📷 截图", "en": "📷 Screenshot"},
	"onboard.bullet1": {"zh": "✓ 局域网访问 + 自动导出 / 热刷新\n", "en": "✓ LAN access + auto export / hot refresh\n"},
	"onboard.bullet2": {"zh": "✓ 浏览器 console / 报错回传 + 页面内调试面板\n", "en": "✓ Browser console / error relay + in-page debug console\n"},
	"onboard.bullet3": {"zh": "✓ 本机根证书 HTTPS（线程版构建需要 SharedArrayBuffer）\n\n", "en": "✓ Local root CA HTTPS (required for threaded builds: SharedArrayBuffer)\n\n"},
	"onboard.close": {"zh": "关闭", "en": "Close"},
	"onboard.feedback": {"zh": "问题反馈：%s（GitHub Issues）\n", "en": "Feedback: %s (GitHub Issues)\n"},
	"onboard.install_ca": {"zh": "安装根证书并启用 HTTPS", "en": "Install Root CA & Enable HTTPS"},
	"onboard.open_website": {"zh": "🌐 打开官网", "en": "🌐 Open Website"},
	"onboard.reopen_hint": {"zh": "随时点右上角「?」重新打开本引导。", "en": "Reopen this guide anytime via the \"?\" at the top right."},
	"onboard.start": {"zh": "开始使用", "en": "Get Started"},
	"onboard.step1": {"zh": "1. 在「调试」页确认端口（当前 %d），点顶部「导出」\n", "en": "1. On the Debug tab, confirm the port (currently %d) and click \"Export\" at the top\n"},
	"onboard.step2": {"zh": "2. 需要线程版时，点下方按钮启用 HTTPS 并安装一次根证书\n", "en": "2. For a threaded build, enable HTTPS below and install the root CA once\n"},
	"onboard.step3": {"zh": "3. 手机扫码打开游戏；改代码会自动重新导出并刷新\n\n", "en": "3. Scan with your phone to open the game; code changes re-export and refresh automatically\n\n"},
	"onboard.steps_title": {"zh": "建议流程：\n", "en": "Suggested workflow:\n"},
	"onboard.text1": {"zh": "把 Godot 项目一键导出成 Web，在 0.0.0.0 上启动服务；手机连同一个 Wi-Fi，扫码即可调试。\n\n", "en": "Export your Godot project to the web with one click and serve it on 0.0.0.0; scan with a phone on the same Wi-Fi to debug.\n\n"},
	"onboard.title": {"zh": "欢迎使用 GDLive", "en": "Welcome to GDLive"},
	"onboard.website": {"zh": "官网：%s（文档 / 下载 / 更新日志）\n", "en": "Website: %s (docs / downloads / changelog)\n"},
	"qr.contact": {"zh": "✉ 联系我们", "en": "✉ Contact Us"},
	"qr.contact_tooltip": {"zh": "邮件联系我们：购买 / 续费 / 发票 / 换机", "en": "Email us: buy / renew / invoice / machine transfer"},
	"qr.game_hint": {"zh": "COOP/COEP 已开启：手机连同一 Wi-Fi 扫码即可调试", "en": "COOP/COEP enabled: scan with a phone on the same Wi-Fi to debug"},
	"qr.game_title": {"zh": "手机扫码调试", "en": "Scan with Phone to Debug"},
	"qr.issues_tooltip": {"zh": "在 GitHub Issues 反馈 Bug / 功能建议\n", "en": "Report bugs / feature requests on GitHub Issues\n"},
	"qr.website": {"zh": "🌐 官网", "en": "🌐 Website"},
	"qr.website_tooltip": {"zh": "打开 GDLive 官网（文档 / 下载 / 更新日志）\n", "en": "Open the GDLive website (docs / downloads / changelog)\n"},
	"remote.custom_domain": {"zh": "自定义域名（Studio），如 demo.studio.example.com", "en": "Custom domain (Studio), e.g. demo.studio.example.com"},
	"remote.establishing": {"zh": "⏳ 正在建立远程会话…", "en": "⏳ Establishing remote session…"},
	"remote.expiring_soon": {"zh": "即将到期", "en": "Expiring soon"},
	"remote.limit_free": {"zh": "免费/试用：单次最长 15 分钟，每天 30 分钟", "en": "Free/Trial: up to 15 minutes per session, 30 minutes per day"},
	"remote.limit_pro": {"zh": "Pro：单次最长 24 小时", "en": "Pro: up to 24 hours per session"},
	"remote.limit_studio": {"zh": "Studio：单次最长 7 天，支持自定义域名", "en": "Studio: up to 7 days per session, custom domains supported"},
	"remote.not_started_free": {"zh": "○ 未启动 · 免费/试用单次 15 分钟", "en": "○ Not started · Free/Trial 15 min per session"},
	"remote.password": {"zh": "访问密码（可选）", "en": "Access Password (optional)"},
	"remote.remaining_hours": {"zh": "%d 小时 %d 分", "en": "%dh %dm"},
	"remote.running": {"zh": "● 远程试玩已启动 · 剩余 %s", "en": "● Remote Play started · %s remaining"},
	"remote.start": {"zh": "开始远程试玩", "en": "Start Remote Play"},
	"remote.title": {"zh": "远程试玩", "en": "Remote Play"},
	"remote.ttl_10m": {"zh": "10 分钟", "en": "10 min"},
	"remote.ttl_12h": {"zh": "12 小时", "en": "12 h"},
	"remote.ttl_15m": {"zh": "15 分钟", "en": "15 min"},
	"remote.ttl_24h": {"zh": "24 小时", "en": "24 h"},
	"remote.ttl_30m": {"zh": "30 分钟", "en": "30 min"},
	"remote.ttl_45m": {"zh": "45 分钟", "en": "45 min"},
	"remote.ttl_5m": {"zh": "5 分钟", "en": "5 min"},
	"remote.ttl_60m": {"zh": "60 分钟", "en": "60 min"},
	"remote.ttl_6h": {"zh": "6 小时", "en": "6 h"},
	"remote.ttl_7d": {"zh": "7 天", "en": "7 days"},
	"remove.text1": {"zh": "移除后将立即退出 Pro：HTTPS、远程调试、自动导出等 Pro 功能会关闭，", "en": "Removing deactivates Pro immediately: HTTPS, remote debugging, auto export and other Pro features turn off,"},
	"remove.text2": {"zh": "正在进行的远程试玩也会断开。\n\n", "en": "and any active remote play session is disconnected.\n\n"},
	"remove.text3": {"zh": "授权码不会丢失，可用同一个授权码重新激活；如果设备数量已达上限，", "en": "Your license code is not lost and can reactivate the same machine; if the device limit is reached,"},
	"remove.text4": {"zh": "可能需要先联系我们解绑。\n\n", "en": "you may need to contact us to unbind a device first.\n\n"},
	"remove.text5": {"zh": "确定要移除本机授权吗？", "en": "Remove the license from this machine?"},
	"remove.title": {"zh": "确认移除", "en": "Confirm Removal"},
	"rotate.confirm": {"zh": "继续吗？", "en": "Continue?"},
	"rotate.text": {"zh": "重新生成后，根证书会换新：所有设备（包括这台电脑）都需要重新安装/信任。\n\n", "en": "Regenerating replaces the root CA: every device (including this computer) must reinstall / re-trust it.\n\n"},
	"rotate.title": {"zh": "重新生成根证书", "en": "Regenerate Root CA"},
	"settings.auto_export": {"zh": "自动导出", "en": "Auto Export"},
	"settings.auto_export_tip": {"zh": "监听项目文件，变更后自动执行 headless 导出", "en": "Watch project files and re-export headlessly on change"},
	"settings.auto_export_tip_short": {"zh": "监听项目文件，变更后自动导出", "en": "Watch project files and re-export on change"},
	"settings.auto_reload": {"zh": "自动刷新", "en": "Auto Refresh"},
	"settings.auto_reload_tip": {"zh": "导出成功后通知所有打开的页面刷新", "en": "Notify all open pages to refresh after export"},
	"settings.auto_reload_tip_short": {"zh": "导出后通知页面刷新", "en": "Notify pages to refresh after export"},
	"settings.auto_start": {"zh": "自动启动", "en": "Auto Start"},
	"settings.auto_start_tip": {"zh": "打开编辑器时自动启动服务器", "en": "Start the server automatically when the editor opens"},
	"settings.debug_overlay": {"zh": "远程调试面板", "en": "Remote Debug Panel"},
	"settings.debug_overlay_tip": {"zh": "在页面注入调试台（console 回传 / 网络抓包 / 截图 / 远程指令）；关闭后页面不再被注入，已打开的页面刷新后生效", "en": "Inject a debug console into pages (console relay / network capture / screenshots / remote commands); pages are no longer injected when off — refresh open pages to apply"},
	"settings.debug_overlay_tip_short": {"zh": "页面注入调试台（console 回传 / 网络抓包 / 截图 / 远程指令），可随时关闭", "en": "Inject a debug console into pages (console relay / network capture / screenshots / remote commands); can be turned off anytime"},
	"settings.host_lan": {"zh": "0.0.0.0 · 局域网", "en": "0.0.0.0 · LAN"},
	"settings.host_local": {"zh": "127.0.0.1 · 仅本机", "en": "127.0.0.1 · Local only"},
	"settings.https": {"zh": "HTTPS（线程版）", "en": "HTTPS (threads)"},
	"settings.https_tip": {"zh": "自签根 CA + TLS；线程版 Web 构建需要（SharedArrayBuffer）", "en": "Self-signed root CA + TLS; required for threaded Web builds (SharedArrayBuffer)"},
	"settings.https_tip_short": {"zh": "本机根证书 + TLS", "en": "Local root CA + TLS"},
	"settings.listen_addr": {"zh": "监听地址", "en": "Listen Address"},
	"settings.manual": {"zh": "手动", "en": "Manual"},
	"settings.options": {"zh": "选项", "en": "Options"},
	"settings.port": {"zh": "端口", "en": "Port"},
	"settings.show_v6": {"zh": "显示 IPv6 地址", "en": "Show IPv6 addresses"},
	"settings.show_v6_tip": {"zh": "服务器默认监听 IPv4（0.0.0.0）；勾选后同时列出本机可用的 IPv6 地址（需路由器与手机支持 IPv6 才能访问）", "en": "The server listens on IPv4 (0.0.0.0) by default; also list local IPv6 addresses when enabled (requires router and phone IPv6 support)"},
	"settings.title": {"zh": "服务设置", "en": "Server Settings"},
	"settings.toggle": {"zh": "▾ 服务设置", "en": "▾ Server Settings"},
	"settings.watch": {"zh": "监听文件", "en": "Watch Files"},
	"settings.watch_short": {"zh": "监听", "en": "Watch"},
	"settings.watch_tip": {"zh": "关闭后只能手动导出", "en": "When off, export manually"},
	"status.exporting": {"zh": "导出中…", "en": "Exporting…"},
	"status.exporting_secs": {"zh": " · 导出中 %ds", "en": " · exporting %ds"},
	"status.no_build": {"zh": "还没有 Web 构建 · 点顶部「导出」生成", "en": "No Web build yet · click \"Export\" at the top to generate one"},
	"status.not_running": {"zh": "服务器未启动 · 点顶部「启动」开始监听", "en": "Server not started · click \"Start\" at the top to listen"},
	"status.not_started": {"zh": "○ 未启动", "en": "○ Not started"},
	"status.running": {"zh": "● 运行中 · %s · %d 个客户端", "en": "● Running · %s · %d client(s)"},
	"status.server_stopped": {"zh": "服务器已停止", "en": "Server stopped"},
	"status.stopped": {"zh": "○ 已停止", "en": "○ Stopped"},
	"status.support_off": {"zh": "支持服务未启动", "en": "Support service not started"},
	"summary.export_once": {"zh": "执行一次 headless Web 导出", "en": "Run one headless Web export"},
	"summary.open_lan": {"zh": "用浏览器打开当前局域网地址", "en": "Open the LAN address in a browser"},
	"summary.settings_tooltip": {"zh": "端口 / 监听地址 / 自动化选项", "en": "Port / listen address / automation"},
	"summary.start_stop": {"zh": "启动 / 停止本地服务器", "en": "Start / Stop Local Server"},
	"support.bound_other_alt": {"zh": "\n当前授权绑定其他机器码：", "en": "\nCurrent license bound to a different machine code: "},
	"support.copy_machine_tooltip": {"zh": "复制本机机器码，购买 / 换机时发给我们", "en": "Copy this machine code; send it to us when buying or transferring"},
	"support.copy_page_tooltip": {"zh": "复制授权 / 购买页地址", "en": "Copy the license / purchase page address"},
	"support.free": {"zh": "免费版", "en": "Free"},
	"support.machine_code": {"zh": "机器码：", "en": "Machine code:"},
	"support.machine_tooltip": {"zh": "机器码由本机硬件标识本地生成，仅用于授权绑定，不会上传；购买后发给我们换取授权码", "en": "The machine code is generated locally from this machine's hardware ID, used only for license binding and never uploaded; send it to us after purchase to get your license code"},
	"support.open_page": {"zh": "打开授权页", "en": "Open License Page"},
	"support.open_page_tooltip": {"zh": "打开授权 / 购买网页", "en": "Open the license / purchase page"},
	"support.permanent": {"zh": "永久有效", "en": "Permanent"},
	"support.pro_licensed": {"zh": "Pro 已授权", "en": "Pro licensed"},
	"support.quota_free": {"zh": "今日导出 %d/%d · 同时只能运行 1 个项目", "en": "Exports today %d/%d · only 1 project at a time"},
	"support.quota_pro": {"zh": "导出次数不限 · 可同时运行多个项目", "en": "Unlimited exports · multiple projects at once"},
	"support.remove_license": {"zh": "移除本机授权", "en": "Remove License"},
	"support.remove_tooltip": {"zh": "退出 Pro 并清除本机授权（会二次确认）", "en": "Deactivate Pro and clear the license on this machine (asks for confirmation)"},
	"support.renew": {"zh": "续费 / 更换授权", "en": "Renew / Change License"},
	"support.status_free": {"zh": "免费版 · 试用已结束", "en": "Free · trial ended"},
	"support.status_licensed": {"zh": "✓ %s 已授权 · %s%s", "en": "✓ %s licensed · %s%s"},
	"support.status_title": {"zh": "授权状态", "en": "License Status"},
	"support.status_trial": {"zh": "⏳ 试用中 · 剩余 %d 天（至 %s）", "en": "⏳ Trial · %d day(s) left (until %s)"},
	"support.studio_licensed": {"zh": "Studio 已授权", "en": "Studio licensed"},
	"support.trial_days": {"zh": "试用中（剩余 %d 天）", "en": "Trial (%d day(s) left)"},
	"support.valid_until": {"zh": "有效期至 %s", "en": "Valid until %s"},
	"tab.cert": {"zh": "证书安装", "en": "Certificate"},
	"tab.debug": {"zh": "调试", "en": "Debug"},
	"tab.logs": {"zh": "日志", "en": "Logs"},
	"tab.remote": {"zh": "远程", "en": "Remote"},
	"tab.support": {"zh": "支持", "en": "Support"},
	"toast.activate_failed": {"zh": "激活失败：", "en": "Activation failed:"},
	"toast.activated": {"zh": "Pro 授权激活成功", "en": "Pro license activated"},
	"toast.cert_auto_incomplete": {"zh": "自动安装未完成：", "en": "Auto-install incomplete:"},
	"toast.cert_dir_opened": {"zh": "已在文件管理器打开证书目录", "en": "Certificate folder opened in file manager"},
	"toast.cert_failed": {"zh": "生成根证书失败", "en": "Failed to generate root CA"},
	"toast.cert_generated": {"zh": "已自动生成根证书，手机安装二维码已更新", "en": "Root CA generated automatically; phone install QR code updated"},
	"toast.cert_installed": {"zh": "根证书安装完成", "en": "Root CA installed"},
	"toast.cert_manual": {"zh": "无法自动安装，请手动安装", "en": "Can't install automatically; please install manually"},
	"toast.cert_manual_phone": {"zh": "无法自动安装，请使用「手机安装引导」手动安装", "en": "Can't install automatically; use the \"Phone Install Guide\" to install manually"},
	"toast.cert_rotated": {"zh": "已生成新的根证书，设备需重新信任", "en": "New root CA generated; devices must re-trust"},
	"toast.clipboard_empty": {"zh": "剪贴板为空", "en": "Clipboard is empty"},
	"toast.cmd_failed": {"zh": "指令发送失败", "en": "Failed to send command"},
	"toast.cmd_no_server": {"zh": "服务器未运行，指令未发送", "en": "Server not running; command not sent"},
	"toast.cmd_sent": {"zh": "指令已发送到 %s 个页面", "en": "Command sent to %s page(s)"},
	"toast.contact_email_copied": {"zh": "已复制联系邮箱", "en": "Contact email copied"},
	"toast.contact_email_copied_detail": {"zh": "已复制联系邮箱：%s", "en": "Contact email copied: %s"},
	"toast.copied": {"zh": "已复制 ✓", "en": "Copied ✓"},
	"toast.debug_overlay_on": {"zh": "开启，页面刷新后生效", "en": "enabled, takes effect after page refresh"},
	"toast.debug_overlay_prefix": {"zh": "远程调试面板已", "en": "Remote debug panel "},
	"toast.debug_page_opened": {"zh": "已在浏览器打开调试页", "en": "Debug page opened in browser"},
	"toast.donate_offline": {"zh": "支持服务未启动，可直接在「支持」页扫码赞赏", "en": "Support service not running; you can scan the QR code on the Support tab to donate"},
	"toast.donate_opened": {"zh": "已在浏览器打开赞赏页", "en": "Donate page opened in browser"},
	"toast.email_app_missing": {"zh": "未找到邮件应用；内容已复制，可粘贴到网页邮箱", "en": "No mail app found; content copied — paste it into a webmail"},
	"toast.email_app_missing_alt": {"zh": "未找到邮件应用，邮件内容已复制到剪贴板", "en": "No mail app found; email content copied to clipboard"},
	"toast.email_app_opened": {"zh": "已打开邮件应用：%s", "en": "Mail app opened: %s"},
	"toast.email_copied": {"zh": "已复制邮件内容", "en": "Email content copied"},
	"toast.email_copied_paste": {"zh": "邮件内容已复制，可粘贴到任意邮箱", "en": "Email content copied; paste it into any mail client"},
	"toast.email_no_recipient": {"zh": "收件人邮箱为空，无法打开邮件应用", "en": "Recipient email is empty; can't open the mail app"},
	"toast.export_dir_opened": {"zh": "已在文件管理器打开导出目录", "en": "Export folder opened in file manager"},
	"toast.free_https_off": {"zh": "免费版无法使用 HTTPS，已自动改用 HTTP；升级 Pro 后可启用", "en": "HTTPS is not available on the Free plan; HTTP is used instead. Upgrade to Pro to enable it."},
	"toast.friend_qr_loading": {"zh": "好友二维码尚未加载，请稍后重试", "en": "Friend QR code not loaded yet, please try again shortly"},
	"toast.game_opened": {"zh": "已在浏览器打开游戏地址", "en": "Game address opened in browser"},
	"toast.game_url_copied": {"zh": "已复制游戏地址", "en": "Game address copied"},
	"toast.github_opened": {"zh": "已在浏览器打开 GitHub 仓库：", "en": "GitHub repo opened in browser:"},
	"toast.https_needs_pro": {"zh": "HTTPS / 根证书需要 Pro 授权，已切换到「支持」页", "en": "HTTPS / root CA requires a Pro license; switched to the Support tab"},
	"toast.install_addr_copied": {"zh": "已复制安装页地址", "en": "Install page address copied"},
	"toast.install_addr_copied_detail": {"zh": "已复制安装页地址: ", "en": "Install page address copied: "},
	"toast.install_page_opened": {"zh": "已在浏览器打开安装页", "en": "Install page opened in browser"},
	"toast.issues_opened": {"zh": "已在浏览器打开问题反馈：", "en": "Issue reporter opened in browser:"},
	"toast.license_removed": {"zh": "已移除本机授权，回到免费版", "en": "License removed; back to the Free plan"},
	"toast.license_removed_short": {"zh": "已移除本机授权", "en": "License removed"},
	"toast.logs_cleared": {"zh": "日志已清空", "en": "Logs cleared"},
	"toast.logs_copied": {"zh": "已复制 %d 条日志", "en": "Copied %d log entries"},
	"toast.machine_copied": {"zh": "已复制机器码", "en": "Machine code copied"},
	"toast.machine_copied_buy": {"zh": "已复制机器码，购买后发给我们即可换取授权码", "en": "Machine code copied; send it to us after purchase to get your license code"},
	"toast.no_pages": {"zh": "没有已连接的页面", "en": "No connected pages"},
	"toast.paste_code_first": {"zh": "请先粘贴授权码", "en": "Please paste a license code first"},
	"toast.qr_page_opened": {"zh": "已在浏览器打开二维码页面", "en": "QR page opened in browser"},
	"toast.refresh_pushed": {"zh": "已推送刷新到 %d 个页面", "en": "Refresh pushed to %d page(s)"},
	"toast.remote_10m": {"zh": "⏰ 远程试玩还剩 10 分钟", "en": "⏰ 10 minutes left in Remote Play"},
	"toast.remote_1m": {"zh": "⏰ 远程试玩还剩 1 分钟", "en": "⏰ 1 minute left in Remote Play"},
	"toast.remote_5m": {"zh": "⏰ 远程试玩还剩 5 分钟", "en": "⏰ 5 minutes left in Remote Play"},
	"toast.remote_copied": {"zh": "已复制远程试玩地址", "en": "Remote Play address copied"},
	"toast.remote_copied_share": {"zh": "已复制远程试玩地址，可直接粘贴分享", "en": "Remote Play address copied; paste to share"},
	"toast.remote_copied_share_alt": {"zh": "远程试玩地址已复制到剪贴板，可直接粘贴分享", "en": "Remote Play address copied to clipboard; paste to share"},
	"toast.remote_ending": {"zh": "⏰ 远程试玩即将结束", "en": "⏰ Remote Play ending soon"},
	"toast.remote_opened": {"zh": "已在浏览器打开远程试玩地址", "en": "Remote Play address opened in browser"},
	"toast.remote_start_failed": {"zh": "启动远程试玩失败：", "en": "Failed to start Remote Play:"},
	"toast.remote_stopping": {"zh": "正在停止远程试玩…", "en": "Stopping Remote Play…"},
	"toast.restart_for_pro": {"zh": "重启 GDLive 服务器后 HTTPS / 页面调试面板生效", "en": "Restart the GDLive server for HTTPS / the in-page debug console to take effect"},
	"toast.rotate_failed": {"zh": "重新生成失败：", "en": "Regeneration failed:"},
	"toast.shot_no_pages_hint": {"zh": "没有已连接的页面，截图请求未送达（先在浏览器/手机打开游戏）", "en": "No connected pages; the screenshot request reached no one (open the game in a browser or phone first)"},
	"toast.shot_no_server": {"zh": "服务器未运行，无法请求截图", "en": "Server not running; can't request screenshots"},
	"toast.shot_saved": {"zh": "截图已保存（%d×%d）", "en": "Screenshot saved (%d×%d)"},
	"toast.start_first": {"zh": "先启动服务器", "en": "Start the server first"},
	"toast.start_first_install": {"zh": "先启动服务器，再打开安装页", "en": "Start the server before opening the install page"},
	"toast.start_first_qr": {"zh": "先启动服务器，再打开二维码页面", "en": "Start the server before opening the QR page"},
	"toast.support_addr_copied": {"zh": "已复制支持服务地址", "en": "Support service address copied"},
	"toast.support_not_running": {"zh": "支持服务未启动，请重启插件或在「支持」页直接粘贴授权码", "en": "Support service not running; restart the plugin or paste the license code directly on the Support tab"},
	"toast.support_page_copied": {"zh": "已复制支持页地址", "en": "Support page address copied"},
	"toast.support_page_opened": {"zh": "已在浏览器打开支持页", "en": "Support page opened in browser"},
	"toast.url_copied": {"zh": "已复制 %s/", "en": "Copied %s/"},
	"toast.website_opened": {"zh": "已在浏览器打开官网：", "en": "Website opened in browser:"},
	"toast.wechat_copied": {"zh": "已复制微信号", "en": "WeChat ID copied"},
	"toast.wechat_copied_detail": {"zh": "已复制微信号：%s", "en": "WeChat ID copied: %s"},
	"tooltip.export_limit_hit": {"zh": "免费版今日导出次数已用完，升级 Pro 可无限导出", "en": "Free daily exports used up; upgrade to Pro for unlimited exports"},
	"tooltip.exports_left": {"zh": "免费版今日剩余 %d 次导出", "en": "%d export(s) left today on the Free plan"},
	"tooltip.exports_unlimited": {"zh": "Pro：导出次数不限", "en": "Pro: unlimited exports"},
}
