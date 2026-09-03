-- ModuleScript: Bullets  (client)
-- Sends shots to the server and renders everyone's tracers and impacts.
--
-- The client sends its BASE view angles (mouse only, no recoil punch) plus a
-- shotId. The server applies its own recoil punch and its own seeded spread to
-- rebuild the direction, then re-resolves the hit against rewound hitboxes.
-- Nothing the client says about where the bullet went is trusted.
--
-- Setup:
--   local Bullets = require(script.Bullets)
--   Bullets.onRecoilSync = Weapons.ApplyRecoilSync   -- before Init
--   Bullets.Init()

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris            = game:GetService("Debris")
local RunService        = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local State  = require(script.Parent.State)

local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera

local FireWeapon = ReplicatedStorage:WaitForChild("FireWeapon", 10)
local BulletFX   = ReplicatedStorage:WaitForChild("BulletFX", 10)
local RecoilSync = ReplicatedStorage:WaitForChild("RecoilSync", 10)
local Visuals = require(script.Parent:WaitForChild("Visuals"))
local WeaponRegistry = require(ReplicatedStorage:WaitForChild("WeaponRegistry"))

local function statsFor(name)
	return WeaponRegistry.Stats(name)
end

local Crosshair = require(script.Parent:WaitForChild("Crosshair"))

local Bullets = {}

-- Set by Player to Weapons.ApplyRecoilSync. A require would be circular:
-- Weapons already requires Bullets.
Bullets.onRecoilSync = nil

local fxFolder
local fadeConn

--=====================================================================
-- TRACER POOL
--=====================================================================

local POOL_SIZE = 24
local tracerPool = {}
local tracerBorn = {}    -- gameTime the tracer was fired
local tracerLife = {}    -- how long it should live
local poolIndex = 1

local function makeTracer()
	local p = Instance.new("Part")
	p.Name = "Tracer"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = Config.cl_tracerColor or Color3.fromRGB(255, 230, 150)
	p.Size = Vector3.new(0.05, 0.05, 1)
	p.Transparency = 1
	p.Parent = fxFolder
	return p
end

local function acquireTracer()
	local i = poolIndex
	poolIndex = (poolIndex % POOL_SIZE) + 1
	return tracerPool[i], i
end

-- One loop over the pool instead of a RenderStepped connection per shot.
-- The old per-shot connection kept fading a part after the pool had already
-- handed it to a newer bullet, so at high RPM tracers flickered out early.
-- Driven by gameTime, so tracer lifetimes scale with host_timescale.
local function fadeStep()
	local now = State.gameTime or 0
	for i = 1, POOL_SIZE do
		local born = tracerBorn[i]
		if born then
			local life = tracerLife[i] or 0.06
			local t = (now - born) / life
			local p = tracerPool[i]
			if t >= 1 then
				p.Transparency = 1
				tracerBorn[i] = nil
			else
				p.Transparency = 0.3 + 0.7 * t
			end
		end
	end
end

--=====================================================================
-- MUZZLE
--=====================================================================

-- Tracers originate from the gun, not the eye. The shot itself comes from the
-- eye (that is where the crosshair points), so the two disagree slightly at
-- close range -- which is correct and what every shooter does.
local function muzzleOf(model)
	if not model then return nil end
	local weapon = model:FindFirstChild("LocalWeapon") or model:FindFirstChild("Holding")
	if not weapon then return nil end

	local att = weapon:FindFirstChild("MuzzleAttachment", true)
	if att and att:IsA("Attachment") then return att.WorldPosition end

	local handle = weapon.PrimaryPart
	return handle and handle.Position or nil
end

local function localMuzzle(fallback)
	return muzzleOf(State.viewmodel) or fallback
end

local function remoteMuzzle(shooter)
	local rawBody = workspace:FindFirstChild(shooter.UserId .. "RawBody")
	local puppet = rawBody and rawBody:FindFirstChild("Puppet")
	return muzzleOf(puppet) or (puppet and puppet.PrimaryPart and puppet.PrimaryPart.Position)
