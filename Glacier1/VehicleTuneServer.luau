-- Script: VehicleTuneServer
-- Parent: Glacier1
--
-- The other half of the vehicle editor, and deliberately much smaller than
-- WeaponTuneServer -- because a vehicle's tuning surface is already
-- replicated and the weapon's is not.
--
-- A weapon module is a table cached per VM, so an edit has to be applied on
-- the server and broadcast field by field to every client. A vehicle's tuning
-- lives in ATTRIBUTES ON THE MODEL, which Roblox replicates for free: this
-- writes one attribute and every machine in the game -- including ones that
-- join later, and including the server's own settle pass -- picks it up
-- through the same AttributeChanged path a person typing in Studio's
-- properties panel goes through. There is nothing to broadcast and nothing to
-- replay on join.
--
-- ADMIN AND CHEAT GATED, the same as the weapon editor. This retunes a car
-- for everybody on the server.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config       = require(ReplicatedStorage:WaitForChild("Config"))
local Glacier      = require(ReplicatedStorage:WaitForChild("Glacier"))
local VehicleDefs  = require(ReplicatedStorage:WaitForChild("VehicleDefs"))
local Registry     = require(script.Parent:WaitForChild("Registry"))

local function ensureRemote(name)
	local remote = ReplicatedStorage:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = ReplicatedStorage
	end
	return remote
end

local VehicleTune = ensureRemote("VehicleTune")

--=====================================================================
-- PERMISSION
--=====================================================================

local function isAdmin(plr)
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

-- The value the client typed, as the type the field actually is.
--
-- Attributes are typed, and an attribute of the wrong type is worse than no
-- attribute: ApplyAttributes checks the type and silently skips a mismatch,
-- so a number written as a string reads as the editor doing nothing.
local function coerce(text, current)
	if type(current) == "boolean" then
		local lower = tostring(text):lower()
		if lower == "true" or lower == "1" then return true end
		if lower == "false" or lower == "0" then return false end
		return nil, "expected true or false"
	end

	if type(current) == "number" then
		local n = tonumber(text)
		if not n then return nil, "expected a number" end
		if n ~= n or n == math.huge or n == -math.huge then
			return nil, "not a finite number"
		end
		return n
	end

	if type(current) == "string" then return tostring(text) end

	return nil, "that field cannot be edited from here"
end

-- Returns ok, reasonOrValue.
local function applyTuning(plr, model, name, text)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return false, "that is not a vehicle"
	end

	-- Registered as a vehicle, not merely model-shaped. Without this the
	-- remote is a way to write arbitrary attributes onto any model in the
	-- game, which is a much bigger thing than a tuning panel.
	local vehicles = Registry.Vehicles
	if not (vehicles and type(vehicles.IsVehicle) == "function" and vehicles.IsVehicle(model)) then
		return false, "that vehicle is not registered"
	end

	local def = VehicleDefs.GetOrDerive(model:GetAttribute("Class"))
	local field = VehicleDefs.FieldFor(name, def)
	if not field then return false, ("no such setting: %s"):format(tostring(name)) end

	-- RESET, as its own action rather than a magic value: clearing the
	-- attribute is what restores the class default, and "" is a legitimate
	-- thing to want in a string field.
	if text == nil then
		model:SetAttribute(name, nil)
		return true, "default"
	end

	local value, why = coerce(text, def[field])
	if value == nil then return false, why end

	model:SetAttribute(name, value)
	return true, value
end

VehicleTune.OnServerEvent:Connect(function(plr, action, model, name, text)
	local can, why = allowed(plr)
	if not can then
		Glacier.Tell(plr, ("[vedit] %s"):format(why), true)
		return
	end

	if action == "set" then
		local ok, result = applyTuning(plr, model, name, text)
		Glacier.Tell(plr, ok
			and ("[vedit] %s = %s"):format(tostring(name), tostring(result))
			or ("[vedit] %s"):format(tostring(result)), not ok)

	elseif action == "reset" then
		local ok, result = applyTuning(plr, model, name, nil)
		Glacier.Tell(plr, ok
			and ("[vedit] %s restored to the class default"):format(tostring(name))
			or ("[vedit] %s"):format(tostring(result)), not ok)

	elseif action == "resetall" then
		if typeof(model) ~= "Instance" or not model:IsA("Model") then return end
		local vehicles = Registry.Vehicles
		if not (vehicles and type(vehicles.IsVehicle) == "function"
			and vehicles.IsVehicle(model)) then return end

		-- Only the tuning attributes. Seat occupancy and Class live in the
		-- same namespace, and wiping those would eject everybody aboard and
		-- turn the car into an untyped model.
		local def = VehicleDefs.GetOrDerive(model:GetAttribute("Class"))
		for name in pairs(model:GetAttributes()) do
			if VehicleDefs.FieldFor(name, def) then
				model:SetAttribute(name, nil)
			end
		end
		Glacier.Tell(plr, "[vedit] every setting restored to the class default")
	end
end)
