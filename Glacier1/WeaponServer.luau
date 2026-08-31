-- Script: WeaponServer
-- Parent: Glacier1 (so script.Parent.Health and script.Parent.Registry resolve)
--
-- Lag-compensated authoritative hit registration.
--
-- Every player's body is anchored and driven client-side, so the server's copy
-- is stale by a variable amount. Raycasting against live server parts tests
-- geometry that is nowhere near where the shooter actually saw it. Instead the
-- server keeps a short history of everyone's transform and resolves each shot
-- against where things were at the moment the client fired. Rather than
-- physically rewinding parts (expensive, and it corrupts state if anything
-- else reads position mid-rewind) it intersects the ray against recorded
-- hitbox transforms directly.
--
-- World geometry is static, so it is raycast normally and only used to decide
-- whether a player hit was occluded.
--
-- AUTHORITY MODEL FOR AIM:
-- The client sends BASE view angles -- pure mouse input, recoil punch NOT
-- included -- plus a shotId. The server runs the same Recoil module against
-- its OWN recoil state and its own seeded spread to rebuild the direction.
-- Nothing the client says about where the bullet went is trusted, and a
-- modified client cannot zero its own cone: the spread seed is derived from a
-- per-life salt the server minted.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris            = game:GetService("Debris")

local Config   = require(ReplicatedStorage:WaitForChild("Config"))
local Recoil   = require(ReplicatedStorage:WaitForChild("Recoil"))
local Health   = require(script.Parent:WaitForChild("Health"))
local Registry = require(script.Parent:WaitForChild("Registry"))

--=====================================================================
-- REMOTES
--=====================================================================

local function ensureRemote(name, class)
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then return existing end
	local remote = Instance.new(class or "RemoteEvent")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local FireWeapon   = ensureRemote("FireWeapon")
local ReloadWeapon = ensureRemote("ReloadWeapon")
local RecoilSync   = ensureRemote("RecoilSync")
local BulletFX     = ensureRemote("BulletFX", "UnreliableRemoteEvent")

-- Created by the main server script; we piggyback on it for history.
local PuppetSync = ReplicatedStorage:WaitForChild("PuppetSync", 30)

--=====================================================================
-- TUNING
--=====================================================================

local HISTORY_SECONDS  = 1.0   -- how far back we can rewind
local MAX_REWIND       = 0.5   -- clamp: beyond this a client is lying or unplayable
local MAX_ORIGIN_DRIFT = 12    -- studs between claimed eye and rewound position
local RATE_TOLERANCE   = 0.85  -- jitter allowance on fire interval

-- Hitboxes, as offsets from the puppet's PrimaryPart (R6 HumanoidRootPart,
-- which sits at torso centre). Tune these against your actual rig.
local HITBOX_BODY = { offset = Vector3.new(0, -2.5, 0), size = Vector3.new(2.2, 4.0, 1.6) }
local HITBOX_HEAD = { offset = Vector3.new(0,  0.0, 0), size = Vector3.new(1.2, 1.2, 1.2) }

-- Crouched players are shorter. The client tells us its stance; if it lies it
-- only makes itself easier or harder to hit consistently, not selectively.
local CROUCH_SCALE_Y = 0.6

local rng = Random.new()

--=====================================================================
-- CVAR CACHE
--=====================================================================

-- Rebuilding the Cfg per bullet at 600 RPM across ten players is pure waste,
-- but a stale cache would silently desync the server from clients after a cvar
-- change, so it is invalidated rather than merely refreshed on a timer.
local recoilCfg = nil
local function getCfg()
	if not recoilCfg then
		recoilCfg = Recoil.readCfg(Config)
	end
	return recoilCfg
end

if type(Config.OnChange) == "function" then
	for _, name in ipairs({
		"weapon_recoil_scale", "weapon_recoil_variance", "weapon_recoil_cooldown",
		"weapon_recoil_reset_rate", "weapon_recoil_decay_exp", "weapon_recoil_decay_lin",
		"weapon_accuracy_delay", "weapon_recoil_view_punch_extra", "weapon_recoil_view_ratio",
		}) do
		pcall(Config.OnChange, name, function()
			recoilCfg = nil
		end)
	end
