-- Script: PlayerLifecycleServer
-- Parent: Glacier1 (so script.Parent.Health resolves)
--
-- Sole owner of RawBody creation and destruction. The client never destroys
-- its own body: it asks, the server does it, and replication removes the
-- instance everywhere. A client-side :Destroy() only unloads that one client's
-- copy, leaving the server convinced the body still exists -- which is what
-- made loadhere fail after unload.
--
-- TWO WAYS IN, deliberately separate:
--   Spawn(plr, cframe)   caller already knows where. No spawn-system lookup.
--   Respawn(plr, team)   asks SpawnPointServer where, then calls Spawn.
-- Keeping them apart means a gamemode that computed its own position never
-- pays for a tag scan, and a console user never has to know a coordinate.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Health = require(script.Parent:WaitForChild("Health"))
local Registry = require(script.Parent:WaitForChild("Registry"))
local Inventory = require(ReplicatedStorage:WaitForChild("Inventory"))

-- Cheat commands. Same list as the console gate in Glacier1 -- worth hoisting
-- into a shared module once there's a second copy of it.
local ADMIN_USER_IDS = {
	[32358526] = true,
}

--=====================================================================
-- REMOTES
--=====================================================================

-- Find-or-create, because Glacier1 also touches ConsoleLog and script start
-- order between the two isn't guaranteed. Two instances named "ConsoleLog"
-- would mean the client listens to one and the server fires the other.
local function ensureRemote(name, class)
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then return existing end
	local remote = Instance.new(class or "RemoteEvent")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local ConsoleLog    = ensureRemote("ConsoleLog")
local CreateBody    = ensureRemote("CreateBody")
local CreatePuppet  = ensureRemote("CreatePuppet")
local Lifecycle     = ensureRemote("PlayerLifecycle")
local InventorySync = ensureRemote("InventorySync")

--=====================================================================
-- CONFIG
--=====================================================================

local config = {
	useplravi = true,
}

local HIDE_BODY_AFTER = 5   -- seconds before the collision hull goes invisible

-- Remembered so a loadhere respawn keeps whatever model you last asked for.
local lastPreferredModel = {}   -- [Player] = string | nil

-- [Instance] = Player. Built at creation time rather than reverse-engineered
-- from the instance name -- Studio hands out negative UserIds, so "-2RawBody"
-- silently failed a "^(%d+)RawBody$" match and every death dropped on the floor.
local bodyOwner = setmetatable({}, { __mode = "k" })

-- Was an unconditional FireAllClients on every body hide and every puppet
-- creation. One respawn command spamming a full server made the console
-- unreadable, so it's behind a cvar now.
local function announce(message)
	if not Config.Values.sv_lifecycleDebug then return end
	ConsoleLog:FireAllClients(message, false)
end

--=====================================================================
-- INVENTORY  (server-authoritative)
--=====================================================================
-- The server owns what every player carries. The client keeps a mirror in
-- State for prediction -- ammo decrements land there instantly so the HUD
-- doesn't lag the trigger -- but the mirror is REPLACED wholesale from here,
-- never merged. Deltas are where duplication bugs live.

local DEFAULT_LOADOUT = {
	primary   = "Non",
	secondary = "Non",
	melee     = "Non",
}

-- Inventory operates on a plain table and touches no Instances, so the same
-- module the client uses runs unmodified here.
local inventories = {}   -- [Player] = { slots = {}, activeSlot = n }

local function inventoryFor(plr)
	local inv = inventories[plr]
	if not inv then
		inv = { slots = {}, activeSlot = Inventory.SLOT_PRIMARY }
		inventories[plr] = inv
	end
	return inv
end

local function pushInventory(plr)
	local inv = inventories[plr]
	if not inv then return end
	InventorySync:FireClient(plr, {
		slots      = Inventory.SerializeAll(inv),
		activeSlot = inv.activeSlot,
	})
end

local function clearInventory(plr)
	inventories[plr] = nil
	-- Empty push, so a client that just died or unloaded doesn't sit holding
	-- a rifle it no longer owns.
	InventorySync:FireClient(plr, { slots = {}, activeSlot = Inventory.SLOT_PRIMARY })
end

--=====================================================================
-- DEATH
--=====================================================================

-- Fires with the Player (not the model) so the gamemode doesn't have to
-- reverse-engineer ownership from the instance name.
local PlayerKilled  = ensureRemote("OnPlayerKilled",  "BindableEvent")
local PlayerSpawned = ensureRemote("OnPlayerSpawned", "BindableEvent")

