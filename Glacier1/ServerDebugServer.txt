-- Script: ServerDebugServer
-- Parent: Glacier1
--
-- Snapshots server state and pushes it to clients for the debug HUD. Fired
-- per-client rather than broadcast, because ping is per-client and the
-- per-player roster block is cheat-gated.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local Stats             = game:GetService("Stats")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Registry = require(script.Parent:WaitForChild("Registry"))

local Remote = ReplicatedStorage:FindFirstChild("ServerDebug")
if not Remote then
	-- Unreliable: these are periodic snapshots, so a dropped one is replaced
	-- 200ms later. No point paying for ordered delivery.
	Remote = Instance.new("UnreliableRemoteEvent")
	Remote.Name = "ServerDebug"
	Remote.Parent = ReplicatedStorage
end

--=====================================================================
-- SERVER FPS
--=====================================================================

local frameAccum, frameCount, serverFps = 0, 0, 0

RunService.Heartbeat:Connect(function(dt)
	frameAccum += dt
	frameCount += 1
	if frameAccum >= 0.5 then
		serverFps = frameCount / frameAccum
		frameAccum, frameCount = 0, 0
	end
end)

--=====================================================================
-- SNAPSHOT
--=====================================================================

local startClock = os.clock()

local function pingOf(plr)
	local ok, ms = pcall(function() return plr:GetNetworkPing() * 1000 end)
	return ok and math.floor(ms) or -1
end

local function baseSnapshot()
	local gm = Registry.Gamemode and Registry.Gamemode() or nil

	return {
		uptime = os.clock() - startClock,
		fps    = serverFps,
		mem    = Stats:GetTotalMemoryUsageMb(),
		instances = workspace:GetAttribute("InstanceCount"),  -- see note below
		players = #Players:GetPlayers(),
		mode   = gm and (gm.label or gm.name) or "none",
		status = gm and gm.status or nil,
		cheats = Config.Values.sv_cheats,
	}
end

-- Per-player rows expose who's alive and where -- that's a wallhack if handed
-- to everyone. Cheat-gated, and only the requesting client's own row is sent
-- when cheats are off.
local function rosterRows(forPlayer)
	local rows = {}
	local cheats = Config.Values.sv_cheats

	for _, plr in ipairs(Players:GetPlayers()) do
		if cheats or plr == forPlayer then
			local Lifecycle = _G.GlacierLifecycle
			table.insert(rows, {
				name  = plr.Name,
				team  = plr.Team and plr.Team.Name or "-",
				ping  = pingOf(plr),
				alive = Lifecycle and Lifecycle.IsAlive(plr) or false,
			})
		end
	end

	table.sort(rows, function(a, b) return a.name < b.name end)
	return rows
end

Config.Command("sv_status", {
	args = {},
	flag = Config.FCVAR.CLIENT,
	help = "dump server state to your console",
	run = function(ctx)
		local snap = baseSnapshot()
		local ConsoleLog = ReplicatedStorage:FindFirstChild("ConsoleLog")

		local lines = {
			("%s | fps %.1f | mem %.0fMB | players %d")
				:format(snap.mode, snap.fps, snap.mem, snap.players),
		}

		if snap.status then
			local st = snap.status
			table.insert(lines, ("phase=%s round=%d/%d  T%d:CT%d  remaining=%s")
				:format(tostring(st.phase), st.round or 0, st.maxRounds or 0,
					st.score and st.score.T or 0, st.score and st.score.CT or 0,
					st.remaining and ("%.1fs"):format(st.remaining) or "none"))
			if st.alive then
				table.insert(lines, ("alive T %d/%d  CT %d/%d"):format(
					st.alive.T or 0, (st.teams and st.teams.T) or 0,
					st.alive.CT or 0, (st.teams and st.teams.CT) or 0))
			end
		else
			table.insert(lines, "no gamemode status (Mode.Status missing?)")
		end

		for _, line in ipairs(lines) do
			print("[sv_status] " .. line)
			if ConsoleLog and ctx.player then
				ConsoleLog:FireClient(ctx.player, line, false)
			end
		end
		return true
	end,
})

task.spawn(function()
	while true do
		local hz = Config.Values.sv_debugSnapshotHz
		if hz <= 0 then
			task.wait(1)
		else
			local snap = baseSnapshot()
			local rows = rosterRows(nil)   -- built once, ping patched per client

			for _, plr in ipairs(Players:GetPlayers()) do
				snap.ping = pingOf(plr)
				snap.roster = Config.Values.sv_cheats and rows or rosterRows(plr)
				Remote:FireClient(plr, snap)
			end

			task.wait(1 / hz)
		end
	end
end)