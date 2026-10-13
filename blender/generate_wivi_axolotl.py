"""
generate_wivi_axolotl.py

Процедурно генерує базову 3D-модель першої істоти Wivials — водяного Wivi-аксолотля:
біло-рожеве кругле тіло на 4 коротких лапках, велика округла голова з чорними очима
й рум'янцем, по 3 пір'їсті зябра з кожного боку голови (градієнт рожевий → помаранчевий)
і плаский хвіст-плавник.

Система координат: Z — вгору, морда дивиться в -Y, хвіст — у +Y. 1 Blender unit ≈ 1 метр.
Усі частини — окремі об'єкти в колекції "Wivi_Axolotl" (без Join), щоб їх легко було
редагувати й перефарбовувати окремо.

Запуск: Blender → вкладка Scripting → Open → цей файл → Run Script.
Скрипт можна запускати повторно: на старті він очищає сцену.
"""

import math

import bpy
from mathutils import Matrix, Vector

COLLECTION_NAME = "Wivi_Axolotl"

# Кольори (лінійний RGBA, як очікує Principled BSDF)
SKIN_COLOR = (1.0, 0.86, 0.88, 1.0)  # майже білий з легким рожевим
GILL_BASE_COLOR = (1.0, 0.18, 0.45, 1.0)  # яскраво-рожевий біля голови
GILL_TIP_COLOR = (1.0, 0.42, 0.08, 1.0)  # помаранчевий на кінчиках
EYE_COLOR = (0.01, 0.01, 0.012, 1.0)
BLUSH_COLOR = (1.0, 0.32, 0.5, 1.0)


# ---------------------------------------------------------------------------
# Очищення сцени: видаляємо всі об'єкти (дефолтні куб/камеру/світло і попередню
# версію аксолотля), стару колекцію та "осиротілі" меші й наші матеріали,
# щоб повторний запуск не накопичував дублікатів (Body.001 тощо).
# ---------------------------------------------------------------------------
def clear_scene():
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()

    old = bpy.data.collections.get(COLLECTION_NAME)
    if old:
        bpy.data.collections.remove(old)
    for mesh in list(bpy.data.meshes):
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)
    for mat in list(bpy.data.materials):
        if mat.name.startswith("Wivi_"):
            bpy.data.materials.remove(mat)


# ---------------------------------------------------------------------------
# Колекція: усі нові об'єкти створюються одразу в ній (вона стає активною)
# ---------------------------------------------------------------------------
def make_collection():
    collection = bpy.data.collections.new(COLLECTION_NAME)
    bpy.context.scene.collection.children.link(collection)
    layer = bpy.context.view_layer.layer_collection.children[collection.name]
    bpy.context.view_layer.active_layer_collection = layer
    return collection


# ---------------------------------------------------------------------------
# Матеріали (прості Principled BSDF)
# ---------------------------------------------------------------------------
def make_material(name, color, roughness):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = color
    bsdf.inputs["Roughness"].default_value = roughness
    mat.diffuse_color = color  # колір у Solid-режимі в'юпорта
    return mat


def make_gill_material():
    """Градієнт уздовж кожної гілочки зябер: рожевий біля основи → помаранчевий на кінчику.

    Generated-координати об'єкта нормовані по його габариту: меш кожної гілочки тягнеться
    вздовж локальної осі X від основи (x = 0) до кінчика, тож X від 0 до 1 — це шлях основа → кінчик.
    """
    mat = make_material("Wivi_Gills", GILL_BASE_COLOR, 0.45)
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = nodes.get("Principled BSDF")

    coords = nodes.new("ShaderNodeTexCoord")
    coords.location = (-800, 300)
    separate = nodes.new("ShaderNodeSeparateXYZ")
    separate.location = (-600, 300)
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.location = (-400, 300)
    ramp.color_ramp.elements[0].position = 0.15
    ramp.color_ramp.elements[0].color = GILL_BASE_COLOR
    ramp.color_ramp.elements[1].position = 0.95
    ramp.color_ramp.elements[1].color = GILL_TIP_COLOR

    links.new(coords.outputs["Generated"], separate.inputs["Vector"])
    links.new(separate.outputs["X"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


# ---------------------------------------------------------------------------
# Допоміжні функції для мешів
# ---------------------------------------------------------------------------
def finish(obj, name, material, subdiv_levels=1):
    """Назва, матеріал, гладке затінення і Subdivision Surface для мультяшної форми."""
    obj.name = name
    obj.data.name = name
    obj.data.materials.append(material)
    obj.data.polygons.foreach_set("use_smooth", [True] * len(obj.data.polygons))
    if subdiv_levels > 0:
        mod = obj.modifiers.new("Subdivision", "SUBSURF")
        mod.levels = subdiv_levels
        mod.render_levels = subdiv_levels
    return obj


def add_sphere(location=(0, 0, 0), scale=(1, 1, 1), segments=32, rings=16):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings, radius=1.0, location=location)
    obj = bpy.context.active_object
    obj.scale = scale
    return obj


def add_stretched_blob(length, width, thickness, segments=24, rings=12):
    """Сфера, витягнута вздовж локальної X від основи (x = 0) до кінчика (x = length).

    Масштаб "запікається" в меш, тож об'єкт має scale = 1 — дочірні об'єкти не спотворюються,
    а Generated-координати йдуть від основи до кінчика (для градієнта зябер).
    """
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings, radius=1.0)
    obj = bpy.context.active_object
    obj.data.transform(Matrix.Translation((length / 2, 0, 0)) @ Matrix.Diagonal((length / 2, width, thickness, 1)))
    return obj