local function playerFromModel(model)
	if not model then return nil end

	local direct = bodyOwner[model]
	if direct then return direct end

	-- Fallback for anything not registered (bots, dummies, hot-reload).
	-- Note the -? : Studio UserIds are negative.
	local rawBody = model.Parent
	if not rawBody then return nil end
	local id = tonumber(string.match(rawBody.Name, "^(%-?%d+)RawBody$"))
	return id and Players:GetPlayerByUserId(id) or nil
end

Health.Killed.Event:Connect(function(model, attacker, group)
	local victim = playerFromModel(model)
	local isBot = false
	-- No auto-revive. A round-based mode wants death to stick; deathmatch
	-- opts back in via mp_respawn. Reviving unconditionally here meant
	-- livingCount() could never reach zero and rounds never ended.
	if victim then
		clearInventory(victim)
		Lifecycle:FireClient(victim, "DIED")
		PlayerKilled:Fire(victim, attacker, group, isBot)
	else
		isBot = true
		PlayerKilled:Fire(model, attacker, group, isBot)
	end

	if Config.Values.mp_respawn then
		task.delay(Config.Values.mp_respawnDelay, function()
			if model.Parent then Health.Revive(model) end
		end)
	end
end)

--=====================================================================
-- BUILD
--=====================================================================

local function findRawBody(plr)
	return workspace:FindFirstChild(plr.UserId .. "RawBody")
end

local function createBody(plr, cframe)
	local template = ReplicatedStorage:WaitForChild("Body", 10)
	if not template then
		warn("[Lifecycle] ReplicatedStorage.Body missing.")
		return nil
	end

	local body = template:Clone()
	body.Name = plr.UserId .. "RawBody"
	body.Anchored = true
	-- Positioned before parenting so it never appears at origin for a frame.
	if typeof(cframe) == "CFrame" then
		body.CFrame = cframe
	end

	body.Parent = workspace
	bodyOwner[body] = plr

	task.delay(HIDE_BODY_AFTER, function()
		-- Guarded: an unload inside the window would otherwise poke a
		-- destroyed instance. A respawn also replaces the body, so the timer
		-- from the OLD body must not touch the new one -- it holds a direct
		-- reference rather than looking the body up by name, which is what
		-- makes that safe.
		if body.Parent then
			body.Transparency = 1
			announce(plr.Name .. " Visibility of RawBody is now hidden. (Glacier)")
		end
	end)

	return body
end

local function createPuppet(plr, preferredModel)
	local plrbody = findRawBody(plr)
	if not plrbody then
		warn("[Lifecycle] createPuppet with no RawBody for", plr.Name)
		return nil
	end

	-- Idempotent: a repeated request must not stack puppets.
	local existing = plrbody:FindFirstChild("Puppet")
	if existing then existing:Destroy() end

	local Puppet

	if preferredModel then
		local obj = ReplicatedStorage:FindFirstChild(preferredModel)
		if not obj then
			warn("[Lifecycle]", preferredModel, "doesn't exist in ReplicatedStorage")
			return nil
		end
		Puppet = obj:Clone()

		for _, v in ipairs(Puppet:GetDescendants()) do
			if v:IsA("BasePart") then
				v.CanCollide = false
				v.CanQuery = false
				v.CanTouch = false
				v.Massless = true
				v.Anchored = true   -- stops gravity dragging the puppet down
				v.AudioCanCollide = false
			end
		end
	else
		-- Cloned here rather than unconditionally at the top: the old order
		-- cloned R6Rig and then threw it away whenever preferredModel was set.
		Puppet = ReplicatedStorage.R6Rig:Clone()
	end

	Puppet.Name = "Puppet"
	Puppet.Archivable = true
	Puppet.Parent = plrbody
	bodyOwner[Puppet] = plr   -- Health fires with the Puppet, not the RawBody

	-- Seat it on the hull so it isn't at origin until the first PuppetSync.
	if Puppet.PrimaryPart and plrbody:IsA("BasePart") then
		Puppet:PivotTo(plrbody.CFrame)
	end

	local hum = Puppet:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.EvaluateStateMachine = false
		hum.RequiresNeck = false
		hum.DisplayName = plr.DisplayName
	end

	Health.Setup(Puppet)

	local animateScript = Puppet:FindFirstChild("Animate")
	if animateScript then animateScript:Destroy() end   -- default R6 idle/walk would override yours

	if not preferredModel then
		if config.useplravi then
			-- Yields on a web call. Respawning everyone at once therefore makes
			-- one request per player -- see the note on `respawn all`.
			local success, desc = pcall(function()
				return Players:GetHumanoidDescriptionFromUserIdAsync(plr.UserId)
			end)
			if success and desc then
				Puppet.Humanoid:ApplyDescription(desc)

				-- Deferred because ApplyDescription parents accessories over
				-- several frames, and a part that arrives after this loop
				-- would still occlude the Advanced Audio API.
				task.spawn(function()
					for _, v in ipairs(Puppet:GetDescendants()) do
						if v:IsA("BasePart") then
							v.AudioCanCollide = false
						end
					end
				end)
			else
				warn("[Lifecycle] failed to fetch HumanoidDescription for " .. plr.Name)
			end
		end
		Puppet.HumanoidRootPart.Transparency = 1
	end

	-- No SetNetworkOwner here: anchored parts can't have one, and the puppet
	-- is driven by PuppetSync anyway.

	announce("Created PuppetModel for " .. plr.Name ..
		"\n  > {PrefferedModel = " .. tostring(preferredModel) ..
		"} { Use Roblox Appearance = " .. tostring(config.useplravi) .. "}")

	return Puppet
