-- Script: WeaponDropServer
-- Parent: Glacier1
--
-- Dropping a weapon into the world and picking it back up. Server-authoritative
-- end to end: the client asks, this decides.
--
--   DropWeapon:FireServer(slot)     -- client asks to drop; slot is optional
--   PickupWeapon:FireServer()       -- client asks for the nearest pickup
--
-- A dropped weapon KEEPS ITS AMMO. That is the whole reason Inventory holds
-- ammo on the item rather than on the player: the rifle you throw down on eight
-- rounds is still on eight rounds when someone else takes it.
--
-- WHY NOT A ProximityPrompt: prompts are positioned against Player.Character,
-- and this engine's players are a RawBody part with a Puppet inside it, not a
-- Roblox character. The prompt would measure range from a body that isn't
-- where the player is. Range is checked here against the RawBody instead.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config         = require(ReplicatedStorage:WaitForChild("Config"))
local Glacier        = require(ReplicatedStorage:WaitForChild("Glacier"))
local Inventory      = require(ReplicatedStorage:WaitForChild("Inventory"))
local WeaponRegistry = require(ReplicatedStorage:WaitForChild("WeaponRegistry"))

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

local DropWeapon   = ensureRemote("DropWeapon")
local PickupWeapon = ensureRemote("PickupWeapon")

-- One folder, so a map reload or a round reset can clear every loose weapon
-- with a single Destroy instead of walking workspace looking for attributes.
local dropFolder = workspace:FindFirstChild("WeaponDrops")
if not dropFolder then
	dropFolder = Instance.new("Folder")
	dropFolder.Name = "WeaponDrops"
	dropFolder.Parent = workspace
end

--=====================================================================
-- PICKUP OBJECTS
--=====================================================================

local pickups = {}   -- [Model|BasePart] = { class, ammo, reserve, id, owner, time }

local function pickupCount()
	local n = 0
	for _ in pairs(pickups) do n += 1 end
	return n
end

local function destroyPickup(object)
	pickups[object] = nil
	if object and object.Parent then object:Destroy() end
end

-- Oldest first, so a busy server sheds the drops nobody came back for rather
-- than refusing the one somebody just made.
local function cullOldest()
	local limit = Config.Get("sv_pickupMax") or 0
	if limit <= 0 then return end

	while pickupCount() > limit do
		local oldest, oldestTime
		for object, info in pairs(pickups) do
			if not oldestTime or info.time < oldestTime then
				oldest, oldestTime = object, info.time
			end
		end
		if not oldest then return end
		destroyPickup(oldest)
	end
end

-- The world model lives at the ReplicatedStorage root under the canonical
-- class name -- the same one EquipWeaponEvent clones onto the puppet's arm.
-- A weapon with no model still drops, as a labelled block: losing the item
-- entirely because an artist hasn't made the mesh yet is worse.
local function buildBody(class)
	local template = WeaponRegistry.Model(class)
	if template then
		local model = template:Clone()
		if model.PrimaryPart then return model, model.PrimaryPart end
		-- A model with no PrimaryPart can't be welded or thrown coherently.
		model:Destroy()
	end

	local part = Instance.new("Part")
	part.Name = class
	part.Size = Vector3.new(1.6, 0.4, 0.4)
	part.Color = Color3.fromRGB(120, 120, 130)
	return part, part
end

local function preparePhysics(object, root)
	for _, part in ipairs(object:IsA("Model") and object:GetDescendants() or { object }) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = true
			part.Massless = part ~= root

			-- Welded rather than left loose: an unwelded multi-part rifle
			-- explodes into its components the moment it lands.
			if part ~= root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = part
				weld.Parent = root
			end
		end
	end

	-- Only the root collides, so the weapon rests on the floor without its
	-- magazine and sights fighting each other for the same contact.
	root.CanCollide = true
end

