extends Control
## Экранный HUD.
##
## Шаг 1 — отладочный лейбл: состояние сети, спавн, authority, счётчики
## ввода. Он же — главный инструмент для диагностики «игрок стоит,
## камера не крутится»: по строкам видно, где именно оборвалась цепочка
## photon -> room_joined -> spawn -> set_input_authority -> setup_local_player.
##
## Шаг 2 — код комнаты, счёт игроков, список ников, выход по ESC.
##
## Шаги 3-4 добавляют прицел, полосу HP и кулдаун способности.
##
## ВАЖНО: корень HUD имеет mouse_filter = IGNORE, иначе Control-узел
## перехватит движение мыши и _unhandled_input у игрока не сработает
## (классический «камера не крутится»).

const REFRESH_SEC := 0.2  # как часто обновляем тексты

@onready var debug_label: Label = %DebugLabel
@onready var room_info: Label = %RoomInfo
@onready var player_list: Label = %PlayerList

var _refresh_left := 0.0


func _process(delta: float) -> void:
	_refresh_left -= delta
	if _refresh_left > 0.0:
		return
	_refresh_left = REFRESH_SEC
	debug_label.text = _build_debug_text()
	room_info.text = _build_room_text()
	var mm := _match_manager()
	player_list.text = mm.get_roster_text() if mm != null else ""


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		var mm := _match_manager()
		if mm != null:
			get_viewport().set_input_as_handled()
			mm.leave_to_menu()


static func _yes(b: bool) -> String:
	return "да" if b else "нет"


func _local_player() -> Player:
	return get_tree().get_first_node_in_group(Player.GROUP_LOCAL_PLAYER) as Player


func _match_manager() -> MatchManager:
	return get_tree().get_first_node_in_group(MatchManager.GROUP) as MatchManager


func _build_room_text() -> String:
	var code := Session.room_code
	if code.is_empty():
		code = "быстрый вход"
	var mm := _match_manager()
	var count := 1
	if mm != null:
		count = mm.get_player_count()
	return "Комната: %s\nИгроки: %d / %d\nТы: %s" % [code, count, Session.MAX_PLAYERS, Session.nickname]


func _build_debug_text() -> String:
	var lines := PackedStringArray()
	lines.append(
		"Сеть:   Fusion=%s  Photon=%s  комната=%s  мастер=%s"
		% [
			_yes(Fusion.is_initialized()),
			_yes(Fusion.is_connected_to_photon()),
			_yes(Fusion.is_in_room()),
			_yes(Fusion.is_master_client())
		]
	)
	lines.append("Игрок:  мой pid=%d  мышь=%s"
		% [Fusion.get_local_player_id(), _yes(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)])

	var me := _local_player()
	if me == null:
		lines.append("Спавн:  НЕТ локального игрока")
		return lines.join("\n")

	var rep := me.replicator
	lines.append(
		"Спавн:  есть  input=%s  state=%s  authority_pid=%d"
		% [_yes(rep.has_input_authority()), _yes(rep.has_authority()), rep.get_input_authority()]
	)
	lines.append("Репликатор: owner_mode=%d  root_replication_mode=%d"
		% [int(rep.owner_mode), int(rep.root_replication_mode)])

	var queue := "-"
	var queue_dt := "-"
	# Диагностические методы из раздела Prediction and Input: берём их
	# через has_method, чтобы HUD не ронял игру на других версиях SDK.
	if rep.has_method("get_input_queue_count"):
		queue = str(rep.get_input_queue_count())
	if rep.has_method("get_input_queue_delta_time"):
		queue_dt = "%.4f" % rep.get_input_queue_delta_time()
	lines.append("Ввод:   отправлено=%d  исполнено=%d  dir=(%.2f, %.2f)  очередь=%s  dt=%s"
		% [
			me.debug_inputs_sent,
			me.debug_inputs_executed,
			me.debug_last_dir.x,
			me.debug_last_dir.y,
			queue,
			queue_dt
		])
	return lines.join("\n")
