class_name MatchManager
extends Node3D
## Менеджер матча: подключение к Photon, вход в комнату,
## спавн игроков по схеме Client-Server (сервер = master client).
##
## Схема (по доке Fusion Godot Client-Server):
##  - Кто создал комнату -> тот master client (= simulation server).
##  - Сервер спавнит своего игрока сразу, чужих — по RPC-запросу.
##  - Спавнер сам кладёт персонажей в $Players (см. spawn_path в main.tscn).
##  - Client-host: обычный запуск игры — один из игроков и сервер, и играет.
##  - Позже можно собрать отдельный выделенный сервер (headless) —
##    код спавна не поменяется.
##
## СПАВН (дока Photon, Prediction and Input): input authority выдаётся
## ТОЛЬКО через pre_spawn_function в spawner.spawn() — до _ready() сцены.
## Назначение после спавна молча не работает: has_input_authority() = false.
##
## Обычно в main.tscn нас приводит ЛОББИ (scenes/ui/lobby.tscn) — после
## того как все игроки набрались и нажали «Принять»: MatchManager находит
## уже готовое соединение и спавнит всех. Если запустить main.tscn
## напрямую (F5), он подключится сам — быстрым входом (для отладки).
##
## Цепочка, которую надо видеть в логе (Output) при запуске:
##   MatchManager: App ID на месте, подключаюсь к Photon...
##   MatchManager: подключился к Photon, pid=...
##   MatchManager: вошёл в комнату, мастер=..., pid=...
##   MatchManager: спавн игрока для pid=..., input_authority выдан
##   Player: локальный игрок готов (...)
## Если лог обрывается — обрыв ровно в этом месте (см. HUD-лейбл).

const MENU_SCENE := "res://scenes/ui/main_menu.tscn"
const GROUP := "match_manager"
## Повторы RPC «чей это аватар» (сек): на клиенте объект появляется по
## сети позже, чем долетает RPC.
const OWNER_RPC_REPEATS := [0.35, 1.2, 2.5]
## Сколько раз клиент просит хост о спавне, если ответа нет.
const SPAWN_REQUEST_ATTEMPTS := 4
## Когда хост повторно выдаёт input authority (сек). По образцу рабочего
## проекта назначение после spawn() тоже работает, но иногда применяется
## не сразу — переспрашиваем, пока get_input_authority() не совпадёт.
const AUTHORITY_RETRY_SEC := [0.1, 0.6, 1.8]
## Через сколько секунд хост спавнит, даже если кто-то не ответил «арена готова».
const ARENA_WAIT_TIMEOUT := 10.0
## Повторы сообщения «я в арене»: RPC не сохраняются, поэтому на всякий
## случай шлём несколько раз.
const ARENA_READY_REPEATS := [0.4, 1.3, 3.0]
## Как часто клиент проверяет, есть ли у его аватара input authority.
const AUTHORITY_CHECK_SEC := 2.0
const AUTHORITY_CHECK_ATTEMPTS := 6

@onready var spawner: FusionSpawner = $FusionSpawner

var _spawned_for: Dictionary = {}  # player_id -> Player
## pid -> true: пир уже загрузил арену и готов принять спавн.
var _arena_ready: Dictionary = {}
## pid -> character_id: кто просил спавн, но ещё не заспавнен.
var _spawn_requests: Dictionary = {}
var _arena_wait_start_msec := 0
var _authority_check_left := AUTHORITY_CHECK_SEC
var _authority_checks_left := AUTHORITY_CHECK_ATTEMPTS
var _roster: Dictionary = {}       # player_id -> {"nick": String, "char": int}
var _leaving := false


