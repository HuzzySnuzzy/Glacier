-- Script: GunGame
-- Parent: ServerScriptService  (sibling of Glacier1, NOT inside it)
--
-- The game loop. Owns progression, the ladder, round cycling and respawn
-- policy. Owns no bodies, no spawn points and no weapons -- all of that is
-- the engine's, reached through the Glacier library.
--
-- SPAWNING IS A FUNCTION CALL, not a fired bindable. Glacier.Respawn resolves
-- a spawn point, destroys the old body, builds a new one and returns after it
-- exists. That is why there is no verify-poll, no retry loop and no arming
-- delay in this file any more -- the old spawnplayer:Fire() was
-- fire-and-forget, so every one of those existed to guess at completion.

local Players           = game:GetService("Players")
local Teams             = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local G      = require(ReplicatedStorage:WaitForChild("Glacier"))
local Config = G.Config

--==========================================================
-- Teams
--==========================================================
-- Find-or-create so a script restart in Studio doesn't stack duplicate teams,
-- which would break Team.Name -> spawn tag resolution. AutoAssignable is off
-- on both: this script owns team placement, and Roblox's own auto-assign would
-- put people on Spectator at random.
local function ensureTeam(name, color)
	local team = Teams:FindFirstChild(name)
	if not team then
		team = Instance.new("Team")
		team.Name = name
		team.TeamColor = color
		team.Parent = Teams
	end
	team.AutoAssignable = false
	return team
end

local team_FFA       = ensureTeam("FFA",       BrickColor.new("Bright orange"))
local team_Spectator = ensureTeam("Spectator", BrickColor.new("Medium stone grey"))

--==========================================================
-- Remotes
--==========================================================
-- Engine signals come through G.On. Everything below is game-specific -- the
-- join UI, the GT tuners, the loadout override -- and stays this script's
-- business, resolved through G.Remote so a missing one names itself instead
-- of hanging on an untimed WaitForChild.
local fx_Death              = G.Remote("fx_Death")
local giveloadout           = G.Remote("GiveLoadout")
local ClearLoadoutOverrides = G.Remote("ClearLoadoutOverrides")

local setPlayerSpawnReq       = G.Remote("setPlayerSpawnReq")
local setPlayerDefaultLoadout = G.Remote("setPlayerDefaultLoadout")
local setPlayerGGLevel        = G.Remote("setPlayerGGLevel")
local ShowJoinUI              = G.Remote("ShowJoinUI")
local RequestSpawn            = G.Remote("RequestSpawn")

--==========================================================
-- Tunables
--==========================================================
local RESPAWN_TIME       = 5      -- seconds from death until the player may spawn again
local SHOW_UI_ON_RESPAWN = false  -- true = must re-press JOIN after each death

local INSTANT_UPGRADE = true   -- hand the next gun over mid-life, CS-style, rather than on respawn
local SUICIDE_DEMOTES = false  -- true = killing yourself costs a level
local KNIFE_DEMOTES   = false  -- true = being knifed costs the victim a level

local VERBOSE = false          -- per-kill and per-hit server logging

-- The engine respawns everyone when the map changes, because for most modes a
-- map change means every body is standing in deleted geometry. This mode
-- reloads the map as part of starting a round and deploys everyone itself a
-- moment later, so it opts out and keeps that ordering to itself. Without
-- this it still happens to work -- wipeAllBodies runs first, so there is
-- nobody alive to respawn -- but relying on that is relying on an accident.
G.Set("mp_respawn_on_mapchange", false)

--==========================================================
-- Match cycle
--==========================================================
-- Win -> hold the scene for WIN_FREEZE_TIME (winner still standing, bodies
-- intact, scoreboard moment) -> wipe every rawbody -> reload the map -> reset
-- the ladder and redeploy everyone. Then it loops.
local WIN_FREEZE_TIME   = 5   -- seconds between the winning kill and the body wipe
local WIN_RESPAWN_DELAY = 1   -- seconds between the wipe and the map reload
local WIN_SOUND_ID      = nil -- set to an asset id to play a fanfare on win

-- The map load is async and MapServer reports no completion, so this is a
-- guess. Replace with an await the moment MapServer exposes one -- until then
-- a slow load means players deploy into a half-built map.
local MAP_LOAD_DELAY    = 5

