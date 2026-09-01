-- Script: CSCommandsServer
-- Parent: Glacier1
--
-- The console verbs a CS player already has muscle memory for, implemented on
-- top of Glacier's server API rather than reaching into the lifecycle directly:
--
--   give weapon_ak47      kill / explode        god / buddha
--   give item_assaultsuit hurtme 50             heal 100
--   impulse 101           status                getpos / setpos
--   jointeam ct           mp_swapteams          mp_scrambleteams
--   changelevel Mirage    mp_restartgame 3      say / say_team
--
-- WHY SERVER-SIDE: all of it is server-authoritative (health, teams, spawn
-- points, inventory), and registering here rather than in Config means the
-- client has no local entry for these names. That is deliberate -- the console
-- forwards a line it has no entry for, and runCommand REJECTS a REPLICATED
-- command in the client VM instead of forwarding it. Same reason loadmap lives
-- in MapServer. Cvar-style names (sv_gravity, mp_warmuptime) are aliases and
-- live in Config, which applies the same rule to itself.
--
-- ACCESS: Glacier1's ConsoleEvent handler gates every forwarded line on
-- ADMIN_USER_IDS before it reaches Config.Exec, so "anyone can type kill" is
-- not a thing here -- non-admins get "Access denied." on any line at all.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config    = require(ReplicatedStorage:WaitForChild("Config"))
local Glacier   = require(ReplicatedStorage:WaitForChild("Glacier"))
local Inventory = require(ReplicatedStorage:WaitForChild("Inventory"))

local FCVAR      = Config.FCVAR
local SERVER     = FCVAR.REPLICATED
local SERVER_CHEAT = FCVAR.REPLICATED + FCVAR.CHEAT

local function reply(ctx, text, isError)
	if ctx and type(ctx.reply) == "function" then
		ctx.reply(text, isError)
	elseif isError then warn(text) else print(text) end
end

--=====================================================================
-- TARGETS
--=====================================================================

-- Nothing given means the person who typed it. A name or "all" means somebody
-- else, and that is cheat-gated even on commands that aren't: `kill` on
-- yourself is a normal CS verb, `kill someone_else` is an admin action.
-- Returns { Player, ... } | nil, reason.
local function resolveTargets(ctx, who, verb)
	if who == nil then
		if not (ctx and ctx.player) then
			return nil, ("%s needs a player; run it from a console"):format(verb)
		end
		return { ctx.player }
	end

	if not Config.Get("sv_cheats") then
		return nil, ("targeting another player with %s needs sv_cheats 1"):format(verb)
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

