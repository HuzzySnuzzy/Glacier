-- Script: FallDamageServer
-- Parent: Glacier1
--
-- The client reports a landing speed; this decides what it costs.
--
-- WHY THE CLIENT REPORTS IT: movement is client-predicted and the server's copy
-- of the RawBody never moves, so the server cannot see a landing at all. The
-- impact exists in exactly one place. Trusting it is bounded -- the number can
-- only ever hurt the player who sent it, and it is clamped to a speed no fall
-- in this engine can exceed.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config  = require(ReplicatedStorage:WaitForChild("Config"))
local Glacier = require(ReplicatedStorage:WaitForChild("Glacier"))

local FallDamage = ReplicatedStorage:FindFirstChild("FallDamage")
if not FallDamage then
	FallDamage = Instance.new("RemoteEvent")
	FallDamage.Name = "FallDamage"
	FallDamage.Parent = ReplicatedStorage
end

-- One landing per player per this many seconds. A landing is a discrete event;
-- anything faster is a held key or a broken client, and either way the second
-- report is not a second fall.
local LAND_INTERVAL = 0.25
local lastLanding = {}

Players.PlayerRemoving:Connect(function(plr) lastLanding[plr] = nil end)

-- Returns the damage a landing at this speed costs, exactly as Source does it:
-- nothing under the safe speed, then linear up to the fatal speed, which is
-- worth precisely 100 damage. Source's endpoints are 580 and 1024 units/s
-- (52.7 and 93.1 studs/s), so the slope is 100 / (1024 - 580) per unit.
local function damageFor(speed)
	local safe = Config.Get("sv_falldamage_safe") or 52.7
	if speed <= safe then return 0 end

	-- Guarded: a fatal speed at or under the safe one would divide by zero or
	-- flip the curve, and that is a plausible typo at a console.
	local fatal = math.max(Config.Get("sv_falldamage_fatal") or 93.1, safe + 0.01)

	local damage = (speed - safe) * (100 / (fatal - safe))
	return damage * (Config.Get("sv_falldamage_scale") or 1)
end

FallDamage.OnServerEvent:Connect(function(plr, speed)
	if not Config.Get("sv_falldamage") then return end
	if type(speed) ~= "number" or speed ~= speed then return end   -- NaN
	if not Glacier.IsAlive(plr) then return end

	local now = os.clock()
	if lastLanding[plr] and now - lastLanding[plr] < LAND_INTERVAL then return end
	lastLanding[plr] = now

	-- Clamped to terminal velocity: the number came from a client, and this is
	-- the fastest anything in this engine can be moving downward.
	speed = math.clamp(speed, 0, (Config.Get("sv_maxfallspeed") or 181) * 1.1)

	local damage = damageFor(speed)
	if damage <= 0 then return end

	-- Through Health.Damage with a leg hitgroup, which is how CS models it:
	-- kevlar does not cover your legs, so armour never absorbs a fall.
	Glacier.Damage(plr, damage, { hitPart = "Left Leg" })
end)

--=====================================================================
-- COMMANDS
--=====================================================================

Config.Command("falldamage_test", {
	args = { "number" },
	flag = Config.FCVAR.REPLICATED + Config.FCVAR.CHEAT,
	help = "what a landing at this speed (studs/s) would cost",
	run = function(ctx, speed)
		local damage = damageFor(speed)
		local text = ("%.1f damage"):format(damage)
		if damage >= 100 then text = text .. " (fatal from full health)" end
		if ctx and ctx.reply then
			ctx.reply(("[falldamage] %.1f studs/s -> %s"):format(speed, text))
		end
		return true
	end,
})
