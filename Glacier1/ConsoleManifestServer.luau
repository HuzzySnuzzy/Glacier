-- Script: ConsoleManifestServer
-- Parent: Glacier1
--
-- Publishes the server's command list to clients so their console can
-- autocomplete commands it has no local implementation of. Gamemodes register
-- and unregister commands at Start/Stop, so this re-pushes on every change.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local Remote = ReplicatedStorage:FindFirstChild("ConsoleManifest")
if not Remote then
	Remote = Instance.new("RemoteEvent")
	Remote.Name = "ConsoleManifest"
	Remote.Parent = ReplicatedStorage
end

local function manifest()
	local out = {}
	for name, spec in pairs(Config.Commands) do
		out[name] = {
			usage = Config.Usage(name),
			help  = spec.help,
			flag  = spec.flag,
		}
	end
	return out
end

local function push(plr)
	local m = manifest()
	if plr then
		Remote:FireClient(plr, m)
	else
		Remote:FireAllClients(m)
	end
end

-- Debounced: a gamemode switch registers several commands in a row, and each
-- one would otherwise fire its own broadcast.
local queued = false
Config.OnCommandsChanged(function()
	if queued then return end
	queued = true
	task.defer(function()
		queued = false
		push(nil)
	end)
end)

Players.PlayerAdded:Connect(function(plr)
	-- Deferred so the client's console has connected its listener.
	task.delay(2, function()
		if plr.Parent then push(plr) end
	end)
end)

task.defer(push)