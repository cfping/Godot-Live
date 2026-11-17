extends Node2D

## Tiny demo that is easy to verify on a phone:
##  - touch / drag moves the glowing dot
##  - the HUD shows FPS and viewport size
##  - every 5 seconds a console line is emitted, which GDLive relays back to
##    the Godot Output panel (and the in-page debug overlay).

var _target := Vector2(480, 300)
var _dot := Vector2(480, 300)
var _time := 0.0
var _ticks := 0
var _tick_timer: Timer
var _hud: Label
var _pulse := 26.0


func _ready() -> void:
	_target = get_viewport_rect().size * 0.5
	_dot = _target

	_hud = Label.new()
	_hud.position = Vector2(18, 14)
	_hud.add_theme_font_size_override("font_size", 15)
	_hud.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	add_child(_hud)

	var hint := Label.new()
	hint.text = "拖动 / 点击屏幕 · GDLive 内网调试示例"
	hint.position = Vector2(18, 40)
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7))
	add_child(hint)

	_tick_timer = Timer.new()
	_tick_timer.wait_time = 5.0
	_tick_timer.autostart = true
	_tick_timer.timeout.connect(_on_tick)
	add_child(_tick_timer)

	print("[demo] GDLive web demo ready · viewport=%s" % str(get_viewport_rect().size))
	set_process(true)


func _on_tick() -> void:
	_ticks += 1
	print("[demo] tick %d · fps=%d · dot=%s" % [_ticks, Engine.get_frames_per_second(), str(_dot.round())])


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.pressed:
		_target = event.position
	elif event is InputEventScreenDrag:
		_target = event.position
	elif event is InputEventMouseButton and event.pressed:
		_target = event.position
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_target = event.position


func _process(delta: float) -> void:
	_time += delta
	_dot = _dot.lerp(_target, clampf(delta * 10.0, 0.0, 1.0))

	_pulse = 26.0 + sin(_time * 3.0) * 4.0
	_hud.text = "GDLive demo  ·  FPS %d  ·  %d×%d" % [
		Engine.get_frames_per_second(),
		int(get_viewport_rect().size.x),
		int(get_viewport_rect().size.y),
	]
	queue_redraw()


func _draw() -> void:
	# Grid backdrop.
	var size := get_viewport_rect().size
	var step := 48.0
	var grid_color := Color(1, 1, 1, 0.035)
	var x := 0.0
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), grid_color, 1.0)
		x += step
	var y := 0.0
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), grid_color, 1.0)
		y += step

	# Soft glow + dot.
	draw_circle(_dot, 34.0 + sin(_time * 3.0) * 3.0, Color(0.25, 0.55, 1.0, 0.10))
	draw_circle(_dot, 22.0, Color(0.35, 0.65, 1.0, 0.22))
	draw_circle(_dot, 13.0, Color(0.55, 0.8, 1.0, 0.95))
	draw_circle(_dot, 5.0, Color(1, 1, 1, 0.95))
	draw_arc(_dot, _pulse, 0, TAU, 64, Color(0.55, 0.8, 1.0, 0.35), 2.0)
# touch 1794815363