end

-- Full rig in one call, for loadhere. The two-remote path below stays intact
-- so the client's existing join-time spawn is unchanged.
local function buildRawBody(plr, cframe)
	local body = createBody(plr, cframe)
	if not body then return nil end

	local puppet = createPuppet(plr, lastPreferredModel[plr])
	if not puppet then
		body:Destroy()   -- don't leave a headless hull lying around
		return nil
	end

	return body
end

--=====================================================================
-- DESTROY
--=====================================================================

local function clearServerState(plr)
	local ws = Registry.WeaponServer
	if ws and type(ws.ClearHistory) == "function" then
		pcall(ws.ClearHistory, plr)
	end
end

local function destroyRawBody(plr)
	local rawBody = findRawBody(plr)
	if rawBody then rawBody:Destroy() end
	clearServerState(plr)
	return rawBody ~= nil
end

--=====================================================================
-- SPAWN POINT BRIDGE
--=====================================================================

-- Looked up lazily, not with a WaitForChild at load: SpawnPointServer and this
-- script have no guaranteed order, and a top-level wait would hang this whole
-- module if SpawnPointServer ever errored before publishing.
local spawnPointFn

local function getSpawnPointFn()
	if spawnPointFn and spawnPointFn.Parent then return spawnPointFn end
	spawnPointFn = ReplicatedStorage:FindFirstChild("GetSpawnPoint")
	return spawnPointFn
end

-- Returns cframe | nil, reason.
local function resolveSpawn(plr, teamOverride)
	local fn = getSpawnPointFn()
	if not fn then
		return nil, "SpawnPointServer is not loaded (no GetSpawnPoint in ReplicatedStorage)"
	end

	-- pcall because an OnInvoke error propagates straight back into the
	-- caller, and a broken spawn system should fail this one command rather
	-- than take down whatever loop is calling it.
	local ok, cframe, _, reason = pcall(fn.Invoke, fn, plr, teamOverride)
	if not ok then
		return nil, "GetSpawnPoint errored: " .. tostring(cframe)
	end
	if typeof(cframe) ~= "CFrame" then
		return nil, reason or "no spawn point available"
	end
	return cframe
end

--=====================================================================
-- PUBLIC API  ← what the gamemode script calls
--=====================================================================

local Lifecycle_API = {}
local GiveLoadout   = ensureRemote("GiveLoadout",   "BindableEvent")
GiveLoadout.Event:Connect(function(plr, loadout)
	Lifecycle_API.GiveLoadout(plr, loadout)
end)

-- spec is the same shape Inventory.ApplyLoadout takes; nil means the default.
-- This is the ONLY sanctioned way a player gets weapons.
function Lifecycle_API.GiveLoadout(plr, spec)
	local inv = inventoryFor(plr)
	Inventory.ApplyLoadout(inv, spec or DEFAULT_LOADOUT)
	pushInventory(plr)
	return true
end

