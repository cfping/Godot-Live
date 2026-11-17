@tool
extends Control

## Draws a QR matrix produced by GDLiveServer.qr_matrix().

var _n := 0
var _data := PackedByteArray()
var _url := ""


func _ready() -> void:
	custom_minimum_size = Vector2(150, 150)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_matrix(n: int, data: PackedByteArray, url: String) -> void:
	_n = n
	_data = data
	_url = url
	queue_redraw()


func clear_matrix() -> void:
	_n = 0
	_data = PackedByteArray()
	_url = ""
	queue_redraw()


func has_matrix() -> bool:
	return _n > 0


func _draw() -> void:
	if _n <= 0 or _data.size() < _n * _n:
		return

	var padding := 8.0
	var usable := maxf(0.0, minf(size.x, size.y) - padding * 2.0)
	var cell := floorf(usable / float(_n))
	if cell < 1.0:
		return
	var total := cell * float(_n)
	var origin := ((size - Vector2(total, total)) * 0.5).floor()

	draw_rect(Rect2(origin - Vector2(padding, padding) * 0.5, Vector2(total + padding, total + padding)), Color.WHITE, true)
	for y in _n:
		for x in _n:
			if _data[y * _n + x] != 1:
				continue
			draw_rect(
				Rect2(origin + Vector2(float(x), float(y)) * cell, Vector2(cell, cell)),
				Color(0.02, 0.02, 0.03),
				true
			)