-- item is an Inventory item, so ammo and reserve travel with it.
-- Returns the pickup instance, or nil plus a reason.
local function spawnPickup(item, cframe, velocity, owner)
	if not (item and item.class) then return nil, "nothing to drop" end

	local object, root = buildBody(item.class)
	if not root then return nil, "no droppable model for " .. tostring(item.class) end

	object.Name = item.class .. "_Drop"
	preparePhysics(object, root)

	-- Attributes rather than a server-side table alone: a client that wants to
	-- draw a "press E" label can read them straight off the instance, and they
	-- survive anything that reparents the model.
	object:SetAttribute("GlacierPickup", true)
	object:SetAttribute("Class", item.class)
	object:SetAttribute("Ammo", item.ammo or 0)
	object:SetAttribute("Reserve", item.reserve or 0)
	object:SetAttribute("DroppedBy", owner and owner.UserId or 0)

	if object:IsA("Model") then
		object:PivotTo(cframe)
	else
		object.CFrame = cframe
	end
	object.Parent = dropFolder

	if velocity then
		root.AssemblyLinearVelocity = velocity
		local spin = Config.Get("sv_dropSpin") or 0
		if spin > 0 then
			root.AssemblyAngularVelocity = Vector3.new(
				(math.random() - 0.5) * spin,
				(math.random() - 0.5) * spin,
				(math.random() - 0.5) * spin)
		end
	end

	pickups[object] = {
		class   = item.class,
		ammo    = item.ammo or 0,
		reserve = item.reserve or 0,
		id      = item.id,
		owner   = owner,
		time    = os.clock(),
	}

	cullOldest()

	local lifetime = Config.Get("sv_pickupLifetime") or 0
	if lifetime > 0 then
		task.delay(lifetime, function()
			-- Re-checked rather than cancelled on pickup: the table entry is
			-- gone by then, so a taken weapon simply falls through this.
			if pickups[object] then destroyPickup(object) end
		end)
	end

	return object
end

--=====================================================================
-- WHERE A DROP LANDS
--=====================================================================

-- The Puppet's root is re-CFramed from the client every frame, so it faces
-- where the player is actually looking. The RawBody is only re-oriented on
-- spawn and teleport, which is why a drop keyed off it flies out sideways.
local function throwFrom(plr)
	local body = Glacier.RawBody(plr)
	if not body then return nil end

	local puppet = Glacier.PuppetOf(plr)
	local root = puppet and puppet.PrimaryPart
	local cframe = root and root.CFrame or body.CFrame

	local look = cframe.LookVector
	local origin = CFrame.new(cframe.Position + look * 2 + Vector3.new(0, 1, 0))
		* (cframe - cframe.Position)

	local velocity = look * (Config.Get("sv_dropForce") or 0)
		+ Vector3.new(0, Config.Get("sv_dropUpForce") or 0, 0)

	-- Inherit the thrower's motion, or a weapon dropped while sprinting hangs
	-- in the air behind them.
	local carried = body.AssemblyLinearVelocity
	if typeof(carried) == "Vector3" then velocity += carried end

	return origin, velocity
end

--=====================================================================
-- DROP
--=====================================================================

-- Returns ok, pickup | reason.
local function dropSlot(plr, slot)
	if not Config.Get("sv_dropWeapons") then return false, "dropping is disabled" end
	if not Glacier.IsAlive(plr) then return false, "you're not alive" end

	slot = Inventory.SlotIndex(slot) or Glacier.ActiveSlot(plr)

	if slot == Inventory.SLOT_MELEE and not Config.Get("sv_dropMelee") then
		return false, "you can't drop your knife"
	end

	local item = Glacier.GetSlot(plr, slot)
	if not item then return false, "that slot is empty" end

	local origin, velocity = throwFrom(plr)
	if not origin then return false, "you have no body" end

	-- Taken BEFORE the pickup is built: if spawnPickup fails the item goes
	-- straight back, but leaving it in the inventory while a copy exists in
	-- the world would duplicate the weapon.
	local taken = Glacier.TakeSlot(plr, slot)
	if not taken then return false, "that slot is empty" end

	local pickup, reason = spawnPickup(taken, origin, velocity, plr)
	if not pickup then
		Glacier.GiveWeapon(plr, taken.class, taken, slot)
		return false, reason
	end

	return true, pickup