func _ready() -> void:
	add_to_group(GROUP)
	Fusion.room_joined.connect(_on_room_joined)
	Fusion.room_left.connect(_on_room_left)
	Fusion.player_joined.connect(_on_player_joined)
	Fusion.player_left.connect(_on_player_left)
	Fusion.connection_failed.connect(_on_connection_failed)
	Fusion.register_broadcast_receiver(self)
	# ВАЖНО: все клиенты регистрируют сцены в одном и том же порядке.
	for i in Characters.COUNT:
		spawner.add_spawnable_scene(Characters.scene_for(i))
	add_to_group(Player.GROUP_MATCH_MANAGER)
	# Диагностика: видно, доходят ли аватары до клиента и кому они отданы.
	if not spawner.spawned.is_connected(_on_spawned):
		spawner.spawned.connect(_on_spawned)
	_debug_spawn_signature()

	if Fusion.is_in_room():
		# Меню уже завело нас в комнату — спавнимся сразу.
		_on_room_joined.call_deferred()
	elif Fusion.is_connected_to_photon():
		_join_room.call_deferred()
	else:
		# Прямой запуск main.tscn (минуя меню).
		_connect_to_photon.call_deferred()


func _exit_tree() -> void:
	# Обязательно отписываемся: иначе у Fusion останется висячая ссылка и краш (см. доку RPC).
	if Fusion:
		Fusion.unregister_broadcast_receiver(self)
		_disconnect(Fusion.room_joined, _on_room_joined)
		_disconnect(Fusion.room_left, _on_room_left)
		_disconnect(Fusion.player_joined, _on_player_joined)
		_disconnect(Fusion.player_left, _on_player_left)
		_disconnect(Fusion.connection_failed, _on_connection_failed)
		_disconnect(Fusion.connected_to_photon, _on_connected)
	if is_instance_valid(spawner) and spawner.spawned.is_connected(_on_spawned):
		spawner.spawned.disconnect(_on_spawned)


func _disconnect(sig: Signal, callable: Callable) -> void:
	if sig.is_connected(callable):
		sig.disconnect(callable)


# ---------- подключение ----------

func _connect_to_photon() -> void:
	var app_id := AppConfig.get_app_id()
	if app_id.is_empty():
		# Запасной путь: App ID вбит прямо в Project Settings.
		app_id = String(ProjectSettings.get_setting("fusion/connection/app_id", ""))
	if app_id.is_empty():
		push_error("MatchManager: нет Fusion App ID. Настрой config/secret.cfg (см. README).")
		return
	Fusion.set_app_id(app_id)
	print("MatchManager: App ID на месте, подключаюсь к Photon...")
	Fusion.connected_to_photon.connect(_on_connected)
	Fusion.connect_to_photon.call_deferred(Session.make_user_id())


func _join_room() -> void:
	## Прямой запуск main.tscn (минуя меню): тот же матчмейкинг, что и в меню —
	## сначала пытаемся войти в любую свободную комнату, иначе создаём свою.
	Fusion.join_room("", Session.make_room_options())


func _on_connected() -> void:
	print("MatchManager: подключился к Photon, pid=%d" % Fusion.get_local_player_id())
	_join_room()


func _on_connection_failed(error: String) -> void:
	push_error("MatchManager: не удалось подключиться к Photon: %s" % error)
	Session.last_notice = "Ошибка подключения: %s" % error
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_SCENE)


# ---------- комната ----------

func _on_room_joined() -> void:
	print("MatchManager: вошёл в комнату, мастер=%s, pid=%d"
		% [str(Fusion.is_master_client()), Fusion.get_local_player_id()])
	_roster.clear()
	_announce_self()
	# Сообщаем: «я в арене, спавнер готов». Без этого хост мог бы
	# заспавнить аватар, пока мы ещё в лобби, — а спавн не сохраняется,
	# и клиент остался бы с нулём аватаров навсегда.
	_announce_arena_ready()
	if Fusion.is_master_client():
		_spawn_pending()
	else:
		# Клиент просит сервер заспавнить его (broadcast-RPC).
		Fusion.rpc(request_spawn, Session.character_id)
		# На всякий случай: если сервер не ответил (например, он ещё
		# не зарегистрировал спавнер), повторяем запрос через секунду.
		_retry_spawn_request.call_deferred()


func _on_room_left() -> void:
	_roster.clear()
	if _leaving:
		return
	# Выкинуло не по нашей воле (разрыв, кик) — возвращаемся в меню.
	Session.last_notice = "Соединение с комнатой потеряно."
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().change_scene_to_file(MENU_SCENE)


