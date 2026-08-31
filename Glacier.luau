-- ModuleScript: Glacier
-- Parent: ReplicatedStorage
--
-- One entry point to the engine, from any script in either VM:
--   local G = require(game:GetService("ReplicatedStorage"):WaitForChild("Glacier"))
--   G.Config.mv_gravity          -- shared, always there
--   G.Physics.Step(dt)           -- client only
--   G.Respawn(plr)               -- server only
--
-- NOTHING IS REQUIRED AT LOAD. Every module resolves on first access and is
-- cached after. Two reasons, both load-bearing:
--
--   1. Cross-VM safety. Visuals reads workspace.CurrentCamera and waits 10s on
--      AnimationSync at require time; Input and Debug hold Players.LocalPlayer.
--      Requiring those from a Script would hang or break. Deferring means a
--      server script that never touches them never pays for them.
--
--   2. Circularity. A module inside the engine can require Glacier and Glacier
--      can expose that same module, because the require fires on ACCESS, not
--      on load -- by which point both have finished loading. This is the
--      problem Visuals.onWeaponEquipped exists to dodge; the library must not
--      reintroduce it.
--
-- Accessing a module that doesn't belong to this VM ERRORS, naming the module
-- and the VM. Returning nil instead would surface as "attempt to index nil"
-- somewhere downstream with nothing pointing back here.

local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local IS_SERVER = RunService:IsServer()
local IS_CLIENT = RunService:IsClient()

local Glacier = {}

Glacier.IsServer = IS_SERVER
Glacier.IsClient = IS_CLIENT
Glacier.Version  = "1.0.0"

--=====================================================================
-- PATH RESOLUTION
--=====================================================================

-- Cached, because a failed FindFirstChild on every access to every client
-- module would be a per-frame cost for scripts that poll.
local clientFolder, serverFolder

-- The client modules must be the SAME instance the client controller requires.
-- ModuleScripts cache per instance, so a second copy of, say, Input yields a
-- different BindableEvent and every event connection silently never fires.
-- Candidates are ordered most to least likely; a recursive search is
-- deliberately NOT used, since it could find a different folder entirely.
local function findClientFolder()
	if clientFolder and clientFolder.Parent then return clientFolder end
	if not IS_CLIENT then return nil end

	local plr = Players.LocalPlayer
	if not plr then return nil end

	local candidates = {
		plr:FindFirstChild("PlayerScripts"),
		ReplicatedStorage,
		plr:FindFirstChild("PlayerGui"),
	}

	for _, parent in ipairs(candidates) do
		if parent then
			local folder = parent:FindFirstChild("Player")
			if folder and folder:FindFirstChild("State") then
				clientFolder = folder
				return folder
			end
		end
	end
	return nil
end

local function findServerFolder()
	if serverFolder and serverFolder.Parent then return serverFolder end
	if not IS_SERVER then return nil end

	local sss = game:GetService("ServerScriptService")
	local folder = sss:FindFirstChild("Glacier1")
	if folder then serverFolder = folder end
	return folder
end

Glacier.ClientFolder = findClientFolder
Glacier.ServerFolder = findServerFolder

--=====================================================================
-- REMOTE RESOLUTION
--=====================================================================

-- Deliberately NOT find-or-create, unlike Lifecycle's ensureRemote. A
-- consumer that creates a missing engine remote wins the race against the
-- owner: Lifecycle builds OnPlayerKilled with a bare Instance.new, so it would
-- make a SECOND instance of the same name and the two halves of the engine
-- would end up on different objects. Waiting and failing loudly is correct
-- here -- creating is the owner's job.
function Glacier.Remote(name, timeout)
	local inst = ReplicatedStorage:FindFirstChild(name)
	if inst then return inst end

	inst = ReplicatedStorage:WaitForChild(name, timeout or 10)
	if not inst then
		error(("[Glacier] remote '%s' never appeared in ReplicatedStorage. " ..
			"Its owning script either didn't run or errored before publishing it.")
			:format(name), 2)
	end
	return inst
end

-- Same, but returns nil instead of erroring. For optional integrations.
function Glacier.TryRemote(name)
	return ReplicatedStorage:FindFirstChild(name)
