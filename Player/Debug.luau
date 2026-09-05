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
local playerLabel
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
-- COLOUR
--------------------------------------------------------------------
-- The HUD was one shade of white and one of amber, which makes every number
-- cost a read. Colour carries the meaning that matters at a glance: how much
-- health is left, whether a magazine is nearly out, how fast you are going.

local PALETTE = {
	good  = Color3.fromRGB(120, 230, 140),
	warn  = Color3.fromRGB(255, 205, 90),
	bad   = Color3.fromRGB(255, 100, 100),
	cool  = Color3.fromRGB(120, 200, 255),
	armor = Color3.fromRGB(130, 180, 255),
	dim   = Color3.fromRGB(150, 155, 165),
	name  = Color3.fromRGB(105, 180, 255),
	value = Color3.fromRGB(245, 245, 245),
}

local function hex(c)
	return ("#%02X%02X%02X"):format(
		math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

-- RichText is markup, so a literal < in the payload is a parse error and
-- Roblox drops the WHOLE label to raw text when it hits one. "<-- STARVED"
-- and friends have to go through this first.
local function esc(text)
	return (tostring(text)
		:gsub("&", "&amp;")
		:gsub("<", "&lt;")
		:gsub(">", "&gt;"))
end

local function paint(text, colour)
	return ('<font color="%s">%s</font>'):format(hex(colour), tostring(text))
end

-- Row helpers for the stats panel. The label is dim so the eye skips it and
-- lands on the number; the number carries the colour.
local function row(label, ...)
	return paint(esc(("%-9s "):format(label)), PALETTE.dim) .. table.concat({ ... })
end

local function v(fmt, ...)
	return paint(esc(fmt:format(...)), PALETTE.value)
end

local function vc(colour, fmt, ...)
	return paint(esc(fmt:format(...)), colour)
end

local function dim(fmt, ...)
	return paint(esc(fmt:format(...)), PALETTE.dim)
end

-- Booleans keep their old %-5s width so the columns still line up; only the
-- colour is new. Green means the flag is set, grey means it isn't -- so a
-- glance down the block reads as "what is true about me right now".
local function flag(b)
	return paint(("%-5s"):format(b and "true" or "false"),
		b and PALETTE.good or PALETTE.dim)
end

-- A movement key lights up when it is held. Reading the row is then the same
-- gesture as looking at your hand, which is the point of having it.
local function key(code, glyph)
	local down = UserInputService:IsKeyDown(code)
	return paint(glyph, down and PALETTE.good or PALETTE.dim)
end

-- Green when full, amber past halfway down, red when it is nearly gone. Used
-- for health, armour and the magazine alike -- one rule, so the colour means
-- the same thing everywhere on the HUD.
local function levelColour(fraction)
	if fraction > 0.6 then return PALETTE.good end
	if fraction > 0.25 then return PALETTE.warn end
	return PALETTE.bad
end

-- Speed ramp: grey while stopped, white at a walk, amber at a run, cyan past
-- it. Anything cyan is speed the movement code gave you rather than the
-- keyboard, which is exactly what you are watching for on a bhop.
local function speedColour(speed, walk)
	if speed < 0.5 then return PALETTE.dim end
	if speed < walk * 0.9 then return PALETTE.value end
	if speed < walk * 1.15 then return PALETTE.warn end
	return PALETTE.cool
end

--------------------------------------------------------------------
-- CLIENT MACHINE INFO
--------------------------------------------------------------------
-- Everything Roblox will actually tell a LocalScript about the machine it is
-- running on.
--
-- What is NOT here, because there is no API for it and guessing would be
-- worse than silence: CPU model, core count, GPU model, driver version, OS
-- build, installed RAM, and the monitor's refresh rate. Roblox exposes none
-- of them to game code. What you get instead is the platform class, the
-- window, the graphics quality the user has chosen, and the live cost
-- figures -- which are the parts you can act on anyway.

local Stats = game:GetService("Stats")
local RunService = game:GetService("RunService")
local LocalizationService = game:GetService("LocalizationService")

-- Every one of these reads can throw on some platform or another (VREnabled
-- on an old client, ServerStatsItem before the first packet, GetTotalMemory
-- under a restricted context). A debug panel is the last thing that should
-- take the frame down with it.
local function safe(fn, fallback)
	local ok, result = pcall(fn)
	if ok and result ~= nil then return result end
	return fallback
end

local function platformName()
	if safe(function() return UserInputService.VREnabled end, false) then return "vr" end
	if safe(function() return GuiService:IsTenFootInterface() end, false) then return "console" end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then return "touch" end
	if UserInputService.KeyboardEnabled then return "desktop" end
	return "unknown"
end

-- Cached: none of it changes for the life of the session, and version() in
-- particular is not free.
local sysStatic
local function staticInfo()
	if sysStatic then return sysStatic end

	local inputs = {}
	if UserInputService.KeyboardEnabled then table.insert(inputs, "kbd") end
	if UserInputService.MouseEnabled then table.insert(inputs, "mouse") end
	if UserInputService.TouchEnabled then table.insert(inputs, "touch") end
	if UserInputService.GamepadEnabled then table.insert(inputs, "pad") end

	sysStatic = {
		platform = platformName(),
		client   = safe(function() return version() end, "?"),
		studio   = RunService:IsStudio(),
		place    = tostring(game.PlaceId),
		job      = (game.JobId ~= "" and game.JobId:sub(1, 8)) or "local",
		locale   = safe(function() return LocalizationService.SystemLocaleId end, "?"),
		inputs   = (#inputs > 0) and table.concat(inputs, "/") or "none",
	}
	return sysStatic
end

local function qualityName()
	local q = safe(function()
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel
	end, nil)
	if not q then return "?" end
	-- "Automatic" and "Level07" both come back as enum names; strip the noise.
	local name = tostring(q):gsub("^Enum%.SavedQualitySetting%.", "")
	return (name:gsub("^QualityLevel0?", "L"))
end

-- Live network round trip, in ms. Client-only, and absent until the first
-- stats packet lands, so a nil here is "too early" rather than "broken".
local function pingMs()
	return safe(function()
		return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
	end, nil)
end

local function sysBlock()
	local info = staticInfo()
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize or Vector2.zero

	local mem = safe(function() return Stats:GetTotalMemoryUsageMb() end, 0)
	local ping = pingMs()
	local heartbeat = safe(function() return Stats.HeartbeatTimeMs end, 0)
	local physStep = safe(function() return Stats.PhysicsStepTimeMs end, 0)

	-- Colour by whether the number is a problem, on the same rule as the rest
	-- of the HUD: green fine, amber worth a look, red is the thing that is
	-- making the game feel bad.
	local pingColour = PALETTE.dim
	if ping then
		pingColour = (ping < 60 and PALETTE.good)
			or (ping < 120 and PALETTE.warn) or PALETTE.bad
	end
	local memColour = (mem < 1500 and PALETTE.good)
		or (mem < 3000 and PALETTE.warn) or PALETTE.bad

	return table.concat({
		row("client", v("%s", info.client),
			dim("   %s", info.platform),
			info.studio and paint("  studio", PALETTE.warn) or ""),
		row("input", v("%s", info.inputs),
			dim("   locale "), v("%s", info.locale)),
		row("window", v("%dx%d", vp.X, vp.Y),
			dim("   quality "), v("%s", qualityName())),
		row("memory", vc(memColour, "%6.0f MB", mem),
			dim("   ping "),
			ping and vc(pingColour, "%.0f ms", ping) or dim("--")),
		row("engine", v("hb %5.2f ms", heartbeat),
			dim("  phys "), v("%5.2f ms", physStep)),
		row("session", dim("place "), v("%s", info.place),
			dim("  job "), v("%s", info.job),
			dim("  "), v("%s", os.date("%H:%M:%S"))),
	}, "\n")
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
	statsLabel = makeLabel(gui, UDim2.new(0, 12, 0, 12), UDim2.new(0, 420, 0, 760), 14)
	statsLabel.RichText = true
	statsLabel.Position = UDim2.new(0, 12, 0, 12 + GuiService:GetGuiInset().Y * 0.25)

	-- Bottom-right, where an ammo counter would live.
	weaponLabel = makeLabel(gui, UDim2.new(1, -320, 1, -240), UDim2.new(0, 300, 0, 220), 14,
		Enum.TextXAlignment.Right)
	weaponLabel.TextColor3 = Color3.fromRGB(255, 230, 180)

	-- Bottom-left: who you are and what state you are in. Health and armour
	-- are read from the PUPPET's attributes, which Health writes and Roblox
	-- replicates -- so this is the server's own number, not a local guess.
	playerLabel = makeLabel(gui, UDim2.new(0, 12, 1, -180), UDim2.new(0, 380, 0, 170), 15)
	playerLabel.TextYAlignment = Enum.TextYAlignment.Bottom
	playerLabel.RichText = true

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

--------------------------------------------------------------------
-- PLAYER PANEL
--------------------------------------------------------------------

local function bar(fraction, width)
	local filled = math.clamp(math.floor(fraction * width + 0.5), 0, width)
	return string.rep("|", filled) .. string.rep(".", width - filled)
end

-- Resolve the puppet from the world every frame instead of trusting
-- State.playerPuppet.
--
-- This is the whole fix for the HUD desync. A respawn destroys the old puppet
-- and the server parents a NEW one under the RawBody, but State.playerPuppet
-- is only rewritten by Character.Adopt/Spawn. Between the two, the stale
-- reference is not nil and not obviously broken -- a destroyed Instance still
-- answers GetAttribute with whatever it held when it was destroyed -- so the
-- panel kept happily reporting the health of a corpse.
local function livePuppet()
	local body = workspace:FindFirstChild(plr.UserId .. "RawBody")
	local fromWorld = body and body:FindFirstChild("Puppet")
	if fromWorld and fromWorld:IsA("Model") then return fromWorld end

	-- Fallback for anything that reparents the puppet elsewhere (spectating,
	-- a test rig): the cached one is still fine as long as it is in the world.
	local cached = State.playerPuppet
	if cached and cached.Parent and cached:IsDescendantOf(workspace) then
		return cached
	end
	return nil
end

local function updatePlayerPanel()
	local puppet = livePuppet()
	local lines = {}

	local name = plr.DisplayName ~= plr.Name
		and ("%s (%s)"):format(plr.DisplayName, plr.Name) or plr.Name
	table.insert(lines, paint(esc(name), PALETTE.name)
		.. paint(("   #%d"):format(plr.UserId), PALETTE.dim))

	local team = plr.Team and plr.Team.Name or "none"
	local hpNow = puppet and puppet:GetAttribute("Health")
	local alive = puppet ~= nil and puppet:GetAttribute("Dead") ~= true
		and (hpNow == nil or hpNow > 0)
	table.insert(lines, paint("team ", PALETTE.dim) .. paint(team, PALETTE.value)
		.. paint("   ", PALETTE.dim)
		.. (alive and paint("ALIVE", PALETTE.good) or paint("DEAD", PALETTE.bad)))

	if puppet then
		local hp    = puppet:GetAttribute("Health") or 0
		local maxHp = puppet:GetAttribute("MaxHealth") or 100
		local armor = puppet:GetAttribute("Armor") or 0
		local helmet = puppet:GetAttribute("Helmet") == true

		local hpFrac = (maxHp > 0) and (hp / maxHp) or 0
		table.insert(lines, paint("hp    ", PALETTE.dim)
			.. paint(("%3d"):format(math.floor(hp)), levelColour(hpFrac))
			.. paint("  " .. bar(hpFrac, 20), levelColour(hpFrac)))

		local armorFrac = armor / 100
		table.insert(lines, paint("armor ", PALETTE.dim)
			.. paint(("%3d"):format(math.floor(armor)), armor > 0 and PALETTE.armor or PALETTE.dim)
			.. paint("  " .. bar(armorFrac, 20), armor > 0 and PALETTE.armor or PALETTE.dim)
			.. (helmet and paint("  HELMET", PALETTE.armor) or ""))
	else
		table.insert(lines, paint("no puppet -- unloaded or spectating", PALETTE.dim))
	end

	-- The two numbers that explain how the player is moving right now, and
	-- neither is visible anywhere else on the HUD.
	local scale = State.weaponSpeedScale or 1
	table.insert(lines, paint("wpn speed ", PALETTE.dim)
		.. paint(("x%.2f"):format(scale), scale < 0.999 and PALETTE.warn or PALETTE.value)
		.. paint("   last land ", PALETTE.dim)
		.. paint(("%.0f"):format(State.lastLandSpeed or 0),
			(State.lastLandSpeed or 0) > num(Config.sv_falldamage_safe, 52.7)
				and PALETTE.bad or PALETTE.value))

	playerLabel.Text = table.concat(lines, "\n")
end

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
	playerLabel.Visible = showHud
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

	-- ---- player panel ----
	-- Outside the body gate on purpose: when the body is gone is exactly when
	-- you want to see that you are DEAD, and a panel that stops updating is a
	-- panel that lies.
	if showHud then updatePlayerPanel() end

	-- ---- speedometer + stats ----
	if showHud and body then
		speedLabel.Text = string.format("%.0f", speed)
		-- Coloured by how fast rather than by grounded: the interesting thing
		-- about a number on a speedometer is the number.
		speedLabel.TextColor3 = speedColour(speed, num(Config.sv_maxspeed, 22.7))

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

		local fpsColour = (displayFps < 30 and PALETTE.bad)
			or (displayFps < 55 and PALETTE.warn) or PALETTE.good
		local hzColour = (displayHz < targetHz * 0.9) and PALETTE.bad or PALETTE.good
		local driftMag = (actualVel - vel).Magnitude
		local driftColour = (driftMag > 5 and PALETTE.bad)
			or (driftMag > 1 and PALETTE.warn) or PALETTE.good
		local depen = int(State.depenCount)
		local landSpeed = num(State.lastLandSpeed)

		statsLabel.Text = table.concat({
			sysBlock(),
			"",
			row("fps", vc(fpsColour, "%6.1f", displayFps)),
			row("phys hz", vc(hzColour, "%6.1f", displayHz),
				dim(" / %d", int(targetHz)),
				hzWarn ~= "" and vc(PALETTE.bad, "%s", hzWarn) or ""),
			row("dt game", v("%6.4f", deltaTime), dim("   real "), v("%6.4f", realDt)),
			"",
			row("speed", vc(speedColour(speed, num(Config.sv_maxspeed, 22.7)), "%6.2f", speed),
				dim("   (peak %.2f)", peakSpeed)),
			row("vel", v("%s", fmtVec(vel))),
			row("vert", vc(vel.Y > 0.1 and PALETTE.cool
				or (vel.Y < -num(Config.sv_falldamage_safe, 52.7) and PALETTE.bad)
				or PALETTE.value, "%6.2f", vel.Y)),
			row("wishdir", v("%s", fmtVec(wd)), dim("  |%.2f|", wd.Magnitude)),
			row("pos", v("%s", fmtVec(body.Position))),
			row("hull", v("%s", fmtVec(body.Size))),
			row("gnd nrm", v("%s", fmtVec(State.groundNormal or Vector3.yAxis))),
			"",
			row("actual", v("%s", fmtVec(actualVel))),
			row("drift", vc(driftColour, "%6.2f", driftMag)),
			-- depen is per-TICK: anything above 0 means the hull is inside
			-- geometry right now. stepup is cumulative; watch it climb.
			row("depen", vc(depen > 0 and PALETTE.bad or PALETTE.good, "%d", depen),
				dim("/tick   stepup "), v("%d", int(State.stepUpCount))),
			"",
			row("grounded", flag(State.isGrounded),
				dim("  ladder "), flag(State.onLadder),
				dim("  noclip "), flag(State.noclip)),
			row("jumping", flag(State.isJumping),
				dim("  diving "), flag(State.isDiving),
				dim("  sprint "), flag(State.isSprinting)),
			-- Intent and hull are now two different things, separated by up to
			-- mv_uncrouchJumpTime. Speed follows the HULL, so isCrouching
			-- alone will lie to you for the whole transition.
			row("crouch", dim("key "), flag(State.isCrouching),
				dim(" hull "), flag(State.isDucked),
				dim("  f "), v("%.2f", num(State.duckFraction))),
			row("prone", dim("key "), flag(State.isProne),
				dim(" hull "), flag(State.isProneStance),
				dim("  trans "), v("%s", yn(State.isInStanceTransition))),
			"",
			row("coyote", v("%5.3f", num(State.coyoteTimer)),
				dim("   buffer "), v("%5.3f", num(State.jumpBufferTimer))),
			row("brake", v("%5.3f", brakeElapsed), dim(" / "), v("%5.3f", brakeWindow),
				dim("  "),
				braking and paint("APPLYING", PALETTE.warn) or paint("WITHHELD", PALETTE.good)),
			row("lift", v("%-3d", int(State.duckLift)),
				dim("  sgs "), v("%5.3f", num(State.sgsGrace)),
				dim("  ladderTO "), v("%5.3f", num(State.ladderTimeout))),
			row("airtime", v("%5.2fs", num(State.dbgAirtime)),
				dim("   lastJump "), v("%.2f", num(State.dbgJumpHeight)),
				dim("   land "),
				vc(landSpeed > num(Config.sv_falldamage_safe, 52.7) and PALETTE.bad
					or PALETTE.value, "%.0f", landSpeed)),
			"",
			row("wishCall", v("%d", wishCalls), dim("  (%s)", wishTag)),
			row("gameTime", v("%9.3f", gameTime), dim("  (%s)", gameTag)),
			row("timescale", vc(scaleDrift and PALETTE.bad or PALETTE.value, "%5.3f", stateScale),
				dim("  cvar "), v("%5.3f", cvarScale),
				scaleDrift and vc(PALETTE.bad, "  %s", "<-- DESYNC") or ""),
			"",
			row("keys",
				key(Enum.KeyCode.W, "W"), dim(" "), key(Enum.KeyCode.A, "A"), dim(" "),
				key(Enum.KeyCode.S, "S"), dim(" "), key(Enum.KeyCode.D, "D"),
				dim("   focus "), flag(UserInputService.WindowFocused)),
			"",
			row("strafe", v("%5.1f deg", angle),
				dim("  proj "), v("%5.2f", proj),
				dim(" / %.2f", num(Config.sv_air_max_wishspeed))),
			"",
			-- Bob is a viewmodel-only signal now. If these move and the gun
			-- doesn't, the cause is downstream in ViewSway or the vm pivot,
			-- not in ViewBob.
			row("bob", v("v%+.3f l%+.3f", num(ViewBob.verticalBob), num(ViewBob.lateralBob)),
				dim("  spd "), v("%5.2f", num(ViewBob.bobSpeed))),
			row("roll", v("%+5.2f deg", num(State.cameraRoll))),
			"",
			-- Effective friction, not just the cvar: surface and edge both
			-- multiply it, and either can be the reason a stop feels wrong.
			row("accel", dim("g"), v("%.1f", num(Config.sv_accelerate)),
				dim(" a"), v("%.1f", num(Config.sv_airaccelerate)),
				dim("  fric "), v("%.1f", num(Config.sv_friction)),
				dim(" x"), vc(surfFric < 0.999 and PALETTE.warn or PALETTE.value, "%.2f", surfFric),
				dim(" x"), vc(edgeFric > 1.001 and PALETTE.warn or PALETTE.value, "%.2f", edgeFric)),
			row("grav", v("%.1f", num(Config.sv_gravity)),
				dim("  jump "), v("%.1f", num(Config.sv_jump_impulse)),
				dim("  step "), v("%.2f", num(Config.sv_stepsize))),
		}, "\n")

	elseif showHud then
		-- No body. Keep the clock diagnostics up rather than blanking the
		-- panel -- "is anything still ticking" is the question you have here.
		speedLabel.Text = "--"
		statsLabel.Text = table.concat({
			paint("NO BODY", PALETTE.bad),
			"",
			sysBlock(),
			"",
			row("fps", v("%6.1f", displayFps)),
			row("phys hz", v("%6.1f", displayHz)),
			row("gameTime", v("%9.3f", gameTime), dim("  (%s)", gameTag)),
			row("timescale", vc(scaleDrift and PALETTE.bad or PALETTE.value, "%5.3f", stateScale),
				dim("  cvar "), v("%5.3f", cvarScale),
				scaleDrift and vc(PALETTE.bad, "  %s", "<-- DESYNC") or ""),
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
			local walk = num(Config.sv_maxspeed, 22.7)
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

		-- The magazine is what you look at this label for, so it picks the
		-- colour -- same green/amber/red rule as health. A knife's magSize is
		-- math.huge and has no fraction to take.
		local mag = s and s.magSize
		weaponLabel.TextColor3 = (type(mag) == "number" and mag < math.huge and mag > 0)
			and levelColour(num(State.currentAmmo, 0) / mag)
			or Color3.fromRGB(255, 230, 180)

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
	displayScale = num(Config.sv_maxspeed, 22.7) * 1.25
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