-- ModuleScript: Physics
-- Fully kinematic movement. The body is ANCHORED; Roblox's solver never moves
-- it. We own position, velocity, gravity and collision entirely.
--
-- Collision geometry is boxes, including rotated clip brushes standing in for
-- wedges. Sweeps use Blockcast (exact for boxes); overlap tests use SAT so
-- rotated brushes resolve correctly.
--
-- Requires in State: velocity, coyoteTimer, jumpBufferTimer, groundNormal,
--                    duckLift, sgsGrace, wantsStand, forwardMoveAxis,
--                    surfaceFriction, brakingWindowElapsed, ladderTimeout,
--                    prevCrouchStance, duckFraction, isDucked, isProneStance,
--                    cameraRoll, noclip
-- Requires in Character.Spawn: body.Anchored = true, body.CanCollide = false

local CollectionService = game:GetService("CollectionService")
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
local State   = require(script.Parent.State)
local Math    = require(script.Parent.MovementMath)
local Visuals = require(script.Parent.Visuals)
local Sounds  = require(script.Parent.Sounds)
local ViewBob = require(script.Parent.ViewBob)
local ViewSway = require(script.Parent.ViewSway)

local Physics = {}

local accumulator = 0

local MAX_BUMPS = 4          -- planes resolved against per move
local SKIN = 0.02            -- gap kept between hull and geometry
local GROUND_NORMAL_Y = 0.75 -- steeper than this is not walkable (~41 degrees)
local DEPEN_EPS = 0.001      -- overlap below this is float noise
local EPS = 1e-4

-- LADDER

local function ladderNormalFor(part, playerPos)
	local lp = part.CFrame:PointToObjectSpace(playerPos)
	local half = part.Size * 0.5
	local rx, ry, rz = math.abs(lp.X)/half.X, math.abs(lp.Y)/half.Y, math.abs(lp.Z)/half.Z

	local axis
	if rx >= ry and rx >= rz then
		axis = Vector3.new(math.sign(lp.X), 0, 0)
	elseif rz >= ry then
		axis = Vector3.new(0, 0, math.sign(lp.Z))
	else
		axis = Vector3.new(0, math.sign(lp.Y), 0)
	end
	return part.CFrame:VectorToWorldSpace(axis)
end

local function findLadder(pos, size, op)
	local reach = Config.mv_ladderGrabRange or 0.6
	local probe = size + Vector3.new(reach * 2, 0, reach * 2)
	for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(pos), probe, op)) do
		if CollectionService:HasTag(part, "Ladder") then
			return part, ladderNormalFor(part, pos)
		end
	end
	return nil
end

--=====================================================================
-- OBB INTERSECTION  (Separating Axis Theorem)
--=====================================================================

-- Tests our hull (world-axis-aligned, since Blockcast uses identity rotation)
-- against a part's oriented box. Returns the minimum translation vector: a
-- unit axis pointing AWAY from the part, plus the penetration depth.
--
-- 15 candidate axes: 3 ours, 3 theirs, 9 cross products. The cross products
-- catch edge-on-edge contact, which is exactly what a tilted ramp produces --
-- skipping them makes depenetration push along the slope instead of out of it.
local function IntersectOBB(centreA, halfA, part)
	local cf = part.CFrame
	local bx, by, bz = cf.RightVector, cf.UpVector, cf.LookVector
	local halfB = part.Size * 0.5
	local delta = part.Position - centreA

	local bestAxis, bestDepth = nil, math.huge

	local function test(L)
		local lenSq = L:Dot(L)
		if lenSq < 1e-12 then return true end -- degenerate (parallel axes)
		local axis = L / math.sqrt(lenSq)

		local rA = math.abs(axis.X) * halfA.X
			+ math.abs(axis.Y) * halfA.Y
			+ math.abs(axis.Z) * halfA.Z
		local rB = math.abs(bx:Dot(axis)) * halfB.X
			+ math.abs(by:Dot(axis)) * halfB.Y
			+ math.abs(bz:Dot(axis)) * halfB.Z

		local dist = delta:Dot(axis)
		local overlap = rA + rB - math.abs(dist)
		if overlap <= 0 then return false end -- separating axis found

		if overlap < bestDepth then
			bestDepth = overlap
			bestAxis = (dist > 0) and -axis or axis
		end
		return true
	end

	if not test(Vector3.xAxis) then return nil end
	if not test(Vector3.yAxis) then return nil end
	if not test(Vector3.zAxis) then return nil end
	if not test(bx) then return nil end
	if not test(by) then return nil end
	if not test(bz) then return nil end

	for _, a in ipairs({Vector3.xAxis, Vector3.yAxis, Vector3.zAxis}) do
		for _, b in ipairs({bx, by, bz}) do
			if not test(a:Cross(b)) then return nil end
		end
	end

	return bestAxis, bestDepth
end

--=====================================================================
-- CASTING
--=====================================================================

-- Swept AABB: the GoldSrc hull, natively. Identity rotation means the hull
-- never turns with the camera, which is what makes CS collision deterministic.
local function Sweep(pos, size, displacement, params)
	if displacement.Magnitude < 1e-5 then return nil end
	return workspace:Blockcast(CFrame.new(pos), size, displacement, params)
end

