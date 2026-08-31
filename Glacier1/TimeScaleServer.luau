-- Script: TimescaleServer
-- child of Glacier1
--
-- Ramps host_timescale over real time. Owns the cvar exclusively: anything
-- that wants slow-mo fires the bindable rather than writing the cvar directly,
-- so two effects can't fight over it mid-ramp.
--
--   ReplicatedStorage.SetTimescale:Fire(0.25, 1.2)  -- ease to 0.25 over 1.2s
--   ReplicatedStorage.SetTimescale:Fire(1, 0.6)     -- ease back
--   ReplicatedStorage.SetTimescale:Fire(1, 0)       -- snap, cancels any ramp

local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

-- Bumped on every new request. An in-flight ramp captures the value it started
-- under and aborts the moment it no longer matches -- same generation-guard
-- pattern as roundId, and for the same reason: a ramp scheduled just before a
-- round cycles must not keep writing during the next round.
local generation = 0

local function clampScale(v)
	local min = Config.Get("host_timescaleMin") or 0.05
	return math.clamp(tonumber(v) or 1, min, 10)
end

-- Smoothstep. Linear reads as a mechanical slider; this eases out of 1.0 and
-- settles into the target, which is what sells the "the world is stopping"
-- read rather than "someone turned a dial".
local function ease(t)
	return t * t * (3 - 2 * t)
end

local function apply(value)
	-- Server-side Set skips the permission block and fires
	-- OnServerVarChanged, which is what pushes it to every client.
	Config.Set("host_timescale", value, true)
end

local function ramp(target, duration)
	generation += 1
	local myGen = generation

	target = clampScale(target)

	if not duration or duration <= 0 then
		apply(target)
		return
	end

	local from = Config.Get("host_timescale") or 1
	if math.abs(from - target) < 1e-3 then
		apply(target)
		return
	end

	task.spawn(function()
		-- os.clock, deliberately. Driving this off State.gameTime would mean
		-- the ramp slows itself down as timescale falls, decelerating
		-- asymptotically and never arriving at the target.
		local t0 = os.clock()
		local hz = math.max(1, Config.Get("host_timescaleHz") or 20)
		local step = 1 / hz

		while true do
			if generation ~= myGen then return end   -- superseded

			local alpha = (os.clock() - t0) / duration
			if alpha >= 1 then break end

			apply(from + (target - from) * ease(alpha))
			task.wait(step)
		end

		if generation ~= myGen then return end
		apply(target)   -- land exactly on it; the loop never quite does
	end)
end

--=====================================================================
-- BINDABLE
--=====================================================================
-- Safe in ReplicatedStorage: BindableEvents don't cross the network boundary,
-- so a client firing this reaches nothing.

local SetTimescale = Instance.new("BindableEvent")
SetTimescale.Name = "SetTimescale"
SetTimescale.Parent = ReplicatedStorage

SetTimescale.Event:Connect(function(target, duration)
	ramp(target, duration)
end)

--=====================================================================
-- CONSOLE
--=====================================================================

Config.Command("timescale", {
	args = { "number", "number" },
	flag = Config.FCVAR.CHEAT,
	help = "ramp host_timescale to <target> over <seconds>",
	run = function(ctx, target, duration)
		ramp(target, duration)
		return true
	end,
})

--=====================================================================
-- SAFETY
--=====================================================================
-- An error inside a ramp, or a script restart in Studio, can strand the server
-- at 0.25 with no ramp running to bring it back. This notices a stuck value
-- and restores it rather than leaving the whole server in slow motion.

local STUCK_AFTER = 30   -- seconds of unchanged sub-1 timescale before we intervene

task.spawn(function()
	local heldSince = nil

	while true do
		task.wait(5)

		local current = Config.Get("host_timescale") or 1
		local ramping = false

		-- A live ramp writes at host_timescaleHz, so if the value is still
		-- moving we leave it alone. Cheap check: sample twice.
		local before = current
		task.wait(0.2)
		ramping = (Config.Get("host_timescale") ~= before)

		if current < 0.999 and not ramping then
			heldSince = heldSince or os.clock()
			if os.clock() - heldSince > STUCK_AFTER then
				warn("[Timescale] stuck at %.3f for %ds; restoring to 1")
					:format(current, STUCK_AFTER)
				ramp(1, 0)
				heldSince = nil
			end
		else
			heldSince = nil
		end
	end
end)