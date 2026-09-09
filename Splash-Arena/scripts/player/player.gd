class_name Player
extends CharacterBody3D
## Игрок-дайвер (FPS) в топологии Fusion Client-Server.
##
## СПАВН: спавнит ТОЛЬКО хост (master client). Клиент не создаёт свой
## аватар сам, а просит хост: Fusion.rpc(request_spawn, character_id).
## Хост спавнит, выдаёт set_input_authority() и объектным RPC сообщает
## аватару, чей он (set_owner_player) — на машине владельца это включает
## камеру и захват мыши.
##
## ЛОКАЛЬНЫЙ ИГРОК (камера + захват мыши + ввод) включается тремя путями,
## все идемпотентны и срабатывают хоть один, хоть все сразу:
##  1. хост вызывает setup_local_player() сразу после спавна (свой аватар);
##  2. object-RPC set_owner_player(pid) — доезжает до этого же аватара на
##     всех пирах, на машине владельца включает камеру (основной путь);
##  3. само-детект _try_setup_local() в _ready/_physics_process по
##     has_input_authority() — работает, если authority выдана до _ready().
##
## ВАЖНО: input authority хост выдаёт через pre_spawn_function (см.
## MatchManager._spawn_with_input_authority). Назначение ПОСЛЕ спавна Fusion
## молча игнорирует — тогда has_input_authority() = false даже у хоста.
##
## ДВИЖЕНИЕ: вода. Скорость не ставится мгновенно — есть разгон и
## инерция: velocity плавно тянется к целевой (MOVE_ACCEL), а когда ввода
## нет — вода гасит скорость (MOVE_DRAG). Формула exp(-rate * delta)
## одинакова на сервере и в предсказании при любом delta.
##
## Если предсказание Fusion по какой-то причине не исполняет ввод
## (on_process_input не приходит), локальный игрок всё равно двигается:
## включается локальная симуляция (см. _physics_process) и в HUD-дебаге
## появляется метка «ЛОКАЛЬНАЯ СИМУЛЯЦИЯ» — это сигнал чинить сеть.
##
## Оружие (шаг 3): выстрел — бит BUTTON_FIRE во вводе, исполнение в
## process_input; урон считает ТОЛЬКО сервер (рейкаст от глаз), жертве
## уходит object-RPC take_damage(), хит-маркер — rpc_to_player() стрелку.

const LOOK_SENS := 0.003       # чувствительность мыши
const PITCH_LIMIT := 1.35      # ~77°, предел наклона камеры
const EYE_HEIGHT := 1.7        # высота глаз — откуда смотрит камера и бьёт гарпун

const VERT_SPEED := 4.5        # м/с, вертикаль (всплытие/погружение)
const MOVE_ACCEL := 9.0        # разгон в воде (1/с)
const MOVE_DRAG := 3.5         # как вода гасит скорость без ввода (1/с)
const PREDICTION_DEAD_MS := 400  # если ввод не исполнялся дольше — включаем локальную симуляцию

const WEAPON_DAMAGE := 25      # урон гарпуна
const FIRE_COOLDOWN := 0.35    # сек между выстрелами
const WEAPON_RANGE := 120.0    # дальность хитскана

## Раскладка пакета ввода (байты):
##   0  float  move_x    (+1 = D, вправо)
##   4  float  move_y    (-1 = W, вперёд)
##   8  float  vertical  (+1 = Space, вверх)
##   12 float  yaw       (поворот корпуса)
##   16 u32    tick      (счётчик пакетов, для ловли потерь)
##   20 float  pitch     (наклон взгляда)
##   24 u8     buttons   (бит 0 — огонь, бит 1 — способность)
##   25..31              резерв (нули), чтобы пакет был ровно 32 байта
const INPUT_SIZE := 32
const BUTTON_FIRE := 1
const BUTTON_ABILITY := 2

## Кто я по классу. Константы дублируют Characters, но player.gd НЕ должен
## зависеть от characters.gd: иначе цикл
## player.gd -> Characters -> preload(player_medic.tscn) -> player.gd.
const CHARACTER_ASSAULT := 0
const CHARACTER_MEDIC := 1
const CHARACTER_SCOUT := 2

const GROUP_LOCAL_PLAYER := "local_player"
const GROUP_ALL := "players"            # все аватары в мире (и чужие тоже)
const GROUP_PREVIEW_CAMERA := "preview_camera"
const GROUP_EFFECTS := "effects"
const GROUP_SPAWN_POINTS := "spawn_points"

