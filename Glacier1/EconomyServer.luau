-- Script: EconomyServer
-- Parent: Glacier1
--
-- WHO HAS HOW MUCH, AND WHAT THEY MAY SPEND IT ON.
--
-- The rules are in ReplicatedStorage.Economy and are shared with the buy
-- menu, so the menu greys out exactly what this refuses and nothing else.
-- What lives HERE is the three things a client cannot be trusted with: the
-- balance, whether the purchase happened, and what the world looks like
-- around the player at the moment they ask.
--
-- MONEY IS AN ATTRIBUTE on the Player. It replicates, so the HUD reads it
-- without a remote; it is server-written, so a client setting it is a client
-- lying to itself; and it survives anything that rebuilds the character,
-- which a field on the body would not.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config   = require(ReplicatedStorage:WaitForChild("Config"))
local Glacier  = require(ReplicatedStorage:WaitForChild("Glacier"))
local Economy  = require(ReplicatedStorage:WaitForChild("Economy"))
local Inventory = require(ReplicatedStorage:WaitForChild("Inventory"))
local Registry = require(script.Parent:WaitForChild("Registry"))
local Health   = require(script.Parent:WaitForChild("Health"))

local FCVAR = Config.FCVAR
local SERVER = FCVAR.REPLICATED
local SERVER_CHEAT = FCVAR.REPLICATED + FCVAR.CHEAT

local function num(v, fallback)
	local n = tonumber(v)
	return n or fallback
end

--=====================================================================
-- REMOTES
--=====================================================================

local function ensureRemote(name)
	local remote = ReplicatedStorage:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = ReplicatedStorage
	end
	return remote
end

local BuyRequest = ensureRemote("BuyRequest")
local BuyReport  = ensureRemote("BuyReport")

--=====================================================================
-- THE BALANCE
--=====================================================================

local function EconomyOf(plr)
	return Economy.Clamp(plr:GetAttribute("Money"))
end

local function setMoney(plr, amount)
	plr:SetAttribute("Money", Economy.Clamp(amount))
end

-- Returns the new balance. Clamped at both ends by Economy, so nothing here
-- has to remember the cap.
local function award(plr, amount, reason)
	if not plr then return 0 end
	local before = EconomyOf(plr)
	local after = Economy.Clamp(before + num(amount, 0))
	setMoney(plr, after)

	if after ~= before and Config.mp_buyfeedback ~= false and reason then
		Glacier.Tell(plr, ("[$] %+d  %s   ($%d)"):format(after - before, reason, after))
	end
	return after
end

--=====================================================================
-- BUY ZONES
--=====================================================================
-- A part tagged BuyZone, optionally with a Team attribute naming whose it is.
--
-- A MAP WITH NONE LETS YOU BUY ANYWHERE. Every map that exists today was
-- built before this file did, and refusing every purchase on all of them
-- would be a feature nobody can use and nobody can diagnose -- it looks
-- exactly like the buy key not working. The zones are opt-in, and the moment
-- a map has one they start meaning something.
local BUY_ZONE_TAG = "BuyZone"

local function zones()
	return CollectionService:GetTagged(BUY_ZONE_TAG)
end

local function inBuyZone(plr)
	if Config.mp_buy_anywhere then return true end

	local tagged = zones()
	if #tagged == 0 then return true end   -- see above

	local position = Glacier.PositionOf(plr, "player")
	if not position then return false end

	local team = plr.Team and plr.Team.Name or nil

	for _, zone in ipairs(tagged) do
		if zone:IsA("BasePart") and zone:IsDescendantOf(workspace) then
			local owner = zone:GetAttribute("Team")
			if not owner or owner == team then
				-- The part's own box, in its own orientation: a buy zone is
				-- usually a rotated brush over a spawn, and an axis-aligned
				-- test would cover the wrong corner of it.
				local local_ = zone.CFrame:PointToObjectSpace(position)
				local half = zone.Size * 0.5
				if math.abs(local_.X) <= half.X
					and math.abs(local_.Y) <= half.Y
					and math.abs(local_.Z) <= half.Z then
					return true
				end
			end
		end
	end

	return false
end

-- Seconds of buy time left, or nil when there is no limit. nil rather than a
-- big number, because Economy.CanBuy tells "no limit" from "lots left" and
-- only one of them is a rule.
local roundStartedAt = nil

local function buyTimeLeft()
	local window = num(Config.mp_buytime, 0)
	if window <= 0 or not roundStartedAt then return nil end
	return math.max(window - (os.clock() - roundStartedAt), 0)
end

--=====================================================================
-- REFUNDS
--=====================================================================
-- The last thing you bought, for as long as you could plausibly have bought
-- it by mistake. Cleared the moment it stops being the thing you bought: you
-- fired it, you dropped it, you bought something else, or the window closed.
local lastBuy = {}

