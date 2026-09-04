-- ModuleScript: Spectate
-- Parent: CustomController (sibling of State / Input / Physics)
--
-- Owns the camera for as long as State.playerBody is nil. Modes mirror CS:GO
-- observer modes: in-eye, chase, roaming.
--
-- Controls while spectating:
--   Mouse1 / Mouse2  next / previous target
--   Space            cycle mode
--   WASD + Space/Ctrl  freecam move (LeftShift fast, LeftAlt slow)
--   Wheel            freecam speed

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local State  = require(script.Parent.State)

local LocalPlayer = Players.LocalPlayer

local Spectate = {}

Spectate.MODE = { FIRST = 0, THIRD = 1, FREE = 2 }
local MODE_NAME = { [0] = "First Person", [1] = "Third Person", [2] = "Freecam" }

-- Match this to whatever Input.lua multiplies raw mouse delta by, or the
-- freecam will feel faster/slower than your normal look.
local SENS_SCALE = 0.3

Spectate.active = false
Spectate.target = nil
Spectate.mode   = Spectate.MODE.THIRD

-- NOT weak-keyed, deliberately. A __mode="k" table here gets collected out from
-- under us mid-round and first-person pitch silently flattens to zero.
local remoteInfo = {}   -- [Player] = { pitch = number, crouched = boolean }

local camera      = workspace.CurrentCamera
local camYaw      = 0     -- degrees
local camPitch    = 0     -- degrees
local freePos     = Vector3.zero
local freeVel     = Vector3.zero
local freeSpeed   = 30
local snapNext    = true
local holdUntil   = 0
local holdCFrame  = nil

local savedCamType, savedMouseBehaviour, savedFov
local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Exclude

local hudGui, hudLabel

--=====================================================================
-- HELPERS
--=====================================================================

local function alphaFor(rate, dt)
	if rate <= 0 then return 1 end
	return 1 - math.exp(-rate * dt)   -- framerate independent lerp
end

local function getRawBody(plr)
	return workspace:FindFirstChild(plr.UserId .. "RawBody")
end

local function getPuppet(plr)
	local rb = getRawBody(plr)
	local p = rb and rb:FindFirstChild("Puppet")
	if p and p.PrimaryPart then return p end
	return nil
end

-- Teams aren't in yet. Until a player actually has a Team assigned this returns
-- true, so spec_everyone false doesn't lock you out of spectating entirely.
local function sameTeam(a, b)
	if a.Team == nil or b.Team == nil then return true end
	return a.Team == b.Team
end

-- Health lives in Instance Attributes. Checks the usual spots; if nothing is
-- set anywhere we assume alive rather than filtering everyone out.
local function isAlive(plr, puppet)
	local hp = puppet:GetAttribute("Health")
	if hp == nil and puppet.Parent then hp = puppet.Parent:GetAttribute("Health") end
	if hp == nil then hp = plr:GetAttribute("Health") end
	if hp == nil then return true end
	return hp > 0
end

local function isValidTarget(plr)
	if plr == LocalPlayer then return false end
	local puppet = getPuppet(plr)
	if not puppet then return false end
	if not isAlive(plr, puppet) then return false end
	if not Config.spec_everyone and not sameTeam(LocalPlayer, plr) then return false end
	return true
end

-- Sorted by UserId so cycling order is stable for everyone.
function Spectate.Targets()
	local out = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if isValidTarget(plr) then table.insert(out, plr) end
	end
	table.sort(out, function(a, b) return a.UserId < b.UserId end)
	return out
end

local function refreshCastFilter()
	local ignore = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local rb = getRawBody(plr)
		if rb then table.insert(ignore, rb) end
	end
	castParams.FilterDescendantsInstances = ignore
end

local function eyePos(puppet)
	local head = puppet:FindFirstChild("Head")
	if head then return head.Position end
	return puppet.PrimaryPart.Position + Vector3.new(0, Config.spec_firstPersonHeight, 0)
end

local function puppetYawDeg(puppet)
	local _, y = puppet.PrimaryPart.CFrame:ToEulerAnglesYXZ()
	return math.deg(y)
