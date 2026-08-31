-- ModuleScript: ViewSway
-- Inertial viewmodel motion. Distinct from ViewBob, which is a periodic
-- function of distance travelled; this is a response to CHANGES in view
-- angle and velocity, plus discrete impulses from jump and landing.
--
-- Produces a single CFrame in viewmodel-local space (X right, Y up, -Z
-- forward). Visuals composes it onto the pivot; nothing here touches the
-- camera, so the gun can lag without the crosshair lagging with it.
--
-- Everything is a smoothed chase toward a target derived from current
-- state, so there is no accumulation and no drift. A teleport or respawn
-- produces one large angular delta, which is discarded rather than fed in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local State  = require(script.Parent.State)

local ViewSway = {}

ViewSway.offset = CFrame.identity

--=====================================================================
-- INTERNAL STATE
--=====================================================================

local lastCamX, lastCamY = nil, nil

local lagYaw, lagPitch     = 0, 0
local lagPosX, lagPosY     = 0, 0
local movX, movY, movZ     = 0, 0, 0
local movRoll              = 0
local sprintBlend          = 0

-- Impulse spring: one vertical axis, pitch is derived from it.
local springPos, springVel = 0, 0

--=====================================================================
-- HELPERS
--=====================================================================

local SNAP_DEG = 45   -- single-frame view change above this is a teleport

local function wrapDeg(a)
	return (a + 180) % 360 - 180
end

local function approach(current, target, rate, dt)
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

local function clampAbs(v, limit)
	return math.clamp(v, -limit, limit)
end

-- Damped harmonic oscillator. Substepped: at low frame rates a single
-- explicit Euler step on a stiff spring diverges instead of settling.
local function stepSpring(x, v, dt, freq, damp)
	local omega = 2 * math.pi * freq
	local steps = math.clamp(math.ceil(dt / (1 / 120)), 1, 8)
	local h = dt / steps
	for _ = 1, steps do
		local accel = -(omega * omega) * x - (2 * damp * omega) * v
		v = v + accel * h
		x = x + v * h
	end
	return x, v
end

--=====================================================================
-- IMPULSES
--=====================================================================

-- Called from PhysicsKinematic at the moment of takeoff.
function ViewSway.Jump()
	if Config.vm_sway == false then return end
	springPos = springPos - (Config.vm_jumpKick or 0.22)
end

-- Called from PhysicsKinematic on the airborne -> grounded transition.
-- impactY is the vertical velocity at the moment of contact (negative).
function ViewSway.Land(impactY)
	if Config.vm_sway == false then return end
	local speed = math.abs(impactY or 0)
	local dip = math.min(speed * (Config.vm_landDip or 0.0055),
		Config.vm_landDipMax or 0.55)
	if dip < 0.005 then return end
	springPos = springPos - dip
	springVel = springVel - dip * 6   -- bias the spring downward, not just offset it
end

-- Respawn, weapon rebuild, spectate exit. Everything back to rest.
function ViewSway.Reset()
	lastCamX, lastCamY = nil, nil
	lagYaw, lagPitch = 0, 0
	lagPosX, lagPosY = 0, 0
	movX, movY, movZ = 0, 0, 0
	movRoll = 0
	sprintBlend = 0
	springPos, springVel = 0, 0
	ViewSway.offset = CFrame.identity
end

--=====================================================================
-- UPDATE
--=====================================================================

