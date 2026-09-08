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

-- The one service this module touches, and only for Template below: a class
-- name has to be resolvable to the model in ReplicatedStorage.Vehicles it is
-- built from. Everything else here is arithmetic on tables.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

	-- HOW FAST THE WHEEL ITSELF MOVES, drawn. Not the same thing as the
	-- spring above, which is what holds the CAR up.
	--
	-- The two rates are deliberately different, and the difference is the
	-- whole point. A bump drives the wheel up hard and fast -- the road is
	-- doing it, and the road wins. Coming back down, nothing is pushing but
	-- the spring against the weight of the wheel, so it extends and it takes
	-- its time. A wheel that dropped into a hole instantly is a wheel with no
	-- mass and no spring, which is what it looked like.
	wheelCompressRate = 22,
	wheelExtendRate   = 7,

	-- How much of the ground's unevenness reaches the BODY.
	--
	-- The suspension normal already handles a slope -- all four wheels
	-- compress equally and the whole car tilts. What it cannot see is one
	-- side being higher than the other, because a kerb and the road beside it
	-- both point straight up: the normals agree while the heights do not.
	-- That is why the shell sat dead level with one pair of wheels on a kerb.
	--
	-- Below 1 because a car body is not rigidly bolted to its axles. 1 would
	-- be a go-kart.
	terrainLean  = 0.8,

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

	--=================================================================
	-- ENGINE AND GEARBOX
	--=================================================================
	-- Faked, in the sense that no torque curve drives the car -- the drive
	-- force is still constant and the top speed is still set by drag. What
	-- the gearbox produces is the RPM, and the RPM is what everything you
	-- can HEAR and SEE runs off: the engine note, the shift, the backfire.
	--
	-- That is the right way round for an arcade car. A real gearbox that fed
	-- back into the acceleration would mean the car's performance depended on
	-- ratios nobody wants to tune, and the difference is inaudible next to
	-- the difference the sound makes.
	horsepower   = 300,       -- see driveFromPower below; this is what HP means
	gears        = 5,
	shiftTime    = 0.18,      -- seconds of cut drive on an upshift
	idleRpm      = 800,
	redlineRpm   = 6800,
	revLimiter   = true,      -- hold at the redline in top gear rather than past it

	-- HOW FAR THE ENGINE NOTE MOVES, as multipliers on the PlaybackSpeed the
	-- sound was authored at. The rpm decides where between them it sits.
	--
	-- These exist separately from the rpm because they are not the same
	-- question. The rpm is a fact about the car; how far a sample may be
	-- stretched is a fact about the SAMPLE. A loop recorded near the redline
	-- is already a scream at 1.0, and the old fixed 0.55-to-2.2 span -- more
	-- than a factor of four, applied on top of whatever the artist set --
	-- made first gear at walking pace sound like a motorway.
	--
	-- Defaults are deliberately narrow. A real engine across its whole range
	-- is about an octave, which is a factor of two; going wider is an effect,
	-- not realism, and should be asked for.
	enginePitchMin = 0.8,     -- at idle
	enginePitchMax = 1.7,     -- at the redline
	revScale       = 1,       -- squeezes (or stretches) that span about idle

	--=================================================================
	-- TURBO
	--=================================================================
	-- Off unless the car says otherwise, because a turbo is a character
	-- decision: the spool and the valve are the two most recognisable noises
	-- a car can make, and putting them on everything makes them mean nothing.
	--
	-- Faked like the gearbox, and for the same reason -- boost here produces
	-- a NUMBER, not more power. What that number drives is the spool whine
	-- and when the blow-off valve fires, which is the whole of what a turbo
	-- contributes to how a car sounds.
	turbo         = false,

	-- Boost builds only under LOAD, which is throttle and revs together --
	-- a turbo is driven by exhaust gas, and there is none worth having at
	-- idle. Off the throttle it bleeds away whatever the revs are doing,
	-- which is why a turbo car goes quiet the instant you lift.
	turboOnset    = 0.35,     -- fraction of the rev range below which nothing spools
	turboSpoolUp  = 2.2,      -- how fast it builds, per second at full load
	turboSpoolDown = 3.4,     -- and how fast it bleeds off; lag is the gap between these

	-- Least boost worth hearing a valve for. Below it a lift is just a lift.
	bovSpool      = 0.35,

	-- Above this, an upshift spits flame. Nothing to do with the physics --
	-- it is a decision about which cars are loud, and it is a horsepower
	-- figure so it reads the way the rest of the engine numbers do.
	backfirePower = 400,

	--=================================================================
	-- SURFACES
	--=================================================================
	-- How much of the SURFACE's grip multiplier this car actually feels.
	--
	-- 1 takes the table below at face value: ice is a third of the grip of
	-- tarmac and the car is undriveable on it, which is correct and not
	-- always wanted. 0 ignores the ground entirely, which is what every car
	-- did before this existed. Between them is a car with road tyres (high)
	-- or something on knobblies that barely notices (low).
	surfaceGrip  = 1,

	--=================================================================
	-- TEMPERATURE
	--=================================================================
	-- Fake, in exactly the sense the gearbox is fake: nothing here feeds back
	-- into how the car drives. What it produces is two NUMBERS that move the
	-- way an engine's do -- coolant first and fast, oil behind it and slow --
	-- so a gauge has something true-feeling to show and a temperature warning
	-- has something to fire on.
	--
	-- Deliberately not wired into power. An engine that quietly loses output
	-- when it gets hot is a car that feels broken with no explanation, and
	-- that is a gameplay decision to make on purpose rather than a side
	-- effect of adding a gauge.
	ambientTemp  = 22,        -- what a cold car sits at, degrees
	coolantWarm  = 90,        -- normal running temperature
	coolantMax   = 120,       -- over this the gauge is in the red
	oilWarm      = 105,       -- oil runs hotter than coolant, and lags it
	oilMax       = 145,

	-- Degrees per second at FULL load, and the rate it sheds toward ambient
	-- when it is not working. Warm-up is the difference between them: a car
	-- idling gains heat_at_idle and loses coolRate, and settles wherever
	-- those meet.
	heatRate     = 9,
	coolRate     = 2.2,

	--=================================================================
	-- THE RADIATOR FAN
	--=================================================================
	-- Thermostatic, with a GAP between the two thresholds, and the gap is the
	-- whole design. One threshold chatters: the fan pulls the coolant a
	-- fraction below the line, switches off, the coolant crosses back over,
	-- and it switches on again -- several times a second. That is a fan sound
	-- that stutters and a cooling term that is neither on nor off.
	--
	-- So it cuts in HOT and drops out COOLER, and holds whatever it was in
	-- between. Both sit ABOVE normal running temperature on purpose: below it
	-- there is nothing for a fan to do, and a fan that could not switch off
	-- until the coolant fell under the thermostat's own floor would never
	-- switch off at all.
	fanOnTemp    = 97,
	fanOffTemp   = 92,

	-- What the fan is worth, on the same 0..1 scale road speed feeds. Not
	-- added to airflow but MAXED with it: a fan cannot help a radiator that
	-- already has a headwind through it, which is exactly why sitting still
	-- is the case it exists for.
	fanAirflow   = 0.85,

	-- Blades have mass. Instant is the one thing a fan is not, and hearing it
	-- wind up is most of what makes it read as a fan rather than a switch.
	fanSpinUp    = 1.6,
	fanSpinDown  = 0.9,

	--=================================================================
	-- STARTING
	--=================================================================
	-- How long the starter turns before the engine is running. Nothing drives
	-- during it -- an engine that is not running is not driving anything --
	-- and the crank sound plays over exactly this window.
	--
	-- A NUMBER rather than the length of the sample, because the sim must not
	-- depend on an asset having loaded: a car that was driveable on the
	-- machines where the sound arrived late and not on the others is worse
	-- than one that is consistently a bit out of step with its own audio.
	startTime    = 1.1,
	-- How fast the oil chases the coolant, per second. Much slower than the
	-- coolant chases its own target, and that gap is the whole point: oil is
	-- a bigger mass further from the water jacket, so it is still climbing
	-- when the coolant has settled -- and it settles hotter. A pair of gauges
	-- that move together is one gauge drawn twice.
	--
	-- 0.045 is a time constant of about twenty seconds against the coolant's
	-- eleven, which is enough for the two needles to be visibly out of step
	-- for the first half-minute of a drive.
	oilLag       = 0.045,

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

