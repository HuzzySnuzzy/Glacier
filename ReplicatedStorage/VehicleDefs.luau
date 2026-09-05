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
	brake        = 30,
	topSpeed     = 95,
	topReverse   = 26,

	grip         = 34,
	balance      = 0.44,
	handbrakeGrip= 0.28,      -- rear grip multiplier while the handbrake is on

	-- How hard the tyres fight sideways motion before they saturate. Low is
	-- vague and floaty, high is darty; this is the "connected to the road"
	-- number and it is separate from how much grip there is in total.
	gripResponse = 5,

	-- LOAD TRANSFER, as a fraction of grip moved front-to-rear by a full
	-- braking or accelerating effort. This is the mechanism behind most of
	-- what a heavy car feels like: braking loads the front and the car turns
	-- in, power unloads it and the car washes wide, and lifting mid-corner
	-- swings the tail. 0 makes the car handle identically whatever the
	-- throttle is doing, which is what it did before this existed.
	loadTransfer = 0.45,

	-- Front grip lost at topSpeed. The fast-corner push that makes a heavy
	-- car feel heavy rather than merely slow.
	understeer   = 0.35,

	steerAngle   = 34,
	steerSpeed   = 55,
	steerRate    = 3.6,       -- how fast the wheels turn toward the input
	steerReturn  = 6,         -- and how fast they centre when you let go

	dragLinear   = 0.06,      -- rolling resistance, proportional to speed
	-- dragQuad is DERIVED from drive and topSpeed, below. Do not author it.

	suspension   = 1.6,       -- travel
	springHz     = 1.5,       -- undamped natural frequency of the springs
	springDamp   = 0.28,      -- 1 is critical; under it the car breathes

	wheelRadius  = 1.1,
	wheelWidth   = 0.7,

	-- Degrees of lean per stud/s^2 of tyre load. Read them against the
	-- limits: at full grip (34) the sedan leans 7 degrees, and under full
	-- braking (30) it dives 5. Those are about what a real car does.
	--
	-- 0.55 was chosen for "more bounce" and is what a car leans at the LIMIT
	-- times two and a half -- so ordinary cornering sat against the 14-degree
	-- bound, permanently at full lean and unable to express anything. Bounce
	-- is bodyDamp's job; this is amplitude.
	bodyRoll     = 0.21,
	bodyPitch    = 0.17,

	-- The BODY's own spring, separate from the suspension that holds the car
	-- up. It decides how the shell leans and settles rather than where the
	-- car is, and it is second-order on purpose: a first-order approach can
	-- only ease toward its target and stop, which reads as a car whose body
	-- is bolted solid. Under-damped, so it overshoots and comes back.
	bodyHz       = 1.1,
	bodyDamp     = 0.35,      -- well under 1: that overshoot IS the bounce

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

-- The mass a def's handling numbers are quoted against, and how quickly a car
-- of that mass builds yaw rate (1/s). Everything heavier is slower to rotate
-- and slower to stop rotating, in proportion.
local REFERENCE_MASS = 1400
local YAW_RESPONSE_AT_REFERENCE = 7

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
		steerRate  = 4.4,       -- lighter car, quicker rack
		understeer = 0.24,      -- and it pushes less than the sedan
		bodyRoll   = 0.18,      -- 5.5 deg at its grip limit: flatter than the sedan
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
		steerRate   = 2.8,       -- slow, heavy rack
		understeer  = 0.5,       -- and it pushes wide at anything like speed
		loadTransfer = 0.6,      -- tall and heavy: the weight really moves
		wheelRadius = 1.35,
		suspension  = 2.1,
		bodyRoll    = 0.37,     -- 10 deg at its limit: it is tall and it shows
		bodyPitch   = 0.3,
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

	-- ROTATIONAL INERTIA, and the only thing mass is used for -- which is why
	-- it is on the def at all rather than being decoration.
	--
	-- The bicycle model says what yaw rate the steering geometry is ASKING
	-- for. A real car takes time to get there and time to stop again, and how
	-- long depends on how heavy it is. Without this the car begins and ends
	-- its rotation on the exact frame the wheels move, which is most of what
	-- "the movements feel very intense" is.
	--
	-- Derived rather than authored so it cannot disagree with the mass beside
	-- it: a van at 2600kg turns in at roughly half the rate of a 1400kg sedan.
	def.yawResponse = YAW_RESPONSE_AT_REFERENCE * (REFERENCE_MASS / math.max(def.mass, 1))

	-- Seats are the one nested table, so a class that overrides them must not
	-- end up sharing DEFAULTS.seats by reference with everything else.
	local seats = {}
	for i, seat in ipairs(def.seats) do
		seats[i] = { name = seat.name, offset = seat.offset }
	end
	def.seats = seats

	return def
