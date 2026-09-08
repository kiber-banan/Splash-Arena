extends StaticBody3D
## Управляемый «полигон» для теста: подводная пещера.
## Позже заменим на полноценный уровень (модели, киты, каустика).

@export var _box_material: Material

var _arena_center := Vector3.ZERO

func build_arena() -> void:
	_clear_children()
	_arena_center = global_position
	var size := 30.0

	# Дно (песок/камень): непрозрачное снизу, сверху тонкий слой песка.
	_add_box(Vector3(size * 2.0, 1.0, size * 2.0), _arena_center + Vector3(0, -8.5, 0), _box_material)

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
		_add_box(box_size, _arena_center + offset, _box_material)

	# Несколько колонн-камней внутри: укрытия для перестрелок.
	for i in 5:
		var rnd_pos := Vector3(randf_range(-10.0, 10.0), 0.0, randf_range(-10.0, 10.0))
		_add_box(Vector3(2.0 + randf(), 9.0, 2.0 + randf()), _arena_center + rnd_pos + Vector3(0, 0.5, 0), _box_material)

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
