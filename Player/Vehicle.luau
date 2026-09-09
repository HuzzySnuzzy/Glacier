-- ModuleScript: Vehicle
-- Parent: Player (the LocalScript's module folder)
--
-- Driving, on the client that is doing it. Same shape as Physics: a fixed
-- timestep sim, a render interpolation on top, and Config for every number.
--
-- THREE ROLES, and this module is exactly one of them at a time:
--   none      you are on foot. All this does is watch for +use near a car.
--   driver    you own the sim. It runs, and the result goes to the server.
--   passenger you are seated in someone else's car. You ride the interpolated
--             transform and can get out.
-- Every vehicle you are NOT in is an observer case, handled by the same
-- interpolation as remote puppets.
--
-- THE MODEL, and why it is not a rigid body:
--
--   Position and velocity are full 3D and integrated honestly, with gravity
--   and a swept box against the world. That part is a rigid body.
--
--   YAW comes from a bicycle model -- yawRate = speed/wheelbase * tan(steer)
--   -- plus a slip term. Not from torque about an inertia tensor.
--
--   PITCH and ROLL are integrated as angles with rates, from ONE question:
--   does the car's weight still land between the wheels holding it up? See
--   VehicleDefs.TipAccel. Not from torque about an inertia tensor either, but
--   they are state rather than decoration -- a car that leaves a ramp
--   rotating is still rotating when it lands.
--
-- They USED to be drawn: a bounded spring on the shell, on the reasoning that
-- a car's attitude is almost entirely a suspension artefact. That is true
-- right up to the two moments everybody expects a car to fall over, and it
-- could do neither -- you could corner at any speed you liked, and you could
-- park with half the car over a cliff and hang there perfectly level.
--
-- What is kept from that reasoning is the shape of the model rather than its
-- conclusion. There is still no inertia tensor and no contact solver; there
-- is a support polygon, a centre of gravity, and gravity about whichever
-- wheels are still down. That is enough for a swerve to put a car on its
-- roof and for a ledge to pitch it in nose-first, and it costs none of the
-- stability a real solver would.
--
-- What it still gives up, stated plainly: a collision does not impart spin,
-- and nothing here knows about hitting a kerb. `vehicle_flip` remains, for
-- the car that ends up on its roof and stays there.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config      = require(ReplicatedStorage:WaitForChild("Config"))
local VehicleDefs = require(ReplicatedStorage:WaitForChild("VehicleDefs"))
local VehicleFX   = require(script.Parent.VehicleFX)
local State       = require(script.Parent.State)
local Interact    = require(script.Parent.Interact)
local Input       = require(script.Parent.Input)

local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera

local Vehicle = {}

--=====================================================================
-- REMOTES
--=====================================================================

local remotes = {}

-- Looked up lazily and re-looked-up on a miss. A cached nil from a load-time
-- WaitForChild is how the weapon pickup silently died the first time; the
-- server's remotes simply do not exist yet when this module is required.
local function remote(name)
	local found = remotes[name]
	if found and found.Parent then return found end

	found = ReplicatedStorage:FindFirstChild(name)
	remotes[name] = found
	return found
end

--=====================================================================
-- LOCAL STATE
--=====================================================================

-- The car this client is simulating, when it is the driver.
local sim = nil        -- { model, chassis, def, cf, vel, yaw, steer, ... }
local seatIndex = nil  -- which seat we occupy, nil when on foot
local seatModel = nil  -- the model we occupy, driver or not

-- Every vehicle anyone else is driving, keyed by model, for interpolation.
local observed = {}

local accumulator = 0

-- Declared up here because onStateChange clears it on exit and is defined
-- above the camera block. A `local camPos` further down would be a SECOND
-- variable and the reset would silently do nothing -- the same shadowing bug
-- that nil'd every repaintInput call in the console.
local camPos = nil

-- Set from the last enter attempt so the same key press cannot immediately ask
-- again. The server throttles too; this stops the request being SENT.
local nextRequestAt = 0

Vehicle.stepCount = 0

--=====================================================================
-- HELPERS
--=====================================================================

local function num(v, fallback)
	return (type(v) == "number" and v == v) and v or fallback
end

-- Exponential approach that is correct at any dt, unlike `a + (b-a) * k * dt`
-- which changes its rate with the frame rate and overshoots below 1/k.
local function approach(current, target, rate, dt)
	if rate <= 0 then return target end
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

-- A damped harmonic oscillator, stepped once. Returns the new value and rate.
--
-- The difference from `approach` is the whole point and is not a nuance: an
-- exponential approach is FIRST order and can only ever ease toward its target
-- and stop. This is second order -- it carries a rate, so it arrives with
-- momentum, goes past, and comes back. Under damping 1 it rings; at or above
-- it, it does not.
--
-- Module level rather than a closure inside the step, so it can be exercised
-- on its own. Through the sim the only observable is the angle against a
-- target that is itself moving, and a first-order lag looks exactly like
-- overshoot there -- which is how a lerp passed the first version of the test
-- that was meant to catch it.
local function dampedSpring(value, rate, target, hz, damping, dt)
	local omega = 2 * math.pi * hz
	local accel = (target - value) * omega * omega - rate * (2 * damping * omega)
	rate += accel * dt
	return value + rate * dt, rate
end

-- EVERYONE ELSE SITTING IN THIS CAR.
--
-- A passenger is parked at their seat, INSIDE the chassis, every frame -- and
-- on the driver's machine they arrive as a remote Puppet, which is a solid,
-- queryable R6 rig unless the server happened to spawn a custom model. So the
-- depenetration pass found a body inside the car and shoved the car off it;
-- the passenger, being bolted to the seat, came with it; and the next frame
-- found the same overlap again. That feedback loop is the car "spazzing out"
-- the moment a second player gets in, and it cannot happen with one occupant
-- because the driver's own body and puppet were already excluded below.
--
-- Read off the SEAT ATTRIBUTES, which are the server's record of who is in
-- what and replicate to everybody, so every client works this out the same
-- way and nothing new has to go over the wire.
--
-- Excluding the RawBody covers the Puppet too: it is a child, and the filter
-- is by descendant.
local function addOccupants(model, seatCount, ignore)
	for i = 1, seatCount do
		local id = model:GetAttribute(("Seat%d"):format(i))
		if type(id) == "number" and id ~= 0 and id ~= plr.UserId then
			local body = workspace:FindFirstChild(id .. "RawBody")
			if body then table.insert(ignore, body) end
		end
	end
end

local function castParams(model, seatCount)
	local p = RaycastParams.new()
	local ignore = { model }

	-- Our own body and puppet: while driving they are parked INSIDE the car,
	-- so leaving them in would have every suspension ray hit the driver.
	if State.playerBody then table.insert(ignore, State.playerBody) end
	if State.playerPuppet then table.insert(ignore, State.playerPuppet) end

	if seatCount then addOccupants(model, seatCount, ignore) end

	-- Dropped weapons, for the same reason the player hull ignores them: a
	-- rifle on the road is a prop, not the road. Letting one into these casts
	-- means the springs try to climb it.
	--
	-- Other VEHICLES are deliberately still in. Driving up onto another car
	-- is a thing that should work, and both the springs and the box sweep
	-- need to see it for that to happen.
	local drops = workspace:FindFirstChild("WeaponDrops")
	if drops then table.insert(ignore, drops) end

	p.FilterDescendantsInstances = ignore
	p.FilterType = Enum.RaycastFilterType.Exclude

	-- Same reason as Physics: a Roblox cast hits a part whether or not it
	-- collides, so without this a car is stopped by every non-collidable
	-- decoration -- and by its OWN wheels and seats, which are deliberately
	-- CanCollide false. pcall'd because assigning an unknown property errors.
	pcall(function() p.RespectCanCollide = true end)
	return p
end

-- The same ignore set for the overlap query the depenetration pass runs. It
-- has to be a separate object: OverlapParams and RaycastParams are different
-- types and GetPartBoundsInBox will not take the latter.
local function castOverlapParams(model, seatCount)
	local op = OverlapParams.new()
	op.FilterDescendantsInstances = castParams(model, seatCount).FilterDescendantsInstances
	op.FilterType = Enum.RaycastFilterType.Exclude
	-- Bounded: a car in a dense scene can overlap a lot of bounding boxes, and
	-- the narrow phase below only cares about the deepest contact anyway.
	op.MaxParts = 24
	pcall(function() op.RespectCanCollide = true end)
	return op
end

--=====================================================================
-- SUSPENSION
--=====================================================================
-- One ray per corner, straight down the chassis's own up axis. Returns the
-- contacts, the average ground normal, and how much of the car is on the
-- ground at all -- which is what decides whether the engine and the tyres do
-- anything this step.

local function probeSuspension(s)
	local def = s.def
	local wheels = s.rig.wheels

	local contacts = {}
	local normalSum = Vector3.zero
	local grounded = 0
	local deepest = 0

	-- How far the strut top has gone BELOW where the fully compressed wheel
	-- would put it. Zero in normal driving; positive means the suspension has
	-- run out of travel and the chassis is inside the road.
	local penetration = 0

	for i, wheel in ipairs(wheels) do
		-- Per-wheel radius, measured off the part. A model with 1.4-stud
		-- wheels must not be simulated as though it had 1.1-stud ones, and
		-- a model with a big pair on the back is a thing people build.
		local ground = wheel.ground or wheel.radius
		local reach = def.suspension + ground * 2
		local origin = s.cf * wheel.offset
		local hit = workspace:Raycast(origin, -s.cf.UpVector * reach, s.params)

		if hit then
			-- 0 at full droop, 1 at fully compressed. Past 1 means the wheel
			-- is jammed into geometry, which the spring answers very hard.
			local compression = 1 - math.clamp(
				(hit.Distance - ground) / math.max(def.suspension, 0.05), 0, 1)

			contacts[i] = {
				position = hit.Position,
				normal = hit.Normal,
				compression = compression,
				front = wheel.front,
				anchor = wheel.offset,
				distance = hit.Distance,
				-- WHAT THIS WHEEL IS ON. Per contact, not per car: two wheels
				-- on tarmac and two in the grass is a car that pulls to one
				-- side, and one grip number for the whole vehicle cannot say
				-- that. The instance rides along because a debug readout that
				-- says "Grass" is half an answer without saying which part.
				material = hit.Material,
				instance = hit.Instance,
				grip = VehicleDefs.GripFor(hit.Material, def.surfaceGrip),
			}
			-- Measured BEFORE the clamp above throws it away. This is what
			-- the bump stop needs, and clamping compression to 1 hides it.
			penetration = math.max(penetration, ground - hit.Distance)

			normalSum += hit.Normal
			grounded += 1
			if compression > deepest then deepest = compression end
		else
			contacts[i] = false
		end
	end

	local normal = (grounded > 0 and normalSum.Magnitude > 1e-3)
		and normalSum.Unit or Vector3.yAxis

	return contacts, normal, grounded / math.max(#wheels, 1), deepest, penetration
end

--=====================================================================
-- COLLISION
--=====================================================================
-- The chassis box, swept. Deliberately much simpler than the player's
-- MoveAndSlide: a car that slides along a wall for four bumps reads as a car
-- that is stuck, where a car that scrapes and loses speed reads as a car that
-- hit something. Two bumps, restitution, and a chunk of the speed eaten.

local MAX_BUMPS = 3
local SKIN = 0.05
local SKIN_SIZE = Vector3.new(SKIN * 2, SKIN * 2, SKIN * 2)

--=====================================================================
-- DEPENETRATION
--=====================================================================
-- Separating Axis Test, box against box, both rotated.
--
-- Physics has one of these already, but its box A is AXIS-ALIGNED -- a player
-- hull never rotates -- so it tests 3 + 3 axes and cannot be reused for a car.
-- A car is an OBB, and OBB against OBB needs all 15: three faces each, plus
-- the nine edge-edge cross products. Skipping the cross products is the
-- classic shortcut and it fails exactly on edge-on-edge contact, which is
-- what hitting a wall at an angle IS.
--
-- WHY THIS IS NEEDED AT ALL, given the sweep: because the sweep does not
-- cover rotation. Yaw is integrated and the CFrame rebuilt with no collision
-- test, so a car can turn its own corner into a wall without ever translating
-- into it. And once the box overlaps ANYTHING, Roblox shapecasts -- which
-- ignore the geometry they start inside, exactly as raycasts do -- return nil
-- from then on. The car stops colliding with the world entirely and drives
-- through everything, permanently. That is the reported bug, and no amount of
-- tuning the sweep fixes it: something has to push the box back out.

local function boxAxes(cf)
	return cf.RightVector, cf.UpVector, cf.LookVector
end

-- Returns the minimum translation vector that separates A from B, or nil when
-- they are already apart. The vector points the way A has to move.
local function separateOBB(cfA, halfA, part)
	local cfB = part.CFrame
	local ax, ay, az = boxAxes(cfA)
	local bx, by, bz = boxAxes(cfB)
	local halfB = part.Size * 0.5
	local delta = cfB.Position - cfA.Position

	local bestAxis, bestDepth = nil, math.huge

	local function test(axis)
		local lenSq = axis:Dot(axis)
		if lenSq < 1e-12 then return true end   -- degenerate: parallel edges
		axis = axis / math.sqrt(lenSq)

		local rA = math.abs(ax:Dot(axis)) * halfA.X
			+ math.abs(ay:Dot(axis)) * halfA.Y
			+ math.abs(az:Dot(axis)) * halfA.Z
		local rB = math.abs(bx:Dot(axis)) * halfB.X
			+ math.abs(by:Dot(axis)) * halfB.Y
			+ math.abs(bz:Dot(axis)) * halfB.Z

		local dist = delta:Dot(axis)
		local overlap = rA + rB - math.abs(dist)
		if overlap <= 0 then return false end   -- separating axis: done

		if overlap < bestDepth then
			bestDepth = overlap
			bestAxis = (dist > 0) and -axis or axis
		end
		return true
	end

	-- Six face normals.
	if not test(ax) then return nil end
	if not test(ay) then return nil end
	if not test(az) then return nil end
	if not test(bx) then return nil end
	if not test(by) then return nil end
	if not test(bz) then return nil end

	-- Nine edge pairs. These are the ones that catch a corner on a corner.
	for _, a in ipairs({ ax, ay, az }) do
		for _, b in ipairs({ bx, by, bz }) do
			if not test(a:Cross(b)) then return nil end
		end
	end

	if not bestAxis then return nil end
	return bestAxis * bestDepth, bestDepth
end

-- Pushes the chassis out of anything it is inside, and returns the total push
-- so the caller can kill the velocity component that drove it in.
--
-- Iterated, because resolving one overlap can create another -- a car wedged
-- in a corner has to come out along both faces -- but bounded, because two
-- walls closing on a car have no solution and the alternative is a hang.
-- How far the body may lean, either way. See the bound() note in the step.
local BODY_ANGLE_LIMIT = 14

-- Steeper than this is a wall, not a road, and a car does not lie on it. The
-- player movement code draws the same line at 0.75.
local MIN_RESTING_NORMAL_Y = 0.5

local MAX_DEPEN_PASSES = 4
local DEPEN_EPS = 0.01

local function depenetrate(s, cf)
	local half = s.rig.size * 0.5
	local total = Vector3.zero

	for _ = 1, MAX_DEPEN_PASSES do
		-- Generously sized: a rotated part's bounding box is much larger than
		-- the part, so the broad phase has to over-collect or it will miss
		-- contacts the narrow phase would have found.
		local candidates = workspace:GetPartBoundsInBox(cf, s.rig.size * 1.5, s.overlapParams)

		local push, deepest = Vector3.zero, 0
		for _, part in ipairs(candidates) do
			if part.CanCollide then
				local mtv, depth = separateOBB(cf, half, part)
				-- Upward pushes are the GROUND, and the ground is the
				-- suspension's job for the same reason as the sweep above.
				-- Shoving the chassis up out of a ramp it is resting on
				-- fights the springs and launches the car off crests.
				local fromGround = mtv and mtv.Unit.Y >= MIN_RESTING_NORMAL_Y
				if mtv and not fromGround and depth > DEPEN_EPS and depth > deepest then
					push, deepest = mtv, depth
				end
			end
		end

		if deepest <= DEPEN_EPS then break end

		-- A little past touching, so the next sweep starts OUTSIDE. Landing
		-- exactly on the surface leaves the shapecast overlapping by a float
		-- error, which is the whole failure this exists to prevent.
		local step = push.Unit * (deepest + SKIN)
		cf = cf + step
		total += step
	end

	return cf, total
end

--=====================================================================
-- COLLISION
--=====================================================================
-- The chassis box, swept. Deliberately much simpler than the player's
-- MoveAndSlide: a car that slides along a wall for four bumps reads as a car
-- that is stuck, where a car that scrapes and loses speed reads as a car that
-- hit something. A few bumps, restitution, and a chunk of the speed eaten.
--
-- Takes and returns a CFRAME rather than a position, because the sweep has to
-- be done with the car's real orientation and the depenetration pass wants to
-- hand its result straight back in.
local function moveChassis(s, cf, displacement)
	local remaining = displacement
	local vel = s.vel
	local hitAnything = nil

	for _ = 1, MAX_BUMPS do
		if remaining.Magnitude < 1e-4 then break end

		-- Shrunk by the skin for the same reason the player hull is: a cast
		-- box exactly the size of the collision box starts the sweep already
		-- touching whatever it is resting against.
		local hit = workspace:Blockcast(cf, s.rig.size - SKIN_SIZE, remaining, s.params)

		if not hit then
			cf = cf + remaining
			break
		end

		-- DRIVABLE SURFACES ARE NOT THE BOX'S PROBLEM.
		--
		-- The suspension carries the car over the ground; the box exists to
		-- stop it going through things it cannot drive over. Colliding the
		-- box with the ground as well means the two fight: a car climbing a
		-- ramp catches its leading bottom edge on the ramp surface and the
		-- sweep takes the speed away, which is "ramps slow the car
		-- massively". The same hit on the way down turns a landing into a
		-- bounce off the restitution, which is "leaping over an edge is
		-- weird".
		--
		-- Anything too steep for the suspension to hold is still a wall and
		-- still stops the car -- that is what the threshold is for.
		if hit.Normal.Y >= MIN_RESTING_NORMAL_Y then
			-- Step past it and carry on. The suspension will lift the car
			-- over it on the same tick.
			cf = cf + remaining
			break
		end

		hitAnything = hit

		local travelled = math.max(hit.Distance - SKIN, 0)
		local direction = remaining.Unit
		cf = cf + direction * travelled
		remaining -= direction * travelled

		-- Split the impact into the part going INTO the surface and the part
		-- going along it. The first bounces back scaled by restitution, the
		-- second survives with friction taken off -- which is what makes a
		-- glancing scrape cost you a little and a head-on cost you everything.
		local into = vel:Dot(hit.Normal)
		if into < 0 then
			local normalPart = hit.Normal * into
			local tangent = vel - normalPart
			vel = tangent * (1 - s.def.crashLoss * 0.35) - normalPart * s.def.restitution

			local severity = math.abs(into)
			s.lastImpact = severity
			if severity > 12 then
				-- A real crash bleeds the whole car, not just the component
				-- that hit. Otherwise you ricochet off a wall at full speed.
				vel *= (1 - math.clamp(s.def.crashLoss * severity / 60, 0, 0.85))
			end
		end

		remaining = remaining - hit.Normal * remaining:Dot(hit.Normal)
	end

	s.vel = vel
	return cf, hitAnything
end

--=====================================================================
-- STEP
--=====================================================================

local function step(s, dt)
	Vehicle.stepCount += 1

	local def = s.def

	-- THE STARTER IS STILL TURNING.
	--
	-- An engine that is not running is not driving anything, and the car used
	-- to pull away under its own crank sound. Counted down here rather than
	-- measured against a clock, so it is a pure function of the steps taken
	-- and a paused or slowed sim cranks for the same number of ticks.
	--
	-- Brakes and steering are deliberately NOT suppressed: a car being started
	-- on a hill rolls, and the one thing you want then is the brake.
	local cranking = (s.crankRemaining or 0) > 0
	if cranking then
		s.crankRemaining = math.max((s.crankRemaining or 0) - dt, 0)
	end

	-- RETUNED from the model's attributes, once, on the first step after one
	-- changed. In place on the rig, so the effects layer and anything else
	-- holding it sees the same numbers without being told.
	if s.tuningDirty then
		s.tuningDirty = false
		s.def = VehicleDefs.Retune(s.rig, s.model)
		def = s.def
	end

	-- Rebuilt only when the ignore set actually changes. A RaycastParams per
	-- step is an allocation per step, and this runs at sv_PhysicsHz.
	--
	-- seatsDirty is set by an attribute listener rather than polled here, for
	-- the same reason: reading a seat attribute per seat per step to notice
	-- something that changes twice a minute is the same waste in a cheaper
	-- disguise.
	if s.paramsBody ~= State.playerBody or s.paramsPuppet ~= State.playerPuppet
		or s.seatsDirty then
		s.params = castParams(s.model, s.seatCount)
		s.overlapParams = castOverlapParams(s.model, s.seatCount)
		s.paramsBody = State.playerBody
		s.paramsPuppet = State.playerPuppet
		s.seatsDirty = false
	end

	-- Cars fall at the same rate as everything else unless told otherwise.
	-- sv_vehicle_gravity 0 means "follow sv_gravity"; a positive value
	-- overrides it, which is the knob rather than the default.
	local gravity = num(Config.sv_vehicle_gravity, 0)
	if gravity <= 0 then gravity = num(Config.sv_gravity, 72.7) end
	local powerScale = num(Config.sv_vehicle_powerscale, 1)
	local gripScale = num(Config.sv_vehicle_gripscale, 1)

	--------------------------------------------------------------
	-- 1. INPUT
	--------------------------------------------------------------
	-- The RAW axes, not wishDir. wishDir is normalised and rotated into camera
	-- space, which is right for a player -- W means "away from the camera" --
	-- and wrong for a car: W means "forward along the car" and A means "turn
	-- the wheels left", neither of which has anything to do with where the
	-- camera is pointing. Reading the axes directly is also what lets
	-- cl_vehicle_freelook exist at all.
	--
	-- Every binding still works, because Input publishes these from the same
	-- +forward / +moveleft buttons the movement code reads.
	-- THE CAR'S KEYS, not the walking ones. Same physical keys by default and
	-- separately bindable, which is the point: see the vehicle bind set in
	-- Input. Reading forwardMoveAxis here is what made "vehicle controls" a
	-- thing that could not be rebound.
	local throttleAxis = math.clamp(num(State.vehicleThrottleAxis, 0), -1, 1)
	local steerAxis = math.clamp(num(State.vehicleSteerAxis, 0), -1, 1)

	local handbrake = State.vehicleHandbrake == true

	--------------------------------------------------------------
	-- 2. SUSPENSION
	--------------------------------------------------------------
	local contacts, groundNormal, groundFrac, deepest, penetration = probeSuspension(s)

	--------------------------------------------------------------
	-- 2a. WHAT THE CAR IS STANDING ON
	--------------------------------------------------------------
	-- Averaged per END rather than per car, because the ends are what the
	-- grip model is already split into -- and because the interesting cases
	-- are asymmetric down the length of the car, not across it: the fronts
	-- reaching tarmac while the rears are still in the grass is a car that
	-- suddenly has steering and no drive.
	--
	-- A wheel in the AIR contributes nothing rather than counting as 1.
	-- Averaging air in as full grip would mean a car cresting a hill briefly
	-- gripped better on the two wheels it had left.
	local frontSurface, frontCount = 0, 0
	local rearSurface, rearCount = 0, 0

	for i, contact in ipairs(s.rig.wheels) do
		local hit = contacts[i]
		if hit then
			if hit.front then
				frontSurface, frontCount = frontSurface + hit.grip, frontCount + 1
			else
				rearSurface, rearCount = rearSurface + hit.grip, rearCount + 1
			end
		end
	end

	-- 1 when an end is entirely airborne, which is the neutral value: the
	-- grip that end contributes is already scaled to zero by groundFrac.
	s.surfaceFront = (frontCount > 0) and (frontSurface / frontCount) or 1
	s.surfaceRear = (rearCount > 0) and (rearSurface / rearCount) or 1
	s.surface = ((frontCount + rearCount) > 0)
		and ((frontSurface + rearSurface) / (frontCount + rearCount)) or 1

	--------------------------------------------------------------
	-- 2b. BUMP STOP
	--------------------------------------------------------------
	-- The suspension has a limit, and past it the wheel cannot go any further
	-- into the arch -- so the CHASSIS has to stop instead. Without this there
	-- is nothing at all holding the car up once the springs bottom out: the
	-- spring force saturates at full compression, and anything that pushes
	-- harder than that simply drives the car down through the road.
	--
	-- It used to be masked. The chassis box collided with the ground too, so
	-- bottoming out was caught by the sweep -- badly, by taking all the speed
	-- away, which is what made ramps feel like driving into treacle. Handing
	-- drivable surfaces to the suspension means the suspension has to own this
	-- end of the travel as well.
	--
	-- The state it prevented was not a slow sink but a coin flip: a car
	-- bottoming out at speed either recovered or punched through and fell for
	-- ever, decided by float noise. Two runs from what looked like identical
	-- state went different ways, which is how this was found.
	if penetration > 0 then
		local lift = (groundFrac > 0) and groundNormal or Vector3.yAxis
		s.cf = s.cf + lift * penetration

		-- And the speed that was driving it in, or the next step puts it
		-- straight back and the car hammers along the bump stop.
		local into = s.vel:Dot(lift)
		if into < 0 then s.vel -= lift * into end
		s.bumpStops = (s.bumpStops or 0) + 1
	end
	local grounded = groundFrac > 0.01
	s.groundFrac = groundFrac
	s.groundNormal = groundNormal

	local vel = s.vel
	local speed = vel.Magnitude
	local forward = s.cf.LookVector
	local right = s.cf.RightVector

	-- Signed road speed. The sign is what tells reverse from a forward roll,
	-- and it must come from the car's own axis rather than |vel|.
	local roadSpeed = vel:Dot(forward)
	s.roadSpeed = roadSpeed

	--------------------------------------------------------------
	-- 3. STEERING
	--------------------------------------------------------------
	-- Lock falls off with speed. Without this the car is undriveable above
	-- about 40 studs/s -- full lock at speed is a spin, every time, and no
	-- amount of grip tuning fixes it.
	local speedFactor = 1 / (1 + math.abs(roadSpeed) / math.max(def.steerSpeed, 1))
	local targetSteer = steerAxis * def.steerAngle * speedFactor

	local rate = (math.abs(steerAxis) > 0.01) and def.steerRate or def.steerReturn
	s.steer = approach(s.steer or 0, targetSteer, rate, dt)

	--------------------------------------------------------------
	-- 3b. GEARBOX
	--------------------------------------------------------------
	-- Faked, and deliberately: no ratio here feeds back into how hard the car
	-- accelerates. What it produces is an RPM and a shift event, which is
	-- what the engine note, the exhaust and the backfire are driven from --
	-- and that is the whole of what a gearbox contributes to how a car FEELS
	-- in a game like this.
	--
	-- The one thing it does do to the physics is cut the drive for shiftTime
	-- on an upshift. That pause is most of the character: it is why a fast
	-- car in GTA lurches up through the gears instead of pulling smoothly.
	local roadAbs = math.abs(roadSpeed)
	s.gear = s.gear or 1
	s.shiftRemaining = math.max((s.shiftRemaining or 0) - dt, 0)
	s.shiftedUp = false

	if s.shiftRemaining <= 0 then
		local fraction = VehicleDefs.GearFraction(def, s.gear, roadAbs)

		if fraction > 1 and s.gear < def.gears then
			s.gear += 1
			s.shiftRemaining = def.shiftTime
			s.shiftedUp = true

		-- HYSTERESIS on the way down, and it has to be well inside the lower
		-- gear's band rather than at its edge. Downshifting the moment the
		-- fraction goes negative puts the speed right at the top of the gear
		-- below, which immediately shifts up again -- a gearbox that hunts
		-- between two ratios several times a second.
		elseif s.gear > 1 and VehicleDefs.GearFraction(def, s.gear - 1, roadAbs) < 0.75 then
			s.gear -= 1
			s.shiftRemaining = def.shiftTime * 0.5   -- downshifts are quicker
		end
	end

	s.rpm = VehicleDefs.RpmFor(def, s.gear, roadAbs)
	if def.revLimiter and s.gear >= def.gears then
		s.rpm = math.min(s.rpm, def.redlineRpm)
	end

	-- Idle needs the engine to be turning even when the car is not, and the
	-- gear fraction alone gives idle exactly at a standstill. A touch of
	-- throttle should lift the note before the car has actually moved.
	if roadAbs < 1 and throttleAxis > 0.01 then
		s.rpm = math.max(s.rpm, def.idleRpm + (def.redlineRpm - def.idleRpm) * 0.25)
	end

	-- Flagged rather than fired, so the effects layer decides what a backfire
	-- looks like and this stays about the car.
	s.backfired = s.shiftedUp and (def.horsepower >= def.backfirePower)

	--------------------------------------------------------------
	-- 3c. TURBO
	--------------------------------------------------------------
	-- Another number for the effects layer, not more power. See the note on
	-- the def fields: what boost drives here is the spool whine and when the
	-- blow-off valve opens.
	--
	-- Mid-shift the throttle is DOWN as far as the turbo is concerned, because
	-- the drive is cut and the engine is not pumping gas through it. That is
	-- the same reason a real car chirps its valve on every upshift, and doing
	-- it any other way would mean the one moment everybody recognises is the
	-- one moment nothing happens.
	local wasBoosted = (s.spool or 0) >= def.bovSpool
	local turboThrottle = ((s.shiftRemaining or 0) > 0) and 0 or math.max(throttleAxis, 0)
	s.spool = VehicleDefs.TurboSpool(def, s.spool, turboThrottle, s.rpm, dt)

	-- A blow-off valve vents the boost that has nowhere to go when the
	-- throttle plate shuts against it. So: a LIFT, or a shift, and only while
	-- there was something to vent -- measured BEFORE this frame's spool, or
	-- the same update that dumps the boost also decides there was none.
	local lifted = (s.lastThrottle or 0) > 0.2 and math.max(throttleAxis, 0) <= 0.2
	s.bov = def.turbo and wasBoosted and (lifted or s.shiftedUp)
	s.lastThrottle = math.max(throttleAxis, 0)

	--------------------------------------------------------------
	-- 3d. TEMPERATURE
	--------------------------------------------------------------
	-- Two numbers that move the way an engine's do. Nothing reads them back
	-- into the physics on purpose -- see the note on the def fields.
	--
	-- LOAD is what the engine is being ASKED for, which is throttle and revs
	-- together: a car held against the redline in neutral is working as hard
	-- as one doing it at speed. AIRFLOW is the other half, and it is road
	-- speed rather than engine speed, because what cools a radiator is air
	-- going through it. Sitting still with the throttle open is how a real
	-- engine cooks, and this is the whole of why.
	local revFrac = math.clamp((s.rpm - def.idleRpm)
		/ math.max(def.redlineRpm - def.idleRpm, 1), 0, 1)
	-- An engine that is not running makes no heat, whatever the pedal is
	-- doing -- and the pedal is being ignored anyway while the starter turns.
	local heatLoad = cranking and 0
		or math.clamp(math.max(throttleAxis, 0) * 0.6 + revFrac * 0.4, 0, 1)
	local roadAir = math.clamp(roadAbs / math.max(def.topSpeed * 0.5, 1), 0, 1)

	-- THE FAN, stepped from the temperature it is reacting to -- this frame's,
	-- before the temperature moves again. Reacting to a number that has
	-- already been updated for this tick would put the switch one frame ahead
	-- of the thing it is switching on.
	s.fanOn, s.fanSpeed = VehicleDefs.StepFan(def, s.coolantTemp, s.fanOn, s.fanSpeed, dt)

	s.coolantTemp, s.oilTemp = VehicleDefs.StepTemperature(
		def, s.coolantTemp, s.oilTemp, heatLoad,
		VehicleDefs.Airflow(def, roadAir, s.fanSpeed), dt, not cranking)
	s.overheating = VehicleDefs.Overheating(def, s.coolantTemp, s.oilTemp)
	s.roadAirflow = roadAir

	--------------------------------------------------------------
	-- 4. LONGITUDINAL
	--------------------------------------------------------------
	local accel = Vector3.zero

	-- The tyre forces ALONE, kept apart from gravity and the suspension.
	-- These are what actually load the springs, and so they are what the body
	-- leans in response to. Using the total acceleration for that -- which is
	-- what this did -- puts GRAVITY into the lean, and gravity has a sideways
	-- component the moment the car is tilted at all. See the note on the
	-- render frame below: together those two made a loop with a gain of 1.9.
	local tyre = Vector3.zero

	if grounded then
		-- Traction scales with how many wheels are down, so a car cresting a
		-- hill on two wheels does not accelerate as if it were planted.
		--
		-- THE DRIVEN ONES, for the engine's own force. A rear-drive car with
		-- its back wheels in the air has no drive however hard you press, and
		-- scaling by the whole car meant one balanced on its front wheels
		-- still pulled away at half throttle -- and meant that changing a car
		-- to front-wheel drive changed nothing about which end had to be on
		-- the road. Braking and the tyre forces stay on groundFrac: all four
		-- wheels brake, whichever two are driven.
		local traction = groundFrac
		local driveGrip = VehicleDefs.DrivenGrip(def, s.rig.wheels, contacts)
		s.driveGrip = driveGrip

		-- Mid-shift the clutch is out and the engine is not driving the
		-- wheels. Brakes still work: you can stand on them during a shift.
		--
		-- A car still being cranked is the same condition for the same reason,
		-- and lasts longer.
		local shifting = (s.shiftRemaining or 0) > 0 or cranking

		if throttleAxis > 0.01 and not shifting then
			if roadSpeed < -1 then
				-- Forward while rolling backwards is braking, not launching.
				tyre += forward * def.brake * traction * throttleAxis
			else
				-- Constant force. The top speed is set by DRAG, not by a cap
				-- here -- VehicleDefs derives the drag coefficient from drive
				-- and topSpeed precisely so these two cannot disagree.
				tyre += forward * def.drive * powerScale * traction * driveGrip * throttleAxis
			end

		elseif throttleAxis < -0.01 and (roadSpeed > 1 or not shifting) then
			if roadSpeed > 1 then
				tyre += forward * -def.brake * traction * -throttleAxis
			else
				-- Reverse DOES get a hard falloff, because reverse is one
				-- gear and running out of revs in it is exactly what happens.
				-- Drag alone would let you reverse at sixty.
				local headroom = 1 - math.clamp(-roadSpeed / def.topReverse, 0, 1)
				tyre += forward * -def.reverse * powerScale * traction * -throttleAxis * headroom
			end
		end

		if handbrake then
			-- Rear wheels locked. Kills forward speed and, below, most of the
			-- rear grip -- which together is what a handbrake turn IS.
			tyre += forward * -math.sign(roadSpeed) * def.brake * 0.55 * traction
		end
	end

	--------------------------------------------------------------
	-- 5. LATERAL GRIP
	--------------------------------------------------------------
	-- The tyres resist sideways motion up to a limit and no further. Past the
	-- limit the car slides -- which is not a failure mode, it is the feature.
	--
	-- The limit is not ONE number any more. It is split front and rear, and
	-- the split moves with what the throttle is doing, because that is the
	-- mechanism behind almost everything a heavy car does:
	--
	--   braking loads the front  -> it turns in, and the rear goes light
	--   power unloads the front  -> it washes wide
	--   lifting mid-corner       -> the load snaps forward and the tail comes
	--                               round, with nothing in the code that
	--                               mentions lifting
	--
	-- Before this, load transfer existed only as body roll -- the car LOOKED
	-- like it was leaning and handled identically whatever the throttle did.
	local lateralSpeed = vel:Dot(right)

	if grounded then
		local limit = def.grip * gripScale * groundFrac

		-- accel so far is the drivetrain and the brakes and nothing else, so
		-- this is exactly the longitudinal effort the tyres are being asked
		-- for -- which is what moves the weight.
		local longEffort = tyre:Dot(forward)
		local transfer = math.clamp(longEffort / math.max(def.grip * gripScale, 1), -1, 1)

		local frontGrip = limit * (1 - transfer * def.loadTransfer)
		local rearGrip  = limit * (1 + transfer * def.loadTransfer)

		-- WHAT THE TYRES ARE ON. Applied per end, after the load split and
		-- before the understeer term, because a surface changes how much grip
		-- there IS -- it does not change how the weight moves between the
		-- axles or how the front washes out with speed.
		frontGrip *= s.surfaceFront or 1
		rearGrip *= s.surfaceRear or 1

		-- The front washes out with speed. A car that corners as hard at 90
		-- as it does at 20 feels weightless however heavy the numbers say it
		-- is; this is the push that makes speed cost something.
		frontGrip *= 1 - def.understeer
			* math.clamp(math.abs(roadSpeed) / math.max(def.topSpeed, 1), 0, 1)

		-- The handbrake locks the REAR only. That asymmetry is the whole
		-- trick: the front keeps steering while the back lets go.
		if handbrake then rearGrip *= def.handbrakeGrip end

		frontGrip = math.max(frontGrip, 0)
		rearGrip = math.max(rearGrip, 0)

		-- Proportional near zero so the car does not vibrate about straight
		-- ahead, saturating at the limit so it can be broken loose.
		local demand = -lateralSpeed * def.gripResponse
		local magnitude = math.abs(demand)

		-- The whole car resists with what both ends have between them, split
		-- by balance -- but each END saturates on its own, and that is what
		-- the yaw model below reads.
		local total = frontGrip * (1 - def.balance) + rearGrip * def.balance
		tyre += right * math.clamp(demand, -total, total)

		local function saturation(available)
			if available <= 1e-3 then return 1 end
			return math.max(magnitude - available, 0) / available
		end

		-- The same curve for a demand that is not the lateral one. Split out
		-- rather than given a default argument, so neither caller can quietly
		-- start measuring the other's demand.
		local function saturation2(demandFor, available)
			if available <= 1e-3 then return 1 end
			return math.max(demandFor - available, 0) / available
		end

		s.slipFront = saturation(frontGrip)
		s.slipRear = saturation(rearGrip)
		-- One number for the HUD and the old callers: whichever end is worse.
		s.slip = math.max(s.slipFront, s.slipRear)

		--------------------------------------------------------------
		-- 5b. PER WHEEL
		--------------------------------------------------------------
		-- The end values above are what the CAR does; these are what each
		-- corner does, and the difference is only interesting when the four
		-- are not on the same thing. One wheel dropping into the grass on the
		-- exit of a corner is a real and common event, and an effects layer
		-- reading the end value smokes both tyres on that axle for it.
		--
		-- Derived from the end rather than modelled separately: this wheel
		-- has the end's grip, scaled by how its own surface compares to the
		-- end's average. On matched surfaces that ratio is 1 and every wheel
		-- reports exactly what its end does, which is the behaviour this
		-- replaces and the thing it must not change.
		local wheelSlip = s.wheelSlip
		if not wheelSlip then
			wheelSlip = {}
			s.wheelSlip = wheelSlip
		end

		-- The longitudinal demand, shared by every driven wheel. A wheel on
		-- ice under full power spins even going in a straight line, which the
		-- lateral term alone can never say.
		local longDemand = math.abs(longEffort)

		for i in ipairs(s.rig.wheels) do
			local contact = contacts[i]
			if not contact then
				-- Airborne. Not sliding -- there is nothing to slide on --
				-- and an effects layer that smoked a wheel in the air would
				-- be smoking against nothing.
				wheelSlip[i] = 0
			else
				local endGrip = contact.front and frontGrip or rearGrip
				local endSurface = (contact.front and s.surfaceFront or s.surfaceRear) or 1
				local share = endGrip * (contact.grip / math.max(endSurface, 0.01))

				local lateral = saturation(share)
				local longitudinal = saturation2(longDemand, share)
				wheelSlip[i] = math.min(math.max(lateral, longitudinal), 4)
			end
		end
	else
		s.slip, s.slipFront, s.slipRear = 0, 0, 0
		if s.wheelSlip then
			for i in ipairs(s.wheelSlip) do s.wheelSlip[i] = 0 end
		end
	end

	--------------------------------------------------------------
	-- 6. DRAG + GRAVITY
	--------------------------------------------------------------
	-- Everything the tyres are doing folds into the total here, and nothing
	-- reads `tyre` again except the body lean.
	accel += tyre

	if speed > 1e-3 then
		local drag = def.dragLinear + def.dragQuad * speed
		accel -= vel.Unit * drag * speed
	end

	accel -= Vector3.yAxis * gravity

	--------------------------------------------------------------
	-- 7. SPRINGS
	--------------------------------------------------------------
	-- Written as SUPPORT + RESTORING rather than as a raw spring, and that
	-- split is not cosmetic. The obvious version -- force proportional to
	-- compression, gravity fighting it, ride height wherever they balance --
	-- ties the ride height to three numbers at once, and it is very easy to
	-- pick a spring rate whose force at FULL compression is still less than
	-- gravity. Then the car bottoms out and sinks through the road, slowly,
	-- with no error anywhere. The first draft of this did exactly that: at
	-- 2.1Hz over 1.1 studs of travel the springs top out at 191 studs/s^2
	-- against a gravity of 196.
	--
	-- So: SUPPORT cancels the weight the grounded wheels are carrying, which
	-- makes the equilibrium exactly REST_COMPRESSION whatever gravity is set
	-- to; RESTORING is the spring about that point, pushing up when the car is
	-- compressed past it and pulling down when it is extended past it, which
	-- is what keeps the car planted over a crest instead of launching it.
	if grounded then
		local omega = 2 * math.pi * def.springHz
		local stiffness = omega * omega
		local damping = 2 * def.springDamp * omega

		local sum, touching = 0, 0
		for _, contact in ipairs(contacts) do
			if contact then
				sum += contact.compression
				touching += 1
			end
		end
		local average = (touching > 0) and (sum / touching) or 0

		-- Scaled by how much of the car is down: two wheels hold up half a car.
		local support = gravity * groundFrac
		local restore = (average - VehicleDefs.RestCompression) * def.suspension * stiffness
		local verticalSpeed = vel:Dot(groundNormal)

		accel += groundNormal * (support + restore - verticalSpeed * damping)
	end

	--------------------------------------------------------------
	-- 8. INTEGRATE
	--------------------------------------------------------------
	vel += accel * dt

	-- Clamped before the sweep, not after: an unbounded velocity produces an
	-- unbounded Blockcast, and that is a frame-time cliff rather than a bug
	-- you notice.
	local maxVel = num(Config.sv_vehicle_maxvelocity, 400)
	if vel.Magnitude > maxVel then vel = vel.Unit * maxVel end
	if vel ~= vel then vel = Vector3.zero end   -- NaN guard, as Physics has

	s.vel = vel

	--------------------------------------------------------------
	-- 9. YAW  (bicycle model)
	--------------------------------------------------------------
	-- Only when the wheels are actually turning. A stationary car with the
	-- wheel wound over does not rotate, and letting it would mean tank-turning
	-- on the spot, which reads as a bug even to people who like it.
	if grounded and math.abs(roadSpeed) > 0.5 then
		-- NEGATED, and this is the counterpart to the heading sign below.
		-- Roblox yaw INCREASES counter-clockwise seen from above, so a
		-- positive yaw rate turns the car LEFT -- while a positive steer
		-- angle is the D key, which has to turn it RIGHT. Without the
		-- negation the car steers into the key you did not press, which is
		-- perfectly stable, perfectly smooth, and completely wrong.
		local wheelbase = s.rig.wheelbase
		local target = -(roadSpeed / wheelbase) * math.tan(math.rad(s.steer))

		-- Understeer and oversteer are now separate things, because the two
		-- ends of the car saturate separately.
		--
		-- A sliding FRONT turns less than the wheels are asking for: that is
		-- what running wide in a fast corner is, and the car should feel like
		-- it is refusing rather than like the wheel stopped working.
		--
		-- A sliding REAR keeps rotating past where the wheels point. balance
		-- below 0.5 leans this way on purpose, and the handbrake gets there
		-- immediately by cutting rear grip alone.
		local understeer = math.clamp(s.slipFront or 0, 0, 1.5)
		local oversteer = math.clamp(s.slipRear or 0, 0, 1.5) * (1.5 - def.balance)

		target *= math.clamp(1 - understeer * 0.55 + oversteer * 0.8, 0.15, 2.5)

		-- APPROACHED, not assigned. Everything above computes the yaw rate the
		-- geometry is asking for; def.yawResponse is how fast this particular
		-- car can actually get there, and it comes from its mass. Assigning
		-- the target directly is a car that starts and stops rotating on the
		-- frame the wheels move, with no weight to it at all.
		s.yawRate = approach(s.yawRate or 0, target, def.yawResponse, dt)
	else
		-- Off the ground or stopped: no new rotation is being generated, but
		-- what the car already had bleeds off at the same rate rather than
		-- vanishing. A car that stops mid-slide finishes its rotation.
		s.yawRate = approach(s.yawRate or 0, 0, def.yawResponse, dt)
	end

	-- Integrated OUTSIDE the branch, so the tail of a rotation survives the
	-- moment the car stops driving it. A car at rest has a yaw rate of zero
	-- and so still does not tank-turn.
	s.yaw += (s.yawRate or 0) * dt

	--------------------------------------------------------------
	-- 10. MOVE
	--------------------------------------------------------------
	-- Swept from the car's CURRENT orientation, then re-oriented, then pushed
	-- out of anything the rotation put it inside. That order matters: the
	-- sweep can only see translation, so rotation is the one way into
	-- geometry that nothing else catches.
	local moveCF = CFrame.new(s.cf.Position) * s.cf.Rotation
	local displacement = vel * dt

	-- SUBSTEPPED when a single step would move the car more than half its own
	-- smallest dimension. A shapecast cannot tunnel, but a car that covers
	-- three studs in one step resolves a corner impact from three studs away
	-- and skates around it; splitting keeps each resolution local. At 60Hz
	-- and 95 studs/s this is two substeps, and at 240Hz it is none.
	local shortest = math.min(s.rig.size.X, s.rig.size.Y, s.rig.size.Z)
	local substeps = math.clamp(
		math.ceil(displacement.Magnitude / math.max(shortest * 0.5, 0.1)), 1, 8)

	local hit
	for _ = 1, substeps do
		local stepped
		moveCF, stepped = moveChassis(s, moveCF, s.vel * (dt / substeps))
		hit = hit or stepped
	end

	local pos = moveCF.Position

	--------------------------------------------------------------
	-- 11. ORIENTATION  (drawn, per the header)
	--------------------------------------------------------------
	-- ROLL AND PITCH ARE SIMULATED FROM HERE, not drawn.
	--
	-- They used to be a bounded spring on the shell -- the header said as
	-- much, deliberately -- and that is fine right up to the two moments
	-- everybody expects a car to fall over. It could do neither: you could
	-- corner at any speed you liked, and you could park with half the car
	-- over a cliff and sit there perfectly level, leaning on nothing.
	--
	-- The model is in VehicleDefs.TipAccel and it is one sentence: a car
	-- stands up for as long as its weight lands between the wheels holding it
	-- up. Everything below is measuring those two things.

	-- WHERE IT IS BEING HELD UP. Not how many wheels are down but WHICH: two
	-- on the left is a car about to roll, two at the back is a car about to
	-- nose into a ravine, and "half the wheels" describes both.
	local halfTrack = math.max(def.size.X * 0.5, 0.1)
	local halfBase = math.max((s.rig.wheelbase or def.size.Z) * 0.5, 0.1)

	local rollMin, rollMax = VehicleDefs.SupportSpan(s.rig.wheels, contacts, "right", halfBase)
	local pitchMin, pitchMax = VehicleDefs.SupportSpan(s.rig.wheels, contacts, "forward", halfBase)

	-- Load transfer, exactly as before: lateral acceleration leans the body
	-- out of the corner, longitudinal dives or squats it. From the TYRE
	-- forces, not the total -- gravity is not a cornering load, and including
	-- it meant a tilted car leaned because it was tilted.
	local lateralG = tyre:Dot(right)
	local longG = tyre:Dot(forward)

	-- The lean the suspension is asked to hold, which is the load transfer
	-- plus whatever the road is doing. Degrees out of bodyRoll and bodyPitch,
	-- because that is what those numbers have always been; radians from here
	-- on, because a sine of degrees is not a thing.
	--
	-- A car parked across a hill has to lie with the hill. Without the ground
	-- term the spring would hold it level and it would stand on one corner --
	-- which is what OrientCF used to do for it, and OrientCF cannot express a
	-- car on its roof.
	local groundPitch, groundRoll = 0, 0
	if grounded and groundNormal.Y >= MIN_RESTING_NORMAL_Y then
		groundPitch, groundRoll = VehicleDefs.LeanForNormal(s.yaw, groundNormal)
	end

	-- Load transfer only. The ground's own lean is the REFERENCE these are
	-- measured against rather than part of the target -- see below.
	s.rollTarget = math.rad(lateralG * def.bodyRoll)
	s.pitchTarget = math.rad(longG * def.bodyPitch)

	-- INTEGRATED, not eased. The difference is the whole feature: an ease can
	-- only ever arrive at its target and stop, and a car that can only arrive
	-- at a target cannot leave the ground rotating.
	-- AGAINST THE GROUND, not against the world. A car parked across a
	-- thirty-degree bank is thirty degrees from vertical and is not falling
	-- over; a car leaning that far on the flat is most of the way onto its
	-- roof. Measuring against the world made the first one indistinguishable
	-- from the second, and every hillside a rollover.
	--
	-- The slope still pulls, and that goes in as its own term rather than as
	-- part of the lean: gravity does not need the cornering fudge to reach a
	-- car. See TipAccel.
	-- THE TYRE FORCE, SPLIT. Most of what the tyres are doing on a hill is
	-- holding the car on it, and that part is gravity: it must not be
	-- multiplied by tipLoad, which exists to make up for a grip model tuned
	-- below a real tyre. Counted once, at face value, a car sits on a
	-- thirty-degree bank; counted with the fudge it rolls straight off one,
	-- which is what the first version of this did.
	local rollHold = gravity * math.sin(groundRoll)
	local pitchHold = gravity * math.sin(groundPitch)

	local rollAccel = VehicleDefs.TipAccel({
		angle = (s.roll or 0) - groundRoll, rate = s.rollRate or 0,
		accel = lateralG - rollHold, lean = s.rollTarget,
		slopeAccel = rollHold,
		supportMin = rollMin, supportMax = rollMax,
		comHeight = def.comHeight, halfBase = halfTrack,
		load = def.tipLoad, gravity = gravity,
		stiffness = def.rollStiffness, damping = def.rollDamping,
	})

	local pitchAccel = VehicleDefs.TipAccel({
		angle = (s.pitch or 0) - groundPitch, rate = s.pitchRate or 0,
		accel = longG - pitchHold, lean = s.pitchTarget,
		slopeAccel = pitchHold,
		supportMin = pitchMin, supportMax = pitchMax,
		comHeight = def.comHeight, halfBase = halfBase,
		load = def.tipLoad, gravity = gravity,
		stiffness = def.pitchStiffness, damping = def.pitchDamping,
	})

	s.rollRate = (s.rollRate or 0) + rollAccel * dt
	s.pitchRate = (s.pitchRate or 0) + pitchAccel * dt
	s.roll = (s.roll or 0) + s.rollRate * dt
	s.pitch = (s.pitch or 0) + s.pitchRate * dt

	-- Wrapped rather than clamped. A car that rolls all the way over comes
	-- back onto its wheels and keeps going; one clamped at pi would stick on
	-- its roof with the rate still fighting the stop.
	local function wrap(a) return (a + math.pi) % (2 * math.pi) - math.pi end
	s.roll = wrap(s.roll)
	s.pitch = wrap(s.pitch)

	-- THE LEAN THE WHEELS ARE ASKING FOR, on top of the attitude above, and
	-- still drawn rather than simulated.
	--
	-- The chassis lies along the suspension NORMAL, which handles a slope and
	-- is blind to a kerb: a kerb and the road beside it both point straight
	-- up, so the normals agree while the heights do not. That is why the body
	-- sat dead level with one pair of wheels a stud higher than the other.
	-- This reads the heights instead -- see VehicleDefs.AxleLean.
	--
	-- Read from the DRAWN travel, which the render pass maintains, so the
	-- body and the wheels are describing the same suspension rather than two
	-- versions of it. That is a frame behind; on a decoration, invisible.
	local axleRollTarget, axlePitchTarget = VehicleDefs.AxleLean(def, s.rig.wheels, s.rig.wheelbase)

	s.axleRoll, s.axleRollRate = dampedSpring(s.axleRoll or 0, s.axleRollRate or 0,
		axleRollTarget, def.bodyHz * 1.6, 0.75, dt)
	s.axlePitch, s.axlePitchRate = dampedSpring(s.axlePitch or 0, s.axlePitchRate or 0,
		axlePitchTarget, def.bodyHz * 1.6, 0.75, dt)

	-- Bounded, and the rate zeroed at the stop. This one IS a decoration, and
	-- a decoration that can reach 90 degrees is a car lying on its side.
	local function bound(angle, rate, limit)
		if angle > limit then return limit, math.min(rate, 0) end
		if angle < -limit then return -limit, math.max(rate, 0) end
		return angle, rate
	end
	s.axleRoll, s.axleRollRate = bound(s.axleRoll, s.axleRollRate, BODY_ANGLE_LIMIT)
	s.axlePitch, s.axlePitchRate = bound(s.axlePitch, s.axlePitchRate, BODY_ANGLE_LIMIT)

	-- What goes over the wire, in degrees, and it is the DECORATION ONLY.
	--
	-- The receiver undoes exactly these to recover the frame the wheels
	-- belong in, and the attitude is now part of that frame rather than a
	-- lean applied to it -- a car on its side has its wheels on their sides
	-- too. Sending the attitude here as well would have the receiver undo it
	-- and draw the wheels of a rolled car standing neatly upright in the air.
	s.rollDrawn = s.axleRoll
	s.pitchDrawn = s.axlePitch

	-- Published for the debug panel: what the body is actually doing, in
	-- degrees, because nobody reads radians off a HUD.
	s.rollDeg = math.deg(s.roll)
	s.pitchDeg = math.deg(s.pitch)
	-- And against the ground, which is the number that says how close to
	-- going over it is. On a bank the two differ by the bank.
	s.rollLean = math.deg(s.roll - groundRoll)
	s.pitchLean = math.deg(s.pitch - groundPitch)

	-- Kept so anything still reading it -- the settle pass, a gamemode -- gets
	-- the car's real up rather than a stale one.
	s.up = (VehicleDefs.AttitudeCF(Vector3.zero, s.yaw, s.pitch, s.roll)).UpVector

	s.cf = VehicleDefs.AttitudeCF(pos, s.yaw, s.pitch, s.roll)

	--------------------------------------------------------------
	-- 11b. DEPENETRATION
	--------------------------------------------------------------
	-- After the orientation, because the orientation is what puts the car
	-- inside things. The sweep never sees a rotation, so a car turning beside
	-- a wall drives its own corner straight through it -- and from that point
	-- on every Blockcast starts overlapping, Roblox returns nil for a
	-- shapecast that begins inside geometry, and the car passes through
	-- everything forever. Pushing back out is the only thing that ends that
	-- state.
	local pushed, push = depenetrate(s, s.cf)
	s.cf = pushed

	if push.Magnitude > DEPEN_EPS then
		-- Kill the velocity that drove it in, keeping whatever was sliding
		-- along the surface. Without this the car pushes out and is shoved
		-- straight back in on the next step, which reads as a violent buzz
		-- against the wall rather than a car resting on it.
		local outward = push.Unit
		local into = s.vel:Dot(outward)
		if into < 0 then s.vel -= outward * into end
		s.depenCount = (s.depenCount or 0) + 1
	end

	--------------------------------------------------------------
	-- 12. WHEEL SPIN  (visual)
	--------------------------------------------------------------
	-- Spin rate from the FRONT wheel's real radius: a bigger wheel turns
	-- slower for the same road speed, which is visible at a glance.
	-- NEGATIVE, and this is the sign the wheels are actually drawn with.
	--
	-- drawWheels applies the spin as CFrame.Angles(spin, 0, 0) about the
	-- wheel's own X, which is its axle. Roblox rotations are counter-clockwise
	-- about the axis, and the wheel's +X points to the car's RIGHT -- so a
	-- positive angle rolls the tread forward over the top and backward at the
	-- contact patch, which is a car driving forwards with its wheels spinning
	-- in reverse.
	--
	-- Flipped here rather than at the draw because wheelSpin goes over the
	-- wire: correcting it in drawWheels would fix the driver's car and leave
	-- every observed one turning the wrong way, since they draw from the
	-- synced number through the same function.
	local spinRadius = s.rig.wheels[1] and s.rig.wheels[1].radius or def.wheelRadius
	s.wheelSpin = (s.wheelSpin or 0) - (roadSpeed / math.max(spinRadius, 0.1)) * dt
	s.contacts = contacts
	s.deepest = deepest
	s.lastHit = hit

	-- Built last, from the finished physics frame. Everything downstream that
	-- DRAWS reads this; everything that simulates reads s.cf.
	s.renderCf = s.cf * CFrame.Angles(math.rad(s.pitchDrawn), 0, math.rad(s.rollDrawn))
end

--=====================================================================
-- DRAWING
--=====================================================================

local function drawWheels(rig, cf, steer, spin, contacts, dt)
	if not rig then return end
	local def = rig.def

	for i, wheel in ipairs(rig.wheels) do
		local part = wheel.part
		if part and part.Parent then
			-- Drawn relative to its REST position, so a car sitting still puts
			-- its wheels exactly where the model put them and travel is a
			-- deviation from that rather than an offset baked into it.
			--
			-- WheelTravel, not WheelOffset: the offset is where the ray says
			-- the wheel should be, and a wheel does not get there instantly.
			-- `contacts` present means we know which wheels are airborne;
			-- absent means we were told nothing, which is not the same thing.
			local travel = VehicleDefs.WheelTravel(
				def, wheel, contacts and contacts[i], dt, contacts ~= nil)

			-- Steer about the CHASSIS up axis, before the wheel's own rotation.
			-- Front axle only, which is what rig.front is for.
			--
			-- TurnCF, not CFrame.Angles(0, rad(steer), 0). Positive steer is
			-- the D key and means RIGHT; a positive rotation about Y in Roblox
			-- is counter-clockwise, which is LEFT. So the front wheels pointed
			-- the wrong way while the car turned correctly -- the same sign
			-- trap as the heading vector and the yaw rate, which is why the
			-- convention now lives in one helper.
			local steerRot = wheel.front and VehicleDefs.TurnCF(steer) or CFrame.identity

			-- restRot is the orientation the wheel was AUTHORED with, kept
			-- rather than replaced. The first version forced a quarter turn about
			-- Z, which is right for a cylinder built the way Build builds them and
			-- wrong for every wheel anybody models themselves -- it would twist
			-- their art on the first frame.
			--
			-- Spin goes last, about the wheel's own X, because that is the axle of
			-- a Roblox cylinder. A wheel modelled around a different axis will roll
			-- about the wrong one; that is the one thing here that art has to match
			-- rather than declare.
			local placed = cf
				* CFrame.new(wheel.rest - Vector3.new(0, travel, 0))
				* steerRot
				* wheel.restRot
				* CFrame.Angles(spin, 0, 0)
			part.CFrame = placed

			-- Anything else the wheel is built from, carried rigid to it. The
			-- rig recorded each one's offset from the measured part, so a
			-- brake disc turns and steers with its own wheel instead of being
			-- anchored to a spot in the world and left behind.
			for _, extra in ipairs(wheel.extras or {}) do
				if extra.part then
					extra.part.CFrame = placed * extra.cf
				end
			end
		end
	end
end

--=====================================================================
-- OCCUPANCY
--=====================================================================

local function seatCFrame(rig, index)
	if not rig or not rig.chassis then return nil end
	local seat = rig.seats[index]
	if not seat then return nil end
	-- The seat's full local CFrame, not just its position: a seat rotated to
	-- face out of a door should put the occupant facing that way too.
	return rig.chassis.CFrame * seat.cf
end

-- Parks the RawBody at the seat. Everything else in the engine -- health,
-- weapons, PuppetSync, hit detection -- keys off the body, so the one thing a
-- passenger MUST keep doing is being where the car is.
local function parkBody(rig, index)
	local body = State.playerBody
	if not body then return end

	local cf = seatCFrame(rig, index)
	if not cf then return end

	body.CFrame = cf
	State.pos = cf

	-- The PUPPET has to be moved explicitly. Visuals normally does it and
	-- Visuals is skipped while seated, so without this your body stays
	-- standing wherever you got in -- and PuppetSync would broadcast that
	-- pose, so everyone else would watch you drive off without you.
	local puppet = State.playerPuppet
	if puppet and puppet.PrimaryPart then
		puppet.PrimaryPart.CFrame = cf
	end
	State.prevBodyPos = State.curBodyPos or cf.Position
	State.curBodyPos = cf.Position

	-- Zeroed so stepping out does not inherit the car's speed and fling you
	-- across the map, and so fall damage does not fire on the way in.
	State.velocity = Vector3.zero
	State.isGrounded = true
	State.isJumping = false
	State.lastLandSpeed = 0
end

-- The viewmodel is drawn by Visuals, which does not run while seated, so it
-- would otherwise hang in the air at the spot you got in. Transparency rather
-- than destroy: rebuilding it on every exit would reload every animation track
-- on the arms, and you get in and out of cars a lot.
local function setViewmodelHidden(hidden)
	local vm = State.viewmodel
	if not vm then return end
	for _, part in ipairs(vm:GetDescendants()) do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = hidden and 1 or 0
		end
	end
end

local function startDriving(model, def, index)
	-- Measured once, here, and carried for the life of the drive. Rebuilding
	-- it per step would mean a GetDescendants walk at sv_PhysicsHz.
	local rig = VehicleDefs.Rig(model, def)
	if not rig then
		warn("[Vehicle] " .. model.Name .. " has no PrimaryPart and no part named Chassis.")
		return
	end

	local chassis = rig.chassis
	local _, yaw = chassis.CFrame:ToEulerAnglesYXZ()

	sim = {
		model = model,
		chassis = chassis,
		-- The RIG's def, not the class it started from: Rig applies the
		-- model's own attributes, and driving the untuned one would mean
		-- MaxSpeed and HP were read and then ignored.
		def = rig.def,
		rig = rig,
		cf = chassis.CFrame,
		spool = 0,
		renderCf = chassis.CFrame,
		prevRenderCf = chassis.CFrame,
		prevPhysicsCf = chassis.CFrame,
		vel = Vector3.zero,
		yaw = yaw,
		yawRate = 0,
		steer = 0,
		slip = 0,
		wheelSpin = 0,
		up = Vector3.yAxis,
		-- THE ATTITUDE, in radians, and it is state rather than decoration:
		-- a car that leaves a ramp rotating is still rotating when it lands,
		-- which is the whole of why these carry a rate.
		roll = 0,
		rollRate = 0,
		pitch = 0,
		pitchRate = 0,
		-- The suspension's own lean on top, still drawn, still in degrees.
		axleRoll = 0,
		axlePitch = 0,
		groundFrac = 0,
		-- THE STARTER. Counted down by the step, and the whole of why the car
		-- does not pull away under its own crank sound.
		crankRemaining = rig.def.startTime or 0,
		seatCount = #rig.seats,
		params = castParams(model, #rig.seats),
		overlapParams = castOverlapParams(model, #rig.seats),
		paramsBody = State.playerBody,
		paramsPuppet = State.playerPuppet,
	}
	accumulator = 0

	-- WHO ELSE IS ABOARD, watched rather than polled.
	--
	-- The step rebuilds its cast filters when this fires, which is what keeps
	-- a passenger who got in halfway through a drive out of the car's own
	-- collision -- and, just as importantly, puts them back into it the
	-- moment they get out and become a pedestrian again.
	sim.seatConns = {}
	for i = 1, #rig.seats do
		table.insert(sim.seatConns,
			model:GetAttributeChangedSignal(("Seat%d"):format(i)):Connect(function()
				if sim then sim.seatsDirty = true end
			end))
	end

	-- LIVE TUNING. Every attribute on the model is a knob, and changing one
	-- while the car is moving retunes it on the next step rather than on the
	-- next time somebody gets in.
	--
	-- AttributeChanged, not a per-name signal: the point is that ALL of them
	-- work, and a list of names here would be a third place to keep in step
	-- with the alias table.
	--
	-- Marked rather than applied, because this fires once per attribute and a
	-- panel dragging a slider writes several in a frame. Retuning inside the
	-- handler would rebuild the def per keystroke; the step does it once.
	table.insert(sim.seatConns, model.AttributeChanged:Connect(function(name)
		-- The seat record is not tuning, and it already has its own handler.
		if sim and not name:match("^Seat%d+$") then sim.tuningDirty = true end
	end))

	-- The ignition, once, on getting in. An event rather than a state, so it
	-- fires here rather than being inferred inside the per-frame update.
	VehicleFX.Start(model, rig)
end

local function stopDriving()
	-- Disconnected explicitly: these are connections to a MODEL that outlives
	-- the drive, so they would otherwise accumulate one set per car entered
	-- and keep firing into a sim that no longer exists.
	if sim and sim.seatConns then
		for _, conn in ipairs(sim.seatConns) do conn:Disconnect() end
	end
	sim = nil
	accumulator = 0
end

-- Applied for every player, not just this one: the announcement is broadcast
-- so each client learns who is in what and can stop interpolating a car whose
-- driver just got out.
local function onStateChange(packet)
	if type(packet) ~= "table" then return end

	local model = packet.vehicle
	local isMe = packet.userId == plr.UserId

	if not isMe then
		-- Someone else's transition. The only thing we care about is dropping
		-- a stale interpolation buffer when a car stops being driven.
		if not packet.entered and model then
			local entry = observed[model]
			if entry and entry.rig then VehicleFX.Quiet(entry.rig) end
			observed[model] = nil
		end
		return
	end

	if packet.entered then
		if not model then return end
		local def = VehicleDefs.GetOrDerive(packet.class or model:GetAttribute("Class"))

		seatModel = model
		seatIndex = packet.seat
		State.inVehicle = true
		State.vehicleSeat = packet.seat
		-- Published so anything that wants to act on the car itself -- the
		-- tuning panel, a gamemode -- can reach it without this module
		-- exporting a getter that returns a live handle.
		State.vehicleModel = model
		setViewmodelHidden(true)

		-- THE CAR'S KEYBOARD. From here W is the throttle rather than forward,
		-- and every key the vehicle set does not claim still does what it did.
		Input.SetContext("vehicle")

		if packet.seat == 1 then
			startDriving(model, def, packet.seat)
		else
			stopDriving()
		end
	else
		-- Quietened before the handle is dropped, or the car is left revving
		-- and smoking with nobody in it.
		if sim and sim.rig then VehicleFX.Quiet(sim.rig) end

		seatModel = nil
		seatIndex = nil
		State.inVehicle = false
		State.vehicleSeat = nil
		State.vehicleModel = nil
		-- Or the panel keeps reading the last car's revs and temperatures at
		-- whatever they were when you stepped out, which looks live.
		State.vehicleRpm, State.vehicleGear = nil, nil
		State.vehicleCoolant, State.vehicleOil = nil, nil
		State.vehicleOverheating, State.vehicleSurface = nil, nil
		State.vehicleWheelSlip, State.vehicleContacts = nil, nil
		State.vehicleSlipFront, State.vehicleSlipRear = nil, nil
		State.vehicleSpool, State.vehicleDef = nil, nil
		State.vehicleFan, State.vehicleFanOn = nil, nil
		State.vehicleCranking = nil
		-- Back to walking, which also releases whatever the car was holding:
		-- stepping out with the throttle down would otherwise leave it latched.
		Input.SetContext("player")
		stopDriving()
		setViewmodelHidden(false)
		camPos = nil   -- so the next car does not lerp in from the last one

		-- The camera is scriptable and Visuals owns it again from here. Fall
		-- damage in particular must not fire on the frame we step out.
		State.lastLandSpeed = 0
		State.velocity = Vector3.zero
	end
end

--=====================================================================
-- USE
--=====================================================================

-- Is there anywhere to sit? Offering a full car means +use does nothing and
-- eats the press that would have picked up a gun.
--
-- SeatCount is published by the server when it registers the vehicle, because
-- how many seats a car has is a property of the MODEL and this must not build
-- a rig for every candidate on screen.
local function hasFreeSeat(model)
	local seatCount = model:GetAttribute("SeatCount") or 0
	for i = 1, seatCount do
		local occupant = model:GetAttribute(("Seat%d"):format(i))
		if not occupant or occupant == 0 then return true end
	end
	return false
end

-- Distance from the body to the chassis SURFACE, measured against the box
-- rather than a sphere around it -- which is how the server measures it, and
-- the two answers have to agree or the prompt offers a car the server then
-- refuses.
local function surfaceDistance(chassis, from)
	local local_ = chassis.CFrame:PointToObjectSpace(from)
	local half = chassis.Size * 0.5
	local clamped = Vector3.new(
		math.clamp(local_.X, -half.X, half.X),
		math.clamp(local_.Y, -half.Y, half.Y),
		math.clamp(local_.Z, -half.Z, half.Z))
	return (local_ - clamped).Magnitude
end

-- CARS YOU COULD GET INTO, offered to Interact rather than scanned when the
-- key is pressed.
--
-- Registered here rather than lived in Interact, because which cars are
-- enterable is this module's business -- the seat rule, the range cvar, and
-- the fact that you cannot enter one while sitting in another are all facts
-- about vehicles. Interact only knows how to point at things.
Interact.AddSource("vehicles", function(add, ctx)
	if not Config.sv_vehicles then return end
	-- Already driving. Getting OUT is a key, not something you aim at, and a
	-- prompt on the car you are sitting in is a prompt over your own bonnet.
	if seatModel then return end

	local folder = workspace:FindFirstChild("Vehicles")
	if not folder then return end

	for _, model in ipairs(folder:GetChildren()) do
		local chassis = model:IsA("Model") and model.PrimaryPart
		if chassis and hasFreeSeat(model) then
			local class = model:GetAttribute("Class")
			local def = class and VehicleDefs.Get(class)
			add({
				instance = model,
				kind = "vehicle",
				command = "+use",
				verb = "Enter",
				label = (def and def.label) or model.Name,
				-- Its own reach and its own measurement, both matching the
				-- server's.
				range = num(Config.sv_vehicle_userange, 12),
				reach = surfaceDistance(chassis, ctx.from),
			})
		end
	end
end)

-- Returns true when the press was CONSUMED. Weapons reads that: a +use aimed
-- at a car is "get in", and a +use anywhere else is still "pick that up".
--
-- WHAT IS AIMED AT, not what is nearest. The old version scanned for the
-- closest car and took the press if it found one, so standing beside a car
-- meant you could not pick up the rifle at your feet -- the car ate every
-- press, silently, and there was nothing on screen to say why.
function Vehicle.TryConsumeUse()
	if not Config.sv_vehicles then return false end

	local now = os.clock()

	-- SEATED: leaving is its own key on the vehicle bind set, so it is not a
	-- +use at all any more and does not compete with anything.
	if seatModel then
		-- A +use pressed while driving is swallowed rather than left set. On
		-- the same key by default it is the same press as the exit below, and
		-- leaving the flag on would fire a pickup the instant you got out.
		State.useRequested = false

		if not State.vehicleExitRequested then return false end
		State.vehicleExitRequested = false

		if now < nextRequestAt then return true end
		nextRequestAt = now + 0.4

		local exit = remote("ExitVehicle")
		if exit then exit:FireServer() end
		return true
	end

	-- ON FOOT: exit presses are meaningless, and holding one from a car you
	-- have already left would fire at the next one you got into.
	State.vehicleExitRequested = false

	if not State.useRequested then return false end

	local target = Interact.TargetOfKind("vehicle")
	if not target then return false end

	if now < nextRequestAt then return false end

	State.useRequested = false
	nextRequestAt = now + 0.4
	local enter = remote("EnterVehicle")
	if enter then enter:FireServer(target.instance) end
	return true
end

--=====================================================================
-- CAMERA
--=====================================================================

local function updateCamera(model, def, dt)
	local chassis = model.PrimaryPart
	if not chassis then return end

	local dist = num(Config.cl_vehicle_camdist, 17)
	local height = num(Config.cl_vehicle_camheight, 5.2)
	local pitch = num(Config.cl_vehicle_campitch, -11)
	local lag = num(Config.cl_vehicle_camlag, 7)

	-- Two ways to aim it. Free-look orbits on the mouse, which is what you
	-- want for looking at a map or shooting out of a window; otherwise the
	-- camera trails the car's heading, which is what you want for driving.
	local _, carYaw = chassis.CFrame:ToEulerAnglesYXZ()

	local yaw
	if Config.cl_vehicle_freelook then
		yaw = math.rad(State.cameraX or 0)

		-- AUTO-CENTRE. Free-look and driving want opposite things: looking
		-- out of a window is worth a whole mouse for, and then you want to be
		-- facing forward again without putting it back by hand.
		--
		-- Written back into cameraX rather than blended only into the drawn
		-- yaw, so the mouse picks up from where the camera actually IS. A
		-- version that left cameraX alone would snap back to wherever you had
		-- last dragged it the moment you touched the mouse again.
		local delay = num(Config.cl_vehicle_camautocenter, 0)
		local idle = (State.gameTime or 0) - (State.lastLookAt or -1e9)

		if delay > 0 and idle >= delay then
			-- The SHORT way round. Yaw is an angle, and lerping 179 to -179
			-- the long way is a full spin of the camera for two degrees of
			-- correction.
			-- cameraX is already in degrees, so only the car's yaw converts.
			local diff = (math.deg(carYaw) - (State.cameraX or 0) + 180) % 360 - 180
			local rate = num(Config.cl_vehicle_camautorate, 3.2)
			local blend = math.clamp(rate * dt, 0, 1)

			State.cameraX = (State.cameraX or 0) + diff * blend
			yaw = math.rad(State.cameraX)
		end
	else
		yaw = carYaw
	end

	-- BEHIND. HeadingFromYaw is the direction a yaw FACES, so the camera goes
	-- the other way -- and this line had it written out longhand as
	-- (-sin, 0, -cos), which is the heading itself. The camera therefore sat
	-- in front of the car looking away from it.
	--
	-- It survived because free-look hid it: cameraX is the mouse's yaw and
	-- has nothing to do with the car's, so you dragged until the car was in
	-- shot and the sign never came up. Auto-centre is what drives the two
	-- together, and the first thing it did was put the camera on the bonnet.
	--
	-- Through the shared helper rather than written out again. This engine
	-- has now had this exact sign wrong five separate times, and every one of
	-- them was a hand-written (-sin, 0, -cos) somewhere.
	local behind = -VehicleDefs.HeadingFromYaw(yaw)
	local focus = chassis.Position + Vector3.new(0, height * 0.45, 0)
	local target = focus + behind * dist + Vector3.new(0, height, 0)

	camPos = camPos and approach(camPos, target, lag, dt) or target

	-- Pulled in rather than clipped through. A camera inside a wall is worse
	-- than a close camera, and this is the whole of the collision handling
	-- the chase view needs.
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { model, State.playerBody, State.playerPuppet }
	params.FilterType = Enum.RaycastFilterType.Exclude

	local toCam = camPos - focus
	local blocked = workspace:Raycast(focus, toCam, params)
	local finalPos = blocked and (blocked.Position - toCam.Unit * 0.5) or camPos

	local aim = focus + Vector3.new(0, math.tan(math.rad(pitch)) * dist, 0)
	cam.CFrame = CFrame.lookAt(finalPos, aim)

	-- Speed pulls the FOV out. It is the cheapest sense of speed there is and
	-- the only one that survives a bare grey baseplate.
	local speed = sim and math.abs(sim.roadSpeed or 0) or 0
	local gain = num(Config.cl_vehicle_camfovgain, 14)
	local frac = math.clamp(speed / math.max(def.topSpeed, 1), 0, 1)
	cam.FieldOfView = num(Config.fov, 70) + gain * frac * frac
end

--=====================================================================
-- OBSERVED VEHICLES
--=====================================================================
-- Cars other people are driving. Same snapshot interpolation as remote
-- puppets, for the same reason: VehicleSync is unreliable and irregular, and
-- every bit of that shows up as jitter if you snap to the newest packet.

local MAX_SNAPSHOTS = 24

local function pushObserved(packet)
	local model = packet.vehicle
	if typeof(model) ~= "Instance" or not model:IsA("Model") then return end

	local entry = observed[model]
	if not entry then
		local def = VehicleDefs.GetOrDerive(model:GetAttribute("Class"))
		local rig = VehicleDefs.Rig(model, def)
		entry = { snapshots = {}, def = (rig and rig.def) or def, rig = rig }
		observed[model] = entry
	end
	if not entry.def then return end

	local t = num(packet.T, workspace:GetServerTimeNow())
	local snapshot = {
		t = t,
		recv = os.clock(),
		cf = packet.cf,
		steer = num(packet.steer, 0),
		spin = num(packet.wheelSpin, 0),
		roll = num(packet.roll, 0),
		pitch = num(packet.pitch, 0),
		-- What the effects run off. Cheap, and it means another player's car
		-- sounds and smokes like the driver's own rather than being a silent
		-- prop sliding past.
		rpm = num(packet.rpm, 0),
		gear = num(packet.gear, 1),
		spool = num(packet.spool, 0),
		-- A one-shot, so it is a flag rather than a level. Sent as a boolean
		-- and read back as one: an interpolated valve chirp is not a thing.
		bov = packet.bov == true,
		throttle = num(packet.throttle, 0),
		slipFront = num(packet.slipFront, 0),
		slipRear = num(packet.slipRear, 0),
	}

	-- Inserted in time order: a packet delayed in flight carries an OLD pose,
	-- and appending it would drag the interpolation backwards.
	local list = entry.snapshots
	local i = #list
	while i > 0 and list[i].t > t do i -= 1 end
	table.insert(list, i + 1, snapshot)

	while #list > MAX_SNAPSHOTS do table.remove(list, 1) end
end

local function drawObserved(deltaTime)
	local interp = num(Config.cl_interp, 0.1)
	local now = workspace:GetServerTimeNow()
	local renderAt = now - interp

	for model, entry in pairs(observed) do
		if not model.Parent then
			observed[model] = nil
		else
			local list = entry.snapshots
			local a, b

			for i = #list, 1, -1 do
				if list[i].t <= renderAt then
					a = list[i]
					b = list[i + 1]
					break
				end
			end

			-- Before the buffer starts, hold the oldest rather than
			-- extrapolating backwards into a pose that never happened.
			if not a then a = list[1] end

			if a then
				local cf = a.cf
				local steer, spin = a.steer, a.spin
				local roll, pitch = a.roll, a.pitch
				if b and b.t > a.t then
					local alpha = math.clamp((renderAt - a.t) / (b.t - a.t), 0, 1)
					cf = a.cf:Lerp(b.cf, alpha)
					steer = a.steer + (b.steer - a.steer) * alpha
					spin = a.spin + (b.spin - a.spin) * alpha
					roll = a.roll + (b.roll - a.roll) * alpha
					pitch = a.pitch + (b.pitch - a.pitch) * alpha
				end

				model:PivotTo(cf)
				-- Re-measured if the rig went stale, which happens when the
				-- model was still streaming in when the first packet landed.
				entry.rig = entry.rig or VehicleDefs.Rig(model, entry.def)

				-- The lean undone, to recover the physics frame the wheels
				-- belong in. The sender's frame is the physics one with these
				-- two angles applied, so applying their negatives takes it
				-- back -- and someone else's car then has its wheels flat on
				-- the road exactly like your own.
				local flat = cf * CFrame.Angles(math.rad(-pitch), 0, math.rad(-roll))
				-- No contacts over the wire, so the wheels ease toward rest
				-- rather than being told they are airborne. deltaTime so
				-- somebody else's car has the same unhurried suspension as
				-- your own rather than snapping between packets.
				drawWheels(entry.rig, flat, steer, spin, nil, deltaTime)

				-- Someone else's car gets the same treatment from the same
				-- code. The gear is what triggers a backfire, and comparing
				-- it against the last one we drew means the crack lands
				-- without a separate event having to survive the wire.
				local shifted = entry.lastGear ~= nil and a.gear > entry.lastGear
				entry.lastGear = a.gear

				-- Computed BEFORE the snapshot is marked, or marking it would
				-- make the test below false on the very frame it should fire.
				local bovNow = a.bov and entry.lastBov ~= a
				if a.bov then entry.lastBov = a end

				VehicleFX.Update(model, entry.rig, {
					rpm = a.rpm,
					gear = a.gear,
					spool = a.spool,
					-- Fired on the snapshot we are actually drawing, and only
					-- once: without the guard a valve would chirp every frame
					-- the buffer sat on the same packet.
					bov = bovNow,
					throttle = a.throttle,
					slipFront = a.slipFront,
					slipRear = a.slipRear,
					grounded = true,
					backfired = shifted and entry.def.horsepower >= entry.def.backfirePower,
				}, 0)
			end
		end
	end
end

--=====================================================================
-- UPDATE
--=====================================================================

-- Called from the frame loop BEFORE Physics, and returns whether it has taken
-- over. When it has, Physics must not run: two things writing the RawBody in
-- the same frame is exactly the fight this avoids.
function Vehicle.Update(deltaTime)
	drawObserved(deltaTime)

	-- Before the seated early-out, so a +use on foot next to a car is caught
	-- here. Weapons runs later in the frame and picks up whatever survives,
	-- which is what makes the key mean "get in" by a car and "pick that up"
	-- everywhere else without either module knowing about the other.
	Vehicle.TryConsumeUse()

	if not seatModel then return false end

	-- The car was removed underneath us. The server announces this, but a
	-- despawn during a network hiccup would otherwise leave us driving a
	-- destroyed model.
	if not seatModel.Parent then
		onStateChange({ vehicle = seatModel, userId = plr.UserId, entered = false })
		return false
	end

	local def = VehicleDefs.GetOrDerive(seatModel:GetAttribute("Class"))
	local rig = (sim and sim.rig) or VehicleDefs.Rig(seatModel, def)
	if not rig then return false end

	if sim then
		local hz = num(Config.sv_PhysicsHz, 60)
		local fixedDelta = 1 / hz

		accumulator = math.min(accumulator + deltaTime,
			fixedDelta * num(Config.sv_MaxCatchupSteps, 8))

		while accumulator >= fixedDelta do
			-- BOTH frames are carried, because the body and the wheels are
			-- drawn from different ones -- see below.
			sim.prevRenderCf = sim.renderCf or sim.cf
			sim.prevPhysicsCf = sim.cf
			step(sim, fixedDelta)
			accumulator -= fixedDelta
		end

		-- Rendered between the last two steps, exactly as the player is. The
		-- car is simulated at a fixed rate and drawn at the display rate, and
		-- without this the difference reads as stutter at any frame rate that
		-- is not an exact multiple of the tick.
		local alpha = math.clamp(accumulator / fixedDelta, 0, 1)
		local renderCf = (sim.prevRenderCf or sim.cf):Lerp(sim.renderCf or sim.cf, alpha)
		local physicsCf = (sim.prevPhysicsCf or sim.cf):Lerp(sim.cf, alpha)

		-- The BODY gets the render frame, which leans.
		seatModel:PivotTo(renderCf)

		-- The WHEELS get the physics frame, which does not.
		--
		-- PivotTo has just moved them along with everything else, so this
		-- overrides them, and the order matters. Drawing the wheels in the
		-- render frame tilts them with the body, which is a car milled from a
		-- single block: the whole point of independent suspension is that the
		-- body leans and the wheels stay flat on the road. That is what "the
		-- wheels look stuck onto the chassis" was -- the travel was working
		-- the whole time, but every wheel was leaning with the shell.
		drawWheels(rig, physicsCf, sim.steer, sim.wheelSpin, sim.contacts, deltaTime)

		-- Everything you can hear or see but that does not move the car. Fed
		-- the sim's own numbers; it publishes nothing back.
		VehicleFX.Update(seatModel, rig, {
			rpm = sim.rpm,
			gear = sim.gear,
			spool = sim.spool,
			bov = sim.bov,
			throttle = math.clamp(num(State.vehicleThrottleAxis, 0), 0, 1),
			slipFront = sim.slipFront,
			slipRear = sim.slipRear,
			-- PER WHEEL, when we have it. Only the driver's own sim does:
			-- an observed car is drawn from a packet that carries the two end
			-- values, so it falls back to those and looks exactly as it did.
			wheelSlip = sim.wheelSlip,
			fanSpeed = sim.fanSpeed,
			grounded = (sim.groundFrac or 0) > 0.01,
			backfired = sim.backfired,
		}, deltaTime)

		State.vehicleSpeed = math.abs(sim.roadSpeed or 0)
		State.vehicleSlip = sim.slip or 0
		State.vehicleGrounded = (sim.groundFrac or 0) > 0.01

		-- Published for the debug panel and anything else that wants to read
		-- the car rather than ask it. Kept here rather than written from
		-- inside step(), so the sim stays a pure function of its own state.
		State.vehicleRpm = sim.rpm
		State.vehicleGear = sim.gear
		State.vehicleCoolant = sim.coolantTemp
		State.vehicleOil = sim.oilTemp
		State.vehicleOverheating = sim.overheating == true
		State.vehicleSurface = sim.surface
		State.vehicleSlipFront = sim.slipFront
		State.vehicleSlipRear = sim.slipRear
		State.vehicleWheelSlip = sim.wheelSlip
		State.vehicleContacts = sim.contacts
		State.vehicleSpool = sim.spool
		State.vehicleFan = sim.fanSpeed
		State.vehicleFanOn = sim.fanOn == true
		State.vehicleCranking = (sim.crankRemaining or 0) > 0
		State.vehicleDef = sim.def
		-- THE ATTITUDE, against the ground rather than against the world: on
		-- a bank the two differ by the bank, and the one that says how close
		-- the car is to going over is the first.
		State.vehicleRoll = sim.rollLean
		State.vehiclePitch = sim.pitchLean
		State.vehicleDrive = sim.def.driveLayout
		State.vehicleDriveGrip = sim.driveGrip
	else
		State.vehicleSpeed = 0
	end

	parkBody(rig, seatIndex or 1)
	updateCamera(seatModel, def, deltaTime)

	return true
end

-- Fired on Heartbeat, not per frame: the server relays to everyone else and
-- there is no point sending faster than they can receive.
-- Rate limited, and NOT to the frame rate.
--
-- It ran on Heartbeat, so a driver sent sixty packets a second, each of which
-- the server relays to every other player -- the cost is one send times the
-- whole server, sixty times a second, to feed receivers who interpolate
-- behind a cl_interp buffer an order of magnitude longer than the gap between
-- packets. Nobody can see the difference and everybody pays for it.
local lastSyncAt = 0

function Vehicle.Sync()
	if not sim then return end

	local hz = num(Config.cl_vehicle_synchz, 20)
	if hz > 0 then
		local now = os.clock()
		if now - lastSyncAt < 1 / hz then return end
		lastSyncAt = now
	end

	local send = remote("VehicleSync")
	if not send then return end

	send:FireServer({
		vehicle = sim.model,
		-- What it LOOKS like, so other clients see the same lean the driver
		-- does. The server only reads the position out of this.
		cf = sim.renderCf or sim.cf,
		-- The body lean, so the receiver can recover the PHYSICS frame and
		-- draw the wheels flat on the road. Two numbers is cheaper than a
		-- second CFrame and exact, since the render frame is just the
		-- physics one with these applied.
		roll = sim.rollDrawn,
		pitch = sim.pitchDrawn,
		rpm = sim.rpm,
		gear = sim.gear,
		spool = sim.spool,
		bov = sim.bov,
		throttle = math.clamp(num(State.vehicleThrottleAxis, 0), 0, 1),
		slipFront = sim.slipFront,
		slipRear = sim.slipRear,
		vel = sim.vel,
		steer = sim.steer,
		wheelSpin = sim.wheelSpin,
	})
end

function Vehicle.IsDriving() return sim ~= nil end
function Vehicle.IsSeated() return seatModel ~= nil end
function Vehicle.Current() return seatModel, seatIndex end
function Vehicle.Sim() return sim end

--=====================================================================
-- INIT
--=====================================================================

function Vehicle.Init()
	local state = remote("VehicleState")
	if state then
		state.OnClientEvent:Connect(onStateChange)
	else
		-- Not fatal, and worth saying out loud: without the server half this
		-- module is inert rather than broken.
		warn("[Vehicle] VehicleState is missing -- is VehicleServer in ServerScriptService.Glacier1?")
	end

	local sync = remote("VehicleSync")
	if sync then sync.OnClientEvent:Connect(pushObserved) end
end

--=====================================================================
-- DIAGNOSTICS
--=====================================================================
-- CLIENT side, unlike vehicle_rig, because the effects only exist here: the
-- server has never looked for an emitter and cannot tell you whether one was
-- found. The two commands answer the two halves of the same question -- what
-- the sim measured, and what the art turned into.

Config.Command("vehicle_fx", {
	args = {},
	help = "print the sounds and emitters found on the car you are in",
	run = function(ctx)
		local model = seatModel
		local rig = sim and sim.rig

		-- Not driving: report whatever car is being watched, so this is
		-- usable from a passenger seat or standing beside one.
		if not (model and rig) then
			for watched, entry in pairs(observed) do
				if entry.rig then
					model, rig = watched, entry.rig
					break
				end
			end
		end

		if not (model and rig) then
			ctx.reply("[fx] not in or near a vehicle")
			return
		end

		-- The LIVE numbers alongside the instances, when we have a sim to read
		-- them from. A report that shows a fan sound was found says nothing
		-- about why it is not making a noise; the coolant temperature beside
		-- the thresholds does.
		ctx.reply(table.concat(
			VehicleFX.Report(model, rig, (sim and model == seatModel) and sim or nil), "\n"))
	end,
})

return Vehicle
