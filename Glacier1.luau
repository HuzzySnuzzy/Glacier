-- Glacier1 Server script, MAIN MANAGER
-- Place in ServerScriptService
--
-- RawBody/Puppet creation and destruction live in the PlayerLifecycleServer
-- child script. Map load/clear lives in the MapServer child script.
for _, in_ in pairs(script:WaitForChild("Injection"):GetChildren()) do
	for i, v in pairs(in_:GetChildren()) do
		v.Parent = game[in_.Name]
	end
end
local GlacierAssetId = 82155705987686

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

script.Parent = game.ServerScriptService

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local FCVAR = Config.FCVAR

local OnPlayerJoined = Instance.new("BindableEvent", ReplicatedStorage)
OnPlayerJoined.Name = "OnPlayerJoined"

Players.PlayerAdded:Connect(function(plr)
	OnPlayerJoined:Fire(plr)
	plr.CharacterAdded:Connect(function(char)
		char.PrimaryPart:SetNetworkOwner(plr)
	end)
end)

local function ensurePlayers() -- make sure they have the *Player* script.
	local endpoint = 'PlayerGui'
	for _, plr in pairs(Players:GetChildren()) do
		local pscript = plr[endpoint]:FindFirstChild("Player")
		if not pscript then
			pscript = script:WaitForChild("Player", 5):Clone()
			pscript.Parent = plr[endpoint]
		end

		local console = plr.PlayerGui:FindFirstChild("Console")
		if not console then
			console = script.Console:Clone()
			console.Parent = plr.PlayerGui
		end

		local menu = plr.PlayerGui:FindFirstChild("menu")
		if not menu then
			menu = script.menu:Clone()
			menu.Parent = plr.PlayerGui
		end

		local fx = plr.PlayerGui:FindFirstChild("fx")
		if not fx then
			fx = script.fx:Clone()
			fx.Parent = plr.PlayerGui
		end
	end
end

task.spawn(function()
	while true do
		task.wait(1)
		ensurePlayers()
	end
end)

for _, in_ in pairs(script:WaitForChild("Injection"):GetChildren()) do
	for _, v in pairs(in_:GetChildren()) do
		v.Parent = game[in_.Name]
	end
end

--=====================================================================
-- REMOTES
--=====================================================================

-- Find-or-create: PlayerLifecycleServer also uses ConsoleLog, and start order
-- between the two scripts isn't guaranteed.
local ConsoleLog = ReplicatedStorage:FindFirstChild("ConsoleLog")
if not ConsoleLog then
	ConsoleLog = Instance.new("RemoteEvent")
	ConsoleLog.Name = "ConsoleLog"
	ConsoleLog.Parent = ReplicatedStorage
end

local SoundReceiver = Instance.new("RemoteEvent")
SoundReceiver.Name = "SoundReceiver"
SoundReceiver.Parent = ReplicatedStorage

local PuppetSyncEvent = Instance.new("UnreliableRemoteEvent")
PuppetSyncEvent.Name = "PuppetSync"
PuppetSyncEvent.Parent = ReplicatedStorage

PuppetSyncEvent.OnServerEvent:Connect(function(plr, packet)
	local ID = plr.UserId
	local Body = workspace:FindFirstChild(ID .. "RawBody")
	if not Body then
		warn("Body Doesnt Exist ~PuppetSyncEvent")
		return
	end

	local Puppet = Body:FindFirstChild("Puppet")
	if Puppet and packet.CFRAME then
		Puppet.PrimaryPart.CFrame = packet.CFRAME
	end

	PuppetSyncEvent:FireAllClients(plr, packet)
end)

local AnimationSyncEvent = Instance.new("RemoteEvent")
AnimationSyncEvent.Name = "AnimationSync"
AnimationSyncEvent.Parent = ReplicatedStorage

AnimationSyncEvent.OnServerEvent:Connect(function(plr, packet)
	if type(packet) ~= "table" then return end
	AnimationSyncEvent:FireAllClients(plr, packet)
end)