-- Horsepower to drive force.
--
-- The arcade model wants a constant acceleration in studs/s^2; the tuning
-- surface people expect on a car is horsepower. Power per unit mass is the
-- honest bridge between them -- it is what actually decides how hard a car
-- accelerates -- so a 600hp car of the same weight accelerates twice as hard,
-- and the same engine in something twice as heavy accelerates half as hard.
--
-- Anchored so the existing classes come out where they already were: 300hp in
-- 1400kg is the 26 studs/s^2 the sedan was tuned at.
local REFERENCE_POWER = 300
local REFERENCE_MASS_FOR_POWER = 1400
local REFERENCE_DRIVE = 26

function VehicleDefs.DriveFromPower(horsepower, mass)
	local powerToWeight = (horsepower / math.max(mass, 1))
		/ (REFERENCE_POWER / REFERENCE_MASS_FOR_POWER)
	return REFERENCE_DRIVE * powerToWeight
end

VehicleDefs.Classes = {
	-- The one you get from a bare `vehicle_spawn`. Deliberately middle of the
	-- road: quick enough to be worth driving, slow enough to survive a mistake.
	sedan = {
		label = "Sedan",
	},

	-- Light, short wheelbase, low grip. Slides on purpose.
	Car = {
		label      = "Car",
		bodyPitch = 0.1,
		enginePitchMin = 0.5,
		Gears = 6,
		HP = 450,
		MaxSpeed = 170,
		Redline = 6500,
		revScale = 0.5,
		ShiftTime = 0.15,
		Turbo = true,
	},

	-- Heavy, tall, understeers, rolls a lot. Slow to stop, which is the point.
	van = {
		label       = "Van",
		size        = Vector3.new(7, 4.2, 14),
		mass        = 2600,
		horsepower  = 385,      -- a lot, but it is moving 2600kg
		backfirePower = 9999,   -- and a van does not crackle on the overrun
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
	-- DRIVE FIRST, because the drag below is derived from it. Deriving drag
	-- from a drive figure that is about to be replaced leaves the car's real
	-- top speed at whatever the old one implied, which reads as horsepower
	-- being ignored.
	def.drive = VehicleDefs.DriveFromPower(def.horsepower, def.mass)

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

-- THE MODEL A CLASS IS BUILT FROM, in ReplicatedStorage.Vehicles.
--
-- One lookup rule, reachable from both VMs, because there are now three
-- callers: the spawner clones it, the tuning panel reads the attributes an
-- author put on it, and the reset path restores them. Three copies of
-- "case-insensitive, exact match wins" is three chances to disagree.
--
-- Returns the TEMPLATE, not a clone. Callers that need an instance clone it.
function VehicleDefs.Template(class)
	local library = ReplicatedStorage:FindFirstChild("Vehicles")
	if not library then return nil end

	-- Case-insensitive, because a model called "Car" and a command typed as
	-- `vehicle_spawn car` should find each other. Exact match wins so an
	-- author can still have both "Van" and "van" if they insist.
	local template = library:FindFirstChild(tostring(class))
	if not template then
		local wanted = string.lower(tostring(class))
		for _, child in ipairs(library:GetChildren()) do
			if string.lower(child.Name) == wanted then template = child break end
		end
	end

	return (template and template:IsA("Model")) and template or nil
end

-- What this car SHIPS WITH for one setting: the value the author put on the
-- template in ReplicatedStorage.Vehicles, or nil if they set none.
--
-- This is the baseline a reset should return to, and it is NOT the class
-- default. A model cloned from the library carries its author's attributes,
-- so clearing them does not restore the car -- it throws away the setup and
-- leaves whatever the class happens to say, which for a model the engine has
-- never heard of is a sedan.
function VehicleDefs.AuthoredValue(class, name)
	local template = VehicleDefs.Template(class)
	return template and template:GetAttribute(name) or nil
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

-- Where the wheel is DRAWN, easing toward where the ray says it should be.
--
-- WheelOffset above is the target and nothing more: it is a pure function of
-- this frame's raycast, so a wheel reaching a kerb or leaving a ledge snapped
-- to its new position in a single frame. Nothing on a car moves like that.
-- A wheel has mass and a spring holding it, and both take time.
--
-- Asymmetric on purpose -- see wheelCompressRate. Up is the road shoving; down
-- is a spring pushing a wheel it is barely strong enough to move.
--
-- `contacts` present but this wheel missing from it means AIRBORNE, and an
-- airborne wheel hangs at full droop. `contacts` absent entirely means we have
-- no information -- an observed car, drawn from a packet that does not carry
-- them -- and the honest answer there is the rest position, not full droop:
-- guessing droop would leave every other player's car with its wheels hanging.
function VehicleDefs.WheelTravel(def, wheel, contact, dt, known)
	local target
	if contact then
		target = VehicleDefs.WheelOffset(def, wheel, contact)
	elseif known then
		target = def.suspension * VehicleDefs.RestCompression   -- full droop
	else
		target = 0
	end

	local current = wheel.travel
	if current == nil or not dt or dt <= 0 then
		wheel.travel = target
		return target
	end

	local rate = (target > current)
		and (def.wheelExtendRate or 7)      -- dropping away from the body
		or (def.wheelCompressRate or 22)    -- being pushed up into it

	wheel.travel = current + (target - current) * math.clamp(rate * dt, 0, 1)
	return wheel.travel
end

-- The lean the WHEELS are asking the body for, in degrees, as roll and pitch.
--
-- Measured from how far each corner's suspension has moved, not from the
-- surface normals: a kerb and the road beside it both point straight up, so
-- the normals agree while the heights do not. Reading the normals is why a
-- car with two wheels up a kerb sat perfectly level.
--
-- Returns 0, 0 on a uniform slope, which is correct and not a coincidence:
-- all four wheels compress the same amount there, and the tilt is already
-- handled by the chassis lying along the surface normal. This is only ever
-- the DIFFERENCE between corners -- the articulation.
function VehicleDefs.AxleLean(def, wheels, wheelbase)
	local frontSum, frontCount, rearSum, rearCount = 0, 0, 0, 0
	local leftSum, leftCount, rightSum, rightCount = 0, 0, 0, 0

	for _, wheel in ipairs(wheels) do
		local travel = wheel.travel or 0

		if wheel.front then
			frontSum, frontCount = frontSum + travel, frontCount + 1
		else
			rearSum, rearCount = rearSum + travel, rearCount + 1
		end

		-- Local +X is the car's right.
		if wheel.rest.X < 0 then
			leftSum, leftCount = leftSum + travel, leftCount + 1
		else
			rightSum, rightCount = rightSum + travel, rightCount + 1
		end
	end

	local function mean(sum, count) return count > 0 and sum / count or 0 end

	-- Divided by the distance between the corners, because the same height
	-- difference is a far bigger angle on a narrow car than a wide one --
	-- that is what makes this an angle rather than a number that happens to
	-- look right on the vehicle it was tuned against.
	local track = math.max(def.size.X, 0.5)
	-- The rig's measured wheelbase when there is one; the box's length is the
	-- fallback, and it is only ever a fallback -- a car whose wheels are not
	-- at its corners would get the wrong angle from it.
	local base = math.max(wheelbase or def.size.Z, 0.5)

	local scale = def.terrainLean or 1

	-- SIGNS. Both are stated as what the body DOES, because working them back
	-- from Roblox's rotation conventions is how this engine has now got a sign
	-- wrong four separate times.
	--
	-- The angles are applied as CFrame.Angles(pitch, 0, roll) on the chassis
	-- frame, where +X is the car's right and forward is -Z. A positive roll
	-- carries +X toward +Y, so it lifts the RIGHT side; a positive pitch
	-- carries -Z toward +Y, so it lifts the NOSE.
	--
	-- More travel at a corner means the ground is further away there, so that
	-- corner's end of the body should drop toward it:
	--
	--   left wheels extended  -> the left side goes down -> right side up
	--                         -> POSITIVE roll   (left minus right)
	--   front wheels extended -> the nose goes down
	--                         -> NEGATIVE pitch  (rear minus front)
	--
	-- The rig harness asserts both by measuring where a point on the body
	-- actually ends up, rather than by restating this paragraph.
	local roll = math.deg(math.atan(
		(mean(leftSum, leftCount) - mean(rightSum, rightCount)) / track)) * scale
	local pitch = math.deg(math.atan(
		(mean(rearSum, rearCount) - mean(frontSum, frontCount)) / base)) * scale

	return roll, pitch
end

-- Every BasePart a wheel is built from -- the one the sim measures first, then
-- anything held rigid to it.
--
-- The server anchors what this returns. A part it misses is a part Roblox goes
-- on simulating while the engine moves the car by CFrame around it, which
-- looks exactly like the wheel falling off.
function VehicleDefs.WheelParts(wheel)
	local parts = {}
	if wheel.part then table.insert(parts, wheel.part) end
	for _, extra in ipairs(wheel.extras or {}) do
		if extra.part then table.insert(parts, extra.part) end
	end
	return parts
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

-- The parts of a wheel that are NOT the one the sim measures: a rim, a brake
-- disc, a hub cap. Recorded with their offset from the measured part so they
-- can be drawn rigid to it.
--
-- They have to be recorded at all because of what happens to a part this
-- system does not know about. Nothing draws it, so it does not follow the
-- car; and the server anchors what the rig lists, so an unlisted part is left
-- unanchored and Roblox drops it on the floor. That is the bug this exists to
-- stop -- wheels visibly falling off a moving car.
--
-- The WHOLE SUBTREE, including when the holder IS the measured part. The
-- natural way to build a wheel here is a plain transparent cylinder with the
-- detailed rim parented inside it, so that the rim turns and rolls with the
-- collision shape -- which is to say the commonest layout of all is the one
-- where holder and part are the same object. Skipping that case dropped every
-- rim on the road.
local function gatherExtras(holder, part)
	if not holder then return nil end

	local extras
	for _, other in ipairs(holder:GetDescendants()) do
		if other:IsA("BasePart") and other ~= part then
			extras = extras or {}
			table.insert(extras, { part = other, cf = localOffset(part, other) })
		end
	end
	return extras
end

local function gatherWheels(model, chassis, def)
	local wheels = {}
	local container = wheelsFolder(model)

	-- DIRECT CHILDREN, not descendants. A wheel is a thing you hang other
	-- things off -- a smoke emitter, a broken-wheel mesh to swap in, a brake
	-- disc -- and walking the whole subtree turns every one of those into
	-- another wheel. Four wheels with a mesh inside each became eight, and
	-- since the ride height is decided by whichever reaches lowest, one stray
	-- child was enough to park the car wrong and cast rays from inside itself.
	--
	-- A child that is not itself a part is followed INTO, because ignoring it
	-- is worse than counting it twice. Every part the rig does not find is a
	-- part nothing anchors and nothing draws -- so a wheel modelled as an
	-- assembly, or one whose Model has no PrimaryPart set, was left behind by
	-- the chassis and dropped through the world under Roblox's own physics.
	-- Wheels falling off is a more visible failure than a car parked an inch
	-- high, and it is the one this cost.
	--
	-- PrimaryPart first, since that is the modeller SAYING which part is the
	-- wheel; failing that, the biggest part in the subtree, which for a wheel
	-- assembly is the tyre and not the brake disc or the lug nuts.
	local function wheelPartOf(child)
		if child:IsA("BasePart") then return child end

		local best, bestVolume = nil, -1
		if child:IsA("Model") and child.PrimaryPart then return child.PrimaryPart end
		for _, part in ipairs(child:GetDescendants()) do
			if part:IsA("BasePart") then
				local size = part.Size
				local volume = size.X * size.Y * size.Z
				if volume > bestVolume then
					best, bestVolume = part, volume
				end
			end
		end
		return best
	end

	-- One entry per wheel-shaped child. A FOLDER is a grouping rather than a
	-- wheel -- somebody who puts their fronts and rears in subfolders means
	-- four wheels, not two -- so folders are flattened and everything else is
	-- a candidate.
	local candidates = {}
	local function collect(node)
		for _, child in ipairs(node:GetChildren()) do
			if child:IsA("Folder") then
				collect(child)
			else
				table.insert(candidates, child)
			end
		end
	end
	if container then collect(container) end

	for _, child in ipairs(candidates) do
		local part = wheelPartOf(child)
		if part and part ~= chassis then
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
				-- The CHILD, not the part, so a wheel built as a Model has
				-- its emitters found under the thing you actually named.
				holder = child,
				-- Everything else the wheel is made of, held rigid to the
				-- part above. See gatherExtras.
				extras = gatherExtras(child, part),
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

--=====================================================================
-- GEARBOX
--=====================================================================
-- The band of road speed a gear covers. Geometric rather than even, because
-- first gear on a real car is short and top gear is long: at five gears, 1st
-- reaches about a seventh of top speed and 5th covers the last quarter.
--
-- Nothing here feeds back into the physics. The gearbox exists to produce an
-- RPM, and the RPM is what the engine note, the shift and the backfire run
-- off -- see the note on the def fields.
local GEAR_SPREAD = 1.35

function VehicleDefs.GearTop(def, gear)
	local n = math.max(def.gears, 1)
	return def.topSpeed * (math.clamp(gear, 0, n) / n) ^ GEAR_SPREAD
end

-- Where in its gear the engine is, 0 at the bottom of the band and 1 at the
-- top. Above 1 means the gear has run out and it is time to shift up.
function VehicleDefs.GearFraction(def, gear, speed)
	local low = VehicleDefs.GearTop(def, gear - 1)
	local high = VehicleDefs.GearTop(def, gear)
	if high - low < 1e-3 then return 0 end
	return (math.abs(speed) - low) / (high - low)
end

-- Where the revs land at the BOTTOM of a gear, as a fraction of the way from
-- idle to the redline. A gearbox is chosen so the next gear picks up in the
-- meat of the power, not at a standstill -- so an upshift drops the engine to
-- here, not to idle.
--
-- Mapping the band straight onto idle-to-redline is the obvious version and
-- it sounds wrong: every shift cuts the engine to a tickover for an instant,
-- as though it had stalled and caught again.
local IN_GEAR_FLOOR = 0.35

-- Engine speed for a given gear and road speed.
function VehicleDefs.RpmFor(def, gear, speed)
	local span = def.redlineRpm - def.idleRpm
	local fraction = math.clamp(VehicleDefs.GearFraction(def, gear, speed), 0, 1.05)
	local inGear = def.idleRpm + span * (IN_GEAR_FLOOR + (1 - IN_GEAR_FLOOR) * fraction)

	-- Below walking pace the engine is idling rather than lugging: a car at a
	-- standstill in first should tick over, not sit at a third of its redline.
	local rolling = math.clamp(math.abs(speed) / 4, 0, 1)
	return def.idleRpm + (inGear - def.idleRpm) * rolling
end

-- Playback speed for the engine loop at a given rpm, as a MULTIPLIER on
-- whatever the sound was authored at.
--
-- Returned as a multiplier rather than an absolute speed so the artist's own
-- PlaybackSpeed still means something: a loop recorded at high revs is set to
-- 0.5 in Studio and everything here follows it, instead of being stretched
-- from a value this code invented.
--=====================================================================
-- SURFACES
--=====================================================================
-- What the ground under a WHEEL does to the grip that wheel has.
--
-- Read per wheel, not per car, and that is the whole point: two wheels on
-- tarmac and two in the grass is a car that pulls to one side and steps out
-- of a corner, and averaging the four into one number throws away the only
-- interesting thing about driving off the road.
--
-- Multipliers against tarmac at 1. They are tuned by feel rather than derived
-- from anything -- what matters is the ORDER and roughly how far apart the
-- rungs are, and a real coefficient of friction would not make a Roblox car
-- feel more like a car.
--
-- Built by NAME through pcall, because Enum.Material gains members over time
-- and indexing one this client does not have is an error, not a nil. A
-- material missing here is a material at 1, which is the safe way round: an
-- unknown surface drives like a road rather than like ice.
local SURFACE_GRIP = {}

do
	local byName = {
		-- Sealed road, and the reference everything else is quoted against.
		Asphalt = 1,       Concrete = 1,      Pavement = 0.98,
		Brick = 0.96,      Cobblestone = 0.92,
		Metal = 0.95,      DiamondPlate = 0.95,  CorrodedMetal = 0.88,
		Marble = 0.85,     Granite = 0.95,    Slate = 0.9,
		Plastic = 1,       SmoothPlastic = 1, Neon = 1,
		Glass = 0.7,       ForceField = 1,

		-- Loose. Enough grip to drive on, not enough to corner hard.
		Grass = 0.72,      LeafyGrass = 0.66,  Ground = 0.75,
		Sand = 0.55,       Salt = 0.6,         Sandstone = 0.85,
		Rock = 0.88,       Basalt = 0.88,      Limestone = 0.9,
		Pebble = 0.7,      WoodPlanks = 0.9,   Wood = 0.9,
		Fabric = 0.85,     Cardboard = 0.8,    Carpet = 0.85,

		-- The ones you notice.
		Mud = 0.45,        Snow = 0.4,        Ice = 0.28,
		Glacier = 0.3,     Water = 0.35,      CrackedLava = 0.8,
	}

	for name, value in pairs(byName) do
		pcall(function() SURFACE_GRIP[Enum.Material[name]] = value end)
	end
end

VehicleDefs.SurfaceGrip = SURFACE_GRIP

-- The multiplier for one wheel's contact, with the car's own sensitivity
-- already folded in.
--
-- `response` is def.surfaceGrip: 1 takes the table at face value, 0 ignores
-- the ground entirely, which is what every car did before this existed.
-- Interpolating rather than switching means a car can be made to care a
-- little, and means turning the feature off is a value rather than a branch.
function VehicleDefs.GripFor(material, response)
	local base = material and SURFACE_GRIP[material] or 1
	if base == 1 then return 1 end

	local weight = math.clamp(response or 1, 0, 1)
	return 1 + (base - 1) * weight
end

-- The name of a material, for a readout. Enum items stringify as
-- "Enum.Material.Ice", which is three words too long for a debug row.
function VehicleDefs.MaterialName(material)
	if not material then return "air" end
	local ok, name = pcall(function() return material.Name end)
	return (ok and name) or tostring(material)
end

--=====================================================================
-- TEMPERATURE
--=====================================================================

-- Coolant and oil, stepped one tick.
--
-- The model is two first-order lags chasing a target that load moves, which
-- is enough to reproduce everything a temperature gauge is actually for: a
-- cold car that takes a minute to come up, a hot lap that pushes past normal,
-- and a slow fall back when you park.
--
-- COOLANT leads. It is a small mass in direct contact with the block, so it
-- moves first and it is what a warning light is wired to. OIL is a bigger
-- mass further away: it lags, it ends up hotter, and the gap between the two
-- is what makes a pair of gauges worth having rather than one drawn twice.
--
-- `load` is 0..1 -- what the engine is being asked for, not what the car is
-- doing. A car sitting at the redline against a wall is working just as hard
-- as one doing it at speed, and cools worse for not moving.
-- `running` is whether the engine is turning over under its own power. False
-- while the starter is still cranking, and the difference is not a detail: an
-- engine that is not running makes NO heat, so the thermostat has nothing to
-- hold and the whole thing is just cooling toward the air around it.
--
-- Defaulted to true, because every caller that predates this had a running
-- engine and saying so at each of them would be noise.
function VehicleDefs.StepTemperature(def, coolant, oil, load, airflow, dt, running)
	if not (dt and dt > 0) then return coolant or def.ambientTemp, oil or def.ambientTemp end

	local ambient = def.ambientTemp or 22
	coolant = coolant or ambient
	oil = oil or ambient

	load = math.clamp(load or 0, 0, 1)
	-- Airflow through the radiator. Standing still in traffic is how a real
	-- car overheats, and without this the only thing that mattered would be
	-- the throttle.
	airflow = math.clamp(airflow or 0, 0, 1)

	-- Where the coolant would end up if this were held forever.
	--
	-- NORMAL RUNNING IS THE FLOOR, not a place hard driving eventually
	-- reaches. That is what a thermostat does: it holds the coolant at its
	-- rated temperature whatever the engine is doing, and only once the
	-- radiator cannot reject the heat does the number climb past it. The
	-- previous version made the floor depend on load, so an idling car
	-- settled thirty degrees cold and the fan could never come on -- which is
	-- the opposite of what idling in traffic does to a real engine.
	--
	-- Above the floor, two terms:
	--   LOAD    how much heat is being made
	--   AIRFLOW how much is being carried away, and the fan feeds this
	--
	-- The airflow term is scaled BY LOAD as well as standing on its own. The
	-- standalone part is what makes idling in traffic get hot -- a radiator
	-- with no air through it cannot reject even idle heat -- and the
	-- load-scaled part is what makes the red zone reachable at all: an engine
	-- held at the redline with nothing moving past it is the one case that
	-- should cook, and a curve whose maximum fell short of the ceiling would
	-- make coolantMax a colour on a gauge that nothing can ever produce.
	--
	-- Read against the thresholds, with the shipped numbers:
	--   idling, no air          99      over the 97 the fan cuts in at
	--   idling, fan running     91      under the 92 it drops out at
	--   cruising                95      never needs it
	--   driving hard           104      does, and it stays on
	--   revving, stood still   120      the red, and only here
	--   revving, fan running   106      which is what the fan is for
	local warm = def.coolantWarm or 90
	local ceiling = def.coolantMax or 120

	local target
	if running == false then
		-- Nothing is making heat. A stopped engine has one destination.
		target = ambient
	else
		target = warm + (ceiling - warm) * math.clamp(
			load * 0.45 + (1 - airflow) * (0.3 + load * 0.25), 0, 1)
	end

	-- Approach it, faster when heating than when cooling: an engine makes
	-- heat much more quickly than it sheds it, which is why a hard lap warms
	-- a car in seconds and a cool-down lap takes minutes.
	local rate = (target > coolant) and (def.heatRate or 9) or (def.coolRate or 2.2)
	local span = math.max(ceiling - ambient, 1)
	coolant += (target - coolant) * math.clamp(rate * dt / span, 0, 1)

	-- The oil chases the COOLANT rather than the load, offset by how much
	-- hotter it runs. That is what makes it lag without needing its own idea
	-- of what the engine is doing.
	local oilTarget = ambient + (coolant - ambient)
		* ((def.oilWarm or 105) - ambient) / math.max(warm - ambient, 1)
	oil += (oilTarget - oil) * math.clamp((def.oilLag or 0.35) * dt, 0, 1)

	return coolant, oil
end

-- The radiator fan, stepped one tick. Returns whether it is RUNNING and how
-- fast the blades are actually going.
--
-- Two values because they answer different questions. The switch is
-- thermostatic and instant; the blades take a moment to reach speed, and it
-- is the blade speed that both the sound and the cooling should follow -- a
-- fan that cooled at full effect on the frame it switched on would drop the
-- coolant in a step.
--
-- `on` is carried IN as well as out: between the two thresholds the answer is
-- "whatever it was already", and that holding is the hysteresis.
function VehicleDefs.StepFan(def, coolant, on, speed, dt)
	coolant = coolant or def.ambientTemp or 22
	speed = speed or 0

	local onAt = def.fanOnTemp or 97
	local offAt = def.fanOffTemp or 92

	if coolant >= onAt then
		on = true
	elseif coolant <= offAt then
		on = false
	end
	-- Between them: unchanged. Deliberately no else.

	if dt and dt > 0 then
		local target = on and 1 or 0
		local rate = on and (def.fanSpinUp or 1.6) or (def.fanSpinDown or 0.9)
		speed += (target - speed) * math.clamp(rate * dt, 0, 1)
	end

	return on == true, speed
end

-- Air through the radiator, from the road and the fan together.
--
-- MAXED rather than added: a fan cannot help a radiator that already has a
-- headwind going through it, which is exactly why standing still is the case
-- it exists for. Adding them would make a fan at speed cool better than
-- physics allows, and would hide the one behaviour worth having.
function VehicleDefs.Airflow(def, roadAirflow, fanSpeed)
	return math.max(
		math.clamp(roadAirflow or 0, 0, 1),
		math.clamp(fanSpeed or 0, 0, 1) * (def.fanAirflow or 0.85))
end

-- 0 cold, 1 at normal running, above 1 into the red. What a gauge needle and
-- a warning colour both want, so neither has to know the numbers.
function VehicleDefs.HeatFraction(def, value, which)
	local ambient = def.ambientTemp or 22
	local warm = (which == "oil") and (def.oilWarm or 105) or (def.coolantWarm or 90)
	return ((value or ambient) - ambient) / math.max(warm - ambient, 1)
end

function VehicleDefs.Overheating(def, coolant, oil)
	return (coolant or 0) >= (def.coolantMax or 120)
		or (oil or 0) >= (def.oilMax or 145)
end

function VehicleDefs.EnginePitch(def, rpm)
	local span = math.max(def.redlineRpm - def.idleRpm, 1)
	local fraction = math.clamp(((rpm or def.idleRpm) - def.idleRpm) / span, 0, 1)

	local lo = def.enginePitchMin or 0.8
	local hi = lo + ((def.enginePitchMax or 1.7) - lo) * (def.revScale or 1)
	return lo + (hi - lo) * fraction
end

-- Where the boost goes next, 0 to 1.
--
-- Pure, so the whole of a turbo's behaviour can be tested without a Sound in
-- the room: how long it takes to come on song, that it does not spool at idle
-- however hard you press, and that it dumps the moment you lift.
--
-- The lag people mean when they say "turbo lag" is the gap between the two
-- rates: building is deliberately slower than bleeding, so a lift-and-back-on
-- costs you the boost and the time to make it again.
function VehicleDefs.TurboSpool(def, spool, throttle, rpm, dt)
	if not def.turbo then return 0 end
	spool = spool or 0

	local span = math.max(def.redlineRpm - def.idleRpm, 1)
	local revs = math.clamp(((rpm or def.idleRpm) - def.idleRpm) / span, 0, 1)

	local onset = def.turboOnset or 0
	local load = math.clamp(throttle or 0, 0, 1)
		* math.clamp((revs - onset) / math.max(1 - onset, 1e-3), 0, 1)

	local rate = (load > spool) and (def.turboSpoolUp or 2) or (def.turboSpoolDown or 3)
	return math.clamp(spool + (load - spool) * math.clamp(rate * dt, 0, 1), 0, 1)
end

--=====================================================================
-- ATTRIBUTE TUNING
--=====================================================================
-- Anything in the def can be overridden by an attribute of the same name on
-- the vehicle MODEL. Set MaxSpeed to 130 on your Car and that car does 130,
-- whatever its class says, with no code change and no new class.
--
-- Friendly names first, because nobody opening the Properties panel wants to
-- type "topSpeed" or guess that "drive" is measured in studs per second
-- squared. The right-hand side is the field it actually sets.
-- FRIENDLY NAMES for the fields, as they appear in Studio's attribute panel.
--
-- Every core field is reachable, and that is the contract: if a number
-- decides how a car drives, sounds or looks, you can set it on the model
-- without touching a script. Aliases exist for the ones whose internal name
-- is jargon -- nobody types `topSpeed` when the box says MaxSpeed -- but the
-- exact field name always works too, so a field with no alias here is still
-- tunable rather than being a hidden second class of knob.
local ATTRIBUTE_ALIASES = {
	-- Identity and mass
	Label         = "label",
	Mass          = "mass",
	Weight        = "mass",

	-- Engine
	HP            = "horsepower",
	Horsepower    = "horsepower",
	Power         = "horsepower",
	Gears         = "gears",
	GearShiftSpeed= "shiftTime",
	ShiftTime     = "shiftTime",
	Redline       = "redlineRpm",
	RevLimit      = "redlineRpm",
	RevLimiter    = "revLimiter",
	Idle          = "idleRpm",
	IdleRPM       = "idleRpm",
	BackfirePower = "backfirePower",
	RevScale      = "revScale",
	EnginePitchMin = "enginePitchMin",
	EnginePitchMax = "enginePitchMax",

	-- Speed and drive
	MaxSpeed      = "topSpeed",
	TopSpeed      = "topSpeed",
	Reverse       = "reverse",
	TopReverse    = "topReverse",
	MaxReverse    = "topReverse",
	Brakes        = "brake",
	Drag          = "dragLinear",
	RollingDrag   = "dragLinear",

	-- Grip and handling
	Grip          = "grip",
	Balance       = "balance",
	HandbrakeGrip = "handbrakeGrip",
	GripResponse  = "gripResponse",
	LoadTransfer  = "loadTransfer",
	Understeer    = "understeer",
	SurfaceGrip   = "surfaceGrip",

	-- Steering
	Steering      = "steerAngle",
	SteerAngle    = "steerAngle",
	SteerSpeed    = "steerSpeed",
	SteerRate     = "steerRate",
	SteerReturn   = "steerReturn",

	-- Suspension and body
	Suspension    = "suspension",
	SpringHz      = "springHz",
	SpringDamp    = "springDamp",
	WheelCompressRate = "wheelCompressRate",
	WheelExtendRate = "wheelExtendRate",
	TerrainLean   = "terrainLean",
	WheelRadius   = "wheelRadius",
	WheelWidth    = "wheelWidth",
	BodyRoll      = "bodyRoll",
	BodyPitch     = "bodyPitch",
	BodyHz        = "bodyHz",
	BodyDamp      = "bodyDamp",
	Restitution   = "restitution",
	CrashLoss     = "crashLoss",

	-- Turbo
	Turbo         = "turbo",
	TurboSpoolUp  = "turboSpoolUp",
	TurboSpoolDown = "turboSpoolDown",
	TurboOnset    = "turboOnset",
	BOVSpool      = "bovSpool",

	-- Starting
	StartTime     = "startTime",
	CrankTime     = "startTime",

	-- Temperature
	AmbientTemp   = "ambientTemp",
	CoolantWarm   = "coolantWarm",
	CoolantMax    = "coolantMax",
	OilWarm       = "oilWarm",
	OilMax        = "oilMax",
	HeatRate      = "heatRate",
	CoolRate      = "coolRate",
	OilLag        = "oilLag",
	FanOnTemp     = "fanOnTemp",
	FanOffTemp    = "fanOffTemp",
	FanAirflow    = "fanAirflow",
	FanSpinUp     = "fanSpinUp",
	FanSpinDown   = "fanSpinDown",
}

VehicleDefs.AttributeAliases = ATTRIBUTE_ALIASES

-- Every name that can be written on a model, with the field it sets and the
-- value it currently has. What a tuning panel enumerates, and what
-- `vehicle_attrs` prints -- so "which knobs are there" has one answer rather
-- than being a thing you find out by reading this file.
--
-- Sorted, because an editor that reorders its own rows between openings is
-- an editor you cannot use.
function VehicleDefs.TunableList(def)
	def = def or DEFAULTS

	local seen, out = {}, {}
	for name, field in pairs(ATTRIBUTE_ALIASES) do
		if def[field] ~= nil and not seen[name] then
			seen[name] = true
			table.insert(out, { name = name, field = field, value = def[field] })
		end
	end

	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

-- The field an attribute name sets, or nil if it sets nothing. The exact
-- field name counts as its own alias.
function VehicleDefs.FieldFor(name, def)
	if type(name) ~= "string" then return nil end
	local field = ATTRIBUTE_ALIASES[name]
	if field then return field end
	if (def or DEFAULTS)[name] ~= nil then return name end
	return nil
end

-- Applied to a COPY, so one car's attributes never leak into the class every
-- other car of that class is built from.
function VehicleDefs.ApplyAttributes(def, model)
	if not model then return def end

	local attributes = model:GetAttributes()
	if not attributes then return def end

	local tuned, touched = {}, false
	for k, v in pairs(def) do tuned[k] = v end

	for name, value in pairs(attributes) do
		local field = ATTRIBUTE_ALIASES[name]
		-- An exact field name works too, so anything without a friendly alias
		-- is still reachable rather than being a hidden second class of knob.
		if not field and def[name] ~= nil and type(def[name]) == type(value) then
			field = name
		end

		if field and def[field] ~= nil and type(value) == type(def[field]) then
			tuned[field] = value
			touched = true
		end
	end

	if not touched then return def end

	-- Re-derived, because both of these are computed FROM fields the
	-- attributes may have just changed. Setting MaxSpeed without redoing the
	-- drag would leave the car's real top speed at whatever the class said,
	-- which is the sort of thing that looks like the attribute being ignored.
	tuned.drive = VehicleDefs.DriveFromPower(tuned.horsepower, tuned.mass)
	tuned.dragQuad = math.max(tuned.drive - tuned.dragLinear * tuned.topSpeed, 0.01)
		/ (tuned.topSpeed * tuned.topSpeed)
	tuned.yawResponse = YAW_RESPONSE_AT_REFERENCE * (REFERENCE_MASS / math.max(tuned.mass, 1))

	return tuned
end

-- Measured once per model and cached on it. Weak keys, so a despawned vehicle
-- does not keep its rig (or its parts) alive.
function VehicleDefs.Rig(model, def)
	if not model or not model.Parent then return nil end

	local cached = rigCache[model]
	if cached and cached.chassis and cached.chassis.Parent then return cached end

	local baseDef = def or VehicleDefs.GetOrDerive(model:GetAttribute("Class"))

	-- Per-car tuning from the model's own attributes, applied HERE so there
	-- is one place a def becomes final. Everything downstream reads rig.def
	-- rather than the class it started from, which is what makes setting
	-- MaxSpeed on one Car in Studio actually change that car.
	def = VehicleDefs.ApplyAttributes(baseDef, model)

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
		-- THE UNTUNED DEF, kept so a retune can start from it.
		--
		-- Re-applying attributes to an already-tuned def is subtly wrong in
		-- one direction that matters: DELETING an attribute would then leave
		-- the last value it had, because nothing remembers what the class
		-- said. Live tuning without this is a one-way trip.
		baseDef = baseDef,
	}

	rigCache[model] = rig
	return rig
end

-- Re-read the model's attributes into an existing rig, in place.
--
-- IN PLACE is the point: the rig is cached per model and handed out by
-- reference, so every holder of it -- the client sim, the server's settle
-- pass, the effects layer -- sees the new numbers without being told. A
-- version that returned a fresh rig would retune only whoever called it.
--
-- The geometry is deliberately NOT re-measured. Attributes tune how a car
-- behaves, not what parts it is made of, and re-walking the model on every
-- keystroke of a tuning panel is a GetDescendants per character typed.
--
-- Returns the def, so a caller holding its own reference can refresh it.
function VehicleDefs.Retune(rig, model)
	if not (rig and model) then return rig and rig.def end
	rig.def = VehicleDefs.ApplyAttributes(rig.baseDef or rig.def, model)
	return rig.def
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
		-- Nothing tuned it, so the base and the live def are the same table.
		-- Set anyway, so Retune works on a nominal rig rather than being a
		-- thing that only functions on rigs built from real models.
		baseDef = def,
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