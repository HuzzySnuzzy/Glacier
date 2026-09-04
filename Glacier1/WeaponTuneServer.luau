-- Script: WeaponTuneServer
-- Parent: Glacier1
--
-- The other half of the weapon editor. A weapon module's table is cached per
-- VM, so an edit made on a client changes that client's copy and nothing else
-- -- the server would still validate hits against the shipped numbers, and
-- every other player would see the old weapon. Edits therefore go through
-- here: applied to the server's copy, then broadcast so every client applies
-- the same one.
--
-- ADMIN AND CHEAT GATED. This rewrites weapon damage for everybody on the
-- server; it is a tuning tool for a developer in a test session, not something
-- to leave open. Requests from a non-admin are dropped, and sv_cheats must be
-- on -- the same bar the rest of the loadout commands sit behind.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config       = require(ReplicatedStorage:WaitForChild("Config"))
local Glacier      = require(ReplicatedStorage:WaitForChild("Glacier"))
local WeaponTuning = require(ReplicatedStorage:WaitForChild("WeaponTuning"))

local function ensureRemote(name)
	local remote = ReplicatedStorage:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = ReplicatedStorage
	end
	return remote
end

-- Client -> server: "set this field". Server -> client: "apply this field".
-- One remote, two directions, because the payload is identical in both.
local WeaponTune = ensureRemote("WeaponTune")

--=====================================================================
-- ADMIN
--=====================================================================
-- Glacier1's console handler owns the admin list, and it is not exported. The
-- console path is already gated there, so an edit typed as a command is
-- covered; this remote is the one that needs its own check, and it uses the
-- same rule the console does: an admin, with cheats on.
local Registry = require(script.Parent:WaitForChild("Registry"))

local function isAdmin(plr)
	-- Glacier1 publishes the same rule its console handler uses, so a person
	-- who can type wedit_set can also use the panel. Without it the two would
	-- disagree and the panel would refuse edits the console accepted.
	if type(Registry.IsAdmin) == "function" then return Registry.IsAdmin(plr) end

	-- Glacier1 has not run yet, or is an older copy. Studio only: a solo test
	-- session is the whole audience there, and a live server gets nothing
	-- rather than an open door.
	return game:GetService("RunService"):IsStudio()
end

local function allowed(plr)
	if not Config.Get("sv_cheats") then return false, "sv_cheats must be 1" end
	if not isAdmin(plr) then return false, "not an admin" end
	return true
end

--=====================================================================
-- APPLY
--=====================================================================

-- Returns ok, reason. Applies here and pushes to every client, including the
-- one that asked -- it applied nothing locally, so this is what makes its own
-- edit take effect and keeps every VM agreeing on one value.
local function apply(class, path, value)
	local ok, result = WeaponTuning.Set(class, path, value)
	if not ok then return false, result end

	WeaponTune:FireAllClients("set", class, path, result)
	return true, result
end

local function resetField(class, path)
	local ok, result = WeaponTuning.Reset(class, path)
	if not ok then return false, result end

	WeaponTune:FireAllClients("set", class, path, result)
	return true, result
end

WeaponTune.OnServerEvent:Connect(function(plr, action, class, path, value)
	local can, why = allowed(plr)
	if not can then
		Glacier.Tell(plr, ("[wedit] %s"):format(why), true)
		return
	end

	if action == "set" then
		local ok, result = apply(class, path, value)
		Glacier.Tell(plr, ok
			and ("[wedit] %s.%s = %s"):format(tostring(class), tostring(path), tostring(result))
			or ("[wedit] %s"):format(tostring(result)), not ok)

	elseif action == "reset" then
		local ok, result = resetField(class, path)
		Glacier.Tell(plr, ok
			and ("[wedit] %s.%s restored to %s"):format(tostring(class), tostring(path), tostring(result))
			or ("[wedit] %s"):format(tostring(result)), not ok)

	elseif action == "resetall" then
		-- Reset each field individually rather than calling ResetAll, so every
		-- client is told about every field -- ResetAll only fixes this VM.
		for _, field in ipairs(WeaponTuning.Fields(class)) do
			if WeaponTuning.IsChanged(class, field) then resetField(class, field) end
		end
		Glacier.Tell(plr, ("[wedit] %s restored"):format(tostring(class)))
	end
end)

-- A player who joins after an edit has the shipped numbers. Replayed on spawn
-- rather than on join: the client's weapon modules may not be required yet
-- when PlayerAdded fires, and applying to a table nothing has loaded does
-- nothing at all.
Players.PlayerAdded:Connect(function(plr)
	task.delay(4, function()
		if not plr.Parent then return end
		for _, class in ipairs(WeaponTuning.ChangedClasses()) do
			for _, path in ipairs(WeaponTuning.Fields(class)) do
				if WeaponTuning.IsChanged(class, path) then
					WeaponTune:FireClient(plr, "set", class, path, WeaponTuning.Get(class, path))
				end
			end
		end
	end)
end)

--=====================================================================
-- COMMANDS
--=====================================================================
-- The panel is the comfortable way in; these are the same thing without a UI,
-- and they are what a bind or an alias can reach.

local FLAG = Config.FCVAR.REPLICATED + Config.FCVAR.CHEAT

local function reply(ctx, text)
	if ctx and type(ctx.reply) == "function" then ctx.reply(text) else print(text) end
end

local function heldClass(ctx, given)
	if given and given ~= "" then return given end
	local plr = ctx and ctx.player
	local class = plr and Glacier.HeldClass(plr)
	return class
end

Config.Command("wedit_set", {
	args = { "string", "string", "string?" },
	flag = FLAG,
	help = "set a field on a weapon: wedit_set damage 42 [class]",
	run = function(ctx, path, value, class)
		class = heldClass(ctx, class)
		if not class then return false, "not holding a weapon, and no class given" end

		local ok, result = apply(class, path, value)
		if not ok then return false, result end

		reply(ctx, ("[wedit] %s.%s = %s"):format(class, path, tostring(result)))
		return true
	end,
})

Config.Command("wedit_reset", {
	args = { "string?", "string?" },
	flag = FLAG,
	help = "restore one field, or the whole weapon when no field is given",
	run = function(ctx, path, class)
		class = heldClass(ctx, class)
		if not class then return false, "not holding a weapon, and no class given" end

		if not path then
			local n = 0
			for _, field in ipairs(WeaponTuning.Fields(class)) do
				if WeaponTuning.IsChanged(class, field) and resetField(class, field) then n += 1 end
			end
			reply(ctx, ("[wedit] %s: restored %d field%s"):format(class, n, n == 1 and "" or "s"))
			return true
		end

		local ok, result = resetField(class, path)
		if not ok then return false, result end
		reply(ctx, ("[wedit] %s.%s restored to %s"):format(class, path, tostring(result)))
		return true
	end,
})

Config.Command("wedit_export", {
	args = { "string?" },
	flag = Config.FCVAR.REPLICATED,
	help = "print the changed fields as Lua, ready to paste into the module",
	run = function(ctx, class)
		local classes = class and { class } or WeaponTuning.ChangedClasses()
		if #classes == 0 then return false, "nothing has been changed" end

		local out = {}
		for _, name in ipairs(classes) do
			local text = WeaponTuning.Export(name)
			if text then table.insert(out, text) end
		end

		if #out == 0 then return false, "nothing has been changed" end
		reply(ctx, table.concat(out, "\n\n"))
		return true
	end,
})