## Статы персонажа. Значения ниже — дефолт («Штурмовик»); настоящие
## статы лежат в трёх сценах-наследниках: player_assault / player_medic /
## player_scout. Скрипт у всех один, спавнер выбирает сцену по character_id.
@export var character_id := CHARACTER_ASSAULT
@export var character_name := "Штурмовик"
@export var max_hp := 100
@export var move_speed := 6.0            # м/с, горизонталь
@export var suit_color := Color(1.0, 0.45, 0.12, 1.0)
@export var ability_name := "Рывок"
@export var ability_cooldown := 5.0      # сек, кулдаун способности
@export var ability_duration := 0.25     # сек, сколько действует эффект
@export var ability_speed_multiplier := 3.0  # множитель скорости (рывок/ускорение)
@export var ability_heal := 0            # HP, сколько лечит медик

@onready var camera_rig: Camera3D = $CameraRig
@onready var replicator: FusionServerReplicator = $FusionServerReplicator

# --- состояние, которое видно в HUD ---
var hp: int = 100
var deaths: int = 0
# --- диагностика (показывается в HUD) ---
var debug_inputs_sent := 0
var debug_inputs_executed := 0
var debug_last_dir := Vector2.ZERO
var debug_local_sim := false      # true = предсказание Fusion молчит, двигаем сами
var debug_owner_pid := 0          # кому хост отдал этот аватар

var _input_tick: int = 0
var _is_local_player := false
var _yaw := 0.0
var _pitch := 0.0
var _fire_cooldown := 0.0
var _ability_cooldown_left := 0.0
var _ability_time_left := 0.0
var _owner_player_id := 0
var _last_input := PackedByteArray()
var _last_input_exec_ms := 0


func _enter_tree() -> void:
	# Ставим режимы до _ready() репликатора.
	_apply_replicator_modes()


func _ready() -> void:
	# И ещё раз здесь: если SDK сбрасывает режим при инициализации узла,
	# вторая установка это перекроет (значения одинаковые, побочек нет).
	_apply_replicator_modes()
	if not replicator.on_process_input.is_connected(_on_fusion_input):
		replicator.on_process_input.connect(_on_fusion_input)
	hp = max_hp
	_apply_suit_color()
	if not is_in_group(GROUP_ALL):
		add_to_group(GROUP_ALL)
	_try_setup_local()


func setup_local_player() -> void:
	## Включает камеру, захват мыши и локальное управление этим аватаром.
	if _is_local_player:
		return
	_is_local_player = true
	_owner_player_id = Fusion.get_local_player_id()
	debug_owner_pid = _owner_player_id
	_yaw = rotation.y
	if not is_in_group(GROUP_LOCAL_PLAYER):
		add_to_group(GROUP_LOCAL_PLAYER)
	camera_rig.current = true
	camera_rig.rotation.x = _pitch
	_disable_preview_cameras()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	print(
		"Player: локальный игрок готов (pid=%d, input_authority=%s, state_authority=%s, authority_pid=%d, owner_mode=%d, root_replication_mode=%d)"
		% [
			Fusion.get_local_player_id(),
			str(replicator.has_input_authority()),
			str(replicator.has_authority()),
			replicator.get_input_authority(),
			int(replicator.owner_mode),
			int(replicator.root_replication_mode),
		]
	)


@rpc("any_peer", "call_local")
func set_owner_player(player_id: int) -> void:
	## Object-RPC: выполняется на ЭТОМ ЖЕ аватаре на всех пирах (Fusion
	## маршрутизирует вызов через репликатор). На машине владельца это
	## включает камеру и захват мыши — не надеясь на has_input_authority().
	_owner_player_id = player_id
	debug_owner_pid = player_id
	if player_id == Fusion.get_local_player_id():
		setup_local_player()


func is_local_player() -> bool:
	return _is_local_player


func get_eye_position() -> Vector3:
	## Точка, из которой смотрит/стреляет игрок (совпадает с камерой).
	return global_position + Vector3(0.0, EYE_HEIGHT, 0.0)


func get_aim_direction() -> Vector3:
	## Направление взгляда из yaw/pitch — одинаково на клиенте и сервере.
	return Vector3.FORWARD.rotated(Vector3.RIGHT, _pitch).rotated(Vector3.UP, _yaw)


