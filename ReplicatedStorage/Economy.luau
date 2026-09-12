-- ModuleScript: ReplicatedStorage.Economy
--
-- WHAT THINGS COST AND WHAT KILLING PAYS. CS 1.6 / CS:GO economy, as rules
-- rather than as a table of numbers somewhere in a server script.
--
-- Pure and shared: the server enforces it, the buy menu draws it, and neither
-- gets to have its own opinion about whether you can afford an AK. A menu
-- that greys out what the server would refuse -- and only that -- is the
-- whole reason this is one module.
--
-- PRICES LIVE ON THE ITEM. A weapon module declares `price` and `killReward`
-- beside its fire rate, because that is where everything else about it lives
-- and a second table keyed by class name is a second thing to keep in step.
-- The table below is the fallback for the guns that predate the field, and
-- it is a fallback rather than the source: anything it holds that the module
-- also holds, the module wins.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("ItemRegistry"))

local Economy = {}

local function num(v, fallback)
	local n = tonumber(v)
	return n or fallback
end

--=====================================================================
-- THE PRICE LIST
--=====================================================================
-- CS:GO's, for the guns that have a counterpart, and keyed by the canonical
-- class the registry resolves to. Everything here is a FALLBACK -- see the
-- header -- so adding a gun is a `price` field on its module and nothing in
-- this file.
Economy.FALLBACK_PRICES = {
	-- Pistols
	glock       = 200,
	usp         = 200,
	deagle      = 700,
	p250        = 300,
	fiveseven   = 500,

	-- Rifles
	ak47        = 2700,
	m4a1        = 3100,
	awp         = 4750,
	famas       = 2050,
	galil       = 1800,

	-- SMGs
	mp5         = 1500,
	mac10       = 1050,
	ump45       = 1200,
	p90         = 2350,

	-- Heavy
	nova        = 1050,
	xm1014      = 2000,
	negev       = 1700,
	m249        = 5200,

	-- Gear. Not weapons, and the buy menu is the only thing that cares which.
	kevlar      = 650,
	kevlarhelmet = 1000,
	defuser     = 400,

	-- Grenades
	hegrenade   = 300,
	flashbang   = 200,
	smokegrenade = 300,
	molotov     = 400,
	incendiary  = 600,
	decoy       = 50,
}

-- What a kill with each is worth. The interesting ones are the two that are
-- nothing like their price: the AWP pays a third of a pistol kill because
-- otherwise one good round funds the next five, and a knife pays fifteen
-- hundred because a knife kill should change somebody's round.
Economy.FALLBACK_KILL_REWARDS = {
	awp         = 100,
	knife       = 1500,
	hegrenade   = 300,
	nova        = 900,
	xm1014      = 900,
	mac10       = 600,
	mp5         = 600,
	ump45       = 600,
	p90         = 300,
	zeus        = 0,
}

-- Everything else. A rifle or a pistol kill is three hundred dollars, which
-- is the number the whole economy is calibrated against.
Economy.DEFAULT_KILL_REWARD = 300

--=====================================================================
-- LOOKUP
--=====================================================================

-- The canonical class, or nil. Buying is by name and names arrive from a
-- console line or a button, so this is the one place that decides whether
-- "AK47", "ak-47" and "ak47" are the same gun.
function Economy.Resolve(name)
	if type(name) ~= "string" or name == "" then return nil end

	local class = ItemRegistry.Class(name)
	if class then return class end

	-- Gear is not an item in the registry -- there is no kevlar module to
	-- hold and no kevlar to draw -- so the price list is the whole of what it
	-- is. Matched case-insensitively for the same reason the registry is.
	local lowered = string.lower(name)
	if Economy.FALLBACK_PRICES[lowered] then return lowered end
	return nil
end

-- What it costs, or nil if it is not for sale. Zero IS a price -- a knife
-- costs nothing and is still buyable -- so the absence of one is nil rather
-- than 0, and callers have to tell the two apart.
function Economy.Price(name)
	local class = Economy.Resolve(name)
	if not class then return nil end

	local stats = ItemRegistry.Stats(class)
	if type(stats) == "table" and type(stats.price) == "number" then
		return stats.price
	end

	return Economy.FALLBACK_PRICES[class]
end

