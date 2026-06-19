@tool
extends Node2D

## Draws the upcoming tetromino in a small box. game.gd calls set_piece().

const Tet = preload("res://tetris/tetromino.gd")
const CELL := 24
const BOX := 4
const BG := Color(0.07, 0.07, 0.10)
const BORDER := Color(0.55, 0.55, 0.65)

var piece_type: int = -1

func set_piece(type: int) -> void:
	piece_type = type
	queue_redraw()

func _draw() -> void:
	var w := BOX * CELL
	var h := BOX * CELL
	draw_rect(Rect2(0, 0, w, h), BG, true)
	if piece_type >= 0:
		var col := Tet.color(piece_type)
		for c in Tet.cells(piece_type, 0):
			draw_rect(Rect2(c.x * CELL + 1, c.y * CELL + 1, CELL - 2, CELL - 2), col, true)
	draw_rect(Rect2(0, 0, w, h), BORDER, false, 2.0)