end	

--=====================================================================
-- MODULE TABLE
--=====================================================================

-- Each entry is { vm, get }. `get` returns the value or nil; it must never
-- yield indefinitely, so callers get a clear error instead of a hang.
local function sharedModule(name)
	return function()
		local m = ReplicatedStorage:FindFirstChild(name)
		return m and m:IsA("ModuleScript") and require(m) or nil
	end
end

local function clientModule(name)
	return function()
		local folder = findClientFolder()
		if not folder then return nil end
		local m = folder:FindFirstChild(name)
		return m and m:IsA("ModuleScript") and require(m) or nil
	end
end

local function serverModule(name)
	return function()
		local folder = findServerFolder()
		if not folder then return nil end
		local m = folder:FindFirstChild(name)
		return m and m:IsA("ModuleScript") and require(m) or nil
	end
end

-- Published into Registry at runtime rather than being a module of its own.
-- Never cached as nil: the owning script may not have run yet, so a miss has
-- to stay retryable.
local function registryEntry(key)
	return function()
		local folder = findServerFolder()
		if not folder then return nil end
		local reg = folder:FindFirstChild("Registry")
		if not reg then return nil end
		local ok, registry = pcall(require, reg)
		return ok and registry[key] or nil
	end
end

local MODULES = {
	-- shared
	Config         = { vm = "both",   get = sharedModule("Config") },
	Inventory      = { vm = "both",   get = sharedModule("Inventory") },
	WeaponRegistry = { vm = "both",   get = sharedModule("WeaponRegistry") },
	AnimDefs       = { vm = "both",   get = sharedModule("AnimDefs") },

	-- client
	State        = { vm = "client", get = clientModule("State") },
	Physics      = { vm = "client", get = clientModule("Physics") },
	MovementMath = { vm = "client", get = clientModule("MovementMath") },
	Visuals      = { vm = "client", get = clientModule("Visuals") },
	Weapons      = { vm = "client", get = clientModule("Weapons") },
	Bullets      = { vm = "client", get = clientModule("Bullets") },
	Input        = { vm = "client", get = clientModule("Input") },
	Sounds       = { vm = "client", get = clientModule("Sounds") },
	SoundReceiver= { vm = "client", get = clientModule("SoundReceiver") },
	ViewBob      = { vm = "client", get = clientModule("ViewBob") },
	ViewSway     = { vm = "client", get = clientModule("ViewSway") },
	Crosshair    = { vm = "client", get = clientModule("Crosshair") },
	Character    = { vm = "client", get = clientModule("Character") },
	Spectate     = { vm = "client", get = clientModule("Spectate") },
	Debug        = { vm = "client", get = clientModule("Debug") },
	ServerDebug  = { vm = "client", get = clientModule("ServerDebug") },

	-- server
	Health       = { vm = "server", get = serverModule("Health") },
	Registry     = { vm = "server", get = serverModule("Registry") },
	Lifecycle    = { vm = "server", get = registryEntry("Lifecycle") },
	WeaponServer = { vm = "server", get = registryEntry("WeaponServer") },
	Gamemode     = { vm = "server", get = registryEntry("Gamemode") },
}

local cache = {}

local function vmName()
	return IS_SERVER and "server" or "client"
end

local function resolve(name, soft)
	local cached = cache[name]
	if cached ~= nil then return cached end

	local entry = MODULES[name]
	if not entry then
		if soft then return nil end
		error(("[Glacier] unknown module '%s'. Known: %s")
			:format(tostring(name), Glacier.ListNames()), 3)
	end

	if entry.vm ~= "both" and entry.vm ~= vmName() then
		if soft then return nil end
		error(("[Glacier] '%s' is %s-only; this is the %s VM.")
			:format(name, entry.vm, vmName()), 3)
	end

	local value = entry.get()
	if value == nil then
		if soft then return nil end
		error(("[Glacier] '%s' is not loaded yet. If a script owns it and runs " ..
			"later, use Glacier.Await('%s') instead of indexing directly.")
			:format(name, name), 3)
	end

	cache[name] = value
	return value
end

-- Non-erroring probe. Returns the module or nil.
function Glacier.Try(name)
	return resolve(name, true)
