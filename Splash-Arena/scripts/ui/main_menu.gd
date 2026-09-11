extends Control
## Главное меню: матчмейкинг, выбор класса, профиль.
##
## МАТЧМЕЙКИНГ (без ручных кодов комнат):
##   1. «Найти матч» → подключаемся к Photon (если ещё не подключены).
##   2. Каждые SEARCH_STEP_SEC (после ошибки — сразу) повторяем попытку:
##        попытки 1 и 3 — Fusion.join_room(""): пустое имя = случайная
##        комната, Photon сам выберет открытую и не заполненную;
##        попытка 2   — join_or_create_room("SA_MATCH"): хаб с известным
##        именем (страховка, если случайный вход не находит чужие комнаты);
##        попытки 4+  — create_room(случайный код): создаём свою, чтобы
##        в неё зашли следующие игроки.
##   3. Как только room_joined — открываем ЛОББИ (scenes/ui/lobby.tscn):
##      там ждём всех игроков, все жмут «Принять» (как в LoL), и только
##      после этого грузится арена main.tscn и начинается спавн.
##
## Размер матча — одна константа Session.MATCH_SIZE (сейчас 2 = тест 1 на 1).

const LOBBY_SCENE := "res://scenes/ui/lobby.tscn"
const SEARCH_STEP_SEC := 3.0    # как часто повторяем попытку найти матч
const FOUND_DELAY_SEC := 0.6    # пауза перед загрузкой арены (показать «найдено»)
const MAX_JOIN_FAILURES := 6    # после стольких ошибок входа останавливаем поиск

## «Хаб» — комната с известным именем. Страховка на случай, если случайный
## вход (join_room с пустым именем) не подхватывает чужие комнаты: тогда
## первый игрок создаёт хаб, второй в него заходит по имени.
const HUB_ROOM := "MATCH"

const COLOR_INFO := Color(0.80, 0.92, 1.0)
const COLOR_ERROR := Color(1.0, 0.55, 0.45)
const COLOR_OK := Color(0.45, 0.95, 0.62)

const CARD_BG := Color(0.055, 0.102, 0.145, 1)
const CARD_BORDER := Color(0.11, 0.243, 0.318, 1)
const CARD_ACTIVE_BG := Color(0.071, 0.243, 0.325, 1)
const CARD_ACTIVE_BORDER := Color(0.302, 0.886, 1.0, 1)

@onready var tabs: TabContainer = %Tabs
@onready var status_label: Label = %StatusLabel
@onready var find_button: Button = %FindButton
@onready var search_bar: ProgressBar = %SearchBar
@onready var search_status: Label = %SearchStatus
@onready var cards_row: HBoxContainer = %CardsRow
@onready var hero_info: Label = %HeroInfo
@onready var nick_edit: LineEdit = %NickEdit
@onready var diag_label: Label = %DiagLabel

var _searching := false
var _search_time := 0.0
var _attempts := 0
var _join_failures := 0
var _cards: Array[Button] = []


func _ready() -> void:
	tabs.set_tab_title(0, "Играть")
	tabs.set_tab_title(1, "Персонаж")
	tabs.set_tab_title(2, "Профиль")
	_build_settings_tab()
	nick_edit.text = Session.nickname
	_build_character_cards()
	_select_character(Session.character_id)
	find_button.pressed.connect(_on_find_pressed)
	Fusion.connected_to_photon.connect(_on_connected_to_photon)
	Fusion.room_joined.connect(_on_room_joined)
	Fusion.connection_failed.connect(_on_connection_failed)
	_update_diag()
	if Session.last_notice.is_empty():
		_set_status("Готов к бою. Выбери класс и жми «Найти матч».", COLOR_INFO)
	else:
		_set_status(Session.last_notice, COLOR_INFO)
		Session.last_notice = ""


func _exit_tree() -> void:
	# Иначе у Fusion останутся висячие обработчики на уже удалённый узел.
	if Fusion.room_joined.is_connected(_on_room_joined):
		Fusion.room_joined.disconnect(_on_room_joined)
	if Fusion.connected_to_photon.is_connected(_on_connected_to_photon):
		Fusion.connected_to_photon.disconnect(_on_connected_to_photon)
	if Fusion.connection_failed.is_connected(_on_connection_failed):
		Fusion.connection_failed.disconnect(_on_connection_failed)


