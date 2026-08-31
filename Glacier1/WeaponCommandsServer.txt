-- Script: WeaponCommandsServer
-- Child of Glacier1
--
-- Console overrides for a player's loadout. Server-side because GiveLoadout is
-- server-authoritative -- a client-side command would only change what the
-- client thinks it's holding, and the first server hit-reg would disagree.
--
--   primary negev      -- swap only the primary, keep the rest
--   secondary usp
--   melee knife
--   noweapons          -- clear all three, releases the lock
--
-- Setting any slot raises sv_lockLoadout, which stops the gamemode re-arming
-- you on your next kill or spawn. Without that, INSTANT_UPGRADE hands you the
-- ladder weapon back roughly one kill later and the override looks broken.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config      = require(ReplicatedStorage:WaitForChild("Config"))
local giveloadout = ReplicatedStorage:WaitForChild("GiveLoadout")

local setPlayerDefaultLoadout = ReplicatedStorage:WaitForChild("setPlayerDefaultLoadout")

-- The sentinel an empty slot carries, matching GunGameWeaponCycle. This is a
-- string rather than nil because the loadout table is serialised across the
-- remote boundary and a nil field would collapse the table's shape.
local EMPTY = "Non"

--=====================================================================
-- Weapon name resolution
--=====================================================================
-- WeaponRegistry does case-insensitive lookup, which is the whole point at a
-- console prompt -- nobody types "M4A1-S" with the right capitalisation. The
-- fallback exists so this script still works if the registry moves or hasn't
-- loaded; it just resolves against the template names in ReplicatedStorage.

local WeaponRegistry
do
	local module = ReplicatedStorage:FindFirstChild("WeaponRegistry")
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(require, module)
		if ok then WeaponRegistry = result end
	end
end

-- Returns the CANONICAL name (correctly cased), or nil plus a reason.
local function resolveWeapon(query)
	if type(query) ~= "string" or query == "" then
		return nil, "expected a weapon name"
	end

	-- Explicit empty. Lets you clear one slot without clearing the others:
	-- `secondary none` leaves your primary alone.
	local lower = string.lower(query)
	if lower == "none" or lower == "non" or lower == "-" or lower == EMPTY:lower() then
		return EMPTY
	end

	if WeaponRegistry then
		-- Adjust this line if your registry exposes a different entry point;
		-- everything else in this file goes through resolveWeapon.
		local resolver = WeaponRegistry.Resolve or WeaponRegistry.Get or WeaponRegistry.Find
		if resolver then
			local ok, result = pcall(resolver, query)
			if ok and result then
				return (type(result) == "table" and result.name) or tostring(result)
			end
		end
	end

	-- Fallback: match a template in ReplicatedStorage, case-insensitively.
	for _, child in ipairs(ReplicatedStorage:GetChildren()) do
		if string.lower(child.Name) == lower then return child.Name end
	end

	return nil, ("no weapon named '%s'"):format(query)
end

--=====================================================================
-- Loadout state
--=====================================================================
-- A loadout is all three slots at once -- GiveLoadout takes the whole table,
-- so overriding one slot means reading the other two first. GT holds the
-- gamemode's view of them; this cache holds ours, seeded from GT the first
-- time a player is touched so an override composes on top of whatever the
-- ladder last gave them rather than resetting the other slots.

local cache = {}   -- [Player] = { primary, secondary, melee }

-- GT field names vary by gamemode. Try the likely ones and fall back to EMPTY;
-- trim this list to the single correct name once you've confirmed it.
local FIELD_CANDIDATES = {
	primary   = { "weapon_primary",   "primary",   "Primary" },
	secondary = { "weapon_secondary", "secondary", "Secondary" },
	melee     = { "weapon_melee",     "melee",     "Melee" },
}

local function readGT(player, slot)
	local GT = player:FindFirstChild("GT")
	if not GT then return nil end

	for _, name in ipairs(FIELD_CANDIDATES[slot]) do
		local value = GT:FindFirstChild(name)
		if value and type(value.Value) == "string" and value.Value ~= "" then
			return value.Value
		end
	end
	return nil
end

local function getLoadout(player)
	local existing = cache[player]
	if existing then return existing end

	local built = {
		primary   = readGT(player, "primary")   or EMPTY,
		secondary = readGT(player, "secondary") or EMPTY,
		melee     = readGT(player, "melee")     or EMPTY,
	}
	cache[player] = built
	return built
end

