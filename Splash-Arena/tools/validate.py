#!/usr/bin/env python3
"""Статический валидатор Splash Arena: сцены, скрипты, связки."""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # папка Godot-проекта
fails: list[str] = []
warns: list[str] = []

def fail(msg): fails.append(msg)
def warn(msg): warns.append(msg)

def res_path(p: str) -> Path:
    assert p.startswith("res://"), p
    return ROOT / p[len("res://"):]

# ---------- 1. Парсинг .tscn ----------
SECT = re.compile(r"^\[(gd_scene|ext_resource|sub_resource|node|connection)([^\]]*)\]\s*$")
ATTR = re.compile(r'(\w+)\s*=\s*("(?:[^"\\]|\\.)*"|\S+)')

def parse_tscn(path: Path):
    text = path.read_text(encoding="utf-8")
    header, exts, subs, nodes = {}, {}, {}, {}
    cur_kind, cur = None, None
    def flush():
        if cur_kind == "node":
            nodes[cur["_path"]] = cur
    for line in text.splitlines():
        m = SECT.match(line.strip())
        if m:
            flush()
            cur_kind, cur = m.group(1), {"_attrs": {}}
            for k, v in ATTR.findall(m.group(2)):
                cur["_attrs"][k] = v.strip('"')
            if cur_kind == "ext_resource":
                exts[cur["_attrs"]["id"]] = cur["_attrs"]
            elif cur_kind == "sub_resource":
                subs[cur["_attrs"]["id"]] = cur["_attrs"]
            elif cur_kind == "node":
                a = cur["_attrs"]
                if "parent" not in a:
                    cur["_path"] = a["name"]
                elif a["parent"] == ".":
                    cur["_path"] = "__ROOT__/" + a["name"]
                else:
                    cur["_path"] = "__ROOT__/" + a["parent"] + "/" + a["name"]
            elif cur_kind == "gd_scene":
                header = cur["_attrs"]
            continue
        s = line.strip()
        if not s or s.startswith(";"):
            continue
        if cur_kind in ("node", "sub_resource") and "=" in line:
            k, v = line.split("=", 1)
            cur[k.strip()] = v.strip()
    flush()
    roots = [p for p in nodes if "/" not in p]
    assert len(roots) == 1, f"{path}: root nodes = {roots}"
    root = roots[0]
    norm = {}
    for p, n in nodes.items():
        norm[p.replace("__ROOT__", root)] = n
    return header, exts, subs, norm, text

def check_tscn(rel: str):
    path = ROOT / rel
    header, exts, subs, nodes, text = parse_tscn(path)
    expect = 1 + len(exts) + len(subs)
    if int(header.get("load_steps", -1)) != expect:
        fail(f"{rel}: load_steps={header.get('load_steps')} != 1+{len(exts)}+{len(subs)}={expect}")
    for m in re.finditer(r'ExtResource\("([^"]+)"\)', text):
        if m.group(1) not in exts:
            fail(f"{rel}: ExtResource {m.group(1)} не найден")
    for m in re.finditer(r'SubResource\("([^"]+)"\)', text):
        if m.group(1) not in subs:
            fail(f"{rel}: SubResource {m.group(1)} не найден")
    for p, n in nodes.items():
        if "/" in p:
            parent = p.rsplit("/", 1)[0]
            if parent not in nodes:
                fail(f"{rel}: у узла {p} нет родителя {parent}")
    for eid, a in exts.items():
        if not res_path(a["path"]).exists():
            fail(f"{rel}: ext_resource {a['path']} отсутствует на диске")
    return header, exts, subs, nodes

main = check_tscn("scenes/main/main.tscn")
player = check_tscn("scenes/player/player.tscn")
menu = check_tscn("scenes/ui/main_menu.tscn")
hud = check_tscn("scenes/ui/hud.tscn")

# ---------- 1b. Разворот вложенных сцен (instance=...) ----------
# Скрипт на узле Main/HUD ссылается на %DebugLabel, который живёт внутри
# hud.tscn. Чтобы такие ссылки проверялись, склеиваем дерево сцены
# с деревьями всех её instance-подсцен.
SCENE_CACHE: dict = {}