def frame_along(direction, up=Vector((0, 0, 1))):
    """Поворот, у якому локальна X дивиться вздовж direction, а тонка вісь Z — горизонтальна
    (площина гілочки містить напрямок і "верх" — віяло зябер видно спереду)."""
    x = direction.normalized()
    z = x.cross(up)
    if z.length < 1e-4:
        z = Vector((0, 1, 0))
    z.normalize()
    y = z.cross(x)
    return Matrix((x, y, z)).transposed()


def ellipsoid_front_point(center, radii, x, z):
    """Точка на передній (-Y) поверхні еліпсоїда для бічного зсуву x і висоти z (відносно центру),
    і зовнішня нормаль у ній — щоб садити очі й рум'янець рівно на поверхню голови."""
    a, b, c = radii
    inside = max(0.0, 1 - (x / a) ** 2 - (z / c) ** 2)
    y = -b * math.sqrt(inside)
    point = Vector(center) + Vector((x, y, z))
    normal = Vector((x / a**2, y / b**2, z / c**2)).normalized()
    return point, normal


# ---------------------------------------------------------------------------
# Генерація
# ---------------------------------------------------------------------------
def build():
    clear_scene()
    make_collection()

    skin = make_material("Wivi_Skin", SKIN_COLOR, 0.4)
    gills_mat = make_gill_material()
    eyes_mat = make_material("Wivi_Eyes", EYE_COLOR, 0.1)
    blush_mat = make_material("Wivi_Blush", BLUSH_COLOR, 0.6)

    # --- ТІЛО: овальна сфера ~1.2 завдовжки (вздовж Y), трохи сплюснута по Z ---
    body_center = (0, 0, 0.5)
    body = add_sphere(body_center, scale=(0.42, 0.6, 0.36))
    finish(body, "Body", skin, subdiv_levels=2)

    # --- ГОЛОВА: більша за тіло завширшки, кругла, трохи сплюснута, спереду тіла ---
    head_center = Vector((0, -0.75, 0.62))
    head_radii = (0.55, 0.5, 0.45)
    head = add_sphere(head_center, scale=head_radii)
    finish(head, "Head", skin, subdiv_levels=2)

    # --- ЛАПКИ: 4 короткі товсті циліндри під кутами тіла (задні товщі),
    #     трохи розставлені назовні, з приплюснутою сферою-ступнею на кінці ---
    legs = [
        ("FrontLeft", -1, -0.3, 0.085),
        ("FrontRight", 1, -0.3, 0.085),
        ("BackLeft", -1, 0.33, 0.105),
        ("BackRight", 1, 0.33, 0.105),
    ]
    for name, side, y, radius in legs:
        x = side * 0.3
        bpy.ops.mesh.primitive_cylinder_add(vertices=16, radius=radius, depth=0.32, location=(x, y, 0.24))
        leg = bpy.context.active_object
        leg.rotation_euler = (0, math.radians(-side * 15), 0)  # нижній кінець — назовні
        finish(leg, "Leg" + name, skin, subdiv_levels=1)

        foot_x = x + side * 0.045
        foot = add_sphere((foot_x, y - 0.03, 0.07), scale=(radius * 1.35, radius * 1.6, radius * 0.75), segments=16, rings=8)
        finish(foot, "Foot" + name, skin, subdiv_levels=1)

    # --- ХВІСТ: сплющений конус від задньої частини тіла, звужується до кінчика,
    #     нахилений на 15° вгору; тонкий по X — вертикальний плавник ---
    tail_pitch = math.radians(15)
    tail_dir = Vector((0, math.cos(tail_pitch), math.sin(tail_pitch)))
    tail_base = Vector((0, 0.42, 0.52))
    tail_length = 1.0
    bpy.ops.mesh.primitive_cone_add(vertices=24, radius1=0.3, radius2=0.03, depth=tail_length,
                                    location=tail_base + tail_dir * (tail_length / 2))
    tail = bpy.context.active_object
    # Вісь конуса (+Z) повертаємо до +Y і на tail_pitch вгору
    tail.rotation_euler = (-(math.pi / 2 - tail_pitch), 0, 0)
    tail.scale = (0.3, 1, 1)
    finish(tail, "Tail", skin, subdiv_levels=2)

    # --- ЗОВНІШНІ ЗЯБРА: по 3 гілочки з кожного боку голови, віялом назовні й угору.
    #     Від передньої (верхньої) до задньої — довші й ширші. На кожній гілочці —
    #     дрібні пір'їсті відростки, "дочірні" до неї (рухаються разом), з тим самим градієнтом. ---
    gills = [
        # (точка кріплення відносно центру голови для правого боку, напрямок, довжина, ширина)
        (Vector((0.42, 0.06, 0.24)), Vector((0.55, -0.05, 0.85)), 0.36, 0.06),
        (Vector((0.47, 0.14, 0.12)), Vector((0.8, 0.3, 0.5)), 0.46, 0.07),
        (Vector((0.46, 0.22, -0.02)), Vector((0.75, 0.6, 0.12)), 0.56, 0.08),
    ]
    for side_name, side in (("Left", -1), ("Right", 1)):
        for i, (attach, direction, length, width) in enumerate(gills, start=1):
            mirror = Vector((side, 1, 1))
            base = head_center + attach * mirror
            gill_dir = direction * mirror
            gill = add_stretched_blob(length, width, width * 0.45)
            gill.matrix_world = Matrix.Translation(base) @ frame_along(gill_dir).to_4x4()
            finish(gill, f"Gill{side_name}{i}", gills_mat, subdiv_levels=1)

            # Пір'їсті відростки: по черзі з обох боків гілочки, нахилені до кінчика
            for k, t in enumerate((0.35, 0.5, 0.65, 0.8)):
                flip = 1 if k % 2 == 0 else -1
                fil_len = length * (0.32 - 0.12 * t)
                filament = add_stretched_blob(fil_len, width * 0.35, width * 0.2, segments=12, rings=6)
                filament.parent = gill
                filament.matrix_parent_inverse = Matrix.Identity(4)
                filament.matrix_basis = (Matrix.Translation((length * t, flip * width * 0.6, 0))
                                         @ Matrix.Rotation(flip * math.radians(50), 4, "Z"))
                finish(filament, f"Gill{side_name}{i}_Filament{k + 1}", gills_mat, subdiv_levels=0)

    # --- ОЧІ: маленькі чорні глянцеві сфери спереду голови, трохи випуклі назовні ---
    for side_name, side in (("Left", -1), ("Right", 1)):
        point, normal = ellipsoid_front_point(head_center, head_radii, side * 0.27, 0.08)
        eye = add_sphere(point + normal * 0.02, scale=(0.085, 0.085, 0.085), segments=24, rings=12)
        finish(eye, f"Eye{side_name}", eyes_mat, subdiv_levels=1)

    # --- РУМ'ЯНЕЦЬ: плоскі рожеві овали під очима, ближче до боків, рівно на поверхні голови ---
    for side_name, side in (("Left", -1), ("Right", 1)):
        point, normal = ellipsoid_front_point(head_center, head_radii, side * 0.37, -0.06)
        blush = add_sphere(point + normal * 0.008, scale=(0.11, 0.075, 0.015), segments=24, rings=12)
        # Тонка вісь (локальна Z) — уздовж нормалі поверхні, довга (X) — горизонтально
        blush.rotation_mode = "QUATERNION"
        blush.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(normal)
        finish(blush, f"Blush{side_name}", blush_mat, subdiv_levels=1)

    bpy.ops.object.select_all(action="DESELECT")
    count = len(bpy.data.collections[COLLECTION_NAME].objects)
    print(f"[Wivi] Axolotl generated: {count} objects in collection '{COLLECTION_NAME}'")


build()
