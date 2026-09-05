-- Script: MapServer
-- Place under ServerScriptService > Glacier1
--
-- Maps live in ReplicatedStorage.Maps and are CLONED into workspace, never
-- reparented -- a reparent empties the folder and makes the second loadmap
-- of the same name fail. The live copy carries a CollectionService tag so
-- clearmap can find it without caring how the map is structured internally.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players           = game:GetService("Players")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
-- Only used by the respawn-on-map-change pass at the bottom. Resolving the
-- lifecycle is deferred inside Glacier, so requiring it here does not depend
-- on PlayerLifecycleServer having started yet.
local Glacier = require(ReplicatedStorage:WaitForChild("Glacier"))
local MapsFolder = ReplicatedStorage:WaitForChild("Maps")

local MAP_TAG = "GlacierMap"

-- Fired AFTER the map is parented / destroyed, with the live model (or nil).
-- HullGenerator, spawn-point collection and the gamemode should listen here
-- rather than polling workspace. A load fires exactly ONCE, with the new
-- model -- it does not fire nil first.
local MapChanged = ReplicatedStorage:FindFirstChild("MapChanged")
if not MapChanged then
	MapChanged = Instance.new("BindableEvent")
	MapChanged.Name = "MapChanged"
	MapChanged.Parent = ReplicatedStorage
end

local Map = {}

--=====================================================================
-- Console output
--=====================================================================
-- ctx.reply is injected by Glacier1's ConsoleEvent handler and routes to the
-- ConsoleLog remote for whoever typed the line. Commands invoked from a server
-- script (ConfigExec, the boot path) have no ctx.player, so those fall through
-- to print. Without this, every command that produces a LIST silently writes
-- to the server log and the player sees nothing.

local function reply(ctx, text, isError)
	if ctx and type(ctx.reply) == "function" then
		ctx.reply(text, isError)
	elseif isError then
		warn(text)
	else
		print(text)
	end
end

--=====================================================================
-- Resolution
--=====================================================================
-- Console input is typed by hand; folder children are authored mixed-case
-- ("Mirage", "de_dust2"). Exact match wins, then case-insensitive, then a
-- unique prefix -- ambiguity is an error, same rule as the player parser.

-- A map is a Model or a Folder. Anything else in there (a ModuleScript of map
-- metadata, a Configuration) is not a loadable map and must not appear in the
-- listing or be matched by resolve().
local function isMapTemplate(inst)
	return inst:IsA("Model") or inst:IsA("Folder")
end

local function listTemplates()
	local out = {}
	for _, child in ipairs(MapsFolder:GetChildren()) do
		if isMapTemplate(child) then table.insert(out, child) end
	end
	table.sort(out, function(a, b) return a.Name < b.Name end)
	return out
end

local function resolve(name)
	if type(name) ~= "string" or name == "" then
		return nil, "expected a map name"
	end

	local exact = MapsFolder:FindFirstChild(name)
	if exact and isMapTemplate(exact) then return exact end

	local lower = string.lower(name)
	local partial = {}

	for _, child in ipairs(listTemplates()) do
		local childLower = string.lower(child.Name)
		if childLower == lower then return child end
		if string.find(childLower, lower, 1, true) then table.insert(partial, child) end
	end

	if #partial == 1 then return partial[1] end
	if #partial > 1 then
		local names = {}
		for _, m in ipairs(partial) do table.insert(names, m.Name) end
		return nil, ("'%s' is ambiguous: %s"):format(name, table.concat(names, ", "))
	end
	return nil, ("no map named '%s' in ReplicatedStorage.Maps"):format(name)
end

--=====================================================================
-- Load / clear
--=====================================================================

function Map.Current()
	for _, inst in ipairs(CollectionService:GetTagged(MAP_TAG)) do
		if inst:IsDescendantOf(workspace) then return inst end
	end
	return nil
end

-- notify=false is used by Load: firing MapChanged(nil) an instant before
-- MapChanged(model) makes every listener tear down and immediately rebuild,
-- which for HullGenerator means regenerating collision for a map that is
-- about to be destroyed anyway.
local function clear(notify)
	local removed = false
	for _, inst in ipairs(CollectionService:GetTagged(MAP_TAG)) do
		if inst:IsDescendantOf(workspace) then
			inst:Destroy()
			removed = true
		end
	end

	if Config.Get("mp_map") ~= "" then Config.Set("mp_map", "") end
	if notify ~= false then MapChanged:Fire(nil) end
	return removed
end

function Map.Clear()
	return clear(true)
end

function Map.Load(name)
	local template, reason = resolve(name)
	if not template then return false, reason end

	clear(false)

	local clone = template:Clone()
	CollectionService:AddTag(clone, MAP_TAG)
	clone.Parent = workspace

	-- Set the cvar BEFORE firing, so a MapChanged listener reading mp_map
	-- during its own handler sees the new value, not the old one.
	Config.Set("mp_map", template.Name)
	MapChanged:Fire(clone)
	return true, template.Name
end