def scene_nodes(rel: str, depth: int = 0) -> dict:
    if rel in SCENE_CACHE:
        return SCENE_CACHE[rel]
    SCENE_CACHE[rel] = {}  # защита от циклического instance
    _, exts, _, nodes, _ = parse_tscn(ROOT / rel)
    out = dict(nodes)
    if depth < 4:
        for path, node in list(nodes.items()):
            m = re.search(r'ExtResource[(]"([^"]+)"[)]', node.get("_attrs", {}).get("instance", ""))
            if not m:
                continue
            sub = exts.get(m.group(1), {}).get("path", "")
            if not sub.startswith("res://"):
                continue
            for sp, sn in scene_nodes(sub[len("res://"):], depth + 1).items():
                if "/" in sp:
                    out[path + "/" + sp.split("/", 1)[1]] = sn
                else:
                    merged = dict(sn)
                    for k, v in node.items():
                        if k != "_path":
                            merged[k] = v
                    out[path] = merged
    SCENE_CACHE[rel] = out
    return out

mexp = scene_nodes("scenes/main/main.tscn")
pexp = scene_nodes("scenes/player/player.tscn")
uexp = scene_nodes("scenes/ui/main_menu.tscn")

def script_of(exts, node: dict) -> str:
    mm_ = re.search(r'ExtResource\("([^"]+)"\)', node.get("script", ""))
    return exts.get(mm_.group(1), {}).get("path", "") if mm_ else ""

# ---------- 2. Проверки конкретных сцен ----------
_, mext, _, m = main
def mnode(p):
    if p not in m: fail(f"main.tscn: нет узла {p}")
    return m.get(p, {})

mm = mnode("Main/MatchManager")
if "match_manager.gd" not in script_of(mext, mm): fail("main.tscn: у MatchManager нет скрипта match_manager.gd")
sp = mnode("Main/MatchManager/FusionSpawner")
if sp.get("spawn_path") != 'NodePath("../Players")': fail(f"main.tscn: spawn_path={sp.get('spawn_path')}")
mnode("Main/MatchManager/Players")
ul = mnode("Main/UnderwaterLight")
if "underwater_light.gd" not in script_of(mext, ul): fail("main.tscn: у UnderwaterLight нет скрипта")
mnode("Main/UnderwaterLight/Sun"); mnode("Main/UnderwaterLight/WorldEnvironment")
ar = mnode("Main/Arena")
if "arena.gd" not in script_of(mext, ar): fail("main.tscn: у Arena нет скрипта arena.gd")
ws = mnode("Main/WaterSurface")
if "mesh" not in ws or "surface_material_override/0" not in ws: fail("main.tscn: у WaterSurface нет mesh/материала")
pc = mnode("Main/PreviewCamera")
if pc.get("current") != "true": fail("main.tscn: PreviewCamera не current")

_, pext, _, p = player
def pnode(x):
    if x not in p: fail(f"player.tscn: нет узла {x}")
    return p.get(x, {})
prt = pnode("Player")
if "player.gd" not in script_of(pext, prt): fail("player.tscn: у корня нет скрипта player.gd")
cam = pnode("Player/CameraRig")
if cam.get("_attrs", {}).get("type") != "Camera3D": fail("player.tscn: CameraRig не Camera3D")
rep = pnode("Player/FusionServerReplicator")
if "owner_mode" not in rep or "root_replication_mode" not in rep:
    fail("player.tscn: у репликатора нет owner_mode/root_replication_mode")
cs = pnode("Player/CollisionShape3D")
if "shape" not in cs: fail("player.tscn: у CollisionShape3D нет shape")

_, _, _, u = menu
def unode(x):
    if x not in u: fail(f"main_menu.tscn: нет узла {x}")
    return u.get(x, {})
MENU_UNIQUE = {
    "StatusLabel": "MainMenu/Center/VBox/StatusLabel",
    "NickEdit": "MainMenu/Center/VBox/NickRow/NickEdit",
    "CodeEdit": "MainMenu/Center/VBox/CodeRow/CodeEdit",
    "CreateButton": "MainMenu/Center/VBox/CreateButton",
    "JoinButton": "MainMenu/Center/VBox/CodeRow/JoinButton",
    "QuickButton": "MainMenu/Center/VBox/QuickButton",
}
for nm, path in MENU_UNIQUE.items():
    if unode(path).get("unique_name_in_owner") != "true":
        fail(f"main_menu.tscn: {nm} ({path}) без unique_name_in_owner")

hud_in_main = mnode("Main/HUD")
if 'ExtResource("5_hud")' not in hud_in_main.get("_attrs", {}).get("instance", ""):
    fail("main.tscn: HUD не инстанцирован из scenes/ui/hud.tscn")

