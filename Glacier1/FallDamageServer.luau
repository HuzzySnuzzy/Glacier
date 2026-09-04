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

-- Returns the damage a landing at this speed costs, as CS does it: nothing at
-- all under the threshold, then linear in the excess.
local function damageFor(speed)
	local threshold = Config.Get("sv_falldamage_threshold") or 52.7
	if speed <= threshold then return 0 end

	local fatal = Config.Get("sv_falldamage_fatal") or 0
	if fatal > 0 and speed >= fatal then return math.huge end

	return (speed - threshold) * (Config.Get("sv_falldamage_scale") or 0.665)
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

	if damage == math.huge then
		Glacier.Kill(plr, nil, "fall")
		return
	end

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
		local text = (damage == math.huge) and "fatal" or ("%.1f damage"):format(damage)
		if ctx and ctx.reply then
			ctx.reply(("[falldamage] %.1f studs/s -> %s"):format(speed, text))
		end
		return true
	end,
})