local function clearRefund(plr)
	lastBuy[plr] = nil
end

local function refundable(plr)
	local entry = lastBuy[plr]
	if not entry then return nil, "you have not bought anything" end

	local window = num(Config.mp_refundtime, 8)
	if window <= 0 then return nil, "refunds are off" end
	if os.clock() - entry.at > window then
		clearRefund(plr)
		return nil, "too late to refund that"
	end

	if not inBuyZone(plr) then return nil, "you are not in a buy zone" end
	return entry
end

--=====================================================================
-- BUYING
--=====================================================================

-- Returns ok, message. The message is worth showing either way: a refused
-- purchase that says nothing is indistinguishable from a dead key, which is
-- the same lesson the pickup path learned.
local function attemptBuy(plr, name)
	local ctx = {
		class = name,
		money = EconomyOf(plr),
		alive = Glacier.IsAlive(plr),
		inBuyZone = inBuyZone(plr),
		buyTimeLeft = buyTimeLeft(),
	}

	local ok, classOrReason, price = Economy.CanBuy(ctx)
	if not ok then return false, classOrReason end

	local class = classOrReason

	-- GEAR IS NOT A WEAPON. Armour and a defuser are attributes on the
	-- player, and handing them to GiveWeapon would look for a module that
	-- does not exist and fail in a way that reads as the price being wrong.
	if class == "kevlar" or class == "kevlarhelmet" then
		local puppet = Glacier.PuppetOf(plr)
		if not puppet then return false, "you have no body" end

		local have = puppet:GetAttribute("Armor") or 0
		local helmet = puppet:GetAttribute("Helmet") == true
		if have >= 100 and (helmet or class == "kevlar") then
			return false, "you already have armour"
		end

		puppet:SetAttribute("Armor", 100)
		if class == "kevlarhelmet" then puppet:SetAttribute("Helmet", true) end
	elseif class == "defuser" then
		if plr:GetAttribute("Defuser") then return false, "you already have a kit" end
		plr:SetAttribute("Defuser", true)
	else
		local given, why = Glacier.GiveWeapon(plr, class)
		if not given then return false, tostring(why or "could not give you that") end
	end

	award(plr, -price, nil)
	lastBuy[plr] = { class = class, price = price, at = os.clock() }

	return true, ("bought %s for $%d"):format(class, price)
end

local function attemptRefund(plr)
	local entry, why = refundable(plr)
	if not entry then return false, why end

	local class = entry.class

	if class == "kevlar" or class == "kevlarhelmet" then
		local puppet = Glacier.PuppetOf(plr)
		if puppet then
			puppet:SetAttribute("Armor", 0)
			puppet:SetAttribute("Helmet", false)
		end
	elseif class == "defuser" then
		plr:SetAttribute("Defuser", nil)
	else
		local slot = Inventory.SlotFor(class, Glacier.ActiveSlot(plr))
		if slot and Glacier.GetSlot(plr, slot) then
			Glacier.ClearSlot(plr, slot)
		end
	end

	award(plr, entry.price, nil)
	clearRefund(plr)
	return true, ("refunded %s for $%d"):format(class, entry.price)
end

local function report(plr, ok, message)
	if Config.mp_buyfeedback ~= false and message then
		Glacier.Tell(plr, "[buy] " .. tostring(message), not ok)
	end
	BuyReport:FireClient(plr, ok, message, EconomyOf(plr))
end

--=====================================================================
-- PAYOUTS
--=====================================================================

-- A KILL PAYS THE KILLER, and pays by the weapon rather than by a flat rate:
-- an AWP kill is worth a third of a pistol kill because otherwise one good
-- round funds the next five, and a knife kill is worth fifteen hundred
-- because it should change somebody's round.
local function onKilled(model, attacker, _group)
	if not attacker then return end

	local killer = Glacier.Identify(attacker)
	if typeof(killer) ~= "Instance" or not killer:IsA("Player") then return end

	-- No paying yourself, and no paying for a teammate.
	local victim = Glacier.Identify(model)
	if victim == killer then return end
	if typeof(victim) == "Instance" and victim:IsA("Player")
		and killer.Team and victim.Team and killer.Team == victim.Team then
		return
	end

	local reward = Economy.KillReward(Glacier.HeldClass(killer))
	if reward ~= 0 then
		award(killer, reward, "kill")
	end
end

Health.Killed.Event:Connect(onKilled)

