extends Node
## Данные сессии: что меню передаёт в матч. Автолоад — потому что эти
## значения должны пережить смену сцены (меню -> арена -> меню).
##
## МАТЧМЕЙКИНГ (вместо ручных кодов комнат):
##   игрок жмёт «Найти матч» → меню пытается войти в любую свободную
##   комнату (Photon сам выбирает: join_room с пустым именем), а если
##   свободных нет — создаёт свою, чтобы в неё зашли следующие.
##
##   MATCH_SIZE — сколько игроков в матче. Сейчас 2 (тест 1 на 1).
##   Когда будешь готов — поставь 4 или 8: больше ничего менять не нужно,
##   Photon просто перестанет подсаживать игроков в заполненные комнаты.

## Игра всегда стартует в фуллскрине. Выключить можно только в меню
## («Настройки» → снять галочку) — значение помнится в user://settings.cfg.
## F11 / Alt+Enter переключают режим на ходу (на время отладки).
const SETTINGS_PATH := "user://settings.cfg"

const NICK_DEFAULT := "Дайвер"
const NICK_MAX := 16
const CODE_LENGTH := 5
const ROOM_PREFIX := "SA"
const QUICK_ROOM := "QUICK"
## Сколько игроков в матче. 2 = тест 1 на 1. Потом поставь 4 / 8 / 16.
const MATCH_SIZE := 2
# Алфавит без похожих символов: нет O/0 и I/1.
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

var nickname: String = NICK_DEFAULT
var character_id: int = 0
var room_code: String = ""        # код комнаты, если мы её создали (просто для показа)
var last_notice: String = ""      # что показать в меню после выхода из матча
## Полноэкранный режим. true — игра всегда в фуллскрине.
var fullscreen: bool = true


func _ready() -> void:
	# Иначе два инстанса на одном ПК выдадут одинаковый код комнаты.
	randomize()
	# Фуллскрин (F11 / Alt+Enter) и ESC переключаем здесь: автолоад живёт
	# всё время, поэтому сочетания работают и в меню, и в матче.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_settings()
	_apply_window_mode.call_deferred()


# ---------- настройки (фуллскрин) ----------

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		fullscreen = bool(cfg.get_value("video", "fullscreen", true))


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("video", "fullscreen", fullscreen)
	var err := cfg.save(SETTINGS_PATH)
	if err != OK:
		push_warning("Session: не смог сохранить настройки (%d)." % err)


func set_fullscreen(enabled: bool) -> void:
	fullscreen = enabled
	save_settings()
	_apply_window_mode()


func toggle_fullscreen() -> void:
	set_fullscreen(not fullscreen)


func _apply_window_mode() -> void:
	var mode := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
	if DisplayServer.window_get_mode() != mode:
		DisplayServer.window_set_mode(mode)


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo:
		# Проверяем и keycode, и physical_keycode: на разных раскладках
		# они могут отличаться, а F11 должен работать всегда.
		if KEY_F11 in [key.keycode, key.physical_keycode] \
			or (key.alt_pressed and KEY_ENTER in [key.keycode, key.physical_keycode]):
			get_viewport().set_input_as_handled()
			toggle_fullscreen()
			return
		if key.keycode == KEY_ESCAPE or key.physical_keycode == KEY_ESCAPE:
			_handle_escape()
			return
	if event.is_action_pressed("toggle_fullscreen"):
		get_viewport().set_input_as_handled()
		toggle_fullscreen()
		return
	if event.is_action_pressed("ui_cancel"):
		_handle_escape()


func _handle_escape() -> void:
	## ESC: в матче — выход в меню, в лобби — отмена поиска. Держим здесь,
	## потому что автолоад получает ввод всегда, даже если сцена его съела.
	var tree := get_tree()
	if tree == null:
		return
	var mm := tree.get_first_node_in_group("match_manager")
	if mm != null:
		get_viewport().set_input_as_handled()
		mm.leave_to_menu()
		return
	var lobby := tree.get_first_node_in_group("lobby")
	if lobby != null and lobby.has_method("cancel_search"):
		get_viewport().set_input_as_handled()
		lobby.cancel_search()


static func sanitize_nick(raw: String) -> String:
	var s := raw.strip_edges()
	if s.is_empty():
		return NICK_DEFAULT
	return s.substr(0, NICK_MAX)


static func random_code(length: int = CODE_LENGTH) -> String:
	var s := ""
	for _i in length:
		s += CODE_ALPHABET[randi() % CODE_ALPHABET.length()]
	return s


static func room_name_for_code(code: String) -> String:
	return "%s_%s" % [ROOM_PREFIX, code]


func make_room_options() -> FusionRoomOptions:
	## Опции матча. max_players = MATCH_SIZE — Photon не подсадит
	## в заполненную комнату, поэтому случайный вход = честный 1 на 1.
	var options := FusionRoomOptions.new()
	options.max_players = MATCH_SIZE
	options.is_visible = true   # комнату видно в случайном поиске
	options.is_open = true
	# Пустая комната живёт минуту: успеют найти те, кто искал параллельно.
	options.empty_room_ttl_ms = 60000
	return options


func make_user_id() -> String:
	## Photon UserID: ник + pid + случайность. pid обязателен — иначе два
	## инстанса на одной машине получат одинаковый ID, и Photon выкинет
	## одного из комнаты («userId уже занят»).
	return "%s#%d#%d" % [nickname, OS.get_process_id(), randi() % 100000]