end

local function targetPitchDeg(plr)
	local info = remoteInfo[plr]
	-- SIGN NOTE: this assumes State.cameraY is positive-up, same convention the
	-- torso bend in CustomController uses. If in-eye spectating looks inverted
	-- vertically, negate this one return value.
	return info and info.pitch or 0
end

--=====================================================================
-- HUD
--=====================================================================

local function buildHud()
	local pg = LocalPlayer:WaitForChild("PlayerGui")

	hudGui = Instance.new("ScreenGui")
	hudGui.Name = "SpectateHud"
	hudGui.ResetOnSpawn = false
	hudGui.IgnoreGuiInset = true
	hudGui.Enabled = false
	hudGui.Parent = pg

	hudLabel = Instance.new("TextLabel")
	hudLabel.AnchorPoint = Vector2.new(0.5, 1)
	hudLabel.Position = UDim2.new(0.5, 0, 1, -40)
	hudLabel.Size = UDim2.new(0, 700, 0, 44)
	hudLabel.BackgroundTransparency = 1
	hudLabel.Font = Enum.Font.Code
	hudLabel.TextSize = 18
	hudLabel.TextColor3 = Color3.fromRGB(235, 235, 235)
	hudLabel.TextStrokeTransparency = 0.35
	hudLabel.Text = ""
	hudLabel.Parent = hudGui
end

local function updateHud()
	if not hudLabel then return end
	hudGui.Enabled = Spectate.active and Config.spec_hud == true
	if not hudGui.Enabled then return end

	local modeStr = MODE_NAME[Spectate.mode] or "?"
	if Spectate.mode == Spectate.MODE.FREE then
		hudLabel.Text = string.format(
			"FREECAM   %.0f studs/s   |   Space: mode   Wheel: speed",
			freeSpeed)
	elseif Spectate.target then
		hudLabel.Text = string.format(
			"SPECTATING  %s   [%s]   |   Mouse1/Mouse2: switch   Space: mode",
			Spectate.target.DisplayName, modeStr)
	else
		hudLabel.Text = "NO ONE TO SPECTATE   |   Space: mode"
	end
end

--=====================================================================
-- TARGET / MODE
--=====================================================================

function Spectate.SetTarget(plr)
	if plr and not isValidTarget(plr) then return false end
	Spectate.target = plr
	snapNext = true
	refreshCastFilter()

	-- Seat the free-look angles behind the new target so the camera doesn't
	-- start facing a wall.
	if plr then
		local puppet = getPuppet(plr)
		if puppet then
			camYaw = puppetYawDeg(puppet)
			camPitch = math.clamp(targetPitchDeg(plr), -89, 89)
		end
	end
	return true
end

