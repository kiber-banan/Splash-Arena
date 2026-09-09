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
## Обычно в комнату нас заводит меню (main_menu.gd): тогда MatchManager
## находит готовое соединение и сразу спавнится. Если запустить main.tscn
## напрямую (F5), он подключится сам — быстрым входом.
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

@onready var spawner: FusionSpawner = $FusionSpawner

var _spawned_for: Dictionary = {}  # player_id -> Player
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
	var options := FusionRoomOptions.new()
	options.max_players = Session.MAX_PLAYERS
	options.is_visible = true
	options.is_open = true
	Fusion.join_or_create_room(Session.room_name_for_code(Session.QUICK_ROOM), options)


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
	if Fusion.is_master_client():
		# Хост (сервер) спавнит собственного игрока.
		_spawn_player(Fusion.get_local_player_id(), Session.character_id)
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


func _retry_spawn_request() -> void:
	# Один повтор с паузой — дешевле, чем молча стоять без персонажа.
	await get_tree().create_timer(1.0).timeout
	if not is_instance_valid(self) or not Fusion.is_in_room():
		return
	if get_tree().get_first_node_in_group(Player.GROUP_LOCAL_PLAYER) != null:
		return
	print("MatchManager: повторяю запрос спавна")
	Fusion.rpc(request_spawn, Session.character_id)


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


# ---------- спавн ----------

@rpc("any_peer", "call_local")
func request_spawn(character_id: int) -> void:
	# Вызывается на сервере (и локально у отправителя — call_local).
	# Спавнит только master client.
	if not Fusion.is_master_client():
		return
	_spawn_player(Fusion.get_rpc_sender(), character_id)


@rpc("any_peer", "call_remote")
func claim_local_player(player: Node) -> void:
	## Сервер присылает владельцу ссылку на его персонажа: так клиент
	## гарантированно включает камеру и захватывает мышь, даже если
	## has_input_authority() по какой-то причине не стал true.
	## RPC может прилететь с player == null (узел уже деспавнен) — терпим.
	if player == null:
		return
	var pl := player as Player
	if pl != null and is_instance_valid(pl):
		pl.setup_local_player()


func _on_player_left(player_id: int, is_inactive: bool) -> void:
	if is_inactive:
		# Пир в пределах player_ttl и может переподключиться — персонажа пока оставляем.
		return
	_roster.erase(player_id)
	if Fusion.is_master_client() and _spawned_for.has(player_id):
		spawner.despawn(_spawned_for[player_id])
		_spawned_for.erase(player_id)


func _spawn_player(player_id: int, character_id: int) -> void:
	if _spawned_for.has(player_id):
		return
	var scene := Characters.scene_for(character_id)
	var player := spawner.spawn(scene) as Player
	if player == null:
		push_error("MatchManager: спавнер вернул не Player.")
		return
	player.position = Player.random_spawn_position(get_tree())
	var rep := player.get_node("FusionServerReplicator") as FusionServerReplicator
	rep.set_input_authority(player_id)
	_spawned_for[player_id] = player
	print("MatchManager: спавн игрока для pid=%d — %s (input_authority выдан)"
		% [player_id, Characters.name_for(player.character_id)])

	# Если этот игрок — я сам, включаем ему локальное управление и камеру.
	if player_id == Fusion.get_local_player_id():
		player.setup_local_player()
	else:
		# Иначе просим его машину включить камеру/мышь сама.
		Fusion.rpc_to_player(player_id, claim_local_player, player)
