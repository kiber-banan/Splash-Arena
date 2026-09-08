class_name Player
extends CharacterBody3D
## Игрок-дайвер (FPS) в топологии Fusion Client-Server.
##
## Сеть:
##  - Реплицируется через FusionServerReplicator (в сцене player.tscn).
##  - Режимы репликатора (owner_mode = PLAYER_PREDICTED,
##    root_replication_mode = AUTO) выставляются скриптом и в _enter_tree(),
##    и в _ready() — по ИМЕНАМ из документации, так не страшна смена
##    порядка enum в будущих версиях SDK. Значения в .tscn — запасной вариант.
##  - Клиент с input-authority каждый physics tick упаковывает свой ввод
##    (движение + yaw/pitch взгляда) и шлёт его на сервер через
##    queue_input(delta, buf). Тот же ввод локально исполняется
##    в предсказании, а на сервере — авторитетно.
##  - Yaw/pitch взгляда едут ВНУТРИ ввода, поэтому сервер и предсказание
##    смотрят в одну сторону (это же понадобится для хитскана оружия).
##
## Локальный игрок (камера + захват мыши) настраивается тремя путями —
## любой сработает, все идемпотентны:
##  1. мастер вызывает setup_local_player() сразу после set_input_authority();
##  2. мастер шлёт RPC claim_local_player(player) на машину владельца;
##  3. сам персонаж ловит has_input_authority() в _physics_process.
## Тройная страховка — потому что «игрок стоит, камера не крутится»
## почти всегда означает, что ни один из этих путей не сработал.

const MOVE_SPEED := 6.0        # м/с, горизонталь
const VERT_SPEED := 4.0        # м/с, вертикаль (всплытие/погружение)
const LOOK_SENS := 0.003       # чувствительность мыши
const PITCH_LIMIT := 1.35      # ~77°, предел наклона камеры
const EYE_HEIGHT := 1.7        # высота глаз — откуда смотрит камера
## Раскладка пакета ввода (байты):
##   0  float  move_x    (+1 = D, вправо)
##   4  float  move_y    (-1 = W, вперёд)
##   8  float  vertical  (+1 = Space, вверх)
##   12 float  yaw       (поворот корпуса)
##   16 u32    tick      (счётчик пакетов, для ловли потерь)
##   20 float  pitch     (наклон взгляда)
const INPUT_SIZE := 24
const GROUP_LOCAL_PLAYER := "local_player"
const GROUP_PREVIEW_CAMERA := "preview_camera"

@onready var camera_rig: Camera3D = $CameraRig
@onready var replicator: FusionServerReplicator = $FusionServerReplicator

# --- диагностика (показывается в HUD, шаг 1) ---
var debug_inputs_sent := 0
var debug_inputs_executed := 0
var debug_last_dir := Vector2.ZERO

var _input_tick: int = 0
var _is_local_player := false
var _yaw := 0.0
var _pitch := 0.0


func _enter_tree() -> void:
	# Ставим режимы до _ready() репликатора.
	_apply_replicator_modes()


func _ready() -> void:
	# И ещё раз здесь: если SDK сбрасывает режим при инициализации узла,
	# вторая установка это перекроет (значения одинаковые, побочек нет).
	_apply_replicator_modes()
	# Сигнал Fusion: ввод приходит и на предсказание (клиент), и на сервер.
	if not replicator.on_process_input.is_connected(_on_fusion_input):
		replicator.on_process_input.connect(_on_fusion_input)


func setup_local_player() -> void:
	## Вызывается для персонажа, которым управляет игрок на этой машине.
	if _is_local_player:
		return
	_is_local_player = true
	_yaw = rotation.y
	if not is_in_group(GROUP_LOCAL_PLAYER):
		add_to_group(GROUP_LOCAL_PLAYER)
	camera_rig.current = true
	camera_rig.rotation.x = _pitch
	_disable_preview_cameras()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	print(
		"Player: локальный игрок готов (pid=%d, input_authority=%s, state_authority=%s, owner_mode=%d, root_replication_mode=%d)"
		% [
			Fusion.get_local_player_id(),
			str(replicator.has_input_authority()),
			str(replicator.has_authority()),
			int(replicator.owner_mode),
			int(replicator.root_replication_mode),
		]
	)


func is_local_player() -> bool:
	return _is_local_player


func get_eye_position() -> Vector3:
	## Точка, из которой смотрит/стреляет игрок (совпадает с камерой).
	return global_position + Vector3(0.0, EYE_HEIGHT, 0.0)


func get_aim_direction() -> Vector3:
	## Направление взгляда из yaw/pitch — одинаково на клиенте и сервере.
	return Vector3.FORWARD.rotated(Vector3.RIGHT, _pitch).rotated(Vector3.UP, _yaw)


func _exit_tree() -> void:
	if _is_local_player:
		_is_local_player = false
		if is_in_group(GROUP_LOCAL_PLAYER):
			remove_from_group(GROUP_LOCAL_PLAYER)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if not _is_local_player:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_yaw = wrapf(_yaw - motion.relative.x * LOOK_SENS, -PI, PI)
		_pitch = clampf(_pitch - motion.relative.y * LOOK_SENS, -PITCH_LIMIT, PITCH_LIMIT)
		camera_rig.rotation.x = _pitch


