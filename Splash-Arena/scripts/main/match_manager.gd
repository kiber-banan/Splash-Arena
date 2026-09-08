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
## Цепочка, которую надо видеть в логе (Output) при запуске:
##   MatchManager: есть App ID
##   MatchManager: подключаюсь к Photon...
##   MatchManager: подключился, pid=...
##   MatchManager: вошёл в комнату, master=..., pid=...
##   MatchManager: спавн игрока для pid=..., input_authority выдан
##   Player: локальный игрок готов (...)
## Если лог обрывается — обрыв ровно в этом месте (см. HUD-лейбл).

const PlayerScene := preload("res://scenes/player/player.tscn")

@onready var spawner: FusionSpawner = $FusionSpawner

var _spawned_for: Dictionary = {}  # player_id -> Player


func _ready() -> void:
	Fusion.room_joined.connect(_on_room_joined)
	Fusion.player_left.connect(_on_player_left)
	Fusion.connection_failed.connect(_on_connection_failed)
	Fusion.register_broadcast_receiver(self)
	spawner.add_spawnable_scene(PlayerScene)

	var app_id := AppConfig.get_app_id()
	if app_id.is_empty():
		# Запасной путь: App ID вбит прямо в Project Settings.
		app_id = String(ProjectSettings.get_setting("fusion/connection/app_id", ""))
	if app_id.is_empty():
		push_error("MatchManager: нет Fusion App ID. Настрой config/secret.cfg (см. README).")
		return
	Fusion.set_app_id(app_id)
	print("MatchManager: App ID на месте, подключаюсь к Photon...")

	# Подключаемся к Photon Cloud; затем создаём/входим в комнату.
	Fusion.connected_to_photon.connect(_on_connected)
	Fusion.connect_to_photon.call_deferred("user_%d" % randi())


func _exit_tree() -> void:
	# Обязательно отписываемся: иначе у Fusion останется висячая ссылка и краш (см. доку RPC).
	if Fusion:
		Fusion.unregister_broadcast_receiver(self)
		if Fusion.room_joined.is_connected(_on_room_joined):
			Fusion.room_joined.disconnect(_on_room_joined)
		if Fusion.player_left.is_connected(_on_player_left):
			Fusion.player_left.disconnect(_on_player_left)
		if Fusion.connection_failed.is_connected(_on_connection_failed):
			Fusion.connection_failed.disconnect(_on_connection_failed)
		if Fusion.connected_to_photon.is_connected(_on_connected):
			Fusion.connected_to_photon.disconnect(_on_connected)


func _on_connected() -> void:
	print("MatchManager: подключился к Photon, pid=%d" % Fusion.get_local_player_id())
	Fusion.join_or_create_room()


func _on_connection_failed(error: String) -> void:
	push_error("MatchManager: не удалось подключиться к Photon: %s" % error)


func _on_room_joined() -> void:
	print("MatchManager: вошёл в комнату, мастер=%s, pid=%d"
		% [str(Fusion.is_master_client()), Fusion.get_local_player_id()])
	if Fusion.is_master_client():
		# Хост (сервер) спавнит собственного игрока.
		_spawn_player(Fusion.get_local_player_id())
	else:
		# Клиент просит сервер заспавнить его (broadcast-RPC).
		Fusion.rpc(request_spawn)
		# На всякий случай: если сервер не ответил (например, он ещё
		# не зарегистрировал спавнер), повторяем запрос через секунду.
		_retry_spawn_request.call_deferred()


func _retry_spawn_request() -> void:
	# Один повтор с паузой — дешевле, чем молча стоять без персонажа.
	await get_tree().create_timer(1.0).timeout
	if not is_instance_valid(self) or not Fusion.is_in_room():
		return
	if _has_local_player():
		return
	print("MatchManager: повторяю запрос спавна")
	Fusion.rpc(request_spawn)


func _has_local_player() -> bool:
	return get_tree().get_first_node_in_group(Player.GROUP_LOCAL_PLAYER) != null


@rpc("any_peer", "call_local")
func request_spawn() -> void:
	# Вызывается на сервере (и локально у отправителя — call_local).
	# Спавнит только master client.
	if not Fusion.is_master_client():
		return
	_spawn_player(Fusion.get_rpc_sender())


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
	if Fusion.is_master_client() and _spawned_for.has(player_id):
		spawner.despawn(_spawned_for[player_id])
		_spawned_for.erase(player_id)


func _spawn_player(player_id: int) -> void:
	if _spawned_for.has(player_id):
		return
	var player := spawner.spawn() as Player
	if player == null:
		push_error("MatchManager: спавнер вернул не Player.")
		return
	player.position = Vector3(randf_range(-3.0, 3.0), 1.0, randf_range(-3.0, 3.0))
	var rep := player.get_node("FusionServerReplicator") as FusionServerReplicator
	rep.set_input_authority(player_id)
	_spawned_for[player_id] = player
	print("MatchManager: спавн игрока для pid=%d (input_authority выдан)" % player_id)

	# Если этот игрок — я сам, включаем ему локальное управление и камеру.
	if player_id == Fusion.get_local_player_id():
		player.setup_local_player()
	else:
		# Иначе просим его машину включить камеру/мышь сама.
		Fusion.rpc_to_player(player_id, claim_local_player, player)
