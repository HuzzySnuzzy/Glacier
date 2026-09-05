-- Script: VehicleServer
-- Parent: Glacier1
--
-- Spawning vehicles and deciding who is sitting in them. The DRIVING is not
-- here: the driver's client simulates the car exactly as it simulates the
-- player, and this relays the result. What this owns is the part a client must
-- not be trusted with -- which vehicles exist, and who occupies which seat.
--
--   EnterVehicle:FireServer(model)   -- client asks for the nearest free seat
--   ExitVehicle:FireServer()         -- client asks to get out
--   VehicleSync:FireServer(packet)   -- the driver's simulated transform
--   VehicleState (server -> clients) -- occupancy changed, here is the truth
--
-- WHY THE CLIENT DRIVES. The alternative is simulating cars on the server and
-- sending the driver their own position back, which costs a full round trip of
-- input lag on the one thing in the game that most needs to feel immediate.
-- Every other movement in this engine is client-simulated and server-checked;
-- a car that worked the other way would be the odd one out AND the worst
-- feeling thing in it. What that costs is stated plainly: a modified client can
-- drive its own car anywhere at any speed. It cannot drive SOMEONE ELSE'S car,
-- occupy a seat that is taken, or teleport a car it is not in -- those are the
-- decisions that live here.
--
-- OCCUPANCY IS ATTRIBUTES, not a table on this script. Attributes replicate on
-- their own, survive a client joining late, and can be read from a command bar
-- while debugging. Seat N holds the occupant's UserId, or 0 for empty.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Registry    = require(script.Parent:WaitForChild("Registry"))
local Config      = require(ReplicatedStorage:WaitForChild("Config"))
local Glacier     = require(ReplicatedStorage:WaitForChild("Glacier"))
local VehicleDefs = require(ReplicatedStorage:WaitForChild("VehicleDefs"))

local FCVAR  = Config.FCVAR
local SERVER = FCVAR.REPLICATED

--=====================================================================
-- REMOTES
--=====================================================================

local function ensureRemote(name, class)
	local remote = ReplicatedStorage:FindFirstChild(name)
	if not remote then
		remote = Instance.new(class or "RemoteEvent")
		remote.Name = name
		remote.Parent = ReplicatedStorage
	end
	return remote
end

local EnterVehicle = ensureRemote("EnterVehicle")
local ExitVehicle  = ensureRemote("ExitVehicle")
local VehicleState = ensureRemote("VehicleState")

-- Unreliable for the same reason PuppetSync is: a dropped transform is stale
-- by the time a retransmit would arrive, and the receiver interpolates anyway.
local VehicleSync = ensureRemote("VehicleSync", "UnreliableRemoteEvent")

--=====================================================================
-- WORLD
--=====================================================================

local function folder()
	local f = workspace:FindFirstChild("Vehicles")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Vehicles"
		f.Parent = workspace
	end
	return f
end

local nextId = 0

-- Every live vehicle, keyed by its model. Holds only what attributes cannot:
-- the def table, and the last packet's arrival time.
local vehicles = {}

-- Assigned in the SETTLING section below.
local wake

local function countVehicles()
	local n = 0
	for _ in pairs(vehicles) do n += 1 end
	return n
end

--=====================================================================
-- SEATS
--=====================================================================

local function seatAttribute(index)
	return ("Seat%d"):format(index)
end

-- Seat NAMES come from the rig -- the model -- not from the def, because how
-- many seats a car has and what they are called is a property of the art now.
-- A car with a Driverseat and five Seats has six.
local function seatName(model, index)
	local entry = vehicles[model]
	local seat = entry and entry.rig and entry.rig.seats[index]
	return seat and seat.name or ("seat " .. index)
end

local function seatOccupant(model, index)
	local id = model:GetAttribute(seatAttribute(index))
	if type(id) ~= "number" or id == 0 then return nil end
	return Players:GetPlayerByUserId(id)
end

local function driverOf(model)
	return seatOccupant(model, 1)
end