-- speed is horizontal studs/second, already computed by Visuals.
function ViewSway.Update(deltaTime, speed)
	local dt = math.max(deltaTime or 0, 1e-5) * (State.timeScale or 1)

	if Config.vm_sway == false then
		ViewSway.offset = CFrame.identity
		return
	end

	--------------------------------------------------------------
	-- 1. MOUSE LAG
	--------------------------------------------------------------
	-- Keyed off State.cameraX/Y, which are pure mouse input. Recoil punch
	-- is deliberately excluded: it already moves the whole camera, and
	-- letting it drive sway as well would double the visible kick.
	local camX, camY = State.cameraX or 0, State.cameraY or 0

	local dYaw, dPitch = 0, 0
	if lastCamX and lastCamY then
		dYaw   = wrapDeg(camX - lastCamX)
		dPitch = wrapDeg(camY - lastCamY)
		if math.abs(dYaw) > SNAP_DEG or math.abs(dPitch) > SNAP_DEG then
			dYaw, dPitch = 0, 0
		end
	end
	lastCamX, lastCamY = camX, camY

	-- Degrees per second, so the result does not scale with frame rate.
	local yawRate   = dYaw / dt
	local pitchRate = dPitch / dt

	local lagRate = Config.vm_lagSmooth or 11
	local lagMax  = Config.vm_lagMax or 6
	local posMax  = Config.vm_lagPosMax or 0.35

	lagYaw   = approach(lagYaw,
		clampAbs(yawRate * (Config.vm_lagYaw or -0.010), lagMax), lagRate, dt)
	lagPitch = approach(lagPitch,
		clampAbs(pitchRate * (Config.vm_lagPitch or -0.008), lagMax), lagRate, dt)
	lagPosX  = approach(lagPosX,
		clampAbs(yawRate * (Config.vm_lagPosX or -0.0022), posMax), lagRate, dt)
	lagPosY  = approach(lagPosY,
		clampAbs(pitchRate * (Config.vm_lagPosY or -0.0018), posMax), lagRate, dt)

	--------------------------------------------------------------
	-- 2. MOVEMENT SWAY
	--------------------------------------------------------------
	-- Velocity is resolved into VIEW space, not world space, so strafing
	-- pushes the gun sideways regardless of which way you happen to face.
	local vel = State.velocity or Vector3.zero
	local yawCF = CFrame.Angles(0, math.rad(camX), 0)
	local localVel = yawCF:VectorToObjectSpace(Vector3.new(vel.X, 0, vel.Z))

	local moveMax  = Config.vm_moveMax or 0.50
	local moveRate = Config.vm_moveSmooth or 7

	-- localVel.X is strafe-right, localVel.Z is backward (-Z is forward).
	local tX = clampAbs(-localVel.X * (Config.vm_moveSide or 0.010), moveMax)
	local tZ = clampAbs(-localVel.Z * (Config.vm_moveFwd or 0.005), moveMax)

	-- Falling means the camera is accelerating downward and the gun is not,
	-- so it rides high. Sign inverts naturally on the way up.
	local tY = clampAbs(-vel.Y * (Config.vm_moveVert or 0.008), moveMax)

	local tRoll = clampAbs(-localVel.X * (Config.vm_moveRoll or 0.035),
		Config.vm_moveRollMax or 5)

	movX    = approach(movX, tX, moveRate, dt)
	movY    = approach(movY, tY, moveRate, dt)
	movZ    = approach(movZ, tZ, moveRate, dt)
	movRoll = approach(movRoll, tRoll, moveRate, dt)

	--------------------------------------------------------------
	-- 3. IMPULSE SPRING
	--------------------------------------------------------------
	springPos, springVel = stepSpring(springPos, springVel, dt,
		Config.vm_springFreq or 4.5, Config.vm_springDamp or 0.42)

	if math.abs(springPos) < 0.0005 and math.abs(springVel) < 0.005 then
		springPos, springVel = 0, 0
	end

	-- Pitch is derived from the dip rather than sprung separately: they are
	-- the same physical event, and two springs at slightly different rates
	-- read as a wobble.
	local springPitch = springPos * (Config.vm_landPitch or 45)

	--------------------------------------------------------------
	-- 4. SPRINT POSE
	--------------------------------------------------------------
	local wantSprint = 0
	if Config.vm_sprintPose ~= false
		and State.isSprinting
		and State.isGrounded
		and not State.isReloading
		and (speed or 0) > 1.5
	then
		wantSprint = 1
	end
	sprintBlend = approach(sprintBlend, wantSprint, Config.vm_sprintBlend or 8, dt)

	local sb = sprintBlend

	--------------------------------------------------------------
	-- 5. COMPOSE
	--------------------------------------------------------------
	local px = lagPosX + movX + (Config.vm_sprintX or 0.25) * sb
	local py = lagPosY + movY + springPos + (Config.vm_sprintY or -0.18) * sb
	local pz = movZ + (Config.vm_sprintZ or 0.15) * sb

	local rPitch = lagPitch + springPitch + (Config.vm_sprintPitch or -8) * sb
	local rYaw   = lagYaw + (Config.vm_sprintYaw or 22) * sb
	local rRoll  = movRoll + (Config.vm_sprintRoll or -12) * sb

	ViewSway.offset = CFrame.new(px, py, pz)
		* CFrame.Angles(math.rad(rPitch), math.rad(rYaw), math.rad(rRoll))
end

return ViewSway