func _process(delta: float) -> void:
	if not _searching:
		return
	# Индикатор «ищу»: полоса бегает туда-обратно.
	search_bar.value = 100.0 * (0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.004))
	_search_time += delta
	if _search_time < SEARCH_STEP_SEC:
		return
	_search_time = 0.0
	_step_matchmaking()


# ---------- матчмейкинг ----------

func _on_find_pressed() -> void:
	if _searching:
		_stop_search("Поиск остановлен.", COLOR_INFO)
		return
	Session.nickname = Session.sanitize_nick(nick_edit.text)
	_searching = true
	_search_time = 0.0
	_attempts = 0
	_join_failures = 0
	find_button.text = "ОТМЕНА"
	search_bar.visible = true
	search_status.text = "Ищем матч %d на %d..." % [Session.MATCH_SIZE, Session.MATCH_SIZE]
	_set_status("Ищем матч...", COLOR_INFO)
	if _ensure_connected():
		_search_time = SEARCH_STEP_SEC  # первая попытка — сразу же


func _ensure_connected() -> bool:
	var app_id := AppConfig.get_app_id()
	if app_id.is_empty():
		# Запасной путь: App ID вбит прямо в Project Settings.
		app_id = String(ProjectSettings.get_setting("fusion/connection/app_id", ""))
	if app_id.is_empty():
		_stop_search("Нет Fusion App ID: скопируй config/secret.example.cfg -> config/secret.cfg и вставь свой App ID.", COLOR_ERROR)
		return false
	Fusion.set_app_id(app_id)
	if Fusion.is_connected_to_photon():
		return true
	_set_status("Подключаюсь к Photon...", COLOR_INFO)
	Fusion.connect_to_photon.call_deferred(Session.make_user_id())
	return false  # продолжим в _on_connected_to_photon


func _on_connected_to_photon() -> void:
	_update_diag()
	if _searching:
		_search_time = SEARCH_STEP_SEC  # попытка входа — без паузы


func _step_matchmaking() -> void:
	if not _searching or not Fusion.is_connected_to_photon():
		return
	_attempts += 1
	var options := Session.make_room_options()
	match _attempts:
		1, 3:
			# Ищем ЛЮБУЮ свободную комнату — Photon выберет сам.
			Fusion.join_room("", options)
			search_status.text = "Ищем свободный матч... (попытка %d)" % _attempts
		2:
			# Хаб: если кто-то уже создал — зайдём, нет — создадим сами.
			# Это и есть страховка от «два инстанса не видят друг друга».
			Fusion.join_or_create_room(Session.room_name_for_code(HUB_ROOM), options)
			search_status.text = "Подключаюсь к общему матчу... (попытка %d)" % _attempts
		_:
			# Свободных нет и хаб занят — создаём свою комнату со случайным
			# кодом, чтобы в неё зашли следующие.
			Session.room_code = Session.random_code()
			Fusion.create_room(Session.room_name_for_code(Session.room_code), options)
			search_status.text = "Свободных матчей нет — создаю свой %s (попытка %d)" % [
				Session.room_code, _attempts
			]
	_set_status(search_status.text, COLOR_INFO)


func _on_room_joined() -> void:
	if not _searching:
		return
	_searching = false
	find_button.text = "МАТЧ НАЙДЕН"
	find_button.disabled = true
	search_bar.visible = false
	search_status.text = "Матч найден! Открываю лобби..."
	_set_status("Матч найден! Открываю лобби...", COLOR_OK)
	await get_tree().create_timer(FOUND_DELAY_SEC).timeout
	# Сначала ЛОББИ: ждём всех игроков, все жмут «Принять» — и только
	# потом лобби грузит main.tscn, где MatchManager просит ХОСТ
	# заспавнить аватары. До приёма матча спавна нет.
	get_tree().change_scene_to_file(LOBBY_SCENE)


func _on_connection_failed(error: String) -> void:
	push_error("MainMenu: %s" % error)
	_update_diag()
	if not _searching:
		_set_status("Ошибка: %s" % error, COLOR_ERROR)
		return
	if not Fusion.is_connected_to_photon():
		_stop_search("Не удалось подключиться к Photon: %s" % error, COLOR_ERROR)
		return
	# Во время поиска ошибка «нет свободных комнат» — это нормально,
	# следующая попытка создаст свою комнату.
	_join_failures += 1
	if _join_failures >= MAX_JOIN_FAILURES:
		_stop_search("Не удалось ни найти, ни создать матч: %s" % error, COLOR_ERROR)
		return
	_search_time = SEARCH_STEP_SEC  # пробуем снова без паузы


