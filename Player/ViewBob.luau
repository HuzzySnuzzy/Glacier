-- ModuleScript: ViewBob
-- Source-lineage view motion: CalcViewmodelBob / AddViewmodelBob (HL2, CS:GO)
-- plus DecayPunchAngle. This is NOT GoldSrc V_CalcBob -- differences are
-- called out inline where they matter.
--
-- Produces two offsets each frame:
--   ViewBob.camOffset -- punch only. Source's punchangle is a VIEW angle.
--   ViewBob.vmOffset  -- bob only. Source bobs the viewmodel, never the view.
--
-- The split is load-bearing. Visuals sets cam.CFrame from camOffset and THEN
-- builds the viewmodel from cam.CFrame, so the gun already inherits
-- everything camOffset contains. Anything in both lands twice.
--
-- Not handled here, deliberately:
--   velocity roll -- Physics publishes State.cameraRoll, Visuals applies it
--   mouse/movement sway -- ViewSway owns the vm_lag* / vm_move* cvars
--
-- AMPLITUDE: Source's numbers are transcribed exactly, then scaled by
-- cl_bobAmtVert/Lat and cl_bobTrans on the way out. Faithful Source bob is
-- angle-dominant and very small -- 0.9 degrees of roll and under a fiftieth
-- of a stud of travel at run speed. Readable on a 90-degree HL2 view; not
-- readable here. Scaling on OUTPUT keeps the shape and dodges the (-7,+4)
-- unit clamp, which would otherwise flatten the top of the sine.

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
local State  = require(script.Parent.State)

local ViewBob = {}

ViewBob.camOffset = CFrame.identity
ViewBob.vmOffset  = CFrame.identity

-- Published for the debug HUD.
ViewBob.verticalBob = 0
ViewBob.lateralBob  = 0
ViewBob.bobSpeed    = 0

--=====================================================================
-- UNITS
--=====================================================================

-- The project's conversion, consistent with Config (mv_walkSpeed 22.7 = 250).
local UNITS_PER_STUD = 11

-- Source clamps the vertical bob to (-7, +4) units. Applied to the RAW bob,
-- before the output multipliers, exactly where Source applies it.
local BOB_CLAMP_MIN = -7 / UNITS_PER_STUD
local BOB_CLAMP_MAX =  4 / UNITS_PER_STUD

-- Source's angle coefficients are degrees PER SOURCE UNIT of bob, so unlike
-- the translation terms they do not survive the unit change untouched --
-- each picks up a factor of UNITS_PER_STUD. Values are the AddViewmodelBob
-- constants (0.5 roll, 0.4 pitch, 0.3 yaw) pre-multiplied.
local ROLL_PER_STUD  = 0.5 * UNITS_PER_STUD   -- 5.5 deg
local PITCH_PER_STUD = 0.4 * UNITS_PER_STUD   -- 4.4 deg
local YAW_PER_STUD   = 0.3 * UNITS_PER_STUD   -- 3.3 deg

-- AddViewmodelBob's translation weights. Dimensionless ratios of bob to
-- offset, so the stud conversion cancels out of these entirely.
local TRANS_VERT = 0.1
local TRANS_LAT  = 0.8

-- DecayPunchAngle's own clamps and deadzone.
local PUNCH_CLAMP      = 89
local PUNCH_DEADZONE   = 0.001
local PUNCH_SPRING_MAX = 2   -- springForceMagnitude is clamped to 2 in Source

--=====================================================================
-- INTERNAL
--=====================================================================

local bobTime   = 0
local lastSpeed = 0
local idleTime  = 0

local verticalBob, lateralBob = 0, 0
local lowerAmt = 0   -- smoothed, so it can't step when speed jumps

-- Punch decays as a torsional spring, not a linear fade -- the overshoot on
-- the way back is what reads as an impact rather than a slide.
local punchPitch, punchRoll = 0, 0
local punchPitchVel, punchRollVel = 0, 0

--=====================================================================
-- CalcViewmodelBob
--=====================================================================

-- Splits the cycle at cl_bobup so the up-stroke is faster than the down.
-- Unchanged from GoldSrc; this part Source inherited verbatim.
local function shapeCycle(t, period, bobUp)
	local cycle = t - math.floor(t / period) * period
	cycle = cycle / period

	if cycle < bobUp then
		return math.pi * cycle / bobUp
	end
	return math.pi + math.pi * (cycle - bobUp) / (1 - bobUp)
end

