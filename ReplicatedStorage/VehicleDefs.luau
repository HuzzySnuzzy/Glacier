-- ModuleScript: VehicleDefs
-- Parent: ReplicatedStorage
--
-- What a vehicle IS, shared by the client that drives it and the server that
-- spawns it. One table per class, plus a builder that produces a barebones
-- chassis out of primitives when there is no art for it yet.
--
-- UNITS. Studs and studs/second throughout, the same as the movement code.
-- Roblox's own convention is roughly 1 stud = 0.28m, and this engine's is
-- 11 units per stud from the GoldSrc side -- but nothing here needs a real
-- world number, so the numbers below are tuned by feel against sv_maxspeed
-- (22.7 studs/s is a CS run) rather than converted from anything.
--
-- WHY NOT A VehicleSeat AND CONSTRAINTS. Roblox's constraint vehicles are
-- simulated by the engine's rigid body solver, which means the driving feel is
-- whatever the solver gives you, network ownership decides who is authoritative
-- rather than this code, and none of it can be tuned from the console. This
-- engine already simulates the PLAYER by hand for exactly those reasons; the
-- car follows the same rule. The chassis is one anchored part moved by CFrame,
-- the wheels are decoration positioned from the suspension result, and the
-- whole thing is a fixed-timestep sim like Physics.
--
-- SEATS are offsets in chassis space. Seat 1 is the driver -- always -- and
-- everything downstream keys on that, so do not reorder them.

local VehicleDefs = {}

--=====================================================================
-- CLASSES
--=====================================================================
-- Every field is optional except size and seats; DEFAULTS below fills the
-- rest. That is what makes adding a class a five-line job.
--
-- Reading the handling numbers:
--   drive        peak forward acceleration, studs/s^2, before drag
--   topSpeed     where drag balances drive and you stop gaining
--   grip         lateral acceleration the tyres can hold before sliding
--   steerAngle   degrees of lock at a standstill
--   steerSpeed   speed at which lock has fallen to half -- this is the
--                single number that decides whether a car feels twitchy
--   balance      0 = grip all on the front (spins), 1 = all rear (ploughs).
--                0.5 is neutral; below it the car oversteers, which is the
--                GTA IV feel and the reason handbrake turns work.

local DEFAULTS = {
	label        = "Vehicle",
	size         = Vector3.new(6, 2.4, 12),   -- chassis collision box
	mass         = 1400,

	drive        = 26,
	reverse      = 12,
	brake        = 42,
	topSpeed     = 95,
	topReverse   = 26,

	grip         = 34,
	balance      = 0.44,
	handbrakeGrip= 0.28,      -- rear grip multiplier while the handbrake is on

	steerAngle   = 34,
	steerSpeed   = 55,
	steerRate    = 6.5,       -- how fast the wheels turn toward the input
	steerReturn  = 9,         -- and how fast they centre when you let go

	dragLinear   = 0.06,      -- rolling resistance, proportional to speed
	-- dragQuad is DERIVED from drive and topSpeed, below. Do not author it.

	suspension   = 1.1,       -- travel
	springHz     = 2.1,       -- undamped natural frequency of the springs
	springDamp   = 0.55,      -- 1 is critical; under it the car breathes

	wheelRadius  = 1.1,
	wheelWidth   = 0.7,

	bodyRoll     = 0.30,      -- degrees of lean per stud/s^2 of lateral accel
	bodyPitch    = 0.22,      -- and of dive/squat per stud/s^2 forward

	restitution  = 0.25,      -- how much of a crash comes back as bounce
	crashLoss    = 0.55,      -- and how much of the rest is simply eaten

	seats = {
		{ name = "driver",    offset = Vector3.new(-1.2, 0.6, 1.2) },
		{ name = "passenger", offset = Vector3.new( 1.2, 0.6, 1.2) },
		{ name = "rear left", offset = Vector3.new(-1.2, 0.6, -1.6) },
		{ name = "rear right",offset = Vector3.new( 1.2, 0.6, -1.6) },
	},
}

VehicleDefs.Defaults = DEFAULTS

-- Where the suspension sits when nothing is happening: half the travel, so a
-- bump has somewhere to compress into and a crest has somewhere to drop into.
-- The sim cancels gravity at exactly this point, which is what makes the ride
-- height independent of the spring rate AND of sv_vehicle_gravity.
VehicleDefs.RestCompression = 0.5