--=====================================================================
-- CONFIG REPLICATION
--=====================================================================
-- Two directions:
--   server -> client : ConfigSync:FireClient(plr, key, value)  (single write)
--                      ConfigSync:FireClient(plr, snapshotTbl) (full pull)
--   client -> server : ConfigSync:FireServer()                 (request pull)
--
-- The client applies with forceOverride, because the server is authoritative
-- and the client's own permission checks would reject REPLICATED/CHEAT writes.

local ConfigSync = ReplicatedStorage:FindFirstChild("ConfigSync")
if not ConfigSync then
	ConfigSync = Instance.new("RemoteEvent")
	ConfigSync.Name = "ConfigSync"
	ConfigSync.Parent = ReplicatedStorage
end
-- Force-push a console line to every client. Distinct from ConfigSync, which
-- only carries REPLICATED/CHEAT cvars: this carries whatever an admin typed,
-- including pure-CLIENT cvars and client-side commands, and the receiver
-- applies it with forceOverride.
local ConsoleBroadcast = Instance.new("RemoteEvent")
ConsoleBroadcast.Name = "ConsoleBroadcast"
ConsoleBroadcast.Parent = ReplicatedStorage
-- Pure-CLIENT cvars (crosshair, viewmodel, bob) stay local; stomping those
-- would wipe a player's personal settings every time the server touched one.
local function shouldReplicate(key)
	return Config.HasFlag(key, FCVAR.REPLICATED) or Config.HasFlag(key, FCVAR.CHEAT)
end

Config.OnServerVarChanged = function(key, value)
	if shouldReplicate(key) then
		ConfigSync:FireAllClients(key, value)
	end
end

local lastPull = {}   -- [player] = os.clock(); cheap flood guard on the snapshot

ConfigSync.OnServerEvent:Connect(function(plr)
	local now = os.clock()
	if lastPull[plr] and now - lastPull[plr] < 1 then return end
	lastPull[plr] = now

	local snapshot = {}
	for key, value in pairs(Config.Values) do
		if shouldReplicate(key) then snapshot[key] = value end
	end
	ConfigSync:FireClient(plr, snapshot)
end)

Players.PlayerRemoving:Connect(function(plr) lastPull[plr] = nil end)

-- Server-to-server cvar writes. Any other server script can do
--   ReplicatedStorage.ConfigSet:Fire("mp_freezetime", 3)
-- and it replicates to everyone via OnServerVarChanged above. Safe to leave in
-- ReplicatedStorage: BindableEvents never cross the network boundary, so a
-- client firing this only reaches client-side listeners (there are none).
local ConfigSet = Instance.new("BindableEvent")
ConfigSet.Name = "ConfigSet"
ConfigSet.Parent = ReplicatedStorage

ConfigSet.Event:Connect(function(key, value)
	if type(key) ~= "string" then
		warn("[ConfigSet] key must be a string")
		return
	end
	Config.Set(key, value, true)
end)

-- Same idea for full command lines: ConfigExec:Fire("loadmap dust2")
local ConfigExec = Instance.new("BindableEvent")
ConfigExec.Name = "ConfigExec"
ConfigExec.Parent = ReplicatedStorage

ConfigExec.Event:Connect(function(line)
	if type(line) ~= "string" then return end
	Config.Exec(line, { admin = true, source = "server", forceOverride = true })
end)

--=====================================================================
-- CONSOLE
--=====================================================================

local ConsoleEvent = Instance.new("RemoteEvent")
ConsoleEvent.Name = "ConsoleEvent"
ConsoleEvent.Parent = ReplicatedStorage

local ADMIN_USER_IDS = {
	[32358526] = true,
	[-1] = true,   -- Studio solo play; REMOVE BEFORE SHIPPING
}

--=====================================================================
-- ADMIN IS OPT-IN
--=====================================================================
-- Being on the list is permission to elevate, not elevation. Until a listed
-- player runs `admin`, every command they send is refused exactly as it would
-- be for anyone else.
--
-- The point is not to stop the admin -- they can elevate in one word -- it is
-- that an admin playing normally cannot fire a cheat command by muscle memory,
-- a stale bind, or a pasted line, and that what they see of the game is what
-- everyone else sees until they choose otherwise.

