-- LocalScript: CustomController
-- Child of Glacier1, Gets injected into the players PlayerGui.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local AnimationSync = ReplicatedStorage:WaitForChild("AnimationSync")
local PuppetSync = ReplicatedStorage:WaitForChild("PuppetSync")
local Weapons = require(script.Weapons)
local Lifecycle = ReplicatedStorage:WaitForChild("PlayerLifecycle")   -- ADD
local ConfigSync = ReplicatedStorage:WaitForChild("ConfigSync")
-- Require all our modules
local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
local State = require(script.State)
local Input = require(script.Input)
local Math = require(script.MovementMath)
local Character = require(script.Character)
local Physics = require(script.Physics)
local Vehicle = require(script.Vehicle)
local Visuals = require(script.Visuals)
local Debug = require(script.Debug)
local Sounds = require(script.Sounds)
local Crosshair = require(script.Crosshair)
local Bullets = require(script.Bullets)
local Spectate = require(script.Spectate)
local SoundReceiver = require(script.SoundReceiver)
local ServerDebug = require(script.ServerDebug)
local Inventory = require(ReplicatedStorage:WaitForChild("Inventory"))
local InventorySync = ReplicatedStorage:WaitForChild("InventorySync")
Debug.Physics = Physics     -- lets it read the step counter

-- Initialize
Input.Init()
--Character.Spawn()
Debug.Init()
Sounds.Init()
Crosshair.Init()
Bullets.onRecoilSync     = Weapons.ApplyRecoilSync
Visuals.onWeaponEquipped = Weapons.OnEquipped
Bullets.Init()
Spectate.Init()
SoundReceiver.Init()
ServerDebug.Init()
Vehicle.Init()
--=====================================================================
-- Lifecycle helpers (shared by loadhere / unload)
--=====================================================================

local function rawBodyName()
	return Players.LocalPlayer.UserId .. "RawBody"
end

-- Waits for the server's destroy to land as a replication removal. Without
-- this, loadhere fires its spawn request while the old body is still on the
-- wire and the server's destroy-then-build can race against it.
local function waitForRawBodyGone(timeout)
	local deadline = os.clock() + (timeout or 3)
	while workspace:FindFirstChild(rawBodyName()) do
		if os.clock() >= deadline then return false end
		RunService.Heartbeat:Wait()
	end
	return true
end

local function waitForRawBody(timeout)
	local deadline = os.clock() + (timeout or 5)
	while not State.playerBody do
		if os.clock() >= deadline then return false end
		RunService.Heartbeat:Wait()
	end
	return true
end

local function clearLocalState()
	State.playerBody = nil
	State.playerPuppet = nil
	State.curBodyPos  = nil
	State.prevBodyPos = nil
	State.snapRender  = true
	--- FIELD NAMES: adjust to match your State module -------------------
	State.currentWeaponStats = nil
	if State.velocity then State.velocity = Vector3.zero end
	----------------------------------------------------------------------
end
--=====================================================================
-- loadhere
--=====================================================================

local pendingLoadHere = false
local loadHereBusy = false

-- Raised by the command below rather than by a cvar write. loadhere and unload
-- are VERBS -- `loadhere` should place you, not need `loadhere 1` and then read
-- back as a setting that is somehow false again afterwards.
--
-- Still a latch and not a direct call: Character.Spawn yields, and the command
-- can run from the console thread or off a bind, neither of which should be
-- left waiting on a spawn.
local function requestLoadHere()
	pendingLoadHere = true
end



local function loadHereCFrame()
	local cam = workspace.CurrentCamera
	local pos = cam.CFrame.Position

	if Config.loadhere_matchEye then
		local eye = Config.cl_standingCamHeight
		pos -= Vector3.new(0, eye, 0)
	end

	-- Keep the body upright; only carry the camera's yaw across.
	local look = cam.CFrame.LookVector
	local yaw = math.atan2(-look.X, -look.Z)
	return CFrame.new(pos) * CFrame.Angles(0, yaw, 0)
end
local function yawOf(cf)
	local _, y = cf:ToEulerAnglesYXZ()
	return y