func leave_to_menu() -> void:
	## Выход из комнаты обратно в меню (ESC в HUD).
	if _leaving:
		return
	_leaving = true
	Session.last_notice = "Ты вышел из комнаты."
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if Fusion.is_in_room():
		Fusion.leave_room()
	get_tree().change_scene_to_file(MENU_SCENE)


# ---------- рукопожатие «арена готова» ----------
#
# Спавн — событие, а не состояние: если объект создан, пока клиент ещё
# в лобби (там нет FusionSpawner), клиент его НЕ получит и не догонит
# потом. Поэтому хост спавнит только тех, кто явно сообщил, что арена
# у него загружена и спавнер зарегистрирован.

func _announce_arena_ready() -> void:
	var pid := Fusion.get_local_player_id()
	_arena_ready[pid] = true
	if Fusion.is_in_room():
		Fusion.rpc(arena_ready, pid)
	_announce_arena_ready_repeats()


func _announce_arena_ready_repeats() -> void:
	for wait in ARENA_READY_REPEATS:
		await get_tree().create_timer(wait).timeout
		if not is_instance_valid(self) or not Fusion.is_in_room():
			return
		if get_tree().get_first_node_in_group(Player.GROUP_LOCAL_PLAYER) != null:
			return  # уже заспавнились — хватит
		Fusion.rpc(arena_ready, Fusion.get_local_player_id())
		if Fusion.is_master_client():
			_spawn_pending()


@rpc("any_peer", "call_local")
func arena_ready(player_id: int) -> void:
	var is_new := not _arena_ready.has(player_id)
	_arena_ready[player_id] = true
	if is_new:
		print("MatchManager: пир pid=%d загрузил арену" % player_id)
	if Fusion.is_master_client():
		_spawn_pending()


func _known_peers() -> Array:
	## Все пиры, которых мы знаем (кроме себя): из ростера и из запросов.
	var out: Array = []
	for pid in _roster.keys():
		var p := int(pid)
		if p not in out:
			out.append(p)
	for pid in _spawn_requests.keys():
		var q := int(pid)
		if q not in out:
			out.append(q)
	return out


func _spawn_pending() -> void:
	## Хост спавнит всех, кто уже в арене. Ждём остальных — иначе их
	## аватары будут созданы на хосте, но потеряны на клиенте.
	if not Fusion.is_master_client() or not Fusion.is_in_room():
		return
	if _arena_wait_start_msec == 0:
		_arena_wait_start_msec = Time.get_ticks_msec()
	var waited := (Time.get_ticks_msec() - _arena_wait_start_msec) / 1000.0
	for pid in _known_peers():
		if not _arena_ready.has(pid) and waited < ARENA_WAIT_TIMEOUT:
			return
	var my_id := Fusion.get_local_player_id()
	if not _spawned_for.has(my_id):
		_spawn_player(my_id, Session.character_id)
	for pid in _spawn_requests.keys():
		var p := int(pid)
		if not _spawned_for.has(p):
			_spawn_player(p, int(_spawn_requests[p]))


func _respawn(player_id: int) -> void:
	## Клиент пишет, что у него нет аватара (спавн потерялся) — удаляем
	## старый объект и создаём новый, раз уж спавн не сохраняется.
	if not Fusion.is_master_client():
		return
	# Dictionary.get() возвращает Variant, поэтому тип указываем через as:
	# иначе GDScript выведет Variant и (у тебя warnings-as-errors) не соберётся.
	var old := _spawned_for.get(player_id) as Node
	if old != null and is_instance_valid(old) and spawner.has_method("despawn"):
		spawner.despawn(old)
		_spawned_for.erase(player_id)
		print("MatchManager: пересоздаю аватар pid=%d — клиент его не получил" % player_id)
		_spawn_pending()
		return
	push_warning("MatchManager: не могу пересоздать аватар pid=%d (нет spawner.despawn())" % player_id)


