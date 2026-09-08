extends Node
## Данные сессии: что меню передаёт в матч. Автолоад — потому что эти
## значения должны пережить смену сцены (меню -> арена -> меню).
##
## Здесь же живут правила генерации кодов комнат и формат имён комнат
## Photon: все наши комнаты называются SA_<КОД>.

const NICK_DEFAULT := "Дайвер"
const NICK_MAX := 16
const CODE_LENGTH := 5
const ROOM_PREFIX := "SA"
const QUICK_ROOM := "QUICK"
const MAX_PLAYERS := 8  # FusionRoomOptions.max_players
# Алфавит без похожих символов: нет O/0 и I/1 — код проще диктовать.
const CODE_ALPHABET := "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

var nickname: String = NICK_DEFAULT
var character_id: int = 0
var join_mode: String = "quick"   # "create" | "join" | "quick"
var room_code: String = ""        # код для показа игроку (пусто = быстрый вход)
var last_notice: String = ""      # что показать в меню после выхода из комнаты


func _ready() -> void:
	# Иначе два инстанса на одном ПК выдадут одинаковый код комнаты.
	randomize()


static func sanitize_nick(raw: String) -> String:
	var s := raw.strip_edges()
	if s.is_empty():
		return NICK_DEFAULT
	return s.substr(0, NICK_MAX)


static func normalize_code(raw: String) -> String:
	return raw.strip_edges().to_upper()


static func random_code(length: int = CODE_LENGTH) -> String:
	var s := ""
	for _i in length:
		s += CODE_ALPHABET[randi() % CODE_ALPHABET.length()]
	return s


static func room_name_for_code(code: String) -> String:
	return "%s_%s" % [ROOM_PREFIX, code]


func make_user_id() -> String:
	## Photon UserID: ник + pid + случайность. pid обязателен — иначе два
	## инстанса на одной машине получат одинаковый ID, и Photon выкинет
	## одного из комнаты («userId уже занят»).
	return "%s#%d#%d" % [nickname, OS.get_process_id(), randi() % 100000]
