extends Control
## Экранный HUD.
##
## Шаг 1 — отладочный лейбл: состояние сети, спавн, authority, счётчики
## ввода. Он же — главный инструмент для диагностики «игрок стоит,
## камера не крутится»: по строкам видно, где именно оборвалась цепочка
## photon -> room_joined -> spawn -> set_input_authority -> setup_local_player.
##
## Шаг 2 — код комнаты, счёт игроков, список ников, выход по ESC.
## Шаг 3 — прицел, хит-маркер, полоса HP, красная вспышка при уроне.
## Шаг 4 добавит полосу кулдауна способности.
##
## HUD зарегистрирован как broadcast-приёмник Fusion: сервер шлёт сюда
## rpc_to_player(notify_hit_confirmed) — «твой гарпун попал».
##
## ВАЖНО: корень HUD (и все его дочерние Control) имеют mouse_filter = IGNORE,
## иначе они перехватят движение мыши и _unhandled_input у игрока не сработает
## (классический «камера не крутится»).

const REFRESH_SEC := 0.2      # как часто обновляем тексты/полосы
const HITMARKER_SEC := 0.2    # сколько живёт хит-маркер
const MESSAGE_SEC := 1.4      # сколько живёт сообщение по центру
const CROSSHAIR_ARM := 8.0
const CROSSHAIR_GAP := 4.0

@onready var debug_label: Label = %DebugLabel
@onready var room_info: Label = %RoomInfo
@onready var player_list: Label = %PlayerList
@onready var health_bar: ProgressBar = %HealthBar
@onready var ability_bar: ProgressBar = %AbilityBar
@onready var ability_label: Label = %AbilityLabel
@onready var health_label: Label = %HealthLabel
@onready var damage_flash: ColorRect = %DamageFlash
@onready var center_message: Label = %CenterMessage

var _refresh_left := 0.0
var _hitmarker_left := 0.0
var _message_left := 0.0
var _last_deaths := 0
var _last_player: Player = null
var _flash_tween: Tween = null


func _ready() -> void:
	queue_redraw()  # рисуем прицел
	Fusion.register_broadcast_receiver(self)


func _exit_tree() -> void:
	# Иначе у Fusion останется висячая ссылка на удалённый узел (см. доку RPC).
	if Fusion:
		Fusion.unregister_broadcast_receiver(self)


func _process(delta: float) -> void:
	if _hitmarker_left > 0.0:
		_hitmarker_left -= delta
		if _hitmarker_left <= 0.0:
			queue_redraw()  # стереть хит-маркер
	if _message_left > 0.0:
		_message_left -= delta
		if _message_left <= 0.0:
			center_message.text = ""
	_refresh_left -= delta
	if _refresh_left > 0.0:
		return
	_refresh_left = REFRESH_SEC
	debug_label.text = _build_debug_text()
	room_info.text = _build_room_text()
	var mm := _match_manager()
	player_list.text = mm.get_roster_text() if mm != null else ""
	_update_vitals()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		var mm := _match_manager()
		if mm != null:
			get_viewport().set_input_as_handled()
			mm.leave_to_menu()


# ---------- уведомления от игрока/сервера ----------

@rpc("any_peer", "call_remote")
func notify_hit_confirmed() -> void:
	## Сервер подтвердил попадание (шлёт стрелку через rpc_to_player).
	_hitmarker_left = HITMARKER_SEC
	queue_redraw()


func notify_local_damaged() -> void:
	## Эту машину ранили — красная вспышка на весь экран.
	if _flash_tween != null and _flash_tween.is_valid():
		_flash_tween.kill()
	damage_flash.modulate = Color(1, 1, 1, 0.45)
	_flash_tween = create_tween()
	_flash_tween.tween_property(damage_flash, "modulate", Color(1, 1, 1, 0.0), 0.4)


func show_message(text: String) -> void:
	center_message.text = text
	_message_left = MESSAGE_SEC


# ---------- отрисовка прицела и хит-маркера ----------

func _draw() -> void:
	var center := size / 2.0
	var color := Color(0.85, 1.0, 1.0, 0.9)
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		draw_line(center + d * CROSSHAIR_GAP, center + d * (CROSSHAIR_GAP + CROSSHAIR_ARM), color, 2.0)
	draw_circle(center, 1.5, color)
	if _hitmarker_left > 0.0:
		var alpha := clampf(_hitmarker_left / HITMARKER_SEC, 0.0, 1.0)
		var hit_color := Color(1.0, 0.35, 0.3, alpha)
		for d in [Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]:
			draw_line(center + d * 5.0, center + d * 13.0, hit_color, 2.0)


# ---------- тексты ----------

func _update_vitals() -> void:
	var me := _local_player()
	if me == null:
		health_bar.value = 0.0
		ability_bar.value = 0.0
		health_label.text = "HP —"
		ability_label.text = "Способность —"
		_last_player = null
		return
	if me != _last_player:
		_last_player = me
		_last_deaths = me.deaths
	health_bar.max_value = float(me.max_hp)
	health_bar.value = float(me.hp)
	health_label.text = "HP %d / %d  •  смерти: %d" % [me.hp, me.max_hp, me.deaths]
	ability_bar.value = me.get_ability_cooldown_ratio() * 100.0
	ability_label.text = "%s • %s (E)" % [me.character_name, me.ability_name]
	if me.deaths > _last_deaths:
		show_message("ВАС УБИЛИ")
	_last_deaths = me.deaths


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
		return "\n".join(lines)

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
	return "\n".join(lines)
