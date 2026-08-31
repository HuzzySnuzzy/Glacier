-- ModuleScript: ReplicatedStorage.Inventory
-- Slot contents as ITEMS, not class-name strings.
--
-- The bug this exists to kill: ammo used to be a player-level field
-- (State.currentAmmo) that loadWeaponStats overwrote from stats.magSize on
-- every slot change. Ammo is a property of the WEAPON INSTANCE, not of the
-- player holding it -- which is also precisely what makes drop/pickup work,
-- since a dropped rifle has to remember it was on its last eight rounds.
--
-- AUTHORITY: on the client this is a PREDICTION. The server owns the real
-- inventory and pushes corrections; nothing here should be treated as
-- trustworthy by server code that receives it over a remote.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WeaponRegistry = require(ReplicatedStorage:WaitForChild("WeaponRegistry"))

local Inventory = {}

Inventory.SLOT_PRIMARY   = 1
Inventory.SLOT_SECONDARY = 2
Inventory.SLOT_MELEE     = 3
Inventory.SLOT_COUNT     = 3

--=====================================================================
-- ITEMS
--=====================================================================

-- id is assigned by the SERVER. A client-minted id is fine for a predicted
-- pickup but must be replaced by the server's on confirmation, or two clients
-- can end up believing they hold the same rifle.
local nextLocalId = 0
local function localId()
	nextLocalId += 1
	return "L" .. nextLocalId
end

-- opts: { ammo, reserve, id }. Omitted ammo/reserve start full.
function Inventory.NewItem(name, opts)
	local class, stats = WeaponRegistry.Resolve(name)
	if not class then
		warn("[Inventory] unknown weapon: " .. tostring(name))
		return nil
	end

	opts = opts or {}

	-- A knife has no magSize. Leaving ammo nil would make Weapons.Update read
	-- it as zero and dry-fire forever, so mark the item instead and let the
	-- fire path skip the ammo check entirely.
	local usesAmmo = type(stats.magSize) == "number"

	return {
		id       = opts.id or localId(),
		class    = class,
		usesAmmo = usesAmmo,
		ammo     = usesAmmo and (opts.ammo    or stats.magSize)    or 0,
		reserve  = usesAmmo and (opts.reserve or stats.maxReserve) or 0,
	}
end

function Inventory.Stats(item)
	return item and WeaponRegistry.Stats(item.class) or nil
end

--=====================================================================
-- SLOTS
--=====================================================================

local function slots(state)
	if not state.slots then state.slots = {} end
	return state.slots
end

-- Bumped on every structural change. Visuals watches this alongside
-- activeSlot, so dropping a rifle and picking up a different one into the
-- SAME slot still rebuilds the model and track sets.
local function touch(state)
	state.inventoryRev = (state.inventoryRev or 0) + 1
end

function Inventory.Get(state, slot)
	return slots(state)[slot]
end

function Inventory.Active(state)
	return slots(state)[state.activeSlot]
end

function Inventory.Set(state, slot, item)
	slots(state)[slot] = item
	touch(state)
	return item
end

function Inventory.Clear(state, slot)
	local old = slots(state)[slot]
	slots(state)[slot] = nil
	touch(state)
	return old
end

function Inventory.Give(state, slot, name, opts)
	local item = Inventory.NewItem(name, opts)
	if not item then return nil end
	return Inventory.Set(state, slot, item)
end

-- Which slot a class belongs in, so pickup doesn't need the caller to know.
function Inventory.SlotFor(name)
	local _, stats = WeaponRegistry.Resolve(name)
	if not stats then return nil end
	return stats.slot or Inventory.SLOT_PRIMARY
end
--=====================================================================
-- LOADOUTS
--=====================================================================