-- Single slot, for buy menus, console commands and pickups. ONLY that slot is
-- touched -- this is the difference from GiveLoadout, which is a complete
-- statement of what the player carries and clears everything it isn't given.
--
-- slot is what the caller WANTS. A weapon with a designated slot overrides it
-- (and refuses outright if the caller explicitly asked for a different one);
-- a weapon that fits anywhere lands in the caller's slot, defaulting to the
-- player's active one so `give` swaps what you're holding.
--
-- Returns ok, slotUsed | reason.
function Lifecycle_API.GiveWeapon(plr, class, opts, slot)
	local inv = inventoryFor(plr)

	local target, reason
	if slot ~= nil then
		-- An explicitly named slot is a DEMAND: the caller said secondary, so
		-- a rifle is refused rather than quietly redirected to slot 1.
		target = Inventory.SlotIndex(slot)
		if not target then return false, ("no such slot: " .. tostring(slot)) end

		local allowed, why = Inventory.CanUseSlot(class, target)
		if not allowed then return false, why end
	else
		-- Nothing named: the active slot is a hint, and the weapon's own
		-- designated slot outranks it.
		target, reason = Inventory.SlotFor(class, inv.activeSlot)
		if not target then return false, reason end
	end

	if not Inventory.Give(inv, target, class, opts) then
		return false, "could not create " .. tostring(class)
	end
	pushInventory(plr)
	return true, target
end

-- Empty one slot and hand back what was in it, ammo counts intact -- which is
-- what makes a drop able to keep the magazine it was on.
function Lifecycle_API.TakeSlot(plr, slot)
	local inv = inventories[plr]
	if not inv then return nil end

	slot = Inventory.SlotIndex(slot)
	if not slot then return nil end

	local item = Inventory.Clear(inv, slot)
	if not item then return nil end

	-- Fall back to whatever the player still has, or they are left holding an
	-- empty slot with no way to notice except the missing viewmodel.
	if inv.activeSlot == slot then
		for i = 1, Inventory.SLOT_COUNT do
			if Inventory.Get(inv, i) then inv.activeSlot = i break end
		end
	end

	pushInventory(plr)
	return item
end

function Lifecycle_API.ClearSlot(plr, slot)
	return Lifecycle_API.TakeSlot(plr, slot) ~= nil
end

function Lifecycle_API.GetSlot(plr, slot)
	local inv = inventories[plr]
	slot = Inventory.SlotIndex(slot)
	return (inv and slot) and Inventory.Get(inv, slot) or nil
end

-- The client owns which slot is EQUIPPED (Input writes State.activeSlot on a
-- keypress and nothing told the server), so it reports the change back here.
-- Trusting it is safe: the only thing a lying client changes is which of its
-- OWN slots a give or a drop lands on.
function Lifecycle_API.SetActiveSlot(plr, slot)
	local inv = inventories[plr]
	slot = Inventory.SlotIndex(slot)
	if not (inv and slot) then return false end
	inv.activeSlot = slot
	return true
end

function Lifecycle_API.ActiveSlot(plr)
	local inv = inventories[plr]
	return inv and inv.activeSlot or Inventory.SLOT_PRIMARY
end

-- Read-only handle for WeaponServer: validate a FireWeapon packet's weapon
-- against what the player is ACTUALLY holding, rather than trusting the name
-- the client put on the wire.
function Lifecycle_API.GetInventory(plr)
	return inventories[plr]
end

-- Reusing InventorySync rather than minting a second remote: it already
-- carries inventory state, it's just been one-directional until now.
InventorySync.OnServerEvent:Connect(function(plr, packet)
	if type(packet) ~= "table" then return end
	if packet.activeSlot ~= nil then
		Lifecycle_API.SetActiveSlot(plr, packet.activeSlot)
	end
end)

function Lifecycle_API.HeldClass(plr)
	local inv = inventories[plr]
	local item = inv and Inventory.Active(inv)
	return item and item.class or nil
end

-- Destroy-then-build. Idempotent: works whether the player is alive,
-- spectating, or stuck half-torn-down.
local Spawnplayer   = ensureRemote("Spawnplayer",   "BindableEvent")
Spawnplayer.Event:Connect(function(plr, cframe)
	Lifecycle_API.Spawn(plr, cframe)
end)