end

--=====================================================================
-- FX
--=====================================================================

local function drawTracer(from, to, stats)
	if Config.cl_tracers == false then return end
	if not from then return end

	local cfg = (stats and stats.tracer) or {}
	if (cfg.chance or 1) < 1 and math.random() > (cfg.chance or 1) then return end

	local delta = to - from
	local dist = delta.Magnitude
	if dist < 0.5 then return end

	local width = cfg.width or Config.cl_tracerWidth or 0.05

	local p, i = acquireTracer()
	p.Color = cfg.color or Config.cl_tracerColor or Color3.fromRGB(255, 230, 150)
	p.Size = Vector3.new(width, width, dist)
	p.CFrame = CFrame.lookAt(from + delta * 0.5, to)
	p.Transparency = 0.3

	tracerBorn[i] = State.gameTime or 0
	tracerLife[i] = cfg.life or Config.cl_tracerLife or 0.06
end

local function drawImpact(pos, normal, material, stats)
	if Config.cl_impactFX == false then return end

	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	p.Transparency = 1
	p.CFrame = CFrame.lookAt(pos + normal * 0.05, pos + normal)
	p.Parent = fxFolder

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Rate = 0
	emitter.Lifetime = NumberRange.new(0.25, 0.5)
	emitter.Speed = NumberRange.new(4, 9)
	emitter.SpreadAngle = Vector2.new(35, 35)
	emitter.Size = NumberSequence.new(0.25, 0)
	emitter.Color = ColorSequence.new(Color3.fromRGB(190, 180, 170))
	emitter.Parent = p

	local cfg = (stats and stats.impact) or {}
	emitter:Emit(cfg.particles or Config.cl_impactParticles or 8)

	-- Bullet hole. Decals accumulate, so cap the lifetime rather than letting
	-- a long match fill the map with them.
	if Config.cl_bulletHoles ~= false then
		local hole = Instance.new("Part")
		hole.Anchored = true
		hole.CanCollide = false
		hole.CanQuery = false
		hole.CanTouch = false
		hole.CastShadow = false
		hole.Size = Vector3.new(0.25, 0.25, 0.05)
		hole.Transparency = 1
		hole.CFrame = CFrame.lookAt(pos + normal * 0.02, pos + normal * 2)
		hole.Parent = fxFolder

		local decal = Instance.new("Decal")
		decal.Texture = Config.cl_bulletHoleTexture or "rbxassetid://5713307085"
		decal.Face = Enum.NormalId.Back
		decal.Parent = hole

		Debris:AddItem(hole, Config.cl_bulletHoleLife or 12)
	end

	Debris:AddItem(p, 1)
end

--=====================================================================
-- REMOTES
--=====================================================================

local statsCache = {}
local weaponNameIndex = nil

-- packet.weapon carries the module's lowercase `name` field ("ak47") while
-- the ModuleScript is "AK47", and FindFirstChild is case-sensitive. Missing
-- here doesn't just break animation lookup -- it silently drops the weapon's
-- own tracer colour, width, life and chance, and its impact particle count,
-- falling back to the Config defaults on every remote shot.
local function resolveWeaponInstance(name)
	local folder = ReplicatedStorage:FindFirstChild("Weapons")
	if not folder then return nil end

	local direct = folder:FindFirstChild(name)
	if direct and direct:IsA("ModuleScript") then return direct end

	if not weaponNameIndex then
		weaponNameIndex = {}
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("ModuleScript") then
				weaponNameIndex[m.Name:lower()] = m
			end
		end
	end

	local hit = weaponNameIndex[name:lower()]
	return (hit and hit.Parent) and hit or nil
end