func _physics_process(delta: float) -> void:
	# Свой персонаж на клиенте появляется по сети (мастер его не настраивает
	# на нашей машине), поэтому локальную настройку делаем лениво сами.
	if not _is_local_player:
		_try_setup_local()
	# Ввод отправляем ТОЛЬКО с клиента, у которого input-authority.
	if replicator.has_input_authority():
		replicator.queue_input(delta, _create_input())
	# process_input_queue(delta) вызывает on_process_input:
	#  - на сервере   -> авторитетное исполнение
	#  - на клиенте   -> предсказание (и повторное исполнение при коррекции)
	#  - у наблюдателя-> no-op
	replicator.process_input_queue(delta)


func _try_setup_local() -> void:
	## Третий путь настройки локального игрока (см. шапку файла).
	if not is_inside_tree() or not Fusion.is_initialized():
		return
	var local_id := Fusion.get_local_player_id()
	if local_id <= 0:
		return
	if replicator.has_input_authority() or replicator.get_input_authority() == local_id:
		setup_local_player()


func _create_input() -> PackedByteArray:
	var dir2 := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var vertical := 0.0
	if Input.is_action_pressed("ascend"):
		vertical = 1.0
	elif Input.is_action_pressed("descend"):
		vertical = -1.0

	var buf := PackedByteArray()
	buf.resize(INPUT_SIZE)
	buf.encode_float(0, dir2.x)
	buf.encode_float(4, dir2.y)
	buf.encode_float(8, vertical)
	buf.encode_float(12, _yaw)
	buf.encode_u32(16, _input_tick)
	buf.encode_float(20, _pitch)
	_input_tick += 1
	debug_inputs_sent += 1
	debug_last_dir = dir2
	return buf


func _on_fusion_input(_tick: int, _delta_time: float, payload: PackedByteArray, _is_new: bool) -> void:
	# Ввод исполняется одинаково на сервере и в предсказании клиента.
	if payload.size() < INPUT_SIZE:
		return
	var input_x := payload.decode_float(0)   # +1 = D (вправо)
	var input_y := payload.decode_float(4)   # -1 = W (вперёд), +1 = S (назад)
	var vertical := payload.decode_float(8)  # +1 = вверх (Space)
	var yaw := payload.decode_float(12)
	var pitch := payload.decode_float(20)

	debug_inputs_executed += 1

	rotation.y = yaw
	# Корпус поворачивается по yaw везде; наклон головы — визуал,
	# на симуляцию не влияет (на сервере нужен только для хитскана).
	camera_rig.rotation.x = pitch
	if _is_local_player:
		_pitch = pitch

	# Направление относительно поворота персонажа (Yaw).
	var body_basis := global_transform.basis
	var forward := -input_y  # +1 = вперёд по взгляду
	var direction := -body_basis.z * forward + body_basis.x * input_x
	if direction.length() > 1.0:
		direction = direction.normalized()

	velocity = direction * MOVE_SPEED
	velocity.y = vertical * VERT_SPEED
	# Подводный бой: плавучесть и сопротивление воды пока игнорируем,
	# TODO: добавим физику воды (тяга, инерция) вместе с геймплеем.
	move_and_slide()


func _disable_preview_cameras() -> void:
	## Иначе после деспавна игрока вид переключится обратно на камеру арены.
	for node in get_tree().get_nodes_in_group(GROUP_PREVIEW_CAMERA):
		var cam := node as Camera3D
		if cam != null and cam != camera_rig:
			cam.current = false


func _apply_replicator_modes() -> void:
	var rep: Node = get_node_or_null("FusionServerReplicator")
	if rep == null:
		push_error("Player: нет узла FusionServerReplicator — проверь scenes/player/player.tscn")
		return
	_set_enum_by_label(rep, "owner_mode", ["PLAYER_PREDICTED"])
	_set_enum_by_label(rep, "root_replication_mode", ["AUTO", "REPLICATION_AUTO"])


static func _set_enum_by_label(node: Object, prop: String, wanted: Array) -> void:
	for d in node.get_property_list():
		if String(d.get("name", "")) != prop:
			continue
		var hint := String(d.get("hint_string", ""))
		var index := _match_enum_index(hint, wanted)
		if index < 0:
			push_error("Player: не нашёл %s среди значений '%s' (hint: '%s'). Выставь режим вручную в инспекторе." % [wanted, prop, hint])
			return
		if int(node.get(prop)) != index:
			node.set(prop, index)
		return
	push_error("Player: у FusionServerReplicator нет свойства '%s'. Совпадает ли версия Fusion SDK?" % prop)


static func _match_enum_index(hint: String, wanted: Array) -> int:
	## Ищет индекс значения в enum-hint'е вида "None,Auto" или "None:0,Auto:1".
	var want_norm: Array = []
	for w in wanted:
		want_norm.append(_norm_enum_label(String(w)))
	var parts := hint.split(",", false)
	for i in parts.size():
		var chunks := parts[i].strip_edges().split(":", true, 1)
		var value := i
		if chunks.size() > 1:
			value = int(chunks[1])
		if _norm_enum_label(chunks[0]) in want_norm:
			return value
	return -1


static func _norm_enum_label(s: String) -> String:
	return s.to_upper().replace("_", "").replace(" ", "")