-- spec: { primary = "AK47", secondary = "Glock", melee = "Knife" }
-- Any omitted slot is left EMPTY, not left alone -- a loadout is a complete
-- statement of what the player carries, so a round-start kit can't silently
-- inherit last round's rifle.
--
-- Each entry may also be a table: { class = "AK47", ammo = 12, reserve = 30 }.
function Inventory.ApplyLoadout(state, spec)
	if type(spec) ~= "table" then return end

	local byIndex = {
		[Inventory.SLOT_PRIMARY]   = spec.primary   or spec[1],
		[Inventory.SLOT_SECONDARY] = spec.secondary or spec[2],
		[Inventory.SLOT_MELEE]     = spec.melee     or spec[3],
	}

	local s = slots(state)
	for i = 1, Inventory.SLOT_COUNT do
		local entry = byIndex[i]
		if type(entry) == "string" then
			s[i] = Inventory.NewItem(entry)
		elseif type(entry) == "table" then
			s[i] = Inventory.NewItem(entry.class, entry)
		else
			s[i] = nil
		end
	end

	-- Clear the legacy strings, or MigrateLegacy overwrites this next frame.
	state.primary, state.secondary, state.melee = nil, nil, nil

	touch(state)

	-- Select the best slot the player actually has, rather than assuming 1.
	local want = state.activeSlot
	if not s[want] then
		want = (s[Inventory.SLOT_PRIMARY]   and Inventory.SLOT_PRIMARY)
			or (s[Inventory.SLOT_SECONDARY] and Inventory.SLOT_SECONDARY)
			or (s[Inventory.SLOT_MELEE]     and Inventory.SLOT_MELEE)
			or Inventory.SLOT_PRIMARY
	end
	state.activeSlot = want

	Inventory.Pull(state)
end

--=====================================================================
-- LIVE STATE BRIDGE
--=====================================================================
-- State.currentAmmo / State.reserveAmmo stay the live working values, so the
-- HUD, Crosshair and anything else reading them needs no change. They are a
-- CACHE of the active item, not the truth.

function Inventory.Pull(state)
	local item = Inventory.Active(state)
	if not item then
		state.currentAmmo, state.reserveAmmo = 0, 0
		return nil
	end
	state.currentAmmo = item.ammo
	state.reserveAmmo = item.reserve
	return item
end

-- Call after ANY mutation of currentAmmo/reserveAmmo. Cheap (two writes), and
-- calling it eagerly rather than only on unequip means a mid-swap or a
-- disconnect can't silently discard a magazine.
function Inventory.Push(state)
	local item = Inventory.Active(state)
	if not item then return end
	item.ammo    = state.currentAmmo or 0
	item.reserve = state.reserveAmmo or 0
end

--=====================================================================
-- WIRE FORMAT
--=====================================================================

function Inventory.Serialize(item)
	if not item then return nil end
	return { id = item.id, class = item.class, ammo = item.ammo, reserve = item.reserve }
end

function Inventory.Deserialize(packet)
	if type(packet) ~= "table" then return nil end
	return Inventory.NewItem(packet.class, {
		id = packet.id, ammo = packet.ammo, reserve = packet.reserve,
	})
end

function Inventory.SerializeAll(state)
	local out = {}
	for i = 1, Inventory.SLOT_COUNT do
		out[i] = Inventory.Serialize(slots(state)[i]) or false
	end
	return out
end

function Inventory.ApplyAll(state, packet)
	if type(packet) ~= "table" then return end
	local s = slots(state)
	for i = 1, Inventory.SLOT_COUNT do
		local entry = packet[i]
		s[i] = (type(entry) == "table") and Inventory.Deserialize(entry) or nil
	end

	-- Or MigrateLegacy rebuilds from the stale strings next frame and wipes
	-- whatever the server just told us we have.
	state.primary, state.secondary, state.melee = nil, nil, nil

	touch(state)
	Inventory.Pull(state)
end
--=====================================================================
-- LEGACY BRIDGE
--=====================================================================
-- Whatever currently assigns State.primary / .secondary / .melee as strings
-- keeps working: those are read once and converted. Delete this, and the call
-- in Visuals.Update, once the loadout path writes items directly.

function Inventory.MigrateLegacy(state)
	local legacy = { state.primary, state.secondary, state.melee }
	local s = slots(state)
	local changed = false

	for i = 1, Inventory.SLOT_COUNT do
		local name = legacy[i]
		if type(name) == "string" and name ~= "" then
			local class = WeaponRegistry.Class(name)
			-- Only rebuild when the class actually differs, or a loadout
			-- string left in place would wipe the item's ammo every frame.
			if class and (not s[i] or s[i].class ~= class) then
				s[i] = Inventory.NewItem(class)
				changed = true
			end
		elseif s[i] and name == "" then
			s[i] = nil
			changed = true
		end
	end

	if changed then touch(state) end
	return changed
end

return Inventory