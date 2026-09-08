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

	-- RESET means "back to what this model SHIPS WITH", not "back to the
	-- class".
	--
	-- A car cloned from ReplicatedStorage.Vehicles carries the attributes its
	-- author put on the template. Clearing them does not restore the car: it
	-- throws the setup away and leaves whatever the class says, which for a
	-- model the engine has never heard of is a sedan. So reset puts the
	-- authored value BACK, and only clears when there was not one.
	--
	-- Its own action rather than a magic value, because "" is a legitimate
	-- thing to want in a string field.
	if text == nil then
		local authored = VehicleDefs.AuthoredValue(model:GetAttribute("Class"), name)
		model:SetAttribute(name, authored)
		return true, authored ~= nil and authored or "class default"
	end

	local value, why = coerce(text, def[field])
	if value == nil then return false, why end

	model:SetAttribute(name, value)
	return true, value
end

-- THE ANSWER GOES BACK TO THE PANEL, not only to the console.
--
-- Every refusal here used to be a Glacier.Tell and nothing else, so a person
-- with the console shut saw a value they typed quietly fail to take -- which
-- is indistinguishable from a broken editor, and is what "changing values
-- does not push changes" turned out to mean. The panel puts it in its own
-- subtitle now, where somebody using the panel is already looking.
local function reportTo(plr, action, ok, reason)
	VehicleTune:FireClient(plr, action, ok, reason)
end

VehicleTune.OnServerEvent:Connect(function(plr, action, model, name, text)
	local can, why = allowed(plr)
	if not can then
		reportTo(plr, action, false, why)
		Glacier.Tell(plr, ("[vedit] %s"):format(why), true)
		return
	end

	if action == "set" then
		local ok, result = applyTuning(plr, model, name, text)
		reportTo(plr, action, ok, ok
			and ("%s = %s"):format(tostring(name), tostring(result))
			or tostring(result))
		Glacier.Tell(plr, ok
			and ("[vedit] %s = %s"):format(tostring(name), tostring(result))
			or ("[vedit] %s"):format(tostring(result)), not ok)

	elseif action == "reset" then
		local ok, result = applyTuning(plr, model, name, nil)
		reportTo(plr, action, ok, ok
			and ("%s restored to %s"):format(tostring(name), tostring(result))
			or tostring(result))
		Glacier.Tell(plr, ok
			and ("[vedit] %s restored to %s"):format(tostring(name), tostring(result))
			or ("[vedit] %s"):format(tostring(result)), not ok)

	elseif action == "resetall" then
		if typeof(model) ~= "Instance" or not model:IsA("Model") then return end
		local vehicles = Registry.Vehicles
		if not (vehicles and type(vehicles.IsVehicle) == "function"
			and vehicles.IsVehicle(model)) then return end

		-- Only the tuning attributes. Seat occupancy and Class live in the
		-- same namespace, and wiping those would eject everybody aboard and
		-- turn the car into an untyped model.
		local class = model:GetAttribute("Class")
		local def = VehicleDefs.GetOrDerive(class)

		-- TWO PASSES, and neither can do the other's half.
		--
		-- The instance may carry settings the template does not -- added in
		-- this session, by this panel -- and those have to GO. The template
		-- may carry ones the instance has lost, deleted by an earlier reset,
		-- and those have to come BACK. Clearing alone leaves a car stripped
		-- of its author's setup; restoring alone leaves this session's edits
		-- sitting on top of it.
		for name in pairs(model:GetAttributes()) do
			if VehicleDefs.FieldFor(name, def) then
				model:SetAttribute(name, nil)
			end
		end

		local template = VehicleDefs.Template(class)
		if template then
			for name, value in pairs(template:GetAttributes()) do
				if VehicleDefs.FieldFor(name, def) then
					model:SetAttribute(name, value)
				end
			end
		end

		reportTo(plr, "resetall", true, "restored to what the model ships with")
		Glacier.Tell(plr, "[vedit] every setting restored to what the model ships with")
	end
end)
