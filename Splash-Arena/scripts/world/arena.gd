extends StaticBody3D
## Управляемый «полигон» для теста: подводная пещера.
## Позже заменим на полноценный уровень (модели, киты, каустика).
##
## Арена строится одинаково на всех пирах: раскладка колонн берётся
## из локального генератора с фиксированным сидом (арена не сетевая,
## но физика обязана совпадать, иначе сервер и клиенты разъедутся).

const LAYOUT_SEED := 424242
## Каустика на дне: свет с поверхности, собранный волнами.
const CAUSTICS_SHADER := preload("res://shaders/water/caustics.gdshader")

@export var _box_material: Material

var _arena_center := Vector3.ZERO


func _ready() -> void:
	build_arena()


func build_arena() -> void:
	_clear_children()
	_arena_center = global_position
	var size := 30.0
	var rng := RandomNumberGenerator.new()
	rng.seed = LAYOUT_SEED

	var mat := _box_material
	if mat == null:
		var fallback := StandardMaterial3D.new()
		fallback.albedo_color = Color(0.36, 0.43, 0.5)
		fallback.roughness = 0.9
		mat = fallback

	# Дно: песок с бегающими бликами каустики.
	_add_box(Vector3(size * 2.0, 1.0, size * 2.0), _arena_center + Vector3(0, -8.5, 0), _make_sand_material())

	# Стены-скалы по периметру: не дают уплыть за арену.
	for i in 4:
		var offset := Vector3.ZERO
		var box_size := Vector3(1.0, 16.0, 1.0)
		if i == 0:  # север
			offset = Vector3(0, 0, -size / 2.0)
			box_size = Vector3(size, 16.0, 2.0)
		elif i == 1:  # юг
			offset = Vector3(0, 0, size / 2.0)
			box_size = Vector3(size, 16.0, 2.0)
		elif i == 2:  # запад
			offset = Vector3(-size / 2.0, 0, 0)
			box_size = Vector3(2.0, 16.0, size)
		else:  # восток
			offset = Vector3(size / 2.0, 0, 0)
			box_size = Vector3(2.0, 16.0, size)
		_add_box(box_size, _arena_center + offset, mat)

	# Несколько колонн-камней внутри: укрытия для перестрелок.
	for i in 5:
		var rnd_pos := Vector3(rng.randf_range(-10.0, 10.0), 0.0, rng.randf_range(-10.0, 10.0))
		_add_box(Vector3(2.0 + rng.randf(), 9.0, 2.0 + rng.randf()), _arena_center + rnd_pos + Vector3(0, 0.5, 0), mat)


static func _make_sand_material() -> Material:
	## Песок + каустика. Если шейдер не соберётся — просто светлый песок.
	var sm := ShaderMaterial.new()
	sm.shader = CAUSTICS_SHADER
	if sm.shader != null:
		return sm
	var fallback := StandardMaterial3D.new()
	fallback.albedo_color = Color(0.42, 0.45, 0.40)
	fallback.roughness = 0.95
	return fallback


func _add_box(box_size: Vector3, position: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = box_size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = position
	mi.material_override = material
	add_child(mi)

	var shape := BoxShape3D.new()
	shape.size = box_size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = position
	add_child(cs)


func _clear_children() -> void:
	for child in get_children():
		child.queue_free()
