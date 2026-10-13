--[[
	WorldGenerator
	Генерує базову тестову зону світу Wivials: містечко (TownArea) з площею,
	вуличною мережею, ліхтарями, фонтанами та подвір'ями з будинками в реальному масштабі,
	і сусідню дику галявину (WildArea). Обидві зони наповнені рослинністю й оточені горами GrassMountain (з колізією),
	а весь світ стоїть на суцільному WorldFloor усередині невидимого кільця SafeZoneBoundary. Дерева й трава — клони з AssetTemplates.
	Виконується один раз при старті сервера.
]]

local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")

-- Фіксований seed, щоб розкладка була однаковою при кожному запуску
local rng = Random.new(2026)

---------------------------------------------------------------------
-- Константи розкладки (Baseplate має верх на Y = 0)
---------------------------------------------------------------------
local GROUND_THICKNESS = 1
local GROUND_TOP = GROUND_THICKNESS -- верхня поверхня газонів

local TOWN_CENTER = Vector3.new(0, 0, 0)
local TOWN_SIZE = 240 -- збільшено, щоб вмістити подвір'я 45x45
local TOWN_HALF = TOWN_SIZE / 2

local WILD_SIZE = 100
-- Дика зона впритул до східного краю містечка
local WILD_CENTER = Vector3.new(TOWN_HALF + WILD_SIZE / 2, 0, 0)
local WILD_HALF = WILD_SIZE / 2

local PLAZA_SIZE = 40 -- збільшено під фонтани, лавочки й ліхтарі
local PLAZA_HALF = PLAZA_SIZE / 2
local CLEARING_SIZE = 15

local STREET_WIDTH = 6
local STREET_THICKNESS = 0.3

-- Подвір'я та будинки (реальний масштаб: стеля помітно вища за персонажа)
local YARD_SIZE = 45
local YARD_HALF = YARD_SIZE / 2
local HOUSE_SIZE = Vector3.new(34, 16, 30) -- перший поверх: ширина x висота x глибина
local UPPER_SIZE = Vector3.new(30, 16, 26) -- другий поверх
-- Будинок углибині подвір'я (2 studs до заднього паркану), спереду садок
local HOUSE_CENTER_Z = YARD_HALF - 2 - HOUSE_SIZE.Z / 2
local WALL_THICKNESS = 0.5
local FLOOR_THICKNESS = 0.2
local SLAB_THICKNESS = 0.5 -- перекриття між поверхами
local DOOR_WIDTH = 7
local DOOR_HEIGHT = 11 -- ~69% висоти стіни, як і раніше
local ROOF_HEIGHT = 10
local ROOF_OVERHANG = 1.5
local UPPER_ROOF_HEIGHT = 9
local FENCE_GAP = 8 -- ширина входу в паркані з боку вулиці

-- Рослинність
local TREE_MIN_DIST = 12 -- мінімальна відстань між стовбурами дерев
local TREE_CLEAR_RADIUS = 6 -- відступ стовбура від вулиць/подвір'їв (щоб крона не нависала низько)
local PATH_MARGIN = 2 -- мінімальний відступ рослинності від доріжок і подвір'їв

-- Межа світу
local BOUNDARY_INNER_STRIP = 16 -- ширина смуги від краю карти до ігрової зони: від її внутрішнього краю назовні ростуть гори GrassMountain
-- WorldFloor + SafeZoneBoundary: єдина гарантія меж світу, незалежна від гір і декору
local WORLD_FLOOR_MARGIN = 25 -- запас підлоги навколо обох зон з кожного боку
local WORLD_FLOOR_DROP = 0.5 -- верх WorldFloor нижче за газони зон (підкладка, не перекриває траву)
local SAFE_ZONE_EXTRA = 20 -- zone-based радіус = найдальша точка прямокутника підлоги + цей запас
local SAFE_ZONE_MOUNTAIN_MARGIN = 18 -- mountain-based радіус = найдальша точка гір + цей запас
local SAFE_ZONE_SEGMENTS = 32 -- кільце з прямих сегментів
local SAFE_ZONE_OVERLAP = 3.5 -- на скільки кожен сегмент довший за точну сторону з кожного боку (внахлест)
-- SafeZoneBoundary стоїть у тілі гір: внутрішня (до гравця) грань стіни — на MOUNTAIN_WALL_DEPTH studs
-- глибше за підніжжя гір (назовні від лінії ігрової зони). Гравець ступає на камінь і лише тоді впирається в стіну.
local MOUNTAIN_WALL_DEPTH = 17 -- бажаний offset; для тоншої гори її сегмент стіни стає мілкішим (див. 7b)
local MOUNTAIN_WALL_THICKNESS = 2 -- стіна займає смугу [offset, offset + THICKNESS] від підніжжя назовні
local MOUNTAIN_WALL_FALLBACK = 0.75 -- якщо гора тонша за offset + товщину: offset = ця частка її товщини
local MOUNTAIN_FOOT_CLEARANCE = 2.5 -- вільна трава перед підніжжям гір: тут закінчуються вулиця й рослинність
local SAFE_ZONE_THICKNESS = 5
local SAFE_ZONE_BOTTOM = -10 -- починається під землею
local SAFE_ZONE_TOP = 90 -- і йде набагато вище за будь-яку гору чи стрибок

-- Зони високої трави для зустрічей з Wivi та стежки між ними
local WILD_PATH_WIDTH = 3.5
local WILD_PATH_THICKNESS = 0.25 -- трохи нижче за вулицю, щоб не мерехтіли перетини
local ENCOUNTER_GRASS_STEP = 0.9 -- крок сітки травинок (щільність заростей)

-- Мінімальний прохід для стандартного персонажа
local CHARACTER_MIN_HEIGHT = 5
local CHARACTER_MIN_WIDTH = 3

-- Кольори
local GREENS = {
	Color3.fromRGB(50, 180, 60),
	Color3.fromRGB(30, 140, 50),
	Color3.fromRGB(90, 200, 70),
}
local PINK = Color3.fromRGB(255, 120, 180)
local YELLOW = Color3.fromRGB(255, 220, 60)
local WHITE = Color3.fromRGB(250, 250, 250)
local FLOWER_COLORS = { PINK, YELLOW, WHITE, Color3.fromRGB(255, 90, 70), Color3.fromRGB(170, 120, 255) }
local WATER_COLOR = Color3.fromRGB(90, 180, 255)

---------------------------------------------------------------------
-- Допоміжні функції
---------------------------------------------------------------------

-- Створює заякорений Part із заданими властивостями
local function makePart(className, props, parent)
	local part = Instance.new(className)
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props) do
		part[key] = value
	end
	part.Parent = parent
	return part
end

local function makeModel(name, parent)
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	return model
end

local function makeFolder(name, parent)
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

-- Вертикальний циліндр (Cylinder у Roblox орієнтований вздовж X → повертаємо на 90° по Z)
local function makeVerticalCylinder(name, x, bottomY, z, height, diameter, props, parent)
	props.Name = name
	props.Shape = Enum.PartType.Cylinder
	props.Size = Vector3.new(height, diameter, diameter)
	props.CFrame = CFrame.new(x, bottomY + height / 2, z) * CFrame.Angles(0, 0, math.rad(90))
	return makePart("Part", props, parent)
end

-- Проста куля, що "сидить" на землі (камені-заглушки)
local function makeBush(name, position, radius, color, parent)
	return makePart("Part", {
		Name = name,
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(radius * 2, radius * 2, radius * 2),
		Position = Vector3.new(position.X, GROUND_TOP + radius * 0.7, position.Z),
		Material = Enum.Material.Grass,
		Color = color,
	}, parent)
end

---------------------------------------------------------------------
-- Зайняті ділянки: вулиці, площа, подвір'я, галявина, смуга межі.
-- Рослинність не ставиться ближче ніж PATH_MARGIN до них.
---------------------------------------------------------------------
local blockedRects = {}
local streetSegments = {} -- для розкладки декору вздовж вулиць
local placed = {} -- точкові об'єкти: { pos = Vector2, radius = number, isTree = bool }

-- soft = true: вузькі стежки й зарості, від яких достатньо відступити на розмір самого об'єкта
-- (дерево може стояти ближче, крона нависає над стежкою природно)
local function blockRect(minX, maxX, minZ, maxZ, soft)
	table.insert(blockedRects, { minX = minX, maxX = maxX, minZ = minZ, maxZ = maxZ, soft = soft or false })
end

local function markPlaced(x, z, radius, isTree)
	table.insert(placed, { pos = Vector2.new(x, z), radius = radius, isTree = isTree or false })
end

-- Відрізок вулиці між двома точками на одній осі (X або Z); реєструє зайняту ділянку
local function makeStreetSegment(name, x1, z1, x2, z2, parent)
	local size
	if x1 == x2 then
		size = Vector3.new(STREET_WIDTH, STREET_THICKNESS, math.abs(z2 - z1))
	else
		size = Vector3.new(math.abs(x2 - x1), STREET_THICKNESS, STREET_WIDTH)
	end
	local cx, cz = (x1 + x2) / 2, (z1 + z2) / 2
	blockRect(cx - size.X / 2, cx + size.X / 2, cz - size.Z / 2, cz + size.Z / 2)
	table.insert(streetSegments, { x1 = x1, z1 = z1, x2 = x2, z2 = z2 })
	return makePart("Part", {
		Name = name,
		Size = size,
		Position = Vector3.new(cx, GROUND_TOP + STREET_THICKNESS / 2, cz),
		Material = Enum.Material.Ground,
		Color = Color3.fromRGB(150, 105, 60),
	}, parent)
end

---------------------------------------------------------------------
-- 0. Корінь світу: видаляємо старий WivialsWorld і створюємо заново
---------------------------------------------------------------------
local existing = Workspace:FindFirstChild("WivialsWorld")
if existing then
	existing:Destroy()
end

local world = makeFolder("WivialsWorld", Workspace)

-- Лічильники для консольного звіту
local stats = {
	town = { trees = 0, bushes = 0, flowerbeds = 0, lamps = 0, benches = 0, fountains = 0, grassPatches = 0 },
	wild = { trees = 0, bushes = 0, flowerbeds = 0, grass = 0, rocks = 0, encounterZones = 0, paths = 0, grassPatches = 0 },
	boundary = { mountains = 0, minHeight = math.huge, collidable = 0, pushedOut = 0, insidePlayArea = 0 },
	treesByTemplate = {},
}

---------------------------------------------------------------------
-- Рослинність: дерева, чотири типи кущів-кластерів, клумби, висока трава
---------------------------------------------------------------------

-- Сплющена "сфера" (еліпсоїд): Ball-деталь у Roblox завжди ідеально кругла, тому беремо Block
-- з SpecialMesh типу Sphere — меш розтягується під будь-який Size (фізика при цьому — коробка)
local function makeBlob(name, cframe, size, color, collide, parent)
	local part = makePart("Part", {
		Name = name,
		Size = size,
		CFrame = cframe,
		Material = Enum.Material.Grass,
		Color = color,
		CanCollide = collide,
		CanQuery = collide,
	}, parent)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
	return part
end

-- Три відтінки (темний/середній/світлий) від базового кольору — для об'єму крони чи куща
local function shadesOf(color)
	return { color:Lerp(Color3.new(0, 0, 0), 0.25), color, color:Lerp(Color3.new(1, 1, 1), 0.18) }
end

---------------------------------------------------------------------
-- Готові моделі з Workspace.AssetTemplates (дерева, GrassMountain, клапті трави)
---------------------------------------------------------------------
local ServerStorage = game:GetService("ServerStorage")

-- Під час гри шаблони не мають бути видимі у світі: переносимо папку в ServerStorage
-- (у режимі редагування Studio вона лишається у Workspace, як і була)
local assetTemplates = Workspace:FindFirstChild("AssetTemplates")
if assetTemplates then
	assetTemplates.Parent = ServerStorage
else
	warn("[WorldGenerator] Workspace.AssetTemplates not found — trees, GrassMountain and grass patches will be skipped")
end

-- Перший знайдений Model з переліку імен (або nil)
local function findTemplate(names)
	if not assetTemplates then
		return nil
	end
	for _, name in ipairs(names) do
		local t = assetTemplates:FindFirstChild(name)
		if t and t:IsA("Model") then
			return t
		end
	end
	warn("[WorldGenerator] Asset template not found: " .. table.concat(names, " / "))
	return nil
end

-- Лише звичайні дерева; TreeTemplatePine/Desert/Snow — для майбутніх біомів
local treeTemplates = {}
for _, name in ipairs({ "TreeTemplate", "TreeTemplate2", "TreeTemplate3", "TreeTemplate4" }) do
	local t = findTemplate({ name })
	if t then
		table.insert(treeTemplates, t)
	end
end
local mountainTemplate = findTemplate({ "GrassMountain" })
local grassTemplate = findTemplate({ "GrassPatchTemplate", "grass" })

-- Осе-орієнтовані межі моделі у світі (точно для коробок; для MeshPart — за їхнім Size)
local function worldBounds(model)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = -minV
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local cf, s = d.CFrame, d.Size
			local r, u, b = cf.RightVector, cf.UpVector, cf.ZVector
			local half = Vector3.new(
				math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(b.X) * s.Z,
				math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(b.Y) * s.Z,
				math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(b.Z) * s.Z
			) / 2
			minV = minV:Min(cf.Position - half)
			maxV = maxV:Max(cf.Position + half)
		end
	end
	return minV, maxV
end