local function apply(player, loadout)
	-- Mirror into GT first so anything reading the config sees the truth
	-- before the weapon actually changes hands.
	setPlayerDefaultLoadout:Fire(player, loadout.primary, loadout.secondary, loadout.melee)

	-- Only arm a live body. GiveLoadout on a dead player is a no-op at best;
	-- the GT write above means the next spawn picks it up regardless.
	local body = workspace:FindFirstChild(player.UserId .. "RawBody")
	if body then giveloadout:Fire(player, loadout) end

	return body ~= nil
end

Players.PlayerRemoving:Connect(function(player) cache[player] = nil end)

--=====================================================================
-- Clearing
--=====================================================================
-- Fired by the gamemode at round start so a leftover override doesn't carry
-- into a fresh round. Safe in ReplicatedStorage: BindableEvents never cross
-- the network boundary.

local ClearLoadoutOverrides = Instance.new("BindableEvent")
ClearLoadoutOverrides.Name = "ClearLoadoutOverrides"
ClearLoadoutOverrides.Parent = ReplicatedStorage

ClearLoadoutOverrides.Event:Connect(function()
	table.clear(cache)
	if Config.Get("sv_lockLoadout") then Config.Set("sv_lockLoadout", false, true) end
end)

--=====================================================================
-- Commands
--=====================================================================
-- CHEAT because handing yourself a Negev mid-round is exactly what sv_cheats
-- gates. REPLICATED because the client console has to forward the line here
-- rather than running it in its own VM, where GiveLoadout doesn't exist.

local FLAG = Config.FCVAR.CHEAT + Config.FCVAR.REPLICATED

local function reply(ctx, text, isError)
	if ctx and type(ctx.reply) == "function" then
		ctx.reply(text, isError)
	elseif isError then warn(text) else print(text) end
end

-- Every slot command is the same three steps with a different key, so they
-- share one body. Writing them out separately would be three chances to fix a
-- bug in two places.
local function setSlot(slot)
	return function(ctx, query)
		local player = ctx and ctx.player
		if not player then
			return false, ("%s needs a player; run it from a console, not a server script"):format(slot)
		end

		local name, reason = resolveWeapon(query)
		if not name then return false, reason end

		local loadout = getLoadout(player)
		loadout[slot] = name

		-- Raised before apply: the gamemode's own re-arm can fire off the back
		-- of GiveLoadout, and it needs to see the lock already up.
		if not Config.Get("sv_lockLoadout") then
			Config.Set("sv_lockLoadout", true, true)
		end

		local armed = apply(player, loadout)
		reply(ctx, ("[Loadout] %s = %s%s"):format(
			slot, name, armed and "" or "  (queued; you're not alive)"))
		return true
	end
end

Config.Command("primary", {
	args = { "string" },
	flag = FLAG,
	help = "override your primary weapon; 'none' to clear the slot",
	run = setSlot("primary"),
})

Config.Command("secondary", {
	args = { "string" },
	flag = FLAG,
	help = "override your secondary weapon; 'none' to clear the slot",
	run = setSlot("secondary"),
})

Config.Command("melee", {
	args = { "string" },
	flag = FLAG,
	help = "override your melee weapon; 'none' to clear the slot",
	run = setSlot("melee"),
})

Config.Command("noweapons", {
	args = {},
	flag = FLAG,
	help = "clear all three slots and release the loadout lock",
	run = function(ctx)
		local player = ctx and ctx.player
		if not player then return false, "noweapons needs a player" end

		local loadout = { primary = EMPTY, secondary = EMPTY, melee = EMPTY }
		cache[player] = loadout
		apply(player, loadout)

		-- Released, not raised. noweapons is how you get back to normal, so
		-- leaving the lock up would mean the gamemode never re-arms you and
		-- you'd stay empty-handed for the rest of the round.
		if Config.Get("sv_lockLoadout") then
			Config.Set("sv_lockLoadout", false, true)
		end

		reply(ctx, "[Loadout] cleared; gamemode will re-arm on next spawn")
		return true
	end,
})

Config.Command("loadout", {
	args = {},
	flag = Config.FCVAR.REPLICATED,
	help = "print your current loadout",
	run = function(ctx)
		local player = ctx and ctx.player
		if not player then return false, "loadout needs a player" end

		local l = getLoadout(player)
		reply(ctx, ("[Loadout] primary %s | secondary %s | melee %s%s"):format(
			l.primary, l.secondary, l.melee,
			Config.Get("sv_lockLoadout") and "  (LOCKED)" or ""))
		return true
	end,
})