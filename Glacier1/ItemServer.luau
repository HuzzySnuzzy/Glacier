-- Script: ItemServer
-- Parent: Glacier1
--
-- What an item DOES, decided on the server.
--
--   UseItem:FireServer(slot)   -- the client asks; this decides and performs
--
-- WHY THIS EXISTS AT ALL. Item behaviour used to be four optional functions
-- on a weapon module -- OnFire, OnEquip, OnReloadStart, OnReloadEnd -- and
-- every one of them ran on the CLIENT, because that is where the fire state
-- machine lives. That is fine for a muzzle flash and useless for an apple:
-- health, hunger and the contents of your own inventory are the server's, and
-- a client hook that tried to change them would change nothing at all on the
-- one machine that matters.
--
-- So an item's `server` table runs here, and the split is the whole contract:
--
--   server = { OnUse = function(plr, item, ctx) ... end }
--       may change the world. Called here, with a validated player and the
--       real inventory item -- not a copy, so writes to item.data stick and
--       travel with the item through a drop and a pickup.
--
--   client = { OnUseStart = ..., OnRender = ... }
--       prediction and presentation. Never trusted, never waited for.
--
-- THE HOOK DOES NOT TOUCH THE INVENTORY. It returns a VERDICT and this
-- applies it. An apple that removed itself from a slot would have to know
-- about slots, pushes and the wire format -- and every item author would then
-- own a copy of that bookkeeping, which is how five items end up with five
-- subtly different ideas of what "used up" means.
--
--   "consume"   the item is gone
--   "keep" / true / nil   it stays (a torch toggling, a tool with a charge)
--   a number    it stays, and cannot be used again for that many seconds
--   false       refused; nothing happens and no cooldown is charged

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Registry     = require(script.Parent:WaitForChild("Registry"))
local Glacier      = require(ReplicatedStorage:WaitForChild("Glacier"))
local Inventory    = require(ReplicatedStorage:WaitForChild("Inventory"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("ItemRegistry"))

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

local UseItem = ensureRemote("UseItem")

--=====================================================================
-- COOLDOWNS
--=====================================================================
-- Keyed by player and ITEM ID, not by class: two medkits are two medkits, and
-- eating one apple should not put the other on a timer.
--
-- There is always a floor, even for an item that asks for none. The client
-- sends this remote and a client can send it every frame; without a floor a
-- modified one would call OnUse sixty times a second, and "the hook is
-- cheap" is a promise about today's items rather than about the next one.
local MIN_INTERVAL = 0.2

local cooldowns = {}   -- [Player] = { [itemId] = readyAt }

local function readyAt(plr, id)
	local byId = cooldowns[plr]
	return (byId and byId[id]) or 0
end

-- Pruned rather than left to grow. An id is per ITEM, not per class, so a
-- player who spends an evening picking things up and throwing them away
-- leaves an entry behind for every one of them -- fine for a round of a
-- shooter, not fine for the long session this is meant to survive.
--
-- Only expired entries go, and only when the table is big enough for it to be
-- worth walking: an item still on cooldown is the one thing here that means
-- anything.
local PRUNE_ABOVE = 64

local function setReady(plr, id, at)
	local byId = cooldowns[plr]
	if not byId then
		byId = {}
		cooldowns[plr] = byId
	end
	byId[id] = at

	local count = 0
	for _ in pairs(byId) do count += 1 end
	if count > PRUNE_ABOVE then
		local now = os.clock()
		for key, readyAtTime in pairs(byId) do
			if readyAtTime <= now then byId[key] = nil end
		end
	end
end

Players.PlayerRemoving:Connect(function(plr) cooldowns[plr] = nil end)

--=====================================================================
-- USE
--=====================================================================

-- Split out of the event handler rather than written inside it, for the
-- reason the vehicle relay was: a body that only a real network can reach is
-- a body no test can reach either.
--
-- Returns ok, reasonOrVerdict.
local function useItem(plr, slot, now)
	if not Glacier.IsAlive(plr) then return false, "you are not alive" end

	slot = Inventory.SlotIndex(slot) or Glacier.ActiveSlot(plr)
	local item = Glacier.GetSlot(plr, slot)
	if not item then return false, "that slot is empty" end

	local stats = ItemRegistry.Stats(item.class)
	if not stats then return false, "unknown item: " .. tostring(item.class) end

	-- A gun is not used, it is fired, and that path is WeaponServer's. Sent
	-- here it would be a way to run a rifle's OnUse hook -- which it does not
	-- have -- once per remote call, forever.
	if ItemRegistry.Action(stats) ~= "use" then
		return false, tostring(item.class) .. " is not something you use"
	end

	if now < readyAt(plr, item.id) then return false, "not ready yet" end

	local hook = ItemRegistry.ServerHook(stats, "OnUse")
	if not hook then
		-- A declared useTime with no hook is an item that plays its animation
		-- and does nothing, which is a legitimate half-built item rather than
		-- an error. Still charge the cooldown so it cannot be spammed.
		setReady(plr, item.id, now + math.max(stats.useCooldown or stats.useTime or 0, MIN_INTERVAL))
		return true, "keep"
	end

	-- pcall'd because an item module is content, not engine code: a typo in
	-- somebody's apple must not take down the use path for every other item
	-- on the server.
	local ok, verdict = pcall(hook, plr, item, {
		slot = slot,
		stats = stats,
		now = now,
	})

	if not ok then
		warn(("[ItemServer] %s OnUse error: %s"):format(tostring(item.class), tostring(verdict)))
		setReady(plr, item.id, now + MIN_INTERVAL)
		return false, "that item is broken"
	end

	if verdict == false then
		-- A refusal the item made on purpose -- no charges left, not hungry,
		-- already lit. It said no, so it is not put on a timer for saying so.
		return false, "refused"
	end

	local cooldown = (type(verdict) == "number") and verdict
		or (stats.useCooldown or stats.useTime or 0)
	setReady(plr, item.id, now + math.max(cooldown, MIN_INTERVAL))

	if verdict == "consume" then
		Glacier.TakeSlot(plr, slot)   -- pushes the inventory itself
		return true, "consume"
	end

	-- Pushed even when nothing was consumed: the hook is handed the real item
	-- and the usual thing for it to do is write item.data -- a torch's `lit`,
	-- a tool's remaining charges -- and the client is drawing from its own
	-- copy of that.
	Glacier.PushInventory(plr)
	return true, "keep"
end

UseItem.OnServerEvent:Connect(function(plr, slot)
	local ok, why = useItem(plr, slot, os.clock())
	-- Silent on refusal. This fires from a held trigger, so a message per
	-- rejected press would be a wall of text on an empty slot -- unlike the
	-- vehicle use key, which is a single deliberate press.
	if not ok and why ~= "not ready yet" and why ~= "refused" then
		Glacier.Tell(plr, "[item] " .. tostring(why), true)
	end
end)

--=====================================================================
-- API
--=====================================================================
-- For gamemodes and console commands: use an item on somebody's behalf,
-- through exactly the same validation the remote goes through.

local ItemServer = {}

function ItemServer.Use(plr, slot)
	return useItem(plr, slot, os.clock())
end

Registry.ItemServer = ItemServer