func _retry_spawn_request() -> void:
	# Повторяем запрос, пока хост не ответит спавном: RPC не сохраняются,
	# поэтому «запрос улетел в никуда» — частая причина пустого мира.
	# Повтор безопасен: на хосте стоит защита от двойного спавна.
	for attempt in SPAWN_REQUEST_ATTEMPTS:
		if attempt == 2:
			_debug_dump_avatars()
		await get_tree().create_timer(1.5).timeout
		if not is_instance_valid(self) or not Fusion.is_in_room():
			return
		if get_tree().get_first_node_in_group(Player.GROUP_LOCAL_PLAYER) != null:
			return
		print("MatchManager: повторяю запрос спавна (попытка %d)" % (attempt + 2))
		Fusion.rpc(request_spawn, Session.character_id, true)
	# Ничего не помогло — печатаем состояние спавнера: по нему видно,
	# почему объекты не долетают.
	_debug_dump_spawner_state()


func _debug_dump_spawner_state() -> void:
	print("MatchManager: === диагностика: аватара так и нет ===")
	print("  pid=%d  мастер=%s  в комнате=%s"
		% [Fusion.get_local_player_id(), str(Fusion.is_master_client()), str(Fusion.is_in_room())])
	print("  аватаров в дереве=%d  готовые пиры=%s  запросы=%s"
		% [
			get_tree().get_nodes_in_group(Player.GROUP_ALL).size(),
			str(_arena_ready.keys()),
			str(_spawn_requests.keys()),
		])
	var room := Fusion.get_room()
	if room != null:
		if room.has_method("get_player_count"):
			print("  игроков в комнате=%d" % int(room.get_player_count()))
		if room.has_method("get_room_name"):
			print("  комната=%s" % str(room.get_room_name()))
	for d in spawner.get_property_list():
		var pname := String(d.get("name", ""))
		if pname.begins_with("_") or pname in ["script", "metadata"]:
			continue
		print("  spawner.%s = %s" % [pname, str(spawner.get(pname))])


# ---------- список игроков (ники) ----------
#
# Никнеймы не реплицируются сами, поэтому каждый пир при входе в комнату
# рассылает broadcast-RPC со своим ником. Когда в комнату заходит кто-то
# новый, все уже сидящие пере-анонсируют себя, чтобы новичок получил
# полный список (RPC, отправленные до его входа, он не увидит).

@rpc("any_peer", "call_local")
func announce_player(player_id: int, nick: String, character_id: int) -> void:
	_roster[player_id] = {"nick": nick, "char": character_id}


func _announce_self() -> void:
	Fusion.rpc(announce_player, Fusion.get_local_player_id(), Session.nickname, Session.character_id)


func _on_player_joined(_player_id: int, _user_id: String) -> void:
	if Fusion.is_in_room():
		_announce_self()


func get_player_count() -> int:
	return maxi(_roster.size(), 1)


func get_roster_text() -> String:
	var lines := PackedStringArray()
	var local_id := Fusion.get_local_player_id()
	for pid in _roster.keys():
		var entry: Dictionary = _roster[pid]
		var nick := str(entry.get("nick", "???"))
		nick += " — " + Characters.name_for(int(entry.get("char", 0)))
		if pid == local_id:
			nick += " (ты)"
		if Fusion.is_master_client() and pid == local_id:
			nick += " [хост]"
		lines.append("• " + nick)
	if lines.is_empty():
		lines.append("• " + Session.nickname + " — " + Characters.name_for(Session.character_id) + " (ты)")
	return "\n".join(lines)


func _process(delta: float) -> void:
	## Клиент следит, что у его аватара есть input authority. Если нет —
	## просит хост выдать её заново (и камеру тоже): так цепочка чинится
	## сама, даже если первое назначение потерялось.
	if _authority_checks_left <= 0 or not Fusion.is_in_room() or Fusion.is_master_client():
		return
	_authority_check_left -= delta
	if _authority_check_left > 0.0:
		return
	_authority_check_left = AUTHORITY_CHECK_SEC
	_authority_checks_left -= 1
	var me := _local_player()
	if me != null and me.replicator != null and me.replicator.has_input_authority():
		_authority_checks_left = 0
		return
	print("MatchManager: у моего аватара нет input authority — прошу хост (pid=%d)"
		% Fusion.get_local_player_id())
	Fusion.rpc(request_input_authority, Fusion.get_local_player_id())


