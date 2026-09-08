extends Node3D
## Менеджер матча: подключение к Photon, вход в комнату,
## спавн игроков по схеме Client-Server (сервер = master client).
##
## Схема (по доке Fusion Godot Client-Server):
##  - Кто создал комнату -> тот master client (= simulation server).
##  - Сервер спавнит своего игрока сразу, чужих — по RPC-запросу.
##  - Client-host: обычный запуск игры — один из игроков и сервер, и играет.
##  - Позже можно собрать отдельный выделенный сервер (headless) —
##    код спавна не поменяется.

const PlayerScene := preload("res://scenes/player/player.tscn")

@onready var spawner: Node = $FusionSpawner
@onready var players_root: Node3D = $Players

var _spawned_for: Dictionary = {}  # player_id -> Player

func _ready() -> void:
	Fusion.room_joined.connect(_on_room_joined)
	Fusion.player_left.connect(_on_player_left)
	Fusion.register_broadcast_receiver(self)
	spawner.add_spawnable_scene(PlayerScene)

	var app_id := AppConfig.get_app_id()
	if app_id.is_empty():
		push_error("MatchManager: нет Fusion App ID. Настрой config/secret.cfg (см. README).")
		return
	Fusion.set_app_id(app_id)

	# Подключаемся к Photon Cloud; затем создаём/входим в комнату.
	Fusion.connected_to_photon.connect(func() -> void:
		Fusion.join_or_create_room()
	)
	Fusion.connect_to_photon.call_deferred("user_%d" % randi())

func _on_room_joined() -> void:
	if Fusion.is_master_client():
		# Хост (сервер) спавнит собственного игрока.
		_spawn_player(Fusion.get_local_player_id())
	# Клиенты запрашивают спавн у сервера через broadcast-RPC.

@rpc("any_peer", "call_local")
func request_spawn() -> void:
	# Вызывается на сервере (и локально у отправителя — call_local).
	# Спавнит только master client.
	if not Fusion.is_master_client():
		return
	_spawn_player(Fusion.get_rpc_sender())

func _on_player_left(player_id: int, is_inactive: bool) -> void:
	if Fusion.is_master_client() and _spawned_for.has(player_id):
		_spawned_for[player_id].queue_free()
		_spawned_for.erase(player_id)

func _spawn_player(player_id: int) -> void:
	if _spawned_for.has(player_id):
		return
	var player := spawner.spawn()
	players_root.add_child(player)
	player.position = Vector3(randf_range(-3.0, 3.0), 1.0, randf_range(-3.0, 3.0))
	player.get_node("FusionServerReplicator").set_input_authority(player_id)
	_spawned_for[player_id] = player

	# Если этот игрок — я сам, включаем ему локальное управление и камеру.
	if player_id == Fusion.get_local_player_id():
		player.setup_local_player()
