extends CharacterBody3D
## Игрок-дайвер (FPS) в топологии Fusion Client-Server.
##
## Сеть:
##  - Реплицируется через FusionServerReplicator (в сцене player.tscn).
##  - Клиент с input-authority каждые physics tick упаковывает свой ввод
##    и шлёт его на сервер через queue_input(). Тот же ввод локально
##    исполняется в предсказании (is_new), а на сервере — авторитетно.
##  - Локальный игрок сам управляет своей камерой (только на своей машине),
##    это не сетевой объект.

const MOVE_SPEED := 6.0        # м/с, горизонталь (по течению игры подстроим)
const VERT_SPEED := 4.0        # м/с, вертикаль (всплытие/погружение)
const LOOK_SENS := 0.003       # чувствительность мыши

@onready var camera_rig: Node3D = $CameraRig
@onready var replicator: Node = $FusionServerReplicator

var _input_tick: int = 0
var _is_local_player := false

func _ready() -> void:
	# Сигнал Fusion: ввод приходит и на предсказание (клиент), и на сервер.
	replicator.on_process_input.connect(_on_fusion_input)

func setup_local_player() -> void:
	## Вызывается менеджером матча на машине игрока, который владеет этим игроком.
	_is_local_player = true
	camera_rig.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func has_input_authority() -> bool:
	return replicator.has_input_authority()

func _unhandled_input(event: InputEvent) -> void:
	if not _is_local_player:
		return
	if event is InputEventMouseMotion:
		camera_rig.rotate_y(-event.relative.x * LOOK_SENS)
		# TODO: ограничить наклон камеры по вертикали (clamp pitch).

func _physics_process(_delta: float) -> void:
	# Ввод отправляем ТОЛЬКО с клиента, у которого input-authority.
	if has_input_authority():
		replicator.queue_input(_create_input())
	# process_input_queue() вызывает on_process_input:
	#  - на сервере   -> авторитетное исполнение
	#  - на клиенте   -> предсказание (и повторное исполнение при коррекции)
	#  - у наблюдателя-> no-op
	replicator.process_input_queue()

func _create_input() -> PackedByteArray:
	var dir2 := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var vertical := 0.0
	if Input.is_action_pressed("ascend"):
		vertical = 1.0
	elif Input.is_action_pressed("descend"):
		vertical = -1.0

	var buf := PackedByteArray()
	buf.resize(12)
	buf.encode_float(0, dir2.x)
	buf.encode_float(4, dir2.y)
	buf.encode_float(8, vertical)
	_input_tick += 1
	return buf

func _on_fusion_input(tick: int, delta_time: float, payload: PackedByteArray, is_new: bool) -> void:
	# Ввод исполняется одинаково на сервере и в предсказании клиента.
	var move_x := payload.decode_float(0)
	var move_z := payload.decode_float(4)  # +1 = вперёд по взгляду
	var vertical := payload.decode_float(8)

	# Направление относительно поворота персонажа (Yaw).
	var basis := global_transform.basis
	var direction := (basis.z * -move_z + basis.x * move_x).normalized()

	velocity = direction * MOVE_SPEED
	velocity.y = vertical * VERT_SPEED
	# Подводный бой: плавучесть и сопротивление воды пока игнорируем,
	# TODO: добавим физику воды (тяга, инерция) вместе с геймплеем.
	move_and_slide()

	# Камера локального игрока повторяет авторитетное положение тела,
	# чтобы предсказание и коррекция не расходились с картинкой.
	if _is_local_player:
		camera_rig.global_position = global_position