local elevated = {}   -- [Player] = true

Players.PlayerRemoving:Connect(function(plr) elevated[plr] = nil end)

local function isListed(plr)
	return typeof(plr) == "Instance"
		and plr:IsA("Player")
		and ADMIN_USER_IDS[plr.UserId] == true
end

-- Published so another server script applies the SAME rule rather than
-- inventing a second admin list that drifts from this one. It reports
-- ELEVATION, not membership -- otherwise wedit and the rest would still be
-- open to a listed admin who had not elevated, and the opt-in would only
-- cover the console.
do
	local Registry = require(script:WaitForChild("Registry"))
	Registry.IsAdmin = function(plr)
		return isListed(plr) and elevated[plr] == true
	end
	Registry.IsListedAdmin = isListed
end

--=====================================================================
-- BROADCAST PREFIX
--=====================================================================
-- A leading '!' means "apply this everywhere", not just on the server:
--
--   host_timescale 0.25   -- server sets it; ConfigSync pushes it because
--                            host_timescale is CHEAT and therefore replicated
--   !cl_crosshairgap 10   -- server sets it AND overrides every client's
--                            personal setting, which ConfigSync would not do
--
-- Admin-gated, obviously -- this reaches into settings players own.

--=====================================================================
-- ELEVATION COMMANDS
--=====================================================================
-- Registered rather than intercepted so the client console knows the names
-- exists at all: DevConsole refuses to forward a line whose first word it has
-- never heard of, so an unregistered `admin` would never leave the client.
--
-- REPLICATED, which is what makes the console forward them rather than trying
-- to run them in the client VM where the elevation table does not exist.

Config.Command("admin", {
	args = {},
	flag = FCVAR.REPLICATED,
	help = "elevate yourself, if you are on the admin list",
	run = function(ctx)
		local plr = ctx and ctx.player
		if not plr then return false, "admin needs a player" end

		-- An unlisted player learns nothing from typing this that they would
		-- not learn from typing any other command.
		if not isListed(plr) then return false, "Access denied." end

		elevated[plr] = true
		if ctx.reply then
			ctx.reply("Elevated. Commands are live -- `unadmin` to drop back.")
		end
		return true
	end,
})

Config.Command("unadmin", {
	args = {},
	flag = FCVAR.REPLICATED,
	help = "drop back to being an ordinary player",
	run = function(ctx)
		local plr = ctx and ctx.player
		if not plr then return false, "unadmin needs a player" end

		elevated[plr] = nil
		if ctx.reply then ctx.reply("Dropped to player.") end
		return true
	end,
})

local BROADCAST_PREFIX = "!"

-- Per-player debounce. An admin isn't a threat model, but a stuck key firing
-- FireAllClients at input rate is a real way to wedge the reliable channel.
local lastCommand = {}
local COMMAND_INTERVAL = 0.1

Players.PlayerRemoving:Connect(function(plr) lastCommand[plr] = nil end)