end

--=====================================================================
-- PICKUP
--=====================================================================

local function positionOf(object)
	if object:IsA("Model") then
		local ok, pivot = pcall(object.GetPivot, object)
		return ok and pivot.Position or nil
	end
	return object.Position
end

-- Nearest first, so walking between two rifles gives you the one you're
-- standing on rather than whichever pairs() happened to hand back first.
local function nearestPickup(plr, range)
	local from = Glacier.PositionOf(plr, "player")
	if not from then return nil end

	local ownerDelay = Config.Get("sv_pickupOwnerDelay") or 0
	local now = os.clock()

	local best, bestDist
	for object, info in pairs(pickups) do
		if not object.Parent then
			pickups[object] = nil
		else
			-- Your own drop ignores you briefly, or the same keypress that
			-- threw it picks it straight back up.
			local blocked = info.owner == plr and (now - info.time) < ownerDelay
			local position = not blocked and positionOf(object) or nil
			if position then
				local d = (position - from).Magnitude
				if d <= range and (not bestDist or d < bestDist) then
					best, bestDist = object, d
				end
			end
		end
	end

	return best, bestDist
end

-- Returns ok, class | reason.
local function takePickup(plr, object, swap)
	local info = pickups[object]
	if not info then return false, "that pickup is gone" end
	if not Glacier.IsAlive(plr) then return false, "you're not alive" end

	-- Designated slot if the weapon has one, otherwise whatever you're holding.
	local slot, reason = Inventory.SlotFor(info.class, Glacier.ActiveSlot(plr))
	if not slot then return false, reason end

	-- Claimed before anything else can: two players pressing use on the same
	-- rifle in the same frame would otherwise both be handed a copy.
	pickups[object] = nil

	local occupant = Glacier.GetSlot(plr, slot)
	if occupant and swap ~= false then
		-- CS behaviour: taking a rifle while holding one throws yours down.
		local origin, velocity = throwFrom(plr)
		local taken = Glacier.TakeSlot(plr, slot)
		if taken and origin then spawnPickup(taken, origin, velocity, plr) end
	end

	local ok, result = Glacier.GiveWeapon(plr, info.class, {
		ammo    = info.ammo,
		reserve = info.reserve,
	}, slot)

	if not ok then
		pickups[object] = info   -- put it back; nobody got anything
		return false, tostring(result)
	end

	destroyPickup(object)
	return true, info.class
end

--=====================================================================
-- REMOTES IN
--=====================================================================

-- Per-player debounce. Not a threat model so much as a held key: both of these
-- mutate the inventory and spawn instances.
local lastAction = {}
local ACTION_INTERVAL = 0.15

local function throttled(plr)
	local now = os.clock()
	if lastAction[plr] and now - lastAction[plr] < ACTION_INTERVAL then return true end
	lastAction[plr] = now
	return false
end

Players.PlayerRemoving:Connect(function(plr) lastAction[plr] = nil end)

DropWeapon.OnServerEvent:Connect(function(plr, slot)
	if throttled(plr) then return end
	-- The slot is the client's own, and SlotIndex rejects anything that isn't
	-- one of the three, so there is nothing here worth validating harder.
	local ok, reason = dropSlot(plr, slot)
	if not ok and Config.Get("sv_lifecycleDebug") then
		Glacier.Tell(plr, ("[drop] %s"):format(tostring(reason)))
	end
end)

PickupWeapon.OnServerEvent:Connect(function(plr)
	if throttled(plr) then return end

	local object = nearestPickup(plr, Config.Get("sv_pickupRange") or 8)
	if not object then return end
	takePickup(plr, object, true)
end)

--=====================================================================
-- AUTO PICKUP
--=====================================================================
-- Off by default. When on, walking over a weapon only fills an EMPTY slot --
-- auto-swapping what you're holding is how you lose your rifle to a pistol
-- lying in a doorway.