@rpc("any_peer", "call_local")
func request_input_authority(player_id: int) -> void:
	## Клиент просит хост (пере)выдать input authority и заново объявить
	## владельца. Хост находит аватар по get_input_authority(), а если тот
	## ещё не совпал — по последнему заспавненному под этот pid.
	if not Fusion.is_master_client():
		return
	var pl := _find_player_by_owner(player_id)
	if pl == null and _spawned_for.has(player_id):
		pl = _spawned_for[player_id]
	if pl == null:
		return
	_assign_input_authority(pl, player_id)
	_announce_owner(pl, player_id)
	Fusion.rpc(assign_owner, player_id)
	print("MatchManager: перевыдал input authority pid=%d (сейчас %d)"
		% [player_id, pl.replicator.get_input_authority() if pl.replicator != null else -1])


@rpc("any_peer", "call_local")
func request_shot(shooter_id: int, from: Vector3, to: Vector3) -> void:
	## ЗАПАСНОЙ ПУТЬ для выстрела: если input authority не выдана, ввод
	## клиента до сервера не доходит, и клиент просит сервер разобрать
	## попадание по присланным точкам. Как только input authority
	## заработает, это не вызывается.
	if not Fusion.is_master_client() or not Fusion.is_in_room():
		return
	var shooter := _find_player_by_owner(shooter_id)
	if shooter == null and _spawned_for.has(shooter_id):
		shooter = _spawned_for[shooter_id]
	if shooter == null:
		return
	shooter._apply_shot(from, to)


func _local_player() -> Player:
	return get_tree().get_first_node_in_group(Player.GROUP_LOCAL_PLAYER) as Player


func _debug_spawn_signature() -> void:
	## Печатаем реальную подпись spawn() — по ней видно, принимает ли
	## SDK pre_spawn_function.
	for m in spawner.get_method_list():
		if String(m.get("name", "")) != "spawn":
			continue
		var args := PackedStringArray()
		for a in m.get("args", []):
			args.append("%s:%s" % [a.get("name", "?"), a.get("type", "?")])
		print("MatchManager: FusionSpawner.spawn(%s)" % ", ".join(args))
		return


func _on_spawned(node: Node) -> void:
	## Срабатывает на всех пирах — и у того, кто спавнил, и у остальных.
	var pl := node as Player
	if pl == null or not is_instance_valid(pl.replicator):
		return
	print(
		"MatchManager: аватар в дереве (мой pid=%d, input_authority=%d, has_input=%s, has_state=%s)"
		% [
			Fusion.get_local_player_id(),
			pl.replicator.get_input_authority(),
			str(pl.replicator.has_input_authority()),
			str(pl.replicator.has_authority()),
		]
	)


func _debug_dump_avatars() -> void:
	## Если через 6 с у клиента нет локального игрока — печатаем, что есть
	## в дереве и кому принадлежат аватары. Быстрее, чем гадать по логу.
	if get_tree().get_first_node_in_group(Player.GROUP_LOCAL_PLAYER) != null:
		return
	print("MatchManager: ВНИМАНИЕ — локального игрока нет. Аватары в дереве:")
	for node in get_tree().get_nodes_in_group(Player.GROUP_ALL):
		var pl := node as Player
		if pl == null:
			continue
		print(
			"  • %s: input_authority=%d, мой pid=%d, имя=%s"
			% [pl.name, pl.replicator.get_input_authority(), Fusion.get_local_player_id(), pl.character_name]
		)


# ---------- спавн ----------

@rpc("any_peer", "call_local")
func request_spawn(character_id: int, missing_avatar: bool = false) -> void:
	# Вызывается на сервере (и локально у отправителя — call_local).
	# Спавнит только master client.
	if not Fusion.is_master_client():
		return
	var pid := Fusion.get_rpc_sender()
	if pid <= 0:
		return
	_spawn_requests[pid] = character_id
	# Раз пир прислал запрос — его арена уже загружена.
	_arena_ready[pid] = true
	if missing_avatar and _spawned_for.has(pid):
		_respawn(pid)
		return
	_spawn_pending()


func _on_player_left(player_id: int, is_inactive: bool) -> void:
	if is_inactive:
		# Пир в пределах player_ttl и может переподключиться — персонажа пока оставляем.
		return
	_roster.erase(player_id)
	if Fusion.is_master_client() and _spawned_for.has(player_id):
		spawner.despawn(_spawned_for[player_id])
		_spawned_for.erase(player_id)


