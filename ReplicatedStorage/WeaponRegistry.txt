-- ModuleScript: ReplicatedStorage.WeaponRegistry
-- Name -> stats resolution, in one place, for client and server alike.
--
-- Weapon modules carry a lowercase `name` field ("ak47") while the
-- ModuleScript itself is "AK47". Both spellings travel over the wire in
-- different packets, and FindFirstChild is case-sensitive, so every consumer
-- that rolled its own lookup got a different subset of them right.
--
-- CANONICAL CLASS is the ModuleScript's own name. It is what inventory items
-- store, what the world model lookup uses, and what should be persisted --
-- never the lowercase `name`, which is only a display/netKey string.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WeaponRegistry = {}

local statsByClass = {}   -- "AK47" -> stats table
local classByAlias = {}   -- "ak47" -> "AK47"
local built = false

local function ingest(mod)
	local ok, s = pcall(require, mod)
	if not (ok and type(s) == "table") then
		warn(("[WeaponRegistry] '%s' failed to load: %s"):format(mod.Name, tostring(s)))
		return
	end

	statsByClass[mod.Name] = s
	classByAlias[mod.Name:lower()] = mod.Name

	if type(s.name) == "string" and s.name ~= "" then
		local alias = s.name:lower()
		local clash = classByAlias[alias]
		if clash and clash ~= mod.Name then
			warn(("[WeaponRegistry] '%s' and '%s' both claim the name '%s'.")
				:format(clash, mod.Name, s.name))
		end
		classByAlias[alias] = mod.Name
	end
end

local function build()
	if built then return end
	built = true

	local folder = ReplicatedStorage:FindFirstChild("Weapons")
	if not folder then
		warn("[WeaponRegistry] no ReplicatedStorage.Weapons folder.")
		return
	end

	for _, mod in ipairs(folder:GetChildren()) do
		if mod:IsA("ModuleScript") then ingest(mod) end
	end

	-- Weapons added at runtime (a live-authored module, a streamed-in pack).
	folder.ChildAdded:Connect(function(mod)
		if mod:IsA("ModuleScript") then ingest(mod) end
	end)
end

-- Returns canonicalClass, stats -- or nil for an unknown name.
function WeaponRegistry.Resolve(name)
	if type(name) ~= "string" or name == "" then return nil end
	build()

	local class = statsByClass[name] and name or classByAlias[name:lower()]
	if not class then return nil end
	return class, statsByClass[class]
end

function WeaponRegistry.Stats(name)
	local _, s = WeaponRegistry.Resolve(name)
	return s
end

function WeaponRegistry.Class(name)
	local class = WeaponRegistry.Resolve(name)
	return class
end

-- The visual model, which lives at the ReplicatedStorage root rather than in
-- the Weapons folder and is named with the canonical class.
function WeaponRegistry.Model(name)
	local class = WeaponRegistry.Class(name)
	if not class then return nil end
	local m = ReplicatedStorage:FindFirstChild(class)
	return (m and m:IsA("Model")) and m or nil
end

function WeaponRegistry.All()
	build()
	return statsByClass
end

return WeaponRegistry