-- Slow motion on the winning kill. These are REAL seconds -- task.delay is
-- unaffected by host_timescale, so WIN_FREEZE_TIME stays 5s of wall clock
-- regardless of the ramp. At 0.25 that's ~1.6s of game time, which is the
-- point: the freeze feels long because the world crawls through it.
local WIN_SLOWMO       = true
local WIN_SLOWMO_SCALE = 0.25  -- target timescale
local WIN_SLOWMO_IN    = 0.8   -- seconds to ease down
local WIN_SLOWMO_HOLD  = 3.0   -- seconds at full slow-mo before easing back
local WIN_SLOWMO_OUT   = 1.0   -- seconds to ease back to 1

--==========================================================
-- Sounds
--==========================================================
local SND_LEVEL_UP = 8535725487
local SND_HIT      = 137166459647708

--==========================================================
-- Bot toggles
--==========================================================
-- Killing a bot progresses the killer. Off = bots are free target practice
-- with no ladder movement, which is what you want while testing weapon feel.
local BOT_KILLS_AWARD = true

-- Bots hold their own gun game level and climb it by killing. Off = bots stay
-- on BOT_FIXED_LEVEL forever and never win the match.
local BOTS_PROGRESS   = false
local BOT_FIXED_LEVEL = 1

-- Bots can trigger endMatch when they clear the ladder. Almost always keep
-- this off -- losing a match to a bot is a bad time.
local BOTS_CAN_WIN    = false

--==========================================================
-- Progression
--==========================================================
local GunGameWeaponCycle = {
	[1] = { primary = "ak47",      secondary = "Non", melee = "Knife" },
	[2] = { primary = "M4A1",      secondary = "Non", melee = "Knife" },
	[3] = { primary = "negev",     secondary = "Non", melee = "Knife" },
	[4] = { primary = "USP",       secondary = "Non", melee = "Knife" },
	[5] = { primary = "glock",     secondary = "Non", melee = "Knife" },
	[6] = { primary = "hellock",   secondary = "Non", melee = "Knife" },
	[7] = { primary = "flintlock", secondary = "Non", melee = "Knife" },
}

local MAX_LEVEL = #GunGameWeaponCycle

--==========================================================
-- State
--==========================================================
local joined    = {}  -- [Player] = true once PlayerJoined has fired (client engine live)
local pending   = {}  -- [Player] = true while a spawn is in flight
local deadUntil = {}  -- [Player] = os.clock() timestamp before which respawn is refused

-- Two distinct gates, previously conflated into one `matchOver` flag:
--   matchOver   the ladder has been cleared; a winner exists
--   deploying   the world is being torn down and rebuilt; nobody may spawn
-- The old code cleared matchOver BEFORE the map load, so for six seconds the
-- spawn watcher happily dropped players into a map that was being replaced.
local matchOver = false
local deploying = false

-- Incremented every time a new round starts. Any deferred work (death respawn
-- timers, slow-mo ramps) captures the value it was scheduled under and aborts
-- if it no longer matches. Without this, a death timer armed one second before
-- the winning kill fires during the intermission and spawns a lone player into
-- an otherwise empty map.
local roundId = 1

-- Bot levels, keyed by name rather than instance. Deliberately a strong table
-- keyed by a stable string: a weak instance-keyed table loses the level the
-- moment a bot's body is destroyed on death, which is exactly when we need it
-- to survive. Cleared explicitly in resetLadder.
local botLevels = {}

local function log(...)
	if VERBOSE then print("[Gungame]", ...) end
end

--==========================================================
-- Entity identity
--==========================================================
-- G.Identify replaces the local copy, which carried two bugs: it matched
-- "^(%d+)RawBody$" without the -? (Studio UserIds are negative, so in Studio
-- every player was classed a bot and nobody climbed the ladder), and it never
-- checked the PARENT name, so an attacker arriving as a Puppet -- which is how
-- Health fires -- also fell through to bot.

local function entityKey(entity, kind)
	if kind == "player" then return entity end
	return entity.Name
end

local function isSameEntity(a, aKind, b, bKind)
	if not a or not b then return false end
	if aKind ~= bKind then return false end
	return entityKey(a, aKind) == entityKey(b, bKind)
end

local function playSoundAt(entity, kind, soundId)
	if not soundId then return end
	local pos = G.PositionOf(entity, kind)
	if pos then G.SoundAt(pos, soundId) end
