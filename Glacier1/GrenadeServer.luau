-- Script: GrenadeServer
-- Parent: Glacier1
--
-- WHERE A GRENADE ACTUALLY WENT.
--
-- The model -- the throw, the bounce, the fuse, the blast, the flash -- is in
-- ReplicatedStorage.GrenadeDefs and is shared with the client, which predicts
-- the same throw to draw an arc you can aim with. Two implementations of a
-- throw is two throws, and the one you practised would not be the one you get.
--
-- WHAT LIVES HERE is everything that needs the world: the sweep that finds
-- what it bounced off, the trace that decides whether a wall was between the
-- bang and a victim, and the damage. A client that could tell the server
-- where its grenade landed could land one inside somebody's head.
--
-- The projectile is a real part so everyone can see it, but nothing is
-- simulated BY the part: it is anchored and moved by CFrame, exactly as the
-- vehicles and the player body are, because two solvers on one object is the
-- fight rather than the fix.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Config       = require(ReplicatedStorage:WaitForChild("Config"))
local Glacier      = require(ReplicatedStorage:WaitForChild("Glacier"))
local GrenadeDefs  = require(ReplicatedStorage:WaitForChild("GrenadeDefs"))
local Registry     = require(script.Parent:WaitForChild("Registry"))
local Health       = require(script.Parent:WaitForChild("Health"))

local FCVAR = Config.FCVAR
local SERVER = FCVAR.REPLICATED
local SERVER_CHEAT = FCVAR.REPLICATED + FCVAR.CHEAT

local function num(v, fallback)
	local n = tonumber(v)
	return n or fallback
end

--=====================================================================
-- REMOTES AND FOLDERS
--=====================================================================

local function ensureRemote(name)
	local remote = ReplicatedStorage:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = ReplicatedStorage
	end
	return remote
end

-- Unreliable: a flash is a thing that happens now or not at all, and a
-- retransmitted one arriving after the white has faded is worse than a
-- dropped one.
local Flashed = ReplicatedStorage:FindFirstChild("Flashed")
if not Flashed then
	Flashed = Instance.new("UnreliableRemoteEvent")
	Flashed.Name = "Flashed"
	Flashed.Parent = ReplicatedStorage
end

local NadeEvent = ensureRemote("NadeEvent")

local folder = workspace:FindFirstChild("Grenades")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "Grenades"
	folder.Parent = workspace
end

--=====================================================================
-- THE PROJECTILE
--=====================================================================

local live = {}     -- [part] = { def, owner, velocity, bornAt, fuseAt, ... }
local liveCount = 0

local function buildBody(def)
	local part = Instance.new("Part")
	part.Name = def.kind
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(0.9, 0.9, 0.9)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Color = (def.kind == "flashbang" and Color3.fromRGB(210, 210, 215))
		or (def.kind == "smokegrenade" and Color3.fromRGB(120, 130, 140))
		or Color3.fromRGB(70, 80, 60)
	part:SetAttribute("Grenade", def.kind)
	part.Parent = folder
	return part
end

-- Everything the cast must not see: the thrower's own body, every other
-- grenade, and the drops. A grenade that bounced off its own owner would
-- come straight back at them.
local function castParams(owner)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local ignore = { folder }
	local drops = workspace:FindFirstChild("WeaponDrops")
	if drops then table.insert(ignore, drops) end

	local body = Glacier.RawBody(owner)
	if body then table.insert(ignore, body) end

	params.FilterDescendantsInstances = ignore
	-- A decorative non-colliding part is not something a grenade bounces off,
	-- the same rule the movement casts use.
	pcall(function() params.RespectCanCollide = true end)
	return params
end

--=====================================================================
-- DETONATION
--=====================================================================

-- Who is who, from the bang's point of view. The only thing the damage model
-- needs to know about a victim.
local function relationOf(owner, victim)
	if victim == owner then return "self" end
	if typeof(owner) == "Instance" and owner:IsA("Player")
		and typeof(victim) == "Instance" and victim:IsA("Player")
		and owner.Team and victim.Team and owner.Team == victim.Team then
		return "team"
	end
	return "enemy"
end

