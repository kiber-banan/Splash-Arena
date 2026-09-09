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


func _ready() -> void:
	# Иначе два инстанса на одном ПК выдадут одинаковый код комнаты.
	randomize()
	# Фуллскрин (F11 / Alt+Enter) переключаем здесь: автолоад живёт всё
	# время, поэтому сочетание работает и в меню, и в матче.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _input(event: InputEvent) -> void:
	if not event.is_action_pressed("toggle_fullscreen"):
		return
	get_viewport().set_input_as_handled()
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


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