end

function Glacier.Has(name)
	return resolve(name, true) ~= nil
end

-- Blocks until the module resolves, or times out. For anything published by a
-- script whose start order isn't guaranteed -- Registry.Lifecycle is set at
-- the very end of PlayerLifecycleServer, so a script that requires Glacier and
-- immediately calls Spawn can lose that race.
function Glacier.Await(name, timeout)
	local deadline = os.clock() + (timeout or 10)
	repeat
		local value = resolve(name, true)
		if value ~= nil then return value end
		task.wait()
	until os.clock() > deadline

	warn(("[Glacier] Await('%s') timed out after %.1fs"):format(name, timeout or 10))
	return nil
end

function Glacier.ListNames()
	local out = {}
	for name in pairs(MODULES) do table.insert(out, name) end
	table.sort(out)
	return table.concat(out, ", ")
end

--=====================================================================
-- CONVENIENCE VERBS
--=====================================================================

-- Config is the one module worth resolving up front: everything below reads
-- it, and it's shared with no VM-specific behaviour at require time.
local function cfg()
	return resolve("Config")
end

-- Routes output to the right place per VM. The recurring footgun in this
-- project is print() landing in the server log where no player can read it,
-- so anything user-facing goes through here.
function Glacier.Log(message, isError)
	if IS_SERVER then
		local log = ReplicatedStorage:FindFirstChild("ConsoleLog")
		if log then
			log:FireAllClients(tostring(message), isError or false)
			return
		end
	else
		local input = resolve("Input", true)
		if input and type(input.Reply) == "function" then
			input.Reply(tostring(message))
			return
		end
	end
	if isError then warn(message) else print(message) end
end

-- Run a console line with a ctx that has a working reply. Calling Config.Exec
-- directly without one makes every command answer into the log instead.
function Glacier.Exec(line, player)
	return cfg().Exec(line, {
		player = player or (IS_CLIENT and Players.LocalPlayer or nil),
		source = IS_SERVER and "server" or "console",
		admin  = IS_SERVER,
		reply  = function(msg) Glacier.Log(msg) end,
	})
end

function Glacier.Get(key)
	return cfg().Get(key)
end

function Glacier.Set(key, value, force)
	return cfg().Set(key, value, force)
end

function Glacier.OnChange(key, fn)
	return cfg().OnChange(key, fn)
end

function Glacier.Command(name, spec)
	return cfg().Command(name, spec)
end

--------------------------------------------------------------
-- server verbs
--------------------------------------------------------------

local function requireServer(what)
	if not IS_SERVER then
		error(("[Glacier] %s is server-only."):format(what), 3)
	end
end

-- Awaited, not resolved: Registry.Lifecycle is published at the end of
-- PlayerLifecycleServer, and a caller at server start would otherwise race it.
local function lifecycle()
	requireServer("Lifecycle")
	return cache.Lifecycle or Glacier.Await("Lifecycle", 10)
end

function Glacier.Spawn(plr, cframe)   return lifecycle().Spawn(plr, cframe) end
function Glacier.Respawn(plr, team)   return lifecycle().Respawn(plr, team) end
function Glacier.Unload(plr)          return lifecycle().Unload(plr) end
function Glacier.Move(plr, cframe)    return lifecycle().Move(plr, cframe) end
function Glacier.IsAlive(plr)         return lifecycle().IsAlive(plr) end
function Glacier.Kill(plr, by, why)   return lifecycle().Kill(plr, by, why) end

function Glacier.GiveLoadout(plr, spec)
	return lifecycle().GiveLoadout(plr, spec)
end

function Glacier.GiveWeapon(plr, class, opts, slot)
	return lifecycle().GiveWeapon(plr, class, opts, slot)
end

function Glacier.HeldClass(plr)
	return lifecycle().HeldClass(plr)
end

-- BindableFunctions rather than events, because the caller needs a value back.
-- Returns cframe, part | nil, nil, reason.
function Glacier.GetSpawnPoint(entity, teamOverride)
	requireServer("GetSpawnPoint")
	local fn = ReplicatedStorage:FindFirstChild("GetSpawnPoint")
	if not fn then return nil, nil, "SpawnPointServer is not loaded" end
	return fn:Invoke(entity, teamOverride)