end

-- A def for ANY name. A known class gets its own numbers; anything else --
-- a model dropped into ReplicatedStorage.Vehicles under a new name -- gets the
-- defaults, so adding a vehicle needs no code at all. Handling can be promoted
-- into Classes later, or never.
function VehicleDefs.GetOrDerive(class)
	local known = VehicleDefs.Get(class)
	if known then return known end

	local derived = VehicleDefs.Get("sedan")
	derived.class = string.lower(tostring(class or "sedan"))
	derived.label = tostring(class or "Vehicle")
	return derived
end

function VehicleDefs.List()
	local names = {}
	for key in pairs(VehicleDefs.Classes) do table.insert(names, key) end
	table.sort(names)
	return names
end

--=====================================================================
-- ORIENTATION
--=====================================================================
-- The yaw convention, in ONE place, because it has already been got wrong
-- once and there are now two callers -- the driving sim and the server's
-- settle pass.
--
-- Roblox's identity CFrame looks down -Z, and LookVector is the NEGATED third
-- column of the matrix. So CFrame.Angles(0, t, 0).LookVector is
-- (-sin t, 0, -cos t), and the textbook (sin t, 0, cos t) is that direction
-- turned 180 degrees. A car built on the textbook version drives out of its
-- own back bumper -- and steers into the key you did not press, because
-- Roblox yaw also increases COUNTER-clockwise seen from above.

-- A rotation of `degrees` to the RIGHT, in Roblox's convention.
--
-- Roblox yaw increases counter-clockwise seen from above, so turning right is
-- a NEGATIVE rotation about Y. This is the third place that has had to know
-- it -- the heading vector, the yaw rate, and now the front wheels, which
-- were visibly steering the wrong way -- so it lives here rather than being
-- rederived, correctly or otherwise, at each call site.
function VehicleDefs.TurnCF(degrees)
	return CFrame.Angles(0, -math.rad(degrees), 0)
end

-- How far BELOW its rest position a wheel hangs, given what its suspension ray
-- found. Positive is down -- the wheel reaching into a dip -- and negative is
-- up, the wheel pushed into the arch by a bump. Bounded by the travel either
-- way, so a wheel over a cliff hangs at full droop rather than stretching to
-- the valley floor.
--
-- Extracted because it is the whole of what independent suspension LOOKS
-- like, and a number that only exists inside a draw call cannot be tested.
function VehicleDefs.WheelOffset(def, wheel, contact)
	if not contact then return 0 end

	local restDrop = def.suspension * (1 - VehicleDefs.RestCompression)
	local ground = wheel.ground or wheel.radius
	local drop = math.clamp(contact.distance - ground, 0, def.suspension)
	return drop - restDrop
end

function VehicleDefs.HeadingFromYaw(yaw)
	return Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
end

-- A CFrame at `position`, facing `yaw`, lying on a surface whose normal is
-- `up`. Guarded at both degenerate cases: heading parallel to up (a vertical
-- wall) gives a zero cross product, and a zero cross product gives a CFrame
-- full of NaN, which does not error -- it renders as nothing and takes the
-- frame with it.
function VehicleDefs.OrientCF(position, yaw, up)
	if not up or up.Magnitude < 1e-3 then up = Vector3.yAxis end
	up = up.Unit

	local heading = VehicleDefs.HeadingFromYaw(yaw)
	local right = heading:Cross(up)
	if right.Magnitude < 1e-3 then right = Vector3.xAxis end

	local look = up:Cross(right.Unit)
	if look.Magnitude < 1e-3 then look = heading end

	return CFrame.lookAt(position, position + look.Unit, up)
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
-- RIG
--=====================================================================
-- The def holds HANDLING -- how much grip, how much power, how fast the lock
-- falls off. The rig holds GEOMETRY, and geometry comes from the model, not
-- from a table: where the wheels actually are, how big they actually are,
-- where the seats actually are, how big the collision box actually is.
--
-- That split is the whole point. It means art can be authored in Studio, by
-- eye, and dropped in -- move a wheel and the suspension ray moves with it,
-- add a seat and there is another seat. Nothing here needs editing to add a
-- vehicle, and a model whose wheels are 1.4 studs across is not silently
-- simulated as though they were 1.1.
--
-- WHAT A MODEL NEEDS:
--   PrimaryPart, or a part named Chassis (this sets it for you). Anchored,
--     CanCollide -- it is the only part the sim collides with.
--   Wheels/       a folder or model of parts. Anchored, CanCollide FALSE.
--                 Named FL FR RL RR to declare which axle they are on;
--                 otherwise the front is decided by local Z.
--   Seats         any number of Seat or VehicleSeat parts. The one whose
--                 name contains "driver" is seat 1. Failing that, Attachments
--                 named Seat1..SeatN on the chassis, which is what Build
--                 makes. Failing that, the def's own offsets.
--
-- Everything else in the model is decoration and is simply carried along.

