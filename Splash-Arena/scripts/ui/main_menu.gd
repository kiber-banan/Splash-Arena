extends Control
## Стартовое меню: ник, создание комнаты с кодом, вход по коду, быстрый вход.
##
## Меню само подключается к Photon и заходит в комнату — так ошибки
## соединения видно сразу в статусе, а не в пустом логе. main.tscn
## (MatchManager) потом подхватывает уже готовое соединение.
##
## Photon-комнаты называются Session.room_name_for_code(code) = "SA_<КОД>",
## у быстрого входа фиксированное имя SA_QUICK (join_or_create).

const MAIN_SCENE := "res://scenes/main/main.tscn"

@onready var status_label: Label = %StatusLabel
@onready var nick_edit: LineEdit = %NickEdit
@onready var code_edit: LineEdit = %CodeEdit
@onready var char_select: OptionButton = %CharSelect
@onready var char_info: Label = %CharInfo

var _pending_room := ""
var _busy := false


func _ready() -> void:
	nick_edit.text = Session.nickname
	_fill_characters()
	char_select.item_selected.connect(_on_character_selected)
	%CreateButton.pressed.connect(_on_create_pressed)
	%JoinButton.pressed.connect(_on_join_pressed)
	%QuickButton.pressed.connect(_on_quick_pressed)
	Fusion.connected_to_photon.connect(_on_connected_to_photon)
	Fusion.room_joined.connect(_on_room_joined)
	Fusion.connection_failed.connect(_on_connection_failed)
	if Session.last_notice.is_empty():
		_set_status("Введи ник и жми «Создать комнату» или «Быстрый вход»")
	else:
		_set_status(Session.last_notice)
		Session.last_notice = ""


func _exit_tree() -> void:
	# Иначе у Fusion останутся висячие обработчики на уже удалённый узел.
	if Fusion.room_joined.is_connected(_on_room_joined):
		Fusion.room_joined.disconnect(_on_room_joined)
	if Fusion.connected_to_photon.is_connected(_on_connected_to_photon):
		Fusion.connected_to_photon.disconnect(_on_connected_to_photon)
	if Fusion.connection_failed.is_connected(_on_connection_failed):
		Fusion.connection_failed.disconnect(_on_connection_failed)


# ---------- выбор персонажа ----------

func _fill_characters() -> void:
	for i in Characters.COUNT:
		char_select.add_item(Characters.name_for(i), i)
	char_select.select(Session.character_id)
	_update_character_info(Session.character_id)


func _on_character_selected(_index: int) -> void:
	_update_character_info(char_select.get_selected_id())


func _update_character_info(character_id: int) -> void:
	char_info.text = Characters.description_for(character_id)


# ---------- кнопки ----------

func _on_create_pressed() -> void:
	var code := Session.random_code()
	Session.join_mode = "create"
	Session.room_code = code
	_enter_room(Session.room_name_for_code(code), "Создаю комнату с кодом %s..." % code)


func _on_join_pressed() -> void:
	var code := Session.normalize_code(code_edit.text)
	if code.length() < 3:
		_set_error("Введи код комнаты — минимум 3 символа")
		return
	Session.join_mode = "join"
	Session.room_code = code
	_enter_room(Session.room_name_for_code(code), "Вхожу в комнату %s..." % code)


func _on_quick_pressed() -> void:
	Session.join_mode = "quick"
	Session.room_code = ""
	_enter_room(Session.room_name_for_code(Session.QUICK_ROOM), "Ищу быстрый матч...")


# ---------- подключение ----------

func _enter_room(room_name: String, message: String) -> void:
	if _busy:
		return
	Session.nickname = Session.sanitize_nick(nick_edit.text)
	Session.character_id = char_select.get_selected_id()
	_pending_room = room_name
	_set_status(message)
	var app_id := AppConfig.get_app_id()
	if app_id.is_empty():
		# Запасной путь: App ID вбит прямо в Project Settings.
		app_id = String(ProjectSettings.get_setting("fusion/connection/app_id", ""))
	if app_id.is_empty():
		_set_error("Нет Fusion App ID: скопируй config/secret.example.cfg -> config/secret.cfg и вставь свой App ID")
		return
	Fusion.set_app_id(app_id)
	_busy = true
	if Fusion.is_connected_to_photon():
		_join_pending_room()
	else:
		Fusion.connect_to_photon.call_deferred(Session.make_user_id())


func _join_pending_room() -> void:
	var options := FusionRoomOptions.new()
	options.max_players = Session.MAX_PLAYERS
	options.is_visible = true
	options.is_open = true
	match Session.join_mode:
		"create":
			Fusion.create_room(_pending_room, options)
		"join":
			Fusion.join_room(_pending_room, options)
		_:
			Fusion.join_or_create_room(_pending_room, options)


func _on_connected_to_photon() -> void:
	_join_pending_room()


func _on_room_joined() -> void:
	_set_status("В комнате. Загружаю арену...")
	get_tree().change_scene_to_file(MAIN_SCENE)


func _on_connection_failed(error: String) -> void:
	_busy = false
	push_error("MainMenu: не удалось подключиться: %s" % error)
	if Session.join_mode == "join":
		_set_error("Не удалось войти в комнату %s: %s" % [Session.room_code, error])
	elif Session.join_mode == "create":
		_set_error("Не удалось создать комнату: %s" % error)
	else:
		_set_error("Ошибка подключения: %s" % error)


# ---------- статус ----------

func _set_status(text: String) -> void:
	status_label.modulate = Color(0.85, 0.95, 1.0)
	status_label.text = text


func _set_error(text: String) -> void:
	status_label.modulate = Color(1.0, 0.55, 0.45)
	status_label.text = text