ConsoleEvent.OnServerEvent:Connect(function(player, commandString)
	if type(commandString) ~= "string" then return end
	if #commandString > 300 then return end

	-- The two commands that have to pass the gate, or there would be no way
	-- through it. They are ordinary Config.Commands (registered below), so
	-- they autocomplete, appear in help, and have one implementation -- this
	-- only decides that the gate does not apply to them.
	local verb = string.match(commandString, "^%s*!?%s*(%S+)")
	local isAuthCommand = (verb == "admin" or verb == "unadmin")

	if not isAuthCommand and not elevated[player] then
		-- Listed but not elevated gets told how; everyone else gets the same
		-- flat refusal, and cannot tell the two apart.
		ConsoleLog:FireClient(player, isListed(player)
			and "Access denied. Run `admin` to elevate."
			or "Access denied.", true)
		return
	end

	local now = os.clock()
	if lastCommand[player] and now - lastCommand[player] < COMMAND_INTERVAL then return end
	lastCommand[player] = now

	-- Strip the prefix before anything else touches the line. Config.Exec
	-- tokenises on whitespace, so '!host_timescale' would tokenise as one
	-- unknown name rather than a cvar.
	local broadcast = string.sub(commandString, 1, 1) == BROADCAST_PREFIX
	local line = broadcast
		and (string.gsub(string.sub(commandString, 2), "^%s+", ""))
		or commandString

	if line == "" then return end

	local name = string.match(line, "^(%S+)")

	local ok, reason = Config.Exec(line, {
		player = player,
		admin = true,
		source = "console",
		forceOverride = true,

		-- Commands that produce OUTPUT (as opposed to just succeeding) need a
		-- way back to the person who typed the line. print() goes to the server
		-- log, which the player can't see. Anything registered via
		-- Config.Command should write through ctx.reply, not print.
		reply = function(text, isError)
			ConsoleLog:FireClient(player, tostring(text), isError == true)
		end,
	})

	if broadcast and ok then
		-- Cvars that already auto-replicate went out via OnServerVarChanged
		-- during Config.Exec above. Sending them again would run every
		-- OnChange listener on every client a second time -- for something
		-- like cl_crosshaircolor that's a wasted rebuild, and for anything
		-- with a spring or an accumulator behind it, it's a visible glitch.
		local isCvar = Config.Values[name] ~= nil
		if not (isCvar and shouldReplicate(name)) then
			ConsoleBroadcast:FireAllClients(line)
		end

		ConsoleLog:FireAllClients(("%s: %s"):format(player.Name, line), false)
	end

	if ok then
		ConsoleLog:FireClient(player, ("-> %s"):format(line), false)
	else
		ConsoleLog:FireClient(player, ("-> %s"):format(tostring(reason or "failed")), true)
	end
end)

--=====================================================================
-- WEAPON EQUIP
--=====================================================================

local EquipWeaponEvent = Instance.new("RemoteEvent")
EquipWeaponEvent.Name = "EquipWeaponEvent"
EquipWeaponEvent.Parent = ReplicatedStorage

EquipWeaponEvent.OnServerEvent:Connect(function(player, weaponName)
	local character = workspace:FindFirstChild(player.UserId .. "RawBody")
	if not character then return end

	for _, child in pairs(character:GetChildren()) do
		if child:GetAttribute("IsEquippedWeapon") then child:Destroy() end
	end

	local puppet = character:FindFirstChild("Puppet")
	if not puppet then return end

	for _, child in ipairs(puppet:GetChildren()) do
		if child:GetAttribute("IsEquippedWeapon") then child:Destroy() end
	end

	if weaponName == "" then return end

	local arm = puppet:FindFirstChild("Right Arm")
	local template = ReplicatedStorage:FindFirstChild(weaponName)
	if not (arm and template) then return end

	local weapon = template:Clone()
	weapon:SetAttribute("IsEquippedWeapon", true)
	weapon.Name = "Holding"
	weapon.Parent = puppet

	for _, v in ipairs(weapon:GetDescendants()) do
		if v:IsA("BasePart") then
			v.CanCollide = false
			v.CanQuery = false
			v.Anchored = false   -- a Motor6D chain can't contain anchored parts
			v.Massless = true
		end
	end

	local handle = weapon.PrimaryPart
	if not handle then
		warn(weaponName .. " is missing a PrimaryPart!")
		return
	end

	local armGrip = arm:FindFirstChild("RightGripAttachment")
	local weaponGrip = handle:FindFirstChild("GripAttachment")
	if not (armGrip and weaponGrip) then return end

	local grip = Instance.new("Motor6D")
	grip.Name = "WeaponGrip"
	grip.Part0 = arm
	grip.Part1 = handle
	grip.C0 = armGrip.CFrame
	grip.C1 = weaponGrip.CFrame
	grip.Parent = arm
end)