class_name Lobby
extends Control
## Лобби: сбор игроков и принятие матча (в стиле LoL).
##
## Фазы:
##   WAIT   — ждём, пока в комнате наберётся Session.MATCH_SIZE игроков.
##            Видны карточки игроков, кнопок нет, сверху «ПОИСК ИГРОКОВ».
##   ACCEPT — все собрались: таймер ACCEPT_TIME, кнопки ПРИНЯТЬ / ОТКАЗАТЬСЯ.
##            Хост решает: все приняли -> lobby_start(); таймер истёк,
##            кто-то вышел или отказался -> lobby_cancel().
##   DONE   — грузим main.tscn. СПАВН происходит ТОЛЬКО там: MatchManager
##            видит комнату и просит ХОСТ заспавнить аватар (request_spawn).
##
## То есть до нажатия «Принять» всеми игроками в мире нет ни одного
## персонажа — ровно как просили: сначала все нашлись и приняли, потом спавн.
##
## Общение между пирами — broadcast-RPC (этот узел зарегистрирован как
## приёмник): lobby_player / lobby_begin_accept / lobby_start / lobby_cancel.

const MAIN_SCENE := "res://scenes/main/main.tscn"
const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const ACCEPT_TIME := 12.0       # сек на принятие матча
const REANNOUNCE_SEC := 1.5     # как часто пересылаем свою карточку
const START_DELAY_SEC := 0.7    # пауза перед загрузкой арены (показать «в бой»)

const COLOR_INFO := Color(0.80, 0.92, 1.0)
const COLOR_OK := Color(0.45, 0.95, 0.62)
const COLOR_ERROR := Color(1.0, 0.55, 0.45)

const ROW_BG := Color(0.055, 0.102, 0.145, 0.9)
const ROW_BORDER := Color(0.11, 0.243, 0.318, 1)
const ROW_OK_BG := Color(0.055, 0.145, 0.11, 0.95)
const ROW_OK_BORDER := Color(0.35, 0.9, 0.55, 1)
const ROW_EMPTY_BG := Color(0.039, 0.078, 0.11, 0.6)
const ROW_EMPTY_BORDER := Color(0.09, 0.18, 0.24, 1)

enum Phase { WAIT, ACCEPT, DONE }

@onready var title: Label = %Title
@onready var subtitle: Label = %Subtitle
@onready var timer_label: Label = %TimerLabel
@onready var timer_bar: ProgressBar = %TimerBar
@onready var players_list: VBoxContainer = %PlayersList
@onready var accept_button: Button = %AcceptButton
@onready var decline_button: Button = %DeclineButton
@onready var status_label: Label = %StatusLabel

var _players: Dictionary = {}   # pid -> {"nick": String, "char": int, "accepted": bool}
var _phase := Phase.WAIT
var _time_left := ACCEPT_TIME
var _reannounce_left := 0.0
var _done := false


func _ready() -> void:
	add_to_group("lobby")
	Fusion.register_broadcast_receiver(self)
	Fusion.player_left.connect(_on_player_left)
	Fusion.room_left.connect(_on_room_left)
	accept_button.pressed.connect(_on_accept_pressed)
	decline_button.pressed.connect(_on_decline_pressed)
	if not Fusion.is_in_room():
		Session.last_notice = "Соединение с комнатой потеряно."
		_goto_menu()
		return
	timer_bar.max_value = ACCEPT_TIME
	timer_bar.value = ACCEPT_TIME
	_announce(false)
	_refresh()
	_set_status("Собираем игроков...", COLOR_INFO)


func _exit_tree() -> void:
	if Fusion:
		Fusion.unregister_broadcast_receiver(self)
		if Fusion.player_left.is_connected(_on_player_left):
			Fusion.player_left.disconnect(_on_player_left)
		if Fusion.room_left.is_connected(_on_room_left):
			Fusion.room_left.disconnect(_on_room_left)


func _process(delta: float) -> void:
	if _done:
		return
	_reannounce_left -= delta
	if _reannounce_left <= 0.0:
		_reannounce_left = REANNOUNCE_SEC
		if _phase == Phase.WAIT:
			_announce(false)  # кто-то мог не получить первую карточку
	if _phase == Phase.ACCEPT:
		_time_left = maxf(_time_left - delta, 0.0)
		timer_bar.value = _time_left
		timer_label.text = "%02d" % int(ceil(_time_left))
		if Fusion.is_master_client() and _time_left <= 0.0:
			Fusion.rpc(lobby_cancel, "Кто-то не принял матч вовремя.")
			return
	_host_check()


# ---------- сетевой протокол лобби ----------

@rpc("any_peer", "call_local")
func lobby_player(player_id: int, nick: String, character_id: int, accepted: bool) -> void:
	_players[player_id] = {"nick": nick, "char": character_id, "accepted": accepted}
	_refresh()
	_host_check()


@rpc("any_peer", "call_local")
func lobby_begin_accept() -> void:
	if _done or _phase != Phase.WAIT:
		return
	_phase = Phase.ACCEPT
	_time_left = ACCEPT_TIME
	timer_bar.value = ACCEPT_TIME
	_refresh()
	_set_status("Матч найден! Прими участие, чтобы начать бой.", COLOR_OK)


@rpc("any_peer", "call_local")
func lobby_start() -> void:
	if _done:
		return
	_done = true
	_phase = Phase.DONE
	_refresh()
	_set_status("Все приняли. В бой!", COLOR_OK)
	# Арену грузим только сейчас: именно MatchManager (уже в main.tscn)
	# попросит ХОСТ заспавнить аватары. До этого спавна нет.
	await get_tree().create_timer(START_DELAY_SEC).timeout
	get_tree().change_scene_to_file(MAIN_SCENE)