func _spawn_with_input_authority(scene: PackedScene, player_id: int) -> Node:
	## ВАЖНО (дока Fusion, раздел Prediction and Input): input authority
	## надо назначать ДО _ready() заспавненной сцены — для этого в spawn()
	## передают pre_spawn_function. Если назначить после спавна (как раньше),
	## has_input_authority() остаётся false и у хоста, и у клиента: аватар
	## никуда не плывёт, а камера не привязывается к своему игроку.
	var player: Node = null
	if _spawn_has_pre_spawn_param():
		var player_id_copy := player_id
		var pre_spawn := func(node: Node) -> void:
			_assign_input_authority(node, player_id_copy)
		player = spawner.spawn(scene, pre_spawn)
		if player == null:
			push_warning("MatchManager: spawn(scene, pre_spawn_function) не принял колбэк — спавню как раньше")
	if player == null:
		# Обычный путь (так же делает рабочий проект-образец).
		player = spawner.spawn(scene)
	# Назначаем и ДО (pre_spawn), и ПОСЛЕ спавна: в разных версиях SDK
	# срабатывает то или другое. Повторное назначение безвредно.
	_assign_input_authority(player, player_id)
	_check_input_authority(player, player_id)
	# Иногда назначение применяется не в этот же кадр — дожимаем повторами.
	if player != null:
		_ensure_input_authority_delayed_loop(player, player_id)
	return player


func _ensure_input_authority_delayed_loop(player: Node, player_id: int) -> void:
	for wait in AUTHORITY_RETRY_SEC:
		await get_tree().create_timer(wait).timeout
		if not is_instance_valid(self) or not is_instance_valid(player):
			return
		if not Fusion.is_master_client():
			return
		var rep := player.get_node_or_null("FusionServerReplicator") as FusionServerReplicator
		if rep != null and rep.get_input_authority() == player_id:
			return
		_assign_input_authority(player, player_id)
		print("MatchManager: повторно выдаю input authority pid=%d (сейчас %d)"
			% [player_id, rep.get_input_authority() if rep != null else -1])
	# Повторы не помогли — перебираем режимы owner_mode с «PREDICT» в названии:
	# если в этой сборке SDK PLAYER_PREDICTED имеет не то числовое значение,
	# найдём рабочее и честно напишем его в лог.
	_try_other_owner_modes(player, player_id)


func _try_other_owner_modes(player: Node, player_id: int) -> void:
	if not Fusion.is_master_client() or not is_instance_valid(player):
		return
	var rep := player.get_node_or_null("FusionServerReplicator") as FusionServerReplicator
	if rep == null:
		return
	if rep.get_input_authority() == player_id:
		return
	var current := int(rep.get("owner_mode"))
	var variants := Player.enum_variants(rep, "owner_mode")
	print("MatchManager: ВНИМАНИЕ — input authority не выдана. Перебираю owner_mode (сейчас %d): %s"
		% [current, str(variants)])
	for variant in variants:
		var label := String((variant as Dictionary).get("label", ""))
		if "PREDICT" not in label.to_upper():
			continue
		var value := int((variant as Dictionary).get("value", -1))
		if value < 0 or value == current:
			continue
		rep.set("owner_mode", value)
		rep.set_input_authority(player_id)
		print("MatchManager: owner_mode=%d (%s) → authority=%d"
			% [value, label, rep.get_input_authority()])
		if rep.get_input_authority() == player_id:
			print("MatchManager: подошёл owner_mode=%d (%s) — input authority выдана" % [value, label])
			return


static func _check_input_authority(node: Node, player_id: int) -> void:
	## Проверяем, что input authority реально выдана. Если нет — в логе
	## будет видно причину (и has_input_authority() останется false).
	if node == null or not is_instance_valid(node):
		return
	var rep := node.get_node_or_null("FusionServerReplicator") as FusionServerReplicator
	if rep == null:
		return
	if rep.get_input_authority() != player_id:
		push_warning(
			"MatchManager: input authority не выдана (нужно pid=%d, сейчас %d). "
			% [player_id, rep.get_input_authority()]
			+ "Проверь owner_mode = PLAYER_PREDICTED у FusionServerReplicator."
		)


