class_name Characters
extends RefCounted
## Справочник персонажей.
##
## Скрипт у всех один — player.gd. Отличаются только экспортируемые статы
## в трёх сценах-наследниках (player_assault / player_medic / player_scout).
## Здесь же данные для меню, чтобы не инстанцировать сцены ради имён.

const ASSAULT := 0
const MEDIC := 1
const SCOUT := 2
const COUNT := 3


static func scene_for(character_id: int) -> PackedScene:
	match character_id:
		MEDIC:
			return preload("res://scenes/player/player_medic.tscn")
		SCOUT:
			return preload("res://scenes/player/player_scout.tscn")
		_:
			return preload("res://scenes/player/player_assault.tscn")


static func name_for(character_id: int) -> String:
	match character_id:
		MEDIC:
			return "Медик"
		SCOUT:
			return "Разведчик"
		_:
			return "Штурмовик"


static func description_for(character_id: int) -> String:
	match character_id:
		MEDIC:
			return "80 HP • скорость 6 • лечение +40 HP (кулдаун 8 с)"
		SCOUT:
			return "70 HP • скорость 7.5 • ускорение ×1.5 на 3 с (кулдаун 10 с)"
		_:
			return "100 HP • скорость 6 • рывок (кулдаун 5 с)"