function Spectate.Cycle(dir)
	local list = Spectate.Targets()
	if #list == 0 then
		Spectate.target = nil
		return
	end

	local cur = 0
	for i, p in ipairs(list) do
		if p == Spectate.target then cur = i break end
	end

	local nextIdx
	if cur == 0 then
		nextIdx = (dir >= 0) and 1 or #list
	else
		nextIdx = ((cur - 1 + dir) % #list) + 1
	end
	Spectate.SetTarget(list[nextIdx])
end

function Spectate.SetMode(mode)
	if mode == Spectate.MODE.FREE and not Config.spec_allowFreecam then
		mode = Spectate.MODE.THIRD
	end

	if mode == Spectate.MODE.FREE and Spectate.mode ~= Spectate.MODE.FREE then
		-- Detach from wherever we currently are rather than teleporting.
		freePos = camera.CFrame.Position
		freeVel = Vector3.zero
		local look = camera.CFrame.LookVector
		camYaw = math.deg(math.atan2(-look.X, -look.Z))
		camPitch = math.deg(math.asin(math.clamp(look.Y, -1, 1)))
	end

	Spectate.mode = mode
	snapNext = true
	Config.Set("spec_mode", mode)   -- keep the cvar honest
end

function Spectate.CycleMode()
	local order = { Spectate.MODE.FIRST, Spectate.MODE.THIRD, Spectate.MODE.FREE }
	local cur = 1
	for i, m in ipairs(order) do
		if m == Spectate.mode then cur = i break end
	end
	for i = 1, #order do
		local candidate = order[((cur - 1 + i) % #order) + 1]
		if candidate ~= Spectate.MODE.FREE or Config.spec_allowFreecam then
			Spectate.SetMode(candidate)
			return
		end
	end
end

--=====================================================================
-- CAMERA MODES
--=====================================================================

local function updateLook()
	local delta = UserInputService:GetMouseDelta()
	local sens = Config.spec_mouseSensitivity
	if sens <= 0 then sens = Config.sensitivity end
	camYaw -= delta.X * sens * SENS_SCALE
	camPitch = math.clamp(camPitch - delta.Y * sens * SENS_SCALE, -89, 89)
end

local function applyGoal(goal, dt)
	if snapNext then
		camera.CFrame = goal
		snapNext = false
	else
		camera.CFrame = camera.CFrame:Lerp(goal, alphaFor(Config.spec_lerp, dt))
	end
end

local function updateFirstPerson(dt, puppet)
	local rot = CFrame.fromEulerAnglesYXZ(
		math.rad(targetPitchDeg(Spectate.target)),
		math.rad(puppetYawDeg(puppet)), 0)
	applyGoal(CFrame.new(eyePos(puppet)) * rot, dt)
end

local function updateThirdPerson(dt, puppet)
	local yaw, pitch
	if Config.spec_thirdPersonFreeLook then
		updateLook()
		yaw, pitch = camYaw, camPitch
	else
		yaw = puppetYawDeg(puppet)
		pitch = targetPitchDeg(Spectate.target)
	end

	local rot = CFrame.fromEulerAnglesYXZ(math.rad(pitch), math.rad(yaw), 0)
	local focus = eyePos(puppet) + Vector3.new(0, Config.spec_thirdPersonHeight, 0)

	local offset = (-rot.LookVector * Config.spec_thirdPersonDist)
		+ (rot.RightVector * Config.spec_thirdPersonSide)
	local desired = focus + offset

	if Config.spec_thirdPersonCollide then
		local hit = workspace:Raycast(focus, desired - focus, castParams)
		if hit then
			local dir = (desired - focus).Unit
			local dist = math.max((hit.Position - focus).Magnitude - Config.spec_collideRadius, 0.2)
			desired = focus + dir * dist
		end
	end

	applyGoal(CFrame.new(desired) * rot, dt)
end

local function updateFreecam(dt)
	updateLook()
	local rot = CFrame.fromEulerAnglesYXZ(math.rad(camPitch), math.rad(camYaw), 0)

	local wish = Vector3.zero
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then wish += rot.LookVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then wish -= rot.LookVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then wish += rot.RightVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then wish -= rot.RightVector end
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) then wish += Vector3.yAxis end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then wish -= Vector3.yAxis end

	if wish.Magnitude > 0 then wish = wish.Unit end

	local speed = freeSpeed
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then speed *= Config.spec_freecamFastMult end
	if UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt)   then speed *= Config.spec_freecamSlowMult end

	freeVel = freeVel:Lerp(wish * speed, alphaFor(Config.spec_freecamAccel, dt))
	freePos += freeVel * dt

	camera.CFrame = CFrame.new(freePos) * rot   -- no lerp; input is already smoothed
	snapNext = false
end

--=====================================================================
-- LIFECYCLE
--=====================================================================

function Spectate.Start()
	if Spectate.active then return end
	Spectate.active = true

	camera = workspace.CurrentCamera
	savedCamType = camera.CameraType
	savedFov = camera.FieldOfView
	savedMouseBehaviour = UserInputService.MouseBehavior

	camera.CameraType = Enum.CameraType.Scriptable
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

	freeSpeed = Config.spec_freecamSpeed
	freeVel = Vector3.zero
	freePos = camera.CFrame.Position
	holdCFrame = camera.CFrame
	holdUntil = os.clock() + math.max(Config.spec_freeze_time, 0)
	snapNext = true

	local wanted = math.clamp(math.floor(Config.spec_mode), 0, 2)
	Spectate.mode = (wanted == Spectate.MODE.FREE and not Config.spec_allowFreecam)
		and Spectate.MODE.THIRD or wanted

	refreshCastFilter()
end

function Spectate.Stop()
	if not Spectate.active then return end
	Spectate.active = false

	if camera then
		camera.CameraType = savedCamType or Enum.CameraType.Scriptable
		camera.FieldOfView = savedFov or Config.fov
	end
	UserInputService.MouseBehavior = savedMouseBehaviour or Enum.MouseBehavior.LockCenter

	Spectate.target = nil
	freeVel = Vector3.zero
	if hudGui then hudGui.Enabled = false end
end

-- Fed from the PuppetSync listener in CustomController.
function Spectate.NoteRemote(plr, packet)
	local info = remoteInfo[plr]
	if not info then
		info = { pitch = 0, crouched = false }
		remoteInfo[plr] = info
	end
	info.pitch = packet.LOOK_PITCH or info.pitch
	info.crouched = packet.CROUCHED or false
end

function Spectate.Update(dt)
	-- Self-managing: this runs every frame, alive or dead.
	if State.playerBody then
		if Spectate.active then Spectate.Stop() end
		return
	end
	if not Spectate.active then Spectate.Start() end

	camera.FieldOfView = (Config.spec_fov > 0) and Config.spec_fov or Config.fov

	-- Death cam: hold the last view for a beat before the observer takes over.
	if os.clock() < holdUntil then
		if holdCFrame then camera.CFrame = holdCFrame end
		updateHud()
		return
	end

	-- Console changes to spec_mode apply live.
	local wanted = math.clamp(math.floor(Config.spec_mode), 0, 2)
	if wanted ~= Spectate.mode then Spectate.SetMode(wanted) end
	if Spectate.mode == Spectate.MODE.FREE and not Config.spec_allowFreecam then
		Spectate.SetMode(Spectate.MODE.THIRD)
	end

	if Spectate.mode == Spectate.MODE.FREE then
		updateFreecam(dt)
		updateHud()
		return
	end

	-- Target still legal? spec_everyone flipping off mid-round drops you too.
	if Spectate.target and not isValidTarget(Spectate.target) then
		if Config.spec_cycleOnTargetLost then
			Spectate.Cycle(1)
		else
			Spectate.target = nil
		end
	end
	if not Spectate.target then Spectate.Cycle(1) end

	local puppet = Spectate.target and getPuppet(Spectate.target)
	if not puppet then
		-- Nobody to watch. Roam if we're allowed, otherwise freeze.
		if Config.spec_allowFreecam then
			Spectate.SetMode(Spectate.MODE.FREE)
			updateFreecam(dt)
		end
		updateHud()
		return
	end

	if Spectate.mode == Spectate.MODE.FIRST then
		updateFirstPerson(dt, puppet)
	else
		updateThirdPerson(dt, puppet)
	end

	updateHud()
end

--=====================================================================
-- INIT
--=====================================================================

function Spectate.Init()
	buildHud()

	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe or not Spectate.active then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			Spectate.Cycle(1)
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			Spectate.Cycle(-1)
		elseif input.KeyCode == Enum.KeyCode.Space then
			Spectate.CycleMode()
		end
	end)

	UserInputService.InputChanged:Connect(function(input, gpe)
		if gpe or not Spectate.active then return end
		if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
		if Spectate.mode ~= Spectate.MODE.FREE then return end

		local step = Config.spec_freecamScrollStep
		freeSpeed = math.clamp(
			freeSpeed * ((input.Position.Z > 0) and step or (1 / step)),
			Config.spec_freecamMinSpeed, Config.spec_freecamMaxSpeed)
	end)

	Players.PlayerRemoving:Connect(function(plr)
		remoteInfo[plr] = nil
		if Spectate.target == plr then Spectate.Cycle(1) end
		refreshCastFilter()
	end)
	Players.PlayerAdded:Connect(refreshCastFilter)
end

return Spectate