-- Віддзеркалення моделі по її локальній осі X. Roblox не має від'ємного масштабу, тому кожна
-- деталь отримує дзеркальну позицію та поворот M·R·M (M = diag(-1, 1, 1) — знову правильний поворот).
-- Для симетричних деталей це точне дзеркало; геометрія самого MeshPart не перевертається.
local function mirrorModelX(model)
	local pivot = model:GetPivot()
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = pivot:ToObjectSpace(d.CFrame):GetComponents()
			d.CFrame = pivot * CFrame.new(-x, y, z, r00, -r01, -r02, -r10, r11, r12, -r20, r21, r22)
		end
	end
end

-- Клон шаблону з варіацією: масштаб, поворот по Y, опційне віддзеркалення.
-- Усе заякорюється; collide = false вимикає колізію (фон), collide = true примусово вмикає її
-- (гори межі), nil — лишає як у шаблоні.
-- Модель ставиться так, що опорна точка (pivot) — над (x, z), а найнижча точка торкається газону.
local function cloneTemplate(template, x, z, opts)
	local clone = template:Clone()
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			if opts.collide == true then
				d.CanCollide = true
				d.CanQuery = true
			elseif opts.collide == false then
				d.CanCollide = false
				d.CanQuery = false
				d.CanTouch = false
			end
		end
	end
	clone:ScaleTo(clone:GetScale() * opts.scale)
	if opts.mirror then
		mirrorModelX(clone)
	end

	-- Поворот по Y додається до власної орієнтації шаблону (не скидає її)
	local pivot = clone:GetPivot()
	clone:PivotTo(CFrame.new(x, pivot.Position.Y, z) * CFrame.Angles(0, opts.yaw, 0) * pivot.Rotation)
	local minV = worldBounds(clone)
	clone:PivotTo(clone:GetPivot() + Vector3.new(0, GROUND_TOP - (opts.sink or 0) - minV.Y, 0))
	return clone
end

