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

	# Подключаемся к Photon Cloud; затем создаём/входим в комнату.
	Fusion.connected_to_photon.connect(_on_connected)
	Fusion.connect_to_photon.call_deferred("user_%d" % randi())


func _exit_tree() -> void:
	# Обязательно отписываемся: иначе у Fusion останется висячая ссылка и краш (см. доку RPC).
	if Fusion:
		Fusion.unregister_broadcast_receiver(self)


func _on_connected() -> void:
	Fusion.join_or_create_room()


func _on_connection_failed(error: String) -> void:
	push_error("MatchManager: не удалось подключиться к Photon: %s" % error)


func _on_room_joined() -> void:
	if Fusion.is_master_client():
		# Хост (сервер) спавнит собственного игрока.
		_spawn_player(Fusion.get_local_player_id())
	else:
		# Клиент просит сервер заспавнить его (broadcast-RPC).
		Fusion.rpc(request_spawn)


@rpc("any_peer", "call_local")
func request_spawn() -> void:
	# Вызывается на сервере (и локально у отправителя — call_local).
	# Спавнит только master client.
	if not Fusion.is_master_client():
		return
	_spawn_player(Fusion.get_rpc_sender())


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

	# Если этот игрок — я сам, включаем ему локальное управление и камеру.
	# (На клиентских машинах свой персонаж настраивается сам, см. player.gd.)
	if player_id == Fusion.get_local_player_id():
		player.setup_local_player()