end

--==========================================================
-- Level accessors (entity-generic)
--==========================================================
local function getLevel(entity, kind)
	if kind == "player" then
		local GT = entity:FindFirstChild("GT")
		local lv = GT and GT:FindFirstChild("gg_Level")
		if lv and lv.Value >= 1 then return lv.Value end
		return 1
	end

	if not BOTS_PROGRESS then return BOT_FIXED_LEVEL end
	return botLevels[entity.Name] or 1
end

local function setLevel(entity, kind, value)
	value = math.clamp(value, 1, MAX_LEVEL)

	if kind == "player" then
		setPlayerGGLevel:Fire(entity, value)
		return
	end

	if not BOTS_PROGRESS then return end
	botLevels[entity.Name] = value
end

local function loadoutFor(entity, kind)
	return GunGameWeaponCycle[math.clamp(getLevel(entity, kind), 1, MAX_LEVEL)]
end

-- Mirror the active loadout into GT's weapon_* values so anything reading the
-- config sees the truth. This only writes strings -- it does not arm anyone.
-- Bots have no GT, so this is a no-op for them.
local function syncLoadoutToGT(entity, kind, loadout)
	if kind ~= "player" then return end
	setPlayerDefaultLoadout:Fire(entity, loadout.primary, loadout.secondary, loadout.melee)
end

-- Hand a loadout to a live entity.
local function armEntity(entity, kind, loadout)
	-- A console override is in force. Handing the ladder weapon back here is
	-- what makes `primary negev` appear to work and then silently revert one
	-- kill later.
	if kind == "player" and Config.Get("sv_lockLoadout") then return end

	if kind == "player" then
		if not G.RawBody(entity) then return end
		-- Direct call rather than the bindable: this returns ok, reason, so a
		-- failure surfaces here instead of vanishing into a fired event.
		local ok, reason = G.GiveLoadout(entity, loadout)
		if not ok then warn(("[Gungame] arming %s failed: %s"):format(entity.Name, tostring(reason))) end
		return
	end

	-- Bots do NOT go through GiveLoadout. Lifecycle's pushInventory calls
	-- InventorySync:FireClient(entity), which throws on a Model. If your bot
	-- layer grows a loadout path, route it from here.
	if entity.Parent == nil then return end
end

-- Gun game is free-for-all, so everyone shares one team and therefore one
-- spawn pool (spawn_FFA). Kept as a function rather than inlined so a
-- team-based mode only has to change this one body.
local function assignTeam(player)
	player.Team = team_FFA
end

--==========================================================
-- Spawn
--==========================================================
local function doSpawn(player)
	if pending[player] then return false end
	if matchOver or deploying then
		-- Drop the latch on the way out. Leaving it high means the next
		-- legitimate request is not a rising edge, and before this was a
		-- direct call that was the end of the player's session -- they could
		-- never spawn again, with the request flag stuck reading "true".
		setPlayerSpawnReq:Fire(player, false)
		return false
	end
	pending[player] = true

	local myRound = roundId
	local loadout = loadoutFor(player, "player")
	syncLoadoutToGT(player, "player", loadout)

	-- Team must be set before this point: GetSpawnPoint refuses a Neutral
	-- player by design, and silently assigning one here would hide the
	-- ordering bug rather than fix it. Last-ditch guard for paths that forget.
	if not player.Team then
		warn(("[Gungame] %s is Neutral at spawn time; assigning"):format(player.Name))
		assignTeam(player)
	end

	-- One call. Resolves a spawn point, tears down the old body, builds the
	-- new one, and returns AFTER it exists -- so there is nothing to poll for
	-- and nothing to retry. A refusal comes back with the spawn system's own
	-- reason ("unassigned (Neutral)", "no spawn points tagged...") rather than
	-- being flattened into a generic failure.
	local ok, reason = G.Respawn(player)

	pending[player] = nil

	if not ok then
		warn(("[Gungame] spawn refused for %s: %s"):format(player.Name, tostring(reason)))
		-- Drop the latch: leaving it high means the next legitimate request
		-- isn't a rising edge and the watcher ignores it.
		setPlayerSpawnReq:Fire(player, false)
		ShowJoinUI:FireClient(player, true)
		return false
	end

	-- Respawn yields on the avatar fetch, so the round can turn over mid-call.
	if roundId ~= myRound then return false end
	if player.Parent ~= Players then return false end

	-- Re-read the level: the player may have been promoted during the spawn
	-- window by a kill queued from a previous life.
	armEntity(player, "player", loadoutFor(player, "player"))

	ShowJoinUI:FireClient(player, false)
	setPlayerSpawnReq:Fire(player, false)
	return true
