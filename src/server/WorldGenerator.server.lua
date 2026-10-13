--[[
	WorldGenerator
	Запускає генерацію світу під час гри (Play / сервер). Уся логіка — у ReplicatedStorage.Shared.WorldGeneratorModule.
	Якщо Workspace.WivialsWorld уже "запечений" (атрибут Baked = true — світ згенеровано в режимі редагування
	через Command Bar і збережено в місці), світ не перебудовується: лише підключається поведінка дверей,
	бо з'єднання подій не зберігаються разом із місцем. Інакше — світ генерується заново, як і раніше.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldGeneratorModule = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WorldGeneratorModule"))

local existing = Workspace:FindFirstChild("WivialsWorld")
if existing and existing:GetAttribute("Baked") == true then
	local active, broken = WorldGeneratorModule.ActivateDoors(existing)
	print(string.format("[WorldGenerator] WivialsWorld is baked — skipping generation; doors activated: %d%s",
		active, broken > 0 and string.format(" (%d incomplete)", broken) or ""))
	return
end

WorldGeneratorModule.Generate()
