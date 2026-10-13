--[[
	WorldGeneratorModule
	Генерує базову тестову зону світу Wivials: містечко (TownArea) з площею,
	вуличною мережею, ліхтарями, фонтанами та подвір'ями з будинками в реальному масштабі,
	і сусідню дику галявину (WildArea). Обидві зони наповнені рослинністю й оточені горами GrassMountain (з колізією),
	а весь світ стоїть на одному рівні з WorldFloor (рамка кольору зон навколо газонів) усередині невидимого кільця SafeZoneBoundary. Дерева й трава — клони з AssetTemplates.

	Generate(markAsBaked) — видаляє старий Workspace.WivialsWorld і будує світ заново; працює і під час гри,
	і в режимі редагування (Studio Command Bar). markAsBaked = true ставить WivialsWorld атрибут Baked = true,
	і тоді серверний скрипт WorldGenerator не перебудовує світ під час гри.
	ActivateDoors(root) — підключає поведінку дверей у вже побудованому світі (з'єднання подій не зберігаються
	разом із місцем, тож "запеченим" дверям їх треба підключити під час гри).
]]

local Workspace = game:GetService("Workspace")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local WorldGeneratorModule = {}

---------------------------------------------------------------------
-- Поведінка дверей на завісах (спільна для щойно побудованого і "запеченого" світу)
---------------------------------------------------------------------
local DOOR_TAG = "HingedDoor"
local DOOR_OPEN_ANGLE = math.rad(95) -- двері відчиняються всередину будинку
local DOOR_TWEEN_TIME = 0.5
local activeDoors = setmetatable({}, { __mode = "k" }) -- модель дверей → setOpen (щоб не підключати двічі)

-- Двері — модель із деталями Hinge (нерухома вісь), Panel (з ProximityPrompt), Knob і NumberValue Angle.
-- Зсуви панелі й ручки від завіс беруться з поточного положення деталей, тож це працює і для збережених дверей.
-- Повертає setOpen(open, instant) або nil, якщо модель неповна.
local function attachDoorBehavior(model)
	if activeDoors[model] then
		return activeDoors[model]
	end
	local hinge = model:FindFirstChild("Hinge")
	local door = model:FindFirstChild("Panel")
	local knob = model:FindFirstChild("Knob")
	local angle = model:FindFirstChild("Angle")
	local prompt = door and door:FindFirstChildWhichIsA("ProximityPrompt")
	if not (hinge and door and knob and angle and prompt) then
		warn(string.format("[WorldGenerator] Door %s is missing Hinge/Panel/Knob/Angle/ProximityPrompt — it will not open", model:GetFullName()))
		return nil
	end
	local hingeCf = hinge.CFrame
	local current = hingeCf * CFrame.Angles(0, -angle.Value, 0)
	local panelOffset = current:ToObjectSpace(door.CFrame)
	local knobOffset = current:ToObjectSpace(knob.CFrame)
	local function apply(a)
		local rotated = hingeCf * CFrame.Angles(0, -a, 0)
		door.CFrame = rotated * panelOffset
		knob.CFrame = rotated * knobOffset
	end
	angle.Changed:Connect(apply)

	local isOpen, moving = model:GetAttribute("Open") == true, false
	local function setOpen(open, instant)
		isOpen = open
		model:SetAttribute("Open", open)
		prompt.ActionText = open and "Close Door" or "Open Door"
		local target = open and DOOR_OPEN_ANGLE or 0
		door.CanCollide = false -- і під час руху, і поки відчинені
		if instant then
			angle.Value = target
			apply(target)
			door.CanCollide = not open
			return
		end
		moving = true
		local tween = TweenService:Create(angle, TweenInfo.new(DOOR_TWEEN_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = target })
		tween.Completed:Connect(function()
			moving = false
			door.CanCollide = not isOpen
		end)
		tween:Play()
	end
	prompt.Triggered:Connect(function()
		if not moving then
			setOpen(not isOpen, false)
		end
	end)
	activeDoors[model] = setOpen
	return setOpen
end

-- Підключає поведінку всім дверям (тег HingedDoor) усередині root. Повертає { active, broken }.
function WorldGeneratorModule.ActivateDoors(root)
	local active, broken = 0, 0
	for _, model in ipairs(CollectionService:GetTagged(DOOR_TAG)) do
		if model:IsDescendantOf(root) then
			if attachDoorBehavior(model) then
				active += 1
			else
				broken += 1
			end
		end
	end
	return active, broken
end

