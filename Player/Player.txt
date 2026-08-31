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

Config.OnChange("loadhere", function(value)
	-- Don't spawn from inside Config.Set: it can be called from the console
	-- thread or the SyncConfig remote, and Character.Spawn may yield.
	-- Just raise the flag; Heartbeat drains it.
	if value == true then
		pendingLoadHere = true
	end
end)

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

Config.OnChange("unload", function(value)
	if value == true then
		pendingUnload = true
	end
end)

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

RunService.Heartbeat:Connect(function()
	if not pendingUnload or unloadBusy then return end
	pendingUnload = false
	unloadBusy = true

	Config.Values.unload = false

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

	-- Reset the latch directly on Values: no print spam, no listener re-entry,
	-- and no cheat-lock check on a value we're only ever clearing.
	Config.Values.loadhere = false

	task.spawn(function()
		local ok, err = pcall(doLoadHere)
		if not ok then warn("[loadhere]", err) end
		loadHereBusy = false
	end)
end)


-- The Physics Loop
RunService.PreSimulation:Connect(function(deltaTime)
	local ts = math.clamp(Config.Values.host_timescale or 1, 0.01, 10)
	State.timeScale = ts

	local sdt = deltaTime * ts
	State.gameTime += sdt

	if not State.playerBody then return end
	Input.UpdateMouse()
	Input.UpdateWishDir()
	Physics.Update(sdt)          -- scaled
	
	
end)

-- The Render Loop
RunService.RenderStepped:Connect(function(deltaTime)
	local sdt = deltaTime * State.timeScale

	Spectate.Update(deltaTime)      -- REAL time: freecam should stay responsive
	ServerDebug.Update(deltaTime)   -- REAL time: it's a HUD
	if not State.playerBody then return end
	-- Fraction of the way to the next sim step. Advanced here rather than
	-- derived from gameTime, so it doesn't matter which loop owns the clock.
	State.tickAlpha = math.min(1,
		State.tickAlpha + deltaTime / math.max(State.stepInterval, 1e-4))
	
	Character.UpdateVisibility()
	Weapons.PreRender(sdt)
	Visuals.Update(sdt)
	Weapons.Update(sdt)
	Debug.Update(deltaTime)         -- REAL time
	Crosshair.Update(sdt)
	Sounds.Update(sdt)
	Input.UpdateMouse()
end)

-- Server Sync
local lastWeaponName = nil
RunService.Heartbeat:Connect(function()
	if State.playerPuppet and State.playerPuppet.PrimaryPart then
		
		if State.currentWeaponStats then
			lastWeaponName = State.currentWeaponStats.name
		end

		
		PuppetSync:FireServer({
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


	if packet.CFRAME and puppet.PrimaryPart then
		puppet.PrimaryPart.CFrame = packet.CFRAME
	end
	
	if packet.LOOK_PITCH then
		UpdateBoneLookPitch(puppet, packet.LOOK_PITCH)
	end

	-- Idempotent, so a dropped packet self-corrects next frame.
	Visuals.ApplyRemoteState(puppet, packet.ANIM, packet.ANIM_SPEED, packet.WEAPON)
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