--=====================================================================
-- THE API OTHER SYSTEMS USE
--=====================================================================
-- Published on Glacier so a gamemode -- including a round loop that does not
-- exist yet -- pays out without requiring this file. The loss ladder lives in
-- Economy, so a caller says who won and how many they have lost in a row and
-- never has to know the numbers.
local Economy_API = {
	Money = EconomyOf,
	Set = function(plr, amount) setMoney(plr, amount) return EconomyOf(plr) end,
	Award = award,
	Buy = attemptBuy,
	Refund = attemptRefund,
	InBuyZone = inBuyZone,

	Reset = function(plr)
		setMoney(plr, Economy.StartMoney())
		clearRefund(plr)
	end,

	-- Called by whatever owns rounds. Nothing does yet; the hook exists so
	-- that when something does, this file does not have to change.
	RoundEnd = function(plr, won, lossStreak)
		return award(plr, Economy.RoundReward(won, lossStreak),
			won and "round win" or "round loss")
	end,

	RoundStart = function()
		roundStartedAt = os.clock()
		for _, plr in ipairs(Players:GetPlayers()) do clearRefund(plr) end
	end,
}

-- Published the way every other server module publishes: a field on the
-- shared Registry. _G would be a different table per VM and would read nil
-- with no error when the producer has not run.
Registry.Economy = Economy_API

--=====================================================================
-- WIRING
--=====================================================================

Players.PlayerAdded:Connect(function(plr)
	setMoney(plr, Economy.StartMoney())
end)

for _, plr in ipairs(Players:GetPlayers()) do
	if plr:GetAttribute("Money") == nil then setMoney(plr, Economy.StartMoney()) end
end

Players.PlayerRemoving:Connect(clearRefund)

-- One request per player per this much. Buying spawns instances and moves
-- money, and the menu is a button somebody will hold down.
local lastRequest = {}
local REQUEST_INTERVAL = 0.15

BuyRequest.OnServerEvent:Connect(function(plr, action, name)
	local now = os.clock()
	if lastRequest[plr] and now - lastRequest[plr] < REQUEST_INTERVAL then return end
	lastRequest[plr] = now

	if action == "refund" then
		report(plr, attemptRefund(plr))
		return
	end

	-- Anything else is a purchase, and the NAME is the only thing the client
	-- gets to decide. Everything that could be lied about -- the price, the
	-- balance, whether they are alive, where they are standing -- is read
	-- here.
	if type(name) ~= "string" then return end
	report(plr, attemptBuy(plr, name))
end)

Players.PlayerRemoving:Connect(function(plr) lastRequest[plr] = nil end)

--=====================================================================
-- CONSOLE
--=====================================================================

Config.Command("buy", {
	args = { "string" },
	flag = SERVER,
	help = "buy a weapon or gear -- buy ak47, buy kevlarhelmet",
	run = function(ctx, name)
		local plr = ctx and ctx.player
		if not plr then return false, "buy needs a player" end

		local ok, message = attemptBuy(plr, name)
		if not ok then return false, message end
		ctx.reply(message)
	end,
})

Config.Command("refund", {
	args = {},
	flag = SERVER,
	help = "hand back the last thing you bought",
	run = function(ctx)
		local plr = ctx and ctx.player
		if not plr then return false, "refund needs a player" end

		local ok, message = attemptRefund(plr)
		if not ok then return false, message end
		ctx.reply(message)
	end,
})

Config.Command("money", {
	args = {},
	flag = SERVER,
	help = "what you have",
	run = function(ctx)
		local plr = ctx and ctx.player
		if not plr then return false, "money needs a player" end
		ctx.reply(("$%d   (buy zone: %s)"):format(EconomyOf(plr),
			inBuyZone(plr) and "yes" or "no"))
	end,
})

Config.Command("give_money", {
	args = { "number", "string?" },
	flag = SERVER_CHEAT,
	help = "add money to yourself or a named player",
	run = function(ctx, amount, who)
		local target = ctx and ctx.player
		if who then
			target = Glacier.Identify(who)
			if typeof(target) ~= "Instance" or not target:IsA("Player") then
				return false, ("no such player '%s'"):format(tostring(who))
			end
		end
		if not target then return false, "give_money needs a player" end

		ctx.reply(("%s now has $%d"):format(target.Name,
			award(target, amount, "given")))
	end,
})

Config.Command("prices", {
	args = { "string?" },
	flag = SERVER,
	help = "the price list, or the price of one thing",
	run = function(ctx, name)
		if name then
			local price = Economy.Price(name)
			if not price then return false, ("'%s' is not for sale"):format(name) end
			ctx.reply(("%s  $%d   (a kill with it pays $%d)")
				:format(Economy.Resolve(name), price, Economy.KillReward(name)))
			return
		end

		local lines = {}
		local slot
		for _, entry in ipairs(Economy.Catalogue()) do
			if entry.slot ~= slot then
				slot = entry.slot
				table.insert(lines, "-- " .. string.upper(slot))
			end
			table.insert(lines, ("  %-14s $%d"):format(entry.class, entry.price))
		end
		ctx.reply(table.concat(lines, "\n"))
	end,
})