---------------------------------------------------------------------
-- Генерація світу
---------------------------------------------------------------------
-- Уся генерація — в одній функції: кожен виклик починає з чистого стану (той самий seed, порожні списки
-- зайнятих місць) і будує світ заново. Повертає WivialsWorld.
function WorldGeneratorModule.Generate(markAsBaked)
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
	local TOWN_GRASS_COLOR = Color3.fromRGB(110, 210, 80) -- газон містечка (і WorldFloor під ним)
	local WILD_GRASS_COLOR = Color3.fromRGB(40, 150, 50) -- газон дикої зони (і WorldFloor під нею)

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
	local ENCOUNTER_ZONE_CLEARANCE = 3 -- мінімальний відступ заростей від дерев, вулиць, будинків і гір
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
		wild = { trees = 0, bushes = 0, flowerbeds = 0, grass = 0, rocks = 0, encounterZones = 0, grassPatches = 0 },
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

	-- Чи вільна точка: не ближче PATH_MARGIN до зайнятих ділянок і не ближче `gap` (типово 1) до інших об'єктів;
	-- дерева — не ближче treeMinDist (типово TREE_MIN_DIST) одне до одного
	local function canPlace(x, z, clearRadius, bodyRadius, isTree, gap, treeMinDist)
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
			if isTree and o.isTree and d < (treeMinDist or TREE_MIN_DIST) then
				return false
			end
		end
		return true
	end

	-- Випадкова вільна точка в зоні (center, half) або nil
	local function findSpot(center, half, clearRadius, bodyRadius, isTree, gap, treeMinDist)
		local inset = half - clearRadius - 1
		for _ = 1, 300 do
			local x = center.X + rng:NextNumber(-inset, inset)
			local z = center.Z + rng:NextNumber(-inset, inset)
			if canPlace(x, z, clearRadius, bodyRadius, isTree, gap, treeMinDist) then
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

	-- Розкидає по зоні дерева, кущі й клумби. counts.treeClear / counts.treeMinDist (необов'язкові) —
	-- відступ стовбура від зайнятих ділянок і відстань між деревами (типово TREE_CLEAR_RADIUS / TREE_MIN_DIST)
	local function scatterVegetation(center, half, parent, counts, zoneStats)
		local treesFolder = parent:FindFirstChild("Trees") or makeFolder("Trees", parent)
		for i = 1, counts.trees do
			local pos = findSpot(center, half, counts.treeClear or TREE_CLEAR_RADIUS, 2, true, nil, counts.treeMinDist)
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
		Color = TOWN_GRASS_COLOR,
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

	-- Деталі фасаду (вікна, черепиця, димар, двері на завісах) — в одній таблиці, щоб не додавати
	-- окремих локальних змінних верхнього рівня (ліміт Luau — 200 на функцію Generate)
	local houseKit = {
		WINDOW_SIZE = 3, -- квадратний отвір вікна
		FRAME = 0.3, -- ширина рамки
		GLASS_COLOR = Color3.fromRGB(150, 220, 240),
		DOOR_OPEN_ANGLE = DOOR_OPEN_ANGLE, -- двері відчиняються всередину будинку (константа модуля)
	}

	-- Матеріал черепиці: RoofShingles, якщо він є в цій версії Roblox, інакше Slate
	do
		local ok, material = pcall(function()
			return Enum.Material.RoofShingles
		end)
		houseKit.ROOF_MATERIAL = ok and material or Enum.Material.Slate
	end

	-- Стіна з прорізами. Стіна лежить у локальній системі будинку: центр center, уздовж осі X (alongX) або Z,
	-- довжина length, висота height від низу стіни. openings — { { u1, u2, v1, v2 } }: u — уздовж стіни
	-- (від -length/2), v — від низу стіни. Над і під кожним прорізом — окремі частини, між прорізами — суцільні.
	function houseKit.wallWithOpenings(name, hcf, center, alongX, length, height, color, openings, parent)
		local t = WALL_THICKNESS
		local axis = alongX and Vector3.xAxis or Vector3.zAxis
		local function piece(pieceName, u1, u2, v1, v2)
			if u2 - u1 < 0.01 or v2 - v1 < 0.01 then
				return
			end
			local len, vh = u2 - u1, v2 - v1
			makePart("Part", {
				Name = pieceName,
				Size = alongX and Vector3.new(len, vh, t) or Vector3.new(t, vh, len),
				CFrame = hcf * CFrame.new(center + axis * ((u1 + u2) / 2) + Vector3.new(0, (v1 + v2) / 2 - height / 2, 0)),
				Material = Enum.Material.SmoothPlastic,
				Color = color,
			}, parent)
		end
		table.sort(openings, function(a, b)
			return a[1] < b[1]
		end)
		local cursor, n = -length / 2, 0
		for _, o in ipairs(openings) do
			n += 1
			piece(name .. "_" .. n, cursor, o[1], 0, height)
			piece(name .. "_Below" .. n, o[1], o[2], 0, o[3])
			piece(name .. "_Above" .. n, o[1], o[2], o[4], height)
			cursor = o[2]
		end
		piece(name .. "_" .. (n + 1), cursor, length / 2, 0, height)
	end

	-- Вікно в прорізі: рамка по периметру, хрестовина, підвіконня і напівпрозоре скло.
	-- center — центр прорізу (локально), alongX — орієнтація стіни, outward — напрямок назовні (для підвіконня).
	function houseKit.window(name, hcf, center, alongX, outward, trim, parent)
		local model = makeModel(name, parent)
		local s, f, t = houseKit.WINDOW_SIZE, houseKit.FRAME, WALL_THICKNESS
		local axis = alongX and Vector3.xAxis or Vector3.zAxis
		local function box(partName, along, up, depth, offset, props)
			local p = {
				Name = partName,
				Size = alongX and Vector3.new(along, up, depth) or Vector3.new(depth, up, along),
				CFrame = hcf * CFrame.new(center + offset),
				Material = Enum.Material.SmoothPlastic,
				Color = trim,
			}
			for k, v in pairs(props or {}) do
				p[k] = v
			end
			return makePart("Part", p, model)
		end
		local depth = t + 0.2 -- рамка трохи виступає з обох боків стіни
		box("FrameTop", s, f, depth, Vector3.new(0, s / 2 - f / 2, 0))
		box("FrameBottom", s, f, depth, Vector3.new(0, -(s / 2 - f / 2), 0))
		box("FrameLeft", f, s - 2 * f, depth, axis * -(s / 2 - f / 2))
		box("FrameRight", f, s - 2 * f, depth, axis * (s / 2 - f / 2))
		box("MullionV", 0.15, s - 2 * f, depth - 0.1, Vector3.zero)
		box("MullionH", s - 2 * f, 0.15, depth - 0.1, Vector3.zero)
		box("Sill", s + 0.6, 0.25, 0.6, Vector3.new(0, -s / 2 - 0.125, 0) + outward * (t / 2 + 0.2))
		box("Glass", s - 2 * f, s - 2 * f, 0.1, Vector3.zero, {
			Material = Enum.Material.Glass,
			Color = houseKit.GLASS_COLOR,
			Transparency = 0.4,
			CastShadow = false,
		})
		return model
	end

	-- Черепиця на двосхилому даху: на кожному схилі ROWS рядів-смуг двох відтінків кольору даху; кожен вищий
	-- ряд лежить трохи вище й заходить на нижчий, тож нижні краї рядів видно сходинками, як у справжньої черепиці.
	-- Плюс коник уздовж гребеня. Схили — як у makeRoof: гребінь на z = 0, карнизи на z = ±halfDepth.
	function houseKit.shingles(prefix, hcf, baseY, width, halfDepth, roofHeight, color, parent)
		local ROWS = 4
		local model = makeModel(prefix .. "Shingles", parent)
		local slopeLength = math.sqrt(roofHeight ^ 2 + halfDepth ^ 2)
		local rowLength = slopeLength / ROWS * 1.15
		local shades = { color, color:Lerp(Color3.new(0, 0, 0), 0.18) }
		for _, side in ipairs({ -1, 1 }) do
			-- side = -1: передній схил (карниз на -Z), +1: задній
			local eave = Vector3.new(0, baseY, side * halfDepth)
			local up = Vector3.new(0, roofHeight, -side * halfDepth) / slopeLength -- уздовж схилу до гребеня
			local normal = Vector3.new(0, halfDepth, side * roofHeight) / slopeLength -- назовні від схилу
			for k = 1, ROWS do
				local along = slopeLength * (k - 0.5) / ROWS
				local pos = eave + up * along + normal * (0.18 + 0.07 * (k - 1))
				makePart("Part", {
					Name = string.format("%s%d", side < 0 and "Front" or "Back", k),
					Size = Vector3.new(width + 0.4, 0.35, rowLength),
					CFrame = hcf * CFrame.fromMatrix(pos, Vector3.xAxis, normal),
					Material = houseKit.ROOF_MATERIAL,
					Color = shades[k % 2 + 1],
				}, model)
			end
		end
		makePart("Part", {
			Name = "Ridge",
			Size = Vector3.new(width + 0.6, 0.6, 1.4),
			CFrame = hcf * CFrame.new(0, baseY + roofHeight + 0.15, 0),
			Material = houseKit.ROOF_MATERIAL,
			Color = shades[2],
		}, model)
		return model
	end

	-- Цегляний димар на задньому схилі даху (низ утоплено в дах, верх — на 2 studs вище за гребінь) з кришкою
	function houseKit.chimney(hcf, baseY, w, halfDepth, roofHeight, parent)
		local model = makeModel("Chimney", parent)
		local x, z = w * 0.25, halfDepth * 0.45
		local surfaceY = baseY + roofHeight * (1 - z / halfDepth)
		local bottom, top = surfaceY - 1.5, baseY + roofHeight + 2
		makePart("Part", {
			Name = "Stack",
			Size = Vector3.new(2.4, top - bottom, 2.4),
			CFrame = hcf * CFrame.new(x, (bottom + top) / 2, z),
			Material = Enum.Material.Brick,
			Color = Color3.fromRGB(160, 80, 60),
		}, model)
		makePart("Part", {
			Name = "Cap",
			Size = Vector3.new(3, 0.4, 3),
			CFrame = hcf * CFrame.new(x, top + 0.2, z),
			Material = Enum.Material.Concrete,
			Color = Color3.fromRGB(90, 90, 95),
		}, model)
		return model
	end

	-- Двері на завісах у прорізі передньої стіни. Завіси — на лівому краю прорізу; відчинені двері повертаються
	-- на DOOR_OPEN_ANGLE всередину будинку (у бік +Z), уздовж стіни біля завіс — прохід лишається вільним.
	-- ProximityPrompt (E): "Open Door" / "Close Door" — повторне натискання зачиняє. Поки двері відчинені
	-- або рухаються, CanCollide = false; після зачинення — знову true. Повертає { door, setOpen(open, instant) }.
	-- Тут будуються лише деталі (вони зберігаються в місці); поведінку підключає attachDoorBehavior — її
	-- з'єднання не зберігаються, тож для "запеченого" світу її підключає ActivateDoors під час гри.
	function houseKit.hingedDoor(hcf, baseY, frontZ, color, parent)
		local model = makeModel("Door", parent)
		-- Панель стоїть над підлогою (не чіпляє її, коли повертається всередину) і трохи нижча за проріз
		local panelHeight = DOOR_HEIGHT - FLOOR_THICKNESS - 0.15
		local hingeCf = hcf * CFrame.new(-DOOR_WIDTH / 2, baseY + FLOOR_THICKNESS + 0.1 + panelHeight / 2, frontZ)
		makePart("Part", {
			Name = "Hinge",
			Size = Vector3.new(0.2, panelHeight, 0.2),
			CFrame = hingeCf,
			Transparency = 1,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
		}, model)
		local panelOffset = CFrame.new(DOOR_WIDTH / 2, 0, 0)
		local knobOffset = CFrame.new(DOOR_WIDTH - 0.8, -0.5, 0)
		local door = makePart("Part", {
			Name = "Panel",
			Size = Vector3.new(DOOR_WIDTH - 0.1, panelHeight, 0.3),
			CFrame = hingeCf * panelOffset,
			Material = Enum.Material.Wood,
			Color = color,
			CanCollide = true,
		}, model)
		makePart("Part", {
			Name = "Knob",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(0.5, 0.5, 0.5),
			CFrame = hingeCf * knobOffset,
			Material = Enum.Material.Metal,
			Color = Color3.fromRGB(230, 190, 70),
			CanCollide = false,
		}, model)
		model.PrimaryPart = door

		local angle = Instance.new("NumberValue")
		angle.Name = "Angle"
		angle.Parent = model

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Open Door"
		prompt.ObjectText = "Door"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Parent = door

		model:SetAttribute("Open", false)
		game:GetService("CollectionService"):AddTag(model, DOOR_TAG)
		local setOpen = attachDoorBehavior(model)
		return { model = model, door = door, setOpen = setOpen, hingeCf = hingeCf }
	end

	-- Самоперевірка дверей одразу після побудови будинку (миттєво, без анімації):
	-- зачинені — CanCollide = true і промінь крізь проріз упирається в двері; відчинені — CanCollide = false,
	-- панель повернута на DOOR_OPEN_ANGLE навколо завіс, проріз вільний, і відчинені двері не зачіпають
	-- меблі та сходи. Наприкінці двері знову зачинені.
	function houseKit.testDoor(house, hcf, baseY, frontZ, doorInfo)
		local door = doorInfo.door
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { house }
		params.RespectCanCollide = true
		local function doorwayBlocked()
			for _, x in ipairs({ -2.5, 0, 2.5 }) do
				local origin = (hcf * CFrame.new(x, baseY + 3, frontZ - 4)).Position
				if Workspace:Raycast(origin, hcf:VectorToWorldSpace(Vector3.new(0, 0, 8)), params) then
					return true
				end
			end
			return false
		end

		local result = { closedCollide = door.CanCollide, closedBlocked = doorwayBlocked() }
		doorInfo.setOpen(true, true)
		local expected = doorInfo.hingeCf * CFrame.Angles(0, -houseKit.DOOR_OPEN_ANGLE, 0) * CFrame.new(DOOR_WIDTH / 2, 0, 0)
		result.openCollide = door.CanCollide
		result.rotated = (door.Position - expected.Position).Magnitude < 0.01
		result.openClear = not doorwayBlocked()
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Include
		overlap.FilterDescendantsInstances = { house:FindFirstChild("Furniture"), house:FindFirstChild("Stairs") }
		result.swingClear = #Workspace:GetPartsInPart(door, overlap) == 0
		doorInfo.setOpen(false, true)
		result.reclosed = door.CanCollide and (door.Position - (doorInfo.hingeCf * CFrame.new(DOOR_WIDTH / 2, 0, 0)).Position).Magnitude < 0.01
		result.ok = result.closedCollide and result.closedBlocked and not result.openCollide and result.rotated
			and result.openClear and result.swingClear and result.reclosed
		return result
	end

	-- Перила вздовж відкритого (кімнатного) боку сходового маршу: балясини на сходинках + похилий поручень
	-- під тим самим кутом, що й сходи. x1 — початок перил уздовж маршу (нижні сходинки лишаються відкритими
	-- збоку, щоб на них можна було зайти з кімнати), z — лінія перил, rise/stepDepth — нахил маршу.
	function houseKit.stairRailing(hcf, x0, floorTop, stepDepth, rise, firstStep, lastStep, z, color, parent)
		local model = makeModel("StairRailing", parent)
		local RAIL = 3 -- висота поручня над сходинкою
		local function stepTop(k)
			return floorTop + k * rise
		end
		local function railPoint(k)
			-- Точка поручня над серединою сходинки k
			return Vector3.new(x0 + (k - 0.5) * stepDepth, stepTop(k) + RAIL, z)
		end
		local count = 0
		local posts = 5
		for i = 0, posts - 1 do
			local k = math.floor(firstStep + (lastStep - firstStep) * i / (posts - 1) + 0.5)
			local top = railPoint(k)
			makePart("Part", {
				Name = "Baluster" .. (i + 1),
				Size = Vector3.new(0.25, RAIL, 0.25),
				CFrame = hcf * CFrame.new(top.X, stepTop(k) + RAIL / 2, z),
				Material = Enum.Material.Wood,
				Color = color,
				CanCollide = true,
			}, model)
			count += 1
		end
		local a, b = railPoint(firstStep), railPoint(lastStep)
		makePart("Part", {
			Name = "Handrail",
			Size = Vector3.new(0.3, 0.3, (b - a).Magnitude + 0.3),
			CFrame = hcf * CFrame.lookAt((a + b) / 2, b),
			Material = Enum.Material.Wood,
			Color = color,
			CanCollide = true,
		}, model)
		return model, count
	end

	-- Меблі першого поверху двоповерхового будинку: кухонний куточок біля правої стіни (між вікнами),
	-- телевізор на передній стіні праворуч від вікна і диван навпроти нього. Лівий передній кут (стіл, шафа),
	-- шлях від дверей до сходів і нижні сходинки лишаються вільними. Повертає модель і список назв.
	function houseKit.furnishGroundFloor(hcf, floorTop, innerX, innerZ, parent)
		local model = makeModel("LivingRoom", parent)
		local names = {}
		local function box(name, size, x, bottomY, z, color, material, props)
			local p = {
				Name = name,
				Size = size,
				CFrame = hcf * CFrame.new(x, bottomY + size.Y / 2, z),
				Material = material or Enum.Material.Wood,
				Color = color,
			}
			for k, v in pairs(props or {}) do
				p[k] = v
			end
			makePart("Part", p, model)
		end

		-- Кухня: тумба зі стільницею (5 studs уздовж правої стіни, висота 3), дві підвісні шафки,
		-- плита й раковина на стільниці
		local kitchenX = innerX - 1 -- тумба глибиною 2 впритул до правої стіни
		local counterTop = floorTop + 3
		box("KitchenCounter", Vector3.new(2, 2.8, 5), kitchenX, floorTop, 0, Color3.fromRGB(235, 225, 205))
		box("Countertop", Vector3.new(2.2, 0.2, 5.2), kitchenX - 0.1, floorTop + 2.8, 0, Color3.fromRGB(205, 195, 180), Enum.Material.Marble)
		box("Stove", Vector3.new(1.6, 0.1, 1.8), kitchenX, counterTop, -1.3, Color3.fromRGB(35, 35, 40), Enum.Material.Metal)
		box("Sink", Vector3.new(1.3, 0.15, 1.6), kitchenX, counterTop - 0.1, 1.3, Color3.fromRGB(200, 205, 210), Enum.Material.Metal)
		box("WallCabinetFront", Vector3.new(1.2, 2, 2.3), innerX - 0.6, floorTop + 6, -1.25, Color3.fromRGB(150, 185, 160))
		box("WallCabinetBack", Vector3.new(1.2, 2, 2.3), innerX - 0.6, floorTop + 6, 1.25, Color3.fromRGB(150, 185, 160))
		table.insert(names, "kitchen (counter, 2 wall cabinets, stove, sink)")

		-- Телевізор: тумба під ним і тонкий екран на передній стіні (праворуч від вікна x 8.5..11.5)
		local tvX = 13.75
		box("TVStand", Vector3.new(4, 1.5, 1.2), tvX, floorTop, -innerZ + 0.6, Color3.fromRGB(110, 75, 45))
		box("TV", Vector3.new(3.6, 2.2, 0.25), tvX, floorTop + 2.2, -innerZ + 0.2, Color3.fromRGB(25, 25, 30), Enum.Material.SmoothPlastic)
		table.insert(names, "TV on the front wall (with stand)")

		-- Диван навпроти телевізора (~8 studs від екрана), на 3 гравців: сидіння + спинка позаду + підлокітники
		local sofaZ, sofaX, sofaLen = -5.5, 12.5, 7
		local fabric = Color3.fromRGB(95, 125, 175)
		box("SofaSeat", Vector3.new(sofaLen, 1.6, 2.6), sofaX, floorTop, sofaZ, fabric, Enum.Material.Fabric)
		box("SofaBack", Vector3.new(sofaLen, 3.2, 0.8), sofaX, floorTop, sofaZ + 1.7, fabric:Lerp(Color3.new(0, 0, 0), 0.15), Enum.Material.Fabric)
		box("SofaArmLeft", Vector3.new(0.7, 2.3, 2.6), sofaX - sofaLen / 2 + 0.35, floorTop, sofaZ, fabric, Enum.Material.Fabric)
		box("SofaArmRight", Vector3.new(0.7, 2.3, 2.6), sofaX + sofaLen / 2 - 0.35, floorTop, sofaZ, fabric, Enum.Material.Fabric)
		table.insert(names, "sofa (7 studs, facing the TV)")
		return model, names
	end

	-- Меблі другого поверху: ліжко біля правої стіни (узголів'ям до неї), тумбочка біля узголів'я, шафа
	-- біля лівої стіни між вікнами, килимок під ліжком (трохи більший за ліжко). Вихід зі сходів
	-- (x > кінця маршу, z — над отвором) лишається вільним. Повертає модель і список назв.
	function houseKit.furnishUpperFloor(hcf, slabTop, upperInnerX, upperInnerZ, parent)
		local model = makeModel("Bedroom", parent)
		local names = {}
		local function box(name, size, x, bottomY, z, color, material)
			makePart("Part", {
				Name = name,
				Size = size,
				CFrame = hcf * CFrame.new(x, bottomY + size.Y / 2, z),
				Material = material or Enum.Material.Wood,
				Color = color,
			}, model)
		end
		local wood = Color3.fromRGB(140, 90, 50)

		-- Килимок: 9 x 6 studs під ліжком
		local rugTop = slabTop + 0.15
		box("Rug", Vector3.new(9, 0.15, 6), upperInnerX - 4.5, slabTop, -1.5, Color3.fromRGB(150, 45, 60), Enum.Material.Fabric)
		table.insert(names, "rug (9x6, under the bed)")

		-- Ліжко: рама, матрац, подушка біля правої стіни
		local bedX, bedZ, bedLen = upperInnerX - 4, -1.5, 8
		box("BedFrame", Vector3.new(bedLen, 1, 4.7), bedX, rugTop, bedZ, Color3.fromRGB(110, 70, 40))
		box("Mattress", Vector3.new(bedLen - 0.2, 0.8, 4.5), bedX, rugTop + 1, bedZ, Color3.fromRGB(245, 190, 210), Enum.Material.Fabric)
		box("Pillow", Vector3.new(1.4, 0.5, 3.4), bedX + bedLen / 2 - 1, rugTop + 1.8, bedZ, WHITE, Enum.Material.Fabric)
		table.insert(names, "bed (frame, mattress, pillow)")

		-- Тумбочка біля узголів'я, впритул до правої стіни (нижче за вікно)
		box("Nightstand", Vector3.new(1.6, 2, 1.6), upperInnerX - 0.8, slabTop, bedZ - 4.0, wood)
		table.insert(names, "nightstand")

		-- Шафа біля лівої стіни, між її вікнами (z ±4.75..7.75)
		box("Wardrobe", Vector3.new(2, 6.5, 4), -upperInnerX + 1, slabTop, 0, wood)
		table.insert(names, "wardrobe (2 x 6.5 x 4)")
		return model, names
	end

	-- Перевірка розстановки меблів: жодна деталь не заходить у стіни, вікна, сходи, перила чи двері, не стоїть
	-- у зоні замаху дверей, на підході до нижніх сходинок чи на виході зі сходів нагорі, і не закриває вікна
	-- (смуга 1.5 studs перед кожним вікном). Повертає список проблем (порожній — усе гаразд).
	function houseKit.checkFurniture(house, hcf, furnitureModels, keepClear)
		local problems = {}
		local solids = {}
		for _, d in ipairs(house:GetChildren()) do
			local isWall = d:IsA("BasePart") and (d.Name:match("^Wall") or d.Name:match("^UpperWall"))
			if isWall or d.Name == "Stairs" or d.Name == "Door" or d.Name == "Windows" or d.Name == "UpperWindows" then
				table.insert(solids, d)
			end
		end
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = solids
		local furnitureParams = OverlapParams.new()
		furnitureParams.FilterType = Enum.RaycastFilterType.Include
		furnitureParams.FilterDescendantsInstances = furnitureModels

		for _, m in ipairs(furnitureModels) do
			for _, p in ipairs(m:GetDescendants()) do
				if p:IsA("BasePart") then
					local hits = Workspace:GetPartBoundsInBox(p.CFrame, p.Size - Vector3.new(0.1, 0.1, 0.1), params)
					if #hits > 0 then
						table.insert(problems, string.format("%s overlaps %s", p.Name, hits[1]:GetFullName()))
					end
				end
			end
		end
		-- Зони, що мають лишатися вільними (локальні коробки будинку)
		for _, zone in ipairs(keepClear) do
			local hits = Workspace:GetPartBoundsInBox(hcf * zone.cframe, zone.size, furnitureParams)
			if #hits > 0 then
				table.insert(problems, string.format("%s blocks %s", hits[1].Name, zone.name))
			end
		end
		-- Смуга перед кожним вікном (вікна в стінах, вирівняних по осях світу)
		for _, folderName in ipairs({ "Windows", "UpperWindows" }) do
			local folder = house:FindFirstChild(folderName)
			for _, window in ipairs(folder and folder:GetChildren() or {}) do
				local cf, size = window:GetBoundingBox()
				local extended = size.X < size.Z and Vector3.new(size.X + 3, size.Y, size.Z) or Vector3.new(size.X, size.Y, size.Z + 3)
				local hits = Workspace:GetPartBoundsInBox(cf, extended, furnitureParams)
				if #hits > 0 then
					table.insert(problems, string.format("%s covers window %s", hits[1].Name, window.Name))
				end
			end
		end
		return problems
	end

	-- Чотири стіни коробки розміром size, що стоїть на висоті baseY, з вікнами (і дверним прорізом спереду).
	-- windows = { front = { u... }, back = {...}, left = {...}, right = {...} } — центри вікон уздовж стіни
	-- (front/back — по X, left/right — по Z); висота вікна — посередині стіни. Повертає frontZ і кількість вікон.
	local function makeWalls(prefix, hcf, baseY, size, color, withDoor, parent, windows, trim)
		local w, h, d = size.X, size.Y, size.Z
		local t = WALL_THICKNESS
		local s = houseKit.WINDOW_SIZE
		local winBottom = h / 2 - s / 2
		local frontZ = -(d / 2 - t / 2)
		local count = 0
		local windowsFolder = makeModel(prefix .. "Windows", parent)

		-- Стіни: передня й задня на всю ширину, бічні — вставлені між ними
		local walls = {
			{ key = "front", name = "WallFront", center = Vector3.new(0, baseY + h / 2, frontZ), alongX = true, length = w, out = -Vector3.zAxis },
			{ key = "back", name = "WallBack", center = Vector3.new(0, baseY + h / 2, d / 2 - t / 2), alongX = true, length = w, out = Vector3.zAxis },
			{ key = "left", name = "WallLeft", center = Vector3.new(-(w / 2 - t / 2), baseY + h / 2, 0), alongX = false, length = d - 2 * t, out = -Vector3.xAxis },
			{ key = "right", name = "WallRight", center = Vector3.new(w / 2 - t / 2, baseY + h / 2, 0), alongX = false, length = d - 2 * t, out = Vector3.xAxis },
		}
		for _, wall in ipairs(walls) do
			local openings = {}
			if wall.key == "front" and withDoor then
				table.insert(openings, { -DOOR_WIDTH / 2, DOOR_WIDTH / 2, 0, DOOR_HEIGHT })
			end
			for _, u in ipairs(windows and windows[wall.key] or {}) do
				table.insert(openings, { u - s / 2, u + s / 2, winBottom, winBottom + s })
				count += 1
				local axis = wall.alongX and Vector3.xAxis or Vector3.zAxis
				houseKit.window(string.format("%s%s%d", prefix, wall.name, count), hcf,
					wall.center + axis * u + Vector3.new(0, winBottom + s / 2 - h / 2, 0), wall.alongX, wall.out, trim, windowsFolder)
			end
			houseKit.wallWithOpenings(prefix .. wall.name, hcf, wall.center, wall.alongX, wall.length, h, color, openings, parent)
		end
		return frontZ, count
	end

	-- Двосхилий дах із двох WedgePart над коробкою w x d, гребінь уздовж X, поверх них — черепиця
	local function makeRoof(prefix, hcf, baseY, w, d, roofHeight, overhang, color, parent)
		local halfDepth = d / 2 + overhang
		local roofY = baseY + roofHeight / 2
		local wedgeSize = Vector3.new(w + overhang * 2, roofHeight, halfDepth)
		local baseColor = color:Lerp(Color3.new(0, 0, 0), 0.3) -- основа під черепицею (видно з торців)
		-- WedgePart: висока грань на +Z, схил спускається до -Z
		makePart("WedgePart", {
			Name = prefix .. "RoofFront",
			Size = wedgeSize,
			CFrame = hcf * CFrame.new(0, roofY, -halfDepth / 2),
			Material = Enum.Material.SmoothPlastic,
			Color = baseColor,
		}, parent)
		-- Друга половина розвернута на 180°, щоб схил ішов до +Z
		makePart("WedgePart", {
			Name = prefix .. "RoofBack",
			Size = wedgeSize,
			CFrame = hcf * CFrame.new(0, roofY, halfDepth / 2) * CFrame.Angles(0, math.pi, 0),
			Material = Enum.Material.SmoothPlastic,
			Color = baseColor,
		}, parent)
		houseKit.shingles(prefix, hcf, baseY, w + overhang * 2, halfDepth, roofHeight, color, parent)
		return halfDepth
	end

	-- Будинок: порожня коробка зі стін з вікнами, підлога, двері на завісах, дах із черепицею й димарем, меблі;
	-- при variant.twoStory — перекриття з отвором, сходи і менший другий поверх зі своїм дахом
	local function makeHouse(name, yardCf, variant, parent)
		local house = makeModel(name, parent)
		local hcf = yardCf * CFrame.new(0, 0, HOUSE_CENTER_Z)
		local w, h, d = HOUSE_SIZE.X, HOUSE_SIZE.Y, HOUSE_SIZE.Z
		local t = WALL_THICKNESS
		local innerX, innerZ = w / 2 - t, d / 2 - t -- піврозміри внутрішнього простору
		local info = { name = name, scheme = variant.scheme, variant = variant }

		-- Перший поверх. Вікна: спереду одне праворуч від дверей, на інших стінах по два.
		-- Ліва стіна: вікна оминають шафу (z -10.5..-5.5) біля передньої частини стіни.
		-- У двоповерховому будинку сходи йдуть уздовж задньої стіни (x -14.5..4.2), тож задні вікна — правіше.
		local frontZ, groundWindows = makeWalls("", hcf, GROUND_TOP, HOUSE_SIZE, variant.wall, true, house, {
			front = { 10 },
			back = variant.twoStory and { 6, 12 } or { -w / 4, w / 4 },
			left = { -1, 7 },
			right = { -7, 7 },
		}, variant.trim)
		info.windows, info.groundWindows, info.upperWindows = groundWindows, groundWindows, 0

		-- Підлога всередині периметра стін
		house.PrimaryPart = makeSlab("Floor", hcf, -innerX, innerX, -innerZ, innerZ,
			GROUND_TOP, FLOOR_THICKNESS, Color3.fromRGB(200, 150, 100), Enum.Material.WoodPlanks, house)
		local floorTop = GROUND_TOP + FLOOR_THICKNESS

		-- Меблі-заглушки: стіл і шафа ліворуч спереду, ліжко праворуч (задня ліва смуга — під сходи).
		-- У двоповерховому будинку замість ліжка — вітальня з кухнею (нижче), спальня — нагорі.
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
		if not variant.twoStory then
			furnitureBox("Bed", Vector3.new(4.5, 1.5, 8), 12, 4, variant.blanket, Enum.Material.Fabric)
			makePart("Part", {
				Name = "Pillow",
				Size = Vector3.new(3.4, 0.6, 1.4),
				CFrame = hcf * CFrame.new(12, floorTop + 1.8, 7.2),
				Material = Enum.Material.Fabric,
				Color = WHITE,
			}, furniture)
		end

		if not variant.twoStory then
			local halfDepth = makeRoof("", hcf, GROUND_TOP + h, w, d, ROOF_HEIGHT, ROOF_OVERHANG, variant.roof, house)
			houseKit.chimney(hcf, GROUND_TOP + h, w, halfDepth, ROOF_HEIGHT, house)
		else
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

			-- Сходи: суцільні сходинки, остання — врівень із перекриттям. Марш займає весь проліт від краю
			-- отвору з боку кімнати (holeZ1) до задньої стіни (innerZ) — без щілини між сходами і стіною.
			-- Зовнішні 2 studs маршу (z > holeZ2) — під перекриттям, тож угорі там нижча стеля; виходять нагору
			-- через отвір (holeZ1..holeZ2).
			local stairs = makeModel("Stairs", house)
			local rise = (slabTop - floorTop) / stepCount
			local stairZ1, stairZ2 = holeZ1, innerZ
			for k = 1, stepCount do
				local stepH = k * rise
				makePart("Part", {
					Name = "Step" .. k,
					Size = Vector3.new(stepDepth, stepH, stairZ2 - stairZ1),
					CFrame = hcf * CFrame.new(holeX1 + (k - 0.5) * stepDepth, floorTop + stepH / 2, (stairZ1 + stairZ2) / 2),
					Material = Enum.Material.WoodPlanks,
					Color = Color3.fromRGB(170, 115, 70),
				}, stairs)
			end

			-- Перила з відкритого (кімнатного) боку маршу, від 4-ї сходинки до верху: перші три низькі
			-- сходинки лишаються відкритими збоку, щоб на марш можна було ступити з кімнати
			local railingColor = Color3.fromRGB(150, 100, 60)
			local _, balusters = houseKit.stairRailing(hcf, holeX1, floorTop, stepDepth, rise, 4, stepCount,
				stairZ1 + 0.15, railingColor, stairs)
			info.stairs = {
				width = stairZ2 - stairZ1, passage = innerZ - holeZ1, wallGap = innerZ - stairZ2,
				holeWidth = holeZ2 - holeZ1, balusters = balusters, fromStep = 4, toStep = stepCount,
			}

			-- Поруччя вздовж отвору на другому поверсі (з боку кімнати)
			makePart("Part", {
				Name = "Railing",
				Size = Vector3.new(holeX2 - holeX1, 3, 0.2),
				CFrame = hcf * CFrame.new((holeX1 + holeX2) / 2, slabTop + 1.5, holeZ1 - 0.1),
				Material = Enum.Material.Wood,
				Color = Color3.fromRGB(120, 70, 35),
			}, stairs)

			-- Другий поверх: менша коробка без дверей, по два вікна на кожній стіні, скриня, власний дах із димарем
			local _, upperWindows = makeWalls("Upper", hcf, slabTop, UPPER_SIZE, variant.wall, false, house, {
				front = { -UPPER_SIZE.X / 4, UPPER_SIZE.X / 4 },
				back = { -UPPER_SIZE.X / 4, UPPER_SIZE.X / 4 },
				left = { -(UPPER_SIZE.Z - 2 * t) / 4, (UPPER_SIZE.Z - 2 * t) / 4 },
				right = { -(UPPER_SIZE.Z - 2 * t) / 4, (UPPER_SIZE.Z - 2 * t) / 4 },
			}, variant.trim)
			info.upperWindows = upperWindows
			info.windows += upperWindows
			-- Меблі: вітальня з кухнею внизу, спальня нагорі (замість колишньої скрині-заглушки)
			local living, groundNames = houseKit.furnishGroundFloor(hcf, floorTop, innerX, innerZ, house)
			local bedroom, upperNames = houseKit.furnishUpperFloor(hcf, slabTop, upperInnerX, upperInnerZ, house)
			info.furniture = { ground = groundNames, upper = upperNames }
			info.furnitureModels = { living, bedroom }
			info.keepClear = {
				{ name = "stair entry (lower steps)", cframe = CFrame.new(-12.5, floorTop + 2.5, 6.7), size = Vector3.new(4, 5, 3.4) },
				{ name = "stair exit on the upper floor", cframe = CFrame.new(holeX2 + 2.2, slabTop + 2.5, (holeZ1 + holeZ2) / 2), size = Vector3.new(4.4, 5, holeZ2 - holeZ1) },
			}
			local halfDepth = makeRoof("Upper", hcf, slabTop + UPPER_SIZE.Y, UPPER_SIZE.X, UPPER_SIZE.Z,
				UPPER_ROOF_HEIGHT, ROOF_OVERHANG, variant.roof, house)
			houseKit.chimney(hcf, slabTop + UPPER_SIZE.Y, UPPER_SIZE.X, halfDepth, UPPER_ROOF_HEIGHT, house)
		end

		-- Двері на завісах (будуються після меблів і сходів, щоб самоперевірка бачила їх)
		local doorInfo = houseKit.hingedDoor(hcf, GROUND_TOP, frontZ, variant.door, house)
		info.door = houseKit.testDoor(house, hcf, GROUND_TOP, frontZ, doorInfo)
		if info.furnitureModels then
			table.insert(info.keepClear, {
				name = "door swing",
				cframe = CFrame.new(0, floorTop + DOOR_HEIGHT / 2, frontZ + DOOR_WIDTH / 2 + 0.2),
				size = Vector3.new(DOOR_WIDTH + 1, DOOR_HEIGHT, DOOR_WIDTH + 0.4),
			})
			info.furnitureProblems = houseKit.checkFurniture(house, hcf, info.furnitureModels, info.keepClear)
		end
		stats.houses = stats.houses or {}
		table.insert(stats.houses, info)
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

	-- Кольорові схеми будинків у стилі піксельних містечок: пастельні стіни + контрастний дах;
	-- рами вікон (trim) і двері (door) контрастують зі стінами. Другий будинок — двоповерховий.
	local VARIANTS = {
		{
			scheme = "cream walls + red roof",
			wall = Color3.fromRGB(255, 240, 205), roof = Color3.fromRGB(205, 55, 50),
			trim = Color3.fromRGB(110, 70, 40), door = Color3.fromRGB(150, 60, 45),
			fence = Color3.fromRGB(235, 225, 205), bush = Color3.fromRGB(60, 170, 60),
			blanket = Color3.fromRGB(80, 140, 230), flowers = { PINK, WHITE },
		},
		{
			scheme = "sand-yellow walls + green roof",
			wall = Color3.fromRGB(245, 225, 150), roof = Color3.fromRGB(65, 140, 75),
			trim = Color3.fromRGB(250, 250, 245), door = Color3.fromRGB(120, 75, 40),
			fence = Color3.fromRGB(170, 115, 65), bush = Color3.fromRGB(45, 150, 70),
			blanket = Color3.fromRGB(230, 90, 90), flowers = { YELLOW, WHITE, PINK },
			twoStory = true,
		},
		{
			scheme = "mint walls + navy roof",
			wall = Color3.fromRGB(190, 235, 220), roof = Color3.fromRGB(45, 65, 135),
			trim = Color3.fromRGB(250, 250, 245), door = Color3.fromRGB(50, 75, 150),
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
		-- DayNightCycle вмикає/вимикає ліхтарі за тегом (світять увечері, вночі й на світанку)
		game:GetService("CollectionService"):AddTag(bulb, "StreetLamp")
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
		Color = WILD_GRASS_COLOR,
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
	-- 6. Зони високої трави (EncounterZone1-2): дві великі суцільні зарості неправильної форми,
	--    і три менші декоративні зарості тієї ж трави в містечку (TallGrassPatch1-3, не зони зустрічей)
	--    Зарості прохідні: гравець може зайти в траву (майбутні зустрічі з Wivi). Окремих стежок через дику
	--    зону немає: Street1 веде з площі до центральної галявини, а зарості починаються з обох боків від неї.
	--    Колишні чотири зони об'єднано попарно (північна й південна пара) разом із прохідною стежкою між ними.
	---------------------------------------------------------------------
	-- Блок do...end: допоміжні змінні розділу не займають місця серед локальних змінних верхнього рівня (ліміт Luau — 200)
	do
		local ENCOUNTER_GRASS_COLORS = {
			Color3.fromRGB(25, 115, 35),
			Color3.fromRGB(35, 130, 40),
			Color3.fromRGB(20, 100, 45),
			Color3.fromRGB(45, 140, 35),
		}

		-- Чи точка (lx, lz) відносно центру зони лежить усередині її форми. "blob" — суперелліпс
		-- (повніший за овал), чий "радіус" хвилясто змінюється з кутом: межа нерівна, як у природних заростях,
		-- але ніколи не виходить за габарит zone.size.
		local function insideZoneShape(zone, lx, lz)
			local hx, hz = zone.size.X / 2, zone.size.Y / 2
			if zone.shape == "blob" then
				local nx, nz = lx / hx, lz / hz
				local angle = math.atan2(nz, nx)
				local limit = 0.92 + 0.04 * (math.sin(3 * angle + zone.phase1) + math.sin(5 * angle + zone.phase2))
				return (math.abs(nx) ^ 2.6 + math.abs(nz) ^ 2.6) ^ (1 / 2.6) <= limit
			elseif zone.shape == "oval" then
				return (lx / hx) ^ 2 + (lz / hz) ^ 2 <= 1
			end
			return math.abs(lx) <= hx and math.abs(lz) <= hz
		end

		-- Щільна сітка тонких високих травинок із випадковим зсувом і нахилом (без колізії) у формі zone,
		-- плюс зайнята ділянка для рослинності. Спільна для зон зустрічей і декоративних заростей у містечку.
		-- Повертає площу зарості (кількість вузлів сітки всередині форми × крок²).
		local function growTallGrass(zone, parent)
			local cx, cz = zone.center.X, zone.center.Y
			local hx, hz = zone.size.X / 2, zone.size.Y / 2
			local blades = makeFolder("Blades", parent)
			local step = ENCOUNTER_GRASS_STEP
			local cells = 0
			for lx = -hx + step / 2, hx, step do
				for lz = -hz + step / 2, hz, step do
					if insideZoneShape(zone, lx, lz) then
						cells += 1
					end
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

			-- Габарит зарості, розширений на ENCOUNTER_ZONE_CLEARANCE - PATH_MARGIN: рослинність відступає від
			-- нього на свій радіус + PATH_MARGIN, тож стовбури й клапті трави — щонайменше за ENCOUNTER_ZONE_CLEARANCE
			local pad = ENCOUNTER_ZONE_CLEARANCE - PATH_MARGIN
			blockRect(cx - hx - pad, cx + hx + pad, cz - hz - pad, cz + hz + pad, true)
			return cells * step * step
		end

		-- Зона зустрічей: невидимий тригер + табличка "Tall Grass" + щільні зарості травинок
		local function makeEncounterZone(index, zone, parent)
			local model = makeModel("EncounterZone" .. index, parent)
			local cx, cz = zone.center.X, zone.center.Y
			local hx, hz = zone.size.X / 2, zone.size.Y / 2

			-- Тригер для майбутньої логіки зустрічей (поки без скриптів)
			-- TODO: для зон "blob"/"oval" перевіряти потрапляння у форму (insideZoneShape), а не в прямокутний тригер
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

			local area = growTallGrass(zone, model)
			stats.wild.encounterZones += 1
			table.insert(stats.wild.zones, {
				name = model.Name, minX = cx - hx, maxX = cx + hx, minZ = cz - hz, maxZ = cz + hz,
				size = zone.size, area = area,
			})
			return model
		end

		-- Дві великі зарості по обидва боки від Street1 і галявини, зміщені одна відносно одної:
		-- північна — на захід (над Street1), південна — на схід (за галявиною). Вільні кути (північний схід
		-- і південний захід) і смуги вздовж гір лишаються під дерева. Відступи ≥ ENCOUNTER_ZONE_CLEARANCE від
		-- підніжжя гір (|z| = 34, x = 204), Street1 (|z| <= 3) і галявини (|z| <= 7.5).
		local wc = WILD_CENTER
		local ENCOUNTER_ZONES = {
			{ center = Vector2.new(wc.X - 21, wc.Z - 22), size = Vector2.new(46, 18), shape = "blob" },
			{ center = Vector2.new(wc.X + 5, wc.Z + 22), size = Vector2.new(46, 18), shape = "blob" },
		}
		stats.wild.zones = {}
		local encounterFolder = makeFolder("EncounterZones", wild)
		for i, zone in ipairs(ENCOUNTER_ZONES) do
			zone.phase1, zone.phase2 = rng:NextNumber(0, math.pi * 2), rng:NextNumber(0, math.pi * 2)
			makeEncounterZone(i, zone, encounterFolder)
		end

		-- Декоративні зарості високої трави в містечку (не зони зустрічей: без тригера й таблички).
		-- Розміри — як у невеликих заростей дикої зони. Місця (відступи ≥ ENCOUNTER_ZONE_CLEARANCE):
		--   • між подвір'ями House2 (-70, -60) і House3 (-70, 60), на захід від гілок Street3 (x = -70) —
		--     за 3 studs від найдальшого можливого куща на узбіччі (край до x = -83.5) і за 3.5 від підніжжя гір (x = -104);
		--   • позаду House2 (фасад дивиться на +Z): між заднім парканом (z = -82.5) і горами (z = -104);
		--   • збоку від House1 (0, 75): на схід від його паркану (x = 22.5).
		local TOWN_TALL_GRASS = {
			{ label = "between House2/House3", center = Vector2.new(-93.5, 0), size = Vector2.new(14, 18), shape = "blob" },
			{ label = "behind House2", center = Vector2.new(yard2Center.X, -93), size = Vector2.new(20, 12), shape = "blob" },
			{ label = "beside House1", center = Vector2.new(38, yard1Center.Z), size = Vector2.new(16, 18), shape = "blob" },
		}
		stats.town.tallGrass = {}
		local townGrassFolder = makeFolder("TallGrassPatches", town)
		for i, zone in ipairs(TOWN_TALL_GRASS) do
			zone.phase1, zone.phase2 = rng:NextNumber(0, math.pi * 2), rng:NextNumber(0, math.pi * 2)
			local model = makeModel("TallGrassPatch" .. i, townGrassFolder)
			model:SetAttribute("EncounterZone", false)
			model:SetAttribute("Location", zone.label)
			local area = growTallGrass(zone, model)
			local cx, cz, hx, hz = zone.center.X, zone.center.Y, zone.size.X / 2, zone.size.Y / 2
			table.insert(stats.town.tallGrass, {
				name = model.Name, label = zone.label, minX = cx - hx, maxX = cx + hx, minZ = cz - hz, maxZ = cz + hz,
				size = zone.size, area = area,
			})
		end
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
	--    • WorldFloor — рамка кольору зон навколо газонів під усім кільцем (до зовнішньої грані стін), на рівні газонів:
	--      прилягає до країв газонів без сходинки й без накладання і не лишає порожнечі між краєм підлоги та стіною.
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

	-- WorldFloor: рамка навколо газонів зон, що разом із ними закриває квадрат з колом радіусом до зовнішньої
	-- грані стін. Верх — точно на рівні газонів (GROUND_TOP), товщина як у газонів, тож на стику немає сходинки.
	-- Під газонами підлоги немає: дві поверхні на одній висоті одна над одною мерехтіли б (z-fighting),
	-- тож рамка лише прилягає до країв газонів без накладання.
	-- Колір — як у газону поруч: усе на захід від стику містечка й дикої зони (x = TOWN_HALF) — колір
	-- містечка, на схід — колір дикої зони. Шов підкладки продовжує лінію, де газони вже стикуються.
	local floorRadius = safeRadius + SAFE_ZONE_THICKNESS + 2
	local floorTop = GROUND_TOP
	local floorSeamX = TOWN_HALF
	local worldFloor = makeModel("WorldFloor", world)
	do
		local minX, maxX = safeCenter.X - floorRadius, safeCenter.X + floorRadius
		local minZ, maxZ = safeCenter.Y - floorRadius, safeCenter.Y + floorRadius
		local wildEast = WILD_CENTER.X + WILD_HALF
		for _, section in ipairs({
			-- Навколо містечка (x < TOWN_HALF): захід, північ, південь
			{ name = "TownWest", minX = minX, maxX = -TOWN_HALF, minZ = minZ, maxZ = maxZ, color = TOWN_GRASS_COLOR },
			{ name = "TownNorth", minX = -TOWN_HALF, maxX = floorSeamX, minZ = minZ, maxZ = -TOWN_HALF, color = TOWN_GRASS_COLOR },
			{ name = "TownSouth", minX = -TOWN_HALF, maxX = floorSeamX, minZ = TOWN_HALF, maxZ = maxZ, color = TOWN_GRASS_COLOR },
			-- Навколо дикої зони (x > TOWN_HALF): північ, південь, схід
			{ name = "WildNorth", minX = floorSeamX, maxX = maxX, minZ = minZ, maxZ = -WILD_HALF, color = WILD_GRASS_COLOR },
			{ name = "WildSouth", minX = floorSeamX, maxX = maxX, minZ = WILD_HALF, maxZ = maxZ, color = WILD_GRASS_COLOR },
			{ name = "WildEast", minX = wildEast, maxX = maxX, minZ = -WILD_HALF, maxZ = WILD_HALF, color = WILD_GRASS_COLOR },
		}) do
			makePart("Part", {
				Name = section.name,
				Size = Vector3.new(section.maxX - section.minX, GROUND_THICKNESS, section.maxZ - section.minZ),
				Position = Vector3.new((section.minX + section.maxX) / 2, floorTop - GROUND_THICKNESS / 2, (section.minZ + section.maxZ) / 2),
				Material = Enum.Material.Grass,
				Color = section.color,
			}, worldFloor)
		end
	end

	-- Перевірка рівнів: верх кожної секції WorldFloor має збігатися з верхом газонів (з точністю 0.1 stud),
	-- і жодна секція не має заходити під газон (інакше z-fighting). Повертає рядок звіту й ознаку "без сходинки".
	local function checkFloorLevels()
		local function top(part)
			return part.Position.Y + part.Size.Y / 2
		end
		local function rectOf(part)
			return {
				minX = part.Position.X - part.Size.X / 2, maxX = part.Position.X + part.Size.X / 2,
				minZ = part.Position.Z - part.Size.Z / 2, maxZ = part.Position.Z + part.Size.Z / 2,
			}
		end
		local townTop, wildTop = top(town.PrimaryPart), top(wild.PrimaryPart)
		local lawns = { rectOf(town.PrimaryPart), rectOf(wild.PrimaryPart) }
		local floorMin, floorMax, worst, overlaps = math.huge, -math.huge, math.abs(townTop - wildTop), 0
		for _, part in ipairs(worldFloor:GetChildren()) do
			local t = top(part)
			floorMin, floorMax = math.min(floorMin, t), math.max(floorMax, t)
			worst = math.max(worst, math.abs(t - townTop), math.abs(t - wildTop))
			for _, lawn in ipairs(lawns) do
				if rectsOverlap(rectOf(part), lawn, 0.01) then
					overlaps += 1
					warn(string.format("[WorldGenerator] WorldFloor.%s overlaps a lawn — coplanar surfaces will flicker", part.Name))
				end
			end
		end
		local flat = worst <= 0.1 and overlaps == 0
		return string.format(
			"[WorldGenerator] Ground levels (top Y): TownArea lawn %.2f, WildArea lawn %.2f, WorldFloor %.2f..%.2f (%d sections, no overlap with lawns: %s); max difference %.2f studs — %s",
			townTop, wildTop, floorMin, floorMax, #worldFloor:GetChildren(), tostring(overlaps == 0), worst,
			flat and "no visible step" or "WARNING: visible step between the ground surfaces"), flat
	end

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

	-- SafeZoneBoundary — окремий сегмент стіни в тілі КОЖНОГО клону GrassMountain, повернутий разом із ним.
	-- • Габарити клону — його орієнтована коробка (GetBoundingBox: реальний масштаб і власний випадковий поворот).
	-- • "Перед" гори — та з чотирьох бічних граней коробки, що найбільше дивиться в ігрову зону (проти зовнішньої
	--   нормалі ряду клону). Сегмент паралельний цій грані, завширшки як вона + MOUNTAIN_WALL_OVERLAP з кожного
	--   боку, і стоїть на offset studs углиб від неї (товщина стіни — ще далі).
	-- • Offset — MOUNTAIN_WALL_DEPTH, якщо гора в цьому напрямку товща за offset + товщину стіни; інакше
	--   MOUNTAIN_WALL_FALLBACK її товщини (і зовнішня грань стіни все одно лишається в камені).
	-- • Сусідні сегменти можуть бути повернуті під різними кутами, тож кінець кожного з'єднано з початком
	--   наступного (по колу, у порядку рядів) перемичкою Joint: стіна — замкнена ламана без щілин.
	local MOUNTAIN_WALL_OVERLAP = 2.5

	local mountainWallInfo = {} -- клон → { depth, offset, reduced, cframe, width, startPoint, endPoint }
	local reducedWallSegments = 0
	local frontWall = makeModel("SafeZoneBoundary", safeZone)
	local frontWallJoints = 0
	do
		local wallY = (SAFE_ZONE_BOTTOM + SAFE_ZONE_TOP) / 2

		for index, clone in ipairs(mountainClones) do
			local edge = playEdges[mountainRowIndex[clone]]
			local inward = Vector3.new(-edge.out.X, 0, -edge.out.Y)
			local cf, size = clone:GetBoundingBox()
			local axes
			if math.abs(cf.UpVector.Y) > 0.99 then
				axes = { { cf.RightVector, size.X, size.Z }, { cf.LookVector, size.Z, size.X } }
			else
				-- Шаблон нахилений: коробка не стоїть рівно, беремо осе-орієнтовані межі
				local rect = modelRect(clone)
				cf = CFrame.new((rect.minX + rect.maxX) / 2, 0, (rect.minZ + rect.maxZ) / 2)
				axes = { { Vector3.xAxis, rect.maxX - rect.minX, rect.maxZ - rect.minZ }, { Vector3.zAxis, rect.maxZ - rect.minZ, rect.maxX - rect.minX } }
			end

			-- Передня грань: вісь (зі знаком), що найближча до напрямку в ігрову зону
			local front, depth, width, best = nil, 0, 0, -math.huge
			for _, axis in ipairs(axes) do
				local v = Vector3.new(axis[1].X, 0, axis[1].Z).Unit
				for _, sign in ipairs({ 1, -1 }) do
					local dot = (v * sign):Dot(inward)
					if dot > best then
						front, depth, width, best = v * sign, axis[2], axis[3], dot
					end
				end
			end

			local offset, reduced = MOUNTAIN_WALL_DEPTH, false
			if offset + MOUNTAIN_WALL_THICKNESS >= depth then
				offset = math.min(depth * MOUNTAIN_WALL_FALLBACK, depth - MOUNTAIN_WALL_THICKNESS - 0.5)
				reduced = true
				reducedWallSegments += 1
			end

			local center = Vector3.new(cf.Position.X, wallY, cf.Position.Z)
			local frontPoint = center + front * (depth / 2)
			local wallCenter = frontPoint - front * (offset + MOUNTAIN_WALL_THICKNESS / 2)
			local wallCf = CFrame.lookAt(wallCenter, wallCenter + front) -- RightVector — уздовж передньої грані
			local wallWidth = width + 2 * MOUNTAIN_WALL_OVERLAP
			makePart("Part", {
				Name = "Wall_" .. clone.Name,
				Size = Vector3.new(wallWidth, safeHeight, MOUNTAIN_WALL_THICKNESS),
				CFrame = wallCf,
				Material = Enum.Material.SmoothPlastic,
				Transparency = 1,
				CanCollide = true,
				CastShadow = false,
			}, frontWall)

			-- Кінці сегмента (по осі стіни): "початок" — той, що раніше вздовж ряду
			local a = wallCenter - wallCf.RightVector * (wallWidth / 2)
			local b = wallCenter + wallCf.RightVector * (wallWidth / 2)
			local dir3 = Vector3.new(edge.dir.X, 0, edge.dir.Y)
			if (b - a):Dot(dir3) < 0 then
				a, b = b, a
			end
			mountainWallInfo[clone] = {
				index = index, depth = depth, offset = offset, reduced = reduced, startPoint = a, endPoint = b,
			}
		end

		-- Перемички між кінцем сегмента і початком наступного (останній — з першим)
		local wallPart = MOUNTAIN_WALL_THICKNESS
		for k, clone in ipairs(mountainClones) do
			local nextClone = mountainClones[k % #mountainClones + 1]
			local p, q = mountainWallInfo[clone].endPoint, mountainWallInfo[nextClone].startPoint
			local gap = (q - p).Magnitude
			if nextClone ~= clone and gap > 0.05 then
				local mid = (p + q) / 2
				makePart("Part", {
					Name = string.format("Joint_%s", clone.Name),
					Size = Vector3.new(wallPart, safeHeight, gap + wallPart), -- + товщина: закриває кути на стиках
					CFrame = CFrame.lookAt(mid, q),
					Material = Enum.Material.SmoothPlastic,
					Transparency = 1,
					CanCollide = true,
					CastShadow = false,
				}, frontWall)
				frontWallJoints += 1
			end
		end
	end

	-- Замкненість стіни: промені з ігрової зони (2 studs перед підніжжям) назовні через кожні 2 studs уздовж
	-- кожного ребра на кількох висотах мають влучити в стіну (сегмент або перемичку). Промені довгі: біля
	-- увігнутих кутів промінь іде вздовж кам'яної кишені й упирається в стіну іншого ряду. Повертає кількість промахів.
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

	-- Перевірка кожного сегмента: у системі ЙОГО гори (уздовж нормалі передньої грані після повороту) стіна
	-- займає offset..offset + товщина від передньої грані; вона в тілі гори, якщо 0 < offset і offset + товщина < товщини гори.
	-- Друкує рядок на кожну гору; повертає кількість сегментів поза тілом гори і мін./макс. offset.
	local function checkWallThroughMountains()
		local bad, minOffset, maxOffset = 0, math.huge, -math.huge
		for _, clone in ipairs(mountainClones) do
			local info = mountainWallInfo[clone]
			local inside = info.offset > 0 and info.offset + MOUNTAIN_WALL_THICKNESS < info.depth
			minOffset = math.min(minOffset, info.offset)
			maxOffset = math.max(maxOffset, info.offset)
			local p = clone:GetPivot().Position
			local line = string.format(
				"[WorldGenerator]   segment %d %s at (%.1f, %.1f): mountain %.1f studs deep, offset +%.1f%s, wall %.1f..%.1f — %s",
				info.index, clone.Name, p.X, p.Z, info.depth, info.offset,
				info.reduced and string.format(" (REDUCED from +%.1f: mountain too thin)", MOUNTAIN_WALL_DEPTH) or "",
				info.offset, info.offset + MOUNTAIN_WALL_THICKNESS, inside and "inside the mountain body" or "OUTSIDE the mountain body")
			if inside and not info.reduced then
				print(line)
			else
				warn(line)
			end
			if not inside then
				bad += 1
			end
		end
		return bad, minOffset, maxOffset
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

	-- Дика зона: густий ліс по всій вільній площі (усе, крім заростей, Street1 і галявини), кущі (трохи
	-- темніші, ніж у містечку) і клумби. Дерева ставляться щільніше, ніж у містечку: центр стовбура за 1.5 + PATH_MARGIN studs
	-- від зайнятих ділянок і 7 studs між деревами (крони можуть торкатися, як у справжньому лісі)
	scatterVegetation(WILD_CENTER, WILD_HALF, wild, {
		trees = rng:NextInteger(20, 25),
		treeClear = 1.5,
		treeMinDist = 7,
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

	-- Декоративні клапті трави (шаблон grass / GrassPatchTemplate) на газоні обох зон: у містечку 28-40,
	-- у дикій зоні 25-35; масштаб 0.7-1.2, поворот 0-360°, без колізії. Ставляться останніми й оминають
	-- зайняті ділянки (вулиці, подвір'я з будинками, галявину, зарості, смугу перед горами).
	-- У містечку — ще й з відступом 2 studs від дерев, кущів і декору. У дикій зоні вільного газону мало
	-- (ліс + великі зарості), тож пласкі клапті можуть частково заходити під крони й один на одного:
	-- центр клаптя лише не ближче 40% його радіуса до краю іншого об'єкта.
	if grassTemplate then
		local minV, maxV = worldBounds(grassTemplate)
		local baseRadius = math.max(maxV.X - minV.X, maxV.Z - minV.Z) / 2
		local GRASS_GAP = 2
		local function scatterGrass(center, half, count, parent, zoneStats, tuckUnder)
			for i = 1, count do
				local scale = rng:NextNumber(0.7, 1.2)
				local radius = baseRadius * scale
				local pos = findSpot(center, half, radius, radius, false, tuckUnder and -0.6 * radius or GRASS_GAP)
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
		scatterGrass(WILD_CENTER, WILD_HALF, rng:NextInteger(25, 35), makeFolder("GrassPatches", wild), stats.wild, true)
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
	-- Звіт — окрема функція: її локальні змінні мають власні регістри. Блок do...end цього не дає — його
	-- змінні додаються до регістрів функції Generate, а там ліміт Luau — 200 локальних змінних.
	local function printReport()
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

		-- Будинки: кольорова схема, вікна, двері на завісах (результат самоперевірки після побудови)
		for _, info in ipairs(stats.houses or {}) do
			local function rgb(c)
				return string.format("%d,%d,%d", math.round(c.R * 255), math.round(c.G * 255), math.round(c.B * 255))
			end
			local v, d = info.variant, info.door
			print(string.format(
				"[WorldGenerator] %s: scheme \"%s\" (walls %s, roof %s, window frames %s, door %s); windows: %d (ground %d, upper %d); shingle roof (%s) + chimney",
				info.name, info.scheme, rgb(v.wall), rgb(v.roof), rgb(v.trim), rgb(v.door),
				info.windows, info.groundWindows, info.upperWindows, houseKit.ROOF_MATERIAL.Name))
			local line = string.format(
				"[WorldGenerator] %s door: hinged, opens %d° inward with ProximityPrompt (E: Open/Close Door); closed CanCollide=%s & blocks doorway=%s; open CanCollide=%s, rotated on hinge=%s, doorway clear=%s, swing clear of furniture/stairs=%s; re-closed=%s — %s",
				info.name, math.round(math.deg(houseKit.DOOR_OPEN_ANGLE)), tostring(d.closedCollide), tostring(d.closedBlocked),
				tostring(d.openCollide), tostring(d.rotated), tostring(d.openClear), tostring(d.swingClear), tostring(d.reclosed),
				d.ok and "door functional" or "DOOR CHECK FAILED")
			if d.ok then
				print(line)
			else
				warn(line)
			end

			-- Двоповерховий будинок: сходи на всю ширину прольоту, перила, меблі обох поверхів
			if info.stairs then
				local st = info.stairs
				local stairsLine = string.format(
					"[WorldGenerator] %s stairs: width %.1f studs = full stairwell width %.1f (room edge of the opening to the back wall), gap to wall %.1f — %s; railing on the open side: %d balusters + sloped handrail (steps %d-%d, CanCollide)",
					info.name, st.width, st.passage, st.wallGap, (math.abs(st.width - st.passage) < 0.01 and st.wallGap < 0.01) and "no gap" or "GAP REMAINS",
					st.balusters, st.fromStep, st.toStep)
				if math.abs(st.width - st.passage) < 0.01 and st.wallGap < 0.01 then
					print(stairsLine)
				else
					warn(stairsLine)
				end
			end
			if info.furniture then
				print(string.format("[WorldGenerator] %s furniture — ground floor: %s; upper floor: %s",
					info.name, table.concat(info.furniture.ground, ", "), table.concat(info.furniture.upper, ", ")))
				if #info.furnitureProblems == 0 then
					print(string.format("[WorldGenerator] %s furniture check: no overlaps with walls/windows/stairs/door, windows not covered, door swing and stair entry/exit clear", info.name))
				else
					for _, problem in ipairs(info.furnitureProblems) do
						warn(string.format("[WorldGenerator] %s furniture: %s", info.name, problem))
					end
				end
			end
		end
		print(string.format("[WorldGenerator] Town decor: %d lamps, %d benches, %d fountains",
			stats.town.lamps, stats.town.benches, stats.town.fountains))
		print(string.format("[WorldGenerator] Town vegetation: %d trees, %d bushes, %d flowerbeds, %d grass patches",
			stats.town.trees, stats.town.bushes, stats.town.flowerbeds, stats.town.grassPatches))
		print(string.format("[WorldGenerator] Wild vegetation: %d trees (of 20-25 requested), %d grass patches (of 25-35), %d bushes, %d flowerbeds, %d tall-grass clumps, %d rocks",
			stats.wild.trees, stats.wild.grassPatches, stats.wild.bushes, stats.wild.flowerbeds, stats.wild.grass, stats.wild.rocks))

		-- Скільки дерев створено з кожного шаблону
		local templateCounts = {}
		for _, template in ipairs(treeTemplates) do
			table.insert(templateCounts, string.format("%s = %d", template.Name, stats.treesByTemplate[template.Name] or 0))
		end
		print(string.format("[WorldGenerator] Trees from templates: %d total (%s)",
			stats.town.trees + stats.wild.trees, (#templateCounts > 0) and table.concat(templateCounts, ", ") or "no templates found"))
		-- Зарості: розмір кожної, частка ігрової площі WildArea (газон дикої зони до підніжжя гір) і відступи
		-- ≥ ENCOUNTER_ZONE_CLEARANCE від дерев, вулиць і галявини, будинків, гір і SafeZoneBoundary.
		-- Окрема функція: її змінні не займають регістри функції Generate.
		local function reportEncounterZones()
			local function rectGap(a, b)
				local dx = math.max(a.minX - b.maxX, b.minX - a.maxX, 0)
				local dz = math.max(a.minZ - b.maxZ, b.minZ - a.maxZ, 0)
				return math.sqrt(dx * dx + dz * dz)
			end
			local function partRect(part)
				local cf, s = part.CFrame, part.Size
				local hx = (math.abs(cf.RightVector.X) * s.X + math.abs(cf.UpVector.X) * s.Y + math.abs(cf.LookVector.X) * s.Z) / 2
				local hz = (math.abs(cf.RightVector.Z) * s.X + math.abs(cf.UpVector.Z) * s.Y + math.abs(cf.LookVector.Z) * s.Z) / 2
				return { minX = cf.Position.X - hx, maxX = cf.Position.X + hx, minZ = cf.Position.Z - hz, maxZ = cf.Position.Z + hz }
			end

			-- Перешкоди: { name, rect } — стовбури дерев (радіус 2, як при розміщенні), вулиці, галявина,
			-- подвір'я з будинками, гори, сегменти SafeZoneBoundary
			local obstacles = {}
			for _, d in ipairs(world:GetDescendants()) do
				if d:IsA("Model") and d:GetAttribute("Template") then
					local p = d:GetPivot().Position
					table.insert(obstacles, { name = d:GetFullName(), rect = { minX = p.X - 2, maxX = p.X + 2, minZ = p.Z - 2, maxZ = p.Z + 2 } })
				end
			end
			for _, seg in ipairs(streetSegments) do
				local h = STREET_WIDTH / 2
				table.insert(obstacles, { name = "street", rect = {
					minX = math.min(seg.x1, seg.x2) - h, maxX = math.max(seg.x1, seg.x2) + h,
					minZ = math.min(seg.z1, seg.z2) - h, maxZ = math.max(seg.z1, seg.z2) + h,
				} })
			end
			table.insert(obstacles, { name = "EncounterClearing", rect = {
				minX = WILD_CENTER.X - clearingHalf, maxX = WILD_CENTER.X + clearingHalf,
				minZ = WILD_CENTER.Z - clearingHalf, maxZ = WILD_CENTER.Z + clearingHalf,
			} })
			for _, yard in ipairs(yards:GetChildren()) do
				table.insert(obstacles, { name = yard.Name, rect = (modelRect(yard)) })
			end
			for _, clone in ipairs(mountainClones) do
				table.insert(obstacles, { name = clone.Name, rect = (modelRect(clone)) })
			end
			for _, part in ipairs(frontWall:GetChildren()) do
				if part:IsA("BasePart") then
					table.insert(obstacles, { name = "SafeZoneBoundary." .. part.Name, rect = partRect(part) })
				end
			end
			-- Дрібні розміщені об'єкти (ліхтарі, лавочки, кущі, клумби, клапті трави, камені) — колом радіуса o.radius
			for _, o in ipairs(placed) do
				table.insert(obstacles, { name = string.format("object at (%.0f, %.0f)", o.pos.X, o.pos.Y), rect = {
					minX = o.pos.X - o.radius, maxX = o.pos.X + o.radius, minZ = o.pos.Y - o.radius, maxZ = o.pos.Y + o.radius,
				} })
			end

			-- Найближча перешкода до ділянки й попередження про кожну ближчу за ENCOUNTER_ZONE_CLEARANCE
			local function checkClearance(zone)
				local nearest, nearestName, bad = math.huge, "-", 0
				for _, o in ipairs(obstacles) do
					local gap = rectGap(zone, o.rect)
					if gap < nearest then
						nearest, nearestName = gap, o.name
					end
					if gap < ENCOUNTER_ZONE_CLEARANCE then
						bad += 1
						warn(string.format("[WorldGenerator] %s is only %.1f studs from %s (need %d)",
							zone.name, gap, o.name, ENCOUNTER_ZONE_CLEARANCE))
					end
				end
				return nearest, nearestName, bad
			end

			local playArea = (WILD_SIZE - BOUNDARY_INNER_STRIP) * (WILD_SIZE - 2 * BOUNDARY_INNER_STRIP)
			local totalArea, violations = 0, 0
			for _, zone in ipairs(stats.wild.zones) do
				totalArea += zone.area
				local nearest, nearestName, bad = checkClearance(zone)
				violations += bad
				print(string.format(
					"[WorldGenerator]   %s: %.0fx%.0f studs, %.0f studs² of tall grass (organic edge), center (%.0f, %.0f); nearest obstacle %.1f studs (%s)",
					zone.name, zone.size.X, zone.size.Y, zone.area, (zone.minX + zone.maxX) / 2, (zone.minZ + zone.maxZ) / 2,
					nearest, nearestName))
			end
			print(string.format(
				"[WorldGenerator] Encounter zones: %d large tall-grass areas, %.0f studs² total = %.0f%% of the WildArea play area (%.0f studs²); clearance >= %d studs violations: %d (expected 0); extra wild paths: none (Street1 leads to the clearing)",
				#stats.wild.zones, totalArea, totalArea / playArea * 100, playArea, ENCOUNTER_ZONE_CLEARANCE, violations))

			-- Декоративні зарості високої трави в містечку (не зони зустрічей)
			local townViolations, locations = 0, {}
			for _, zone in ipairs(stats.town.tallGrass or {}) do
				local nearest, nearestName, bad = checkClearance(zone)
				townViolations += bad
				table.insert(locations, zone.label)
				print(string.format(
					"[WorldGenerator]   %s (%s): %.0fx%.0f studs, %.0f studs² of tall grass, center (%.0f, %.0f); nearest obstacle %.1f studs (%s)",
					zone.name, zone.label, zone.size.X, zone.size.Y, zone.area, (zone.minX + zone.maxX) / 2, (zone.minZ + zone.maxZ) / 2,
					nearest, nearestName))
			end
			print(string.format(
				"[WorldGenerator] Town tall grass (decor, not encounter zones): %d patches — %s; clearance >= %d studs violations: %d (expected 0)",
				#(stats.town.tallGrass or {}), table.concat(locations, ", "), ENCOUNTER_ZONE_CLEARANCE, townViolations))
		end
		reportEncounterZones()

		-- WorldFloor: розмір і чи повністю покриває обидві зони
		local coverage = floorCoverageMargin()
		print(string.format(
			"[WorldGenerator] WorldFloor: frame of 6 sections around the lawns (town colour west of x = %.0f, wild colour east of it — same seam as the zones' lawns), covering radius %.1f around (%.1f, %.1f), top Y = %.1f; zones X %.0f..%.0f, Z %.0f..%.0f; min margin beyond zones = %.1f studs",
			floorSeamX, floorRadius, safeCenter.X, safeCenter.Y, floorTop,
			worldRect.minX, worldRect.maxX, worldRect.minZ, worldRect.maxZ, coverage))
		if coverage < WORLD_FLOOR_MARGIN then
			warn(string.format("[WorldGenerator] WorldFloor is too small: only %.1f studs beyond the zones (need %d) — some area may be uncovered",
				coverage, WORLD_FLOOR_MARGIN))
		end
		local levelsLine, levelsFlat = checkFloorLevels()
		if levelsFlat then
			print(levelsLine)
		else
			warn(levelsLine)
		end

		-- Радіуси кола: far point (mountain-based), near point (найближча до центру точка гір), zone-based
		print(string.format(
			"[WorldGenerator] Circle radii: mountain far point = %.1f (+%d -> %.1f), mountain near point = %.1f, zone-based = %.1f",
			mountainFarthest, SAFE_ZONE_MOUNTAIN_MARGIN, mountainRadius, (#mountainClones > 0) and mountainNearest or 0,
			zoneRadius))

		-- SafeZoneBoundary (у тілі гір): замкненість і чи проходить стіна крізь кожну гору
		local frontGaps = countFrontWallGaps()
		local frontClosed = frontGaps == 0
		print(string.format(
			"[WorldGenerator] SafeZoneBoundary (inside mountains): %d individual wall segments for %d GrassMountains (each rotated with its mountain) + %d joints; offset +%.1f studs INTO each mountain from its front face, thickness %d, Y %d..%d; closed = %s",
			#mountainClones, #mountainClones, frontWallJoints, MOUNTAIN_WALL_DEPTH, MOUNTAIN_WALL_THICKNESS,
			SAFE_ZONE_BOTTOM, SAFE_ZONE_TOP, tostring(frontClosed)))
		local mountainsMisplaced = 0
		if #mountainClones > 0 then
			local minOffset, maxOffset
			mountainsMisplaced, minOffset, maxOffset = checkWallThroughMountains()
			print(string.format(
				"[WorldGenerator] SafeZoneBoundary offset check: +%.1f inside the mountain body for %d of %d segments; reduced for %d (mountain too thin, %.0f%% of its thickness); outside the body: %d (expected 0); offsets used: +%.1f..+%.1f",
				MOUNTAIN_WALL_DEPTH, #mountainClones - reducedWallSegments, #mountainClones, reducedWallSegments,
				MOUNTAIN_WALL_FALLBACK * 100, mountainsMisplaced, minOffset, maxOffset))
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

	-- Позначка "запеченого" світу: серверний скрипт тоді не перебудовує його під час гри
	if markAsBaked then
		world:SetAttribute("Baked", true)
	end

	printReport()
	return world
end

return WorldGeneratorModule