-- Chassis CENTRE above the ground when parked. What a spawn needs, so a car
-- placed at road level starts on its springs rather than buried in the road.
function VehicleDefs.RestHeight(def)
	return def.wheelRadius
		+ def.suspension * (1 - VehicleDefs.RestCompression)
		+ def.size.Y * 0.5
end

VehicleDefs.Classes = {
	-- The one you get from a bare `vehicle_spawn`. Deliberately middle of the
	-- road: quick enough to be worth driving, slow enough to survive a mistake.
	sedan = {
		label = "Sedan",
	},

	-- Light, short wheelbase, low grip. Slides on purpose.
	coupe = {
		label      = "Coupe",
		size       = Vector3.new(5.6, 2.2, 10.5),
		mass       = 1150,
		drive      = 32,
		topSpeed   = 112,
		grip       = 31,
		balance    = 0.38,
		steerAngle = 38,
		bodyRoll   = 0.36,
	},

	-- Heavy, tall, understeers, rolls a lot. Slow to stop, which is the point.
	van = {
		label       = "Van",
		size        = Vector3.new(7, 4.2, 14),
		mass        = 2600,
		drive       = 18,
		topSpeed    = 72,
		brake       = 30,
		grip        = 27,
		balance     = 0.54,
		steerAngle  = 28,
		steerSpeed  = 42,
		wheelRadius = 1.35,
		bodyRoll    = 0.52,
		bodyPitch   = 0.34,
	},
}

--=====================================================================
-- LOOKUP
--=====================================================================

-- Returns a fully populated def -- every DEFAULTS key present -- so callers
-- never have to write `def.grip or 34` and never disagree about the fallback.
function VehicleDefs.Get(class)
	local key = string.lower(tostring(class or "sedan"))
	local raw = VehicleDefs.Classes[key]
	if not raw then return nil end

	local def = {}
	for k, v in pairs(DEFAULTS) do def[k] = v end
	for k, v in pairs(raw) do def[k] = v end
	def.class = key

	-- Aerodynamic drag is DERIVED, never authored: it is exactly the value at
	-- which the engine's force is cancelled at topSpeed, so topSpeed is the
	-- real asymptote rather than a number in a comment. Authoring both is how
	-- the first draft ended up with a "95 stud/s" sedan that ran out of breath
	-- at 21 -- the drag was four times what the engine could push through, and
	-- nothing anywhere said so.
	--
	-- The falloff this produces is the right shape for free, too: constant
	-- engine force against a v^2 drag is quick off the line and slow at the
	-- top, which is what a car does.
	def.dragQuad = math.max(def.drive - def.dragLinear * def.topSpeed, 0.01)
		/ (def.topSpeed * def.topSpeed)

	-- Seats are the one nested table, so a class that overrides them must not
	-- end up sharing DEFAULTS.seats by reference with everything else.
	local seats = {}
	for i, seat in ipairs(def.seats) do
		seats[i] = { name = seat.name, offset = seat.offset }
	end
	def.seats = seats

	return def
end

function VehicleDefs.List()
	local names = {}
	for key in pairs(VehicleDefs.Classes) do table.insert(names, key) end
	table.sort(names)
	return names
end

--=====================================================================
-- WHEEL LAYOUT
--=====================================================================
-- Four corners in chassis space, at the bottom of the body. The suspension
-- ray starts here and the wheel is drawn at whatever depth it found ground.
-- Order is fixed: FL, FR, RL, RR -- the sim indexes it for load transfer.

function VehicleDefs.WheelAnchors(def)
	local halfTrack = def.size.X * 0.5 - def.wheelWidth * 0.5
	local halfBase  = def.size.Z * 0.5 - def.wheelRadius * 1.1
	local y         = -def.size.Y * 0.5

	return {
		{ name = "FL", front = true,  offset = Vector3.new(-halfTrack, y,  halfBase) },
		{ name = "FR", front = true,  offset = Vector3.new( halfTrack, y,  halfBase) },
		{ name = "RL", front = false, offset = Vector3.new(-halfTrack, y, -halfBase) },
		{ name = "RR", front = false, offset = Vector3.new( halfTrack, y, -halfBase) },
	}
end

-- Distance front axle to rear axle. The bicycle model's only geometry input.
function VehicleDefs.Wheelbase(def)
	return math.max(def.size.Z - def.wheelRadius * 2.2, 1)
end

