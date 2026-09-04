-- ModuleScript: ReplicatedStorage.WeaponTuning
-- Live edits to weapon module stats, in both VMs.
--
-- A weapon module is a ModuleScript that returns a table, and require() caches
-- that table per VM -- so writing a field into it changes the weapon for
-- everything in that VM that reads it, immediately and with no reload. That is
-- the whole mechanism. This module is the bookkeeping around it: which fields
-- may be edited, what they were before, and how to get the change into the
-- OTHER VM (WeaponTuneServer owns that half).
--
-- IT DOES NOT SAVE. Edits live until the server restarts. Export() prints the
-- changed fields as a paste-ready snippet, which is the point: tune it in
-- game, then put the numbers in the module.
--
-- Fields are addressed by dotted path -- "damage", "accuracy.moving",
-- "recoil.pattern" is refused (see EDITABLE below).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WeaponRegistry = require(ReplicatedStorage:WaitForChild("WeaponRegistry"))

local WeaponTuning = {}

-- [class] = { [path] = originalValue }. Only paths that have actually been
-- changed appear, and the value is what the module shipped with -- which is
-- what makes Reset and Export possible without re-reading the source.
local originals = {}

--=====================================================================
-- PATHS
--=====================================================================

-- Only scalars. A weapon's recoil pattern is a hundred Vector2s and its
-- animation table is a set of asset ids; neither belongs behind a text box,
-- and letting a path reach them is how you end up with a half-written pattern
-- and no way back.
local function isEditable(value)
	local t = typeof(value)
	return t == "number" or t == "boolean" or t == "string"
end

WeaponTuning.IsEditable = isEditable

local function split(path)
	local parts = {}
	for part in string.gmatch(tostring(path), "[^%.]+") do
		table.insert(parts, part)
	end
	return parts
end

-- Returns the table holding the final key, and that key.
local function resolve(stats, path)
	local parts = split(path)
	if #parts == 0 then return nil end

	local holder = stats
	for i = 1, #parts - 1 do
		holder = holder[parts[i]]
		if type(holder) ~= "table" then return nil end
	end
	return holder, parts[#parts]
end

--=====================================================================
-- READ
--=====================================================================

function WeaponTuning.Get(class, path)
	local stats = WeaponRegistry.Stats(class)
	if not stats then return nil end
	local holder, key = resolve(stats, path)
	if not holder then return nil end
	return holder[key]
end

-- Every editable path on a weapon, sorted, one level of nesting deep. One
-- level covers accuracy.*, which is where the interesting numbers are, without
-- walking into the pattern arrays.
function WeaponTuning.Fields(class)
	local stats = WeaponRegistry.Stats(class)
	if not stats then return {} end

	local out = {}
	for key, value in pairs(stats) do
		if isEditable(value) then
			table.insert(out, key)
		elseif type(value) == "table" then
			for subKey, subValue in pairs(value) do
				if isEditable(subValue) then
					table.insert(out, key .. "." .. subKey)
				end
			end
		end
	end

	table.sort(out)
	return out
end

function WeaponTuning.IsChanged(class, path)
	return originals[class] ~= nil and originals[class][path] ~= nil
end

function WeaponTuning.Original(class, path)
	local byClass = originals[class]
	return byClass and byClass[path] or nil
end

--=====================================================================
-- WRITE
--=====================================================================

-- Returns ok, applied | reason. The value is coerced to the type the field
-- already has, so a text box can hand this a string and get a number.
function WeaponTuning.Set(class, path, value)
	local canonical, stats = WeaponRegistry.Resolve(class)
	if not stats then return false, ("no weapon named '%s'"):format(tostring(class)) end

	local holder, key = resolve(stats, path)
	if not holder then return false, ("no field '%s' on %s"):format(tostring(path), canonical) end

	local current = holder[key]
	if not isEditable(current) then
		return false, ("'%s' is a %s -- only numbers, booleans and strings are editable")
			:format(tostring(path), typeof(current))
	end

	-- Coerce to the field's OWN type. A weapon whose damage became the string
	-- "36" would pass every arithmetic in Lua and then fail somewhere far away.
	local wanted = typeof(current)
	if type(value) == "string" then
		if wanted == "number" then
			local n = tonumber(value)
			if not n then return false, ("'%s' wants a number"):format(path) end
			value = n
		elseif wanted == "boolean" then
			local lower = string.lower(value)
			if lower == "true" or lower == "1" then value = true
			elseif lower == "false" or lower == "0" then value = false
			else return false, ("'%s' wants true or false"):format(path) end
		end
	end

	if typeof(value) ~= wanted then
		return false, ("'%s' wants a %s, got %s"):format(path, wanted, typeof(value))
	end

	-- Remembered on the FIRST change only, so repeated edits still know what
	-- the module actually shipped with.
	local byClass = originals[canonical]
	if not byClass then
		byClass = {}
		originals[canonical] = byClass
	end
	if byClass[path] == nil then byClass[path] = current end

	holder[key] = value
	return true, value
end

-- Returns ok, restored | reason.
function WeaponTuning.Reset(class, path)
	local canonical, stats = WeaponRegistry.Resolve(class)
	if not stats then return false, "no such weapon" end

	local byClass = originals[canonical]
	local original = byClass and byClass[path]
	if original == nil then return false, ("'%s' was never changed"):format(tostring(path)) end

	local holder, key = resolve(stats, path)
	if not holder then return false, "field is gone" end

	holder[key] = original
	byClass[path] = nil
	if next(byClass) == nil then originals[canonical] = nil end

	return true, original
end

function WeaponTuning.ResetAll(class)
	local canonical = WeaponRegistry.Class(class)
	local byClass = canonical and originals[canonical]
	if not byClass then return 0 end

	local n = 0
	-- Snapshotted: Reset deletes from the table being walked.
	local paths = {}
	for path in pairs(byClass) do table.insert(paths, path) end
	for _, path in ipairs(paths) do
		if (WeaponTuning.Reset(canonical, path)) then n += 1 end
	end
	return n
end

--=====================================================================
-- EXPORT
--=====================================================================

-- The changed fields as Lua, ready to paste back into the weapon module. This
-- is what makes the editor more than a toy: nothing here persists, so the
-- session's work has to leave as source.
local function literal(value)
	if type(value) == "string" then return ('%q'):format(value) end
	return tostring(value)
end

function WeaponTuning.Export(class)
	local canonical = WeaponRegistry.Class(class)
	local byClass = canonical and originals[canonical]
	if not byClass then return nil end

	local paths = {}
	for path in pairs(byClass) do table.insert(paths, path) end
	if #paths == 0 then return nil end
	table.sort(paths)

	local lines = { ("-- %s"):format(canonical) }
	for _, path in ipairs(paths) do
		table.insert(lines, ("%s = %s,   -- was %s")
			:format(path, literal(WeaponTuning.Get(canonical, path)), literal(byClass[path])))
	end
	return table.concat(lines, "\n")
end

function WeaponTuning.ChangedClasses()
	local out = {}
	for class in pairs(originals) do table.insert(out, class) end
	table.sort(out)
	return out
end

return WeaponTuning