_, hext, _, h = hud
hroot = h.get("HUD", {})
if "hud.gd" not in script_of(hext, hroot):
    fail("hud.tscn: у корня HUD нет скрипта hud.gd")
if hroot.get("mouse_filter") != "3":
    fail("hud.tscn: корень HUD должен быть mouse_filter=3 (IGNORE), иначе мышь не дойдёт до игрока")
for nm in ("DebugLabel", "RoomInfo", "PlayerList", "HintLabel"):
    if h.get("HUD/" + nm, {}).get("unique_name_in_owner") != "true":
        fail(f"hud.tscn: {nm} без unique_name_in_owner")

# ---------- 3. Скрипты: пути, узлы, санити ----------
GD = {
    "scripts/main/match_manager.gd": ("scenes/main/main.tscn", "Main/MatchManager", mexp),
    "scripts/player/player.gd": ("scenes/player/player.tscn", "Player", pexp),
    "scripts/ui/main_menu.gd": ("scenes/ui/main_menu.tscn", "MainMenu", uexp),
    "scripts/ui/hud.gd": ("scenes/main/main.tscn", "Main/HUD", mexp),
    "scripts/world/underwater_light.gd": ("scenes/main/main.tscn", "Main/UnderwaterLight", mexp),
    "scripts/world/arena.gd": ("scenes/main/main.tscn", "Main/Arena", mexp),
    "autoload/app_config.gd": (None, None, None),
    "autoload/session.gd": (None, None, None),
    "autoload/inputs.gd": (None, None, None),
}

def strip_gd(text: str) -> list[str]:
    """Убирает комментарии и строки, возвращает значимые строки."""
    out = []
    for line in text.splitlines():
        res, i, instr = [], 0, False
        while i < len(line):
            c = line[i]
            if instr:
                if c == "\\": i += 2; continue
                if c == '"': instr = False
                i += 1; continue
            if c == '"': instr = True; i += 1; continue
            if c == "#": break
            res.append(c); i += 1
        out.append("".join(res))
    return out

# 3b. Опечатки в именах функций. fwrap() вместо wrapf() уже ловили руками —
# теперь такие вещи видит валидатор.
BANNED_CALLS = {"fwrap": "wrapf", "fposmod2": "fposmod"}
KEYWORDS = {
    "if", "elif", "else", "for", "while", "match", "and", "or", "not", "in", "is",
    "as", "return", "await", "signal", "class", "extends", "func", "break",
    "continue", "pass", "super", "var", "const", "enum", "static", "set", "get",
}
# Методы движка, которые в GDScript принято звать без точки (через self).
KNOWN_METHODS = set("""
get_tree get_node get_node_or_null has_node find_child add_child remove_child
add_sibling queue_free free call_deferred set_deferred get_parent get_child
get_children get_child_count is_in_group add_to_group remove_from_group
get_groups is_inside_tree is_ancestor_of move_and_slide set_physics_process
connect disconnect is_connected emit_signal get_viewport get_world_3d
get_first_node_in_group get_nodes_in_group create_timer change_scene_to_file
reload_current_scene quit set_input_authority has_input_authority has_authority
get_input_authority add_spawnable_scene spawn despawn rpc rpc_id has_method
intersect_ray get_property_list queue_redraw create_tween kill is_valid
draw_line draw_circle draw_rect draw_arc tween_property tween_callback
set_input_as_handled is_action_pressed get_rid get_world_3d
""".split())
BUILTIN_FUNCS = set("""
abs absf absi acos acosh angle_difference asin asinh assert atan atan2 atanh
bool int float str string color vector2 vector2i vector3 vector3i vector4
rect2 rect2i transform2d transform3d plane quaternion aabb basis projection nodepath
rid dict array callable signal packedbytearray packedstringarray packedint32array
packedint64array packedfloat32array packedfloat64array packedvector2array
packedvector3array packedcolorarray
bezier_interpolate bytes_to_var ceil ceilf ceili clamp clampf clampi cos cosh
cubed_interpolate db_to_linear deg_to_rad deep_equal ease error_string exp floor
floorf floori fmod fposmod get_stack hash instance_from_id inverse_lerp
is_equal_approx is_finite is_inf is_instance_of is_instance_valid is_nan is_same
is_zero_approx len lerp lerp_angle lerpf linear_to_db load log max maxf maxi min
minf mini move_toward nearest_po2 pingpong posmod pow preload print print_rich
print_verbose printerr printraw printt push_error push_warning rad_to_deg
rand_from_seed randf randf_range randfn randi randi_range randomize range remap
rid_allocate_id rid_from_int64 round roundf roundi seed sign signf signi sin sinh
smoothstep snapped snappedf snappedi sqrt step_decimals str str_to_var tan tanh
type_convert typeof var_to_bytes var_to_str wrap wrapf wrapi
""".split())
PROJECT_FUNCS: set = set()
for rel in GD:
    PROJECT_FUNCS |= set(
        re.findall(r"^\s*(?:static\s+)?func\s+(\w+)", (ROOT / rel).read_text(encoding="utf-8"), re.M)
    )