static func random_spawn_position(tree: SceneTree) -> Vector3:
	## Случайная точка респауна (ноды-маркеры в группе spawn_points).
	var holder := tree.get_first_node_in_group(GROUP_SPAWN_POINTS) as Node3D
	if holder != null and holder.get_child_count() > 0:
		var marker := holder.get_child(randi() % holder.get_child_count()) as Node3D
		if marker != null:
			return marker.global_position
	return Vector3(0.0, 1.5, 0.0)


func _exit_tree() -> void:
	if is_in_group(GROUP_ALL):
		remove_from_group(GROUP_ALL)
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
	if not _is_local_player:
		_try_setup_local()
	# Ввод отправляем только за свой аватар: has_input_authority() — норма,
	# но если флаг по какой-то причине не взвёлся, ориентируемся на
	# get_input_authority() (чей это аватар по версии сервера).
	var has_input_authority := (
		replicator.has_input_authority()
		or replicator.get_input_authority() == Fusion.get_local_player_id()
	)
	if _is_local_player and has_input_authority:
		_last_input = _create_input()
		replicator.queue_input(delta, _last_input)
	# process_input_queue(delta) вызывает on_process_input:
	#  - на сервере   -> авторитетное исполнение
	#  - на клиенте   -> предсказание (и повтор при коррекции)
	#  - у наблюдателя-> no-op
	replicator.process_input_queue(delta)
	# Страховка: если предсказание Fusion не исполняет ввод, двигаем аватара
	# сами (иначе локальный игрок просто стоит). В HUD это видно как
	# «ЛОКАЛЬНАЯ СИМУЛЯЦИЯ» — значит, надо чинить цепочку ввода.
	debug_local_sim = (
		_is_local_player
		and not _last_input.is_empty()
		and Time.get_ticks_msec() - _last_input_exec_ms > PREDICTION_DEAD_MS
	)
	if debug_local_sim:
		_apply_input(_last_input, delta)


func _try_setup_local() -> void:
	## Само-детект (3-й путь): если этот аватар наш — включаем камеру.
	if _is_local_player or not is_inside_tree() or not Fusion.is_initialized():
		return
	var local_id := Fusion.get_local_player_id()
	if local_id <= 0:
		return
	if (
		_owner_player_id == local_id
		or replicator.has_input_authority()
		or replicator.get_input_authority() == local_id
	):
		setup_local_player()


func _create_input() -> PackedByteArray:
	var dir2 := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var vertical := 0.0
	if Input.is_action_pressed("ascend"):
		vertical = 1.0
	elif Input.is_action_pressed("descend"):
		vertical = -1.0

	var buttons := 0
	if Input.is_action_pressed("fire"):
		buttons |= BUTTON_FIRE
	if Input.is_action_pressed("ability"):
		buttons |= BUTTON_ABILITY

	var buf := PackedByteArray()
	buf.resize(INPUT_SIZE)
	buf.encode_float(0, dir2.x)
	buf.encode_float(4, dir2.y)
	buf.encode_float(8, vertical)
	buf.encode_float(12, _yaw)
	buf.encode_u32(16, _input_tick)
	buf.encode_float(20, _pitch)
	buf.encode_u8(24, buttons)
	_input_tick += 1
	debug_inputs_sent += 1
	debug_last_dir = dir2
	return buf


func _on_fusion_input(_tick: int, delta_time: float, payload: PackedByteArray, is_new: bool) -> void:
	if payload.size() < INPUT_SIZE:
		return
	_last_input_exec_ms = Time.get_ticks_msec()
	_apply_input(payload, delta_time)
	_update_weapon(delta_time, payload.decode_u8(24), is_new)


func _apply_input(payload: PackedByteArray, delta: float) -> void:
	## Одна и та же логика на сервере, в предсказании и в локальной симуляции.
	var input_x := payload.decode_float(0)   # +1 = D (вправо)
	var input_y := payload.decode_float(4)   # -1 = W (вперёд), +1 = S (назад)
	var vertical := payload.decode_float(8)  # +1 = вверх (Space)
	var yaw := payload.decode_float(12)
	var pitch := payload.decode_float(20)

	debug_inputs_executed += 1

	# Yaw/pitch взгляда обновляем ВСЕГДА (не только у локального игрока):
	# сервер симулирует чужих дайверов и должен стрелять из их глаз.
	_yaw = yaw
	_pitch = pitch
	rotation.y = yaw
	camera_rig.rotation.x = pitch

	_update_ability(delta, payload.decode_u8(24))

	var body_basis := global_transform.basis
	var forward := -input_y  # +1 = вперёд по взгляду
	var direction := -body_basis.z * forward + body_basis.x * input_x
	if direction.length() > 1.0:
		direction = direction.normalized()
	_swim(direction, vertical, delta)