function Lifecycle_API.Spawn(plr, cframe)
	if typeof(cframe) == "Vector3" then cframe = CFrame.new(cframe) end
	if typeof(cframe) ~= "CFrame" then
		return false, "Spawn needs a CFrame or Vector3"
	end

	destroyRawBody(plr)

	local body = buildRawBody(plr, cframe)
	if not body then return false, "buildRawBody failed" end
	Lifecycle_API.GiveLoadout(plr)
	PlayerSpawned:Fire(plr, cframe)

	-- The client's State.playerBody is nil right now: it didn't do this spawn,
	-- so nothing on its side knows the body exists. Without this it sits in
	-- spectate staring at its own puppet.
	Lifecycle:FireClient(plr, "ADOPT", cframe)
	return true
end

-- Ask the spawn system where, then spawn there. Everything a round start,
-- a death respawn, and the console command all need in common.
--
-- teamOverride is passed straight through to GetSpawnPoint, which is what
-- lets you place a player before their Team is actually set, and what lets a
-- solo developer with no team spawn at all.
local Respawnplayer = ensureRemote("Respawnplayer", "BindableEvent")
Respawnplayer.Event:Connect(function(plr, teamOverride)
	Lifecycle_API.Respawn(plr, teamOverride)
end)

function Lifecycle_API.Respawn(plr, teamOverride)
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then
		return false, "Respawn needs a Player"
	end
	if not plr.Parent then
		return false, "player has left"
	end

	local cframe, reason = resolveSpawn(plr, teamOverride)
	if not cframe then
		-- Reason comes from the spawn system and is already specific
		-- ("unassigned (Neutral)", "no spawn points tagged..."), so it is
		-- passed through untouched rather than flattened to a generic failure.
		return false, reason
	end

	return Lifecycle_API.Spawn(plr, cframe)
end

function Lifecycle_API.Unload(plr)
	local had = destroyRawBody(plr)
	clearInventory(plr)
	Lifecycle:FireClient(plr, "UNLOADED", had)
	return had
end

-- Teleport a LIVING player. The client owns its hull and predicts movement,
-- so setting the CFrame server-side alone gets overwritten within a frame by
-- the client's next PuppetSync. The client has to be told.
function Lifecycle_API.Move(plr, cframe)
	if typeof(cframe) == "Vector3" then cframe = CFrame.new(cframe) end
	if typeof(cframe) ~= "CFrame" then
		return false, "Move needs a CFrame or Vector3"
	end

	local body = findRawBody(plr)
	if not body then return false, plr.Name .. " has no body" end

	body.CFrame = cframe                      -- authoritative position
	Lifecycle:FireClient(plr, "TELEPORT", cframe)   -- and the prediction reset
	return true
end

function Lifecycle_API.IsAlive(plr)
	local body = findRawBody(plr)
	if not body then return false end

	local puppet = body:FindFirstChild("Puppet")
	if not puppet then return false end

	-- Attribute, not instance-existence. A corpse still has a RawBody.
	if puppet:GetAttribute("Dead") == true then return false end

	local hp = puppet:GetAttribute("Health")
	if hp ~= nil and hp <= 0 then return false end

	return true
end

Lifecycle_API.Killed = PlayerKilled.Event
Lifecycle_API.Spawned = PlayerSpawned.Event

function Lifecycle_API.Kill(plr, attacker, reason)
	local body = findRawBody(plr)
	if not body then return false end
	local puppet = body:FindFirstChild("Puppet")
	if not puppet then return false end
	return Health.Kill(puppet, attacker, reason)
end

--=====================================================================
-- CONSOLE COMMANDS
--=====================================================================

-- Accepts a name, "all", or nothing (meaning whoever typed it).
-- Returns { Player, ... } | nil, reason.
local function resolveTargets(ctx, who)
	if who == nil then
		if not (ctx and ctx.player) then
			return nil, "no player given, and this console has no player attached"
		end
		return { ctx.player }
	end

	local lower = string.lower(who)
	if lower == "all" or lower == "*" then
		local list = Players:GetPlayers()
		if #list == 0 then return nil, "nobody is connected" end
		return list
	end

	local plr, reason = Config.ResolvePlayer(who)
	if not plr then return nil, reason end
	return { plr }
end