-- Runs fn over the targets and reports as one line, because "kill all" on a
-- full server would otherwise be sixteen console lines of the same message.
-- fn returns ok, reason.
local function forEach(ctx, targets, verb, fn)
	local done, failures = 0, {}
	for _, plr in ipairs(targets) do
		local ok, why = fn(plr)
		if ok then
			done += 1
		else
			table.insert(failures, ("%s (%s)"):format(plr.Name, tostring(why or "failed")))
		end
	end

	if done == 0 then
		return false, ("%s: %s"):format(verb, table.concat(failures, ", "))
	end

	reply(ctx, ("[%s] %d player%s%s"):format(verb, done, done == 1 and "" or "s",
		#failures > 0 and ("  skipped: " .. table.concat(failures, ", ")) or ""))
	return true
end

--=====================================================================
-- GIVE
--=====================================================================
-- CS:GO spells everything weapon_* / item_*; CS 1.6 and everyone typing fast
-- spell it "ak47". Both work: the prefix is stripped and what's left goes to
-- WeaponRegistry, which is already case-insensitive.

local ITEMS = {
	item_kevlar = function(plr)
		Glacier.GiveArmor(plr, 100, false)
		return true, "kevlar"
	end,
	item_assaultsuit = function(plr)
		Glacier.GiveArmor(plr, 100, true)
		return true, "kevlar + helmet"
	end,
	item_helmet = function(plr)
		Glacier.GiveArmor(plr, 0, true)
		return true, "helmet"
	end,
	item_healthshot = function(plr)
		Glacier.Heal(plr, 50)
		return true, "healthshot"
	end,
}

local function giveTo(plr, raw)
	local query = string.lower(raw)

	local item = ITEMS[query]
	if item then
		if not Glacier.IsAlive(plr) then return false, "not alive" end
		return item(plr)
	end

	-- weapon_ak47 -> ak47, and a bare "ak47" falls through untouched.
	local class = Glacier.WeaponClass(string.match(query, "^weapon_(.+)$") or raw)
	if not class then
		return false, ("no weapon or item named '%s'"):format(raw)
	end

	-- No slot is passed, so GiveWeapon uses the weapon's designated slot if it
	-- has one and the player's ACTIVE slot if it doesn't -- give swaps what
	-- you're holding, and never touches the slots you aren't.
	local ok, result = Glacier.GiveWeapon(plr, class)
	if not ok then return false, result end
	return true, ("%s (%s)"):format(class, Inventory.SlotName(result))
end

Config.Command("give", {
	args = { "string", "string?" },
	flag = SERVER_CHEAT,
	help = "give a weapon or item: give weapon_ak47 | give ak47 | give item_assaultsuit",
	run = function(ctx, what, who)
		local targets, reason = resolveTargets(ctx, who, "give")
		if not targets then return false, reason end

		local given, failures, label = 0, {}, what
		for _, plr in ipairs(targets) do
			local ok, result = giveTo(plr, what)
			if ok then
				given += 1
				label = result
			else
				table.insert(failures, ("%s (%s)"):format(plr.Name, tostring(result)))
			end
		end

		if given == 0 then return false, table.concat(failures, ", ") end

		-- The gamemode owns the loadout and re-arms on spawn; `primary` raises
		-- sv_lockLoadout for exactly that reason and this deliberately does not,
		-- matching CS:GO, where a give lasts until you next get kitted out.
		reply(ctx, ("[give] %s to %d player%s -- until the gamemode re-arms them%s"):format(
			label, given, given == 1 and "" or "s",
			#failures > 0 and ("  skipped: " .. table.concat(failures, ", ")) or ""))
		return true
	end,
})

Config.Command("impulse", {
	args = { "number" },
	flag = SERVER_CHEAT,
	help = "impulse 101: full health, armour and helmet",
	run = function(ctx, code)
		local plr = ctx and ctx.player
		if not plr then return false, "impulse needs a player" end
		if code ~= 101 then
			return false, ("impulse %d does nothing here (101 is the only one wired up)"):format(code)
		end
		if not Glacier.IsAlive(plr) then return false, "you're not alive" end

		Glacier.Heal(plr, 100)
		Glacier.GiveArmor(plr, 100, true)
		reply(ctx, "[impulse] 100 health, 100 armour, helmet")
		return true
	end,
})

--=====================================================================
-- HEALTH
--=====================================================================

Config.Command("kill", {
	args = { "string?" },
	flag = SERVER,
	help = "kill yourself, or another player with sv_cheats 1",
	run = function(ctx, who)
		local targets, reason = resolveTargets(ctx, who, "kill")
		if not targets then return false, reason end

		return forEach(ctx, targets, "kill", function(plr)
			if not Glacier.IsAlive(plr) then return false, "already dead" end
			return Glacier.Kill(plr, nil, "suicide")
		end)
	end,
})

-- Same verb, different killfeed reason. Cheap to keep, and it's the one every
-- CS player types when kill is on cooldown in the real game.
Config.Command("explode", {
	args = { "string?" },
	flag = SERVER,
	help = "kill yourself, attributed to 'explode'",
	run = function(ctx, who)
		local targets, reason = resolveTargets(ctx, who, "explode")
		if not targets then return false, reason end

		return forEach(ctx, targets, "explode", function(plr)
			if not Glacier.IsAlive(plr) then return false, "already dead" end
			return Glacier.Kill(plr, nil, "explode")
		end)
	end,
})

Config.Command("hurtme", {
	args = { "number", "string?" },
	flag = SERVER_CHEAT,
	help = "damage yourself by an amount, armour and hitgroups included",
	run = function(ctx, amount, who)
		if amount <= 0 then return false, "hurtme takes a positive amount" end

		local targets, reason = resolveTargets(ctx, who, "hurtme")
		if not targets then return false, reason end

		return forEach(ctx, targets, "hurtme", function(plr)
			if not Glacier.IsAlive(plr) then return false, "not alive" end
			-- Through Health.Damage rather than straight to the attribute, so
			-- armour, buddha and the OnDamage listeners all see it -- that is
			-- the whole point of testing with it.
			local dealt = Glacier.Damage(plr, amount, { hitPart = "Torso" })
			return dealt > 0, "no damage landed"
		end)
	end,
})

Config.Command("heal", {
	args = { "number?", "string?" },
	flag = SERVER_CHEAT,
	help = "heal yourself (default: to full)",
	run = function(ctx, amount, who)
		local targets, reason = resolveTargets(ctx, who, "heal")
		if not targets then return false, reason end

		return forEach(ctx, targets, "heal", function(plr)
			if not Glacier.IsAlive(plr) then return false, "not alive" end
			Glacier.Heal(plr, amount or 100)
			return true
		end)
	end,
})

-- god and buddha are attributes on the puppet, so they clear themselves on
-- death. Reporting the state back matters more than usual for that reason.
local function cheatToggle(name, attribute, setter, description)
	Config.Command(name, {
		args = { "string?" },
		flag = SERVER_CHEAT,
		help = description,
		run = function(ctx, who)
			local targets, reason = resolveTargets(ctx, who, name)
			if not targets then return false, reason end

			-- Not forEach: a toggle's useful output is the resulting STATE, and
			-- over several targets those states can differ, so "3 players" would
			-- be the one thing the caller can't act on.
			local changed, failures = {}, {}
			for _, plr in ipairs(targets) do
				local puppet = Glacier.PuppetOf(plr)
				if not puppet then
					table.insert(failures, ("%s (no body)"):format(plr.Name))
				else
					local on = not puppet:GetAttribute(attribute)
					local ok, why = setter(plr, on)
					if ok then
						table.insert(changed, ("%s %s"):format(plr.Name, on and "ON" or "off"))
						-- Somebody else flipping your invulnerability is worth
						-- knowing about; you already see it if you typed it.
						if plr ~= (ctx and ctx.player) then
							Glacier.Tell(plr, ("[%s] %s"):format(name, on and "ON" or "off"))
						end
					else
						table.insert(failures, ("%s (%s)"):format(plr.Name, tostring(why)))
					end
				end
			end

			if #changed == 0 then return false, table.concat(failures, ", ") end
			reply(ctx, ("[%s] %s%s"):format(name, table.concat(changed, ", "),
				#failures > 0 and ("  skipped: " .. table.concat(failures, ", ")) or ""))
			return true
		end,
	})
end

cheatToggle("god", "God", Glacier.SetGod,
	"toggle invulnerability; clears when you die")
cheatToggle("buddha", "Buddha", Glacier.SetBuddha,
	"toggle taking damage without ever dying")

--=====================================================================
-- POSITION
--=====================================================================

Config.Command("getpos", {
	args = {},
	flag = SERVER,
	help = "print your position as a setpos line",
	run = function(ctx)
		local plr = ctx and ctx.player
		if not plr then return false, "getpos needs a player" end

		local body = Glacier.RawBody(plr)
		if not body then return false, "you have no body" end

		local pos = body.Position
		local yaw = math.deg(select(2, body.CFrame:ToOrientation()))
		reply(ctx, ("setpos %.2f %.2f %.2f   (yaw %.1f)"):format(pos.X, pos.Y, pos.Z, yaw))
		return true
	end,
})

Config.Command("setpos", {
	args = { "vector3" },
	flag = SERVER_CHEAT,
	help = "teleport yourself to x y z, keeping your facing",
	run = function(ctx, position)
		local plr = ctx and ctx.player
		if not plr then return false, "setpos needs a player" end

		local body = Glacier.RawBody(plr)
		if not body then return false, "you have no body" end

		-- Rotation is carried over rather than reset: setpos in Source moves
		-- you without spinning you, and setang is the command that turns you.
		local rotation = body.CFrame - body.CFrame.Position
		local ok, reason = Glacier.Move(plr, CFrame.new(position) * rotation)
		if not ok then return false, reason end

		reply(ctx, ("[setpos] %.2f %.2f %.2f"):format(position.X, position.Y, position.Z))
		return true
	end,
})

--=====================================================================
-- TEAMS
--=====================================================================

Config.Command("jointeam", {
	args = { "string", "string?" },
	flag = SERVER,
	help = "join a team by name: jointeam ct | jointeam t | jointeam spec",
	run = function(ctx, teamName, who)
		local targets, reason = resolveTargets(ctx, who, "jointeam")
		if not targets then return false, reason end

		return forEach(ctx, targets, "jointeam", function(plr)
			-- respawn = true: the spawn system reads Player.Team, so a live
			-- body left standing in the old team's spawn is the visible half
			-- of not doing this.
			return Glacier.SetTeam(plr, teamName, true)
		end)
	end,
})

local function sideTeams()
	local t = Glacier.ResolveTeam("T")
	local ct = Glacier.ResolveTeam("CT")
	if not (t and ct) then
		return nil, nil, "this server has no T and CT teams (TeamsSetup only creates Spectator)"
	end
	return t, ct
end

Config.Command("mp_swapteams", {
	args = {},
	flag = SERVER_CHEAT,
	help = "swap every player to the other side and respawn them",
	run = function(ctx)
		local t, ct, reason = sideTeams()
		if not t then return false, reason end

		-- The whole roster is read BEFORE anything moves. Reassigning inside
		-- the loop would swap a player twice: over to CT, then back on the
		-- second pass, because the list is Player.Team-derived either way.
		local moves = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Team == t then table.insert(moves, { plr, ct })
			elseif plr.Team == ct then table.insert(moves, { plr, t }) end
		end

		if #moves == 0 then return false, "nobody is on T or CT" end

		for _, move in ipairs(moves) do
			Glacier.SetTeam(move[1], move[2], true)
		end

		Glacier.Broadcast(("[mp_swapteams] swapped %d players"):format(#moves))
		return true
	end,
})

Config.Command("mp_scrambleteams", {
	args = {},
	flag = SERVER_CHEAT,
	help = "shuffle everyone across T and CT, then respawn them",
	run = function(ctx)
		local t, ct, reason = sideTeams()
		if not t then return false, reason end

		local roster = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			-- Spectators stay spectators: scrambling drags people who chose to
			-- sit out back into the round.
			if plr.Team == t or plr.Team == ct then table.insert(roster, plr) end
		end
		if #roster < 2 then return false, "need at least two players on a side" end

		-- Fisher-Yates, then deal alternately. Assigning each player a random
		-- side independently gives 5-1 splits often enough to notice.
		for i = #roster, 2, -1 do
			local j = math.random(i)
			roster[i], roster[j] = roster[j], roster[i]
		end

		for index, plr in ipairs(roster) do
			Glacier.SetTeam(plr, (index % 2 == 1) and t or ct, true)
		end

		Glacier.Broadcast(("[mp_scrambleteams] scrambled %d players"):format(#roster))
		return true
	end,
})

--=====================================================================
-- MATCH
--=====================================================================

local restartPending = false

Config.Command("mp_restartgame", {
	args = { "number?" },
	flag = SERVER_CHEAT,
	help = "restart the current gamemode after a countdown (default 1s)",
	run = function(ctx, delay)
		if restartPending then return false, "a restart is already counting down" end

		delay = math.clamp(delay or 1, 0, 60)
		restartPending = true

		Glacier.Broadcast(("[mp_restartgame] restarting in %d second%s")
			:format(delay, delay == 1 and "" or "s"))

		-- Through Exec rather than reaching into GamemodeServer: it owns the
		-- start/stop pair, and a second entry point into that is a second place
		-- for a half-started mode to come from.
		task.delay(delay, function()
			restartPending = false
			local ok, reason = Glacier.Exec("gamemode_restart")
			if not ok then
				Glacier.Broadcast(("[mp_restartgame] failed: %s"):format(tostring(reason)))
			end
		end)
		return true
	end,
})

-- changelevel is what a CS player types; loadmap is what this engine calls it.
-- Registered as its own command rather than a Config.Alias because an alias
-- targets a CVAR, and this is a verb.
local function changelevel(ctx, name)
	local ok, reason = Config.Exec("loadmap " .. name, ctx)
	if not ok then return false, reason end
	return true
end

Config.Command("changelevel", {
	args = { "string" },
	flag = SERVER,
	help = "load a map (same as loadmap)",
	run = changelevel,
})

Config.Command("map", {
	args = { "string" },
	flag = SERVER,
	help = "load a map (same as loadmap)",
	run = changelevel,
})

--=====================================================================
-- CHAT
--=====================================================================

Config.Command("say", {
	args = { "rest" },
	flag = SERVER,
	help = "print a line in everyone's console",
	run = function(ctx, message)
		local who = (ctx and ctx.player and ctx.player.Name) or "Console"
		Glacier.Broadcast(("%s : %s"):format(who, message))
		return true
	end,
})

Config.Command("say_team", {
	args = { "rest" },
	flag = SERVER,
	help = "print a line in your team's consoles only",
	run = function(ctx, message)
		local plr = ctx and ctx.player
		if not plr then return false, "say_team needs a player" end
		if not plr.Team then return false, "you're not on a team" end

		local line = ("(TEAM) %s : %s"):format(plr.Name, message)
		for _, mate in ipairs(Glacier.PlayersOnTeam(plr.Team)) do
			Glacier.Tell(mate, line)
		end
		return true
	end,
})

--=====================================================================
-- STATUS
--=====================================================================
-- CS's `status`, which is a ROSTER -- who is here, on what side, alive or not.
-- sv_status next door is the gamemode's view (phase, round, score); the two
-- answer different questions and both are worth having.

local function pingOf(plr)
	local ok, ms = pcall(function() return plr:GetNetworkPing() * 1000 end)
	return ok and math.floor(ms) or -1
end

Config.Command("status", {
	args = {},
	flag = SERVER,
	help = "list who's connected, their team, ping and health",
	run = function(ctx)
		local _, mapName = Glacier.CurrentMap()
		local players = Players:GetPlayers()

		local lines = {
			("version : Glacier %s"):format(Glacier.Version),
			("map     : %s"):format(mapName or "<none>"),
			("gamemode: %s%s"):format(Config.Get("mp_gamemode"),
				Config.Get("sv_cheats") and "   sv_cheats 1" or ""),
			("players : %d / %d"):format(#players, Players.MaxPlayers),
			("%-10s %-20s %-10s %5s %5s  %s"):format("# userid", "name", "team", "ping", "hp", "state"),
		}

		for _, plr in ipairs(players) do
			local hp = Glacier.HealthOf(plr)
			local alive = Glacier.IsAlive(plr)
			table.insert(lines, ("# %-8d %-20s %-10s %5d %5s  %s"):format(
				plr.UserId,
				string.sub(plr.Name, 1, 20),
				plr.Team and plr.Team.Name or "-",
				pingOf(plr),
				hp and tostring(math.floor(hp.health)) or "-",
				alive and "alive" or (hp and hp.dead and "dead" or "unloaded")))
		end

		reply(ctx, table.concat(lines, "\n"))
		return true
	end,
})