-- Is there something solid between the bang and them? The caller of
-- GrenadeDefs owns this, because GrenadeDefs does not have a world.
local function blockedBetween(from, to, owner)
	local params = castParams(owner)
	local delta = to - from
	local distance = delta.Magnitude
	if distance < 1e-3 then return false end

	local hit = workspace:Raycast(from, delta, params)
	-- Short of them by a margin: the cast is aimed at a body it has been told
	-- to ignore, so anything it finds at all is between.
	return hit ~= nil and hit.Distance < distance - 1
end

local function detonate(part, entry)
	local def = entry.def
	local at = part.Position

	NadeEvent:FireAllClients("detonate", def.kind, at)

	for _, plr in ipairs(Players:GetPlayers()) do
		local position = Glacier.PositionOf(plr, "player")
		if position and Glacier.IsAlive(plr) then
			local distance = (position - at).Magnitude
			local blocked = blockedBetween(at, position, entry.owner)

			-- THE BLAST.
			if (def.damage or 0) > 0 then
				local damage = GrenadeDefs.BlastDamage(def, distance, blocked,
					relationOf(entry.owner, plr), Config.mp_friendlyfire == true)

				if damage > 0 then
					local puppet = Glacier.PuppetOf(plr)
					if puppet then
						Health.Damage(puppet, damage, {
							attacker = entry.owner,
							hitPart = "Torso",
							cause = def.kind,
						})
					end
				end
			end

			-- THE FLASH, which is about where they are LOOKING and is the
			-- one thing here the server cannot work out on its own: the view
			-- direction lives on the client. Published to the puppet as the
			-- rest of the aim already is, so this reads it rather than
			-- inventing a second channel for it.
			if (def.flashMax or 0) > 0 then
				local puppet = Glacier.PuppetOf(plr)
				local look = puppet and puppet:GetPivot().LookVector
				local seconds = look and GrenadeDefs.FlashDuration(def, distance,
					look, at - position, blocked) or 0

				if seconds > 0 then
					Flashed:FireClient(plr, seconds, def.kind)
				end
			end
		end
	end

	-- THE SMOKE outlives the grenade that made it, so the cloud is its own
	-- entity rather than the projectile hanging around invisible. Published
	-- as attributes: a client draws it without a remote, and anything that
	-- wants to ask whether a line is blocked can read the same numbers.
	if (def.smokeRadius or 0) > 0 then
		part.Anchored = true
		part.Transparency = 1
		part:SetAttribute("Smoke", true)
		part:SetAttribute("SmokeRadius", def.smokeRadius)
		part:SetAttribute("SmokeTime", def.smokeTime)
		part:SetAttribute("SmokeBloom", def.smokeBloom)
		part:SetAttribute("SmokeStarted", workspace:GetServerTimeNow())
		Debris:AddItem(part, def.smokeTime + 1)
	else
		part:Destroy()
	end

	live[part] = nil
	liveCount -= 1
end

--=====================================================================
-- THE STEP
--=====================================================================

local accumulator = 0

local function step(dt)
	local gravity = num(Config.sv_nade_gravity, 0)
	if gravity <= 0 then gravity = num(Config.sv_gravity, 72.7) end

	local now = os.clock()
	local maxLife = num(Config.sv_nade_maxlife, 20)

	for part, entry in pairs(live) do
		if not part.Parent then
			live[part] = nil
			liveCount -= 1
		elseif now >= entry.fuseAt or now - entry.bornAt > maxLife then
			detonate(part, entry)
		else
			local velocity = entry.velocity

			if not entry.resting then
				velocity += Vector3.new(0, -gravity * dt, 0)

				local displacement = velocity * dt
				local hit = workspace:Raycast(part.Position, displacement, entry.params)

				if hit then
					-- Landed ON the surface rather than in it, and the
					-- remainder of the step is spent going wherever the
					-- bounce sent it. A grenade that used the whole step
					-- twice would gain speed on every bounce.
					local travelled = math.max(hit.Distance - 0.1, 0)
					local direction = displacement.Magnitude > 1e-6
						and displacement.Unit or Vector3.yAxis
					part.Position = part.Position + direction * travelled

					local out, resting = GrenadeDefs.Bounce(entry.def, velocity, hit.Normal)
					velocity = out
					entry.resting = resting

					if not resting then
						NadeEvent:FireAllClients("bounce", entry.def.kind, part.Position)
					end
				else
					part.Position = part.Position + displacement
				end
			end

			entry.velocity = velocity
		end
	end