end
local function doLoadHere()
	local cf = loadHereCFrame()

	if not State.playerBody then
		-- Back to the client path. This is what actually assigns
		-- State.playerBody; the server LOADHERE route created the instance but
		-- left State nil, so we sat in spectate forever. Safe again now that
		-- unload is server-side and can't leave a stale body behind.
		Character.Spawn()

		if not waitForRawBody(5) then
			warn("[loadhere] Character.Spawn() produced no State.playerBody within 5s.")
			return
		end
	end

	local body = State.playerBody
	if body:IsA("BasePart") then
		body.CFrame = cf
	elseif body:IsA("Model") then
		body:PivotTo(cf)
	end

	--- FIELD NAMES ------------------------------------------------------
	if State.velocity then State.velocity = Vector3.zero end
	if State.cameraX then State.cameraX = math.deg(yawOf(cf)) end
	----------------------------------------------------------------------

	print(string.format("[loadhere] placed at %.1f, %.1f, %.1f",
		cf.Position.X, cf.Position.Y, cf.Position.Z))
end

--=====================================================================
-- unload
--=====================================================================

local pendingUnload = false
local unloadBusy = false

local function requestUnload()
	pendingUnload = true
end



local function doUnload()
	if not State.playerBody and not workspace:FindFirstChild(rawBodyName()) then
		print("[unload] nothing to unload.")
		return
	end

	local lastCam = workspace.CurrentCamera.CFrame

	-- Clear State first so the render/physics loops stop touching the rig a
	-- frame before it disappears. We do NOT :Destroy() locally — the server
	-- owns that, and a local destroy is exactly what desyncs the two.
	clearLocalState()

	Lifecycle:FireServer("UNLOAD")

	if Config.unload_keepCamera then
		workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
		workspace.CurrentCamera.CFrame = lastCam
	end

	if waitForRawBodyGone(3) then
		print("[unload] server destroyed body; spectating.")
	else
		warn("[unload] RawBody still present after 3s — server didn't destroy it. Check PlayerLifecycleServer.")
	end
end

--=====================================================================
-- loadhere / unload, as commands
--=====================================================================
-- They were cvars used as latches, which the Config header itself calls out as
-- the wrong shape: "verbs stored as state". As commands they take no argument
-- and stop pretending to hold a value.
--
-- loadhere_matchEye and unload_keepCamera stay cvars -- those really are
-- settings, and they are read at the moment the verb runs.

Config.Command("loadhere", {
	args = {},
	flag = Config.FCVAR.CHEAT,
	help = "place your body where you are looking",
	run = function(ctx)
		requestLoadHere()
		if ctx and ctx.reply then ctx.reply("[loadhere] placing") end
	end,
})

Config.Command("unload", {
	args = {},
	flag = Config.FCVAR.CHEAT,
	help = "destroy your body and drop to spectate",
	run = function(ctx)
		requestUnload()
		if ctx and ctx.reply then ctx.reply("[unload] unloading") end
	end,
})

RunService.Heartbeat:Connect(function()
	if not pendingUnload or unloadBusy then return end
	pendingUnload = false
	unloadBusy = true

	task.spawn(function()
		local ok, err = pcall(doUnload)
		if not ok then warn("[unload]", err) end
		unloadBusy = false
	end)
end)

----
--Maine
----
ConfigSync.OnClientEvent:Connect(function(a, b)
	if type(a) == "table" then
		for key, value in pairs(a) do Config.Set(key, value, true) end
	else
		Config.Set(a, b, true)
	end
end)
-- Pull the full server state. Do this before requiring gameplay modules so
-- OnChange listeners aren't racing a half-applied snapshot.
ConfigSync:FireServer()

RunService.Heartbeat:Connect(function()
	if not pendingLoadHere or loadHereBusy then return end
	pendingLoadHere = false
	loadHereBusy = true

	task.spawn(function()
		local ok, err = pcall(doLoadHere)
		if not ok then warn("[loadhere]", err) end
		loadHereBusy = false
	end)
end)