--=====================================================================
-- BUILDER
--=====================================================================
-- A barebones chassis out of primitives, used when ReplicatedStorage.Vehicles
-- has no model for the class. It is not meant to be pretty; it is meant to
-- mean that `vehicle_spawn` works on a blank baseplate with nothing prepared.
--
-- STRUCTURE, and every consumer relies on it:
--   Model
--     Chassis   BasePart, PrimaryPart, ANCHORED, CanCollide -- the only
--               part that collides with anything
--     Wheels    Folder of four parts, CanCollide FALSE, purely drawn
--     Seats     Folder of Attachments, one per seat, for prompts and exit
--
-- Anchored because this engine moves things by CFrame. An unanchored chassis
-- would be simulated twice: once by this code and once by Roblox.

local function part(name, size, colour, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = colour
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function VehicleDefs.Build(class)
	local def = VehicleDefs.Get(class)
	if not def then return nil, ("unknown vehicle class '%s'"):format(tostring(class)) end

	local model = Instance.new("Model")
	model.Name = def.label

	-- ONE collision box for the whole car. Per-panel collision on a vehicle
	-- this size buys nothing but sweep cost and wedge cases -- the sim casts
	-- against the box, and so does everything shooting at it.
	local chassis = part("Chassis", def.size, Color3.fromRGB(150, 160, 175), model)
	chassis.CanCollide = true
	chassis.CanTouch = true
	chassis.Material = Enum.Material.Metal
	model.PrimaryPart = chassis

	-- Cabin and bonnet are welded decoration so the thing reads as a car and,
	-- more usefully, so you can see which way it is pointing at a glance.
	local cabin = part("Cabin",
		Vector3.new(def.size.X * 0.86, def.size.Y * 0.75, def.size.Z * 0.42),
		Color3.fromRGB(90, 100, 115), model)
	cabin.Material = Enum.Material.Glass
	cabin.Transparency = 0.35

	local nose = part("Nose",
		Vector3.new(def.size.X * 0.9, def.size.Y * 0.18, def.size.Z * 0.2),
		Color3.fromRGB(200, 70, 60), model)

	local wheels = Instance.new("Folder")
	wheels.Name = "Wheels"
	wheels.Parent = model

	for _, anchor in ipairs(VehicleDefs.WheelAnchors(def)) do
		-- Cylinder, not a sphere. A sphere reads as a ball wherever it sits;
		-- a cylinder shows steering angle and, once it spins, road speed.
		local wheel = part(anchor.name,
			Vector3.new(def.wheelWidth, def.wheelRadius * 2, def.wheelRadius * 2),
			Color3.fromRGB(35, 35, 40), wheels)
		wheel.Shape = Enum.PartType.Cylinder
		wheel.Material = Enum.Material.Rubber

		-- Placed at the REST position now, and not welded. Only a car being
		-- driven or watched gets its wheels positioned by the suspension, so
		-- a parked one would otherwise sit with all four stacked at the
		-- chassis centre until somebody got in. The quarter turn about Z is
		-- what stands a Roblox cylinder up -- they point down their X axis.
		wheel.CFrame = CFrame.new(
				anchor.offset - Vector3.new(0, def.suspension * (1 - VehicleDefs.RestCompression), 0))
			* CFrame.Angles(0, 0, math.rad(90))
	end

	-- Seats are Attachments ON THE CHASSIS rather than parts in a folder.
	-- An attachment already follows its parent part, costs nothing, and gives
	-- both ends a named point to read -- which is all a seat is here, since
	-- the occupant's RawBody is parked at it by CFrame every tick.
	for i, seat in ipairs(def.seats) do
		local a = Instance.new("Attachment")
		a.Name = ("Seat%d"):format(i)
		a.Position = seat.offset
		a:SetAttribute("Label", seat.name)
		a.Parent = chassis
	end

	-- Positioned BEFORE the welds exist. A WeldConstraint captures the
	-- relative transform at the moment it is created; welding first and
	-- moving afterwards snaps the panels straight back where they were.
	chassis.CFrame = CFrame.identity
	cabin.CFrame = chassis.CFrame * CFrame.new(0, def.size.Y * 0.72, -def.size.Z * 0.06)
	nose.CFrame  = chassis.CFrame * CFrame.new(0, def.size.Y * 0.5, def.size.Z * 0.4)

	-- Welded so the decoration follows the chassis without this code having to
	-- position it. The wheels are NOT welded: the suspension places them.
	for _, piece in ipairs({ cabin, nose }) do
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = chassis
		weld.Part1 = piece
		weld.Parent = chassis
	end

	return model, def
end

return VehicleDefs
