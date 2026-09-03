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
--
-- WHY THIS NO LONGER GOES THROUGH GiveLoadout: it used to read the other two
-- slots out of GT, then hand all three to GiveLoadout, which rebuilds every
-- slot from scratch. Two things fell out of that. The GT field names it read
-- ("weapon_primary") never matched the ones Player_Gametuner writes
-- ("weapon_Primary") and FindFirstChild is case-sensitive, so both other slots
-- read back as EMPTY and `primary ak47` silently disarmed you. Even with the
-- names right, rebuilding a slot mints a fresh item, so the untouched slots
-- lost their ammo counts. Lifecycle.GiveWeapon touches ONE slot, so neither
-- can happen.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config      = require(ReplicatedStorage:WaitForChild("Config"))
local Glacier     = require(ReplicatedStorage:WaitForChild("Glacier"))
local Inventory   = require(ReplicatedStorage:WaitForChild("Inventory"))

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

-- Player_Gametuner writes weapon_Primary / weapon_Secondary / weapon_Melee.
-- FindFirstChild is case-sensitive, so the capital matters -- the lowercase
-- spellings that used to lead this list never matched anything. The other
-- spellings stay as a fallback for a gamemode that writes its own.
local FIELD_CANDIDATES = {
	primary   = { "weapon_Primary",   "weapon_primary",   "primary",   "Primary" },
	secondary = { "weapon_Secondary", "weapon_secondary", "secondary", "Secondary" },
	melee     = { "weapon_Melee",     "weapon_melee",     "melee",     "Melee" },
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

local SLOT_INDEX = {
	primary   = Inventory.SLOT_PRIMARY,
	secondary = Inventory.SLOT_SECONDARY,
	melee     = Inventory.SLOT_MELEE,
}

-- What the player is ACTUALLY holding wins over the cache and over GT. The
-- live inventory is the only one of the three that can't be stale, and it is
-- the thing every other slot in this file must be left alone.
local function getLoadout(player)
	local built = {
		primary   = EMPTY,
		secondary = EMPTY,
		melee     = EMPTY,
	}

	for name, index in pairs(SLOT_INDEX) do
		local item = Glacier.GetSlot(player, index)
		built[name] = (item and item.class)
			or cache[player] and cache[player][name]
			or readGT(player, name)
			or EMPTY
	end

	cache[player] = built
	return built
end

-- Mirrors the whole loadout into GT so the gamemode's view matches, WITHOUT
-- re-arming anything: the slot itself was already changed by the caller.
local function mirrorToGT(player, loadout)
	setPlayerDefaultLoadout:Fire(player, loadout.primary, loadout.secondary, loadout.melee)
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
	local index = SLOT_INDEX[slot]

	return function(ctx, query)
		local player = ctx and ctx.player
		if not player then
			return false, ("%s needs a player; run it from a console, not a server script"):format(slot)
		end

		local name, reason = resolveWeapon(query)
		if not name then return false, reason end

		-- A weapon locked to another slot is refused rather than redirected.
		-- `secondary ak47` asked for something that cannot happen, and quietly
		-- putting the rifle in slot 1 would look like the command misfired.
		if name ~= EMPTY then
			local ok, why = Inventory.CanUseSlot(name, index)
			if not ok then return false, why end
		end

		-- Raised first: the gamemode's re-arm can fire off the back of the
		-- inventory change, and it needs to see the lock already up.
		if not Config.Get("sv_lockLoadout") then
			Config.Set("sv_lockLoadout", true, true)
		end

		if name == EMPTY then
			Glacier.ClearSlot(player, index)   -- already empty is not an error
		else
			-- ONE slot. The other two keep their weapons AND their ammo.
			local ok, why = Glacier.GiveWeapon(player, name, nil, index)
			if not ok then return false, tostring(why) end
		end

		mirrorToGT(player, getLoadout(player))

		-- The inventory is server-side, so this lands whether or not you have a
		-- body; only the viewmodel waits for one.
		reply(ctx, ("[Loadout] %s = %s%s"):format(
			slot, name, Glacier.IsAlive(player) and "" or "  (queued; you're not alive)"))
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
		for _, index in pairs(SLOT_INDEX) do
			Glacier.ClearSlot(player, index)
		end
		cache[player] = loadout
		mirrorToGT(player, loadout)

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