local function onBulletFX(packet)
	if type(packet) ~= "table" then return end

	-- Server-confirmed hit. No shooter field on this packet.
	if packet.hitmarker then
		Crosshair.HitMarker()
		return
	end

	if not packet.shooter then return end
	if packet.shooter == plr then return end   -- we already drew our own

	local rawBody = workspace:FindFirstChild(packet.shooter.UserId .. "RawBody")
	local puppet  = rawBody and rawBody:FindFirstChild("Puppet")

	-- Fire animation rides this UNRELIABLE packet rather than AnimationSync.
	-- A 600 RPM weapon would push ten un-droppable packets per second per
	-- player through the reliable channel; a dropped one here costs a single
	-- missed muzzle flick, which is invisible at that rate.
	--
	-- Played before the hitPos guards below: a shot that hits nothing still
	-- needs the shooter's arms to move.
	if puppet then
		Visuals.PlayRemoteOneShot(puppet, "Fire", packet.weapon)
	end

	local stats = statsFor(packet.weapon)

	local from = remoteMuzzle(packet.shooter)
	if from and packet.hitPos then
		drawTracer(from, packet.hitPos, stats)
	end
	if packet.hitPos and packet.hitNormal then
		drawImpact(packet.hitPos, packet.hitNormal, packet.material, stats)
	end
end

local function onRecoilSync(packet)
	if type(Bullets.onRecoilSync) == "function" then
		pcall(Bullets.onRecoilSync, packet)
	end
end

--=====================================================================
-- PUBLIC
--=====================================================================

function Bullets.Init()
	if fxFolder then return end

	fxFolder = Instance.new("Folder")
	fxFolder.Name = "BulletFX"
	fxFolder.Parent = workspace

	for i = 1, POOL_SIZE do
		tracerPool[i] = makeTracer()
	end
	fadeConn = RunService.RenderStepped:Connect(fadeStep)

	if RecoilSync then
		RecoilSync.OnClientEvent:Connect(onRecoilSync)

		-- CLIENT-PULL, once, here -- not a server broadcast on PlayerAdded,
		-- which fires before this listener exists. Without the salt the player
		-- cannot shoot at all, so this is retried until it lands.
		task.spawn(function()
			for _ = 1, 20 do
				if State.recoilSalt then return end
				RecoilSync:FireServer()
				task.wait(0.5)
			end
			warn("[Bullets] never received a recoil salt from the server.")
		end)
	else
		warn("[Bullets] RecoilSync remote missing -- firing will be suppressed.")
	end

	if BulletFX then
		BulletFX.OnClientEvent:Connect(onBulletFX)
	else
		warn("[Bullets] BulletFX remote missing -- no FX will render.")
	end
end

function Bullets.Shutdown()
	if fadeConn then fadeConn:Disconnect() end
	fadeConn = nil
	if fxFolder then fxFolder:Destroy() end
	fxFolder = nil
	table.clear(tracerPool)
	table.clear(tracerBorn)
	table.clear(tracerLife)
	poolIndex = 1
end

-- Called from Weapons.fire.
--   origin    -- eye position (no viewbob)
--   direction -- locally predicted direction, tracer only
--   shotId    -- PRE-increment seed basis, must match what the server expects
--   yaw/pitch -- BASE view angles in degrees, recoil punch NOT included
function Bullets.Fire(stats, origin, direction, shotId, yaw, pitch)
	local range = (stats and stats.range) or 500

	-- Local prediction: raycast purely to pick a visual endpoint. The server
	-- decides the real one and it can legitimately differ under lag comp.
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = {
		State.playerBody, State.playerPuppet, State.viewmodel, cam, fxFolder,
	}
	params.FilterType = Enum.RaycastFilterType.Exclude

	local result = workspace:Raycast(origin, direction * range, params)
	local endPos = result and result.Position or (origin + direction * range)

	drawTracer(localMuzzle(origin), endPos, stats)
	if result then
		drawImpact(result.Position, result.Normal, result.Instance.Material, stats)
	end

	if FireWeapon then
		FireWeapon:FireServer({
			origin   = origin,
			yaw      = yaw,
			pitch    = pitch,
			shotId   = shotId,
			crouched = State.isCrouching == true,
			grounded = State.isGrounded ~= false,
			weapon   = stats and stats.name or nil,
			time     = workspace:GetServerTimeNow(),
		})
	end

	return result
end

return Bullets