--=====================================================================
-- BINDABLES
--=====================================================================
-- Server-to-server map control. Safe to leave in ReplicatedStorage:
-- BindableEvents never cross the network boundary, so a client firing this
-- only reaches client-side listeners (there are none).
--
--   ReplicatedStorage.SetMap:Fire("dust2")   -- load
--   ReplicatedStorage.SetMap:Fire(nil)       -- clear
--
-- Fire-and-forget by design. Listen on MapChanged if you need to know when it
-- actually landed, or call Config.Get("mp_map") after -- Fire is synchronous
-- on the firing thread, so the map is already parented when Fire returns.

local SetMap = Instance.new("BindableEvent")
SetMap.Name = "SetMap"
SetMap.Parent = ReplicatedStorage

SetMap.Event:Connect(function(name)
	if name == nil or name == "" then
		Map.Clear()
		return
	end

	if type(name) ~= "string" then
		warn("[MapServer] SetMap expects a string map name or nil")
		return
	end

	local ok, reason = Map.Load(name)
	if not ok then warn("[MapServer] SetMap: " .. tostring(reason)) end
end)

-- Invoke() -> model|nil, name. Lets a gamemode check a map is up before it
-- starts a round, without knowing the tag or reaching into workspace.
local GetMap = Instance.new("BindableFunction")
GetMap.Name = "GetMap"
GetMap.OnInvoke = function()
	local current = Map.Current()
	return current, current and current.Name or nil
end
GetMap.Parent = ReplicatedStorage

--=====================================================================
-- COMMANDS
--=====================================================================
-- REPLICATED flag: runCommand rejects these client-side unless ctx.admin,
-- so a client console has to forward the line to the server. Registering
-- here also fires notifyCommandsChanged(), which is what pushes the name
-- into the ConsoleManifest clients pull for autocomplete.

Config.Command("loadmap", {
	args = { "string" },
	flag = Config.FCVAR.REPLICATED,
	help = "clone a map from ReplicatedStorage.Maps into workspace",
	run = function(ctx, name)
		local ok, result = Map.Load(name)
		if not ok then return false, result end
		reply(ctx, ("[Maps] loaded %s"):format(result))
		return true
	end,
})

Config.Command("clearmap", {
	args = {},
	flag = Config.FCVAR.REPLICATED,
	help = "destroy the currently loaded map",
	run = function(ctx)
		-- Anyone standing on the map falls; the gamemode should respawn or
		-- freeze players off the back of MapChanged(nil).
		if not Map.Clear() then return false, "no map is loaded" end
		reply(ctx, "[Maps] cleared")
		return true
	end,
})

Config.Command("maps", {
	args = {},
	flag = Config.FCVAR.REPLICATED,
	help = "list maps available in ReplicatedStorage.Maps",
	run = function(ctx)
		local templates = listTemplates()

		if #templates == 0 then
			reply(ctx, "[Maps] ReplicatedStorage.Maps is empty (no Models or Folders)", true)
			return true
		end

		local current = Config.Get("mp_map")
		local names = {}
		for _, t in ipairs(templates) do
			-- Mark the live one so it's obvious what clearmap would remove.
			table.insert(names, (t.Name == current) and ("* " .. t.Name) or t.Name)
		end

		reply(ctx, ("[Maps] %d available: %s"):format(#templates, table.concat(names, ", ")))
		return true
	end,
})

--=====================================================================
-- RESPAWN ON MAP CHANGE
--=====================================================================
-- Every live body is standing in geometry that has just been deleted, at
-- coordinates the new map has never heard of, and the spawn points they would
-- have used went with it. Doing nothing leaves players floating in the void
-- of the old map -- which is what happened before this existed.
--
-- HERE rather than in a gamemode, because it is true of every mode. A mode
-- with its own opinion (a round system that reloads the map as part of
-- starting a round and deploys everyone itself a moment later) sets
-- mp_respawn_on_mapchange 0, which is one line in one place instead of every
-- other mode having to remember to do this.
--
-- Deferred off the MapChanged thread. Respawn yields -- it tears down a body,
-- resolves a spawn point and fetches an avatar -- and yielding inside a
-- BindableEvent handler blocks every other listener behind it, including the
-- collision generator that is trying to build the map these players are about
-- to be placed on.
local function respawnEveryone(map)
	if not map then return end   -- a clear, not a load; nothing to spawn onto
	if Config.Get("mp_respawn_on_mapchange") == false then return end

	local reviveDead = Config.Get("mp_mapchange_revives_dead") == true

	for _, plr in ipairs(Players:GetPlayers()) do
		-- A player who was dead stays dead unless the cvar says otherwise: a
		-- map change is not a free life, and a mode with a respawn timer has
		-- its own idea of when they come back.
		if reviveDead or Glacier.IsAlive(plr) then
			task.spawn(function()
				local ok, reason = Glacier.Respawn(plr)
				if not ok then
					warn(("[MapServer] respawn after map change failed for %s: %s")
						:format(plr.Name, tostring(reason)))
				end
			end)
		end
	end
end

MapChanged.Event:Connect(respawnEveryone)

--=====================================================================
-- BOOT
--=====================================================================

local startMap = Config.Get("mp_startmap")
if startMap and startMap ~= "" then
	local ok, reason = Map.Load(startMap)
	if not ok then warn("[MapServer] " .. tostring(reason)) end
end