end

--=====================================================================
-- SESSIONS + POSITION HISTORY
--=====================================================================

local history  = {}   -- [player] = { {t, cf, crouched, grounded}, ... } oldest first
local sessions = {}

local function newSession()
	return {
		lastFire  = -1e9,
		reloadEnd = -1e9,
		ammo      = {},
		recoil    = Recoil.newState(),
		salt      = rng:NextInteger(1, 2147483646),
	}
end

local function record(p, cf, crouched, grounded)
	local h = history[p]
	if not h then return end

	local now = workspace:GetServerTimeNow()
	table.insert(h, { t = now, cf = cf, crouched = crouched, grounded = grounded })

	while #h > 1 and now - h[1].t > HISTORY_SECONDS do
		table.remove(h, 1)
	end
end

-- Transform at a past instant, interpolated between the two bracketing
-- samples. Returns nil if we have no history at all for this player.
local function sampleAt(p, t)
	local h = history[p]
	if not h or #h == 0 then return nil end

	if t >= h[#h].t then
		return h[#h].cf, h[#h].crouched, h[#h].grounded
	end
	if t <= h[1].t then
		return h[1].cf, h[1].crouched, h[1].grounded
	end

	for i = 1, #h - 1 do
		local a, b = h[i], h[i + 1]
		if t >= a.t and t <= b.t then
			local span = b.t - a.t
			local alpha = span > 0 and (t - a.t) / span or 0
			local near = (alpha < 0.5) and a or b
			return a.cf:Lerp(b.cf, alpha), near.crouched, near.grounded
		end
	end

	return h[#h].cf, h[#h].crouched, h[#h].grounded
end

-- Horizontal speed in studs/sec around a past instant. Derived from history
-- rather than trusting the client, because movement inaccuracy is the largest
-- term in the cone and a client that claims to be standing still while running
-- would otherwise get free accuracy.
local function speedAt(p, t)
	local h = history[p]
	if not h or #h < 2 then return 0 end

	local a, b = h[#h - 1], h[#h]
	for i = 1, #h - 1 do
		if t >= h[i].t and t <= h[i + 1].t then
			a, b = h[i], h[i + 1]
			break
		end
	end

	local dt = b.t - a.t
	if dt <= 0 then return 0 end
	local d = b.cf.Position - a.cf.Position
	return Vector3.new(d.X, 0, d.Z).Magnitude / dt
end

if PuppetSync then
	PuppetSync.OnServerEvent:Connect(function(p, packet)
		if type(packet) ~= "table" then return end
		if typeof(packet.CFRAME) ~= "CFrame" then return end
		record(p, packet.CFRAME, packet.CROUCHED == true, packet.GROUNDED ~= false)
	end)
else
	warn("[WeaponServer] PuppetSync missing -- no lag compensation history.")
end

Players.PlayerAdded:Connect(function(p)
	history[p] = {}
	sessions[p] = newSession()
end)

Players.PlayerRemoving:Connect(function(p)
	history[p] = nil
	sessions[p] = nil
end)

--=====================================================================
-- RECOIL SYNC
--=====================================================================

local function syncRecoil(p, includeSalt)
	local session = sessions[p]
	if not session then return end
	RecoilSync:FireClient(p, {
		salt   = includeSalt and session.salt or nil,
		index  = session.recoil.indexAtFire,
		shotId = session.recoil.shotId,
	})
end

-- Client-pull. A broadcast on PlayerAdded fires before the client's listener
-- exists, so the client asks and we answer.
RecoilSync.OnServerEvent:Connect(function(p)
	local session = sessions[p]
	if not session then return end
	RecoilSync:FireClient(p, { salt = session.salt })
end)

-- Push on spawn as well, so a respawn re-arms the client without it polling.
task.spawn(function()
	while not (Registry.Lifecycle and Registry.Lifecycle.Spawned) do task.wait() end
	Registry.Lifecycle.Spawned:Connect(function(p)
		local session = sessions[p]
		if not session then return end
		Recoil.reset(session.recoil, workspace:GetServerTimeNow())
		session.ammo = {}
		syncRecoil(p, true)
	end)
end)

--=====================================================================
-- RAY VS ORIENTED BOX
--=====================================================================

-- Slab method in the box's local space. Returns the distance along the ray to
-- the entry point, or nil if there's no intersection in front of the origin.
local function rayVsOBB(origin, dir, boxCF, boxSize)
	local localOrigin = boxCF:PointToObjectSpace(origin)
	local localDir = boxCF:VectorToObjectSpace(dir)
	local half = boxSize * 0.5

	local tMin, tMax = -math.huge, math.huge

	local o = { localOrigin.X, localOrigin.Y, localOrigin.Z }
	local d = { localDir.X, localDir.Y, localDir.Z }
	local e = { half.X, half.Y, half.Z }

	for i = 1, 3 do
		if math.abs(d[i]) < 1e-8 then
			-- Ray is parallel to this slab: miss unless already inside it.
			if o[i] < -e[i] or o[i] > e[i] then return nil end
		else
			local t1 = (-e[i] - o[i]) / d[i]
			local t2 = ( e[i] - o[i]) / d[i]
			if t1 > t2 then t1, t2 = t2, t1 end
			if t1 > tMin then tMin = t1 end
			if t2 < tMax then tMax = t2 end
			if tMin > tMax then return nil end
		end
	end

	if tMax < 0 then return nil end
	return (tMin >= 0) and tMin or 0
end

--=====================================================================
-- HELPERS
--=====================================================================

local statsCache = {}

local function statsFor(name)
	if name == nil then return nil end
	local cached = statsCache[name]
	if cached ~= nil then return cached or nil end

	local folder = ReplicatedStorage:FindFirstChild("Weapons")
	local mod = folder and folder:FindFirstChild(name)
	if not (mod and mod:IsA("ModuleScript")) then
		statsCache[name] = false
		return nil
	end

	local ok, s = pcall(require, mod)
	local result = (ok and type(s) == "table") and s or false
	statsCache[name] = result
	return result or nil
end

local function bodyOf(p)
	return workspace:FindFirstChild(p.UserId .. "RawBody")
end

local function humanoidOf(p)
	local body = bodyOf(p)
	local puppet = body and body:FindFirstChild("Puppet")
	return puppet and puppet:FindFirstChildOfClass("Humanoid")
end

local function boxesFor(cf, crouched)
	local scale = crouched and CROUCH_SCALE_Y or 1

	local bodySize = Vector3.new(
		HITBOX_BODY.size.X,
		HITBOX_BODY.size.Y * scale,
		HITBOX_BODY.size.Z
	)
	local bodyCF = cf * CFrame.new(HITBOX_BODY.offset * Vector3.new(1, scale, 1))
	local headCF = cf * CFrame.new(HITBOX_HEAD.offset * Vector3.new(1, scale, 1))

	return bodyCF, bodySize, headCF, HITBOX_HEAD.size
end

-- Bots and test dummies aren't in the history system: they're server-owned, so
-- their live position IS correct. Raycast handles them.
local function humanoidFromPart(part)
	local node = part.Parent
	while node and node ~= workspace do
		if node:IsA("Model") then
			local hum = node:FindFirstChildOfClass("Humanoid")
			if hum then return hum, node end
		end
		node = node.Parent
	end
	return nil, nil
end

--=====================================================================
-- DEBUG HITBOXES
--=====================================================================

-- Cvar-gated and called INLINE from the fire handler, after the gates pass.
-- The old version was a second OnServerEvent connection, so it drew boxes for
-- shots the real handler had already rejected -- which reads as a hitreg bug
-- when it isn't one.
local function showBox(cf, size, colour)
	local part = Instance.new("Part")
	part.Anchored, part.CanCollide, part.CanQuery = true, false, false
	part.Transparency = 0.7
	part.Color = colour
	part.Size = size
	part.CFrame = cf
	part.Parent = workspace
	Debris:AddItem(part, 2)
end

local function debugRewind(shooter, shotTime)
	if not Config.Values.sv_lagcomp_debug then return end
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= shooter then
			local cf, crouched = sampleAt(other, shotTime)
			if cf then
				local bodyCF, bodySize, headCF, headSize = boxesFor(cf, crouched)
				showBox(bodyCF, bodySize, Color3.fromRGB(80, 160, 255))
				showBox(headCF, headSize, Color3.fromRGB(255, 80, 80))
			end
		end
	end
end

--=====================================================================
-- FIRE
--=====================================================================

FireWeapon.OnServerEvent:Connect(function(p, packet)
	if type(packet) ~= "table" then return end
	if typeof(packet.origin) ~= "Vector3" then return end

	local yaw, pitch = tonumber(packet.yaw), tonumber(packet.pitch)
	if not (yaw and pitch) then return end
	if pitch < -90 or pitch > 90 then return end
	if yaw ~= yaw or pitch ~= pitch then return end   -- NaN

	local session = sessions[p]
	if not session then return end

	local s = statsFor(packet.weapon)
	if not s then return end
	if not (s.recoil and s.accuracy) then
		warn(("[WeaponServer] '%s' has no recoil/accuracy block."):format(tostring(packet.weapon)))
		return
	end

	local st = session.recoil
	local serverNow = workspace:GetServerTimeNow()

	-- A rejected shot leaves the client one pattern step and one seed ahead.
	-- Without the correction every remaining bullet in the magazine rolls a
	-- different cone than we do, and tracers stop matching hits.
	local function reject()
		syncRecoil(p, false)
	end

	-- ---- rate limit ----
	-- Server clock throughout, never os.clock(): wall time drifts from
	-- gameTime under host_timescale and desyncs the limiter from the recoil.
	local interval = 60 / math.max(s.fireRate or 600, 1)
	if serverNow - session.lastFire < interval * RATE_TOLERANCE then
		return reject()
	end
	session.lastFire = serverNow

	-- ---- ammo ----
	local ammo = session.ammo[packet.weapon]
	if ammo == nil then ammo = s.magSize or 0 end
	if ammo <= 0 then return reject() end
	session.ammo[packet.weapon] = ammo - 1

	-- ---- rewind time ----
	local shotTime = math.clamp(tonumber(packet.time) or serverNow,
		serverNow - MAX_REWIND, serverNow)

	-- ---- origin sanity, against the shooter's own rewound position ----
	local ownCF, ownCrouched, ownGrounded = sampleAt(p, shotTime)
	if ownCF then
		local drift = (packet.origin - ownCF.Position).Magnitude
		if drift > MAX_ORIGIN_DRIFT then
			-- Not warning: at high ping this fires legitimately and the log
			-- noise buries real problems. Count it instead if you want.
			return reject()
		end
	end

	-- ---- rebuild the shot direction ourselves ----
	-- Recoil advances only AFTER the rate and ammo gates, so a rejected shot
	-- never consumes a pattern index.
	if packet.shotId ~= st.shotId then
		reject()   -- correct, but still resolve this shot with our own state
	end

	local cfg   = getCfg()
	local seed  = Recoil.shotSeed(session.salt, st.shotId)
	local punch = Recoil.fire(st, serverNow, s, cfg, seed)

	local aimCF = Recoil.aimCFrame(packet.origin, yaw, pitch, punch)
	local inacc = Recoil.inaccuracy(st, s,
		speedAt(p, shotTime), ownGrounded ~= false, ownCrouched == true)
	local dir   = Recoil.spreadDirection(aimCF, inacc, seed)

	debugRewind(p, shotTime)

	local range = s.range or 500

	-- ---- world geometry (static, no rewind needed) ----
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude = { workspace:FindFirstChild("BulletFX") }
	for _, other in ipairs(Players:GetPlayers()) do
		local b = bodyOf(other)
		if b then table.insert(exclude, b) end
	end
	params.FilterDescendantsInstances = exclude

	local worldHit = workspace:Raycast(packet.origin, dir * range, params)
	local bestDist = worldHit and worldHit.Distance or range

	local bestModel, bestPart, bestPos = nil, nil, nil

	-- A server-owned dummy is at its true position already, so a world hit on
	-- one is a legitimate hit.
	if worldHit then
		local hum, model = humanoidFromPart(worldHit.Instance)
		if hum and hum.Health > 0 then
			bestModel = model
			bestPart  = worldHit.Instance.Name
			bestPos   = worldHit.Position
		end
	end

	-- ---- rewound players ----
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= p then
			local cf, crouched = sampleAt(other, shotTime)
			local hum = cf and humanoidOf(other)

			if hum and hum.Health > 0 then
				local bodyCF, bodySize, headCF, headSize = boxesFor(cf, crouched)

				-- Head first: it's inside the body box, so testing it second
				-- would always lose the distance comparison.
				local tHead = rayVsOBB(packet.origin, dir, headCF, headSize)
				local tBody = rayVsOBB(packet.origin, dir, bodyCF, bodySize)

				local t, head
				if tHead and (not tBody or tHead <= tBody + 0.01) then
					t, head = tHead, true
				elseif tBody then
					t, head = tBody, false
				end

				if t and t < bestDist then
					bestDist  = t
					bestModel = hum.Parent
					bestPart  = head and "Head" or "Torso"
					bestPos   = packet.origin + dir * t
				end
			end
		end
	end

	-- ---- resolve ----
	local hitPos = bestPos
		or (worldHit and worldHit.Position)
		or (packet.origin + dir * range)
	local hitNormal = (worldHit and not bestPos) and worldHit.Normal or -dir
	local material  = (worldHit and not bestPos) and worldHit.Instance.Material or nil

	if bestModel then
		local dealt, killed, group = Health.Damage(bestModel, s.damage or 25, {
			hitPart  = bestPart,
			attacker = p,
			stats    = s,
			distance = bestDist,
		})

		if dealt > 0 then
			BulletFX:FireClient(p, {
				hitmarker = true,
				headshot  = group == "head",
				killed    = killed,
			})

			-- Resolved strictly AFTER damage: armour and helmet state must be
			-- final before the sound key is chosen.
			local SoundReceiver = ReplicatedStorage:FindFirstChild("SoundReceiver")
			if SoundReceiver and group == "head" then
				SoundReceiver:FireAllClients(bestPos, 122699784909910)
			end
		end
	end

	BulletFX:FireAllClients({
		shooter   = p,
		hitPos    = hitPos,
		hitNormal = hitNormal,
		material  = material,
		weapon    = packet.weapon,
	})
end)

--=====================================================================
-- RELOAD
--=====================================================================

ReloadWeapon.OnServerEvent:Connect(function(p, weaponName)
	local session = sessions[p]
	local s = statsFor(weaponName)
	if not (session and s) then return end

	-- Ignore repeat requests inside the reload window so a client can't refill
	-- by spamming R.
	local now = workspace:GetServerTimeNow()
	if now < (session.reloadEnd or -1e9) then return end
	session.reloadEnd = now + (s.reloadTime or 2)

	task.delay(s.reloadTime or 2, function()
		local live = sessions[p]
		if not live then return end
		live.ammo[weaponName] = s.magSize

		-- Fresh mag, fresh spray. Push the reset so the client re-enters the
		-- pattern at the same index we do.
		Recoil.reset(live.recoil, workspace:GetServerTimeNow())
		syncRecoil(p, false)
	end)
end)

--=====================================================================
-- REGISTRY API
--=====================================================================

local WeaponServer = {}

-- Called by PlayerLifecycleServer on unload. A stale history buffer means a
-- rewound shot can still hit where an unloaded player used to be.
function WeaponServer.ClearHistory(p)
	if history[p] then table.clear(history[p]) end
	local session = sessions[p]
	if session then
		Recoil.reset(session.recoil, workspace:GetServerTimeNow())
		session.ammo = {}
	end
end

function WeaponServer.ResetRecoil(p)
	local session = sessions[p]
	if not session then return end
	Recoil.reset(session.recoil, workspace:GetServerTimeNow())
	syncRecoil(p, false)
end

Registry.WeaponServer = WeaponServer

Config.Command("sv_recoil_status", {
	args = { "player" },
	flag = Config.FCVAR.CHEAT,
	help = "print a player's server-side recoil state",
	run = function(ctx, target)
		local session = sessions[target]
		if not session then return false end
		local st = session.recoil
		print(("[%s] shotId=%d index=%.2f (anchor %.2f) punch=(%.2f, %.2f)")
			:format(target.Name, st.shotId, st.index, st.indexAtFire, st.punch.X, st.punch.Y))
		return true
	end,
})