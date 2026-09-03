-- Script: SpawnPointServer
-- child of Glacier1
--
-- Owns spawn point selection for every gamemode. Spawn parts are tagged
-- "spawn_<TeamName>" and live inside the map model, so they arrive and leave
-- with the map -- there is no registration step and no per-map table here.
--
-- REFUSAL IS A VALID RESULT. A player with no team (Neutral) is unassigned and
-- has no business in the world yet, so this returns nil rather than picking
-- something. Callers must set the team FIRST, then ask.
--
-- Exposes two BindableFunctions rather than events: the caller needs a value
-- back, and a BindableEvent is fire-and-forget with no return channel.
-- Otherwise identical -- server-to-server only, never crosses the network.

local Players           = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local TAG_PREFIX = "spawn_"
local ANY_TAG    = "spawn_any"

-- Teams that are states, not sides. Asking for a spawn on one of these is a
-- caller bug, so it's warned about rather than silently satisfied.
local NO_SPAWN_TEAMS = {
	Spectator = true,
	Unassigned = true,
}

--=====================================================================
-- Part preparation
--=====================================================================
-- Spawn markers are authored as visible bricks so you can see them while
-- building. Stripping them here means the map ships one way and plays another.
-- CanQuery = false keeps them out of Blockcast sweeps; AudioCanCollide = false
-- stops them occluding the Advanced Audio API.

local function prepare(part)
	if not part:IsA("BasePart") then return end
	if not Config.Get("sv_spawnHideParts") then return end

	part.Anchored     = true
	part.CanCollide   = false
	part.CanQuery     = false
	part.CanTouch     = false
	part.Transparency = 1
	part.CastShadow   = false
	pcall(function() part.AudioCanCollide = false end)
end

-- Tags are added to the template in ReplicatedStorage, so GetInstanceAddedSignal
-- fires for the clone the instant MapServer parents it into workspace.
local function watchTag(tag)
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do prepare(inst) end
	CollectionService:GetInstanceAddedSignal(tag):Connect(prepare)
end

--=====================================================================
-- Candidate gathering
--=====================================================================

local lastUsed = {}   -- [tag] = part; feeds sv_spawnAvoidRepeat

local function gather(tag)
	local out = {}
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		-- Descendant check, not a parent check: the template copies still
		-- carry the tag while they sit in ReplicatedStorage.
		if inst:IsA("BasePart") and inst:IsDescendantOf(workspace) then
			table.insert(out, inst)
		end
	end
	return out
end

-- Occupancy is tested against live rawbodies. Bots are picked up too if their
-- models are tagged "GlacierBody" -- if your bot layer doesn't tag them, they
-- simply don't block a spawn, which is cosmetic rather than a correctness issue.
local function occupiedPositions()
	local out = {}

	for _, plr in ipairs(Players:GetPlayers()) do
		local body = workspace:FindFirstChild(plr.UserId .. "RawBody")
		if body then
			-- The Puppet, where there is one. The RawBody's CFrame is written
			-- client-side by Physics and never replicates, so on the server it
			-- reads as the spawn point for the whole round -- which made every
			-- live player look like they were standing on their own spawn.
			local puppet = body:FindFirstChild("Puppet")
			local target = (puppet and puppet.PrimaryPart) and puppet or body
			local ok, pivot = pcall(function() return target:GetPivot() end)
			if ok then table.insert(out, pivot.Position) end
		end
	end

	for _, inst in ipairs(CollectionService:GetTagged("GlacierBody")) do
		if inst:IsDescendantOf(workspace) then
			local ok, pivot = pcall(function() return inst:GetPivot() end)
			if ok then table.insert(out, pivot.Position) end
		end
	end

	return out
end

local function isClear(part, occupied, radius)
	local r2 = radius * radius
	for _, pos in ipairs(occupied) do
		if (pos - part.Position).Magnitude ^ 2 < r2 then return false end
	end
	return true
end

--=====================================================================
-- Selection
--=====================================================================

