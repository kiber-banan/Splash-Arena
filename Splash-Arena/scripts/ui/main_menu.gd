extends Control
## Стартовое меню: локальный одиночный вход (для теста сети позже
## добавим комнаты, никнеймы и т.д.).

@onready var status_label: Label = %StatusLabel

func _ready() -> void:
	%PlayButton.pressed.connect(_on_play_pressed)

func _on_play_pressed() -> void:
	# Один узел-менеджер внутри сцены main:
	# он сам решает: стать сервером (master) или клиентом.
	get_tree().change_scene_to_file("res://scenes/main/main.tscn")
