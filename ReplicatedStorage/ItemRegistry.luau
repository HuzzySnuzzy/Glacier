-- ModuleScript: ReplicatedStorage.ItemRegistry
-- Name -> definition resolution, in one place, for client and server alike.
--
-- This is the old WeaponRegistry with the word "weapon" taken out of it, and
-- that is the whole idea: a weapon is an item that happens to have a fire
-- rate. An apple, a torch and a pickaxe resolve through exactly the same
-- lookup, sit in the same inventory, and are authored as the same kind of
-- ModuleScript -- so nothing downstream needs a second code path for
-- "things that are not guns".
--
-- CANONICAL CLASS is the ModuleScript's own name. It is what inventory items
-- store, what the world model lookup uses, and what should be persisted --
-- never the lowercase `name`, which is only a display/netKey string.
--
-- SOURCES. Every ModuleScript under any registered source folder is an item,
-- and folders nest, so Items/Food/Apple is found without anything being told
-- about Food. ReplicatedStorage.Items and ReplicatedStorage.Weapons are
-- registered by default; AddSource takes any other folder, which is what a
-- plugin will hand it. Modules that appear later -- a live-authored file, a
-- pack that finished replicating, a plugin folder parented at runtime -- are
-- picked up by the ChildAdded watch rather than needing a restart.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemRegistry = {}

local statsByClass = {}   -- "AK47" -> definition table
local classByAlias = {}   -- "ak47" -> "AK47"
local sources = {}        -- [Instance] = true, so a folder is never watched twice
local built = false

local function ingest(mod)
	local ok, s = pcall(require, mod)
	if not (ok and type(s) == "table") then
		warn(("[ItemRegistry] '%s' failed to load: %s"):format(mod.Name, tostring(s)))
		return
	end

	statsByClass[mod.Name] = s
	classByAlias[mod.Name:lower()] = mod.Name

	if type(s.name) == "string" and s.name ~= "" then
		local alias = s.name:lower()
		local clash = classByAlias[alias]
		if clash and clash ~= mod.Name then
			warn(("[ItemRegistry] '%s' and '%s' both claim the name '%s'.")
				:format(clash, mod.Name, s.name))
		end
		classByAlias[alias] = mod.Name
	end
end

-- Declared before scan() so the two can recurse into each other: a source
-- folder holding a folder is itself a source.
local scan

-- Registers a folder of item modules. Safe to call twice with the same folder
-- -- a plugin that re-registers on reload must not end up with two ChildAdded
-- connections, or every later module would be ingested twice.
function ItemRegistry.AddSource(folder)
	if typeof(folder) ~= "Instance" then return false end
	if sources[folder] then return true end
	sources[folder] = true

	scan(folder)

	folder.ChildAdded:Connect(function(child)
		if child:IsA("ModuleScript") then
			ingest(child)
		elseif child:IsA("Folder") then
			ItemRegistry.AddSource(child)
		end
	end)

	return true
end

function scan(folder)
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("ModuleScript") then
			ingest(child)
		elseif child:IsA("Folder") then
			ItemRegistry.AddSource(child)
		end
	end
end

-- The default sources, added on first use rather than at require time: this
-- module is required from both VMs during startup, and a folder that has not
-- replicated yet would be silently empty forever.
local DEFAULT_SOURCES = { "Items", "Weapons" }

local function build()
	if built then return end
	built = true

	local found = false
	for _, name in ipairs(DEFAULT_SOURCES) do
		local folder = ReplicatedStorage:FindFirstChild(name)
		if folder then
			found = true
			ItemRegistry.AddSource(folder)
		end
	end

	if not found then
		warn("[ItemRegistry] no ReplicatedStorage.Items or .Weapons folder.")
	end
end

-- Returns canonicalClass, definition -- or nil for an unknown name.
function ItemRegistry.Resolve(name)
	if type(name) ~= "string" or name == "" then return nil end
	build()

	local class = statsByClass[name] and name or classByAlias[name:lower()]
	if not class then return nil end
	return class, statsByClass[class]
end

function ItemRegistry.Stats(name)
	local _, s = ItemRegistry.Resolve(name)
	return s
end

function ItemRegistry.Class(name)
	local class = ItemRegistry.Resolve(name)
	return class
end

--=====================================================================
-- BEHAVIOUR
--=====================================================================
-- An item's behaviour lives on the definition in two tables, split by which
-- VM is allowed to run them:
--
--   server = { OnUse = function(plr, item, ctx) ... end, ... }
--   client = { OnUseStart = ..., OnRender = ..., ... }
--
-- The split is the contract, not a suggestion. The server table is the only
-- thing that may change the world -- health, inventory, anything another
-- player can observe -- and the client table is prediction and presentation.
-- An item that heals from its client hook heals nobody, and one that tries is
-- easier to spot when the tables say which side it is on.
--
-- Both are optional at every level: no table, no hook, not a function -- all
-- three answer nil, so a caller never has to write the same three checks.

local function hookOf(stats, side, name)
	if type(stats) ~= "table" then return nil end
	local tbl = stats[side]
	if type(tbl) ~= "table" then return nil end
	local fn = tbl[name]
	return type(fn) == "function" and fn or nil
end

function ItemRegistry.ServerHook(stats, name)
	return hookOf(stats, "server", name)
end

function ItemRegistry.ClientHook(stats, name)
	return hookOf(stats, "client", name)
end

-- What the item DOES when you press the trigger.
--
--   "fire"  a weapon: it has a rate of fire and goes through the shot path
--   "use"   anything else that declares a use: an apple, a torch, a medkit
--   nil     inert -- carried and drawn, and the trigger does nothing
--
-- Derived rather than declared, so an item author states the numbers they
-- actually have and never has to keep a `kind` field in step with them. An
-- explicit `kind` still wins, for the one item that is both.
function ItemRegistry.Action(stats)
	if type(stats) ~= "table" then return nil end
	if stats.kind == "weapon" then return "fire" end
	if type(stats.fireRate) == "number" then return "fire" end
	if type(stats.useTime) == "number" or ItemRegistry.ServerHook(stats, "OnUse") then
		return "use"
	end
	return nil
end

-- The visual model, which lives at the ReplicatedStorage root rather than in
-- the item folder and is named with the canonical class.
function ItemRegistry.Model(name)
	local class = ItemRegistry.Class(name)
	if not class then return nil end
	local m = ReplicatedStorage:FindFirstChild(class)
	return (m and m:IsA("Model")) and m or nil
end

function ItemRegistry.All()
	build()
	return statsByClass
end

return ItemRegistry