func _swim(direction: Vector3, vertical: float, delta: float) -> void:
	## Вода: плавный разгон по вводу и инерция, когда ввода нет.
	var desired := direction * get_current_speed()
	desired.y = vertical * VERT_SPEED
	var has_input := direction.length_squared() > 0.001 or absf(vertical) > 0.001
	var rate := MOVE_ACCEL if has_input else MOVE_DRAG
	# exp() — чтобы результат не зависел от величины delta (tick у сервера
	# и у клиента может отличаться).
	velocity = velocity.lerp(desired, clampf(1.0 - exp(-rate * delta), 0.0, 1.0))
	move_and_slide()


# ---------- оружие ----------

func _update_weapon(delta_time: float, buttons: int, is_new: bool) -> void:
	_fire_cooldown = maxf(_fire_cooldown - delta_time, 0.0)
	if (buttons & BUTTON_FIRE) != 0 and _fire_cooldown <= 0.0:
		_fire_cooldown = FIRE_COOLDOWN
		_shoot(is_new)


func get_fire_cooldown_ratio() -> float:
	return clampf(_fire_cooldown / FIRE_COOLDOWN, 0.0, 1.0)


func _shoot(is_new: bool) -> void:
	if not replicator.has_authority():
		# Клиент в предсказании: крутим кулдаун, но урон считает сервер.
		return
	var from := get_eye_position()
	var to := from + get_aim_direction() * WEAPON_RANGE

	# Трассер видят все. is_new отсекает повторное исполнение ввода
	# при пересимуляции после коррекции предсказания.
	if is_new:
		Fusion.rpc(show_shot, from, to)  # остальные пиры (call_remote)
		_spawn_tracer(from, to, true)    # себе — сразу, без RTT

	var world := get_world_3d()
	if world == null:
		return
	var space := world.direct_space_state
	if space == null:
		return
	# Глаза находятся внутри капсулы персонажа, поэтому себя надо
	# исключить явно — иначе гарпун упрется в собственный гидрокостюм.
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [self.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return
	var victim := _find_player(hit["collider"])
	if victim == null or victim == self:
		return
	Fusion.rpc(victim.take_damage, WEAPON_DAMAGE)
	# Хит-маркер нужен стрелку, а не жертве — шлём его машине стрелка.
	var shooter_id := replicator.get_input_authority()
	if shooter_id > 0:
		var hud := get_tree().get_first_node_in_group("hud")
		if hud != null and hud.has_method("notify_hit_confirmed"):
			Fusion.rpc_to_player(shooter_id, hud.notify_hit_confirmed)


@rpc("authority", "call_remote")
func show_shot(from: Vector3, to: Vector3) -> void:
	## Трассер у остальных пиров. Стреляющий рисует свой сам (в _shoot),
	## поэтому здесь call_remote — иначе у него будет два трассера.
	_spawn_tracer(from, to, true)


static func _find_player(collider: Variant) -> Player:
	var node := collider as Node
	while node != null:
		if node is Player:
			return node as Player
		node = node.get_parent()
	return null


func _spawn_tracer(from: Vector3, to: Vector3, with_flash: bool) -> void:
	var fx := get_tree().get_first_node_in_group(GROUP_EFFECTS)
	if fx == null:
		return
	var distance := from.distance_to(to)
	if distance < 0.01:
		return

	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.025
	mesh.bottom_radius = 0.025
	mesh.height = 1.0
	mesh.radial_segments = 5

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.95, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.95, 1.0)
	mat.emission_energy_multiplier = 2.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var tracer := MeshInstance3D.new()
	tracer.mesh = mesh
	tracer.material_override = mat
	tracer.cast_shadows = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Цилиндр смотрит вдоль оси Y, а Basis.looking_at даёт ось -Z:
	# доворачиваем на -90° вокруг X.
	var basis := Basis().looking_at((to - from).normalized(), Vector3.UP) * Basis(Vector3.RIGHT, -PI / 2.0)
	tracer.transform = Transform3D(basis, from + (to - from) * 0.5)
	tracer.scale = Vector3(1.0, distance, 1.0)
	fx.add_child(tracer)

	var tween := tracer.create_tween()
	tween.tween_property(mat, "albedo_color", Color(0.55, 0.95, 1.0, 0.0), 0.15)
	tween.tween_callback(tracer.queue_free)

	if with_flash:
		_spawn_muzzle_flash(from)


