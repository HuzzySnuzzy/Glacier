-- ModuleScript: Debug
-- Telemetry overlay for the movement system.
-- Reads State/Config only; never writes movement state.
--
-- Setup:
--   local Debug = require(script.Debug)
--   Debug.Init()
--   Debug.Physics = Physics          -- for the phys hz counter
--   -- in RenderStepped, after Visuals.Update:
--   Debug.Update(deltaTime)
--
-- Requires in Physics.Step (see the patch shipped alongside this file):
--   Physics.stepCount      -- incremented at the top of Step
--   State.groundNormal     -- after ground detection
--   State.depenCount       -- depenetration pushes THIS TICK
--   State.stepUpCount      -- cumulative successful step-ups
--   State.dbgEdgeFriction  -- last edge-friction multiplier
--
-- TWO CLOCKS, deliberately:
--   os.clock()     -- every RATE: fps, phys hz, graph timebase, RPM, drift.
--                     A scaled dt would report 4x the true physics rate
--                     during a host_timescale ramp.
--   State.gameTime -- every gameplay DEADLINE: fire cooldown, equip gate,
--                     reload. That is the clock they were stamped on.
-- Mixing the two is the class of bug this file exists to catch, so it must
-- not commit it itself.

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
local State   = require(script.Parent.State)
local ViewBob = require(script.Parent.ViewBob)

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local plr = Players.LocalPlayer

local Debug = {}
local SAMPLE_HZ = 120
local sampleAccum = 0
local GRAPH_SAMPLES = 140
local FONT = Enum.Font.Code

local gui, statsLabel, speedLabel, graphFrame
local bars = {}
local samples = {}
local sampleIndex = 1

-- rate tracking
local frameAccum, frameCount = 0, 0
local displayFps = 0
local lastStepCount, displayHz = 0, 0
local peakSpeed = 0
local displayScale = 40
local weaponLabel
local lastAmmo, lastWeaponId, shotTimes = nil, nil, {}
local ceilingLabel

-- Drift measurement. lastBody is tracked alongside lastPos so a respawn
-- doesn't produce a one-frame drift spike the size of the teleport.
local lastPos, lastBody, actualVel = nil, nil, Vector3.zero

local lastRealClock = os.clock()

-- Previous-frame snapshots for the RUNNING/FROZEN indicators. These live here
-- rather than on Debug so nothing external can stomp them. Seeded nil rather
-- than -1: on the very first frame there is no previous value to compare
-- against, and -1 made every field claim RUNNING before anything had ticked.
local prevGameTime = nil
local prevWishCalls = nil

-- 3D helpers
local hullBox, velPart, normalPart

--------------------------------------------------------------------
-- FORMATTING
--------------------------------------------------------------------

local function fmtVec(v)
	return string.format("%7.2f %7.2f %7.2f", v.X, v.Y, v.Z)
end

local function num(v, default)
	return (type(v) == "number" and v) or default or 0
end

-- Safe for "%d". math.floor(math.huge) is STILL math.huge, and "%d" on a
-- non-finite number raises "number has no integer representation" -- a hard
-- error that takes the whole overlay down, not a cosmetic glitch.
local function int(v)
	local n = num(v)
	if n ~= n then return 0 end                      -- NaN
	return math.floor(math.clamp(n, -1e15, 1e15))
end

-- For counts that may LEGITIMATELY be infinite -- the knife carries
-- magSize = math.huge. Returns a string, so format it with %s, and "inf" is
-- the honest readout rather than a clamped lie.
local function fmtCount(v)
	local n = num(v)
	if n ~= n then return "nan" end
	if n ==  math.huge then return "inf" end
	if n == -math.huge then return "-inf" end
	return string.format("%d", math.floor(math.clamp(n, -1e15, 1e15)))
end

local function boolTag(prev, current)
	if prev == nil then return "?" end               -- nothing to compare yet
	return (current > prev) and "RUNNING" or "FROZEN"
end

local function yn(v)
	return v and "yes" or "no"
end

--------------------------------------------------------------------
-- CONSTRUCTION
--------------------------------------------------------------------

local function makeLabel(parent, pos, size, textSize, align)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Position = pos
	l.Size = size
	l.Font = FONT
	l.TextSize = textSize
	l.TextColor3 = Color3.fromRGB(235, 235, 235)
	l.TextStrokeTransparency = 0.4
	l.TextStrokeColor3 = Color3.new(0, 0, 0)
	l.TextXAlignment = align or Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.Text = ""
	l.Parent = parent
	return l