local function pick(candidates, tag)
	if #candidates == 0 then return nil end
	if #candidates == 1 then return candidates[1] end

	local radius   = Config.Get("sv_spawnClearRadius") or 0
	local occupied = occupiedPositions()

	local clear = {}
	if radius > 0 then
		for _, part in ipairs(candidates) do
			if isClear(part, occupied, radius) then table.insert(clear, part) end
		end
	end

	-- Every point blocked (small map, full server) -> fall back to the whole
	-- set. Spawning on top of someone beats refusing to spawn.
	local pool = (#clear > 0) and clear or candidates

	if Config.Get("sv_spawnAvoidRepeat") and #pool > 1 then
		local previous = lastUsed[tag]
		if previous then
			local filtered = {}
			for _, part in ipairs(pool) do
				if part ~= previous then table.insert(filtered, part) end
			end
			if #filtered > 0 then pool = filtered end
		end
	end

	local chosen = pool[math.random(1, #pool)]
	lastUsed[tag] = chosen
	return chosen
end

--=====================================================================
-- CFrame construction
--=====================================================================
-- Yaw only. A spawn part rotated to sit flush on a ramp would otherwise hand
-- the player a pitched camera on the frame they take control.

local function toSpawnCFrame(part)
	local look = part.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)

	-- Part pointing straight up or down: no usable yaw, so default to -Z.
	if flat.Magnitude < 1e-4 then flat = Vector3.new(0, 0, -1) else flat = flat.Unit end

	local origin = part.Position + Vector3.new(0, Config.Get("sv_spawnHeight") or 0, 0)
	return CFrame.lookAt(origin, origin + flat)
end

--=====================================================================
-- Team resolution
--=====================================================================
-- Returns: teamName | nil, refusalReason
--
-- The override exists so a gamemode can ask for a T spawn before it has
-- actually moved the player onto T, and so bots (which have no Team) can be
-- placed at all. It cannot rescue a Neutral player who was never given one --
-- that's a caller ordering bug and should surface as such.

local function resolveTeamName(entity, override)
	if type(override) == "string" and override ~= "" then
		if NO_SPAWN_TEAMS[override] then
			return nil, ("'%s' is a stateless team and has no spawns"):format(override)
		end
		return override
	end

	if typeof(entity) ~= "Instance" then
		return nil, "no entity and no team override"
	end

	if entity:IsA("Player") then
		local team = entity.Team
		if not team then
			return nil, ("%s is unassigned (Neutral); set a team before requesting a spawn")
				:format(entity.Name)
		end
		if NO_SPAWN_TEAMS[team.Name] then
			return nil, ("%s is on %s, which has no spawns"):format(entity.Name, team.Name)
		end
		return team.Name
	end

	-- A bot model carries no Team, so the caller has to say which side it's on.
	return nil, ("%s has no team; pass a team name override"):format(entity.Name)
end

--=====================================================================
-- Public API
--=====================================================================

-- Invoke(entity, teamNameOverride) -> CFrame, part   on success
--                                 -> nil, nil, reason on refusal
local function getSpawnPoint(entity, override)
	local teamName, reason = resolveTeamName(entity, override)
	if not teamName then
		warn("[Spawns] " .. tostring(reason))
		return nil, nil, reason
	end

	-- Exact team first, then the shared pool. spawn_any is legitimate because
	-- it is authored as shared; a CT spawn is not, so it is never borrowed.
	for _, tag in ipairs({ TAG_PREFIX .. teamName, ANY_TAG }) do
		local part = pick(gather(tag), tag)
		if part then
			if Config.Get("sv_spawnDebug") then
				print(("[Spawns] %s -> %s (%s)"):format(
					tostring(entity and entity.Name or teamName), part:GetFullName(), tag))
			end
			return toSpawnCFrame(part), part
		end
	end

	-- Non-strict is a map-testing affordance only. It will happily drop a CT
	-- into a T spawn, so leave sv_spawnStrict on in anything resembling a game.
	if not Config.Get("sv_spawnStrict") then
		local everything = {}
		for _, tag in ipairs(CollectionService:GetAllTags()) do
			if string.sub(tag, 1, #TAG_PREFIX) == TAG_PREFIX then
				for _, part in ipairs(gather(tag)) do table.insert(everything, part) end
			end
		end

		local part = pick(everything, "__loose")
		if part then
			warn(("[Spawns] no '%s' spawn; borrowing %s (sv_spawnStrict 0)")
				:format(teamName, part:GetFullName()))
			return toSpawnCFrame(part), part
		end
	end

	local why = ("no spawn points tagged '%s%s' or '%s' in the loaded map")
		:format(TAG_PREFIX, teamName, ANY_TAG)
	warn("[Spawns] " .. why)
	return nil, nil, why
end

local GetSpawnPoint = Instance.new("BindableFunction")
GetSpawnPoint.Name = "GetSpawnPoint"
GetSpawnPoint.OnInvoke = getSpawnPoint
GetSpawnPoint.Parent = ReplicatedStorage

-- Invoke(teamName) -> count. Lets a gamemode check a map is playable at round
-- start instead of discovering it one failed spawn at a time.
local HasSpawnPoints = Instance.new("BindableFunction")
HasSpawnPoints.Name = "HasSpawnPoints"
HasSpawnPoints.OnInvoke = function(teamName)
	if type(teamName) ~= "string" or NO_SPAWN_TEAMS[teamName] then return 0 end
	return #gather(TAG_PREFIX .. teamName) + #gather(ANY_TAG)
end
HasSpawnPoints.Parent = ReplicatedStorage

--=====================================================================
-- Tag watchers
--=====================================================================

for _, tag in ipairs(CollectionService:GetAllTags()) do
	if string.sub(tag, 1, #TAG_PREFIX) == TAG_PREFIX then watchTag(tag) end
end

for _, teamName in ipairs({ "FFA", "CT", "T" }) do
	watchTag(TAG_PREFIX .. teamName)
end
watchTag(ANY_TAG)

--=====================================================================
-- Console
--=====================================================================

Config.Command("spawns", {
	args = {},
	flag = Config.FCVAR.REPLICATED,
	help = "list tagged spawn points in the loaded map",
	run = function(ctx)
		local lines, total = {}, 0
		for _, tag in ipairs(CollectionService:GetAllTags()) do
			if string.sub(tag, 1, #TAG_PREFIX) == TAG_PREFIX then
				local n = #gather(tag)
				if n > 0 then
					table.insert(lines, ("  %-16s %d"):format(tag, n))
					total += n
				end
			end
		end
		table.sort(lines)

		-- ctx.reply, not print: print lands in the server log, and this is
		-- exactly the command you run when a respawn just refused.
		ctx.reply(total > 0
			and (("%d spawn points:\n"):format(total) .. table.concat(lines, "\n"))
			or "no spawn points in workspace -- is a map loaded?")
	end,
})