-- 30% constant + 70% sine, so the gun is never perfectly still while moving.
local function shapeAmplitude(speed, cycle)
	local bob = speed * (Config.cl_bob or 0.005)
	bob = bob * 0.3 + bob * 0.7 * math.sin(cycle)
	return math.clamp(bob, BOB_CLAMP_MIN, BOB_CLAMP_MAX)
end

local function calcBob(deltaTime, speed)
	-- Defaults to walk speed rather than Source's 320 units. Leaving it at
	-- 320 parks a running player at a 0.78 speed ratio, which stretches every
	-- cycle by 28% and is most of what reads as floatiness.
	local maxSpeed = math.max(Config.cl_bobMaxSpeed or 22.7, 0.01)

	-- CS:GO's speed slew limiter. Without it, stopping dead collapses the
	-- amplitude in one frame and the gun snaps. Source uses 320 u/s^2, which
	-- takes most of a second to spin up -- raise it if the ease-in drags.
	local slew = Config.cl_bobSpeedSlew or 0
	if slew > 0 then
		local maxDelta = slew * deltaTime
		speed = math.clamp(speed, lastSpeed - maxDelta, lastSpeed + maxDelta)
	end
	speed = math.clamp(speed, 0, maxSpeed)
	lastSpeed = speed

	local ratio = speed / maxSpeed
	ViewBob.bobSpeed = speed

	if Config.cl_bobInAir == false and not State.isGrounded then
		-- Freezing is a departure. Source lets the cycle run airborne
		-- specifically because stopping it snaps the gun on takeoff.
		return verticalBob, lateralBob, ratio
	end

	-- Source scales the advance of bobtime by the speed ratio, where GoldSrc
	-- advanced it with raw time and scaled only the amplitude. Walking slowly
	-- now slows the CYCLE instead of producing a fast wobble at low
	-- amplitude -- but it also means cl_bobcycle is a floor, not the period.
	bobTime = bobTime + deltaTime * ratio

	local bobCycle = math.max(Config.cl_bobcycle or 0.6, 0.01)
	local bobUp    = math.clamp(Config.cl_bobup or 0.5, 0.01, 0.99)

	verticalBob = shapeAmplitude(speed, shapeCycle(bobTime, bobCycle, bobUp))

	-- Lateral runs at HALF the frequency. Beating the two against each other
	-- traces the figure-eight the HL2 viewmodel makes; GoldSrc had no lateral
	-- term at all and moved on a single vertical line.
	lateralBob = shapeAmplitude(speed, shapeCycle(bobTime, bobCycle * 2, bobUp))

	return verticalBob, lateralBob, ratio
end

--=====================================================================
-- DecayPunchAngle
--=====================================================================

-- Ported from CBasePlayer::DecayPunchAngle rather than kept as an explicit
-- spring: the multiplicative damping stays stable at large dt where the
-- explicit form diverges, and the deadzone stops the micro-ringing that
-- leaves the view a hundredth of a degree off true forever.
local function decayPunch(deltaTime, stiffness, damping)
	if math.abs(punchPitch) < PUNCH_DEADZONE
		and math.abs(punchRoll) < PUNCH_DEADZONE
		and math.abs(punchPitchVel) < PUNCH_DEADZONE
		and math.abs(punchRollVel) < PUNCH_DEADZONE then
		punchPitch, punchRoll = 0, 0
		punchPitchVel, punchRollVel = 0, 0
		return
	end

	punchPitch = punchPitch + punchPitchVel * deltaTime
	punchRoll  = punchRoll  + punchRollVel  * deltaTime

	local decay = math.max(1 - damping * deltaTime, 0)
	punchPitchVel = punchPitchVel * decay
	punchRollVel  = punchRollVel  * decay

	local spring = math.clamp(stiffness * deltaTime, 0, PUNCH_SPRING_MAX)
	punchPitchVel = punchPitchVel - punchPitch * spring
	punchRollVel  = punchRollVel  - punchRoll  * spring

	punchPitch = math.clamp(punchPitch, -PUNCH_CLAMP, PUNCH_CLAMP)
	punchRoll  = math.clamp(punchRoll,  -PUNCH_CLAMP, PUNCH_CLAMP)
end

--=====================================================================
-- PUBLIC
--=====================================================================

-- Kick the view. Positive pitch looks up (recoil), negative dips (landing).
-- Accumulates into VELOCITY, not position -- two kicks in one frame add.
function ViewBob.Punch(pitch, roll)
	punchPitchVel = punchPitchVel + (pitch or 0)
	punchRollVel  = punchRollVel  + (roll or 0)