end

--==========================================================
-- Match cycle
--==========================================================
local function resetLadder()
	for _, p in ipairs(Players:GetPlayers()) do
		setPlayerGGLevel:Fire(p, 1)
	end
	table.clear(botLevels)
end

-- Bot bodies are left alone -- the bot layer owns their lifecycle and wiping
-- them here would orphan whatever state it holds.
local function wipeAllBodies()
	for _, p in ipairs(Players:GetPlayers()) do
		-- G.Unload, not body:Destroy(). A raw destroy skips clearInventory and
		-- clearServerState, so every player carried a server-side inventory
		-- and stale WeaponServer lag-compensation history across the round
		-- boundary. Death was already covered by Health.Killed; the round wipe
		-- was not.
		G.Unload(p)

		deadUntil[p] = nil
		-- Drop the latch low so the redeploy below is a clean rising edge.
		setPlayerSpawnReq:Fire(p, false)
	end
end

-- Routed through the spawn_Requested latch rather than calling doSpawn
-- directly, so there is exactly one spawn path in the whole script.
-- Forward-declared: deployAll below calls it and it is defined with the rest
-- of the spawn-request handling, a couple of hundred lines further down.
-- Declared ONCE here and assigned there with `function`, not `local function`
-- -- a second `local` would shadow this one and every call above it would
-- quietly find nil.
local serviceSpawnRequest

local function deployAll()
	for _, p in ipairs(Players:GetPlayers()) do
		if joined[p] and not G.RawBody(p) then
			assignTeam(p)
			setPlayerSpawnReq:Fire(p, true)
			-- Serviced directly, not left to the flag's Changed. If a
			-- player's flag were already high the raise above would be a
			-- true-to-true write, which fires nothing -- and this is the
			-- round-start path, so that player would sit out the entire
			-- round with a flag that reads "requested".
			serviceSpawnRequest(p)
		end
	end
end

local function startNewRound()
	roundId += 1
	local myRound = roundId

	-- Stays closed across the whole rebuild. The old code cleared matchOver
	-- here, six seconds before deployAll, leaving a window where the watcher
	-- would spawn someone into a map mid-replacement.
	deploying = true

	G.SetTimescale(1, 0)

	-- A leftover override from last round would survive the ladder reset and
	-- leave one player armed with whatever they typed.
	ClearLoadoutOverrides:Fire()

	local ok, mapOrReason = G.LoadMap()   -- nil = mp_startmap
	if not ok then
		warn(("[Gungame] map load failed: %s"):format(tostring(mapOrReason)))
	end
	task.wait(MAP_LOAD_DELAY)

	if roundId ~= myRound then return end   -- something cycled us mid-load

	resetLadder()

	matchOver = false
	deploying = false
	deployAll()

	print(("[Gungame] round %d started on %s"):format(roundId, tostring(mapOrReason)))
end

local function endMatch(winner, winnerKind)
	if matchOver then return end
	if winnerKind == "bot" and not BOTS_CAN_WIN then return end

	matchOver = true
	print(("[Gungame] %s wins the match"):format(winner.Name))
	playSoundAt(winner, winnerKind, WIN_SOUND_ID)

	local myRound = roundId

	if WIN_SLOWMO then
		G.SetTimescale(WIN_SLOWMO_SCALE, WIN_SLOWMO_IN)

		task.delay(WIN_SLOWMO_IN + WIN_SLOWMO_HOLD, function()
			-- Stale check: if the round already cycled, startNewRound has
			-- restored the timescale and this ramp would drag it back down.
			if roundId ~= myRound then return end
			G.SetTimescale(1, WIN_SLOWMO_OUT)
		end)
	end

	task.delay(WIN_FREEZE_TIME, function()
		if roundId ~= myRound then return end

		wipeAllBodies()

		task.delay(WIN_RESPAWN_DELAY, function()
			if roundId ~= myRound then return end
			-- Spawned as its own thread: startNewRound yields across the map
			-- load, and yielding inside a task.delay callback would block the
			-- scheduler slot for the whole duration.
			task.spawn(startNewRound)
		end)
	end)
