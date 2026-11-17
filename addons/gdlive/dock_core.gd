@tool
extends VBoxContainer

## GDLive dock — core layer: palette, i18n, toasts, dialogs and widget factories.
##
## Holds the shared state read by every other layer, plus the small helpers used to
## build the dock UI (cards, buttons, sections, labels) and the editor toast.
##
## Layered dock scripts (base → top):
##   dock_core → dock_settings → dock_log → dock_cert → dock_remote →
##   dock_support → dock_license → dock_server → dock_onboard → dock_tabs → dock.gd

const CFG_PATH := "user://gdlive.cfg"
const LEGACY_CFG_PATH := "user://gtlive.cfg"
const ONBOARD_VERSION := 1
const QR_VIEW := preload("res://addons/gdlive/qr_view.gd")
const I18N := preload("res://addons/gdlive/i18n.gd")
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

# --- Editor / server -----------------------------------------------------
var plugin
var server
var _project_dir := ""
var _out_dir := ""
var _godot_bin := ""
var _preset := ""

# --- Settings tab --------------------------------------------------------
var _port: SpinBox
var _host: OptionButton
var _auto_export: CheckBox
var _auto_reload: CheckBox
var _watch: CheckBox
var _tls: CheckBox
var _auto_start: CheckBox
var _debug_overlay: CheckBox
# UI language selector: auto (follow OS locale) / Chinese / English.
var _language_option: OptionButton
var _settings_box: VBoxContainer
var _settings_toggle: Button
var _settings_summary: Label

# --- Dock chrome / debug tab ---------------------------------------------
var _tabs: TabContainer
var _tab_support := 3
var _tab_cert := 1
var _status_label: Label
var _start_button: Button
var _export_button: Button
var _open_quick_button: Button
var _cert_quick_button: Button
var _state_hint: Label
var _export_progress: ProgressBar
var _export_started_ms := 0
var _refresh_timer: Timer
var _url_list: ItemList
var _show_v6: CheckBox
var _qr
var _qr_url_label: Label
var _open_button: Button
var _copy_button: Button
var _debug_page_button: Button
var _preset_label: Label
var _preset_button: Button
var _last_urls: PackedStringArray = PackedStringArray()
var _qr_cache := {}

# --- Log tab -------------------------------------------------------------
var _log_view: RichTextLabel
var _log_toolbar: HBoxContainer
var _log_pro_hint: Label
var _log_entries: Array = []
var _log_filter := 0
var _log_autoscroll := true
var _log_filter_option: OptionButton
var _log_autoscroll_check: CheckBox
var _cmd_input: LineEdit
var _cmd_history: Array[String] = []
var _cmd_history_index := -1

# --- Cert tab (root CA) --------------------------------------------------
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
var _ca_pro_hint: Label
var _install_urls: PackedStringArray = PackedStringArray()
var _ca_trust_installed := false
var _ca_trust_detail := ""
var _confirm_rotate: ConfirmationDialog

# --- Remote play tab -----------------------------------------------------
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
var _remote_copy_token := 0
var _remote_tick_timer: Timer
var _remote_session_id := ""
var _remote_toasts_fired: Dictionary = {}

# --- Support tab (contact / donate / buy / email) ------------------------
var _donate_qr_wechat: TextureRect
var _donate_qr_alipay: TextureRect
var _donate_loaded := false
var _buy_dialog: AcceptDialog
var _buy_price_label: Label
var _buy_machine_label: Label
var _buy_step3_label: Label
var _buy_qr_wechat: TextureRect
var _buy_qr_alipay: TextureRect
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
var _support_base := ""
var _support_open_button: Button
var _support_copy_button: Button
var _onboard: AcceptDialog
var _onboarded := false

# --- License state -------------------------------------------------------
var _license_status_label: Label
var _license_quota_label: Label
var _license_machine_label: Label
var _license_input: TextEdit
var _license_badge: Button
var _license_activate_button: Button
var _buy_button: Button
var _remove_license_button: Button
# License / support-server button rows. Both stay hidden for a permanently
# licensed (private) build: nothing to renew, remove or purchase.
var _license_row: HBoxContainer
var _support_row: HBoxContainer
var _activate_card: VBoxContainer
var _license_pro := false
var _license_tier := "free"
var _license_last_check_ms := 0
var _confirm_remove_license: ConfirmationDialog

# --- Floating toast overlay ----------------------------------------------
# A child of the editor root viewport (so it shows above every dock tab);
# auto-fades after a few seconds.
var _toast_panel: PanelContainer
var _toast_label: Label
var _toast_tween: Tween

func setup(editor_plugin, live_server) -> void:
	plugin = editor_plugin
	server = live_server

# true = Chinese UI, false = English UI (see `_t`).
var _zh := false

## Visible feedback for actions whose log lines land on another tab.
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

## Translate a UI string. The key is semantic (`tab.debug`); missing keys fall
## back to the key itself so a missing translation degrades gracefully instead
## of hiding the label.
func _t(key: String) -> String:
	var entry: Dictionary = I18N.TEXT.get(key, {})
	return entry.get("zh" if _zh else "en", key)


## Pop a dock dialog as the ONLY visible exclusive child of the editor window.
## AcceptDialogs default to exclusive; opening a second one while another is
## showing makes Godot refuse (window.cpp "already has another exclusive
## child") and the new dialog renders at a stale size with dead space. Hide
## the sibling dialogs first so only one is ever visible.
func _popup_dialog(dialog: Window, minsize := Vector2i(0, 0)) -> void:
	for other in [_confirm_rotate, _confirm_remove_license, _ca_prompt, _onboard, _buy_dialog, _email_dialog]:
		if other != null and other != dialog:
			other.hide()
	if minsize == Vector2i(0, 0):
		dialog.popup_centered()
	else:
		dialog.popup_centered(minsize)

func _selected_url() -> String:
	var selected := _url_list.get_selected_items()
	if selected.is_empty():
		return ""
	var index: int = selected[0]
	if index < 0 or index >= _url_list.item_count:
		return ""
	return _last_urls[index]