end

function ViewBob.Reset()
	bobTime, idleTime, lastSpeed = 0, 0, 0
	verticalBob, lateralBob = 0, 0
	lowerAmt = 0
	punchPitch, punchRoll = 0, 0
	punchPitchVel, punchRollVel = 0, 0
	ViewBob.verticalBob, ViewBob.lateralBob, ViewBob.bobSpeed = 0, 0, 0
	ViewBob.camOffset = CFrame.identity
	ViewBob.vmOffset  = CFrame.identity
end

function ViewBob.Update(deltaTime, speed)
	if Config.cl_bobEnabled == false then
		ViewBob.camOffset = CFrame.identity
		ViewBob.vmOffset  = CFrame.identity
		return
	end

	-- A frame spike shouldn't lurch the view, and the timescale factor keeps
	-- bob in step with animations and viewmodel pushback, which already scale.
	deltaTime = math.min(math.max(deltaTime, 0), 1 / 15) * (State.timeScale or 1)
	if deltaTime <= 0 then return end

	local vBob, lBob, speedRatio = calcBob(deltaTime, speed or 0)

	-- Output scaling, after the Source clamp. cl_bobAmt* is the master and
	-- moves translation and angle together, preserving the angle-dominant
	-- character; cl_bobTrans then lifts translation alone, because Source's
	-- 0.1 weight is invisible at this scale.
	vBob = vBob * (Config.cl_bobAmtVert or 1)
	lBob = lBob * (Config.cl_bobAmtLat or 1)
	local trans = Config.cl_bobTrans or 1

	ViewBob.verticalBob, ViewBob.lateralBob = vBob, lBob

	decayPunch(deltaTime,
		Config.cl_punchStiffness or 65,
		Config.cl_punchDamping or 9)

	--------------------------------------------------------------
	-- CAMERA  (punch only)
	--------------------------------------------------------------
	-- No bob translation and no roll here. Velocity roll is Physics' via
	-- State.cameraRoll; bob is Source-viewmodel-only. Either one placed here
	-- reaches the gun a second time through cam.CFrame inheritance.
	local idleScale = Config.cl_idleScale or 0
	local idlePitch, idleYaw, idleRoll = 0, 0, 0
	if idleScale > 0 then
		-- Retained for scripted shake, off by default. Source's v_idlescale
		-- drives damage and scripted effects, never an ambient drift.
		idleTime = idleTime + deltaTime
		idlePitch = math.sin(idleTime * 1.0) * 0.03 * idleScale
		idleYaw   = math.sin(idleTime * 0.7) * 0.04 * idleScale
		idleRoll  = math.sin(idleTime * 0.5) * 0.05 * idleScale
	end

	local camBobY = (Config.cl_bobCamera and vBob * TRANS_VERT * trans * 5) or 0

	ViewBob.camOffset = CFrame.new(0, camBobY, 0)
		* CFrame.Angles(
			math.rad(punchPitch + idlePitch),
			math.rad(idleYaw),
			math.rad(punchRoll + idleRoll)
		)

	--------------------------------------------------------------
	-- VIEWMODEL  (AddViewmodelBob)
	--------------------------------------------------------------
	-- Local space: +X right, +Y up, -Z forward. Source pushes the gun along
	-- forward and right by the bob, which is why the motion tilts with the
	-- weapon rather than sliding on screen axes.

	-- Settle at speed. Smoothed rather than driven straight off speedRatio:
	-- as a raw term it steps whenever speed does, and at anything above a
	-- couple of hundredths it becomes a static droop larger than the
	-- oscillation riding on it -- which reads as the bob having died.
	local targetLower = (Config.cl_bobLowerAmt or 0) * speedRatio
	lowerAmt = lowerAmt + (targetLower - lowerAmt) * (1 - math.exp(-8 * deltaTime))

	local ox = lBob * TRANS_LAT  * trans
	local oy = vBob * TRANS_VERT * trans - lowerAmt
	local oz = -vBob * TRANS_VERT * trans + lowerAmt * 0.5   -- +Z is back toward the player

	ViewBob.vmOffset = CFrame.new(ox, oy, oz)
		* CFrame.Angles(
			math.rad(-vBob * PITCH_PER_STUD),
			math.rad(-lBob * YAW_PER_STUD),
			math.rad(vBob * ROLL_PER_STUD)
		)
	-- No punch term. The viewmodel is built from cam.CFrame downstream, so it
	-- has already inherited every punch degree from camOffset above.
end

return ViewBob