extends Node
## Читает локальный секретный конфиг (config/secret.cfg) и отдаёт
## Fusion App ID. Секрет в git не хранится — см. .gitignore.

const SECRET_PATH := "res://config/secret.cfg"

var _app_id := ""

func _ready() -> void:
	if FileAccess.file_exists(SECRET_PATH):
		var cfg := ConfigFile.new()
		if cfg.load(SECRET_PATH) == OK:
			_app_id = str(cfg.get_value("fusion", "app_id", ""))
	if _app_id.is_empty():
		push_warning(
			"AppConfig: config/secret.cfg не найден или app_id пуст.\n" +
			"Скопируй config/secret.example.cfg -> config/secret.cfg и вставь свой Fusion App ID."
		)
	else:
		print("AppConfig: Fusion App ID загружен из config/secret.cfg")

func get_app_id() -> String:
	return _app_id