end

--==========================================================
-- Progression on kill
--==========================================================
local function awardKill(attacker, attackerKind)
	-- A bot with progression disabled has nothing to advance, so bail before
	-- we burn a match-ending check on it.
	if attackerKind == "bot" and not BOTS_PROGRESS then return end

	local level = getLevel(attacker, attackerKind)

	if level >= MAX_LEVEL then
		-- A kill on the final rung (the knife level) wins it.
		endMatch(attacker, attackerKind)
		return
	end

	local newLevel = level + 1
	setLevel(attacker, attackerKind, newLevel)

	local loadout = GunGameWeaponCycle[newLevel]
	syncLoadoutToGT(attacker, attackerKind, loadout)

	-- Hand the upgrade over immediately if they're still alive; otherwise the
	-- next spawn picks it up from the stored level.
	if INSTANT_UPGRADE then
		armEntity(attacker, attackerKind, loadout)
	end

	playSoundAt(attacker, attackerKind, SND_LEVEL_UP)
end

--==========================================================
-- spawn_Requested watcher
--==========================================================
-- Creating the flag through the tuner (rather than reaching into GT directly)
-- keeps object creation in one place. Firing false also guarantees GT and the
-- BoolValue exist before we try to connect to them.
-- Everything the rising edge used to do, as a CALL. It has to be a call and
-- not just a handler, because the edge is not reliable in either direction:
--
--   attachSpawnWatcher yields twice on WaitForChild before it connects, and
--   in Studio the client can press JOIN inside that window. The flag goes
--   true with nothing listening and the request is gone.
--
--   Setting a BoolValue to true when it is ALREADY true fires no Changed at
--   all. doSpawn's early return on matchOver/deploying leaves the flag high,
--   so from then on every request is a no-op and the player never spawns
--   again. That is the "sometimes" in "sometimes my player doesn't spawn".
--
-- Idempotent by design: every reason to refuse is checked here, so calling it
-- when there is nothing to do costs a few comparisons.
function serviceSpawnRequest(player)
	if player.Parent ~= Players then return end
	if G.RawBody(player) then return end         -- already alive
	if pending[player] then return end

	if matchOver or deploying then
		-- Intermission. Drop the latch rather than leaving it high: the flag
		-- means "outstanding and actionable", and a high one that nothing
		-- will act on is worse than no flag at all -- the next raise is not a
		-- change, so it fires nothing. deployAll re-raises and services this
		-- directly when the round starts.
		setPlayerSpawnReq:Fire(player, false)
		return
	end

	local until_ = deadUntil[player]
	if until_ and os.clock() < until_ then
		-- Respawn timer still running. Drop the latch and let the death
		-- handler re-raise it when the timer expires.
		setPlayerSpawnReq:Fire(player, false)
		return
	end

	assignTeam(player)
	-- doSpawn yields, and Changed handlers run on the signal's thread.
	task.spawn(doSpawn, player)
end

local function attachSpawnWatcher(player)
	-- Read any request that arrived BEFORE we got here, and read it before the
	-- reset below wipes it. Firing false is what creates GT and the BoolValue
	-- in the first place, so it cannot simply be moved -- but it also erases a
	-- JOIN that landed while the player was still being set up, which is the
	-- earliest of the three windows this function has to survive.
	local existingGT = player:FindFirstChild("GT")
	local existingFlag = existingGT and existingGT:FindFirstChild("spawn_Requested")
	local requestedEarly = (existingFlag ~= nil) and existingFlag.Value == true

	setPlayerSpawnReq:Fire(player, false)
	setPlayerGGLevel:Fire(player, 1)

	local GT = player:WaitForChild("GT", 5)
	if not GT then warn("[Gungame] no GT for " .. player.Name) return end
	local flag = GT:WaitForChild("spawn_Requested", 5)
	if not flag then warn("[Gungame] no spawn_Requested for " .. player.Name) return end

	flag.Changed:Connect(function(value)
		if not value then return end                 -- only act on the rising edge
		serviceSpawnRequest(player)
	end)

	-- Requests that happened before there was anything to hear them: one from
	-- before this function ran at all, one from during its two WaitForChilds.
	-- In Studio those windows are most of the gap between pressing Play and
	-- the first click, which is why this only failed "sometimes".
	if requestedEarly or flag.Value then
		setPlayerSpawnReq:Fire(player, true)
		serviceSpawnRequest(player)
	end