end

function Glacier.HasSpawnPoints(teamName)
	requireServer("HasSpawnPoints")
	local fn = ReplicatedStorage:FindFirstChild("HasSpawnPoints")
	return fn and fn:Invoke(teamName) or 0
end

--------------------------------------------------------------
-- entity identity
--------------------------------------------------------------

-- Normalises whatever a kill or damage event handed you -- a Player, a rawbody
-- model, a Puppet, a bot model, or nil -- into (entity, kind).
--
-- Two things every hand-rolled copy of this gets wrong:
--   the -? , because Studio UserIds are NEGATIVE and "^(%d+)RawBody$" fails
--   silently on every one of them; and the PARENT check, because Health fires
--   with the Puppet, whose own Name is just "Puppet".
function Glacier.Identify(x)
	if typeof(x) ~= "Instance" then return nil, nil end
	if x:IsA("Player") then return x, "player" end

	local parentName = x.Parent and x.Parent.Name or ""
	for _, n in ipairs({ x.Name, parentName }) do
		local id = tonumber(string.match(n, "^(%-?%d+)RawBody$"))
		if id then
			local p = Players:GetPlayerByUserId(id)
			if p then return p, "player" end
		end
	end

	local p = Players:GetPlayerFromCharacter(x)
	if p then return p, "player" end

	-- Not resolvable to a Player but still an Instance: treat as a bot.
	return x, "bot"
end

function Glacier.RawBody(plr)
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then return nil end
	return workspace:FindFirstChild(plr.UserId .. "RawBody")
end

-- Nil rather than an error for anything with no body right now: world damage,
-- a dead bot, a player mid-respawn. Callers shouldn't have to branch on type.
function Glacier.BodyOf(entity, kind)
	if not entity then return nil end
	if kind == "player" then return Glacier.RawBody(entity) end
	return entity   -- a bot model is its own body
end

function Glacier.PositionOf(entity, kind)
	local body = Glacier.BodyOf(entity, kind)
	if not body or not body.Parent then return nil end

	if body:IsA("BasePart") then return body.Position end
	if body:IsA("Model") then
		local ok, pivot = pcall(body.GetPivot, body)
		if ok then return pivot.Position end
	end
	return nil
end

--------------------------------------------------------------
-- world
--------------------------------------------------------------

function Glacier.SetTimescale(scale, rampTime)
	requireServer("SetTimescale")
	local e = Glacier.TryRemote("SetTimescale")
	if not e then return false, "TimescaleServer is not loaded" end
	e:Fire(scale, rampTime or 0)
	return true
end

-- Defaults to mp_startmap so a game loop never has to hardcode a map name.
function Glacier.LoadMap(name)
	requireServer("LoadMap")
	name = name or cfg().Get("mp_startmap")
	if not name or name == "" then
		return false, "no map given and mp_startmap is empty"
	end
	local ok, reason = Glacier.Exec("loadmap " .. name)
	return ok, reason or name
end

function Glacier.SoundAt(position, soundId)
	requireServer("SoundAt")
	if not (position and soundId) then return false end
	local r = Glacier.TryRemote("SoundReceiver")
	if not r then return false, "SoundReceiver remote missing" end
	r:FireAllClients(position, soundId)
	return true
end

--------------------------------------------------------------
-- client verbs
--------------------------------------------------------------

local function requireClient(what)
	if not IS_CLIENT then
		error(("[Glacier] %s is client-only."):format(what), 3)
	end
end

function Glacier.Bind(key, command)
	requireClient("Bind")
	return resolve("Input").Bind(key, command)
end

function Glacier.Unbind(key)
	requireClient("Unbind")
	return resolve("Input").Unbind(key)
end

function Glacier.IsDown(command)
	requireClient("IsDown")
	return resolve("Input").IsDown(command)
end

-- Shorthands for the two State fields most external scripts actually want.
function Glacier.Velocity()
	requireClient("Velocity")
	return resolve("State").velocity or Vector3.zero
end

function Glacier.Speed()
	local v = Glacier.Velocity()
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