local rigCache = setmetatable({}, { __mode = "k" })

local function localOffset(chassis, part)
	return chassis.CFrame:ToObjectSpace(part.CFrame)
end

-- A wheel's radius from its size. Roblox cylinders lie along their own X, so
-- the radius is on the other two axes; taking the larger of them also gives a
-- sane answer for a ball, a block or an imported mesh.
-- How far the wheel hangs below its strut top when the car is parked. The one
-- number that relates "where the wheel is drawn" to "where the ray starts",
-- and it is wanted in four places, so it is not written out four times.
local function restDrop(def)
	return def.suspension * (1 - VehicleDefs.RestCompression)
end

-- The ROLLING radius, for how fast the wheel spins. Roblox cylinders lie along
-- their own X, so the radius is on the other two axes; the larger of them is
-- also a sane answer for a ball, a block or an imported mesh.
local function wheelRadiusOf(part)
	return math.max(part.Size.Y, part.Size.Z) * 0.5
end

-- How far the wheel reaches DOWN from its own centre, in chassis space.
--
-- Not the same number as the rolling radius, and this is what decides where
-- the road is. wheelRadiusOf measures in the part's OWN frame, but a wheel is
-- rotated -- a Roblox cylinder has to be turned on its side to stand up at
-- all -- so the part's local Y is not the chassis's vertical. Using the
-- rolling radius as a height is right only when the wheel happens to be
-- authored axis-aligned, and wrong by however much it is not, which shows up
-- as a car parked slightly above the road.
--
-- The exact half-height of the rotated box: each of its own half-extents
-- projected onto the chassis's up axis.
local function wheelGroundOffset(part, restRot)
	local half = part.Size * 0.5
	return math.abs(restRot.RightVector.Y) * half.X
		+ math.abs(restRot.UpVector.Y) * half.Y
		+ math.abs(restRot.LookVector.Y) * half.Z
end

-- Only a folder named Wheels, and only its own descendants. Falling back to
-- the whole MODEL means every part in it becomes a wheel -- the seats, the
-- bonnet, an aerial -- each with its own radius, and the biggest of them
-- decides how high the car parks. A model without a Wheels folder gets the
-- nominal layout instead, which is at least coherent.
local function wheelsFolder(model)
	local found = model:FindFirstChild("Wheels")
	if found and (found:IsA("Folder") or found:IsA("Model")) then return found end
	return nil
end

-- Roblox Seats are not passive. A Seat with a Humanoid touching it welds that
-- Humanoid into itself, and this engine's puppets HAVE Humanoids -- so a
-- player who walks into a parked car would be grabbed by its back seat, by
-- Roblox, behind this system's back. Disabled stops that; CanTouch off stops
-- the touch events it would still fire.
--
-- Done here rather than at spawn so it applies to every path that produces a
-- vehicle, including a model somebody drops into the world by hand.
local function neutraliseSeat(part)
	pcall(function() part.Disabled = true end)
	part.CanTouch = false
	part.CanCollide = false
end