-- The Frame
--
-- ONE connection, and the order inside it is the whole reason the camera is
-- smooth. The sim used to run in PreSimulation, which Roblox fires AFTER
-- PreRender -- so every frame was rendered from a physics accumulator that was
-- a full frame stale. With a 240Hz sim and a 60Hz display that meant the
-- rendered position always sat on a step boundary, advancing in whole 4.17ms
-- quanta while real frame times varied around 16.7ms. The interpolation could
-- not help: by render time the leftover already exceeded a step, so tickAlpha
-- clamped to 1 and the lerp collapsed onto the newest step.
--
-- Measured, constant velocity with ordinary frame-time jitter, as error between
-- displayed movement and real elapsed time:
--
--            before                 after
--    60fps   worst 47%  rms 18%     0%
--   144fps   worst 48%  rms 31%     0%
--    30fps   worst 32%  rms 16%     0%
--
-- Stepping first makes the accumulator fresh, so the leftover is a real
-- fraction of a step and the lerp lands exactly where real time says it should
-- -- one step behind, constantly, which reads as smooth rather than as lag.
RunService.RenderStepped:Connect(function(deltaTime)
	local ts = math.clamp(Config.Values.host_timescale or 1, 0.01, 10)
	State.timeScale = ts

	local sdt = deltaTime * ts
	State.gameTime += sdt

	Spectate.Update(deltaTime)      -- REAL time: freecam should stay responsive
	ServerDebug.Update(deltaTime)   -- REAL time: it's a HUD
	if not State.playerBody then return end

	-- Simulate, THEN draw. Physics.Update publishes State.tickAlpha from what
	-- is left in the accumulator, so everything below reads a fraction that is
	-- current as of this frame.
	Input.UpdateMouse()
	Input.UpdateWishDir()

	-- Vehicle first, and it returns whether it has taken over. Driving and
	-- walking both write the RawBody and both write the camera, so exactly one
	-- of them may run per frame -- running both is the fight, not the fix.
	-- It is called unconditionally because it also draws every car OTHER
	-- people are driving, which has to happen whether we are seated or not.
	if Vehicle.Update(sdt) then
		-- Weapons deliberately does NOT run while seated. Its update owns the
		-- viewmodel, the muzzle and the recoil punch, and all three are drawn
		-- by Visuals, which is skipped here -- so letting it fire would leave
		-- the effects frozen wherever they were when you got in. Drive-by
		-- shooting is a real feature and this is where it would go; it needs
		-- a seated viewmodel pass first, not just this call back.
		Debug.Update(deltaTime)
		Sounds.Update(sdt)
		return
	end

	Physics.Update(sdt)

	Character.UpdateVisibility()
	Weapons.PreRender(sdt)
	Visuals.Update(sdt)
	Weapons.Update(sdt)
	Debug.Update(deltaTime)         -- REAL time
	Crosshair.Update(sdt)
	Sounds.Update(sdt)
end)

-- Server Sync
local lastWeaponName = nil
RunService.Heartbeat:Connect(function()
	-- The car we are driving, if any. On Heartbeat rather than per frame for
	-- the same reason PuppetSync is: the server relays it to other clients,
	-- and there is no point sending faster than they can draw.
	Vehicle.Sync()

	if State.playerPuppet and State.playerPuppet.PrimaryPart then
		
		if State.currentWeaponStats then
			lastWeaponName = State.currentWeaponStats.name
		end

		
		PuppetSync:FireServer({
			-- Shared clock, so the receiver can order and interpolate these.
			-- os.clock() would be each machine's own epoch and meaningless
			-- anywhere but the sender.
			T = workspace:GetServerTimeNow(),
			CFRAME = State.playerPuppet.PrimaryPart.CFrame,
			LOOK_PITCH = State.cameraY or 0,
			CROUCHED = State.isCrouching or State.isProne,
			GROUNDED = State.isGrounded,
			ANIM = Visuals.lastTargetState,
			ANIM_SPEED = Visuals.lastAnimSpeed,
			WEAPON = lastWeaponName,
		})
	end
	
	
	
end)

local RemoteTracksCache = {}