-- Everything the movement hull must never see. Your own body and puppet,
-- obviously -- and dropped weapons, which are PROPS: a rifle lying on the
-- floor is not level geometry, and letting one into these casts means it
-- blocks a step, counts as "occupied" against an uncrouch, and can wedge you
-- against a wall. Every other system may still hit them; this is the one that
-- decides where a player can stand.
--
-- Re-looked-up rather than cached once: workspace.WeaponDrops is created by
-- the server and may not exist when this module loads, and a map reload can
-- replace it.
local dropFolder

local function ignoreList(body, puppet)
	if not (dropFolder and dropFolder.Parent) then
		dropFolder = workspace:FindFirstChild("WeaponDrops")
	end
	if dropFolder then return { body, puppet, dropFolder } end
	return { body, puppet }
end

local function MakeParams(body, puppet)
	local p = RaycastParams.new()
	p.FilterDescendantsInstances = ignoreList(body, puppet)
	p.FilterType = Enum.RaycastFilterType.Exclude
	return p
end

local function MakeOverlapParams(body, puppet)
	local op = OverlapParams.new()
	op.FilterDescendantsInstances = ignoreList(body, puppet)
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.MaxParts = 16
	return op
end

-- Broad phase: a bounds query gathers candidates (generous, since a rotated
-- part's AABB is much larger than the part). Narrow phase: SAT decides.
local function GatherCandidates(pos, size, op)
	return workspace:GetPartBoundsInBox(CFrame.new(pos), size * 1.5, op)
end

local function IsOccupied(pos, size, op, tolerance)
	tolerance = tolerance or 0.01
	local half = size * 0.5
	for _, part in ipairs(GatherCandidates(pos, size, op)) do
		if part.CanCollide then
			local _, depth = IntersectOBB(pos, half, part)
			if depth and depth > tolerance then return true end
		end
	end
	return false
end

--=====================================================================
-- SURFACE FRICTION  (Source: m_surfaceFriction, PB: GetFrictionFromHit)
--=====================================================================

-- Source scales BOTH friction and ground acceleration by the surface's
-- friction value, which is why ice feels slippery to stop on AND slow to get
-- moving on. PB clamps to 1.0 so only surfaces BELOW the reference matter.
-- Roblox's Plastic sits at 0.3, so that's our stand-in for Source's 1.0.
local function SurfaceFrictionFor(part)
	if not part or not (Config.mv_surfaceFriction ~= false) then return 1 end
	local props = part.CurrentPhysicalProperties
	if not props then return 1 end
	local ref = Config.mv_surfaceFrictionRef or 0.3
	if ref <= 0 then return 1 end
	return math.clamp(props.Friction / ref, Config.mv_minSurfaceFriction or 0.1, 1)
end

--=====================================================================
-- EDGE FRICTION  (Source PM_Friction)
--=====================================================================

-- Trace down from a point ahead of the feet. Nothing under it means we're
-- about to walk off a ledge, so friction is doubled. This is the entire
-- reason Source players can stop on a crate edge instead of sliding off.
local function EdgeFrictionMultiplier(pos, hullSize, vel, params, bodyScale, hasInput, ducked)
	local mult = Config.mv_edgeFriction or 2
	if mult <= 1 then return 1 end

	-- PB gates it to braking only; GoldSrc applied it unconditionally.
	if hasInput and (Config.mv_edgeFrictionOnlyWhenBraking ~= false) then
		if not (ducked and (Config.mv_edgeFrictionAlwaysWhenCrouching ~= false)) then
			return 1
		end
	end

	local flat = Vector3.new(vel.X, 0, vel.Z)
	if flat.Magnitude < 0.1 then return 1 end

	local ahead = flat.Unit * ((Config.mv_edgeFrictionDist or 1.45) * bodyScale)
	local origin = pos + ahead - Vector3.new(0, hullSize.Y * 0.5, 0)
	local depth = (Config.mv_edgeFrictionHeight or 3.1) * bodyScale

	local hit = workspace:Raycast(origin, Vector3.new(0, -depth, 0), params)
	return hit and 1 or mult
end

--=====================================================================
-- DEPENETRATION
--=====================================================================

-- Nothing pushes us out of geometry any more, so we do it ourselves. Pushing
-- along the minimum translation vector means a ramp ejects us perpendicular to
-- its face rather than sliding us down it.
local function Depenetrate(pos, size, op)
	local half = size * 0.5
	local candidates = GatherCandidates(pos, size, op)
	if #candidates == 0 then return pos end

	for _ = 1, 4 do
		local moved = false
		for _, part in ipairs(candidates) do
			if part.CanCollide then
				local axis, depth = IntersectOBB(pos, half, part)
				if axis and depth > DEPEN_EPS then
					pos = pos + axis * (depth + DEPEN_EPS)
					moved = true
				end
			end
		end
		if not moved then break end
	end

	return pos
end

--=====================================================================
-- MOVE AND SLIDE  (PM_FlyMove)
--=====================================================================

-- noUp: while grounded, never let a clip produce upward velocity. Clipping a
-- flat vector against a slope yields +Y, which launches us off ramps.
-- Step-up owns climbing.
local function MoveAndSlide(pos, vel, size, dt, params, noUp)
	local remaining = dt
	local planes = {}
	local blocked = false
	local overbounce = Config.mv_surfOverbounce or 1.0
	local boostFix = Config.mv_slopeBoostFix

	for _ = 1, MAX_BUMPS do
		if vel.Magnitude < 0.001 or remaining <= 0 then break end

		local displacement = vel * remaining
		local hit = Sweep(pos, size, displacement, params)

		if not hit then
			pos = pos + displacement
			break
		end

		blocked = true

		local travel = math.max(hit.Distance - SKIN, 0)
		pos = pos + vel.Unit * travel
		remaining = remaining - (travel / vel.Magnitude)

		-- Walkable surface while grounded: step-up owns it. Clipping here
		-- bleeds speed into +Y, and where two walkable planes meet -- a ramp
		-- crest -- the seam projection would zero us out entirely.
		if noUp and hit.Normal.Y >= GROUND_NORMAL_Y then break end

		-- Skip planes we already know, or the cross product below runs on two
		-- copies of the same normal and freezes us.
		local duplicate = false
		for _, p in ipairs(planes) do
			if p:Dot(hit.Normal) > 0.999 then duplicate = true break end
		end
		if not duplicate then table.insert(planes, hit.Normal) end

		local speedBefore = vel.Magnitude

		-- Accept the first clip that doesn't drive us into a known plane.
		local resolved = false
		for i, n in ipairs(planes) do
			local candidate = Math.ClipVelocity(vel, n, overbounce)

			-- Source's HandleSlopeBoosting. Clipping against a downward-facing
			-- ramp can RAISE speed -- that is surf. Off by default because
			-- turning it on kills surf maps outright.
			if boostFix and candidate.Magnitude > speedBefore and speedBefore > 0.001 then
				candidate = candidate.Unit * speedBefore
			end

			local ok = true
			for j, n2 in ipairs(planes) do
				if j ~= i and candidate:Dot(n2) < -0.01 then ok = false break end
			end
			if ok then
				vel = candidate
				resolved = true
				break
			end
		end

		-- Trapped between planes: the only legal direction is their seam.
		if not resolved then
			if #planes >= 2 then
				local dir = planes[1]:Cross(planes[2])
				if dir.Magnitude > 0.001 then
					vel = dir.Unit * vel:Dot(dir.Unit)
				else
					vel = Vector3.zero
					break
				end
			else
				vel = Vector3.zero
				break
			end
		end

		if noUp and vel.Y > 0 then
			vel = Vector3.new(vel.X, 0, vel.Z)
		end
	end

	return pos, vel, blocked
end

--=====================================================================
-- STEP UP  (PM_StepUp)
--=====================================================================

-- Run the move twice: once normally, once lifted by maxStep then dropped. Take
-- whichever got further horizontally. This is also how ramps are climbed --
-- velocity stays flat and the step machinery ascends, so horizontal speed is
-- never reduced by the slope angle.
local function MoveWithStep(pos, vel, size, dt, params, op, maxStep)
	local noUp = maxStep > 0 -- only true while grounded
	local flatPos, flatVel, blocked = MoveAndSlide(pos, vel, size, dt, params, noUp)

	if not blocked or maxStep <= 0 then
		return flatPos, flatVel
	end

	local upHit = Sweep(pos, size, Vector3.new(0, maxStep, 0), params)
	local upDist = upHit and math.max(upHit.Distance - SKIN, 0) or maxStep
	if upDist <= 0.01 then return flatPos, flatVel end

	local stepPos = pos + Vector3.new(0, upDist, 0)

	-- Never move across from a position we haven't confirmed is clear: sweeps
	-- originating inside geometry return nil and we'd pass straight through.
	if IsOccupied(stepPos, size, op) then return flatPos, flatVel end

	local acrossPos, acrossVel = MoveAndSlide(stepPos, vel, size, dt, params, noUp)

	local downHit = Sweep(acrossPos, size, Vector3.new(0, -(upDist + 0.1), 0), params)
	if not downHit or downHit.Normal.Y < GROUND_NORMAL_Y then
		return flatPos, flatVel
	end
	acrossPos = acrossPos + Vector3.new(0, -math.max(downHit.Distance - SKIN, 0), 0)

	-- The drop only checks the column beneath acrossPos, not what we straddle.
	if IsOccupied(acrossPos, size, op) then return flatPos, flatVel end

	local flatGain = (Vector3.new(flatPos.X, 0, flatPos.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude
	local stepGain = (Vector3.new(acrossPos.X, 0, acrossPos.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude

	if stepGain > flatGain then
		State.stepUpCount = (State.stepUpCount or 0) + 1
		-- Stepping up is a position change, not an upward launch.
		return acrossPos, Vector3.new(acrossVel.X, math.min(acrossVel.Y, 0), acrossVel.Z)
	end

	return flatPos, flatVel
end

--=====================================================================
-- STRAFE ASSIST
--=====================================================================

-- Air accel only gains while vel:Dot(wishDir) is under the cap, and holding
-- that requires continuous mouse rotation at an angle that narrows as you
-- speed up. This computes that angle; mv_strafeAssist controls how much of it
-- the player gets for free. 0 is authentic, 1 does it entirely for them.
local function AssistWishDir(wishDir, horizontalVel, targetSpeed, deltaTime, cap)
	local assist = Config.mv_strafeAssist or 0
	if assist <= 0 or wishDir.Magnitude < 0.1 then return wishDir end

	local speed = horizontalVel.Magnitude
	if speed < 0.5 then return wishDir end

	local velDir = horizontalVel.Unit
	local side = velDir:Cross(Vector3.yAxis)
	local sign = (wishDir:Dot(side) >= 0) and 1 or -1

	-- Aim just under the cap so the full accel step lands each tick rather
	-- than being clamped by addSpeed. Uses the EFFECTIVE cap, so an SGS
	-- boost widens the angle to match.
	local accelPerTick = Config.mv_airAcceleration * targetSpeed * deltaTime
	local targetProj = math.max(cap - accelPerTick, 0)
	local theta = math.acos(math.clamp(targetProj / speed, -1, 1))

	local ideal = (velDir * math.cos(theta)) + (side * sign * math.sin(theta))
	if ideal.Magnitude < 0.001 then return wishDir end

	return wishDir:Lerp(ideal.Unit, assist).Unit
end

--=====================================================================
-- CAMERA ROLL  (Source: sv_rollangle / sv_rollspeed, PB: GetCameraRoll)
--=====================================================================

-- Lateral velocity tilts the view. Published to State; Visuals applies it.
-- Uses the existing cl_rollangle / cl_rollspeed, which are already the
-- correct Source cvar names at the correct values.
local function UpdateCameraRoll(vel)
	local angle = Config.cl_rollangle or 0
	if angle <= 0 then State.cameraRoll = 0 return end

	local speed = Config.cl_rollspeed or 18.2
	local right = CFrame.Angles(0, math.rad(State.cameraX or 0), 0).RightVector
	local side = vel:Dot(right)
	local sign = side < 0 and -1 or 1
	side = math.abs(side)

	State.cameraRoll = ((side < speed) and (side * angle / speed) or angle) * sign
end

--=====================================================================
-- COMMIT
--=====================================================================

-- Shared by the normal path and the noclip early-out, so interpolation state
-- can never be left stale by whichever branch ran.
local function Commit(body, pos, vel, deltaTime)
	State.velocity = vel

	local rotation = Config.cl_noOrient
		and CFrame.identity
		or CFrame.Angles(0, math.rad(State.cameraX), 0)

	body.CFrame = CFrame.new(pos) * rotation
	body.AudioCanCollide = false
	State.pos = CFrame.new(pos) * rotation

	State.prevBodyPos  = State.curBodyPos or pos
	State.curBodyPos   = pos
	State.stepInterval = deltaTime
	State.tickAlpha    = 0

	body.Transparency = Config.cl_showbody and 0 or 1

	UpdateCameraRoll(vel)
end

--=====================================================================
-- MAIN LOOP
--=====================================================================

function Physics.Update(deltaTime)
	local hz = Config.sv_PhysicsHz or 60
	local fixedDelta = 1 / hz

	-- Clamped so a frame spike doesn't cause a burst of steps that causes the
	-- next spike. At high tickrates this needs headroom: 240Hz at 60fps is
	-- 4 steps per frame with nothing spare.
	accumulator = math.min(accumulator + deltaTime, fixedDelta * (Config.sv_MaxCatchupSteps or 8))

	local steps = 0
	while accumulator >= fixedDelta do
		Physics.Step(fixedDelta)
		accumulator = accumulator - fixedDelta
		steps += 1
	end
	Physics.stepsThisFrame = steps
end

function Physics.Step(deltaTime)
	Physics.stepCount = (Physics.stepCount or 0) + 1

	local body = State.playerBody
	local puppet = State.playerPuppet
	if not body or not puppet then return end

	local scaleValue = puppet:FindFirstChild("BodyScale")
	local bodyScale = (scaleValue and scaleValue:IsA("NumberValue")) and scaleValue.Value or 1
	local defaultSize = State.baseSize * bodyScale

	local params = MakeParams(body, puppet)
	local op = MakeOverlapParams(body, puppet)

	State.velocity = State.velocity or Vector3.zero
	local vel = State.velocity
	local pos = body.Position

	--------------------------------------------------------------
	-- 0. NOCLIP  (MOVETYPE_NOCLIP)
	--------------------------------------------------------------
	-- Bypasses every collision stage entirely, exactly as Source does. Vertical
	-- comes from jump/duck rather than view pitch, since wishDir is already
	-- flattened by the time it reaches us.
	if State.noclip then
		local speed = (Config.mv_noclipSpeed or 45) * (State.isWalking and 0.25 or 1)
		local wish = State.wishDir or Vector3.zero
		local move = Vector3.new(wish.X, 0, wish.Z)
		if move.Magnitude > 1 then move = move.Unit end
		move = move + Vector3.new(0, (State.spaceHeld and 1 or 0) - (State.cIsHeld and 1 or 0), 0)

		vel = move.Magnitude > 0.01 and move.Unit * speed or Vector3.zero
		pos = pos + vel * deltaTime

		State.isGrounded = false
		State.isJumping = false
		State.onLadder = false
		State.coyoteTimer = 0
		State.duckLift = 0

		Commit(body, pos, vel, deltaTime)
		return
	end

	--------------------------------------------------------------
	-- 1. STANCE + HITBOX  (PM_Duck, timed transitions)
	--------------------------------------------------------------
	local hullSize = body.Size - Vector3.new(SKIN * 2, SKIN * 2, SKIN * 2)

	local standY = defaultSize.Y
	local duckY  = defaultSize.Y * (Config.mv_crouchHeightFrac or 0.6)
	local proneY = defaultSize.Y * (Config.mv_proneHeightFrac or 0.3)

	-- Standing up is an intent, not an event: if there's no headroom on the
	-- tick the key is released we must keep trying, or the player is stuck
	-- crouched after walking clear.
	if State.wantsStand and (State.isCrouching or State.isProne) then
		local needed = (standY - body.Size.Y) + SKIN
		if needed <= 0 or Sweep(pos, hullSize, Vector3.new(0, needed, 0), params) == nil then
			State.isCrouching = false
			State.isProne = false
			State.wantsStand = false
		end
	end

	local targetSizeY = standY
	if State.isCrouching then
		targetSizeY = duckY
	elseif State.isProne then
		targetSizeY = proneY
	end

	-- Duck-lift fires on the tick the duck is REQUESTED, not on every tick the
	-- hull happens to be shrinking. With timed transitions the old test held
	-- true for 0.4s straight and left us permanently airborne.
	local crouchStance = State.isCrouching or State.isProne
	if Config.mv_groundStrafe and crouchStance and not State.prevCrouchStance and State.isGrounded then
		State.duckLift = math.ceil((Config.mv_duckLiftTime or 0.12) * (Config.sv_PhysicsHz or 100))
	end
	State.prevCrouchStance = crouchStance

	-- Source ducks over 0.4s on the ground but INSTANTLY in the air, which is
	-- what makes the crouch-jump snap the feet up. Uncrouching inverts it:
	-- fast on the ground, slow in the air, so you can't insta-extend to grab
	-- a ledge. Set all four times to 0 for the old instant behaviour.
	local currentY = body.Size.Y
	local newY = targetSizeY
	local delta = targetSizeY - currentY

	if math.abs(delta) > EPS then
		local shrinking = delta < 0
		local tTime
		if shrinking then
			tTime = State.isGrounded and (Config.mv_crouchTime or 0.4) or (Config.mv_crouchJumpTime or 0)
		else
			tTime = State.isGrounded and (Config.mv_uncrouchTime or 0.2) or (Config.mv_uncrouchJumpTime or 0.8)
		end

		if tTime > 0 then
			-- Rate is derived from the FULL crouch span, so a partial
			-- transition moves at the same speed as a complete one.
			local stepY = ((standY - duckY) / tTime) * deltaTime
			if math.abs(delta) > stepY then
				newY = currentY + (shrinking and -stepY or stepY)
			end
		end
	end

	local sizeDiffY = newY - currentY
	if math.abs(sizeDiffY) > EPS then
		local candidateSize = Vector3.new(defaultSize.X, newY, defaultSize.Z)
		local candidateHull = candidateSize - Vector3.new(SKIN * 2, SKIN * 2, SKIN * 2)

		-- Grounded: feet stay planted, head moves.
		-- Airborne: shrink keeps the top edge fixed (feet tuck up, the
		-- crouch-jump); grow is the exact inverse. Anything else nets free
		-- altitude on every crouch/uncrouch cycle.
		local candidatePos = State.isGrounded
			and (pos + Vector3.new(0, sizeDiffY / 2, 0))
			or  (pos - Vector3.new(0, sizeDiffY / 2, 0))

		-- Growth is re-tested every tick, not just at the start: the player can
		-- walk under a lip halfway through a 0.8s air-uncrouch. Blocked ticks
		-- freeze the transition instead of cancelling it.
		if sizeDiffY < 0 or not IsOccupied(candidatePos, candidateHull, op) then
			body.Size = candidateSize
			hullSize = candidateHull
			pos = candidatePos
		end
	end

	State.isInStanceTransition = math.abs(body.Size.Y - targetSizeY) > EPS
	State.duckFraction = math.clamp((standY - body.Size.Y) / math.max(standY - duckY, EPS), 0, 1)
	State.isDucked = body.Size.Y <= duckY + 1e-3
	State.isProneStance = body.Size.Y <= proneY + 1e-3

	-- Speed follows the HULL, not the keypress: in Source you keep run speed
	-- until the duck actually completes. mv_instantCrouchSpeed restores the
	-- intent-driven behaviour.
	local instantSpeed = Config.mv_instantCrouchSpeed
	local proneForSpeed  = instantSpeed and State.isProne or State.isProneStance
	local duckedForSpeed = instantSpeed and State.isCrouching or State.isDucked

	local targetSpeed = Config.mv_walkSpeed
	if proneForSpeed then
		targetSpeed = Config.mv_proneSpeed
	elseif duckedForSpeed then
		targetSpeed = Config.mv_crouchSpeed
	elseif State.isWalking then
		targetSpeed = Config.mv_walkKeySpeed
	end

	--------------------------------------------------------------
	-- 2. DEPENETRATE
	--------------------------------------------------------------
	-- Published per tick, not accumulated: a nonzero value means the hull is
	-- inside geometry RIGHT NOW, which is the diagnostic you want.
	local depenPushes
	pos, depenPushes = Depenetrate(pos, hullSize, op)
	State.depenCount = depenPushes
	pos = Depenetrate(pos, hullSize, op)

	--------------------------------------------------------------
	-- 3. GROUND DETECTION
	--------------------------------------------------------------
	local groundNormal = Vector3.yAxis
	local wasGrounded = State.isGrounded

	if State.isJumping and vel.Y <= 0 then
		State.isJumping = false
	end

	State.duckLift = math.max((State.duckLift or 0) - 1, 0)

	if not State.isJumping and State.duckLift <= 0 then
		-- Shrunk horizontally so the probe doesn't scrape flush walls and
		-- report them as ground.
		local probeSize = Vector3.new(hullSize.X * 0.95, hullSize.Y, hullSize.Z * 0.95)
		local groundHit = Sweep(pos, probeSize, Vector3.new(0, -(0.15 * bodyScale), 0), params)

		if groundHit and groundHit.Normal.Y >= GROUND_NORMAL_Y then
			State.isGrounded = true
			groundNormal = groundHit.Normal
			State.groundInstance = groundHit.Instance
			State.groundMaterial = groundHit.Instance and groundHit.Instance.Material or nil
			-- Source keeps the last known value while airborne rather than
			-- resetting to 1, so a jump off ice still lands on ice.
			State.surfaceFriction = SurfaceFrictionFor(groundHit.Instance)
			if State.isDiving then State.isDiving = false end
		else
			State.isGrounded = false
		end
	else
		State.isGrounded = false
	end

	State.groundNormal = groundNormal

	if State.isGrounded and not wasGrounded then
		Sounds.Push("land", vel.Y)
		ViewBob.Punch(-math.abs(vel.Y) * 0.35, 0)
		ViewSway.Land(vel.Y)
		State.dbgJumpHeight = 0
	end

	--------------------------------------------------------------
	-- 4. TIMERS
	--------------------------------------------------------------
	if State.isGrounded then
		State.coyoteTimer = Config.mv_coyoteTime or 0
		State.dbgAirtime = 0
		-- PB's braking window: friction is withheld until we've been on the
		-- ground long enough. This is what lets a frame-perfect bhop keep all
		-- of its speed instead of paying one tick of friction.
		State.brakingWindowElapsed = (State.brakingWindowElapsed or 0) + deltaTime
	else
		State.coyoteTimer = math.max((State.coyoteTimer or 0) - deltaTime, 0)
		State.dbgAirtime = (State.dbgAirtime or 0) + deltaTime
		State.brakingWindowElapsed = 0
	end
	State.jumpBufferTimer = math.max((State.jumpBufferTimer or 0) - deltaTime, 0)
	State.ladderTimeout = math.max((State.ladderTimeout or 0) - deltaTime, 0)

	-- Grace window after a duck-lift ends, used to soften friction so the
	-- grounded ticks between scroll notches don't eat the whole gain.
	State.sgsGrace = math.max((State.sgsGrace or 0) - deltaTime, 0)
	if State.duckLift > 0 then
		State.sgsGrace = Config.mv_sgsGraceTime or 0
	end

	--------------------------------------------------------------
	-- 5. JUMP  (outside the grounded branch, so coyote can fire)
	--------------------------------------------------------------
	local jumpedThisFrame = false
	local canJump = State.isGrounded or (State.coyoteTimer > 0 and not State.isJumping)
	local wantsJump = (Config.mv_autoBhop and State.spaceHeld) or State.jumpBufferTimer > 0

	-- Holding crouch through the jump is the crouch-jump: stay ducked, tuck
	-- the feet, clear more. Toggle mode keeps whatever was toggled.
	local keepCrouched = State.cIsHeld or (not Config.mv_crouchHold and State.isCrouching)

	if canJump and wantsJump and not State.isDiving then
		-- Only need headroom if we're actually going to stand up.
		local needed = (standY - body.Size.Y) + SKIN
		local blocked = (not keepCrouched)
			and (State.isProne or State.isCrouching)
			and needed > 0
			and Sweep(pos, hullSize, Vector3.new(0, needed, 0), params) ~= nil

		if not blocked then
			vel = Vector3.new(vel.X, Config.mv_jumpForce, vel.Z)

			if not keepCrouched then
				State.isCrouching = false
				State.isProne = false
			end
			State.isGrounded = false
			State.isJumping = true
			State.coyoteTimer = 0
			State.jumpBufferTimer = 0
			State.brakingWindowElapsed = 0
			jumpedThisFrame = true

			-- Source's PM_Jump speed cap, faithfully including the bug: the
			-- correction is applied along the VIEW vector rather than the
			-- movement vector, so facing backwards turns a reduction into a
			-- gain. Closed form per jump: speed * 2 - capSpeed.
			if Config.mv_abh then
				local ducked = State.isWalking or duckedForSpeed
				local boostPerc = ducked
					and (Config.mv_abhBoostPercDucked or 0.1)
					or (Config.mv_abhBoostPerc or 0.5)

				local forwardMove = (State.forwardMoveAxis or 0) * targetSpeed
				local speedAddition = math.abs(forwardMove * boostPerc)
				local capSpeed = targetSpeed + (targetSpeed * boostPerc)
				local flatSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude

				if speedAddition + flatSpeed > capSpeed then
					speedAddition = speedAddition - ((speedAddition + flatSpeed) - capSpeed)
				end
				-- The AFH line: holding back flips the sign.
				if forwardMove < 0 then speedAddition = -speedAddition end

				local viewForward = CFrame.Angles(0, math.rad(State.cameraX or 0), 0).LookVector
				vel = vel + viewForward * speedAddition
			end

			Visuals.PlayAnim("Jump", 0.0)
			Sounds.Push("jump")
			ViewSway.Jump()
		end
	end

	--------------------------------------------------------------
	-- 5b. LADDER
	--------------------------------------------------------------
	State.onLadder = false

	-- LADDER_MOUNT_TIMEOUT: without it, pushing off a ladder re-grabs it on
	-- the very next tick because we're still inside the grab volume.
	local ladderPart, ladderNormal
	if State.ladderTimeout <= 0 then
		ladderPart, ladderNormal = findLadder(pos, hullSize, op)
	end

	if ladderPart and not jumpedThisFrame then
		local wish = State.wishDir or Vector3.zero
		local pressing = wish.Magnitude > 0.1

		-- Detach by walking away from the face. Without this you'd be stuck
		-- to the ladder any time you brushed past it.
		local movingAway = pressing and wish:Dot(ladderNormal) > 0.5

		if not movingAway then
			State.onLadder = true
			State.ladderNormal = ladderNormal
			State.isGrounded = false
			State.isJumping = false

			if wantsJump then
				-- Kick off along the face normal, exactly as PM_Ladder does.
				vel = ladderNormal * (Config.mv_ladderPushOff or 24.5)
				State.onLadder = false
				State.jumpBufferTimer = 0
				State.ladderTimeout = Config.mv_ladderTimeout or 0.2
				Sounds.Push("jump")

			elseif pressing then
				-- Climb direction is the VIEW vector projected onto the ladder
				-- plane. Look up to ascend, look down to descend -- this is
				-- what makes CS ladders feel the way they do.
				local camCF = CFrame.Angles(0, math.rad(State.cameraX or 0), 0)
					* CFrame.Angles(math.rad(State.cameraY or 0), 0, 0)
				local fwd = camCF.LookVector
				local right = camCF.RightVector

				local function onPlane(v)
					local p = v - ladderNormal * v:Dot(ladderNormal)
					return p.Magnitude > 0.01 and p.Unit or Vector3.zero
				end

				local fwdAxis   = (State.forwardMoveAxis or 0)
				local sideAxis  = wish:Dot(camCF.RightVector) >= 0 and 1 or -1
				local strafing  = math.abs(wish:Dot(camCF.RightVector)) > 0.3

				local dir = onPlane(fwd) * fwdAxis
				if strafing then
					dir = dir + onPlane(right) * sideAxis
				end

				if dir.Magnitude > 0.01 then
					vel = dir.Unit * (Config.mv_ladderClimbSpeed or 18.2)
				else
					vel = Vector3.zero
				end
			else
				-- No input: stick. Ladders in CS hold you in place.
				vel = Vector3.zero
			end
		end
	end

	--------------------------------------------------------------
	-- 6. ACCELERATION
	--------------------------------------------------------------
	local horizontalVel = Vector3.new(vel.X, 0, vel.Z)
	local verticalVel = vel.Y

	if State.onLadder then
		-- Ladder velocity was set outright in 5b: no gravity, no friction, no
		-- acceleration. PM_Ladder switches movetype to fly for exactly this.
		horizontalVel = Vector3.new(vel.X, 0, vel.Z)
		verticalVel = vel.Y

	elseif State.isGrounded and not jumpedThisFrame then
		local surface = State.surfaceFriction or 1
		local hasInput = (State.wishDir or Vector3.zero).Magnitude > 0.1

		-- Friction is withheld inside the braking window. PB skips braking
		-- entirely rather than scaling it, so a bhop lands and leaves clean.
		local brakingAllowed = (State.brakingWindowElapsed or 0) >= (Config.mv_brakingWindow or 0)

		local speed = horizontalVel.Magnitude
		if speed > 0.1 and brakingAllowed then
			local control = speed < Config.mv_stopSpeed and Config.mv_stopSpeed or speed
			local activeFriction = Config.mv_groundFriction * surface

			-- Doubled friction on a ledge edge. Published so the HUD can show
			-- whether it actually fired -- this is the cvar most likely to
			-- make stopping feel sticky, and it's invisible otherwise.
			local edgeMult = EdgeFrictionMultiplier(
				pos, hullSize, horizontalVel, params, bodyScale, hasInput, duckedForSpeed
			)
			State.dbgEdgeFriction = edgeMult
			activeFriction = activeFriction * edgeMult


			-- GoldSrc bites harder on the first grounded tick after a fall.
			-- Suppressed during an SGS grace window: scroll-ducking "lands"
			-- constantly, and paying the spike each time swamps the gain.
			if not wasGrounded and State.sgsGrace <= 0 then
				activeFriction = activeFriction * (Config.mv_landFrictionMult or 1)
			end

			-- Soften friction between scroll notches so the airborne gain
			-- isn't immediately erased. 1 = authentic.
			if State.sgsGrace > 0 then
				activeFriction = activeFriction * (Config.mv_sgsFrictionMult or 1)
			end

			if State.isProneStance and speed > Config.mv_proneSpeed then
				activeFriction = activeFriction * 2
			end

			local drop = control * activeFriction * deltaTime
			horizontalVel = horizontalVel * (math.max(speed - drop, 0) / speed)
		elseif speed <= 0.1 then
			horizontalVel = Vector3.zero
		end

		-- Source scales ground accel by surface friction too, not just the
		-- friction term. Skipping this is why ice normally feels wrong: you
		-- slide correctly but still accelerate like you're on concrete.
		horizontalVel = Math.QuakeGroundAccelerate(
			horizontalVel, State.wishDir, targetSpeed,
			Config.mv_groundAcceleration * surface, deltaTime
		)

		-- Velocity stays flat while grounded. Ramps are climbed by step-up and
		-- descended by ground-stick, as GoldSrc does it. Projecting onto the
		-- slope here would cost a cos(theta) factor and make walking up or
		-- down a ramp slower than strafing across it.
		verticalVel = 0

	else
		State.dbgEdgeFriction = 1
		if not State.isDiving then
			-- addSpeed = cap - proj, so the cap is what actually limits how
			-- much a tick can add. Raising it during lift frames boosts SGS
			-- without touching normal air-strafing or surf.
			local cap = Config.mv_airSpeedCap
			if State.duckLift > 0 then
				cap = cap * (Config.mv_sgsCapMult or 1)
			end

			local wish = AssistWishDir(State.wishDir, horizontalVel, targetSpeed, deltaTime, cap)

			horizontalVel = Math.QuakeAirAccelerate(
				horizontalVel, wish, targetSpeed,
				Config.mv_airAcceleration, deltaTime, cap
			)
		end

		verticalVel = verticalVel - (Config.mv_gravity * deltaTime)
		verticalVel = math.max(verticalVel, -(Config.mv_maxFallSpeed or 181))
	end

	-- Optional sanity clamp; 0 disables. ABH will exceed anything sensible.
	-- Skipped on ladders, where climb speed is set directly.
	local hCap = Config.mv_maxHorizontalSpeed or 0
	if hCap > 0 and not State.onLadder and horizontalVel.Magnitude > hCap then
		horizontalVel = horizontalVel.Unit * hCap
	end

	vel = Vector3.new(horizontalVel.X, verticalVel, horizontalVel.Z)

	-- sv_maxvelocity: Source clamps each AXIS independently, not the magnitude.
	-- That's a different shape of clamp -- a diagonal can reach cap * sqrt(2).
	local axisCap = Config.mv_maxVelocity or 0
	if axisCap > 0 then
		vel = Vector3.new(
			math.clamp(vel.X, -axisCap, axisCap),
			math.clamp(vel.Y, -axisCap, axisCap),
			math.clamp(vel.Z, -axisCap, axisCap)
		)
	end

	--------------------------------------------------------------
	-- 7. MOVE
	--------------------------------------------------------------
	local maxStep = 0
	if State.isGrounded and not State.onLadder then
		maxStep = Config.mv_maxStepHeight * bodyScale
		if Config.mv_scaleStepWithSpeed then
			-- Step-up climbs at most maxStep per tick, so past a certain speed
			-- the rise per tick exceeds it and we stall against the ramp.
			-- Not GoldSrc: CS never went this fast.
			local flatSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
			maxStep = math.max(maxStep, flatSpeed * deltaTime)
		end
	end

	pos, vel = MoveWithStep(pos, vel, hullSize, deltaTime, params, op, maxStep)

	-- Belt and braces with noUp: walking never launches upward, and
	-- ground-stick below needs vel.Y <= 0 to run.
	if State.isGrounded and not jumpedThisFrame then
		vel = Vector3.new(vel.X, math.min(vel.Y, 0), vel.Z)
	end

	--------------------------------------------------------------
	-- 8. GROUND STICK
	--------------------------------------------------------------
	-- Keeps us glued to descending slopes so friction keeps applying and we
	-- don't shed ground contact every tick on the way down. Source steps DOWN
	-- a fraction of max step height -- below that fraction you enter air move
	-- and let gravity do it, which is what makes small ledges feel like drops.
	if State.isGrounded and not jumpedThisFrame and not State.isJumping
		and not State.isDiving and State.duckLift <= 0 and vel.Y <= 0.01 and not State.onLadder then

		local maxDrop = Config.mv_maxStepHeight * bodyScale * (Config.mv_stepDownFraction or 1)
		local stick = Sweep(pos, hullSize, Vector3.new(0, -maxDrop, 0), params)
		if stick and stick.Normal.Y >= GROUND_NORMAL_Y then
			local drop = math.max(stick.Distance - SKIN, 0)
			if drop > 0.01 then
				local dropped = pos - Vector3.new(0, drop, 0)
				if not IsOccupied(dropped, hullSize, op) then
					pos = dropped
					vel = Vector3.new(vel.X, 0, vel.Z)
					State.surfaceFriction = SurfaceFrictionFor(stick.Instance)
				end
			end
		end
	end

	--------------------------------------------------------------
	-- 9. COMMIT
	--------------------------------------------------------------
	if pos.Y < -100 then
		pos = workspace.SpawnLocation.Position + Vector3.new(0, 10, 0)
		vel = Vector3.zero
	end

	if not State.isGrounded then
		State.dbgJumpHeight = math.max(State.dbgJumpHeight or 0, pos.Y)
	end

	Commit(body, pos, vel, deltaTime)
end

return Physics