end

RunService.Heartbeat:Connect(function(deltaTime)
	local hz = math.max(num(Config.sv_nade_hz, 60), 1)
	local fixed = 1 / hz

	-- Fixed steps, capped: a hitch must not teleport a grenade through a
	-- wall, and must not spend a second of frames catching up either.
	accumulator = math.min(accumulator + deltaTime, fixed * 8)
	while accumulator >= fixed do
		step(fixed)
		accumulator -= fixed
	end
end)

--=====================================================================
-- THROWING
--=====================================================================

-- Returns ok, reason.
local function throw(plr, kind, style)
	if not Config.sv_nades then return false, "grenades are disabled (sv_nades 0)" end
	if not Glacier.IsAlive(plr) then return false, "you're not alive" end

	local def = GrenadeDefs.Get(kind)
	if not def then return false, ("there is no such grenade as '%s'"):format(tostring(kind)) end

	local limit = num(Config.sv_nade_maxlive, 24)
	if limit > 0 and liveCount >= limit then
		return false, "too many grenades in the air"
	end

	-- FROM THE EYE, along the AIM. The puppet's pivot is re-CFramed from the
	-- client every frame and faces where the player is actually looking; the
	-- RawBody is not, which is why a drop keyed off it flies out sideways.
	local puppet = Glacier.PuppetOf(plr)
	if not puppet then return false, "you have no body" end

	local pivot = puppet:GetPivot()
	local look = pivot.LookVector
	local origin = pivot.Position + look * 1.6 + Vector3.new(0, 1.2, 0)

	local def_ = def
	local velocity = GrenadeDefs.ThrowVelocity(def_, look, style, nil)

	local part = buildBody(def_)
	part.Position = origin

	local now = os.clock()
	live[part] = {
		def = def_,
		owner = plr,
		velocity = velocity,
		bornAt = now,
		fuseAt = now + num(def_.fuse, 1.6),
		params = castParams(plr),
		resting = false,
	}
	liveCount += 1

	NadeEvent:FireAllClients("throw", def_.kind, origin, velocity)
	return true, def_.kind
end

--=====================================================================
-- API
--=====================================================================
-- What the grenade ITEMS call. A grenade is an item whose OnUse throws it, so
-- everything about carrying one -- the slot, the cooldown, the animation, the
-- fact that it is consumed -- is the item system's job and none of it is
-- restated here.
Registry.Grenades = {
	Throw = throw,
	Live = function() return liveCount end,

	Clear = function()
		for part in pairs(live) do part:Destroy() end
		live = {}
		liveCount = 0
	end,
}

--=====================================================================
-- CONSOLE
--=====================================================================

Config.Command("nade_throw", {
	args = { "string", "string?" },
	flag = SERVER_CHEAT,
	help = "throw a grenade without carrying one -- nade_throw flashbang lob",
	run = function(ctx, kind, style)
		local plr = ctx and ctx.player
		if not plr then return false, "nade_throw needs a player" end

		local ok, why = throw(plr, kind, style)
		if not ok then return false, why end
		ctx.reply(("threw a %s"):format(why))
	end,
})

Config.Command("nade_list", {
	args = {},
	flag = SERVER,
	help = "the grenades this engine knows about",
	run = function(ctx)
		local lines = { ("%d in the air"):format(liveCount) }
		for _, kind in ipairs(GrenadeDefs.List()) do
			local def = GrenadeDefs.Get(kind)
			table.insert(lines, ("  %-14s fuse %.1fs  damage %d  radius %d")
				:format(kind, def.fuse, def.damage, math.max(def.radius, def.smokeRadius)))
		end
		ctx.reply(table.concat(lines, "\n"))
	end,
})

Config.Command("nade_clear", {
	args = {},
	flag = SERVER_CHEAT,
	help = "remove every grenade in the air",
	run = function(ctx)
		local was = liveCount
		Registry.Grenades.Clear()
		ctx.reply(("cleared %d"):format(was))
	end,
})
