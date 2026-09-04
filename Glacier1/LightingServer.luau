-- Script: LightingServer
-- Parent: Glacier1
--
-- Console control of Lighting. Server-side because Lighting is a replicated
-- service: set it here and every client gets it for free, with no remote of
-- our own and no chance of two players seeing different weather.
--
--   light                     what everything is set to now
--   light clocktime 6.5       set one property
--   light ambient 40 40 55    Color3 properties take r g b, 0-255
--   light_preset night        a whole look at once
--   light_reset               back to what the place was published with
--
-- ONE COMMAND, NOT TWENTY. Lighting has a few dozen properties across itself
-- and its effects; a command each would bury the console's autocomplete under
-- names nobody types twice. `light <property> <value>` reaches all of them and
-- reads the type off the property itself.

local Lighting          = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

--=====================================================================
-- WHAT MAY BE TOUCHED
--=====================================================================
-- An allow-list, not "anything on Lighting". Half the service is read-only or
-- deprecated, and a typo that lands on the wrong property is a confusing way
-- to spend an evening. Keys are what you type; the value is the real property
-- and, where it is not on Lighting itself, the effect class holding it.

local PROPERTIES = {
	-- time and sun
	clocktime      = { prop = "ClockTime" },
	timeofday      = { prop = "TimeOfDay" },
	latitude       = { prop = "GeographicLatitude" },

	-- light levels
	brightness     = { prop = "Brightness" },
	ambient        = { prop = "Ambient" },
	outdoorambient = { prop = "OutdoorAmbient" },
	exposure       = { prop = "ExposureCompensation" },
	envdiffuse     = { prop = "EnvironmentDiffuseScale" },
	envspecular    = { prop = "EnvironmentSpecularScale" },
	colorshift_top = { prop = "ColorShift_Top" },
	colorshift_bot = { prop = "ColorShift_Bottom" },

	-- shadows
	shadows        = { prop = "GlobalShadows" },
	shadowsoftness = { prop = "ShadowSoftness" },
	technology     = { prop = "Technology", readOnly = true },

	-- fog
	fogstart       = { prop = "FogStart" },
	fogend         = { prop = "FogEnd" },
	fogcolor       = { prop = "FogColor" },

	-- effects, created on demand so a place without them still works
	atmosphere_density = { prop = "Density",  effect = "Atmosphere" },
	atmosphere_haze    = { prop = "Haze",     effect = "Atmosphere" },
	atmosphere_glare   = { prop = "Glare",    effect = "Atmosphere" },
	atmosphere_color   = { prop = "Color",    effect = "Atmosphere" },
	atmosphere_decay   = { prop = "Decay",    effect = "Atmosphere" },
	bloom_intensity    = { prop = "Intensity", effect = "BloomEffect" },
	bloom_threshold    = { prop = "Threshold", effect = "BloomEffect" },
	bloom_size         = { prop = "Size",      effect = "BloomEffect" },
	blur               = { prop = "Size",      effect = "BlurEffect" },
}

-- The values the place was published with, captured before anything is
-- changed. This is what light_reset restores -- not a hardcoded "default",
-- which would be someone else's idea of what this map should look like.
local shipped = {}

local function holderFor(entry, create)
	if not entry.effect then return Lighting end

	local found = Lighting:FindFirstChildOfClass(entry.effect)
	if found or not create then return found end

	local made = Instance.new(entry.effect)
	made.Parent = Lighting
	return made
end

local function readValue(entry)
	local holder = holderFor(entry, false)
	if not holder then return nil end
	local ok, value = pcall(function() return holder[entry.prop] end)
	return ok and value or nil
end

do
	for key, entry in pairs(PROPERTIES) do
		shipped[key] = readValue(entry)
	end
end

--=====================================================================
-- VALUES
--=====================================================================

-- Coerced to whatever the property already is, so the console can hand this
-- strings and Roblox still gets a Color3 where it wants one.
local function coerce(current, text)
	local wanted = typeof(current)

	if wanted == "number" then
		local n = tonumber(text)
		if not n then return nil, "expected a number" end
		return n

	elseif wanted == "boolean" then
		local lower = string.lower(text)
		if lower == "1" or lower == "true" then return true end
		if lower == "0" or lower == "false" then return false end
		return nil, "expected true or false"

	elseif wanted == "Color3" then
		-- r g b, 0-255, which is how anyone reads a colour off a palette.
		local r, g, b = string.match(text, "(%d+)[%s,]+(%d+)[%s,]+(%d+)")
		if not r then return nil, "expected three numbers, 0-255" end
		return Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b))

	elseif wanted == "string" then
		return text

	elseif wanted == "EnumItem" then
		return nil, "not settable from the console"
	end

	return nil, ("cannot set a %s"):format(wanted)
end

local function show(value)
	if typeof(value) == "Color3" then
		return ("%d %d %d"):format(
			math.floor(value.R * 255 + 0.5),
			math.floor(value.G * 255 + 0.5),
			math.floor(value.B * 255 + 0.5))
	end
	return tostring(value)
