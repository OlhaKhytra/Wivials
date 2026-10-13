--[[
	DayNightCycle
	Цикл дня й ночі: Lighting.ClockTime плавно йде від 0 до 24 за DAY_LENGTH_SECONDS і зациклюється.
	Чотири фази — Ніч, Світанок, День, Захід — кожна зі своїм небом із наявних пресетів:
	  Sky_Day (на старті лежить у Lighting), Sky_Night і Sky_Sunset (у Workspace.SkyPresets).
	У Lighting одночасно лише одне небо: при зміні фази попереднє повертається на своє місце,
	а потрібне переїжджає в Lighting. Нові Sky не створюються — лише переміщуються наявні.
	Brightness, Ambient і OutdoorAmbient інтерполюються лінійно за ClockTime між ключовими точками,
	тож освітлення змінюється плавно, а не стрибком у момент зміни неба.
	Скрипт керує освітленням щокадру й перекриває стартові значення з WorldGenerator (розділ 10).
	Вуличні ліхтарі (тег StreetLamp, ставить WorldGenerator) світять у фазах Захід, Ніч і Світанок,
	удень вимкнені.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Workspace = game:GetService("Workspace")

-- Тривалість повної доби в секундах (3600 = година реального часу; для швидких тестів — 60)
local DAY_LENGTH_SECONDS = 3600

-- Фази за ClockTime: [from, to). День — половина доби (12 год), Захід і Світанок — по 2 год, Ніч — 8 год
-- (займає і кінець доби, і її початок). lamps — чи світять вуличні ліхтарі в цій фазі.
local PHASES = {
	{ name = "Night", from = 0, to = 5, sky = "Sky_Night", lamps = true },
	{ name = "Dawn", from = 5, to = 7, sky = "Sky_Sunset", lamps = true },
	{ name = "Day", from = 7, to = 19, sky = "Sky_Day", lamps = false },
	{ name = "Sunset", from = 19, to = 21, sky = "Sky_Sunset", lamps = true },
	{ name = "Night", from = 21, to = 24, sky = "Sky_Night", lamps = true },
}

-- Ключові точки освітлення (за ClockTime, по зростанню; між ними — лінійна інтерполяція)
-- Ніч: на ~35% яскравіша за початкові 0.6 — видніше, але все ще ніч (кольори ті самі темно-сині)
local NIGHT = { brightness = 0.8, ambient = Color3.fromRGB(40, 50, 95), outdoor = Color3.fromRGB(50, 65, 120) }
local DAWN = { brightness = 1.5, ambient = Color3.fromRGB(170, 125, 105), outdoor = Color3.fromRGB(225, 155, 115) }
local DAY = { brightness = 2.6, ambient = Color3.fromRGB(150, 150, 150), outdoor = Color3.fromRGB(190, 190, 185) }
local SUNSET = { brightness = 1.3, ambient = Color3.fromRGB(180, 100, 70), outdoor = Color3.fromRGB(235, 120, 80) }
local KEYFRAMES = {
	{ time = 0, values = NIGHT },
	{ time = 5, values = NIGHT }, -- до 5:00 — глибока ніч
	{ time = 6, values = DAWN }, -- пік теплих тонів світанку
	{ time = 7, values = DAY },
	{ time = 19, values = DAY },
	{ time = 20, values = SUNSET }, -- пік заходу
	{ time = 21, values = NIGHT },
	{ time = 24, values = NIGHT },
}

---------------------------------------------------------------------
-- Пресети неба
---------------------------------------------------------------------
local skyPresets = Workspace:WaitForChild("SkyPresets", 10)
if not skyPresets then
	warn("[DayNightCycle] Workspace.SkyPresets not found — Sky_Night and Sky_Sunset are unavailable")
end

-- Пресет може бути самим Sky або моделлю/папкою з Sky всередині. Lighting бере небо лише з прямого
-- дочірнього Sky, тож переміщується саме Sky-об'єкт, а "дім" — місце, куди він повертається, коли неактивний:
-- його модель, або Workspace.SkyPresets, якщо пресет — це сам Sky (зокрема Sky_Day, що стартує в Lighting).
local skies = {} -- назва пресета → { sky = Sky, home = Instance }

local function registerSky(name, container)
	local preset = container and container:FindFirstChild(name)
	if not preset then
		return false
	end
	local sky = preset:IsA("Sky") and preset or preset:FindFirstChildWhichIsA("Sky", true)
	if not sky then
		warn(string.format("[DayNightCycle] %s found in %s, but it contains no Sky object — it will be skipped", name, container:GetFullName()))
		return true
	end
	skies[name] = { sky = sky, home = (sky == preset) and skyPresets or sky.Parent }
	return true
end

for _, name in ipairs({ "Sky_Day", "Sky_Night", "Sky_Sunset" }) do
	-- Sky_Day очікується в Lighting, але може вже лежати й у SkyPresets (наприклад, після перезапуску)
	local found = registerSky(name, Lighting) or registerSky(name, skyPresets)
	if not found then
		warn(string.format("[DayNightCycle] Sky preset %s not found (expected in %s) — phases that use it will keep the previous sky",
			name, name == "Sky_Day" and "Lighting" or "Workspace.SkyPresets"))
	end
end

-- Сторонні Sky у Lighting (не наші пресети) змішувалися б із нашими — лише попереджаємо, не чіпаємо
for _, child in ipairs(Lighting:GetChildren()) do
	if child:IsA("Sky") then
		local ours = false
		for _, entry in pairs(skies) do
			ours = ours or entry.sky == child
		end
		if not ours then
			warn(string.format("[DayNightCycle] Lighting contains an extra Sky (%s) that is not one of the presets — it may override the cycle", child.Name))
		end
	end
end

local activeSkyName = nil -- пресет, що зараз у Lighting
for name, entry in pairs(skies) do
	if entry.sky.Parent == Lighting then
		activeSkyName = name
	end
end

-- Робить активним небо name: попереднє повертається додому, потрібне переїжджає в Lighting.
-- Якщо пресета немає — лишає поточне небо й повертає false.
local function setActiveSky(name)
	local target = skies[name]
	if not target then
		return false
	end
	if activeSkyName == name and target.sky.Parent == Lighting then
		return true
	end
	-- Прибираємо з Lighting усі наші пресети, крім потрібного (на випадок, якщо їх там опинилося кілька)
	for otherName, entry in pairs(skies) do
		if otherName ~= name and entry.sky.Parent == Lighting then
			if entry.home then
				entry.sky.Parent = entry.home
			else
				warn(string.format("[DayNightCycle] Nowhere to store %s (Workspace.SkyPresets is missing) — it stays in Lighting", otherName))
			end
		end
	end
	target.sky.Parent = Lighting
	activeSkyName = name
	return true
end

---------------------------------------------------------------------
-- Вуличні ліхтарі
---------------------------------------------------------------------
-- Лампа (тег StreetLamp) — неонова куля з PointLight усередині. Вимкнена: звичайний матеріал замість
-- неону (не світиться) і вимкнений PointLight. Ліхтарі, створені пізніше (WorldGenerator може запуститися
-- після цього скрипта), одразу отримують поточний стан.
local LAMP_TAG = "StreetLamp"
local lampsOn = nil

local function applyLamp(bulb)
	if not bulb:IsA("BasePart") then
		return
	end
	bulb.Material = lampsOn and Enum.Material.Neon or Enum.Material.SmoothPlastic
	for _, light in ipairs(bulb:GetDescendants()) do
		if light:IsA("Light") then
			light.Enabled = lampsOn
		end
	end
end

local function setLamps(on)
	lampsOn = on
	local lamps = CollectionService:GetTagged(LAMP_TAG)
	for _, bulb in ipairs(lamps) do
		applyLamp(bulb)
	end
	return #lamps
end

CollectionService:GetInstanceAddedSignal(LAMP_TAG):Connect(function(bulb)
	if lampsOn ~= nil then
		applyLamp(bulb)
	end
end)

---------------------------------------------------------------------
-- Освітлення й фази
---------------------------------------------------------------------
local function lightingAt(clock)
	for i = 1, #KEYFRAMES - 1 do
		local a, b = KEYFRAMES[i], KEYFRAMES[i + 1]
		if clock >= a.time and clock <= b.time then
			local alpha = (b.time > a.time) and (clock - a.time) / (b.time - a.time) or 0
			return a.values.brightness + (b.values.brightness - a.values.brightness) * alpha,
				a.values.ambient:Lerp(b.values.ambient, alpha),
				a.values.outdoor:Lerp(b.values.outdoor, alpha)
		end
	end
	return NIGHT.brightness, NIGHT.ambient, NIGHT.outdoor
end

local function phaseAt(clock)
	for _, phase in ipairs(PHASES) do
		if clock >= phase.from and clock < phase.to then
			return phase
		end
	end
	return PHASES[1]
end

local currentPhaseName = nil

local function applyPhase(phase)
	-- Ніч у кінці й на початку доби — одна фаза: при переході 24 → 0 нічого не перемикається
	if phase.name == currentPhaseName then
		return
	end
	currentPhaseName = phase.name
	local lampCount = setLamps(phase.lamps)
	local lampText = string.format("street lamps %s (%d)", phase.lamps and "ON" or "OFF", lampCount)
	if setActiveSky(phase.sky) then
		print(string.format("[DayNightCycle] Phase: %s (sky: %s); %s", phase.name, phase.sky, lampText))
	else
		print(string.format("[DayNightCycle] Phase: %s (sky: %s missing — keeping %s); %s",
			phase.name, phase.sky, activeSkyName or "none", lampText))
	end
end

local clock = Lighting.ClockTime % 24
local function update(dt)
	clock = (clock + dt * 24 / DAY_LENGTH_SECONDS) % 24
	Lighting.ClockTime = clock
	local brightness, ambient, outdoor = lightingAt(clock)
	Lighting.Brightness = brightness
	Lighting.Ambient = ambient
	Lighting.OutdoorAmbient = outdoor
	applyPhase(phaseAt(clock))
end

update(0)
RunService.Heartbeat:Connect(update)