end

local function makeDebugPart(colour)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	-- CanQuery false is load-bearing, not tidiness: these sit in workspace and
	-- would otherwise come back from Blockcast and GetPartBoundsInBox, eating
	-- slots against OverlapParams.MaxParts and colliding with the hull.
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = colour
	p.Size = Vector3.new(0.1, 0.1, 1)
	-- Debug geometry sitting in the world will otherwise occlude the Advanced
	-- Audio API the same way a clip brush does.
	pcall(function() p.AudioCanCollide = false end)
	p.Parent = workspace
	return p
end

function Debug.Init()
	if gui then return end

	gui = Instance.new("ScreenGui")
	gui.Name = "MovementDebug"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.DisplayOrder = 100
	gui.Parent = plr:WaitForChild("PlayerGui")

	-- Big speed readout, centre-bottom (CS speedometer position)
	speedLabel = makeLabel(gui, UDim2.new(0.5, -150, 1, -150), UDim2.new(0, 300, 0, 60), 42, Enum.TextXAlignment.Center)
	speedLabel.TextColor3 = Color3.fromRGB(255, 220, 120)

	-- Stats block, top-left. Was 460px tall for ~35 lines at 14px, which
	-- clipped the config rows off the bottom; the panel has grown since.
	statsLabel = makeLabel(gui, UDim2.new(0, 12, 0, 12), UDim2.new(0, 360, 0, 700), 14)
	statsLabel.Position = UDim2.new(0, 12, 0, 12 + GuiService:GetGuiInset().Y * 0.25)

	-- Bottom-right, where an ammo counter would live.
	weaponLabel = makeLabel(gui, UDim2.new(1, -320, 1, -240), UDim2.new(0, 300, 0, 220), 14,
		Enum.TextXAlignment.Right)
	weaponLabel.TextColor3 = Color3.fromRGB(255, 230, 180)

	-- Speed graph, above the speedometer
	graphFrame = Instance.new("Frame")
	graphFrame.Position = UDim2.new(0.5, -GRAPH_SAMPLES / 2, 1, -90)
	graphFrame.Size = UDim2.new(0, GRAPH_SAMPLES, 0, 60)
	graphFrame.BackgroundColor3 = Color3.new(0, 0, 0)
	graphFrame.BackgroundTransparency = 0.75
	graphFrame.BorderSizePixel = 0
	graphFrame.Parent = gui

	for i = 1, GRAPH_SAMPLES do
		local bar = Instance.new("Frame")
		bar.BorderSizePixel = 0
		bar.AnchorPoint = Vector2.new(0, 1)
		bar.Position = UDim2.new(0, i - 1, 1, 0)
		bar.Size = UDim2.new(0, 1, 0, 0)
		bar.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
		bar.Parent = graphFrame
		bars[i] = bar
		samples[i] = 0
	end

	-- Reference line at walk speed
	local ref = Instance.new("Frame")
	ref.BorderSizePixel = 0
	ref.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ref.BackgroundTransparency = 0.6
	ref.AnchorPoint = Vector2.new(0, 1)
	ref.Size = UDim2.new(1, 0, 0, 1)
	ref.Name = "RefLine"
	ref.Parent = graphFrame

	ceilingLabel = makeLabel(graphFrame, UDim2.new(0, 3, 0, 1), UDim2.new(0, 60, 0, 14), 11)
	ceilingLabel.TextColor3 = Color3.fromRGB(180, 180, 180)

	-- Adornments render as world-space geometry, so this belongs in workspace
	-- alongside the vector parts rather than inside a ScreenGui.
	hullBox = Instance.new("SelectionBox")
	hullBox.Name = "DebugHull"
	hullBox.LineThickness = 0.03
	hullBox.Color3 = Color3.fromRGB(120, 255, 160)
	hullBox.Transparency = 0.3
	hullBox.Parent = workspace

	velPart = makeDebugPart(Color3.fromRGB(255, 120, 120))
	normalPart = makeDebugPart(Color3.fromRGB(120, 160, 255))
end

--------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------

local function drawVector(part, origin, direction, thickness)
	local len = direction.Magnitude
	if len < 0.05 then
		part.Transparency = 1
		return
	end
	part.Transparency = 0
	part.Size = Vector3.new(thickness, thickness, len)
	part.CFrame = CFrame.lookAt(origin + direction * 0.5, origin + direction)