-- Where a player is sitting, anywhere in the world. Linear over the vehicle
-- list, which is bounded by sv_vehicle_maxcount and only walked on enter,
-- exit, death and disconnect -- never per frame.
local function seatOf(plr)
	for model, entry in pairs(vehicles) do
		for i = 1, #entry.rig.seats do
			if model:GetAttribute(seatAttribute(i)) == plr.UserId then
				return model, i
			end
		end
	end
	return nil
end

-- One message, one shape, every time occupancy moves. Clients key their whole
-- vehicle state off this rather than polling attributes, so it must fire for
-- BOTH ends of every transition -- including the ones nobody asked for
-- (death, disconnect, the vehicle being removed underneath them).
local function announce(model, plr, seatIndex, entered)
	VehicleState:FireAllClients({
		vehicle = model,
		userId  = plr and plr.UserId or 0,
		seat    = seatIndex,
		entered = entered,
		class   = model and model:GetAttribute("Class") or nil,
	})
end

--=====================================================================
-- SPAWN / REMOVE
--=====================================================================

-- Art if there is any, primitives if there is not. A class named in
-- ReplicatedStorage.Vehicles wins, so dropping a modelled car in there is all
-- it takes to replace the placeholder -- as long as it keeps the structure
-- VehicleDefs.Build documents (a PrimaryPart named Chassis, a Wheels folder).
local function sourceModel(class)
	local library = ReplicatedStorage:FindFirstChild("Vehicles")
	if not library then return nil end

	-- Case-insensitive, because a model called "Car" and a command typed as
	-- `vehicle_spawn car` should find each other. Exact match wins so an
	-- author can still have both "Van" and "van" if they insist.
	local template = library:FindFirstChild(class)
	if not template then
		local wanted = string.lower(tostring(class))
		for _, child in ipairs(library:GetChildren()) do
			if string.lower(child.Name) == wanted then template = child break end
		end
	end

	-- PrimaryPart is NOT required here. A model with a part named Chassis is
	-- the common near-miss, and VehicleDefs.Rig sets PrimaryPart for them --
	-- refusing to spawn over it would be a worse answer than fixing it.
	if template and template:IsA("Model")
		and (template.PrimaryPart or template:FindFirstChild("Chassis")) then
		return template:Clone()
	end
	return nil
end