@rpc("any_peer", "call_local")
func lobby_cancel(reason: String) -> void:
	if _done:
		return
	_done = true
	_phase = Phase.DONE
	Session.last_notice = reason
	_goto_menu()


func _announce(accepted: bool) -> void:
	Fusion.rpc(
		lobby_player,
		Fusion.get_local_player_id(),
		Session.nickname,
		Session.character_id,
		accepted
	)


func _on_accept_pressed() -> void:
	if _phase != Phase.ACCEPT or _i_accepted():
		return
	_announce(true)
	_refresh()


func _on_decline_pressed() -> void:
	if _done:
		return
	_set_status("Ты отклонил матч, расформировываем лобби...", COLOR_ERROR)
	Fusion.rpc(lobby_cancel, "%s отклонил матч" % Session.nickname)


func _host_check() -> void:
	## Решает только хост: пора ли открывать приём и пора ли стартовать.
	if _done or not Fusion.is_master_client():
		return
	if _players.size() < Session.MATCH_SIZE:
		return
	if _phase == Phase.WAIT:
		Fusion.rpc(lobby_begin_accept)
	elif _phase == Phase.ACCEPT and _all_accepted():
		Fusion.rpc(lobby_start)


func _all_accepted() -> bool:
	for pid in _players.keys():
		if not _players[pid].get("accepted", false):
			return false
	return _players.size() >= Session.MATCH_SIZE


func _i_accepted() -> bool:
	var entry: Dictionary = _players.get(Fusion.get_local_player_id(), {})
	return bool(entry.get("accepted", false))


# ---------- сигналы Fusion ----------

func _on_player_left(player_id: int, is_inactive: bool) -> void:
	_players.erase(player_id)
	_refresh()
	if is_inactive or _done or not Fusion.is_master_client():
		return
	if _phase == Phase.ACCEPT:
		Fusion.rpc(lobby_cancel, "Игрок покинул лобби.")


func _on_room_left() -> void:
	if _done:
		return
	_done = true
	Session.last_notice = "Комната закрылась."
	_goto_menu()


func _goto_menu() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if Fusion.is_in_room():
		Fusion.leave_room()
	get_tree().change_scene_to_file(MENU_SCENE)


# ---------- интерфейс ----------

func _refresh() -> void:
	for child in players_list.get_children():
		child.queue_free()
	for pid in _players.keys():
		players_list.add_child(_make_row(pid, _players[pid]))
	for _i in maxi(Session.MATCH_SIZE - _players.size(), 0):
		players_list.add_child(_make_empty_row())

	var waiting := _phase == Phase.WAIT
	title.text = "ПОИСК ИГРОКОВ" if waiting else "МАТЧ НАЙДЕН"
	subtitle.text = (
		"Ждём соперников: %d / %d" % [_players.size(), Session.MATCH_SIZE]
		if waiting
		else "Подтверди участие: %d / %d" % [_accepted_count(), Session.MATCH_SIZE]
	)
	timer_label.visible = not waiting
	timer_bar.visible = not waiting
	accept_button.visible = not waiting and not _i_accepted()
	decline_button.visible = not waiting


func _accepted_count() -> int:
	var n := 0
	for pid in _players.keys():
		if _players[pid].get("accepted", false):
			n += 1
	return n


func _make_row(player_id: int, entry: Dictionary) -> Control:
	var accepted := bool(entry.get("accepted", false))
	var is_me := player_id == Fusion.get_local_player_id()

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _row_style(accepted, false))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	margin.add_child(row)

	var icon := Label.new()
	icon.text = "✔" if accepted else "⏳"
	icon.add_theme_font_size_override("font_size", 26)
	icon.add_theme_color_override("font_color", ROW_OK_BORDER if accepted else Color(0.55, 0.7, 0.8))
	icon.custom_minimum_size = Vector2(40, 0)
	row.add_child(icon)

	var nick := Label.new()
	var nick_text := str(entry.get("nick", "???"))
	if is_me:
		nick_text += " (ты)"
	nick.text = nick_text
	nick.add_theme_font_size_override("font_size", 22)
	nick.add_theme_color_override("font_color", Color(0.95, 0.99, 1.0))
	nick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(nick)

	var hero := Label.new()
	hero.text = Characters.name_for(int(entry.get("char", 0)))
	hero.add_theme_font_size_override("font_size", 20)
	hero.add_theme_color_override("font_color", Color(0.6, 0.78, 0.88))
	row.add_child(hero)

	var state := Label.new()
	state.text = "принял" if accepted else "думает..."
	state.add_theme_font_size_override("font_size", 18)
	state.add_theme_color_override("font_color", ROW_OK_BORDER if accepted else Color(0.5, 0.65, 0.75))
	state.custom_minimum_size = Vector2(140, 0)
	state.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(state)
	return panel


func _make_empty_row() -> Control:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _row_style(false, true))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var label := Label.new()
	label.text = "свободное место — ищем игрока..."
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(0.4, 0.55, 0.65))
	margin.add_child(label)
	return panel


static func _row_style(accepted: bool, empty: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	if empty:
		sb.bg_color = ROW_EMPTY_BG
		sb.border_color = ROW_EMPTY_BORDER
		sb.set_border_width_all(1)
	elif accepted:
		sb.bg_color = ROW_OK_BG
		sb.border_color = ROW_OK_BORDER
		sb.set_border_width_all(2)
	else:
		sb.bg_color = ROW_BG
		sb.border_color = ROW_BORDER
		sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	return sb


func _set_status(text: String, color: Color) -> void:
	status_label.modulate = color
	status_label.text = text