end

--==========================================================
-- Join
--==========================================================
G.On("PlayerJoined", function(plr)
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then return end

	joined[plr] = true
	attachSpawnWatcher(plr)

	-- Client engine is up by the time this fires, so the UI remote will land.
	ShowJoinUI:FireClient(plr, true)
end)

-- Client pressed JOIN. The remote carries no data -- we only use it as a
-- signal, then validate server-side and set the authoritative flag ourselves.
RequestSpawn.OnServerEvent:Connect(function(player)
	-- Recorded FIRST, and unconditionally. A JOIN can arrive before the join
	-- handler has finished setting the player up, and the old code answered
	-- that by returning -- dropping the request with nothing to retry it.
	-- Written down instead, so attachSpawnWatcher finds it when it attaches.
	setPlayerSpawnReq:Fire(player, true)
	if not joined[player] then return end

	-- Raised AND serviced directly. The flag is the authoritative state other
	-- code reads; the direct call is what makes the request actually happen,
	-- because a true-to-true write fires no Changed and would otherwise leave
	-- the player stuck forever.
	serviceSpawnRequest(player)
end)

Players.PlayerRemoving:Connect(function(player)
	joined[player]    = nil
	pending[player]   = nil
	deadUntil[player] = nil
end)

--==========================================================
-- Death / respawn
--==========================================================
G.On("PlayerKilled", function(victim, attacker, group, isBot)
	local victimEntity, victimKind = G.Identify(victim)
	local killerEntity, killerKind = G.Identify(attacker)

	-- Trust the event's flag over our own inference when it's present: the
	-- weapon layer knows what it spawned, we're only pattern-matching names.
	if isBot then victimKind = "bot" end
	if not victimEntity then return end

	log("killed", victimEntity, "by", attacker, group)

	--------------------------------------------------
	-- Progression
	--------------------------------------------------
	local selfKill = isSameEntity(killerEntity, killerKind, victimEntity, victimKind)
	local awardable = killerEntity and not selfKill
		and (victimKind ~= "bot" or BOT_KILLS_AWARD)

	if awardable then
		if KNIFE_DEMOTES and getLevel(killerEntity, killerKind) == MAX_LEVEL then
			setLevel(victimEntity, victimKind, getLevel(victimEntity, victimKind) - 1)
		end
		awardKill(killerEntity, killerKind)
	elseif selfKill and SUICIDE_DEMOTES then
		setLevel(victimEntity, victimKind, getLevel(victimEntity, victimKind) - 1)
	end

	--------------------------------------------------
	-- Teardown
	--------------------------------------------------
	-- Bot bodies and respawning are owned by the bot layer, so we stop here.
	if victimKind == "bot" then return end

	local player = victimEntity

	-- Lifecycle already cleared the inventory and fired DIED when Health
	-- reported the kill; this only removes the corpse.
	G.Unload(player)

	fx_Death:FireClient(player)
	player.Team = team_Spectator

	deadUntil[player] = os.clock() + RESPAWN_TIME

	-- Captured now, checked on expiry. If the round cycles inside the respawn
	-- window this callback is stale and startNewRound has already redeployed
	-- this player.
	local myRound = roundId

	task.delay(RESPAWN_TIME, function()
		-- Liveness check first: assigning a Team on a player who has already
		-- left throws, and every line below it is wasted work.
		if player.Parent ~= Players then return end
		if roundId ~= myRound then return end
		if matchOver or deploying then return end

		assignTeam(player)

		deadUntil[player] = nil
		if G.RawBody(player) then return end

		if SHOW_UI_ON_RESPAWN then
			ShowJoinUI:FireClient(player, true)
		else
			setPlayerSpawnReq:Fire(player, true)
		end
	end)
end)

G.On("Damaged", function(model, damage, attacker, group, armorDamage)
	log("damage", model, damage, group, armorDamage)

	-- Positional hit sound at the ATTACKER's location, matching the original
	-- behaviour. Swap to G.Identify(model) if you meant the victim.
	local attackerEntity, attackerKind = G.Identify(attacker)
	playSoundAt(attackerEntity, attackerKind, SND_HIT)
end)

print("[Gungame] loaded")