task.spawn(function()
	while true do
		task.wait(0.25)
		if Config.Get("sv_pickupAuto") then
			local range = Config.Get("sv_pickupAutoRange") or 4

			for _, plr in ipairs(Players:GetPlayers()) do
				if Glacier.IsAlive(plr) then
					local object = nearestPickup(plr, range)
					local info = object and pickups[object]
					if info then
						local slot = Inventory.SlotFor(info.class, Glacier.ActiveSlot(plr))
						if slot and not Glacier.GetSlot(plr, slot) then
							takePickup(plr, object, false)
						end
					end
				end
			end
		end
	end
end)

--=====================================================================
-- SIGNALS
--=====================================================================

-- Glacier.On ERRORS when the signal's owner hasn't published its BindableEvent
-- yet, and script start order between Glacier1's children isn't guaranteed --
-- so connecting directly at load would take this whole script down roughly
-- half the time. Retried instead, off the main thread.
local function onSignal(name, fn)
	task.spawn(function()
		local deadline = os.clock() + 20
		repeat
			if pcall(Glacier.On, name, fn) then return end
			task.wait(0.25)
		until os.clock() > deadline
		warn(("[WeaponDrop] signal '%s' never appeared; that half is inactive."):format(name))
	end)
end

--=====================================================================
-- DEATH
--=====================================================================

-- Whatever they were holding, left where they fell. Fired before the body is
-- cleaned up, so throwFrom still has something to measure from.
onSignal("PlayerKilled", function(plr)
	if not Config.Get("sv_dropOnDeath") then return end
	if typeof(plr) ~= "Instance" or not plr:IsA("Player") then return end

	local slot = Glacier.ActiveSlot(plr)
	local item = Glacier.GetSlot(plr, slot)
	if not item then return end
	if slot == Inventory.SLOT_MELEE and not Config.Get("sv_dropMelee") then return end

	local origin, velocity = throwFrom(plr)
	if not origin then return end

	local taken = Glacier.TakeSlot(plr, slot)
	if taken then spawnPickup(taken, origin, velocity * 0.3, nil) end
end)

--=====================================================================
-- MAP
--=====================================================================

-- A new map means the old one's floor is gone; anything lying on it would be
-- left hanging in the air over the new one.
onSignal("MapChanged", function()
	for object in pairs(pickups) do destroyPickup(object) end
end)

--=====================================================================
-- COMMANDS
--=====================================================================

local function reply(ctx, text)
	if ctx and type(ctx.reply) == "function" then ctx.reply(text) else print(text) end
end

Config.Command("dropweapon", {
	args = { "string?" },
	flag = Config.FCVAR.REPLICATED,
	help = "drop a slot (primary/secondary/melee); defaults to what you're holding",
	run = function(ctx, slot)
		local plr = ctx and ctx.player
		if not plr then return false, "dropweapon needs a player" end

		local ok, result = dropSlot(plr, slot)
		if not ok then return false, result end

		reply(ctx, ("[drop] %s"):format(result:GetAttribute("Class")))
		return true
	end,
})

Config.Command("cleardrops", {
	args = {},
	flag = Config.FCVAR.REPLICATED,
	help = "destroy every weapon lying on the ground",
	run = function(ctx)
		local n = pickupCount()
		for object in pairs(pickups) do destroyPickup(object) end
		reply(ctx, ("[drop] cleared %d pickup%s"):format(n, n == 1 and "" or "s"))
		return true
	end,
})

Config.Command("drops", {
	args = {},
	flag = Config.FCVAR.REPLICATED,
	help = "list weapons lying on the ground",
	run = function(ctx)
		local lines = {}
		for object, info in pairs(pickups) do
			local position = positionOf(object)
			table.insert(lines, ("%-12s %3d/%-3d  %s"):format(
				info.class, info.ammo, info.reserve,
				position and ("%.0f %.0f %.0f"):format(position.X, position.Y, position.Z) or "?"))
		end

		if #lines == 0 then reply(ctx, "[drop] nothing on the ground") return true end
		table.sort(lines)
		reply(ctx, ("[drop] %d on the ground\n%s"):format(#lines, table.concat(lines, "\n")))
		return true
	end,
})