-- FIXED: R6 Rig bending via the HumanoidRootPart's RootJoint
local function UpdateBoneLookPitch(puppet, lookPitchDeg)
	if not puppet then return end

	local hrp = puppet:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local rootJoint = hrp:FindFirstChild("RootJoint")
	if rootJoint and rootJoint:IsA("Motor6D") then
		-- Cache the original C0 matrix so it doesn't spin infinitely
		if not rootJoint:GetAttribute("OriginalC0") then
			rootJoint:SetAttribute("OriginalC0", rootJoint.C0)
		end

		local origC0 = rootJoint:GetAttribute("OriginalC0")
		local clampedPitch = math.clamp(lookPitchDeg, -75, 75)
		local pitchRad = math.rad(clampedPitch)

		if Config.cl_noOrient then
			rootJoint.C0 = origC0
		else
			-- Bend the R6 torso up and down by rotating the RootJoint's X-axis
			rootJoint.C0 = origC0 * CFrame.Angles(-pitchRad, 0, 0)
		end
	end
end
local lastSeenWeapon = nil
--=====================================================================
-- REMOTE PUPPET INTERPOLATION
--=====================================================================
-- Remote puppets used to be snapped straight onto whatever CFrame last
-- arrived. PuppetSync is an UnreliableRemoteEvent fired from a RenderStepped
-- loop, so packets arrive at an irregular rate, out of order, and sometimes
-- not at all -- and every bit of that showed up as jitter.
--
-- Instead each packet goes into a small buffer keyed on the SENDER's clock,
-- and rendering happens at (now - cl_interp), between the two snapshots that
-- bracket it. Standard Source snapshot interpolation.

local remoteBuffers = {}   -- [Player] = { {t, cf, pitch}, ... } oldest first
local MAX_SNAPSHOTS = 32

local function pushSnapshot(plr, packet)
	local buf = remoteBuffers[plr]
	if not buf then
		buf = {}
		remoteBuffers[plr] = buf
	end

	-- Sender's stamp where there is one. Receive time is the fallback, and it
	-- is strictly worse: a packet delayed in flight carries an OLD pose with a
	-- NEW arrival time, which is exactly the reordering this is meant to undo.
	local t = (type(packet.T) == "number") and packet.T or workspace:GetServerTimeNow()

	-- recv is our own clock at arrival. Pairing it with the sender's stamp is
	-- what lets the render clock below absorb latency instead of fighting it.
	local snapshot = { t = t, recv = os.clock(), cf = packet.CFRAME, pitch = packet.LOOK_PITCH or 0 }

	-- Insert in time order rather than appending: a late packet belongs where
	-- it was sent, not at the end.
	local i = #buf
	while i > 0 and buf[i].t > t do i -= 1 end
	if i > 0 and buf[i].t == t then return end   -- duplicate
	table.insert(buf, i + 1, snapshot)

	while #buf > MAX_SNAPSHOTS do table.remove(buf, 1) end
end

local function puppetOf(plr)
	local rawBody = workspace:FindFirstChild(plr.UserId .. "RawBody")
	return rawBody and rawBody:FindFirstChild("Puppet") or nil
end

