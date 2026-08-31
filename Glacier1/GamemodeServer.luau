-- Script: GamemodeServer
-- Parent: Glacier1
--
-- Owns which gamemode is running. Gamemodes are ModuleScripts under
-- Glacier1.Gamemode returning { Name, Start, Stop }.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))

local folder = script.Parent:WaitForChild("Gamemode")

local current, currentName = nil, nil

local function list()
	local out = {}
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("ModuleScript") then table.insert(out, child.Name) end
	end
	table.sort(out)
	return out
end

local function stopCurrent()
	if not current then return end
	local ok, err = pcall(current.Stop)
	if not ok then warn("[Gamemode] Stop errored:", err) end
	print(("[Gamemode] stopped %s"):format(tostring(currentName)))
	current, currentName = nil, nil
end

local function start(name)
	local mod = folder:FindFirstChild(name)
	if not mod or not mod:IsA("ModuleScript") then
		return false, ("no gamemode '%s' (have: %s)"):format(name, table.concat(list(), ", "))
	end

	local ok, mode = pcall(require, mod)
	if not ok then return false, ("'%s' failed to load: %s"):format(name, tostring(mode)) end
	if type(mode) ~= "table" or type(mode.Start) ~= "function" or type(mode.Stop) ~= "function" then
		return false, ("'%s' must return a table with Start and Stop"):format(name)
	end

	-- Stop AFTER the new one validates, so a typo doesn't leave you with
	-- nothing running and every player unloaded.
	stopCurrent()

	local started, err = pcall(mode.Start)
	if not started then
		warn("[Gamemode] Start errored:", err)
		pcall(mode.Stop)   -- best effort; a half-started mode is worse than none
		return false, tostring(err)
	end

	current, currentName = mode, name
	Config.Set("mp_gamemode", name)
	print(("[Gamemode] started %s (%s)"):format(name, tostring(mode.Name)))
	return true
end

--=====================================================================
-- COMMANDS
--=====================================================================

Config.Command("gamemode", {
	args = { "string" },
	flag = Config.FCVAR.CHEAT,
	help = "switch gamemode; unloads everyone and restarts the match",
	run = function(ctx, name)
		return start(name)
	end,
})

Config.Command("gamemode_list", {
	args = {},
	flag = Config.FCVAR.CLIENT,
	help = "show available gamemodes",
	run = function()
		print(("[Gamemode] available: %s\n[Gamemode] running: %s")
			:format(table.concat(list(), ", "), tostring(currentName)))
		return true
	end,
})

Config.Command("gamemode_restart", {
	args = {},
	flag = Config.FCVAR.CHEAT,
	help = "restart the current gamemode from scratch",
	run = function()
		if not currentName then return false, "nothing running" end
		return start(currentName)
	end,
})

--=====================================================================
-- Read by ServerDebugServer.
local Registry = require(script.Parent:WaitForChild("Registry"))

task.spawn(function()
	local deadline = os.clock() + 10
	while not Registry.Lifecycle do
		if os.clock() > deadline then
			warn("[Gamemode] Registry.Lifecycle never appeared -- PlayerLifecycleServer erroring?")
			return
		end
		task.wait()
	end

	local ok, reason = start(Config.Values.mp_gamemode)
	if not ok then warn("[Gamemode] boot failed: " .. tostring(reason)) end
end)


Registry.Gamemode = function()
	if not current then return nil end
	local ok, status = pcall(function()
		return current.Status and current.Status() or nil
	end)
	return {
		name = currentName,
		label = current.Name,
		status = ok and status or nil,
	}
end