local function gatherSeats(model, chassis, def)
	local seats = {}

	-- 1. Real Seat parts, which is how you would author this in Studio.
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart")
			and (descendant:IsA("Seat") or descendant:IsA("VehicleSeat")) then
			neutraliseSeat(descendant)
			table.insert(seats, {
				part = descendant,
				name = descendant.Name,
				cf = localOffset(chassis, descendant),
				driver = string.find(string.lower(descendant.Name), "driver") ~= nil,
			})
		end
	end

	if #seats > 0 then
		-- Driver first, always -- everything downstream keys seat 1 to the
		-- driver. The rest are ordered front to back and then left to right,
		-- so seat numbers stay stable between runs however GetDescendants
		-- happens to have ordered them.
		table.sort(seats, function(a, b)
			if a.driver ~= b.driver then return a.driver end
			local ap, bp = a.cf.Position, b.cf.Position
			if math.abs(ap.Z - bp.Z) > 0.05 then return ap.Z < bp.Z end
			return ap.X < bp.X
		end)

		local out = {}
		for i, seat in ipairs(seats) do
			out[i] = { offset = seat.cf.Position, cf = seat.cf, name = seat.name, part = seat.part }
		end
		return out
	end

	-- 2. Seat attachments on the chassis, which is what Build makes.
	local fromAttachments = {}
	for i = 1, 32 do
		local a = chassis:FindFirstChild(("Seat%d"):format(i))
		if not a or not a:IsA("Attachment") then break end
		fromAttachments[i] = {
			offset = a.Position,
			cf = CFrame.new(a.Position),
			name = a:GetAttribute("Label") or a.Name,
		}
	end
	if #fromAttachments > 0 then return fromAttachments end

	-- 3. The def's nominal offsets.
	local fallback = {}
	for i, seat in ipairs(def.seats) do
		fallback[i] = { offset = seat.offset, cf = CFrame.new(seat.offset), name = seat.name }
	end
	return fallback
end

local function gatherWheels(model, chassis, def)
	local wheels = {}
	local container = wheelsFolder(model)

	for _, part in ipairs(container and container:GetDescendants() or {}) do
		if part:IsA("BasePart") and part ~= chassis then
			local cf = localOffset(chassis, part)
			-- WHERE YOU PUT THE WHEEL IS WHERE IT SITS AT REST. That is the
			-- only reading a modeller would expect, and the previous one --
			-- treating it as the top of the strut, with the wheel drawn half
			-- a travel BELOW it -- is why cars floated above the road: a
			-- model built with its wheels on the ground parked exactly
			-- restDrop too high.
			--
			-- The strut top is derived from it instead, which is the same
			-- geometry read the other way round.
			local rest = cf.Position
			local restRot = cf.Rotation
			table.insert(wheels, {
				part = part,
				name = part.Name,
				rest = rest,
				offset = rest + Vector3.new(0, restDrop(def), 0),
				restRot = restRot,
				radius = wheelRadiusOf(part),
				ground = wheelGroundOffset(part, restRot),
			})
		end
	end

	if #wheels == 0 then
		-- No art. Fall back to the nominal layout so a def without a model
		-- still has something to cast from.
		for _, anchor in ipairs(VehicleDefs.WheelAnchors(def)) do
			-- WheelAnchors returns strut tops, so the rest position is the
			-- one derived here rather than the other way round.
			table.insert(wheels, {
				name = anchor.name,
				rest = anchor.offset - Vector3.new(0, restDrop(def), 0),
				offset = anchor.offset,
				-- Identity: a Roblox cylinder's axle is already its own X, which
				-- on a car is sideways. See the note in Build.
				restRot = CFrame.identity,
				radius = def.wheelRadius,
				ground = def.wheelRadius,
				front = anchor.front,
			})
		end
		return wheels
	end

	-- Which axle each wheel is on. The name is authoritative when it says so,
	-- because a model can be built with its wheels anywhere; local Z decides
	-- the rest, and -Z is forward in Roblox.
	local sumZ = 0
	for _, wheel in ipairs(wheels) do sumZ += wheel.offset.Z end
	local midZ = sumZ / #wheels

	for _, wheel in ipairs(wheels) do
		local lower = string.lower(wheel.name)
		if string.sub(lower, 1, 1) == "f" then
			wheel.front = true
		elseif string.sub(lower, 1, 1) == "r" and lower ~= "right" then
			wheel.front = false
		else
			wheel.front = wheel.offset.Z < midZ
		end
	end

	return wheels
end