-- Position at renderTime, or nil when the buffer cannot answer.
local function sampleAt(buf, renderTime)
	if #buf == 0 then return nil end

	-- Ahead of everything we hold: the buffer ran dry.
	if renderTime >= buf[#buf].t then
		local newest = buf[#buf]
		if not Config.cl_extrapolate or #buf < 2 then return newest.cf, newest.pitch end

		local gap = renderTime - newest.t
		if gap > (Config.cl_extrapolateMax or 0.25) then return newest.cf, newest.pitch end

		-- Coast on the last known velocity. Rotation is deliberately NOT
		-- extrapolated: a spinning player would wind up like a top.
		local prev = buf[#buf - 1]
		local dt = newest.t - prev.t
		if dt <= 0 then return newest.cf, newest.pitch end

		local vel = (newest.cf.Position - prev.cf.Position) / dt
		return newest.cf + vel * gap, newest.pitch
	end

	-- Behind everything: hold the oldest rather than guessing backwards.
	if renderTime <= buf[1].t then return buf[1].cf, buf[1].pitch end

	for i = 1, #buf - 1 do
		local a, b = buf[i], buf[i + 1]
		if renderTime >= a.t and renderTime <= b.t then
			local span = b.t - a.t
			local alpha = (span > 0) and ((renderTime - a.t) / span) or 1
			-- CFrame:Lerp slerps the rotation, so a turning player sweeps
			-- through the turn instead of snapping across it.
			return a.cf:Lerp(b.cf, alpha), a.pitch + (b.pitch - a.pitch) * alpha
		end
	end

	local newest = buf[#buf]
	return newest.cf, newest.pitch
end

-- The render clock, in the SENDER's timebase.
--
-- Not GetServerTimeNow() - cl_interp, which is the obvious version and is
-- wrong: that measures the buffer from a clock the packet has already spent
-- its latency travelling under, so the depth actually available is
-- cl_interp MINUS latency. At 100ms of ping and cl_interp 0.1 there is no
-- buffer left at all, every frame extrapolates, and the jitter is back.
--
-- Instead the offset between the two clocks is observed directly from the
-- newest packet (which folds latency in), so the buffer is cl_interp deep no
-- matter how far away the sender is. Smoothed, because a single delayed
-- packet reports a smaller offset and would otherwise yank the clock; snapped
-- when the two disagree wildly, which means the sender respawned, rejoined,
-- or the connection stalled long enough that easing back would take seconds.
local function renderClock(buf, interp)
	local newest = buf[#buf]
	local offset = newest.t - newest.recv

	if not buf.offset or math.abs(offset - buf.offset) > 0.5 then
		buf.offset = offset
	else
		buf.offset += (offset - buf.offset) * 0.1
	end

	return os.clock() + buf.offset - interp
end

local function updateRemotePuppets()
	local interp = Config.cl_interp or 0.1

	for plr, buf in pairs(remoteBuffers) do
		if not plr.Parent then
			remoteBuffers[plr] = nil
		elseif #buf == 0 then
			-- nothing to draw from yet
		else
			local renderTime = renderClock(buf, interp)
			local puppet = puppetOf(plr)
			if puppet and puppet.PrimaryPart then
				local cf, pitch = sampleAt(buf, renderTime)
				if cf then
					puppet.PrimaryPart.CFrame = cf
					UpdateBoneLookPitch(puppet, pitch)
				end
			end

			-- Anything older than the two samples bracketing renderTime is
			-- dead weight; keep one spare for the extrapolation velocity.
			-- Reusing renderTime rather than asking again: renderClock steps
			-- the offset filter, and calling it twice a frame would advance
			-- that filter at double rate.
			while #buf > 2 and buf[2].t < renderTime do table.remove(buf, 1) end
		end
	end
end

Players.PlayerRemoving:Connect(function(plr) remoteBuffers[plr] = nil end)

PuppetSync.OnClientEvent:Connect(function(plr, packet)
	if plr == Players.LocalPlayer then return end
	if type(packet) ~= "table" then return end
	
	if packet.WEAPON ~= lastSeenWeapon then
		print("[remote] weapon changed:", lastSeenWeapon, "->", packet.WEAPON)
		lastSeenWeapon = packet.WEAPON
	end
	local rawBody = workspace:FindFirstChild(plr.UserId .. "RawBody")
	local puppet = rawBody and rawBody:FindFirstChild("Puppet")
	if not puppet then return end

	Spectate.NoteRemote(plr, packet)    -- ADD


	if typeof(packet.CFRAME) == "CFrame" and puppet.PrimaryPart then
		if Config.cl_interpolateRemotes == false then
			-- Escape hatch: snap straight to the packet, the old behaviour.
			puppet.PrimaryPart.CFrame = packet.CFRAME
			if packet.LOOK_PITCH then UpdateBoneLookPitch(puppet, packet.LOOK_PITCH) end
		else
			pushSnapshot(plr, packet)
		end
	end

	-- Idempotent, so a dropped packet self-corrects next frame.
	Visuals.ApplyRemoteState(puppet, packet.ANIM, packet.ANIM_SPEED, packet.WEAPON)
end)

-- Its own connection rather than a line in the main render loop, for two
-- reasons: that loop returns early when the local player has no body, and
-- remote puppets still have to move while you are dead or spectating; and
-- updateRemotePuppets is declared below it, so it could not be called from
-- there without a forward declaration.
RunService.RenderStepped:Connect(function()
	if Config.cl_interpolateRemotes == false then return end
	updateRemotePuppets()
end)

local AnimDefs = require(ReplicatedStorage:WaitForChild("AnimDefs"))
local RemoteTracks = setmetatable({}, {__mode = "k"})
local function resolveDefs(packet)
	if packet.layer == "weapon" and packet.weapon then
		local folder = ReplicatedStorage:FindFirstChild("Weapons")
		local mod = folder and folder:FindFirstChild(packet.weapon)
		if mod and mod:IsA("ModuleScript") then
			local ok, stats = pcall(require, mod)
			if ok then
				return AnimDefs.WeaponSet(stats, Config.cl_sharedWeaponAnims)
			end
		end
		return {}
	end
	return AnimDefs.PUPPET
end

AnimationSync.OnClientEvent:Connect(function(plr, packet)
	if plr == Players.LocalPlayer then return end
	if type(packet) ~= "table" then return end

	local rawBody = workspace:FindFirstChild(plr.UserId .. "RawBody")
	local puppet = rawBody and rawBody:FindFirstChild("Puppet")
	if not puppet then return end

	Visuals.PlayRemoteOneShot(puppet, packet.track, packet.weapon)
end)



InventorySync.OnClientEvent:Connect(function(packet)
	if type(packet) ~= "table" then return end

	Inventory.ApplyAll(State, packet.slots)

	if type(packet.activeSlot) == "number" then
		State.activeSlot = packet.activeSlot
		Inventory.Pull(State)
	end
end)

local SyncConfig = ReplicatedStorage:WaitForChild("SyncConfig")
SyncConfig.OnClientEvent:Connect(function(key, value)
	-- Pass 'true' as the third argument to force bypass the local client lock
	Config.Set(key, value, true)
end)

local function snapTo(pos)
	State.curBodyPos  = pos
	State.prevBodyPos = pos
	State.tickAlpha   = 1
	State.snapRender  = true
end
Lifecycle.OnClientEvent:Connect(function(action, detail)
	if action == "DENIED" then
		warn(("[Lifecycle] '%s' refused: not admin, or sv_cheats is 0."):format(tostring(detail)))

	elseif action == "SPAWN_FAILED" then
		warn("[Lifecycle] server could not spawn a body.")

	elseif action == "ADOPT" then
		-- The server built us a body. Wait for replication, then run the same
		-- local setup the client-driven path runs. This used to inline a
		-- partial copy of Character.Spawn's tail, which is why a
		-- server-spawned player got a body and a puppet but no loadout.
		task.spawn(function()
			local body = workspace:WaitForChild(rawBodyName(), 5)
			if not body then
				warn("[Lifecycle] ADOPT but the RawBody never replicated.")
				return
			end

			if not Character.Adopt(body) then
				warn("[Lifecycle] ADOPT: Character.Adopt failed.")
				return
			end

			snapTo(body:IsA("BasePart") and body.Position or body:GetPivot().Position)
			print("[Lifecycle] adopted server-spawned body.")
			
			
			local puppet = body:WaitForChild("Puppet")
			for _, v in ipairs(puppet:GetDescendants()) do
				if v:IsA("BasePart") then
					v.CanCollide = false
					v.CanQuery = false
					v.CanTouch = false
					v.Massless = true
					v.Anchored = true   -- stops gravity dragging the puppet down
					v.AudioCanCollide = false
				end
			end
		end)

	elseif action == "TELEPORT" then
		if not State.playerBody then return end
		if State.playerBody:IsA("BasePart") then
			State.playerBody.CFrame = detail
		else
			State.playerBody:PivotTo(detail)
		end
		-- Kill inherited momentum, or you arrive still carrying your old
		-- velocity and slide out of the spawn box.
		if State.velocity then State.velocity = Vector3.zero end
		snapTo(detail.Position)
	elseif action == "DIED" then
		-- Hand control to the spectator immediately; the corpse lingers
		-- server-side but this client shouldn't still be driving it.
		clearLocalState()
	end
end)
