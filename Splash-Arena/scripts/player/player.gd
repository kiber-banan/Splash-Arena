class_name Player
extends CharacterBody3D
## Игрок-дайвер (FPS) в топологии Fusion Client-Server.
##
## Сеть:
##  - Реплицируется через FusionServerReplicator (в сцене player.tscn).
##  - Режимы репликатора (owner_mode = PLAYER_PREDICTED,
##    root_replication_mode = AUTO) выставляются скриптом в _enter_tree()
##    по ИМЕНАМ из документации — так не страшна смена порядка enum
##    в будущих версиях SDK. Значения в .tscn — запасной вариант.
##  - Клиент с input-authority каждый physics tick упаковывает свой ввод
##    (движение + yaw взгляда) и шлёт его на сервер через
##    queue_input(delta, buf). Тот же ввод локально исполняется
##    в предсказании, а на сервере — авторитетно.
##  - Yaw взгляда едет ВНУТРИ ввода, поэтому сервер и предсказание
##    двигаются в одну сторону. Pitch камеры — чисто локальный
##    (на симуляцию не влияет).

const MOVE_SPEED := 6.0        # м/с, горизонталь
const VERT_SPEED := 4.0        # м/с, вертикаль (всплытие/погружение)
const LOOK_SENS := 0.003       # чувствительность мыши
const PITCH_LIMIT := 1.35      # ~77°, предел наклона камеры
const INPUT_SIZE := 20         # байт: x, y, vertical, yaw (float) + tick (u32)

@onready var camera_rig: Camera3D = $CameraRig
@onready var replicator: FusionServerReplicator = $FusionServerReplicator

var _input_tick: int = 0
var _is_local_player := false
var _yaw := 0.0
var _pitch := 0.0


func _enter_tree() -> void:
	# Ставим режимы раньше _ready() репликатора — аналогично значениям из инспектора.
	_apply_replicator_modes()


func _ready() -> void:
	# Сигнал Fusion: ввод приходит и на предсказание (клиент), и на сервер.
	replicator.on_process_input.connect(_on_fusion_input)


func setup_local_player() -> void:
	## Вызывается для персонажа, которым управляет игрок на этой машине.
	if _is_local_player:
		return
	_is_local_player = true
	_yaw = rotation.y
	camera_rig.current = true
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _exit_tree() -> void:
	if _is_local_player:
		_is_local_player = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _unhandled_input(event: InputEvent) -> void:
	if not _is_local_player:
		return
	if event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		_yaw = fwrap(_yaw - motion.relative.x * LOOK_SENS, -PI, PI)
		_pitch = clampf(_pitch - motion.relative.y * LOOK_SENS, -PITCH_LIMIT, PITCH_LIMIT)
		camera_rig.rotation.x = _pitch


func _physics_process(delta: float) -> void:
	# Свой персонаж на клиенте появляется по сети (мастер его не настраивает
	# на нашей машине), поэтому локальную настройку делаем лениво сами.
	if not _is_local_player and replicator.has_input_authority():
		setup_local_player()
	# Ввод отправляем ТОЛЬКО с клиента, у которого input-authority.
	if replicator.has_input_authority():
		replicator.queue_input(delta, _create_input())
	# process_input_queue(delta) вызывает on_process_input:
	#  - на сервере   -> авторитетное исполнение
	#  - на клиенте   -> предсказание (и повторное исполнение при коррекции)
	#  - у наблюдателя-> no-op
	replicator.process_input_queue(delta)


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
	_input_tick += 1
	return buf


func _on_fusion_input(_tick: int, _delta_time: float, payload: PackedByteArray, _is_new: bool) -> void:
	# Ввод исполняется одинаково на сервере и в предсказании клиента.
	if payload.size() < INPUT_SIZE:
		return
	var input_x := payload.decode_float(0)  # +1 = D (вправо)
	var input_y := payload.decode_float(4)  # -1 = W (вперёд), +1 = S (назад)
	var vertical := payload.decode_float(8)  # +1 = вверх (Space)
	var yaw := payload.decode_float(12)

	rotation.y = yaw

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

	# Камера локального игрока повторяет авторитетное положение тела,
	# чтобы предсказание и коррекция не расходились с картинкой.
	if _is_local_player:
		camera_rig.global_position = global_position


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
