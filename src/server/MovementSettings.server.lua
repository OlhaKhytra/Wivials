--[[
	MovementSettings
	Знижує висоту стрибка персонажа (~на 33% від стандарту Roblox) при кожному спавні.
	Навіщо: межу світу тримає невидима стіна SafeZoneBoundary впритул перед горами GrassMountain
	(Y від -10 до 90) плюс запасне кільце за горами; знижений стрибок — додатковий запас, щоб гравець
	не використовував дрібні об'єкти біля стіни як сходинки.
]]

local Players = game:GetService("Players")

-- Стандарт Roblox: JumpHeight = 7.2 / JumpPower = 50
local JUMP_HEIGHT = 4.8
local JUMP_POWER = 33

local function applyMovement(character)
	local humanoid = character:WaitForChild("Humanoid")
	-- Активна лише одна з властивостей, залежно від UseJumpPower (налаштування StarterPlayer)
	if humanoid.UseJumpPower then
		humanoid.JumpPower = JUMP_POWER
	else
		humanoid.JumpHeight = JUMP_HEIGHT
	end
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(applyMovement)
	if player.Character then
		applyMovement(player.Character)
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
-- Гравці, що зайшли до запуску скрипта (наприклад, у Studio Play Solo)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end