end

--------------------------------------------------------------------
-- UPDATE
--------------------------------------------------------------------

function Debug.Update(deltaTime)
	if not gui then return end

	deltaTime = num(deltaTime, 1 / 60)

	-- Wall-clock delta, independent of host_timescale and of whatever the
	-- caller passed. Clamped because a hitch or a resumed tab produces a
	-- multi-second dt that would otherwise blow out every running average.
	local nowClock = os.clock()
	local realDt = math.clamp(nowClock - lastRealClock, 1e-5, 0.25)
	lastRealClock = nowClock

	local Physics = Debug.Physics
	local body = State.playerBody
	local vel = State.velocity or Vector3.zero
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude

	-- ---- rate tracking (1s real-time windows) ----
	frameAccum += realDt
	frameCount += 1
	if frameAccum >= 1 then
		displayFps = frameCount / frameAccum
		local sc = num(Physics and Physics.stepCount, 0)
		displayHz = (sc - lastStepCount) / frameAccum
		lastStepCount = sc
		frameAccum, frameCount = 0, 0
	end

	if speed > peakSpeed then peakSpeed = speed end

	-- ---- measured velocity ----
	-- Reset on body identity change: comparing a fresh spawn position against
	-- the previous life's would report a drift of the whole map.
	if body ~= lastBody then
		lastBody, lastPos, actualVel = body, nil, Vector3.zero
	end
	if body then
		if lastPos then
			actualVel = (body.Position - lastPos) / realDt
		end
		lastPos = body.Position
	end

	-- ---- visibility ----
	local showHud = Config.cl_debugHud
	local showGraph = Config.cl_debugGraph
	local showWeapon = Config.cl_debugWeapon

	statsLabel.Visible = showHud
	speedLabel.Visible = showHud
	graphFrame.Visible = showGraph
	weaponLabel.Visible = showWeapon
	hullBox.Adornee = (Config.cl_debugHull and body) or nil
	velPart.Transparency = Config.cl_debugVectors and 0 or 1
	normalPart.Transparency = Config.cl_debugVectors and 0 or 1

	-- ---- clock state ----
	-- Read before the body gate: a frozen gameTime is exactly the thing you
	-- need to see when the body is missing and nothing is stepping.
	local gameTime = num(State.gameTime, 0)
	local wishCalls = int(State.dbgWishCalls)
	local gameTag = boolTag(prevGameTime, gameTime)
	local wishTag = boolTag(prevWishCalls, wishCalls)

	-- State.timeScale is what the physics accumulator actually multiplies by;
	-- Config.host_timescale is what the server last told us. They should be
	-- identical -- a divergence means this client missed a ConfigSync push, or
	-- something is writing the cvar without the accumulator picking it up.
	local stateScale = num(State.timeScale, 1)
	local cvarScale = num(Config.host_timescale, 1)
	local scaleDrift = math.abs(stateScale - cvarScale) > 1e-3

	-- ---- speedometer + stats ----
	if showHud and body then
		speedLabel.Text = string.format("%.0f", speed)
		speedLabel.TextColor3 = State.isGrounded
			and Color3.fromRGB(255, 220, 120)
			or Color3.fromRGB(140, 255, 180)

		local targetHz = num(Config.sv_PhysicsHz, 60)
		local hzWarn = (displayHz < targetHz * 0.9) and "  <-- STARVED" or ""

		local wd = State.wishDir or Vector3.zero
		local angle, proj = 0, 0
		if flat.Magnitude > 0.1 and wd.Magnitude > 0.1 then
			angle = math.deg(math.acos(math.clamp(flat.Unit:Dot(wd.Unit), -1, 1)))
			proj = flat:Dot(wd.Unit)
		end

		-- Friction the sim is actually applying, as opposed to the cvar. The
		-- edge multiplier only means anything on the tick it was computed, so
		-- it reads 1.00 while airborne rather than holding a stale 2.00.
		local surfFric = num(State.surfaceFriction, 1)
		local edgeFric = num(State.dbgEdgeFriction, 1)

		-- Braking window: friction is withheld until this passes
		-- mv_brakingWindow, which is what lets a clean bhop keep its speed.
		local brakeElapsed = num(State.brakingWindowElapsed)
		local brakeWindow = num(Config.mv_brakingWindow)
		local braking = brakeElapsed >= brakeWindow

		statsLabel.Text = table.concat({
			string.format("fps       %6.1f", displayFps),
			string.format("phys hz   %6.1f / %d%s", displayHz, int(targetHz), hzWarn),
			string.format("dt game   %6.4f   real %6.4f", deltaTime, realDt),
			"",
			string.format("speed     %6.2f   (peak %.2f)", speed, peakSpeed),
			string.format("vel       %s", fmtVec(vel)),
			string.format("vert      %6.2f", vel.Y),
			string.format("wishdir   %s  |%.2f|", fmtVec(wd), wd.Magnitude),
			string.format("pos       %s", fmtVec(body.Position)),
			string.format("hull      %s", fmtVec(body.Size)),
			string.format("gnd nrm   %s", fmtVec(State.groundNormal or Vector3.yAxis)),
			"",
			string.format("actual    %s", fmtVec(actualVel)),
			string.format("drift     %6.2f", (actualVel - vel).Magnitude),
			-- depen is per-TICK: anything above 0 means the hull is inside
			-- geometry right now. stepup is cumulative; watch it climb.
			string.format("depen/tick %d   stepup %d", int(State.depenCount), int(State.stepUpCount)),
			"",
			string.format("grounded  %-5s  ladder %-5s  noclip %s",
				tostring(State.isGrounded), tostring(State.onLadder), tostring(State.noclip)),
			string.format("jumping   %-5s  diving %-5s  sprint %s",
				tostring(State.isJumping), tostring(State.isDiving), tostring(State.isSprinting)),
			-- Intent and hull are now two different things, separated by up to
			-- mv_uncrouchJumpTime. Speed follows the HULL, so isCrouching
			-- alone will lie to you for the whole transition.
			string.format("crouch    key %-5s hull %-5s  f %.2f",
				tostring(State.isCrouching), tostring(State.isDucked), num(State.duckFraction)),
			string.format("prone     key %-5s hull %-5s  trans %s",
				tostring(State.isProne), tostring(State.isProneStance),
				yn(State.isInStanceTransition)),
			"",
			string.format("coyote    %5.3f   buffer %5.3f", num(State.coyoteTimer), num(State.jumpBufferTimer)),
			string.format("brake     %5.3f / %5.3f  %s", brakeElapsed, brakeWindow,
				braking and "APPLYING" or "WITHHELD"),
			string.format("lift %-3d  sgs %5.3f  ladderTO %5.3f",
				int(State.duckLift), num(State.sgsGrace), num(State.ladderTimeout)),
			string.format("airtime   %5.2fs   lastJump %.2f", num(State.dbgAirtime), num(State.dbgJumpHeight)),
			"",
			string.format("wishCalls %d  (%s)", wishCalls, wishTag),
			string.format("gameTime  %9.3f  (%s)", gameTime, gameTag),
			string.format("timescale %5.3f  cvar %5.3f%s", stateScale, cvarScale,
				scaleDrift and "  <-- DESYNC" or ""),
			"",
			string.format("keys      W%s A%s S%s D%s   focus %s",
				UserInputService:IsKeyDown(Enum.KeyCode.W) and "+" or "-",
				UserInputService:IsKeyDown(Enum.KeyCode.A) and "+" or "-",
				UserInputService:IsKeyDown(Enum.KeyCode.S) and "+" or "-",
				UserInputService:IsKeyDown(Enum.KeyCode.D) and "+" or "-",
				tostring(UserInputService.WindowFocused)),
			"",
			string.format("strafe    %5.1f deg  proj %5.2f / %.2f", angle, proj, num(Config.mv_airSpeedCap)),
			"",
			-- Bob is a viewmodel-only signal now. If these move and the gun
			-- doesn't, the cause is downstream in ViewSway or the vm pivot,
			-- not in ViewBob.
			string.format("bob       v%+.3f l%+.3f  spd %5.2f",
				num(ViewBob.verticalBob), num(ViewBob.lateralBob), num(ViewBob.bobSpeed)),
			string.format("roll      %+5.2f deg", num(State.cameraRoll)),
			"",
			-- Effective friction, not just the cvar: surface and edge both
			-- multiply it, and either can be the reason a stop feels wrong.
			string.format("accel g%.1f a%.1f  fric %.1f x%.2f x%.2f",
				num(Config.mv_groundAcceleration), num(Config.mv_airAcceleration),
				num(Config.mv_groundFriction), surfFric, edgeFric),
			string.format("grav %.1f  jump %.1f  step %.2f",
				num(Config.mv_gravity), num(Config.mv_jumpForce), num(Config.mv_maxStepHeight)),
		}, "\n")

	elseif showHud then
		-- No body. Keep the clock diagnostics up rather than blanking the
		-- panel -- "is anything still ticking" is the question you have here.
		speedLabel.Text = "--"
		statsLabel.Text = table.concat({
			"NO BODY",
			"",
			string.format("fps       %6.1f", displayFps),
			string.format("phys hz   %6.1f", displayHz),
			string.format("gameTime  %9.3f  (%s)", gameTime, gameTag),
			string.format("timescale %5.3f  cvar %5.3f%s", stateScale, cvarScale,
				scaleDrift and "  <-- DESYNC" or ""),
		}, "\n")
	end

	-- ---- graph ----
	if showGraph and body then
		-- Sampled on real time so the graph's horizontal axis stays a
		-- consistent window of wall clock regardless of timescale. Sampling on
		-- game time would stretch the same 2.3s of history across 4x the
		-- wall clock during a slow-mo ramp.
		sampleAccum += realDt
		local pushed = false

		while sampleAccum >= 1 / SAMPLE_HZ do
			samples[sampleIndex] = speed
			sampleIndex = (sampleIndex % GRAPH_SAMPLES) + 1
			sampleAccum -= (1 / SAMPLE_HZ)
			pushed = true
		end

		-- A long hitch can bank enough time to spin this loop hundreds of
		-- times; the clamp on realDt already bounds it, but drain any
		-- remainder so it can't compound.
		if sampleAccum > 1 then sampleAccum = 0 end

		if pushed then
			local sampleMax = 0
			for i = 1, GRAPH_SAMPLES do
				if samples[i] > sampleMax then sampleMax = samples[i] end
			end

			-- Auto ceiling: headroom above the peak, but never so low that the
			-- walk-speed reference line falls off the top.
			local walk = num(Config.mv_walkSpeed, 22.7)
			local target = math.max(sampleMax * 1.15, walk * 1.25, 1)

			local override = num(Config.cl_debugGraphScale, 0)
			if override > 0 then target = override end

			-- Rise fast so a spike is never clipped, fall slow so the graph
			-- doesn't jitter every time you stop moving.
			local rate = (target > displayScale) and 12 or 1.5
			displayScale += (target - displayScale) * (1 - math.exp(-rate * realDt))

			local scale = math.max(displayScale, 1e-3)   -- never divide by zero
			local h = graphFrame.AbsoluteSize.Y

			for i = 1, GRAPH_SAMPLES do
				local idx = ((sampleIndex + i - 2) % GRAPH_SAMPLES) + 1
				local s = samples[idx]
				local bar = bars[i]
				bar.Size = UDim2.new(0, 1, 0, math.clamp(s / scale, 0, 1) * h)
				bar.BackgroundColor3 = (s > walk * 1.02)
					and Color3.fromRGB(140, 255, 160)
					or Color3.fromRGB(120, 200, 255)
			end

			local ref = graphFrame:FindFirstChild("RefLine")
			if ref then
				ref.Position = UDim2.new(0, 0, 1 - math.clamp(walk / scale, 0, 1), 0)
			end

			if ceilingLabel then
				ceilingLabel.Text = string.format("%.0f", scale)
			end
		end
	end

	-- ---- weapon ----
	-- Not gated on body: the ammo/reload state is worth reading while dead,
	-- and every field below is nil-safe.
	if showWeapon then
		local s = State.currentWeaponStats

		-- A swap is not a shot. Without this, going from a 30-round mag to a
		-- 12-round one registers as a discharge and poisons the RPM window.
		local wpnId = s and tostring(s.name) or "-"
		if wpnId ~= lastWeaponId then
			lastWeaponId = wpnId
			lastAmmo = nil
			table.clear(shotTimes)
		end

		-- Measured RPM from actual shots, so you can verify fireRate rather
		-- than trust it. REAL clock: RPM is a wall-clock rate, and measuring
		-- it against game time would hide a timescale-induced fire-rate change
		-- rather than reveal it.
		if State.currentAmmo ~= lastAmmo then
			if lastAmmo and num(State.currentAmmo) < lastAmmo then
				table.insert(shotTimes, nowClock)
				while #shotTimes > 8 do table.remove(shotTimes, 1) end
			end
			lastAmmo = State.currentAmmo
		end
		while #shotTimes > 0 and nowClock - shotTimes[1] > 3 do
			table.remove(shotTimes, 1)
		end

		local measuredRpm = 0
		if #shotTimes >= 2 then
			local span = shotTimes[#shotTimes] - shotTimes[1]
			if span > 0 then measuredRpm = ((#shotTimes - 1) / span) * 60 end
		end

		-- GAME clock, not os.clock(). Visuals stamps equipEndTime as
		-- State.gameTime + equipTime, and Weapons stamps the other two the
		-- same way; subtracting a wall clock from a virtual timestamp gave
		-- three rows of noise that drifted further apart every session.
		local gate     = num(State.equipEndTime)  - gameTime
		local cooldown = num(State.nextFireTime)  - gameTime
		local reload   = State.isReloading and (num(State.reloadEndTime) - gameTime) or 0

		local vmSlot = "-"
		if State.vmWeaponTracks then
			local n = 0
			for _ in pairs(State.vmWeaponTracks) do n += 1 end
			vmSlot = tostring(n)
		end

		-- pcall: a destroyed AnimationTrack still sits in the field until the
		-- next swap overwrites it, and reading through it throws.
		local overlay = "none"
		if State.currentVmOverlay then
			local ok, name = pcall(function()
				local a = State.currentVmOverlay.Animation
				return a and a.Name or "?"
			end)
			overlay = ok and tostring(name) or "destroyed"
		end

		weaponLabel.Text = table.concat({
			s and string.format("%s  (slot %d)", tostring(s.name), int(State.activeSlot))
				or string.format("NO WEAPON  (slot %s)", tostring(State.activeSlot)),
			-- %s with fmtCount, not %d: the knife's magSize is math.huge, and
			-- "%d" on that raises rather than printing.
			s and string.format("%s / %s   reserve %s",
				fmtCount(State.currentAmmo), fmtCount(s.magSize), fmtCount(State.reserveAmmo)) or "",
			"",
			string.format("trigger   %s   auto %s",
				tostring(State.triggerDown), s and tostring(s.isAuto) or "-"),
			string.format("cooldown  %5.3f", math.max(cooldown, 0)),
			string.format("equip gate%5.3f%s", math.max(gate, 0), gate > 0 and "  BLOCKED" or ""),
			string.format("reloading %s %5.3f", tostring(State.isReloading), math.max(reload, 0)),
			"",
			string.format("spread    %5.2f deg", num(State.spreadDegrees)),
			string.format("punch     %5.2f %5.2f",
				(State.recoilPunch or Vector2.zero).X, (State.recoilPunch or Vector2.zero).Y),
			string.format("viewpunch %5.2f %5.2f",
				(State.recoilViewPunch or Vector2.zero).X, (State.recoilViewPunch or Vector2.zero).Y),
			"",
			string.format("rpm cfg   %d", s and int(s.fireRate) or 0),
			string.format("rpm meas  %.0f", measuredRpm),
			"",
			string.format("wpn tracks %s", vmSlot),
			string.format("overlay    %s", overlay),
		}, "\n")
	end

	-- ---- 3D vectors ----
	if Config.cl_debugVectors and body then
		drawVector(velPart, body.Position, vel * 0.15, 0.15)
		drawVector(normalPart, body.Position - Vector3.new(0, body.Size.Y / 2, 0),
			(State.groundNormal or Vector3.yAxis) * 3, 0.1)
	end

	-- Snapshot last, so every RUNNING/FROZEN check above compared against the
	-- previous frame rather than against itself.
	prevGameTime = gameTime
	prevWishCalls = wishCalls
	Debug.lastWishCalls = wishCalls
	Debug.gameTime = gameTime
	Debug.timeScale = stateScale
end

function Debug.ResetPeak()
	peakSpeed = 0
	for i = 1, GRAPH_SAMPLES do samples[i] = 0 end
	displayScale = num(Config.mv_walkSpeed, 22.7) * 1.25
end

--------------------------------------------------------------------
-- CONSOLE
--------------------------------------------------------------------
-- Registered at require time. These are CLIENT-flagged, so they run in this
-- VM directly rather than round-tripping through ConsoleEvent.

Config.Command("resetpeak", {
	args = {},
	help = "clear the debug HUD's peak speed and graph history",
	run = function(ctx)
		Debug.ResetPeak()
		-- ctx.reply, not print: print lands in the log, not the console the
		-- player typed into.
		ctx.reply("peak speed and graph history cleared")
	end,
})

return Debug