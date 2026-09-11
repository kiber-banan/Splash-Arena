extends Node3D
## Настройка подводного освещения и тумана.
## Свет «сверху» — лучи, пробивающиеся с поверхности воды.

@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment

func _ready() -> void:
	_apply_underwater_look()

func _apply_underwater_look() -> void:
	# Тёплый свет сверху, ослабленный толщей воды.
	sun.light_color = Color(1.0, 0.96, 0.82)
	sun.light_energy = 1.7

	if world_env.environment:
		# Голубоватый туман — глубина воды.
		world_env.environment.fog_enabled = true
		world_env.environment.fog_light_color = Color(0.14, 0.42, 0.52)
		world_env.environment.fog_density = 0.0035
		# Лёгкая гамма-коррекция (смотрим из-под воды).
		world_env.environment.adjustment_enabled = true
		world_env.environment.adjustment_brightness = 1.18
		world_env.environment.adjustment_contrast = 1.05
		world_env.environment.adjustment_saturation = 1.15