end

-- Returns ok, applied | reason.
local function setProperty(key, text)
	local entry = PROPERTIES[key]
	if not entry then return false, ("no lighting property '%s'"):format(tostring(key)) end
	if entry.readOnly then return false, ("'%s' is read-only"):format(key) end

	local holder = holderFor(entry, true)
	if not holder then return false, ("could not create a %s"):format(tostring(entry.effect)) end

	local current = holder[entry.prop]
	local value, why = coerce(current, text)
	if value == nil then return false, ("%s: %s"):format(key, why) end

	local ok, err = pcall(function() holder[entry.prop] = value end)
	if not ok then return false, tostring(err) end

	return true, value
end

--=====================================================================
-- PRESETS
--=====================================================================
-- Whole looks rather than a property at a time, because that is how anyone
-- actually uses this: you want "night", not eleven numbers.

local PRESETS = {
	day = {
		clocktime = "14", brightness = "2", outdoorambient = "70 70 70",
		fogend = "100000", ambient = "0 0 0", exposure = "0",
	},
	night = {
		clocktime = "0", brightness = "1", outdoorambient = "35 35 45",
		fogend = "80000", ambient = "10 10 20", exposure = "0.4",
	},
	dusk = {
		clocktime = "17.7", brightness = "1.6", outdoorambient = "80 65 60",
		fogend = "60000", exposure = "0.2",
	},
	dawn = {
		clocktime = "6.4", brightness = "1.6", outdoorambient = "75 70 80",
		fogend = "60000", exposure = "0.2",
	},
	foggy = {
		fogstart = "0", fogend = "180", fogcolor = "150 155 160",
		brightness = "1.4", outdoorambient = "90 92 96",
	},
	clear = {
		fogstart = "0", fogend = "100000", atmosphere_density = "0.15",
		atmosphere_haze = "0", blur = "0",
	},
	dark = {
		clocktime = "0", brightness = "0", outdoorambient = "0 0 0",
		ambient = "0 0 0", exposure = "0",
	},
}

local function presetNames()
	local out = {}
	for name in pairs(PRESETS) do table.insert(out, name) end
	table.sort(out)
	return table.concat(out, ", ")
end

--=====================================================================
-- COMMANDS
--=====================================================================
-- REPLICATED, so a client console forwards them here rather than trying to
-- set Lighting locally -- which would work for exactly one player and then be
-- overwritten by the next replication.

local FLAG = Config.FCVAR.REPLICATED

local function reply(ctx, text)
	if ctx and type(ctx.reply) == "function" then ctx.reply(text) else print(text) end
end

Config.Command("light", {
	args = { "string?", "rest?" },
	flag = FLAG,
	help = "show or set a lighting property: light clocktime 6.5 | light ambient 40 40 55",
	run = function(ctx, key, value)
		if not key then
			local keys = {}
			for name in pairs(PROPERTIES) do table.insert(keys, name) end
			table.sort(keys)

			local lines = {}
			for _, name in ipairs(keys) do
				local current = readValue(PROPERTIES[name])
				table.insert(lines, ("%-20s %s"):format(name,
					current ~= nil and show(current) or "-"))
			end
			reply(ctx, table.concat(lines, "\n"))
			return true
		end

		key = string.lower(key)

		if not value then
			local entry = PROPERTIES[key]
			if not entry then return false, ("no lighting property '%s'"):format(key) end
			local current = readValue(entry)
			reply(ctx, ("%s = %s"):format(key, current ~= nil and show(current) or "-"))
			return true
		end

		local ok, result = setProperty(key, value)
		if not ok then return false, result end

		reply(ctx, ("[light] %s = %s"):format(key, show(result)))
		return true
	end,
})

Config.Command("light_preset", {
	args = { "string?" },
	flag = FLAG,
	help = "apply a whole look: " .. presetNames(),
	run = function(ctx, name)
		if not name then
			reply(ctx, "[light] presets: " .. presetNames())
			return true
		end

		local preset = PRESETS[string.lower(name)]
		if not preset then
			return false, ("no preset '%s' (have: %s)"):format(name, presetNames())
		end

		local failures = {}
		for key, value in pairs(preset) do
			local ok, why = setProperty(key, value)
			if not ok then table.insert(failures, tostring(why)) end
		end

		reply(ctx, ("[light] %s%s"):format(string.lower(name),
			#failures > 0 and ("  (" .. table.concat(failures, "; ") .. ")") or ""))
		return true
	end,
})

Config.Command("light_reset", {
	args = {},
	flag = FLAG,
	help = "restore the lighting the place was published with",
	run = function(ctx)
		local n = 0
		for key, value in pairs(shipped) do
			local entry = PROPERTIES[key]
			if value ~= nil and not entry.readOnly then
				local holder = holderFor(entry, false)
				if holder and pcall(function() holder[entry.prop] = value end) then
					n += 1
				end
			end
		end
		reply(ctx, ("[light] restored %d propert%s"):format(n, n == 1 and "y" or "ies"))
		return true
	end,
})
