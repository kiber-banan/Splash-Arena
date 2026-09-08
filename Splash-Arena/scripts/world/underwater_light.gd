extends Node3D
## Настройка подводного освещения и тумана.
## Свет «сверху» — лучи, пробивающиеся с поверхности воды.

@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment

func _ready() -> void:
	_apply_underwater_look()

func _apply_underwater_look() -> void:
	# Тёплый свет сверху, ослабленный толщей воды.
	sun.light_color = Color(0.95, 0.92, 0.72)
	sun.light_energy = 0.9

	if world_env.environment:
		# Голубоватый туман — глубина воды.
		world_env.environment.fog_enabled = true
		world_env.environment.fog_light_color = Color(0.10, 0.30, 0.38)
		world_env.environment.fog_density = 0.05
		# Лёгкая гамма-коррекция (смотрим из-под воды).
		world_env.environment.adjustment_enabled = true
		world_env.environment.adjustment_brightness = 0.9
		world_env.environment.adjustment_contrast = 1.05
		world_env.environment.adjustment_saturation = 1.15