--=====================================================================
-- EVENTS
--=====================================================================

-- One name per signal, resolved per VM. Wraps the existing BindableEvents
-- rather than inventing a bus -- a second event system would be another place
-- for a listener to be connected twice.
local SIGNALS = {
	PlayerKilled = { vm = "server", get = function()
		local e = ReplicatedStorage:FindFirstChild("OnPlayerKilled")
		return e and e.Event or nil
	end },
	PlayerSpawned = { vm = "server", get = function()
		local e = ReplicatedStorage:FindFirstChild("OnPlayerSpawned")
		return e and e.Event or nil
	end },
	PlayerJoined = { vm = "server", get = function()
		local e = ReplicatedStorage:FindFirstChild("OnPlayerJoined")
		return e and e.Event or nil
	end },
	-- The bindable is "OnDamage", not Health.Damaged. Health fires it; nothing
	-- exposes a Damaged signal on the module itself.
	Damaged = { vm = "server", get = function()
		local e = ReplicatedStorage:FindFirstChild("OnDamage")
		return e and e.Event or nil
	end },

	ActionPressed = { vm = "client", get = function()
		local i = resolve("Input", true)
		return i and i.ActionPressed.Event or nil
	end },
	BindingChanged = { vm = "client", get = function()
		local i = resolve("Input", true)
		return i and i.BindingChanged.Event or nil
	end },
}

-- Returns an RBXScriptConnection, so :Disconnect() works as normal.
function Glacier.On(signalName, fn)
	local entry = SIGNALS[signalName]
	if not entry then
		local names = {}
		for k in pairs(SIGNALS) do table.insert(names, k) end
		table.sort(names)
		error(("[Glacier] unknown signal '%s'. Known: %s")
			:format(tostring(signalName), table.concat(names, ", ")), 2)
	end
	if entry.vm ~= vmName() then
		error(("[Glacier] signal '%s' is %s-only; this is the %s VM.")
			:format(signalName, entry.vm, vmName()), 2)
	end

	local signal = entry.get()
	if not signal then
		error(("[Glacier] signal '%s' is not available yet -- its owner " ..
			"hasn't run."):format(signalName), 2)
	end
	return signal:Connect(fn)
end

--=====================================================================
-- STATUS
--=====================================================================

function Glacier.Status()
	local lines = { ("=== Glacier %s (%s VM) ==="):format(Glacier.Version, vmName()) }

	local folder = IS_CLIENT and findClientFolder() or findServerFolder()
	table.insert(lines, ("  module folder : %s")
		:format(folder and folder:GetFullName() or "<NOT FOUND>"))

	local names = {}
	for name in pairs(MODULES) do table.insert(names, name) end
	table.sort(names)

	for _, name in ipairs(names) do
		local entry = MODULES[name]
		local mark
		if entry.vm ~= "both" and entry.vm ~= vmName() then
			mark = "-  (" .. entry.vm .. " only)"
		elseif cache[name] then
			mark = "ok (cached)"
		elseif resolve(name, true) then
			mark = "ok"
		else
			mark = "MISSING"
		end
		table.insert(lines, ("  %-14s %s"):format(name, mark))
	end

	return table.concat(lines, "\n")
end

--=====================================================================
-- METATABLE
--=====================================================================

setmetatable(Glacier, {
	__index = function(_, key)
		return resolve(key)
	end,

	-- Assignment is allowed as an extension point, but never over a module
	-- name: silently shadowing Glacier.Physics would be near-impossible to
	-- trace back to the line that did it.
	__newindex = function(self, key, value)
		if MODULES[key] then
			error(("[Glacier] '%s' is an engine module and cannot be overwritten.")
				:format(key), 2)
		end
		rawset(self, key, value)
	end,
})

--=====================================================================
-- CONSOLE
--=====================================================================

do
	local Config = ReplicatedStorage:WaitForChild("Config")
	if Config then
		local ok, C = pcall(require, Config)
		if ok then
			C.Command("glacier_status", {
				args = {},
				help = "show which engine modules this VM has resolved",
				run = function(ctx) ctx.reply(Glacier.Status()) end,
			})
		end
	end
end

return Glacier