Config.Command("respawn", {
	args = { "string?", "string?" },
	flag = Config.FCVAR.CHEAT,
	help = "respawn a player (or 'all') at a team spawn point",
	run = function(ctx, who, teamOverride)
		local targets, reason = resolveTargets(ctx, who)
		if not targets then return false, reason end

		local done, failures = 0, {}
		for _, target in ipairs(targets) do
			local ok, why = Lifecycle_API.Respawn(target, teamOverride)
			if ok then
				done += 1
			else
				table.insert(failures, ("%s: %s"):format(target.Name, tostring(why)))
			end
		end

		-- A single failure is reported AS a failure so the reason surfaces in
		-- red; a partial batch reports what it managed plus what it didn't.
		if done == 0 then
			return false, table.concat(failures, "\n")
		end

		local msg = (#targets == 1)
			and ("respawned %s"):format(targets[1].Name)
			or ("respawned %d of %d"):format(done, #targets)

		ctx.reply(#failures > 0 and (msg .. "\n" .. table.concat(failures, "\n")) or msg)
	end,
})

Config.Command("respawn_team", {
	args = { "string" },
	flag = Config.FCVAR.CHEAT,
	help = "respawn everyone on a team",
	run = function(ctx, teamName)
		local targets = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Team and plr.Team.Name == teamName then
				table.insert(targets, plr)
			end
		end
		if #targets == 0 then
			return false, ("nobody is on team '%s'"):format(teamName)
		end

		local done = 0
		local failures = {}
		for _, target in ipairs(targets) do
			local ok, why = Lifecycle_API.Respawn(target)
			if ok then done += 1 else table.insert(failures, ("%s: %s"):format(target.Name, tostring(why))) end
		end

		if done == 0 then return false, table.concat(failures, "\n") end
		ctx.reply(("respawned %d of %d on %s"):format(done, #targets, teamName))
	end,
})

Config.Command("spawn", {
	args = { "player", "vector3" },
	flag = Config.FCVAR.CHEAT,
	help = "respawn a player at an explicit world position",
	run = function(ctx, target, pos)
		local ok, reason = Lifecycle_API.Spawn(target, CFrame.new(pos))
		if not ok then return false, reason end
		-- Was returning the bare boolean, so a success printed nothing at all.
		ctx.reply(("spawned %s at %.1f %.1f %.1f"):format(target.Name, pos.X, pos.Y, pos.Z))
	end,
})

Config.Command("move", {
	args = { "player", "vector3" },
	flag = Config.FCVAR.CHEAT,
	help = "teleport a living player",
	run = function(ctx, target, pos)
		local ok, reason = Lifecycle_API.Move(target, CFrame.new(pos))
		if not ok then return false, reason end
		ctx.reply(("moved %s to %.1f %.1f %.1f"):format(target.Name, pos.X, pos.Y, pos.Z))
	end,
})

Config.Command("unload", {
	args = { "player?" },
	flag = Config.FCVAR.CHEAT,
	help = "destroy a player's body",
	run = function(ctx, target)
		target = target or (ctx and ctx.player)
		if not target then return false, "no player given" end
		local had = Lifecycle_API.Unload(target)
		ctx.reply(had and ("unloaded %s"):format(target.Name)
			or ("%s had no body"):format(target.Name))
	end,
})

--=====================================================================
-- CLIENT ENTRY POINTS
--=====================================================================

CreateBody.OnServerEvent:Connect(function(plr)
	destroyRawBody(plr)
	createBody(plr)
end)

CreatePuppet.OnServerEvent:Connect(function(plr, preferredModel)
	if preferredModel ~= nil and type(preferredModel) ~= "string" then return end
	lastPreferredModel[plr] = preferredModel
	createPuppet(plr, preferredModel)
	Lifecycle_API.GiveLoadout(plr)
	PlayerSpawned:Fire(plr)
end)

local busy = {}

Lifecycle.OnServerEvent:Connect(function(plr, action, cframe)
	if type(action) ~= "string" then return end
	if busy[plr] then return end
	busy[plr] = true

	local ok, err = pcall(function()
		if not ADMIN_USER_IDS[plr.UserId] or not Config.Values.sv_cheats then
			Lifecycle:FireClient(plr, "DENIED", action)
			return
		end
		if action == "UNLOAD" then
			Lifecycle_API.Unload(plr)
		elseif action == "LOADHERE" then
			if not Lifecycle_API.Spawn(plr, cframe) then
				Lifecycle:FireClient(plr, "SPAWN_FAILED")
			end
		end
	end)
	if not ok then warn("[Lifecycle]", err) end

	busy[plr] = nil
end)

Players.PlayerRemoving:Connect(function(plr)
	busy[plr] = nil
	lastPreferredModel[plr] = nil
	inventories[plr] = nil
	destroyRawBody(plr)
end)

Registry.Lifecycle = Lifecycle_API
print("[Lifecycle] API registered")
return nil