-- Measured once per model and cached on it. Weak keys, so a despawned vehicle
-- does not keep its rig (or its parts) alive.
function VehicleDefs.Rig(model, def)
	if not model or not model.Parent then return nil end

	local cached = rigCache[model]
	if cached and cached.chassis and cached.chassis.Parent then return cached end

	def = def or VehicleDefs.GetOrDerive(model:GetAttribute("Class"))

	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
	if not chassis or not chassis:IsA("BasePart") then return nil end
	-- Set for them: PivotTo, the seat offsets and the sweep all key off it,
	-- and a model with a Chassis but no PrimaryPart is the common near-miss.
	if not model.PrimaryPart then model.PrimaryPart = chassis end

	local wheels = gatherWheels(model, chassis, def)

	-- Wheelbase for the bicycle model: front axle to rear axle, measured.
	local frontZ, rearZ, frontN, rearN = 0, 0, 0, 0
	for _, wheel in ipairs(wheels) do
		if wheel.front then frontZ += wheel.offset.Z; frontN += 1
		else rearZ += wheel.offset.Z; rearN += 1 end
	end
	local wheelbase = (frontN > 0 and rearN > 0)
		and math.abs(rearZ / rearN - frontZ / frontN)
		or VehicleDefs.Wheelbase(def)

	local rig = {
		chassis = chassis,
		size = chassis.Size,
		wheels = wheels,
		seats = gatherSeats(model, chassis, def),
		wheelbase = math.max(wheelbase, 1),
		def = def,
	}

	rigCache[model] = rig
	return rig
end

-- The same shape, from the def's numbers alone and touching no Instances.
-- Lets the sim be exercised without a world, and is what the tests run on.
function VehicleDefs.NominalRig(def)
	local wheels = {}
	for _, anchor in ipairs(VehicleDefs.WheelAnchors(def)) do
		table.insert(wheels, {
			name = anchor.name,
			rest = anchor.offset - Vector3.new(0, restDrop(def), 0),
			offset = anchor.offset,
			restRot = CFrame.identity,
			radius = def.wheelRadius,
			ground = def.wheelRadius,
			front = anchor.front,
		})
	end

	local seats = {}
	for i, seat in ipairs(def.seats) do
		seats[i] = { offset = seat.offset, cf = CFrame.new(seat.offset), name = seat.name }
	end

	return {
		size = def.size,
		wheels = wheels,
		seats = seats,
		wheelbase = VehicleDefs.Wheelbase(def),
		def = def,
	}
end

-- How high the chassis CENTRE sits when the car is parked, measured from the
-- wheels themselves: the height at which the lowest wheel's bottom just
-- touches the ground.
--
-- The old version added up the def's numbers -- a radius, half a suspension
-- travel, half the chassis box -- which quietly assumed the wheels were at
-- the bottom face of the chassis. They are wherever the model puts them, so
-- for anything but the built-in car it was wrong, and the error showed up as
-- a car resting with its wheels in the road or hovering above it.
function VehicleDefs.RigRestHeight(rig)
	local needed = 0
	for _, wheel in ipairs(rig.wheels) do
		-- The GROUND offset, not the rolling radius: how far this wheel
		-- reaches down in chassis space. rest.Y is negative for a wheel below
		-- the chassis centre, so this is how far the centre must be above the
		-- ground for THIS wheel to touch.
		needed = math.max(needed, (wheel.ground or wheel.radius) - wheel.rest.Y)
	end
	if needed <= 0 then
		-- No wheels at all: fall back to the box, which at least keeps the
		-- chassis out of the floor.
		return rig.size.Y * 0.5
	end
	return needed
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

		-- Placed at the REST position, and not welded: only a car being driven
		-- or watched gets its wheels positioned by the suspension, so a parked
		-- one would otherwise sit with all four stacked at the chassis centre
		-- until somebody got in.
		--
		-- NO ROTATION, and the quarter turn about Z that used to be here was
		-- simply wrong. A Roblox cylinder's circular faces are on its own X,
		-- so its axle already points along X -- which on a car is sideways,
		-- exactly where a wheel's axle belongs. Turning it 90 degrees about Z
		-- stands the axle UP: a disc lying flat on the road, which then spun
		-- like a turntable, because the spin is applied about the wheel's own
		-- X after this rotation.
		wheel.CFrame = CFrame.new(
			anchor.offset - Vector3.new(0, def.suspension * (1 - VehicleDefs.RestCompression), 0))
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