func _stop_search(message: String, color: Color) -> void:
	_searching = false
	find_button.text = "НАЙТИ МАТЧ"
	find_button.disabled = false
	search_bar.visible = false
	search_status.text = ""
	_set_status(message, color)


# ---------- классы ----------

func _build_settings_tab() -> void:
	## Вкладка «Настройки»: пока только полноэкранный режим. Значение
	## живёт в Session и сохраняется в user://settings.cfg.
	var page := Control.new()
	page.name = "Settings"
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 24.0
	box.offset_top = 24.0
	box.offset_right = -24.0
	box.offset_bottom = -24.0
	box.add_theme_constant_override("separation", 12)
	page.add_child(box)

	var title := Label.new()
	title.text = "Настройки"
	title.add_theme_font_size_override("font_size", 28)
	box.add_child(title)

	var fullscreen_box := CheckBox.new()
	fullscreen_box.text = "Полноэкранный режим"
	fullscreen_box.button_pressed = Session.fullscreen
	fullscreen_box.toggled.connect(func(enabled: bool) -> void:
		Session.set_fullscreen(enabled)
	)
	box.add_child(fullscreen_box)

	var hint := Label.new()
	hint.text = (
		"Игра запускается в фуллскрине. Сними галочку — окно станет обычным,\n"
		+ "настройка запомнится. F11 / Alt+Enter переключают режим на ходу.\n"
		+ "ESC — выход из матча в меню (в лобби — отмена поиска)."
	)
	hint.add_theme_color_override("font_color", Color(0.72, 0.8, 0.88))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(hint)

	tabs.add_child(page)
	tabs.set_tab_title(tabs.get_tab_count() - 1, "Настройки")


func _build_character_cards() -> void:
	for child in cards_row.get_children():
		child.queue_free()
	_cards.clear()
	for i in Characters.COUNT:
		var card := Button.new()
		card.text = _card_text(i)
		card.custom_minimum_size = Vector2(170, 0)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.size_flags_vertical = Control.SIZE_EXPAND_FILL
		# Переносы задаём сами через \n (короткие строки), чтобы не зависеть
		# от autowrap_mode — у Button его поведение между версиями отличается.
		# Фокусная рамка вокруг карточки портит вид — убираем.
		card.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		card.pressed.connect(_on_card_pressed.bind(i))
		cards_row.add_child(card)
		_cards.append(card)


static func _card_text(character_id: int) -> String:
	var lines := PackedStringArray()
	lines.append(Characters.name_for(character_id).to_upper())
	for part in Characters.description_for(character_id).split("•", false):
		lines.append(part.strip_edges())
	return "\n".join(lines)


static func _card_style(active: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = CARD_ACTIVE_BG if active else CARD_BG
	sb.border_color = CARD_ACTIVE_BORDER if active else CARD_BORDER
	sb.set_border_width_all(2 if active else 1)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 16
	sb.content_margin_top = 14
	sb.content_margin_right = 16
	sb.content_margin_bottom = 14
	return sb


func _on_card_pressed(character_id: int) -> void:
	_select_character(character_id)


func _select_character(character_id: int) -> void:
	Session.character_id = character_id
	for i in _cards.size():
		var active := i == character_id
		_cards[i].add_theme_stylebox_override("normal", _card_style(active))
		_cards[i].add_theme_stylebox_override("hover", _card_style(true))
		_cards[i].add_theme_stylebox_override("pressed", _card_style(true))
		_cards[i].add_theme_font_size_override("font_size", 18 if active else 16)
	hero_info.text = "%s\n%s\nОружие: гарпун (урон 25, кд 0.35 с)" % [
		Characters.name_for(character_id),
		Characters.description_for(character_id),
	]


# ---------- служебное ----------

func _set_status(text: String, color: Color) -> void:
	status_label.modulate = color
	status_label.text = text


func _update_diag() -> void:
	var app_id := AppConfig.get_app_id()
	if app_id.is_empty():
		app_id = String(ProjectSettings.get_setting("fusion/connection/app_id", ""))
	var region := String(ProjectSettings.get_setting("fusion/connection/default_region", "eu")).to_upper()
	diag_label.text = "Photon: %s\nApp ID: %s\nРегион: %s\nИгроков в матче: %d" % [
		"подключён" if Fusion.is_connected_to_photon() else "не подключён",
		"есть" if not app_id.is_empty() else "НЕ ЗАДАН",
		region,
		Session.MATCH_SIZE,
	]
