extends Node
## Регистрирует игровые действия ввода (InputMap) при старте проекта.
## Это удобнее ручной правки project.godot: действия всегда совпадают
## с кодом, а переназначить клавиши можно потом в Project Settings.

func _ready() -> void:
	_add_action("move_forward", KEY_W)
	_add_action("move_back", KEY_S)
	_add_action("move_left", KEY_A)
	_add_action("move_right", KEY_D)
	_add_action("ascend", KEY_SPACE)    # всплыть вверх
	_add_action("descend", KEY_CTRL)    # опуститься вниз
	_add_action("ability", KEY_E)       # способность персонажа
	_add_mouse_action("fire", MOUSE_BUTTON_LEFT)  # выстрел гарпуном


func _add_action(action_name: StringName, physical_keycode: int) -> void:
	if InputMap.has_action(action_name):
		return
	InputMap.add_action(action_name)
	var event := InputEventKey.new()
	event.physical_keycode = physical_keycode
	InputMap.action_add_event(action_name, event)


func _add_mouse_action(action_name: StringName, button_index: int) -> void:
	if InputMap.has_action(action_name):
		return
	InputMap.add_action(action_name)
	var event := InputEventMouseButton.new()
	event.button_index = button_index
	InputMap.action_add_event(action_name, event)