local function spawnVehicle(class, cframe)
	if not Config.Get("sv_vehicles") then return nil, "vehicles are disabled (sv_vehicles 0)" end

	-- A name with art behind it is a valid vehicle even if VehicleDefs has
	-- never heard of it: it gets the default handling. That is what makes
	-- "drop a model in ReplicatedStorage.Vehicles" the whole of adding a car.
	local model = sourceModel(class)
	local def = VehicleDefs.Get(class)
	if not def then
		if not model then
			return nil, ("unknown class '%s'; try: %s, or put a model of that "
				.. "name in ReplicatedStorage.Vehicles")
				:format(tostring(class), table.concat(VehicleDefs.List(), ", "))
		end
		def = VehicleDefs.GetOrDerive(class)
	end

	local limit = Config.Get("sv_vehicle_maxcount") or 24
	if countVehicles() >= limit then
		return nil, ("vehicle limit reached (%d); vehicle_clear or raise sv_vehicle_maxcount"):format(limit)
	end

	if not model then
		local built, why = VehicleDefs.Build(def.class)
		if not built then return nil, why end
		model = built
	end

	nextId += 1
	model.Name = ("%s_%d"):format(def.label, nextId)
	model:SetAttribute("Class", def.class)
	model:SetAttribute("VehicleId", nextId)

	-- Parented BEFORE the rig is measured: Rig refuses a model with no parent,
	-- and it also has side effects worth having land on the live instance --
	-- it sets PrimaryPart, and it disables the Roblox Seat behaviour.
	model.Parent = folder()

	local rig = VehicleDefs.Rig(model, def)
	if not rig then
		model:Destroy()
		return nil, ("'%s' has no PrimaryPart and no part named Chassis"):format(def.class)
	end

	for i = 1, #rig.seats do
		model:SetAttribute(seatAttribute(i), 0)
	end
	-- Replicated so a client can tell a full car from an empty one without
	-- measuring the model itself.
	model:SetAttribute("SeatCount", #rig.seats)

	-- Anchored and CanCollide, whatever the source model said. The sim moves
	-- this by CFrame; an unanchored chassis would be simulated twice, once
	-- here and once by Roblox, and they would fight.
	rig.chassis.Anchored = true
	rig.chassis.CanCollide = true

	-- Wheels are drawn, never collided. A wheel that collides catches on the
	-- geometry its own suspension ray is measuring.
	for _, wheel in ipairs(rig.wheels) do
		if wheel.part then
			wheel.part.Anchored = true
			wheel.part.CanCollide = false
		end
	end

	-- Lifted so a spawn at ground level starts ON the springs rather than
	-- buried in the road with them fully compressed. Measured off the rig, so
	-- a model with big wheels parks on them rather than on a table's numbers.
	model:PivotTo(cframe + Vector3.new(0, VehicleDefs.RigRestHeight(rig), 0))

	vehicles[model] = { def = def, rig = rig, lastSync = 0 }
	return model
end

local function removeVehicle(model)
	local entry = vehicles[model]
	if not entry then return false end

	-- Everyone out FIRST. Destroying the model under an occupant leaves their
	-- client driving a nil chassis, and the only thing that tells them
	-- otherwise is this announcement.
	for i = 1, #entry.rig.seats do
		local occupant = seatOccupant(model, i)
		if occupant then announce(model, occupant, i, false) end
	end

	vehicles[model] = nil
	model:Destroy()
	return true
end

--=====================================================================
-- ENTER / EXIT
--=====================================================================

local function chassisOf(model)
	return model and model.PrimaryPart
end

-- Refuses for a stated reason rather than silently: "nothing happened when I
-- pressed E" is the single most annoying bug class in a use system.
local function tryEnter(plr, model, seatIndex)
	if not Config.Get("sv_vehicles") then return false, "vehicles are disabled" end
	if not Glacier.IsAlive(plr) then return false, "you are not alive" end

	local entry = vehicles[model]
	if not entry then return false, "that is not a vehicle" end

	local chassis = chassisOf(model)
	if not chassis then return false, "that vehicle has no chassis" end

	if seatOf(plr) then return false, "you are already in a vehicle" end

	-- RANGE IS CHECKED HERE and nowhere else that matters. The client also
	-- checks it, to decide whether to bother asking -- but that check is a
	-- convenience and this one is the rule.
	local body = Glacier.RawBody(plr)
	if not body then return false, "you have no body" end
	local puppet = body:FindFirstChild("Puppet")
	if not puppet then return false, "you have no puppet" end
	
	local range = Config.Get("sv_vehicle_userange") or 12
	-- Measured to the chassis SURFACE, not its centre: a van is seven studs
	-- wide, and a range measured to the middle of it would mean standing at
	-- the door is further away than standing at the bumper.
	local nearest = chassis.CFrame:PointToObjectSpace(puppet:GetPivot().Position)
	local half = chassis.Size * 0.5
	local clamped = Vector3.new(
		math.clamp(nearest.X, -half.X, half.X),
		math.clamp(nearest.Y, -half.Y, half.Y),
		math.clamp(nearest.Z, -half.Z, half.Z))
	
	
	
	if (nearest - clamped).Magnitude > range then
		return false, "too far from that vehicle :u"..tostring( (nearest - clamped).Magnitude)
	end

	-- A requested seat is honoured if it is free; otherwise take the first
	-- free one, driver's seat first. That is what makes a bare +use do the
	-- obvious thing when you walk up to an empty car.
	local wanted = tonumber(seatIndex)
	local chosen
	if wanted and entry.rig.seats[wanted] and not seatOccupant(model, wanted) then
		chosen = wanted
	else
		for i = 1, #entry.rig.seats do
			if not seatOccupant(model, i) then chosen = i; break end
		end
	end
	if not chosen then return false, "that vehicle is full" end

	model:SetAttribute(seatAttribute(chosen), plr.UserId)
	announce(model, plr, chosen, true)
	return true, chosen
end

local function tryExit(plr, forced)
	local model, seatIndex = seatOf(plr)
	if not model then return false, "you are not in a vehicle" end

	model:SetAttribute(seatAttribute(seatIndex), 0)

	-- Placed beside the car rather than inside it. Left for odd seats, right
	-- for even, so two people leaving at once do not land in each other.
	local chassis = chassisOf(model)
	if chassis and Glacier.IsAlive(plr) and not forced then
		local clear = Config.Get("sv_vehicle_exitclear") or 4.5
		local side = (seatIndex % 2 == 1) and -1 or 1
		local offset = chassis.CFrame.RightVector * (chassis.Size.X * 0.5 + clear) * side
		Glacier.Move(plr, CFrame.new(chassis.Position + offset + Vector3.new(0, 1, 0)))
	end

	-- The driver's sim stops the moment they leave, so whatever the car was
	-- doing it is now doing nothing. Hand it to the settle pass.
	if seatIndex == 1 then wake(model) end

	announce(model, plr, seatIndex, false)
	return true
end

--=====================================================================
-- SETTLING
--=====================================================================
-- Nothing simulates a car that nobody is driving. The driver's client owns
-- the sim, so with no driver there is no sim ANYWHERE -- and a spawned car
-- simply hung wherever it was placed, in mid-air, forever. So did one whose
-- driver got out over a drop, and one that vehicle_flip lifted clear.
--
-- This is the missing half, and it lives on the server because the server is
-- the only party that exists for every vehicle at all times.
--
-- It is NOT the driving sim and does not try to be: no momentum, no rolling,
-- no sliding down slopes. It answers the one question a parked car has --
-- "where does this come to rest" -- and then goes to sleep. A car that needs
-- real physics has a driver, and a driver has a sim.

local VOID_Y = -500        -- below this it is gone, not falling
local REST_EPSILON = 0.05  -- closer than this counts as resting
local SETTLE_HZ = 30
local ASLEEP_RECHECK = 0.5 -- a resting car still looks down this often

-- Everything a settling car must not land on. Player bodies are the
-- load-bearing entry: a RawBody is ANCHORED, so a car would happily come to
-- rest on somebody's hitbox and hang there in the air.
local function settleIgnore(model)
	local ignore = { model }

	local drops = workspace:FindFirstChild("WeaponDrops")
	if drops then table.insert(ignore, drops) end

	for _, plr in ipairs(Players:GetPlayers()) do
		local body = Glacier.RawBody(plr)
		if body then table.insert(ignore, body) end
	end

	return ignore
end

-- How far the car can drop before its FIRST wheel reaches its rest height,
-- plus the average ground normal. Negative means it is embedded and has to
-- come up. nil means there is genuinely nothing under it.
--
-- Straight down in WORLD space, not along the car's own up: this is gravity
-- acting on a parked car, and gravity does not care which way it is facing.
--
-- TWO PROBES, and the second one is not optional.
--
-- Roblox raycasts ignore the part the ray STARTS INSIDE. So a car embedded in
-- the road casts down from inside the road, hits nothing, and is reported as
-- being over a void -- at which point it falls forever and is deleted. Silent
-- and completely wrong.
--
-- The primary probe starts just above the roof, which is far enough out to
-- see the ground the car is standing on or slightly sunk into, and near
-- enough that a car in a tunnel still measures the tunnel FLOOR. Only when
-- that finds nothing at all does the fallback start hundreds of studs up,
-- which finds the top surface of whatever the car is buried in.
--
-- Doing the long probe first would be simpler and wrong: every car under a
-- bridge would measure the bridge and be shoved up onto the deck.
local function probeWheels(model, rig, params, lift, reach)
	local cf = rig.chassis.CFrame
	local restTravel = rig.def.suspension * (1 - VehicleDefs.RestCompression)
	local down = Vector3.new(0, -reach, 0)

	local gap, normalSum, hits = nil, Vector3.zero, 0

	for _, wheel in ipairs(rig.wheels) do
		local origin = cf * wheel.offset + Vector3.new(0, lift, 0)
		local hit = workspace:Raycast(origin, down, params)
		if hit then
			-- Distance measured back to the ANCHOR, so a surface above the
			-- anchor comes out negative and the car gets pushed out.
			local surface = hit.Distance - lift
			local slack = surface - (wheel.radius + restTravel)
			if not gap or slack < gap then gap = slack end
			normalSum += hit.Normal
			hits += 1
		end
	end

	if not gap then return nil end
	local normal = (normalSum.Magnitude > 1e-3) and normalSum.Unit or Vector3.yAxis
	return gap, normal
end

local function groundGap(model, rig)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = settleIgnore(model)
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- A parked car must not come to rest on a non-collidable prop. Roblox
	-- casts ignore CanCollide unless told otherwise; pcall'd because the
	-- property is a recent addition and assigning an unknown one errors.
	pcall(function() params.RespectCanCollide = true end)

	local roof = rig.size.Y + 1
	local gap, normal = probeWheels(model, rig, params, roof, roof + 600)
	if gap then return gap, normal end

	-- Nothing under it and nothing level with it. Either it is over a void or
	-- it is buried deeper than the roof probe reaches, and only a probe that
	-- starts well clear of the geometry can tell those apart.
	return probeWheels(model, rig, params, 500, 1200)
end

local function settleStep(model, entry, dt)
	local rig = entry.rig
	local chassis = rig and rig.chassis
	if not chassis or not chassis.Parent then return end

	local gravity = Config.Get("sv_vehicle_gravity") or 196
	local gap, normal = groundGap(model, rig)

	if gap == nil then
		-- Nothing underneath at all. Keep falling rather than hovering at the
		-- edge of the world: a car pushed off the map should leave.
		entry.fallSpeed = (entry.fallSpeed or 0) + gravity * dt
		model:PivotTo(chassis.CFrame - Vector3.new(0, entry.fallSpeed * dt, 0))
		entry.asleep = false

		if chassis.Position.Y < VOID_Y then
			local driver = driverOf(model)
			if driver then Glacier.Tell(driver, "[vehicle] your car left the world", true) end
			removeVehicle(model)
		end
		return
	end

	if gap > REST_EPSILON then
		entry.fallSpeed = (entry.fallSpeed or 0) + gravity * dt
		-- Clamped to the gap so it lands ON the ground rather than through it.
		-- No sweep is needed for that: the gap IS the distance to contact.
		local drop = math.min(entry.fallSpeed * dt, gap)
		model:PivotTo(chassis.CFrame - Vector3.new(0, drop, 0))
		entry.asleep = false
		return
	end

	if gap < -REST_EPSILON then
		-- Embedded -- spawned inside a ramp, or the ground moved up under it.
		-- Pushed straight out, no bounce; gap is negative, so this lifts.
		model:PivotTo(chassis.CFrame - Vector3.new(0, gap, 0))
		entry.fallSpeed = 0
		entry.asleep = false
		return
	end

	-- Resting. Level onto the surface, keeping yaw, and stop.
	entry.fallSpeed = 0
	local _, yaw = chassis.CFrame:ToEulerAnglesYXZ()
	model:PivotTo(VehicleDefs.OrientCF(chassis.Position, yaw, normal))
	entry.asleep = true
end

-- Woken by anything that can put a car back in the air. A sleeping car whose
-- ground is deleted underneath it still re-checks every ASLEEP_RECHECK, so
-- this is an optimisation rather than the only way down.
function wake(model)
	local entry = vehicles[model]
	if entry then
		entry.asleep = false
		entry.fallSpeed = 0
	end
end

task.spawn(function()
	local last = os.clock()
	while true do
		task.wait(1 / SETTLE_HZ)

		local now = os.clock()
		local dt = math.clamp(now - last, 1 / 240, 0.25)
		last = now

		for model, entry in pairs(vehicles) do
			if not model.Parent then
				vehicles[model] = nil

				-- A driven car is the client's to move. Touching it here would
				-- fight the driver's own sim for the same CFrame.
			elseif not driverOf(model) then
				if entry.asleep then
					if now - (entry.lastSettleCheck or 0) >= ASLEEP_RECHECK then
						entry.lastSettleCheck = now
						settleStep(model, entry, dt)
					end
				else
					entry.lastSettleCheck = now
					settleStep(model, entry, dt)
				end
			end
		end
	end
end)

--=====================================================================
-- REQUEST HANDLERS
--=====================================================================

-- One request per player per this many seconds. +use is a held button on the
-- client and an unthrottled hold would be an enter/exit loop at frame rate.
local REQUEST_INTERVAL = 0.35
local lastRequest = {}

local function throttled(plr)
	local now = os.clock()
	if lastRequest[plr] and now - lastRequest[plr] < REQUEST_INTERVAL then return true end
	lastRequest[plr] = now
	return false
end

EnterVehicle.OnServerEvent:Connect(function(plr, model, seatIndex)
	if throttled(plr) then return end
	if typeof(model) ~= "Instance" or not model:IsA("Model") then return end

	local ok, result = tryEnter(plr, model, seatIndex)
	if not ok then Glacier.Tell(plr, "[vehicle] " .. tostring(result), true) end
end)

ExitVehicle.OnServerEvent:Connect(function(plr)
	if throttled(plr) then return end
	local ok, why = tryExit(plr, false)
	if not ok then Glacier.Tell(plr, "[vehicle] " .. tostring(why), true) end
end)

--=====================================================================
-- TRANSFORM RELAY
--=====================================================================
-- The driver sends where the car ended up; this writes it and passes it on.
-- Two things are checked, and neither is anti-cheat in the strong sense:
--
--   Are you the driver of THIS car. That one is absolute -- it is the whole
--   reason the relay is server-side rather than client-to-client.
--
--   Is the CFrame finite and inside the world. That is a crash guard. A NaN
--   here propagates into every other client's render and takes their frame
--   down with it, which is a much worse outcome than a cheater driving fast.

local WORLD_LIMIT = 100000

local function sane(cf)
	if typeof(cf) ~= "CFrame" then return false end
	local p = cf.Position
	if p ~= p then return false end                       -- NaN
	return math.abs(p.X) < WORLD_LIMIT
		and math.abs(p.Y) < WORLD_LIMIT
		and math.abs(p.Z) < WORLD_LIMIT
end

VehicleSync.OnServerEvent:Connect(function(plr, packet)
	if type(packet) ~= "table" then return end

	local model = packet.vehicle
	if typeof(model) ~= "Instance" or not model:IsA("Model") then return end

	local entry = vehicles[model]
	if not entry then return end
	if driverOf(model) ~= plr then return end
	if not sane(packet.cf) then return end

	entry.lastSync = os.clock()

	-- Written on the server so late joiners, range checks and anything else
	-- reading the world get the real position. Every client overrides this
	-- locally each frame -- the driver from its own sim, everyone else from
	-- the interpolation buffer -- so the replicated write is a floor, not a
	-- fight.
	model:PivotTo(packet.cf)

	-- Relayed to everyone EXCEPT the sender: they already have it, a frame
	-- earlier and without the round trip.
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= plr then
			VehicleSync:FireClient(other, {
				vehicle = model,
				cf = packet.cf,
				vel = packet.vel,
				steer = packet.steer,
				wheelSpin = packet.wheelSpin,
				T = workspace:GetServerTimeNow(),
			})
		end
	end
end)

--=====================================================================
-- LEAVING WITHOUT ASKING
--=====================================================================
-- Death, disconnect and an abandoned car all have to put the seat back, or it
-- stays occupied by a player who is not there and the car is bricked forever.

Players.PlayerRemoving:Connect(function(plr)
	lastRequest[plr] = nil
	local model = seatOf(plr)
	if model then tryExit(plr, true) end
end)

local function onDeath(plr)
	if seatOf(plr) then tryExit(plr, true) end
end

-- Glacier.On errors when the signal's owner has not published its
-- BindableEvent yet, and start order between Glacier1's children is not
-- guaranteed -- so this is retried off the main thread, the same way
-- WeaponDropServer does it.
task.spawn(function()
	local deadline = os.clock() + 20
	repeat
		if pcall(Glacier.On, "PlayerKilled", function(victim) onDeath(victim) end) then return end
		task.wait(0.25)
	until os.clock() > deadline
	warn("[Vehicle] PlayerKilled never appeared; dying in a car will not free the seat.")
end)

-- A driver whose client has stopped sending (crashed tab, frozen script) hands
-- the car back after this long, so a stalled client cannot hold a vehicle
-- hostage. Generous, because a normal hitch must never trigger it.
local ABANDON_AFTER = 8

task.spawn(function()
	while true do
		task.wait(1)
		for model, entry in pairs(vehicles) do
			if not model.Parent then
				vehicles[model] = nil
			else
				local driver = driverOf(model)
				if driver and entry.lastSync > 0
					and os.clock() - entry.lastSync > ABANDON_AFTER then
					tryExit(driver, true)
					Glacier.Tell(driver, "[vehicle] you stopped reporting; the car was released", true)
				end
			end
		end
	end
end)

--=====================================================================
-- COMMANDS
--=====================================================================

local function reply(ctx, text, isError)
	if ctx and type(ctx.reply) == "function" then
		ctx.reply(text, isError)
	elseif isError then warn(text) else print(text) end
end

-- Where a `vehicle_spawn` with no position goes: in front of whoever typed it,
-- clear of their own body, facing away from them.
local function spawnPointFor(plr)
	local body = plr and Glacier.RawBody(plr)
	if not body then return CFrame.new(0, 5, 0) end

	local look = body.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = (flat.Magnitude > 1e-3) and flat.Unit or Vector3.zAxis

	local ahead = body.Position + flat * 14

	-- Find the GROUND under that point rather than using the spawner's own
	-- height. body.Position is the centre of the hull, so it is already a
	-- couple of studs above their feet, and standing on anything raised
	-- meant the car appeared in mid-air over the ground beside it.
	--
	-- Started well above the point, not at it, so a car spawned facing a step
	-- lands on the step rather than inside it.
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { body, folder() }
	params.FilterType = Enum.RaycastFilterType.Exclude

	local hit = workspace:Raycast(ahead + Vector3.new(0, 20, 0), Vector3.new(0, -600, 0), params)
	local ground = hit and hit.Position.Y or body.Position.Y

	local at = Vector3.new(ahead.X, ground, ahead.Z)
	-- The settle pass catches whatever this gets wrong, so a miss here is a
	-- short drop rather than a car stuck in the sky.
	return CFrame.lookAt(at, at + flat * 14)
end

Config.Command("vehicle_spawn", {
	args = { "string" },
	flag = SERVER,
	help = "spawn a vehicle in front of you (sedan, coupe, van)",
	run = function(ctx, class)
		local plr = ctx and ctx.player
		if not plr then return false, "vehicle_spawn needs a player" end

		local model, why = spawnVehicle(class or "sedan", spawnPointFor(plr))
		if not model then return false, why end

		reply(ctx, ("[vehicle] spawned %s"):format(model.Name))
		return true
	end,
})

Config.Command("vehicle_remove", {
	flag = SERVER,
	help = "remove the vehicle you are in, or the nearest one",
	run = function(ctx)
		local plr = ctx and ctx.player
		if not plr then return false, "vehicle_remove needs a player" end

		local model = seatOf(plr)
		if not model then
			local origin = Glacier.PositionOf(plr)
			if not origin then return false, "you have no body" end

			local best, bestDist
			for candidate in pairs(vehicles) do
				local chassis = chassisOf(candidate)
				if chassis then
					local d = (chassis.Position - origin).Magnitude
					if not bestDist or d < bestDist then best, bestDist = candidate, d end
				end
			end
			model = best
		end

		if not model then return false, "no vehicles spawned" end
		local name = model.Name
		removeVehicle(model)
		reply(ctx, ("[vehicle] removed %s"):format(name))
		return true
	end,
})

Config.Command("vehicle_clear", {
	flag = SERVER,
	help = "remove every spawned vehicle",
	run = function(ctx)
		local removed = 0
		for model in pairs(vehicles) do
			if removeVehicle(model) then removed += 1 end
		end
		reply(ctx, ("[vehicle] removed %d"):format(removed))
		return true
	end,
})

Config.Command("vehicle_list", {
	flag = SERVER,
	help = "list spawned vehicles and who is in them",
	run = function(ctx)
		local lines = {}
		for model, entry in pairs(vehicles) do
			local occupants = {}
			for i = 1, #entry.rig.seats do
				local occupant = seatOccupant(model, i)
				if occupant then
					table.insert(occupants, ("%s:%s"):format(seatName(model, i), occupant.Name))
				end
			end
			local chassis = chassisOf(model)
			table.insert(lines, ("  %-18s %s  %s"):format(
				model.Name,
				chassis and ("(%.0f %.0f %.0f)"):format(
					chassis.Position.X, chassis.Position.Y, chassis.Position.Z) or "(no chassis)",
				(#occupants > 0) and table.concat(occupants, " ") or "empty"))
		end

		if #lines == 0 then
			reply(ctx, "[vehicle] none spawned")
		else
			table.sort(lines)
			reply(ctx, ("[vehicle] %d spawned\n%s"):format(#lines, table.concat(lines, "\n")))
		end
		return true
	end,
})

Config.Command("vehicle_flip", {
	flag = SERVER,
	help = "upright the vehicle you are in",
	run = function(ctx)
		local plr = ctx and ctx.player
		if not plr then return false, "vehicle_flip needs a player" end

		local model = seatOf(plr)
		if not model then return false, "you are not in a vehicle" end

		local chassis = chassisOf(model)
		if not chassis then return false, "that vehicle has no chassis" end

		-- Yaw kept, pitch and roll discarded, lifted clear of whatever it is
		-- lying on. The driver's sim reads the chassis back on its next step,
		-- so this lands without any extra plumbing.
		local _, yaw = chassis.CFrame:ToEulerAnglesYXZ()
		model:PivotTo(CFrame.new(chassis.Position + Vector3.new(0, 3, 0)) * CFrame.Angles(0, yaw, 0))
		wake(model)   -- lifted clear; the settle pass puts it back down
		reply(ctx, "[vehicle] flipped")
		return true
	end,
})

Config.Command("vehicle_eject", {
	args = { "string" },
	flag = SERVER,
	help = "remove a player from whatever they are driving",
	run = function(ctx, who)
		local target = who and Config.ResolvePlayer(who) or (ctx and ctx.player)
		if not target then return false, "no such player" end

		local ok, why = tryExit(target, true)
		if not ok then return false, why end

		reply(ctx, ("[vehicle] ejected %s"):format(target.Name))
		return true
	end,
})

--=====================================================================
-- SERVER API
--=====================================================================
-- Published on the Registry the same way the other server modules do, so a
-- gamemode can place cars without going through the console.

Registry.Vehicles = {
	Spawn  = spawnVehicle,
	Remove = removeVehicle,
	SeatOf = seatOf,
	Driver = driverOf,
	Enter  = tryEnter,
	Exit   = tryExit,
	All    = function()
		local list = {}
		for model in pairs(vehicles) do table.insert(list, model) end
		return list
	end,
}