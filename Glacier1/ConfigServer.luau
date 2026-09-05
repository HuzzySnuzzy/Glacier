-- child of glacier1
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local SyncConfig = Instance.new("RemoteEvent",ReplicatedStorage)
SyncConfig.Name = 'SyncConfig'

-- Send all replicated vars to a player when they join
game.Players.PlayerAdded:Connect(function(player)
	for key, flag in pairs(Config.Flags) do
		if flag == Config.FCVAR.REPLICATED or flag == Config.FCVAR.CHEAT then
			SyncConfig:FireClient(player, key, Config.Get(key))
		end
	end
end)

-- Whenever the server calls Config.Set(), automatically broadcast it
Config.OnServerVarChanged = function(key, value)
	local flag = Config.Flags[key]
	if flag == Config.FCVAR.REPLICATED or flag == Config.FCVAR.CHEAT then
		SyncConfig:FireAllClients(key, value)
	end
end

-- Example usage: The server changes sv_cheats at runtime
-- Config.Set("sv_cheats", true)
local FCVAR = Config.FCVAR
local SYNCED = FCVAR.REPLICATED + FCVAR.CHEAT

local function shouldSync(flag)
	return bit32.band(flag or 0, SYNCED) ~= 0
end

game.Players.PlayerAdded:Connect(function(player)
	for key, flag in pairs(Config.Flags) do
		if shouldSync(flag) then
			SyncConfig:FireClient(player, key, Config.Get(key))
		end
	end
end)

Config.OnServerVarChanged = function(key, value)
	if shouldSync(Config.Flags[key]) then
		SyncConfig:FireAllClients(key, value)
	end
end