for rel, (scene, base, nodes) in GD.items():
    src = (ROOT / rel).read_text(encoding="utf-8")
    if not src.endswith("\n"): fail(f"{rel}: нет \\n в конце файла")
    for n, line in enumerate(src.splitlines(), 1):
        if line.startswith(" ") and line.strip():
            fail(f"{rel}:{n}: отступ пробелами, нужны табы")
    stack = []
    pairs = {")": "(", "]": "[", "}": "{"}
    for n, line in enumerate(strip_gd(src), 1):
        for c in line:
            if c in "([{" : stack.append((c, n))
            elif c in ")]}":
                if not stack or stack[-1][0] != pairs[c]:
                    fail(f"{rel}:{n}: несбалансированная скобка {c}")
                else:
                    stack.pop()
    if stack: fail(f"{rel}: незакрытые скобки {stack[:3]}")
    # res:// пути (secret.cfg создаётся локально из примера — его отсутствие норма)
    for mm_ in re.finditer(r'"(res://[^"]+)"', src):
        rp = mm_.group(1)
        if rp == "res://config/secret.cfg":
            continue
        if not res_path(rp).exists():
            fail(f"{rel}: путь {rp} отсутствует")
    # узлы (ищем только в коде, без строк — иначе %d/%s из форматов шумят)
    code = "\n".join(strip_gd(src))
    if scene:
        refs = set(re.findall(r'\$"([^"]+)"', code)) | set(re.findall(r'get_node(?:_or_null)?\("([^"]+)"', code))
        for r in refs:
            full = base + "/" + r if not r.startswith("/") else r
            parts = []
            for seg in full.split("/"):
                if seg == "..": parts.pop()
                else: parts.append(seg)
            full = "/".join(parts)
            if full not in nodes:
                # может быть относительным путём от заспавненного игрока
                if "/" not in r and f"Player/{r}" in p:
                    continue
                fail(f"{rel}: узел ${r} ({full}) не найден в {scene}")
        for uq in set(re.findall(r'%([A-Za-z_]\w*)', code)):
            if not any(n.get("unique_name_in_owner") == "true" and k.rsplit("/",1)[-1] == uq for k, n in nodes.items()):
                fail(f"{rel}: %{uq} не найден в {scene}")
    # вызовы неизвестных глобальных функций (обычно = опечатка в имени)
    known = BUILTIN_FUNCS | PROJECT_FUNCS | KEYWORDS | KNOWN_METHODS
    for n, line in enumerate(code.splitlines(), 1):
        for call in re.finditer(r"(?<![.A-Za-z0-9_])([a-z_][A-Za-z0-9_]*)[(]", line):
            name = call.group(1)
            if name in known:
                continue
            if name in BANNED_CALLS:
                fail(f"{rel}:{n}: функции {name}() не существует в Godot — используй {BANNED_CALLS[name]}()")
            else:
                warn(f"{rel}:{n}: неизвестная функция {name}() — опечатка? Её нет в @GlobalScope и в проекте")

# ---------- 4. project.godot ----------
pg = (ROOT / "project.godot").read_text(encoding="utf-8")
mm_ = re.search(r'run/main_scene="([^"]+)"', pg)
if not mm_ or not res_path(mm_.group(1)).exists():
    fail("project.godot: run/main_scene отсутствует")
for am in re.finditer(r'^\w+="\*res://[^"]+"', pg, re.M):
    ap = re.search(r'"\*(res://[^"]+)"', am.group(0)).group(1)
    if not res_path(ap).exists():
        fail(f"project.godot: autoload {ap} отсутствует")

print("WARNINGS:")
for w in warns: print("  W", w)
print(f"FAILURES: {len(fails)}")
for f in fails: print("  X", f)
sys.exit(1 if fails else 0)