static func _assign_input_authority(node: Node, player_id: int) -> void:
	if node == null or not is_instance_valid(node):
		return
	var rep := node.get_node_or_null("FusionServerReplicator") as FusionServerReplicator
	if rep != null:
		rep.set_input_authority(player_id)


func _spawn_has_pre_spawn_param() -> bool:
	## Подпись spawn() в разных версиях SDK отличается, поэтому смотрим,
	## есть ли у метода параметр pre_spawn_function.
	for m in spawner.get_method_list():
		if String(m.get("name", "")) != "spawn":
			continue
		for a in m.get("args", []):
			if "pre_spawn" in String(a.get("name", "")):
				return true
	return false


func _announce_owner(player: Player, player_id: int) -> void:
	Fusion.rpc(player.set_owner_player, player_id)
	for wait in OWNER_RPC_REPEATS:
		_announce_owner_delayed(player, player_id, wait)


func _announce_owner_delayed(player: Player, player_id: int, wait: float) -> void:
	await get_tree().create_timer(wait).timeout
	if not is_instance_valid(self) or not is_instance_valid(player):
		return
	Fusion.rpc(player.set_owner_player, player_id)


@rpc("any_peer", "call_local")
func assign_owner(player_id: int) -> void:
	## Хост сообщает всем, какой аватар чей. Каждый пир сам находит узел
	## в группе Player.GROUP_ALL по get_input_authority().
	## ВАЖНО: действуем только если это НАШ pid — иначе хост (у которого
	## в дереве все аватары) включит камеру на чужом персонаже.
	if player_id != Fusion.get_local_player_id():
		return
	if _assign_local(player_id):
		return
	# Узел на клиенте может появиться чуть позже RPC — пробуем ещё.
	for wait in OWNER_RPC_REPEATS:
		_assign_owner_delayed(player_id, wait)


func _assign_owner_delayed(player_id: int, wait: float) -> void:
	await get_tree().create_timer(wait).timeout
	if not is_instance_valid(self) or not Fusion.is_in_room():
		return
	_assign_local(player_id)


func _assign_local(player_id: int) -> bool:
	var pl := _find_player_by_owner(player_id)
	if pl == null:
		return false
	pl.setup_local_player()
	return true


func _find_player_by_owner(player_id: int) -> Player:
	## Ищет аватар, чей input authority = player_id (реплицируется сервером).
	for node in get_tree().get_nodes_in_group(Player.GROUP_ALL):
		var pl := node as Player
		if pl == null or not is_instance_valid(pl):
			continue
		if pl.replicator != null and pl.replicator.get_input_authority() == player_id:
			return pl
	return null


func _spawn_player(player_id: int, character_id: int) -> void:
	# СПАВНИТЬ МОЖЕТ ТОЛЬКО ХОСТ (master client = сервер симуляции).
	# Клиент не спавнит сам — он просит хост через request_spawn().
	if not Fusion.is_master_client():
		push_error("MatchManager: спавн пытаются сделать не на хосте — так нельзя, спавнит только хост.")
		return
	if _spawned_for.has(player_id):
		return
	var scene := Characters.scene_for(character_id)
	var player := _spawn_with_input_authority(scene, player_id) as Player
	if player == null:
		push_error("MatchManager: спавнер вернул не Player.")
		return
	player.position = Player.random_spawn_position(get_tree())
	_spawned_for[player_id] = player
	print("MatchManager: спавн игрока для pid=%d — %s (input_authority=%d)"
		% [
			player_id,
			Characters.name_for(player.character_id),
			player.replicator.get_input_authority(),
		])

	# object-RPC: на машине владельца включает камеру и захват мыши.
	# Повторяем — объект мог появиться на клиенте позже, чем долетит RPC.
	_announce_owner(player, player_id)
	# И broadcast на тот случай, если object-RPC не дойдёт.
	Fusion.rpc(assign_owner, player_id)

	# Свой аватар (этот пир и есть хост) настраиваем сразу локально.
	if player_id == Fusion.get_local_player_id():
		player.setup_local_player()