-- What killing with it pays.
function Economy.KillReward(name)
	local class = Economy.Resolve(name)
	if not class then return Economy.DEFAULT_KILL_REWARD end

	local stats = ItemRegistry.Stats(class)
	if type(stats) == "table" and type(stats.killReward) == "number" then
		return stats.killReward
	end

	return Economy.FALLBACK_KILL_REWARDS[class] or Economy.DEFAULT_KILL_REWARD
end

-- Everything for sale, as { class, price, slot }, sorted by price within a
-- slot. What the buy menu enumerates, so a gun added to the registry with a
-- price appears in the menu without the menu being told.
function Economy.Catalogue()
	local out = {}
	local seen = {}

	local function add(class)
		if seen[class] then return end
		local price = Economy.Price(class)
		if not price then return end
		seen[class] = true

		local stats = ItemRegistry.Stats(class)
		table.insert(out, {
			class = class,
			price = price,
			slot = (type(stats) == "table" and stats.slot) or "gear",
			-- A thing with no module behind it is gear: armour, a defuser.
			-- The menu groups on this and nothing else has to know.
			buyable = true,
		})
	end

	for class in pairs(ItemRegistry.All()) do add(class) end
	for class in pairs(Economy.FALLBACK_PRICES) do add(class) end

	table.sort(out, function(a, b)
		if a.slot ~= b.slot then return a.slot < b.slot end
		if a.price ~= b.price then return a.price < b.price end
		return a.class < b.class
	end)
	return out
end

--=====================================================================
-- THE RULES
--=====================================================================

function Economy.MaxMoney()
	return num(Config.mp_maxmoney, 16000)
end

function Economy.StartMoney()
	return math.clamp(num(Config.mp_startmoney, 800), 0, Economy.MaxMoney())
end

-- Nobody holds more than the cap and nobody holds less than nothing.
function Economy.Clamp(money)
	return math.clamp(math.floor(num(money, 0)), 0, Economy.MaxMoney())
end

-- THE LOSS BONUS, which is the single most important number in CS and the
-- one people are most surprised to find is a ladder rather than a constant.
--
-- A team that has just lost gets a base amount; each CONSECUTIVE loss after
-- that adds a step, to a cap. That is what stops a team that lost the pistol
-- round from being dead for the next twenty minutes, and it is why breaking
-- an opponent's loss streak matters as much as the round itself.
--
-- `streak` is how many in a row they have now lost, counting this one, so
-- the first loss is 1.
function Economy.LossBonus(streak)
	local base = num(Config.mp_lossbase, 1400)
	local step = num(Config.mp_lossstep, 500)
	local cap = num(Config.mp_lossmax, 3400)

	local losses = math.max(math.floor(num(streak, 1)), 1)
	return math.clamp(base + step * (losses - 1), 0, cap)
end

function Economy.WinBonus()
	return num(Config.mp_winmoney, 3250)
end

-- What a round pays out, from whether you won it and how many you have lost
-- in a row. One function so a gamemode never has to know the ladder.
function Economy.RoundReward(won, lossStreak)
	if won then return Economy.WinBonus() end
	return Economy.LossBonus(lossStreak)
end

--=====================================================================
-- WHETHER YOU MAY BUY IT
--=====================================================================

-- Returns ok, reason. The reason is shown, so it says which of the several
-- ways a purchase can be refused this one was -- "you can't afford that" and
-- "you're not in a buy zone" are the same silence otherwise, and that silence
-- reads as a broken key.
--
-- The caller supplies the CONTEXT rather than this module reaching for it:
-- the server knows whether the player is alive and where they are standing,
-- and the buy menu knows neither and should still be able to grey a row out
-- for the reasons it does know.
function Economy.CanBuy(ctx)
	ctx = ctx or {}

	local class = Economy.Resolve(ctx.class)
	if not class then
		return false, ("there is no such thing as '%s'"):format(tostring(ctx.class))
	end

	local price = Economy.Price(class)
	if not price then
		return false, ("%s is not for sale"):format(class)
	end

	if ctx.alive == false then
		return false, "you have to be alive to buy"
	end

	if ctx.inBuyZone == false then
		return false, "you are not in a buy zone"
	end

	if ctx.buyTimeLeft ~= nil and ctx.buyTimeLeft <= 0 then
		return false, "buy time is over"
	end

	local money = num(ctx.money, 0)
	if money < price then
		return false, ("you need $%d and have $%d"):format(price, money)
	end

	return true, class, price
end

return Economy