-- Дерево: випадковий з 4 шаблонів, масштаб 0.8-1.3, поворот 0-360°, у ~30% випадків — віддзеркалення.
-- collide = false — для фонових дерев. Повертає модель або nil, якщо шаблонів немає.
local function makeTree(name, x, z, parent, collide)
	if #treeTemplates == 0 then
		return nil
	end
	local template = treeTemplates[rng:NextInteger(1, #treeTemplates)]
	local tree = cloneTemplate(template, x, z, {
		scale = rng:NextNumber(0.8, 1.3),
		yaw = rng:NextNumber(0, math.pi * 2),
		mirror = rng:NextNumber() < 0.3,
		collide = collide,
	})
	tree.Name = name
	tree:SetAttribute("Template", template.Name)
	tree.Parent = parent
	stats.treesByTemplate[template.Name] = (stats.treesByTemplate[template.Name] or 0) + 1
	return tree
end

-- Кластер куща: 3-5 сплющених "сфер" різного розміру, щільно згрупованих із випадковим зміщенням.
-- center — точка на землі (Y ігнорується, якщо baseY не задано); diameter — загальний розмір куща;
-- stretch — напрямок видовження (для овальних кущів) або nil. Повертає список частин-лопатей.
local function makeBushCluster(parent, center, diameter, color, collide, opts)
	opts = opts or {}
	local shades = shadesOf(color)
	local baseY = opts.baseY or (GROUND_TOP + diameter * 0.28)
	local lobes = {}
	local count = opts.lobes or rng:NextInteger(3, 5)
	for i = 1, count do
		local d = diameter * ((i == 1) and rng:NextNumber(0.62, 0.72) or rng:NextNumber(0.4, 0.6))
		local size = Vector3.new(d * rng:NextNumber(0.9, 1.15), d * rng:NextNumber(0.62, 0.78), d * rng:NextNumber(0.9, 1.15))
		local offset
		if opts.stretch then
			-- Видовжений кущ: лопаті вздовж заданого напрямку
			local along = (i - (count + 1) / 2) * diameter * 0.28
			offset = opts.stretch * along + Vector3.new(rng:NextNumber(-0.3, 0.3), 0, rng:NextNumber(-0.3, 0.3)) * diameter
		else
			local a = rng:NextNumber(0, math.pi * 2)
			local dist = (i == 1) and 0 or rng:NextNumber(0.15, 0.3) * diameter
			offset = Vector3.new(math.cos(a) * dist, 0, math.sin(a) * dist)
		end
		offset += Vector3.new(0, rng:NextNumber(-0.05, 0.15) * diameter, 0)
		local cf = CFrame.new(center.X + offset.X, baseY + offset.Y, center.Z + offset.Z)
			* CFrame.Angles(rng:NextNumber(-0.15, 0.15), rng:NextNumber(0, math.pi * 2), rng:NextNumber(-0.15, 0.15))
		table.insert(lobes, makeBlob("Leaves" .. i, cf, size, shades[rng:NextInteger(1, #shades)], collide, parent))
	end
	return lobes
end

-- Дрібні кольорові цятки (ягоди/квіти) на верхній частині поверхні лопатей куща
local function addBushDots(lobes, colors, count, parent)
	for i = 1, count do
		local lobe = lobes[rng:NextInteger(1, #lobes)]
		local yaw = rng:NextNumber(0, math.pi * 2)
		local pitch = rng:NextNumber(0.25, 1.1)
		local unit = Vector3.new(math.cos(yaw) * math.cos(pitch), math.sin(pitch), math.sin(yaw) * math.cos(pitch))
		local half = lobe.Size / 2
		local point = lobe.CFrame:PointToWorldSpace(Vector3.new(unit.X * half.X, unit.Y * half.Y, unit.Z * half.Z))
		makePart("Part", {
			Name = "Dot" .. i,
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.45, 0.45, 0.45),
			Position = point,
			Material = Enum.Material.SmoothPlastic,
			Color = colors[rng:NextInteger(1, #colors)],
			CanCollide = false,
			CanQuery = false,
		}, parent)
	end
end

-- Кущ одного з чотирьох типів (усі — горбкуваті кластери сплющених "сфер"):
-- "round" — компактний; "oval" — видовжений; "berry" — з червоними/рожевими ягідками;
-- "flowering" — з білими/жовтими квіточками. Повертає модель.
local BUSH_TYPES = { "round", "oval", "berry", "flowering" }
local BUSH_BODY_RADIUS = { round = 1.8, oval = 3, berry = 1.8, flowering = 1.8 }
local BERRY_DOT_COLORS = { Color3.fromRGB(220, 30, 50), PINK }
local FLOWER_DOT_COLORS = { WHITE, YELLOW }

local function makeBushOfType(kind, name, position, color, parent)
	local bush = makeModel(name, parent)
	local lobes
	if kind == "oval" then
		local a = rng:NextNumber(0, math.pi * 2)
		lobes = makeBushCluster(bush, position, rng:NextNumber(3.2, 4), color, true, {
			stretch = Vector3.new(math.cos(a), 0, math.sin(a)),
			lobes = rng:NextInteger(4, 5),
		})
	else
		lobes = makeBushCluster(bush, position, rng:NextNumber(2.6, 3.4), color, true)
	end
	bush.PrimaryPart = lobes[1]

	if kind == "berry" then
		addBushDots(lobes, BERRY_DOT_COLORS, rng:NextInteger(3, 6), bush)
	elseif kind == "flowering" then
		addBushDots(lobes, FLOWER_DOT_COLORS, rng:NextInteger(3, 6), bush)
	end
	return bush
end

-- Квіткова клумба: низький циліндр землі + кілька кольорових кульок-квітів
local function makeFlowerBed(name, worldPos, flowerColors, parent, baseY)
	baseY = baseY or GROUND_TOP
	local bed = makeModel(name, parent)
	bed.PrimaryPart = makeVerticalCylinder("Soil", worldPos.X, baseY, worldPos.Z, 0.4, 2.4, {
		Material = Enum.Material.Ground,
		Color = Color3.fromRGB(110, 70, 45),
	}, bed)

	for i = 1, 5 do
		local angle = (i / 5) * math.pi * 2
		local r = (i == 5) and 0 or 0.7
		makePart("Part", {
			Name = "Flower" .. i,
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.7, 0.7, 0.7),
			Position = Vector3.new(worldPos.X + math.cos(angle) * r, baseY + 0.6, worldPos.Z + math.sin(angle) * r),
			Material = Enum.Material.SmoothPlastic,
			Color = flowerColors[(i - 1) % #flowerColors + 1],
		}, bed)
	end
	return bed
end

-- Випадкова палітра з 2-3 кольорів для клумби
local function randomFlowerPalette()
	local palette = {}
	for _ = 1, rng:NextInteger(2, 3) do
		table.insert(palette, FLOWER_COLORS[rng:NextInteger(1, #FLOWER_COLORS)])
	end
	return palette
end

-- Ділянка високої трави: кластер тонких високих стебел з легким нахилом (прохідна)
local GRASS_COLORS = { Color3.fromRGB(70, 170, 50), Color3.fromRGB(110, 185, 60), Color3.fromRGB(150, 190, 70) }

local function makeTallGrass(name, position, parent)
	local patch = makeModel(name, parent)
	for i = 1, rng:NextInteger(8, 14) do
		local h = rng:NextNumber(2, 3.5)
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(0, 2.2)
		local cf = CFrame.new(position.X + math.cos(angle) * dist, GROUND_TOP, position.Z + math.sin(angle) * dist)
			* CFrame.Angles(rng:NextNumber(-0.25, 0.25), rng:NextNumber(0, math.pi), rng:NextNumber(-0.25, 0.25))
			* CFrame.new(0, h / 2, 0)
		makePart("Part", {
			Name = "Blade" .. i,
			Size = Vector3.new(0.3, h, 0.3),
			CFrame = cf,
			Material = Enum.Material.Grass,
			Color = GRASS_COLORS[rng:NextInteger(1, #GRASS_COLORS)],
			CanCollide = false,
		}, patch)
	end
	return patch
end

---------------------------------------------------------------------
-- Пошук вільного місця для рослинності
---------------------------------------------------------------------

-- Чи вільна точка: не ближче PATH_MARGIN до зайнятих ділянок і не ближче `gap` (типово 1) до інших об'єктів
local function canPlace(x, z, clearRadius, bodyRadius, isTree, gap)
	for _, r in ipairs(blockedRects) do
		local m = (r.soft and bodyRadius or clearRadius) + PATH_MARGIN
		if x > r.minX - m and x < r.maxX + m and z > r.minZ - m and z < r.maxZ + m then
			return false
		end
	end
	local p = Vector2.new(x, z)
	for _, o in ipairs(placed) do
		local d = (p - o.pos).Magnitude
		if d < bodyRadius + o.radius + (gap or 1) then
			return false
		end
		if isTree and o.isTree and d < TREE_MIN_DIST then
			return false
		end
	end
	return true
end

-- Випадкова вільна точка в зоні (center, half) або nil
local function findSpot(center, half, clearRadius, bodyRadius, isTree, gap)
	local inset = half - clearRadius - 1
	for _ = 1, 300 do
		local x = center.X + rng:NextNumber(-inset, inset)
		local z = center.Z + rng:NextNumber(-inset, inset)
		if canPlace(x, z, clearRadius, bodyRadius, isTree, gap) then
			markPlaced(x, z, bodyRadius, isTree)
			return Vector3.new(x, 0, z)
		end
	end
	return nil
end

-- Випадкова вільна точка на узбіччі однієї з вулиць містечка (з відступом від краю) або nil
local function findSpotAlongStreet(radius)
	local streetHalf = STREET_WIDTH / 2
	for _ = 1, 300 do
		local seg = streetSegments[rng:NextInteger(1, #streetSegments)]
		local t = rng:NextNumber(0, 1)
		local px, pz = seg.x1 + (seg.x2 - seg.x1) * t, seg.z1 + (seg.z2 - seg.z1) * t
		local side = (rng:NextNumber() < 0.5) and -1 or 1
		local offset = side * (streetHalf + PATH_MARGIN + radius + 0.5 + rng:NextNumber(0, 2))
		local x, z = px, pz
		if seg.x1 == seg.x2 then
			x += offset
		else
			z += offset
		end
		local insideTown = math.abs(x) < TOWN_HALF - BOUNDARY_INNER_STRIP and math.abs(z) < TOWN_HALF - BOUNDARY_INNER_STRIP
		if insideTown and canPlace(x, z, radius, radius, false) then
			markPlaced(x, z, radius, false)
			return Vector3.new(x, 0, z)
		end
	end
	return nil
end

-- Розкидає по зоні дерева, кущі й клумби
local function scatterVegetation(center, half, parent, counts, zoneStats)
	local treesFolder = parent:FindFirstChild("Trees") or makeFolder("Trees", parent)
	for i = 1, counts.trees do
		local pos = findSpot(center, half, TREE_CLEAR_RADIUS, 2, true)
		if pos and makeTree("Tree" .. i, pos.X, pos.Z, treesFolder) then
			zoneStats.trees += 1
		end
	end

	local bushesFolder = parent:FindFirstChild("Bushes") or makeFolder("Bushes", parent)
	for i = 1, counts.bushes do
		local kind = BUSH_TYPES[(i - 1) % #BUSH_TYPES + 1] -- рівномірно всі три типи
		local r = BUSH_BODY_RADIUS[kind]
		local pos = findSpot(center, half, r, r, false)
		if pos then
			local color = GREENS[rng:NextInteger(1, #GREENS)]:Lerp(Color3.new(0, 0, 0), counts.bushShade)
			makeBushOfType(kind, "Bush" .. i, pos, color, bushesFolder)
			zoneStats.bushes += 1
		end
	end

	local bedsFolder = parent:FindFirstChild("Flowerbeds") or makeFolder("Flowerbeds", parent)
	for i = 1, counts.flowerbeds do
		local pos = findSpot(center, half, 1.3, 1.3, false)
		if pos then
			makeFlowerBed("Flowerbed" .. i, pos, randomFlowerPalette(), bedsFolder)
			zoneStats.flowerbeds += 1
		end
	end
end

---------------------------------------------------------------------
-- 1. Містечко (TownArea): газон і площа
---------------------------------------------------------------------
local town = makeModel("TownArea", world)

-- Газон-основа містечка
town.PrimaryPart = makePart("Part", {
	Name = "TownGround",
	Size = Vector3.new(TOWN_SIZE, GROUND_THICKNESS, TOWN_SIZE),
	Position = TOWN_CENTER + Vector3.new(0, GROUND_THICKNESS / 2, 0),
	Material = Enum.Material.Grass,
	Color = Color3.fromRGB(110, 210, 80),
}, town)

-- Центральна площа, трохи "втоплена" в газон, щоб сходинка була невеликою
local PLAZA_TOP = GROUND_TOP + 0.5
makePart("Part", {
	Name = "TownPlaza",
	Size = Vector3.new(PLAZA_SIZE, 1, PLAZA_SIZE),
	Position = TOWN_CENTER + Vector3.new(0, PLAZA_TOP - 0.5, 0),
	Material = Enum.Material.Slate,
	Color = Color3.fromRGB(200, 200, 195),
}, town)
blockRect(-PLAZA_HALF, PLAZA_HALF, -PLAZA_HALF, PLAZA_HALF)

---------------------------------------------------------------------
-- 2. Подвір'я з будинками (HouseYard1-3)
--    Усе будується в локальній системі подвір'я: -Z = фасад, звідки підходить вулиця
---------------------------------------------------------------------

-- Прямокутна "плита" в локальних координатах будинку (x1..x2, z1..z2)
local function makeSlab(name, hcf, x1, x2, z1, z2, bottomY, thickness, color, material, parent)
	return makePart("Part", {
		Name = name,
		Size = Vector3.new(x2 - x1, thickness, z2 - z1),
		CFrame = hcf * CFrame.new((x1 + x2) / 2, bottomY + thickness / 2, (z1 + z2) / 2),
		Material = material,
		Color = color,
	}, parent)
end

-- Чотири стіни коробки розміром size, що стоїть на висоті baseY; опційно з дверним прорізом спереду
local function makeWalls(prefix, hcf, baseY, size, color, withDoor, parent)
	local w, h, d = size.X, size.Y, size.Z
	local t = WALL_THICKNESS
	local wallY = baseY + h / 2

	local function wall(wallName, wallSize, localPos)
		return makePart("Part", {
			Name = prefix .. wallName,
			Size = wallSize,
			CFrame = hcf * CFrame.new(localPos),
			Material = Enum.Material.SmoothPlastic,
			Color = color,
		}, parent)
	end

	-- Задня та бічні стіни (бічні вставлені між передньою і задньою)
	wall("WallBack", Vector3.new(w, h, t), Vector3.new(0, wallY, d / 2 - t / 2))
	wall("WallLeft", Vector3.new(t, h, d - 2 * t), Vector3.new(-(w / 2 - t / 2), wallY, 0))
	wall("WallRight", Vector3.new(t, h, d - 2 * t), Vector3.new(w / 2 - t / 2, wallY, 0))

	local frontZ = -(d / 2 - t / 2)
	if not withDoor then
		wall("WallFront", Vector3.new(w, h, t), Vector3.new(0, wallY, frontZ))
		return frontZ
	end

	-- Передня стіна з прорізом під двері: дві бічні частини + перемичка над дверима
	local sideWidth = (w - DOOR_WIDTH) / 2
	local sideX = DOOR_WIDTH / 2 + sideWidth / 2
	wall("WallFrontLeft", Vector3.new(sideWidth, h, t), Vector3.new(-sideX, wallY, frontZ))
	wall("WallFrontRight", Vector3.new(sideWidth, h, t), Vector3.new(sideX, wallY, frontZ))
	local lintelHeight = h - DOOR_HEIGHT
	wall("WallFrontLintel", Vector3.new(DOOR_WIDTH, lintelHeight, t),
		Vector3.new(0, baseY + DOOR_HEIGHT + lintelHeight / 2, frontZ))
	return frontZ
end

-- Двосхилий дах із двох WedgePart над коробкою w x d, гребінь уздовж X
local function makeRoof(prefix, hcf, baseY, w, d, roofHeight, overhang, color, parent)
	local halfDepth = d / 2 + overhang
	local roofY = baseY + roofHeight / 2
	local wedgeSize = Vector3.new(w + overhang * 2, roofHeight, halfDepth)
	-- WedgePart: висока грань на +Z, схил спускається до -Z
	makePart("WedgePart", {
		Name = prefix .. "RoofFront",
		Size = wedgeSize,
		CFrame = hcf * CFrame.new(0, roofY, -halfDepth / 2),
		Material = Enum.Material.SmoothPlastic,
		Color = color,
	}, parent)
	-- Друга половина розвернута на 180°, щоб схил ішов до +Z
	makePart("WedgePart", {
		Name = prefix .. "RoofBack",
		Size = wedgeSize,
		CFrame = hcf * CFrame.new(0, roofY, halfDepth / 2) * CFrame.Angles(0, math.pi, 0),
		Material = Enum.Material.SmoothPlastic,
		Color = color,
	}, parent)
end

-- Будинок: порожня коробка зі стін, підлога, дверний проріз, дах, меблі;
-- при variant.twoStory — перекриття з отвором, сходи і менший другий поверх зі своїм дахом
local function makeHouse(name, yardCf, variant, parent)
	local house = makeModel(name, parent)
	local hcf = yardCf * CFrame.new(0, 0, HOUSE_CENTER_Z)
	local w, h, d = HOUSE_SIZE.X, HOUSE_SIZE.Y, HOUSE_SIZE.Z
	local t = WALL_THICKNESS
	local innerX, innerZ = w / 2 - t, d / 2 - t -- піврозміри внутрішнього простору

	-- Перший поверх
	local frontZ = makeWalls("", hcf, GROUND_TOP, HOUSE_SIZE, variant.wall, true, house)

	-- Підлога всередині периметра стін
	house.PrimaryPart = makeSlab("Floor", hcf, -innerX, innerX, -innerZ, innerZ,
		GROUND_TOP, FLOOR_THICKNESS, Color3.fromRGB(200, 150, 100), Enum.Material.WoodPlanks, house)
	local floorTop = GROUND_TOP + FLOOR_THICKNESS

	-- Дверна панель у прорізі; без колізії, тож гравець проходить крізь неї
	-- TODO: справжні двері, що відчиняються (ProximityPrompt + TweenService на шарнірі)
	makePart("Part", {
		Name = "Door",
		Size = Vector3.new(DOOR_WIDTH, DOOR_HEIGHT, 0.2),
		CFrame = hcf * CFrame.new(0, GROUND_TOP + DOOR_HEIGHT / 2, frontZ),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(120, 70, 35),
		CanCollide = false,
	}, house)

	-- Меблі-заглушки: стіл і шафа ліворуч спереду, ліжко праворуч (задня ліва смуга — під сходи)
	local furniture = makeModel("Furniture", house)
	local function furnitureBox(partName, size, x, z, color, material)
		return makePart("Part", {
			Name = partName,
			Size = size,
			CFrame = hcf * CFrame.new(x, floorTop + size.Y / 2, z),
			Material = material or Enum.Material.Wood,
			Color = color,
		}, furniture)
	end
	furnitureBox("Table", Vector3.new(4, 3, 3), -8, -5, Color3.fromRGB(150, 95, 50))
	furnitureBox("Wardrobe", Vector3.new(2.5, 8, 5), -innerX + 1.25, -8, Color3.fromRGB(130, 80, 45))
	furnitureBox("Bed", Vector3.new(4.5, 1.5, 8), 12, 4, variant.blanket, Enum.Material.Fabric)
	makePart("Part", {
		Name = "Pillow",
		Size = Vector3.new(3.4, 0.6, 1.4),
		CFrame = hcf * CFrame.new(12, floorTop + 1.8, 7.2),
		Material = Enum.Material.Fabric,
		Color = WHITE,
	}, furniture)

	if not variant.twoStory then
		makeRoof("", hcf, GROUND_TOP + h, w, d, ROOF_HEIGHT, ROOF_OVERHANG, variant.roof, house)
		return house
	end

	-- Перекриття між поверхами на стінах першого поверху, з отвором над сходами.
	-- Сходи йдуть уздовж задньої стіни зліва направо, у межах внутрішнього простору другого поверху.
	local slabBottom = GROUND_TOP + h
	local slabTop = slabBottom + SLAB_THICKNESS
	local upperInnerX = UPPER_SIZE.X / 2 - t
	local upperInnerZ = UPPER_SIZE.Z / 2 - t
	local stepCount = 17 -- підйом ~0.96 stud на сходинку при висоті поверху 16
	local stepDepth = 1.1
	local stairWidth = 4
	local holeX1 = -upperInnerX
	local holeX2 = holeX1 + stepCount * stepDepth -- далі — майданчик другого поверху
	local holeZ2 = upperInnerZ
	local holeZ1 = holeZ2 - stairWidth

	local slabColor = Color3.fromRGB(190, 140, 95)
	local slab = makeModel("FloorSlab", house)
	local ox, oz = w / 2, d / 2
	local planks = Enum.Material.WoodPlanks
	makeSlab("Left", hcf, -ox, holeX1, -oz, oz, slabBottom, SLAB_THICKNESS, slabColor, planks, slab)
	makeSlab("Right", hcf, holeX2, ox, -oz, oz, slabBottom, SLAB_THICKNESS, slabColor, planks, slab)
	makeSlab("Front", hcf, holeX1, holeX2, -oz, holeZ1, slabBottom, SLAB_THICKNESS, slabColor, planks, slab)
	makeSlab("Back", hcf, holeX1, holeX2, holeZ2, oz, slabBottom, SLAB_THICKNESS, slabColor, planks, slab)

	-- Сходи: суцільні сходинки, остання — врівень із перекриттям
	local stairs = makeModel("Stairs", house)
	local rise = (slabTop - floorTop) / stepCount
	for k = 1, stepCount do
		local stepH = k * rise
		makePart("Part", {
			Name = "Step" .. k,
			Size = Vector3.new(stepDepth, stepH, stairWidth),
			CFrame = hcf * CFrame.new(holeX1 + (k - 0.5) * stepDepth, floorTop + stepH / 2, (holeZ1 + holeZ2) / 2),
			Material = Enum.Material.WoodPlanks,
			Color = Color3.fromRGB(170, 115, 70),
		}, stairs)
	end

	-- Поруччя вздовж отвору на другому поверсі (з боку кімнати)
	makePart("Part", {
		Name = "Railing",
		Size = Vector3.new(holeX2 - holeX1, 3, 0.2),
		CFrame = hcf * CFrame.new((holeX1 + holeX2) / 2, slabTop + 1.5, holeZ1 - 0.1),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(120, 70, 35),
	}, stairs)

	-- Другий поверх: менша коробка без дверей, одна заглушка-скриня, власний дах
	makeWalls("Upper", hcf, slabTop, UPPER_SIZE, variant.wall, false, house)
	makePart("Part", {
		Name = "UpperChest",
		Size = Vector3.new(3, 2, 2),
		CFrame = hcf * CFrame.new(7, slabTop + 1, -5),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(150, 95, 50),
	}, house)
	makeRoof("Upper", hcf, slabTop + UPPER_SIZE.Y, UPPER_SIZE.X, UPPER_SIZE.Z,
		UPPER_ROOF_HEIGHT, ROOF_OVERHANG, variant.roof, house)

	return house
end

-- Відрізок паркану між двома локальними точками подвір'я: стовпчики + дві поперечини
local function makeFence(name, yardCf, a, b, color, parent)
	local fence = makeModel(name, parent)
	local length = (b - a).Magnitude
	local midCf = CFrame.lookAt((a + b) / 2, b)

	for i, railY in ipairs({ 1, 2.2 }) do
		makePart("Part", {
			Name = "Rail" .. i,
			Size = Vector3.new(0.25, 0.3, length),
			CFrame = yardCf * (CFrame.new(0, GROUND_TOP + railY, 0) * midCf),
			Material = Enum.Material.Wood,
			Color = color,
		}, fence)
	end

	local postCount = math.max(2, math.floor(length / 3) + 1)
	for i = 0, postCount - 1 do
		local p = a:Lerp(b, i / (postCount - 1))
		makePart("Part", {
			Name = "Post" .. (i + 1),
			Size = Vector3.new(0.4, 3, 0.4),
			CFrame = yardCf * CFrame.new(p.X, GROUND_TOP + 1.5, p.Z),
			Material = Enum.Material.Wood,
			Color = color,
		}, fence)
	end
	return fence
end

-- Подвір'я: будинок + паркан із входом + доріжка до дверей + дерева, кущі й клумби
-- `front` — напрямок у світі від центру подвір'я до вулиці
local function makeYard(index, center, front, variant, parent)
	local yard = makeModel("HouseYard" .. index, parent)
	blockRect(center.X - YARD_HALF, center.X + YARD_HALF, center.Z - YARD_HALF, center.Z + YARD_HALF)
	-- lookAt спрямовує локальну -Z у бік `front`
	local yardCf = CFrame.lookAt(center, center + front)
	local function toWorld(x, z)
		return (yardCf * CFrame.new(x, 0, z)).Position
	end

	makeHouse("House" .. index, yardCf, variant, yard)

	-- Паркан по периметру, з проміжком-входом посередині фасаду
	local e = YARD_HALF - 0.2
	local g = FENCE_GAP / 2
	local fences = makeModel("Fence", yard)
	makeFence("FrontLeft", yardCf, Vector3.new(-e, 0, -e), Vector3.new(-g, 0, -e), variant.fence, fences)
	makeFence("FrontRight", yardCf, Vector3.new(g, 0, -e), Vector3.new(e, 0, -e), variant.fence, fences)
	makeFence("Left", yardCf, Vector3.new(-e, 0, -e), Vector3.new(-e, 0, e), variant.fence, fences)
	makeFence("Right", yardCf, Vector3.new(e, 0, -e), Vector3.new(e, 0, e), variant.fence, fences)
	makeFence("Back", yardCf, Vector3.new(-e, 0, e), Vector3.new(e, 0, e), variant.fence, fences)

	-- Доріжка від входу в паркані до дверей
	local houseFrontZ = HOUSE_CENTER_Z - HOUSE_SIZE.Z / 2
	local walkLength = houseFrontZ + YARD_HALF
	makePart("Part", {
		Name = "YardPath",
		Size = Vector3.new(4, STREET_THICKNESS, walkLength),
		CFrame = yardCf * CFrame.new(0, GROUND_TOP + STREET_THICKNESS / 2, -YARD_HALF + walkLength / 2),
		Material = Enum.Material.Ground,
		Color = Color3.fromRGB(165, 120, 75),
	}, yard)

	local garden = makeModel("Garden", yard)

	-- Два дерева в передніх кутах подвір'я (відсунуті ближче до паркану, щоб крона не врізалась у фасад)
	for i, x in ipairs({ -16, 16 }) do
		local p = toWorld(x, -19.5)
		if makeTree("Tree" .. i, p.X, p.Z, garden) then
			stats.town.trees += 1
		end
	end

	-- 6-8 кущів (круглі або з ягодами) уздовж бічних парканів, у смузі між стіною (±17) і огорожею (±22.3)
	local bushSpots = {
		Vector2.new(-19.8, -14), Vector2.new(19.8, -14),
		Vector2.new(-19.8, -4), Vector2.new(19.8, -4),
		Vector2.new(-19.8, 6), Vector2.new(19.8, 6),
		Vector2.new(-19.8, 16), Vector2.new(19.8, 16),
	}
	for i = 1, rng:NextInteger(6, 8) do
		local spot = bushSpots[i]
		local kind = (rng:NextNumber() < 0.5) and "round" or "berry"
		makeBushOfType(kind, "Bush" .. i, toWorld(spot.X, spot.Y), variant.bush, garden)
		stats.town.bushes += 1
	end

	-- 3-4 квіткові клумби обабіч доріжки
	local bedSpots = { Vector2.new(-7, -16), Vector2.new(7, -16), Vector2.new(-7, -12.5), Vector2.new(7, -12.5) }
	for i = 1, rng:NextInteger(3, 4) do
		local spot = bedSpots[i]
		makeFlowerBed("Flowerbed" .. i, toWorld(spot.X, spot.Y), variant.flowers, garden)
		stats.town.flowerbeds += 1
	end

	return yard
end

-- Три легкі варіації кольорів для подвір'їв; другий будинок — двоповерховий
local VARIANTS = {
	{
		wall = Color3.fromRGB(255, 240, 200), roof = Color3.fromRGB(220, 50, 50),
		fence = Color3.fromRGB(235, 225, 205), bush = Color3.fromRGB(60, 170, 60),
		blanket = Color3.fromRGB(80, 140, 230), flowers = { PINK, WHITE },
	},
	{
		wall = Color3.fromRGB(255, 230, 140), roof = Color3.fromRGB(50, 110, 230),
		fence = Color3.fromRGB(170, 115, 65), bush = Color3.fromRGB(45, 150, 70),
		blanket = Color3.fromRGB(230, 90, 90), flowers = { YELLOW, WHITE, PINK },
		twoStory = true,
	},
	{
		wall = Color3.fromRGB(250, 225, 210), roof = Color3.fromRGB(150, 70, 200),
		fence = Color3.fromRGB(130, 85, 50), bush = Color3.fromRGB(75, 185, 75),
		blanket = Color3.fromRGB(250, 200, 60), flowers = { PINK, YELLOW },
	},
}

---------------------------------------------------------------------
-- 3. Вулична мережа (Street1-4) від площі
--    Street1: на схід до WildArea
--    Street2: на південь до HouseYard1
--    Street3: на захід до T-перехрестя, звідки дві гілки ведуть до HouseYard2 і HouseYard3
--    Street4: на північ, тупик біля гір із табличкою "Скоро тут буде більше"
---------------------------------------------------------------------
local streets = makeFolder("Streets", town)
local yards = makeFolder("HouseYards", town)
local streetHalf = STREET_WIDTH / 2

-- Street1 → центр дикої зони
local street1 = makeModel("Street1", streets)
makeStreetSegment("Segment", PLAZA_HALF, 0, WILD_CENTER.X, 0, street1)

-- Street2 → HouseYard1 (на південь від площі)
local yard1Center = Vector3.new(0, 0, 75)
local street2 = makeModel("Street2", streets)
makeStreetSegment("Segment", 0, PLAZA_HALF, 0, yard1Center.Z - YARD_HALF, street2)
makeYard(1, yard1Center, Vector3.new(0, 0, -1), VARIANTS[1], yards)

-- Street3 → T-перехрестя на заході, гілки на північ і південь
local junctionX = -70
local yard2Center = Vector3.new(junctionX, 0, -60)
local yard3Center = Vector3.new(junctionX, 0, 60)
local street3 = makeModel("Street3", streets)
-- Стовбур доходить до дальнього краю перехрестя, гілки починаються від його країв (без накладання)
makeStreetSegment("Trunk", -PLAZA_HALF, 0, junctionX - streetHalf, 0, street3)
makeStreetSegment("BranchNorth", junctionX, -streetHalf, junctionX, yard2Center.Z + YARD_HALF, street3)
makeStreetSegment("BranchSouth", junctionX, streetHalf, junctionX, yard3Center.Z - YARD_HALF, street3)
makeYard(2, yard2Center, Vector3.new(0, 0, 1), VARIANTS[2], yards)
makeYard(3, yard3Center, Vector3.new(0, 0, -1), VARIANTS[3], yards)

-- Street4 → тупикова дорога на північ, "вихід" зі світу на майбутнє (поки впирається в гори)
local exitEndZ = -(TOWN_HALF - BOUNDARY_INNER_STRIP - MOUNTAIN_FOOT_CLEARANCE) -- закінчується трохи перед підніжжям гір
local street4 = makeModel("Street4", streets)
makeStreetSegment("DeadEnd", 0, -PLAZA_HALF, 0, exitEndZ, street4)

do
	-- Барикада + табличка в кінці дороги (без функції, лише позначка)
	local barricade = makeModel("ComingSoonBarricade", street4)
	local barricadeZ = exitEndZ + 1
	for i, x in ipairs({ -3.5, 3.5 }) do
		makePart("Part", {
			Name = "Post" .. i,
			Size = Vector3.new(0.5, 7, 0.5),
			Position = Vector3.new(x, GROUND_TOP + 3.5, barricadeZ),
			Material = Enum.Material.Wood,
			Color = Color3.fromRGB(120, 75, 40),
		}, barricade)
	end
	for i, plank in ipairs({ { y = 1.5, color = Color3.fromRGB(220, 50, 50) }, { y = 3, color = WHITE } }) do
		makePart("Part", {
			Name = "Plank" .. i,
			Size = Vector3.new(8, 0.6, 0.3),
			Position = Vector3.new(0, GROUND_TOP + plank.y, barricadeZ - 0.4),
			Material = Enum.Material.SmoothPlastic,
			Color = plank.color,
		}, barricade)
	end
	local signBoard = makePart("Part", {
		Name = "SignBoard",
		Size = Vector3.new(7.5, 2.5, 0.3),
		Position = Vector3.new(0, GROUND_TOP + 5.5, barricadeZ - 0.4),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(200, 160, 110),
	}, barricade)
	-- Текст на боці, зверненому до площі (+Z)
	local signGui = Instance.new("SurfaceGui")
	signGui.Face = Enum.NormalId.Back
	signGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	signGui.PixelsPerStud = 40
	signGui.Parent = signBoard
	local signText = Instance.new("TextLabel")
	signText.Size = UDim2.fromScale(1, 1)
	signText.BackgroundTransparency = 1
	signText.Text = "Скоро тут буде більше"
	signText.TextScaled = true
	signText.Font = Enum.Font.SourceSansBold
	signText.TextColor3 = Color3.fromRGB(70, 40, 20)
	signText.Parent = signGui
	markPlaced(0, barricadeZ, 4.5)
end

---------------------------------------------------------------------
-- 4. Декор містечка: фонтани, лавочки, ліхтарі, клумби й кущі на площі та вздовж вулиць
---------------------------------------------------------------------
local decor = makeFolder("Decor", town)

-- Лавочка: сидіння + дві ніжки
local function makeBench(name, position, baseY, yRotation)
	local bench = makeModel(name, decor)
	local base = CFrame.new(position.X, baseY, position.Z) * CFrame.Angles(0, yRotation, 0)
	local woodColor = Color3.fromRGB(160, 100, 50)

	bench.PrimaryPart = makePart("Part", {
		Name = "Seat",
		Size = Vector3.new(5, 0.4, 1.6),
		CFrame = base * CFrame.new(0, 1.2, 0),
		Material = Enum.Material.Wood,
		Color = woodColor,
	}, bench)
	for i, offsetX in ipairs({ -2, 2 }) do
		makePart("Part", {
			Name = "Leg" .. i,
			Size = Vector3.new(0.4, 1, 1.4),
			CFrame = base * CFrame.new(offsetX, 0.5, 0),
			Material = Enum.Material.Wood,
			Color = woodColor,
		}, bench)
	end
	markPlaced(position.X, position.Z, 2.6)
	stats.town.benches += 1
	return bench
end

-- Фонтан-заглушка: кам'яна чаша + вода + постамент + напівпрозорий струмінь
local function makeFountain(name, x, z)
	local fountain = makeModel(name, decor)
	local basinTop = PLAZA_TOP + 1.5
	fountain.PrimaryPart = makeVerticalCylinder("Basin", x, PLAZA_TOP, z, 1.5, 9, {
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(170, 170, 165),
	}, fountain)
	makeVerticalCylinder("Water", x, basinTop, z, 0.15, 8, {
		Material = Enum.Material.Glass,
		Color = WATER_COLOR,
		Transparency = 0.35,
		CanCollide = false,
	}, fountain)
	makeVerticalCylinder("Pedestal", x, basinTop, z, 2.5, 1.5, {
		Material = Enum.Material.Slate,
		Color = Color3.fromRGB(185, 185, 180),
	}, fountain)
	local jetBottom = basinTop + 2.5
	makeVerticalCylinder("Jet", x, jetBottom, z, 6, 0.8, {
		Material = Enum.Material.Glass,
		Color = WATER_COLOR,
		Transparency = 0.4,
		CanCollide = false,
	}, fountain)
	makePart("Part", {
		Name = "Spray",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(2.2, 2.2, 2.2),
		Position = Vector3.new(x, jetBottom + 6, z),
		Material = Enum.Material.Glass,
		Color = WATER_COLOR,
		Transparency = 0.5,
		CanCollide = false,
	}, fountain)
	markPlaced(x, z, 4.5)
	stats.town.fountains += 1
	return fountain
end

-- Ліхтар: тонкий стовп + куля-лампа з теплим світлом
local function makeLamp(name, x, z)
	local lamp = makeModel(name, decor)
	local poleHeight = 10
	lamp.PrimaryPart = makeVerticalCylinder("Pole", x, GROUND_TOP, z, poleHeight, 0.5, {
		Material = Enum.Material.Metal,
		Color = Color3.fromRGB(60, 60, 70),
	}, lamp)
	local bulb = makePart("Part", {
		Name = "Lamp",
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(1.6, 1.6, 1.6),
		Position = Vector3.new(x, GROUND_TOP + poleHeight + 0.6, z),
		Material = Enum.Material.Neon,
		Color = Color3.fromRGB(255, 230, 150),
	}, lamp)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 220, 160)
	light.Range = 16
	light.Brightness = 1.5
	light.Parent = bulb
	markPlaced(x, z, 0.5)
	stats.town.lamps += 1
	return lamp
end

-- Фонтани в північній половині площі (центр лишається вільним для спавну)
makeFountain("Fountain1", -10, -8)
makeFountain("Fountain2", 10, -8)

-- Лавочки: дві вздовж північного краю площі (обабіч виходу на Street4), дві навпроти фонтанів,
-- одна на узбіччі Street1
makeBench("Bench1", Vector3.new(-12.5, 0, -(PLAZA_HALF - 2.5)), PLAZA_TOP, 0)
makeBench("Bench2", Vector3.new(12.5, 0, -(PLAZA_HALF - 2.5)), PLAZA_TOP, 0)
makeBench("Bench3", Vector3.new(-10, 0, 0), PLAZA_TOP, 0)
makeBench("Bench4", Vector3.new(10, 0, 0), PLAZA_TOP, 0)
makeBench("Bench5", Vector3.new(48, 0, streetHalf + 2.5), GROUND_TOP, 0)

-- Окремий блок do...end: тимчасові змінні не займають місця серед локальних змінних верхнього рівня (ліміт Luau — 200)
do
	-- Ліхтарі на узбіччях головних вулиць, по черзі з обох боків
	local lampSpots = {
		Vector2.new(34, -(streetHalf + 1.5)), Vector2.new(64, streetHalf + 1.5), Vector2.new(94, -(streetHalf + 1.5)),
		Vector2.new(streetHalf + 1.5, 36),
		Vector2.new(-36, streetHalf + 1.5), Vector2.new(-56, -(streetHalf + 1.5)),
	}
	for i, spot in ipairs(lampSpots) do
		makeLamp("Lamp" .. i, spot.X, spot.Y)
	end

	-- Клумби в кутах площі та кущі з ягодами біля фонтанів
	local plazaGreen = makeFolder("PlazaGreenery", decor)
	local c = PLAZA_HALF - 3
	for i, corner in ipairs({ Vector2.new(-c, -c), Vector2.new(c, -c), Vector2.new(-c, c), Vector2.new(c, c) }) do
		makeFlowerBed("Flowerbed" .. i, Vector3.new(corner.X, 0, corner.Y), randomFlowerPalette(), plazaGreen, PLAZA_TOP)
		stats.town.flowerbeds += 1
	end
	for i, x in ipairs({ -c, c }) do
		local bush = makeBushOfType("berry", "Bush" .. i, Vector3.new(x, 0, -9), GREENS[1], plazaGreen)
		-- кущ стоїть на плитці площі, а не на газоні
		bush:PivotTo(bush:GetPivot() + Vector3.new(0, PLAZA_TOP - GROUND_TOP, 0))
		stats.town.bushes += 1
	end

	-- Клумби й кущі на узбіччях вулиць між будинками
	local streetGreen = makeFolder("StreetGreenery", decor)
	for i = 1, rng:NextInteger(6, 8) do
		if i % 2 == 0 then
			local pos = findSpotAlongStreet(1.3)
			if pos then
				makeFlowerBed("Flowerbed" .. i, pos, randomFlowerPalette(), streetGreen)
				stats.town.flowerbeds += 1
			end
		else
			local kind = BUSH_TYPES[rng:NextInteger(1, #BUSH_TYPES)]
			local pos = findSpotAlongStreet(BUSH_BODY_RADIUS[kind])
			if pos then
				makeBushOfType(kind, "Bush" .. i, pos, GREENS[rng:NextInteger(1, #GREENS)], streetGreen)
				stats.town.bushes += 1
			end
		end
	end
end

---------------------------------------------------------------------
-- 5. Дика галявина (WildArea): основа й галявина зустрічей
---------------------------------------------------------------------
local wild = makeModel("WildArea", world)

-- Основа дикої зони: темніший, насиченіший зелений
wild.PrimaryPart = makePart("Part", {
	Name = "WildGround",
	Size = Vector3.new(WILD_SIZE, GROUND_THICKNESS, WILD_SIZE),
	Position = WILD_CENTER + Vector3.new(0, GROUND_THICKNESS / 2, 0),
	Material = Enum.Material.Grass,
	Color = Color3.fromRGB(40, 150, 50),
}, wild)

-- Маркер центральної відкритої галявини (невидимий, для майбутніх зустрічей з Wivi)
makePart("Part", {
	Name = "EncounterClearing",
	Size = Vector3.new(CLEARING_SIZE, 0.2, CLEARING_SIZE),
	Position = WILD_CENTER + Vector3.new(0, GROUND_TOP + 0.1, 0),
	Transparency = 1,
	CanCollide = false,
	CanQuery = false,
	CanTouch = true,
}, wild)
local clearingHalf = CLEARING_SIZE / 2
blockRect(WILD_CENTER.X - clearingHalf, WILD_CENTER.X + clearingHalf, WILD_CENTER.Z - clearingHalf, WILD_CENTER.Z + clearingHalf)

---------------------------------------------------------------------
-- 6. Зони високої трави (EncounterZone1-4) і вузькі стежки між ними
--    Зарості прохідні: гравець може зайти в траву (майбутні зустрічі з Wivi) або обійти стежкою
---------------------------------------------------------------------
-- Блок do...end: допоміжні змінні розділу не займають місця серед локальних змінних верхнього рівня (ліміт Luau — 200)
do
	local ENCOUNTER_GRASS_COLORS = {
		Color3.fromRGB(25, 115, 35),
		Color3.fromRGB(35, 130, 40),
		Color3.fromRGB(20, 100, 45),
		Color3.fromRGB(45, 140, 35),
	}

	-- Чи точка (lx, lz) відносно центру зони лежить усередині її форми
	local function insideZoneShape(zone, lx, lz)
		local hx, hz = zone.size.X / 2, zone.size.Y / 2
		if zone.shape == "oval" then
			return (lx / hx) ^ 2 + (lz / hz) ^ 2 <= 1
		end
		return math.abs(lx) <= hx and math.abs(lz) <= hz
	end

	-- Зона зустрічей: невидимий тригер + табличка "Tall Grass" + щільні зарості травинок
	local function makeEncounterZone(index, zone, parent)
		local model = makeModel("EncounterZone" .. index, parent)
		local cx, cz = zone.center.X, zone.center.Y
		local hx, hz = zone.size.X / 2, zone.size.Y / 2

		-- Тригер для майбутньої логіки зустрічей (поки без скриптів)
		-- TODO: для овальних зон перевіряти потрапляння в еліпс, а не в прямокутний тригер
		local trigger = makePart("Part", {
			Name = "Trigger",
			Size = Vector3.new(zone.size.X, 4, zone.size.Y),
			Position = Vector3.new(cx, GROUND_TOP + 2, cz),
			Transparency = 1,
			CanCollide = false,
			CanQuery = false,
			CanTouch = true,
		}, model)
		model.PrimaryPart = trigger
		model:SetAttribute("EncounterZone", true)
		model:SetAttribute("Shape", zone.shape)

		-- Тимчасова табличка для розробки
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "DevLabel"
		billboard.Size = UDim2.fromOffset(90, 22)
		billboard.StudsOffset = Vector3.new(0, 5, 0)
		billboard.MaxDistance = 150
		billboard.Parent = trigger
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundColor3 = Color3.new(0, 0, 0)
		label.BackgroundTransparency = 0.5
		label.Text = "Tall Grass"
		label.TextSize = 14
		label.Font = Enum.Font.SourceSansBold
		label.TextColor3 = WHITE
		label.Parent = billboard

		-- Щільна сітка тонких високих травинок із випадковим зсувом і нахилом (без колізії)
		local blades = makeFolder("Blades", model)
		local step = ENCOUNTER_GRASS_STEP
		for lx = -hx + step / 2, hx, step do
			for lz = -hz + step / 2, hz, step do
				local jx = lx + rng:NextNumber(-0.35, 0.35)
				local jz = lz + rng:NextNumber(-0.35, 0.35)
				if insideZoneShape(zone, jx, jz) then
					local h = rng:NextNumber(3, 4.5)
					local cf = CFrame.new(cx + jx, GROUND_TOP, cz + jz)
						* CFrame.Angles(rng:NextNumber(-0.2, 0.2), rng:NextNumber(0, math.pi), rng:NextNumber(-0.2, 0.2))
						* CFrame.new(0, h / 2, 0)
					makePart("Part", {
						Name = "Blade",
						Size = Vector3.new(0.35, h, 0.35),
						CFrame = cf,
						Material = Enum.Material.Grass,
						Color = ENCOUNTER_GRASS_COLORS[rng:NextInteger(1, #ENCOUNTER_GRASS_COLORS)],
						CanCollide = false,
						CanQuery = false,
						CastShadow = false,
					}, blades)
				end
			end
		end

		blockRect(cx - hx, cx + hx, cz - hz, cz + hz, true)
		stats.wild.encounterZones += 1
		return model
	end

	-- Вузька стежка вздовж однієї осі (трохи нижча за вулицю, щоб перетини не мерехтіли)
	local function makeWildPath(name, x1, z1, x2, z2, parent)
		local size
		if x1 == x2 then
			size = Vector3.new(WILD_PATH_WIDTH, WILD_PATH_THICKNESS, math.abs(z2 - z1))
		else
			size = Vector3.new(math.abs(x2 - x1), WILD_PATH_THICKNESS, WILD_PATH_WIDTH)
		end
		local cx, cz = (x1 + x2) / 2, (z1 + z2) / 2
		blockRect(cx - size.X / 2, cx + size.X / 2, cz - size.Z / 2, cz + size.Z / 2, true)
		stats.wild.paths += 1
		return makePart("Part", {
			Name = name,
			Size = size,
			Position = Vector3.new(cx, GROUND_TOP + WILD_PATH_THICKNESS / 2, cz),
			Material = Enum.Material.Ground,
			Color = Color3.fromRGB(160, 115, 70),
		}, parent)
	end

	-- Чотири зони по кутах навколо центральної галявини: дві прямокутні, дві овальні
	local wc = WILD_CENTER
	local ENCOUNTER_ZONES = {
		{ center = Vector2.new(wc.X - 25, wc.Z - 25), size = Vector2.new(16, 12), shape = "rect" },
		{ center = Vector2.new(wc.X + 21, wc.Z - 23), size = Vector2.new(16, 16), shape = "oval" },
		{ center = Vector2.new(wc.X + 21, wc.Z + 24), size = Vector2.new(18, 14), shape = "rect" },
		{ center = Vector2.new(wc.X - 25, wc.Z + 24), size = Vector2.new(14, 14), shape = "oval" },
	}
	local encounterFolder = makeFolder("EncounterZones", wild)
	for i, zone in ipairs(ENCOUNTER_ZONES) do
		makeEncounterZone(i, zone, encounterFolder)
	end

	-- Стежки: кільце між галявиною та зонами + два проходи між парами зон на північ і південь.
	-- Горизонтальні відрізки кільця перекривають кути, вертикальні стикуються до них (без накладання).
	local wildPaths = makeFolder("Paths", wild)
	local pw = WILD_PATH_WIDTH / 2
	-- Кільце в межах ігрової зони (стіна перед східними горами — на wc.X + 31.5)
	local ringX1, ringX2, ringZ = wc.X - 28, wc.X + 28, 12
	makeWildPath("RingNorth", ringX1 - pw, wc.Z - ringZ, ringX2 + pw, wc.Z - ringZ, wildPaths)
	makeWildPath("RingSouth", ringX1 - pw, wc.Z + ringZ, ringX2 + pw, wc.Z + ringZ, wildPaths)
	makeWildPath("RingWest", ringX1, wc.Z - ringZ + pw, ringX1, wc.Z + ringZ - pw, wildPaths)
	makeWildPath("RingEast", ringX2, wc.Z - ringZ + pw, ringX2, wc.Z + ringZ - pw, wildPaths)
	makeWildPath("PassNorth", wc.X, wc.Z - ringZ - pw, wc.X, wc.Z - 30, wildPaths)
	makeWildPath("PassSouth", wc.X, wc.Z + ringZ + pw, wc.X, wc.Z + 30, wildPaths)
end

---------------------------------------------------------------------
-- 7. Декоративна межа світу: гори GrassMountain по периметру (містечко + дика зона разом)
--    Карта не кругла (містечко + виступ дикої зони), тож периметр задано полігонами:
--    • ігрова зона — зовнішній периметр, зсунутий всередину на BOUNDARY_INNER_STRIP;
--    • гори GrassMountain (CanCollide = true) — внутрішнім краєм рівно на лінії ігрової зони,
--      а більші клони ростуть НАЗОВНІ, ніколи не заходячи на газон.
--    Гори — лише декор. Гравця гарантовано тримає SafeZoneBoundary (розділ 7b), що від гір не залежить.
--    Полігони — замкнені, за годинниковою стрілкою (вісь Z донизу), усі кути прямі.
---------------------------------------------------------------------
local boundary = makeFolder("Boundary", world)
local boundaryVisual = makeFolder("Mountains", boundary)

local wildEastX = WILD_CENTER.X + WILD_HALF
local PERIMETER = {
	Vector2.new(-TOWN_HALF, -TOWN_HALF),
	Vector2.new(TOWN_HALF, -TOWN_HALF),
	Vector2.new(TOWN_HALF, -WILD_HALF),
	Vector2.new(wildEastX, -WILD_HALF),
	Vector2.new(wildEastX, WILD_HALF),
	Vector2.new(TOWN_HALF, WILD_HALF),
	Vector2.new(TOWN_HALF, TOWN_HALF),
	Vector2.new(-TOWN_HALF, TOWN_HALF),
}

-- Та сама територія як об'єднання прямокутників (містечко + дика зона); offset > 0 — розширення назовні
local function perimeterRects(offset)
	local o = offset
	return {
		{ minX = -TOWN_HALF - o, maxX = TOWN_HALF + o, minZ = -TOWN_HALF - o, maxZ = TOWN_HALF + o },
		-- Західний бік дикої зони прилягає до містечка (це не межа світу): при звуженні він має
		-- лишатися з'єднаним із звуженим містечком, тому зсувається назустріч йому на |o|
		{ minX = TOWN_HALF - math.abs(o), maxX = wildEastX + o, minZ = -WILD_HALF - o, maxZ = WILD_HALF + o },
	}
end
-- Ігрова зона: усередину на ширину смуги межі
local playRects = perimeterRects(-BOUNDARY_INNER_STRIP)

-- Ребра полігона: напрямок, довжина, зовнішня нормаль і опуклість кутів на кінцях ребра
local function polygonEdges(points)
	local edges = {}
	for i, a in ipairs(points) do
		local b = points[i % #points + 1]
		local dir = (b - a).Unit
		table.insert(edges, { a = a, b = b, dir = dir, length = (b - a).Magnitude, out = Vector2.new(dir.Y, -dir.X) })
	end
	for i, edge in ipairs(edges) do
		local nextEdge = edges[i % #edges + 1]
		local convex = edge.dir.X * nextEdge.dir.Y - edge.dir.Y * nextEdge.dir.X > 0
		edge.convexEnd = convex
		nextEdge.convexStart = convex
	end
	return edges
end

local boundaryEdges = polygonEdges(PERIMETER)

-- Полігон, зсунутий на offset (> 0 — назовні): усі кути прямі, тож вершина зсувається
-- вздовж суми нормалей двох сусідніх ребер
local function offsetPolygon(offset)
	local points = {}
	for i, edge in ipairs(boundaryEdges) do
		local prev = boundaryEdges[(i - 2) % #boundaryEdges + 1]
		points[i] = edge.a + (prev.out + edge.out) * offset
	end
	return polygonEdges(points)
end
local playEdges = offsetPolygon(-BOUNDARY_INNER_STRIP)

-- Подовження вздовж ребра на його кінцях: на опуклих кутах — convexExt, на увігнутих — concaveExt
local function edgeRange(edge, convexExt, concaveExt)
	local startExt = edge.convexStart and convexExt or concaveExt
	local endExt = edge.convexEnd and convexExt or concaveExt
	return -startExt, edge.length + endExt
end

-- Чи перетинаються два прямокутники XZ (з допуском eps: дотик по межі не рахується)
local function rectsOverlap(a, b, eps)
	return a.minX < b.maxX - eps and a.maxX > b.minX + eps and a.minZ < b.maxZ - eps and a.maxZ > b.minZ + eps
end

local function modelRect(model)
	local minV, maxV = worldBounds(model)
	return { minX = minV.X, maxX = maxV.X, minZ = minV.Z, maxZ = maxV.Z }, minV, maxV
end

-- Смуга між зовнішнім периметром і підніжжям гір (+ MOUNTAIN_FOOT_CLEARANCE) — без рослинності (там гори й SafeZoneBoundary).
-- На увігнутих кутах смуга подовжується, щоб закрити кутовий квадрат.
for _, edge in ipairs(boundaryEdges) do
	local stripWidth = BOUNDARY_INNER_STRIP + MOUNTAIN_FOOT_CLEARANCE
	local s1, s2 = edgeRange(edge, 0, stripWidth)
	local p1 = edge.a + edge.dir * s1
	local p2 = edge.a + edge.dir * s2 - edge.out * stripWidth
	blockRect(math.min(p1.X, p2.X), math.max(p1.X, p2.X), math.min(p1.Y, p2.Y), math.max(p1.Y, p2.Y))
end

-- Гори: ряд клонів GrassMountain уздовж кожного ребра ігрової зони, з перекриттям, без проміжків.
-- Масштаб 0.9-1.4 (або більше, якщо інакше гора нижча за MOUNTAIN_MIN_HEIGHT), поворот 0-360°.
local MOUNTAIN_MIN_HEIGHT = 20 -- нижчі гори не закривають огляд за межу
local MOUNTAIN_OVERLAP = 0.4 -- частка ширини, на яку сусідні клони заходять один на одного
local SPAWN_CLEARANCE = 10 -- мінімальний вільний простір між спавном і горами
local mountainScaleMin, mountainScaleMax = 0.9, 1.4
if mountainTemplate then
	local minV, maxV = worldBounds(mountainTemplate)
	local baseHeight = maxV.Y - minV.Y
	if baseHeight > 0 and baseHeight * mountainScaleMin < MOUNTAIN_MIN_HEIGHT then
		mountainScaleMin = MOUNTAIN_MIN_HEIGHT / baseHeight
		mountainScaleMax = math.max(mountainScaleMax, mountainScaleMin * 1.4)
	end
end

-- Якщо клон усе ж заходить в ігрову зону — зсуваємо його НАЗОВНІ (вздовж нормалі ребра) на глибину
-- перекриття. Повертає true, якщо довелося зсувати.
local function pushOutOfPlayArea(clone, out)
	local pushed = false
	for _ = 1, 4 do
		local rect = modelRect(clone)
		local shift = 0
		for _, play in ipairs(playRects) do
			if rectsOverlap(rect, play, 0.01) then
				local need
				if out.X > 0 then
					need = play.maxX - rect.minX
				elseif out.X < 0 then
					need = rect.maxX - play.minX
				elseif out.Y > 0 then
					need = play.maxZ - rect.minZ
				else
					need = rect.maxZ - play.minZ
				end
				shift = math.max(shift, need)
			end
		end
		if shift <= 0 then
			break
		end
		clone:PivotTo(clone:GetPivot() + Vector3.new(out.X, 0, out.Y) * (shift + 0.05))
		pushed = true
	end
	return pushed
end

local mountainClones = {}
local mountainRowIndex = {} -- клон → номер ребра периметра, уздовж якого стоїть його ряд

local function buildMountainRow(edge, edgeIndex, parent)
	-- На опуклих кутах ряд трохи виходить за кут (гори обох ребер перекриваються);
	-- на увігнутих — закриває кутовий квадрат смуги і закінчується рівно на краю ігрової зони
	-- сусіднього ребра (клони там притискаються всередину діапазону, див. нижче).
	local s1, s2 = edgeRange(edge, 4, BOUNDARY_INNER_STRIP)
	local covered -- до якої точки вздовж ребра вже закрито горами
	local guard = 0
	while (covered == nil or covered < s2) and guard < 500 do
		guard += 1
		local clone = cloneTemplate(mountainTemplate, 0, 0, {
			scale = rng:NextNumber(mountainScaleMin, mountainScaleMax),
			yaw = rng:NextNumber(0, math.pi * 2),
			collide = true,
			sink = GROUND_TOP, -- основа на рівні Baseplate: за краєм газону гора теж стоїть на землі
		})
		local _, minV, maxV = modelRect(clone)
		local ext = maxV - minV
		local halfAlong = math.max(1, (math.abs(edge.dir.X) * ext.X + math.abs(edge.dir.Y) * ext.Z) / 2)
		local depth = math.abs(edge.out.X) * ext.X + math.abs(edge.out.Y) * ext.Z

		-- Перший клон — на початку ребра; кожен наступний заходить на попередній на MOUNTAIN_OVERLAP своєї ширини.
		-- Біля увігнутих кутів клон не виходить за межі ребра вздовж (інакше заліз би на сусідню ігрову зону).
		local s = covered and (covered + halfAlong * (1 - 2 * MOUNTAIN_OVERLAP)) or s1
		if not edge.convexStart then
			s = math.max(s, s1 + halfAlong)
		end
		if not edge.convexEnd then
			s = math.min(s, s2 - halfAlong)
		end

		-- Внутрішній край — рівно на лінії ігрової зони; більший клон глибший, тож росте назовні
		local target = edge.a + edge.dir * s - edge.out * (BOUNDARY_INNER_STRIP - depth / 2)
		local center = (minV + maxV) / 2
		clone:PivotTo(clone:GetPivot() + Vector3.new(target.X - center.X, 0, target.Y - center.Z))
		if pushOutOfPlayArea(clone, edge.out) then
			stats.boundary.pushedOut += 1
		end
		clone.Name = string.format("GrassMountain_%d_%d", edgeIndex, guard) -- ребро_номер: легко знайти в Explorer
		clone.Parent = parent
		table.insert(mountainClones, clone)
		mountainRowIndex[clone] = edgeIndex

		covered = s + halfAlong
		if halfAlong * 2 >= s2 - s1 then
			break -- один клон уже перекриває все ребро
		end
	end
end

if mountainTemplate then
	for i, edge in ipairs(boundaryEdges) do
		buildMountainRow(edge, i, makeModel("Row" .. i, boundaryVisual))
	end
end

-- Підсумки по горах (лише декор, у блокуванні гравця вони більше не беруть участі):
-- висота, колізія, перевірка, що жоден клон не заходить в ігрову зону
local tallestMountain = 0
for _, clone in ipairs(mountainClones) do
	local rect, _, maxV = modelRect(clone)
	stats.boundary.mountains += 1
	stats.boundary.minHeight = math.min(stats.boundary.minHeight, maxV.Y - GROUND_TOP)
	tallestMountain = math.max(tallestMountain, maxV.Y)

	local allCollide = true
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") and not d.CanCollide then
			allCollide = false
		end
	end
	if allCollide then
		stats.boundary.collidable += 1
	end

	for _, play in ipairs(playRects) do
		if rectsOverlap(rect, play, 0.01) then
			stats.boundary.insidePlayArea += 1
			warn(string.format("[WorldGenerator] %s at (%.0f, %.0f) still overlaps the play area",
				clone.Name, clone:GetPivot().X, clone:GetPivot().Z))
			break
		end
	end
end

-- Найменша відстань у площині XZ від точки до прямокутників гір
local function distanceToMountains(point)
	local best = math.huge
	for _, clone in ipairs(mountainClones) do
		local rect = modelRect(clone)
		local dx = math.max(rect.minX - point.X, 0, point.X - rect.maxX)
		local dz = math.max(rect.minZ - point.Z, 0, point.Z - rect.maxZ)
		best = math.min(best, math.sqrt(dx * dx + dz * dz))
	end
	return best
end

---------------------------------------------------------------------
-- 7b. WorldFloor, SafeZoneBoundary (стіна в тілі гір біля підніжжя) і OuterSafetyRing (запасне кільце)
--    • Обидві зони разом займають прямокутник worldRect; з запасом WORLD_FLOOR_MARGIN — floorRect.
--    • SafeZoneBoundary — гладка стіна в тілі гір, на MOUNTAIN_WALL_DEPTH глибше за їхнє підніжжя:
--      гравець ступає на камінь і лише тоді впирається в стіну. Карта не кругла (містечко + виступ
--      дикої зони), тож стіна йде по тому ж прямокутному полігону, що й підніжжя гір, а не по колу.
--    • OuterSafetyRing — запасне кільце з SAFE_ZONE_SEGMENTS сегментів навколо центру floorRect.
--      Внутрішня грань — на відстані safeRadius = БІЛЬШЕ з двох:
--        zone-based:     найдальша точка floorRect + SAFE_ZONE_EXTRA;
--        mountain-based: найдальша точка будь-якого клону GrassMountain (фінальні позиції) + SAFE_ZONE_MOUNTAIN_MARGIN,
--      тож навіть гравець, що якось опинився б на горі, усе одно всередині кільця.
--    • WorldFloor — диск під усім кільцем (до зовнішньої грані стін), трохи нижче за газони зон:
--      закриває будь-які шви між зонами і не лишає порожнечі між краєм підлоги та стіною.
---------------------------------------------------------------------
local safeZone = makeFolder("SafeZone", world)

-- Габарити всіх зон разом (містечко + дика зона)
local worldRect = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
for _, r in ipairs(perimeterRects(0)) do
	worldRect.minX = math.min(worldRect.minX, r.minX)
	worldRect.maxX = math.max(worldRect.maxX, r.maxX)
	worldRect.minZ = math.min(worldRect.minZ, r.minZ)
	worldRect.maxZ = math.max(worldRect.maxZ, r.maxZ)
end
local floorRect = {
	minX = worldRect.minX - WORLD_FLOOR_MARGIN, maxX = worldRect.maxX + WORLD_FLOOR_MARGIN,
	minZ = worldRect.minZ - WORLD_FLOOR_MARGIN, maxZ = worldRect.maxZ + WORLD_FLOOR_MARGIN,
}
local safeCenter = Vector2.new((floorRect.minX + floorRect.maxX) / 2, (floorRect.minZ + floorRect.maxZ) / 2)
local floorCorner = Vector2.new(floorRect.maxX, floorRect.maxZ)
local zoneRadius = (floorCorner - safeCenter).Magnitude + SAFE_ZONE_EXTRA

-- Найдальша від центру точка клону в площині XZ: кути його осе-орієнтованих меж
-- (межі рахуються з усіх деталей після масштабу й повороту, тож це консервативна оцінка)
local function mountainFarthestDistance(clone)
	local rect = modelRect(clone)
	local farthest = 0
	for _, corner in ipairs({
		Vector2.new(rect.minX, rect.minZ), Vector2.new(rect.maxX, rect.minZ),
		Vector2.new(rect.minX, rect.maxZ), Vector2.new(rect.maxX, rect.maxZ),
	}) do
		farthest = math.max(farthest, (corner - safeCenter).Magnitude)
	end
	return farthest
end

local mountainFarthest = 0
for _, clone in ipairs(mountainClones) do
	mountainFarthest = math.max(mountainFarthest, mountainFarthestDistance(clone))
end
local mountainRadius = (#mountainClones > 0) and (mountainFarthest + SAFE_ZONE_MOUNTAIN_MARGIN) or 0
local safeRadius = math.max(zoneRadius, mountainRadius)
local safeRadiusSource = (mountainRadius > zoneRadius) and "mountain-based" or "zone-based"

-- WorldFloor: диск радіусом до зовнішньої грані стін; верх — на WORLD_FLOOR_DROP нижче за газони зон
local floorRadius = safeRadius + SAFE_ZONE_THICKNESS + 2
local floorTop = GROUND_TOP - WORLD_FLOOR_DROP
local worldFloor = makeVerticalCylinder("WorldFloor", safeCenter.X, floorTop - 1, safeCenter.Y, 1, floorRadius * 2, {
	Material = Enum.Material.Grass,
	Color = Color3.fromRGB(45, 110, 50),
}, world)

-- OuterSafetyRing: прямі сегменти, дотичні до кола safeRadius. Точна сторона многокутника по
-- зовнішній грані стіни — 2·(R + товщина)·tan(π/N); кожен сегмент довший на SAFE_ZONE_OVERLAP
-- з кожного боку, тож сусіди перекриваються внахлест і в кутах не лишається щілин.
local safeBoundary = makeModel("OuterSafetyRing", safeZone)
local safeHeight = SAFE_ZONE_TOP - SAFE_ZONE_BOTTOM
local segmentLength = 2 * (safeRadius + SAFE_ZONE_THICKNESS) * math.tan(math.pi / SAFE_ZONE_SEGMENTS)
	+ 2 * SAFE_ZONE_OVERLAP
for i = 1, SAFE_ZONE_SEGMENTS do
	local angle = (i - 1) / SAFE_ZONE_SEGMENTS * math.pi * 2
	local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local pos = Vector3.new(safeCenter.X, (SAFE_ZONE_BOTTOM + SAFE_ZONE_TOP) / 2, safeCenter.Y)
		+ dir * (safeRadius + SAFE_ZONE_THICKNESS / 2)
	-- lookAt спрямовує локальну -Z назовні: X — уздовж сегмента, Z — товщина
	makePart("Part", {
		Name = "Segment" .. i,
		Size = Vector3.new(segmentLength, safeHeight, SAFE_ZONE_THICKNESS),
		CFrame = CFrame.lookAt(pos, pos + dir),
		Material = Enum.Material.SmoothPlastic,
		Transparency = 1,
		CanCollide = true,
		CastShadow = false,
	}, safeBoundary)
end

-- Перевірка замкненості кільця: промені з центру назовні через кожні 0.5° на кількох висотах
-- (під землею, біля землі, посередині, під верхом) мають влучити в сегмент. Повертає кількість промахів.
local function countSafeZoneGaps()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { safeBoundary }
	local heights = { SAFE_ZONE_BOTTOM + 1, GROUND_TOP + 2, (SAFE_ZONE_BOTTOM + SAFE_ZONE_TOP) / 2, SAFE_ZONE_TOP - 1 }
	local gaps = 0
	for step = 0, 719 do
		local a = math.rad(step * 0.5 + 0.25)
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		for _, h in ipairs(heights) do
			local origin = Vector3.new(safeCenter.X, h, safeCenter.Y)
			if not Workspace:Raycast(origin, dir * (safeRadius + SAFE_ZONE_THICKNESS * 4), params) then
				gaps += 1
			end
		end
	end
	return gaps
end

-- SafeZoneBoundary — стіна в тілі гір. Підніжжя (внутрішній край гір) — на лінії ігрової зони (playEdges).
-- Внутрішня (до гравця) грань стіни — на offset studs глибше за підніжжя, стіна росте назовні на товщину:
-- гравець піднімається на камінь на offset studs і лише тоді впирається в стіну.
-- Offset підбирається для КОЖНОГО клону окремо: бажаний MOUNTAIN_WALL_DEPTH, але якщо гора в цьому місці
-- тонша за offset + товщину стіни, її сегмент стає мілкішим (MOUNTAIN_WALL_FALLBACK її товщини) — щоб стіна
-- не вилізла крізь дальній край гори. Кожен клон отримує свій сегмент уздовж ребра; стики сусідніх сегментів —
-- посередині зони перекриття двох клонів, а там, де offset змінюється, стоїть поперечна стінка-сходинка.

-- Положення клону в системі ребра підніжжя: near..far — назовні від підніжжя, sMin..sMax — уздовж ребра
local mountainWallInfo = {} -- клон → { near, far, sMin, sMax, depth, reduced }
local reducedWallSegments = 0
for _, clone in ipairs(mountainClones) do
	local edge = playEdges[mountainRowIndex[clone]]
	local rect = modelRect(clone)
	local info = { near = math.huge, far = -math.huge, sMin = math.huge, sMax = -math.huge }
	for _, corner in ipairs({
		Vector2.new(rect.minX, rect.minZ), Vector2.new(rect.maxX, rect.minZ),
		Vector2.new(rect.minX, rect.maxZ), Vector2.new(rect.maxX, rect.maxZ),
	}) do
		local d, s = (corner - edge.a):Dot(edge.out), (corner - edge.a):Dot(edge.dir)
		info.near, info.far = math.min(info.near, d), math.max(info.far, d)
		info.sMin, info.sMax = math.min(info.sMin, s), math.max(info.sMax, s)
	end
	info.depth = MOUNTAIN_WALL_DEPTH
	if info.depth + MOUNTAIN_WALL_THICKNESS >= info.far then
		-- Гора тонша, ніж треба: частка товщини, але так, щоб і зовнішня грань стіни лишилась у камені
		info.depth = math.min(info.far * MOUNTAIN_WALL_FALLBACK, info.far - MOUNTAIN_WALL_THICKNESS - 0.5)
		info.reduced = true
		reducedWallSegments += 1
		local p = clone:GetPivot().Position
		warn(string.format(
			"[WorldGenerator] %s at (%.1f, %.1f, %.1f) is only %.1f studs thick from its foot — SafeZoneBoundary offset reduced from +%.1f to +%.1f for this segment (path: %s)",
			clone.Name, p.X, p.Y, p.Z, info.far, MOUNTAIN_WALL_DEPTH, info.depth, clone:GetFullName()))
	end
	mountainWallInfo[clone] = info
end

local frontWall = makeModel("SafeZoneBoundary", safeZone)
local frontWallParts = 0
do
	-- Прямокутник стіни в системі ребра: s1..s2 уздовж ребра, d1..d2 назовні від підніжжя (ребра осе-орієнтовані)
	local function wallBox(name, edge, s1, s2, d1, d2)
		if s2 - s1 <= 0.01 then
			return
		end
		local c = edge.a + edge.dir * ((s1 + s2) / 2) + edge.out * ((d1 + d2) / 2)
		makePart("Part", {
			Name = name,
			Size = (edge.out.X ~= 0)
				and Vector3.new(d2 - d1, safeHeight, s2 - s1)
				or Vector3.new(s2 - s1, safeHeight, d2 - d1),
			Position = Vector3.new(c.X, (SAFE_ZONE_BOTTOM + SAFE_ZONE_TOP) / 2, c.Y),
			Material = Enum.Material.SmoothPlastic,
			Transparency = 1,
			CanCollide = true,
			CastShadow = false,
		}, frontWall)
		frontWallParts += 1
	end

	-- Сегменти кожного ребра: по одному на клон (упорядковано вздовж ребра); ряд без гір — один сегмент
	local pieces = {}
	for i, edge in ipairs(playEdges) do
		local row = {}
		for _, clone in ipairs(mountainClones) do
			if mountainRowIndex[clone] == i then
				table.insert(row, mountainWallInfo[clone])
			end
		end
		table.sort(row, function(a, b)
			return a.sMin < b.sMin
		end)
		local list = {}
		for k, info in ipairs(row) do
			list[k] = {
				s1 = (k > 1) and (row[k - 1].sMax + info.sMin) / 2 or 0,
				s2 = (k < #row) and (info.sMax + row[k + 1].sMin) / 2 or edge.length,
				depth = info.depth,
			}
		end
		if #list == 0 then
			list[1] = { s1 = 0, s2 = edge.length, depth = MOUNTAIN_WALL_DEPTH }
		end
		pieces[i] = list
	end

	-- Кути: на опуклому сегмент доходить до зовнішньої грані стіни сусіднього ребра, на увігнутому —
	-- до її внутрішньої грані (сусідня стіна сама закриває кутовий квадрат)
	for i, edge in ipairs(playEdges) do
		local list = pieces[i]
		local prevList = pieces[(i - 2) % #playEdges + 1]
		local prevDepth, nextDepth = prevList[#prevList].depth, pieces[i % #playEdges + 1][1].depth
		list[1].s1 = edge.convexStart and -(prevDepth + MOUNTAIN_WALL_THICKNESS) or prevDepth
		list[#list].s2 = edge.convexEnd and (edge.length + nextDepth + MOUNTAIN_WALL_THICKNESS) or (edge.length - nextDepth)
		for k, piece in ipairs(list) do
			-- Внутрішні стики — внахлест на 0.5 stud з кожного боку
			local s1 = piece.s1 - ((k > 1) and 0.5 or 0)
			local s2 = piece.s2 + ((k < #list) and 0.5 or 0)
			wallBox(string.format("Wall%d_%d", i, k), edge, s1, s2, piece.depth, piece.depth + MOUNTAIN_WALL_THICKNESS)
			local nextPiece = list[k + 1]
			if nextPiece and math.abs(nextPiece.depth - piece.depth) > 0.01 then
				-- Сходинка між сегментами різної глибини: інакше між ними лишився б прохід уздовж ребра
				wallBox(string.format("Step%d_%d", i, k), edge,
					piece.s2 - MOUNTAIN_WALL_THICKNESS / 2, piece.s2 + MOUNTAIN_WALL_THICKNESS / 2,
					math.min(piece.depth, nextPiece.depth), math.max(piece.depth, nextPiece.depth) + MOUNTAIN_WALL_THICKNESS)
			end
		end
	end
end

-- Замкненість стіни: промені з ігрової зони (2 studs перед підніжжям) назовні через кожні 2 studs уздовж
-- кожного ребра на тих самих висотах мають влучити в стіну. Промені довгі: біля увігнутих кутів промінь
-- іде вздовж кам'яної кишені й упирається в стіну іншого ребра. Повертає кількість промахів.
local function countFrontWallGaps()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { frontWall }
	local heights = { SAFE_ZONE_BOTTOM + 1, GROUND_TOP + 2, (SAFE_ZONE_BOTTOM + SAFE_ZONE_TOP) / 2, SAFE_ZONE_TOP - 1 }
	local gaps = 0
	for _, edge in ipairs(playEdges) do
		local outDir = Vector3.new(edge.out.X, 0, edge.out.Y)
		local s = 1
		while s < edge.length do
			local p = edge.a + edge.dir * s - edge.out * 2
			for _, h in ipairs(heights) do
				if not Workspace:Raycast(Vector3.new(p.X, h, p.Y), outDir * 600, params) then
					gaps += 1
				end
			end
			s += 2
		end
	end
	return gaps
end

-- Перевірка гір: сегмент стіни кожного клону має проходити КРІЗЬ його тіло (уздовж нормалі ряду):
-- найближча точка гори < внутрішня грань стіни, а зовнішня грань стіни < найдальша точка гори.
-- Інакше — попередження: стіна перед горою (на траві), позаду неї або вилазить крізь дальній край.
-- Повертає кількість проблемних клонів і мін./макс. глибину каменю перед стіною.
local function checkWallThroughMountains()
	local bad, minStep, maxStep = 0, math.huge, -math.huge
	for _, clone in ipairs(mountainClones) do
		local info = mountainWallInfo[clone]
		local wallInner, wallOuter = info.depth, info.depth + MOUNTAIN_WALL_THICKNESS
		local step = wallInner - info.near
		minStep = math.min(minStep, step)
		maxStep = math.max(maxStep, step)

		local problem
		if wallOuter <= info.near then
			problem = "is entirely IN FRONT of"
		elseif wallInner >= info.far then
			problem = "is entirely BEHIND"
		elseif wallInner <= info.near then
			problem = "starts in front of the foot of"
		elseif wallOuter >= info.far then
			problem = "sticks out behind"
		end
		if problem then
			bad += 1
			local p = clone:GetPivot().Position
			warn(string.format(
				"[WorldGenerator] SafeZoneBoundary %s %s at (%.1f, %.1f, %.1f): mountain %.1f..%.1f, wall %.1f..%.1f from the foot (path: %s)",
				problem, clone.Name, p.X, p.Y, p.Z, info.near, info.far, wallInner, wallOuter, clone:GetFullName()))
		end
	end
	return bad, minStep, maxStep
end

-- Довідково: "near point" — найближча до центру світу точка гір
local mountainNearest = math.huge
for _, clone in ipairs(mountainClones) do
	local rect = modelRect(clone)
	local dx = math.max(rect.minX - safeCenter.X, 0, safeCenter.X - rect.maxX)
	local dz = math.max(rect.minZ - safeCenter.Y, 0, safeCenter.Y - rect.maxZ)
	mountainNearest = math.min(mountainNearest, math.sqrt(dx * dx + dz * dz))
end

-- Фінальна перевірка: найдальша точка КОЖНОГО клону гори має бути строго всередині кільця.
-- Якщо ні — це баг розрахунку; клон названо в консолі, щоб знайти його в Explorer.
local function countMountainsOutsideSafeZone()
	local outside = 0
	for _, clone in ipairs(mountainClones) do
		local farthest = mountainFarthestDistance(clone)
		if farthest >= safeRadius then
			outside += 1
			local p = clone:GetPivot().Position
			warn(string.format(
				"[WorldGenerator] ERROR: %s at (%.1f, %.1f, %.1f) reaches %.1f studs from the center — outside SafeZoneBoundary radius %.1f (path: %s)",
				clone.Name, p.X, p.Y, p.Z, farthest, safeRadius, clone:GetFullName()))
		end
	end
	return outside
end

-- Наскільки WorldFloor перекриває зони: мінімальний запас від найдальшої точки зон до краю диска
local function floorCoverageMargin()
	local worst = math.huge
	for _, r in ipairs(perimeterRects(0)) do
		for _, corner in ipairs({
			Vector2.new(r.minX, r.minZ), Vector2.new(r.maxX, r.minZ),
			Vector2.new(r.minX, r.maxZ), Vector2.new(r.maxX, r.maxZ),
		}) do
			worst = math.min(worst, floorRadius - (corner - safeCenter).Magnitude)
		end
	end
	return worst
end

---------------------------------------------------------------------
-- 8. Рослинність обох зон (після реєстрації всіх зайнятих ділянок)
---------------------------------------------------------------------
local townVegetation = makeFolder("Vegetation", town)
scatterVegetation(TOWN_CENTER, TOWN_HALF, townVegetation, {
	trees = rng:NextInteger(10, 14),
	bushes = rng:NextInteger(14, 18),
	flowerbeds = rng:NextInteger(8, 12),
	bushShade = 0,
}, stats.town)

-- Дика зона: дерева, кущі (трохи темніші, ніж у містечку) і клумби
scatterVegetation(WILD_CENTER, WILD_HALF, wild, {
	trees = rng:NextInteger(14, 18),
	bushes = rng:NextInteger(9, 12),
	flowerbeds = rng:NextInteger(4, 6),
	bushShade = 0.15,
}, stats.wild)

-- Ділянки високої трави, щоб дика зона не виглядала рівним газоном
local grassFolder = makeFolder("TallGrass", wild)
for i = 1, rng:NextInteger(6, 8) do
	local pos = findSpot(WILD_CENTER, WILD_HALF, 2.5, 2.5, false)
	if pos then
		makeTallGrass("TallGrass" .. i, pos, grassFolder)
		stats.wild.grass += 1
	end
end

-- Камені-заглушки
local rocksFolder = makeFolder("Rocks", wild)
for i = 1, rng:NextInteger(3, 5) do
	local radius = rng:NextNumber(1, 1.8)
	local pos = findSpot(WILD_CENTER, WILD_HALF, radius, radius, false)
	if pos then
		local rock = makeBush("Rock" .. i, pos, radius, Color3.fromRGB(140, 140, 145), rocksFolder)
		rock.Material = Enum.Material.Slate
		stats.wild.rocks += 1
	end
end

-- Декоративні клапті трави (шаблон grass / GrassPatchTemplate) на газоні обох зон: 40-60 штук,
-- масштаб 0.7-1.2, поворот 0-360°, без колізії. Ставляться останніми, тож оминають усе вже розміщене
-- (вулиці, стежки, подвір'я з будинками, дерева, кущі, декор) з відступом щонайменше 2 studs.
if grassTemplate then
	local minV, maxV = worldBounds(grassTemplate)
	local baseRadius = math.max(maxV.X - minV.X, maxV.Z - minV.Z) / 2
	local GRASS_GAP = 2
	local function scatterGrass(center, half, count, parent, zoneStats)
		for i = 1, count do
			local scale = rng:NextNumber(0.7, 1.2)
			local radius = baseRadius * scale
			local pos = findSpot(center, half, radius, radius, false, GRASS_GAP)
			if pos then
				local patch = cloneTemplate(grassTemplate, pos.X, pos.Z, {
					scale = scale,
					yaw = rng:NextNumber(0, math.pi * 2),
					collide = false,
				})
				patch.Name = "GrassPatch" .. i
				patch.Parent = parent
				zoneStats.grassPatches += 1
			end
		end
	end
	scatterGrass(TOWN_CENTER, TOWN_HALF, rng:NextInteger(28, 40), makeFolder("GrassPatches", townVegetation), stats.town)
	scatterGrass(WILD_CENTER, WILD_HALF, rng:NextInteger(12, 20), makeFolder("GrassPatches", wild), stats.wild)
end

---------------------------------------------------------------------
-- 9. SpawnLocation на площі (невидимий, без ForceField)
---------------------------------------------------------------------
makePart("SpawnLocation", {
	Name = "TownSpawn",
	Size = Vector3.new(6, 1, 6),
	Position = TOWN_CENTER + Vector3.new(0, PLAZA_TOP + 1, 0),
	Transparency = 1,
	CanCollide = false,
	Duration = 0,
	Neutral = true,
}, world)

---------------------------------------------------------------------
-- 10. Освітлення: тепле сонячне пообіддя
---------------------------------------------------------------------
Lighting.ClockTime = 14
Lighting.Brightness = 3
Lighting.Ambient = Color3.fromRGB(150, 130, 110)
Lighting.OutdoorAmbient = Color3.fromRGB(170, 150, 120)
Lighting.GlobalShadows = true

---------------------------------------------------------------------
-- 11. Перевірки масштабу та підсумок у консоль
---------------------------------------------------------------------
-- Блок do...end: змінні звіту не займають місця серед локальних змінних верхнього рівня (ліміт Luau — 200)
do
	local houseCount = #yards:GetChildren()
	local streetCount = #streets:GetChildren()
	local twoStoryCount = 0
	for _, v in ipairs(VARIANTS) do
		if v.twoStory then
			twoStoryCount += 1
		end
	end

	-- Вільний проріз: висота зменшується на товщину підлоги всередині
	local doorClearHeight = DOOR_HEIGHT - FLOOR_THICKNESS
	local doorClearWidth = DOOR_WIDTH

	print(string.format("[WorldGenerator] TownArea: %dx%d studs, plaza %dx%d, WildArea %dx%d, yards %dx%d",
		TOWN_SIZE, TOWN_SIZE, PLAZA_SIZE, PLAZA_SIZE, WILD_SIZE, WILD_SIZE, YARD_SIZE, YARD_SIZE))
	print(string.format(
		"[WorldGenerator] Houses: %d (%d two-story), ground floor %dx%dx%d, upper floor %dx%dx%d; streets: %d (Street3 forks at a T-junction)",
		houseCount, twoStoryCount, HOUSE_SIZE.X, HOUSE_SIZE.Z, HOUSE_SIZE.Y,
		UPPER_SIZE.X, UPPER_SIZE.Z, UPPER_SIZE.Y, streetCount))
	print(string.format("[WorldGenerator] Door opening: %.1f wide x %.1f high studs (%.0f%% of %d-stud wall)",
		doorClearWidth, doorClearHeight, DOOR_HEIGHT / HOUSE_SIZE.Y * 100, HOUSE_SIZE.Y))
	print(string.format("[WorldGenerator] Town decor: %d lamps, %d benches, %d fountains",
		stats.town.lamps, stats.town.benches, stats.town.fountains))
	print(string.format("[WorldGenerator] Town vegetation: %d trees, %d bushes, %d flowerbeds, %d grass patches",
		stats.town.trees, stats.town.bushes, stats.town.flowerbeds, stats.town.grassPatches))
	print(string.format("[WorldGenerator] Wild vegetation: %d trees, %d bushes, %d flowerbeds, %d grass patches, %d tall-grass clumps, %d rocks",
		stats.wild.trees, stats.wild.bushes, stats.wild.flowerbeds, stats.wild.grassPatches, stats.wild.grass, stats.wild.rocks))

	-- Скільки дерев створено з кожного шаблону
	local templateCounts = {}
	for _, template in ipairs(treeTemplates) do
		table.insert(templateCounts, string.format("%s = %d", template.Name, stats.treesByTemplate[template.Name] or 0))
	end
	print(string.format("[WorldGenerator] Trees from templates: %d total (%s)",
		stats.town.trees + stats.wild.trees, (#templateCounts > 0) and table.concat(templateCounts, ", ") or "no templates found"))
	print(string.format("[WorldGenerator] Encounter zones: %d (tall grass), wild paths: %d",
		stats.wild.encounterZones, stats.wild.paths))

	-- WorldFloor: розмір і чи повністю покриває обидві зони
	local coverage = floorCoverageMargin()
	print(string.format(
		"[WorldGenerator] WorldFloor: disc radius %.1f (diameter %.1f) at center (%.1f, %.1f), top Y = %.1f; zones X %.0f..%.0f, Z %.0f..%.0f; min margin beyond zones = %.1f studs",
		floorRadius, floorRadius * 2, safeCenter.X, safeCenter.Y, floorTop,
		worldRect.minX, worldRect.maxX, worldRect.minZ, worldRect.maxZ, coverage))
	if coverage < WORLD_FLOOR_MARGIN then
		warn(string.format("[WorldGenerator] WorldFloor is too small: only %.1f studs beyond the zones (need %d) — some area may be uncovered",
			coverage, WORLD_FLOOR_MARGIN))
	end

	-- Радіуси кола: far point (mountain-based), near point (найближча до центру точка гір), zone-based
	print(string.format(
		"[WorldGenerator] Circle radii: mountain far point = %.1f (+%d -> %.1f), mountain near point = %.1f, zone-based = %.1f",
		mountainFarthest, SAFE_ZONE_MOUNTAIN_MARGIN, mountainRadius, (#mountainClones > 0) and mountainNearest or 0,
		zoneRadius))

	-- SafeZoneBoundary (у тілі гір): замкненість і чи проходить стіна крізь кожну гору
	local frontGaps = countFrontWallGaps()
	local frontClosed = frontGaps == 0
	local mountainsMisplaced, minStep, maxStep = checkWallThroughMountains()
	print(string.format(
		"[WorldGenerator] SafeZoneBoundary (inside mountains): %d parts (per-mountain segments + steps), offset +%.1f studs INTO the mountain from its foot, thickness %d, Y %d..%d; closed = %s",
		frontWallParts, MOUNTAIN_WALL_DEPTH, MOUNTAIN_WALL_THICKNESS, SAFE_ZONE_BOTTOM, SAFE_ZONE_TOP, tostring(frontClosed)))
	if #mountainClones > 0 then
		print(string.format(
			"[WorldGenerator] SafeZoneBoundary offset check: +%.1f fits inside %d of %d mountains; reduced for %d segment(s) (mountain too thin, %.0f%% of its thickness)",
			MOUNTAIN_WALL_DEPTH, #mountainClones - reducedWallSegments, #mountainClones, reducedWallSegments,
			MOUNTAIN_WALL_FALLBACK * 100))
		print(string.format(
			"[WorldGenerator] SafeZoneBoundary passes THROUGH the mountain body for %d of %d clones (in front / behind / sticking out: %d, expected 0); rock before the wall: %.1f..%.1f studs",
			#mountainClones - mountainsMisplaced, #mountainClones, mountainsMisplaced, minStep, maxStep))
	end
	if not frontClosed then
		warn(string.format("[WorldGenerator] SafeZoneBoundary has %d gap samples", frontGaps))
	end

	-- OuterSafetyRing (запасне коло за горами)
	local safeGaps = countSafeZoneGaps()
	local ringClosed = safeGaps == 0
	print(string.format(
		"[WorldGenerator] OuterSafetyRing: chosen radius %.1f (%s), %d segments (%.1f long, +%.1f overlap per side), center (%.1f, %.1f), thickness %d, Y %d..%d; closed = %s",
		safeRadius, safeRadiusSource, SAFE_ZONE_SEGMENTS, segmentLength, SAFE_ZONE_OVERLAP, safeCenter.X, safeCenter.Y,
		SAFE_ZONE_THICKNESS, SAFE_ZONE_BOTTOM, SAFE_ZONE_TOP, tostring(ringClosed)))
	if not ringClosed then
		warn(string.format("[WorldGenerator] OuterSafetyRing has %d gap samples", safeGaps))
	end
	local mountainsOutside = countMountainsOutsideSafeZone()
	print(string.format("[WorldGenerator] Mountains outside OuterSafetyRing: %d of %d (expected 0)",
		mountainsOutside, #mountainClones))
	if tallestMountain > SAFE_ZONE_TOP - 15 then
		warn(string.format("[WorldGenerator] Tallest GrassMountain reaches Y = %.1f — close to the wall top (%d)",
			tallestMountain, SAFE_ZONE_TOP))
	end

	local boundaryClosed = frontClosed and ringClosed
	print(string.format(
		"[WorldGenerator] SafeZoneBoundary active: +%.1f studs inside the mountain foot, height=%d to %d (backup ring radius=%.1f) — player can step onto the rock but CANNOT climb the mountains or exit this zone. boundaryClosed = %s",
		MOUNTAIN_WALL_DEPTH, SAFE_ZONE_BOTTOM, SAFE_ZONE_TOP, safeRadius, tostring(boundaryClosed)))

	print(string.format(
		"[WorldGenerator] GrassMountain (decor only): %d clones, %d with CanCollide = true, scale %.2f-%.2f, lowest %.1f / tallest %.1f studs; pushed outward: %d, still overlapping play area: %d",
		stats.boundary.mountains, stats.boundary.collidable, mountainScaleMin, mountainScaleMax,
		(stats.boundary.mountains > 0) and stats.boundary.minHeight or 0, math.max(0, tallestMountain - GROUND_TOP),
		stats.boundary.pushedOut, stats.boundary.insidePlayArea))
	if stats.boundary.mountains > 0 and stats.boundary.minHeight < MOUNTAIN_MIN_HEIGHT then
		warn(string.format("[WorldGenerator] Some GrassMountain clones are lower than %d studs and may not hide the view",
			MOUNTAIN_MIN_HEIGHT))
	end

	-- Спавн має бути на відстані щонайменше SPAWN_CLEARANCE від гір (щоб персонаж не застряг у геометрії)
	local spawnClearance = distanceToMountains(TOWN_CENTER)
	print(string.format("[WorldGenerator] Spawn clearance to nearest GrassMountain: %.1f studs (min %d)",
		(spawnClearance == math.huge) and 0 or spawnClearance, SPAWN_CLEARANCE))
	if spawnClearance < SPAWN_CLEARANCE then
		warn("[WorldGenerator] SpawnLocation is too close to the GrassMountain boundary")
	end

	if doorClearHeight < CHARACTER_MIN_HEIGHT or doorClearWidth < CHARACTER_MIN_WIDTH then
		warn(string.format(
			"[WorldGenerator] Door opening %.1fx%.1f is too small for a character (need at least %dx%d)",
			doorClearWidth, doorClearHeight, CHARACTER_MIN_WIDTH, CHARACTER_MIN_HEIGHT))
	end

	print(string.format(
		"[WorldGenerator] Wivials test zone generated: town (%d houses %dx%dx%d, %d streets) + wild area; %d template trees, %d GrassMountains, %d grass patches; %d collidable mountains, %d pushed outward; SafeZoneBoundary +%.1f studs inside mountains (%d mountains not crossed), backup ring radius %.1f (%d mountains outside); boundaryClosed = %s",
		houseCount, HOUSE_SIZE.X, HOUSE_SIZE.Z, HOUSE_SIZE.Y, streetCount,
		stats.town.trees + stats.wild.trees, stats.boundary.mountains, stats.town.grassPatches + stats.wild.grassPatches,
		stats.boundary.collidable, stats.boundary.pushedOut, MOUNTAIN_WALL_DEPTH, mountainsMisplaced, safeRadius, mountainsOutside, tostring(boundaryClosed)))
end