func _spawn_muzzle_flash(at: Vector3) -> void:
	var fx := get_tree().get_first_node_in_group(GROUP_EFFECTS)
	if fx == null:
		return
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 1.0, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.7, 1.0, 1.0)
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	var mesh := SphereMesh.new()
	mesh.radius = 0.16
	mesh.height = 0.32
	var flash := MeshInstance3D.new()
	flash.mesh = mesh
	flash.material_override = mat
	flash.cast_shadows = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flash.position = at
	fx.add_child(flash)

	var tween := flash.create_tween()
	tween.tween_property(mat, "albedo_color", Color(0.8, 1.0, 1.0, 0.0), 0.08)
	tween.tween_callback(flash.queue_free)


# ---------- способность (клавиша E) ----------
#
# Бит BUTTON_ABILITY едет в пакете ввода, исполняется в process_input:
# на сервере — авторитетно, у клиента — в предсказании.

func get_current_speed() -> float:
	if _ability_time_left > 0.0:
		return move_speed * ability_speed_multiplier
	return move_speed


func get_ability_cooldown_ratio() -> float:
	## 0 — только что использована, 1 — готова.
	if ability_cooldown <= 0.0:
		return 1.0
	return clampf(1.0 - _ability_cooldown_left / ability_cooldown, 0.0, 1.0)


func _update_ability(delta_time: float, buttons: int) -> void:
	_ability_cooldown_left = maxf(_ability_cooldown_left - delta_time, 0.0)
	_ability_time_left = maxf(_ability_time_left - delta_time, 0.0)
	if (buttons & BUTTON_ABILITY) != 0 and _ability_cooldown_left <= 0.0:
		_ability_cooldown_left = ability_cooldown
		_use_ability()


func _use_ability() -> void:
	match character_id:
		CHARACTER_MEDIC:
			# Лечение: применяем сразу на всех пирах (HP в HUD без задержки),
			# сервер вдогонку присылает авторитетное значение.
			hp = mini(hp + ability_heal, max_hp)
			if replicator.has_authority():
				Fusion.rpc(sync_vitals, hp, deaths)
		_:
			# Штурмовик (рывок) и разведчик (ускорение): множитель скорости
			# на время ability_duration, направление берётся из ввода.
			_ability_time_left = ability_duration


# ---------- здоровье, смерть, респаун ----------

@rpc("any_peer", "call_local")
func take_damage(amount: int) -> void:
	## Object-RPC: сервер вызывает его на узле жертвы, выполняется на всех
	## пирах (call_local) — поэтому HP в HUD обновляется без отдельной
	## репликации свойства.
	hp = maxi(hp - amount, 0)
	if is_local_player():
		# Красная вспышка — сразу, не дожидаясь sync_vitals.
		var hud := get_tree().get_first_node_in_group("hud")
		if hud != null and hud.has_method("notify_local_damaged"):
			hud.notify_local_damaged()
	if not replicator.has_authority():
		return
	# Дальше — только сервер: он решает, кто умер.
	if hp <= 0:
		deaths += 1
		hp = max_hp
		global_position = random_spawn_position(get_tree())
		velocity = Vector3.ZERO
		print("Player: pid=%d погиб (смертей: %d), респаун" % [replicator.get_input_authority(), deaths])
	Fusion.rpc(sync_vitals, hp, deaths)


@rpc("any_peer", "call_local")
func sync_vitals(new_hp: int, new_deaths: int) -> void:
	## Авторитетные HP/смерти от сервера: после урона и после респауна.
	hp = new_hp
	deaths = new_deaths


# ---------- служебное ----------

func _apply_suit_color() -> void:
	## Красим гидрокостюм в цвет персонажа. Материал дублируем — иначе
	## все игроки покрасятся в цвет последнего заспавненного.
	var body := $BodyMesh as MeshInstance3D
	if body == null:
		return
	var mat := body.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
	else:
		mat = mat.duplicate() as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = suit_color
	body.set_surface_override_material(0, mat)


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
