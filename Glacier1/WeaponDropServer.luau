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
local PhysicsService    = game:GetService("PhysicsService")
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

--=====================================================================
-- COLLISION GROUPS
--=====================================================================
-- Drops collide with the world and nothing else. Two reasons:
--
--   A player's RawBody is ANCHORED and moved by CFrame, so a weapon resting
--   against it gets punted across the room the moment they walk through it.
--
--   Drops piling on each other jitter forever, since each one keeps waking
--   the others' assemblies.
--
-- Registration is idempotent-by-pcall and done from both ends: script start
-- order between Glacier1's children isn't guaranteed, and whichever runs
-- first should be able to use its own group immediately.

local DROP_GROUP = "GlacierDrops"
local BODY_GROUP = "GlacierBodies"

do
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, DROP_GROUP)
	pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, BODY_GROUP)
	pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, DROP_GROUP, BODY_GROUP, false)
	pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, DROP_GROUP, DROP_GROUP, false)
end

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

-- A dropped weapon is ONE invisible box, sized to the whole model, with every
-- visual part welded to it and non-collidable.
--
-- Making the model's PrimaryPart the collider (the previous approach) reads as
-- sensible and behaves badly: a PrimaryPart is normally a grip or muzzle
-- attachment an inch across, so the rifle balanced on an invisible pin,
-- sank through the floor it was supposedly resting on, and tipped over. One
-- hull also stops the parts fighting each other for the same contact.
local MIN_HULL = Vector3.new(0.9, 0.4, 0.9)

-- The world model lives at the ReplicatedStorage root under the canonical
-- class name -- the same one EquipWeaponEvent clones onto the puppet's arm.
-- A weapon with no model still drops, as a labelled block: losing the item
-- entirely because an artist hasn't made the mesh yet is worse.
local function buildBody(class)
	local template = WeaponRegistry.Model(class)
	local model = template and template:Clone() or nil

	-- GetBoundingBox is the model's own extents in its own orientation, which
	-- is what the hull has to match -- GetExtentsSize is axis-aligned to the
	-- world and would give a rifle lying diagonally a hull twice its size.
	local hullCFrame, hullSize
	if model then
		local ok, cframe, size = pcall(model.GetBoundingBox, model)
		if ok and size then
			hullCFrame, hullSize = cframe, size
		else
			model:Destroy()
			model = nil
		end
	end

	if not model then
		model = Instance.new("Model")
		hullCFrame, hullSize = CFrame.new(), Vector3.new(1.6, 0.4, 0.4)
	end

	local hull = Instance.new("Part")
	hull.Name = "DropHull"
	hull.Size = Vector3.new(
		math.max(hullSize.X, MIN_HULL.X),
		math.max(hullSize.Y, MIN_HULL.Y),
		math.max(hullSize.Z, MIN_HULL.Z))
	hull.CFrame = hullCFrame
	hull.Transparency = template and 1 or 0        -- visible only as a stand-in
	hull.Color = Color3.fromRGB(120, 120, 130)
	hull.CanCollide = true
	hull.CanQuery = true
	hull.CanTouch = false
	hull.CollisionGroup = DROP_GROUP

	-- Draggy and inelastic: a weapon should stop where it lands rather than
	-- skate across the floor or bounce down a flight of stairs.
	hull.CustomPhysicalProperties = PhysicalProperties.new(1.2, 0.8, 0.05, 1, 1)

	hull.Parent = model
	model.PrimaryPart = hull
	return model, hull
end

local function preparePhysics(object, root)
	for _, part in ipairs(object:GetDescendants()) do
		if part:IsA("BasePart") and part ~= root then
			part.Anchored = false
			part.CanCollide = false   -- the hull is the only collider
			part.CanQuery = true      -- but they still stop a pickup raycast
			part.CanTouch = false
			part.Massless = true
			part.CollisionGroup = DROP_GROUP

			-- Welded rather than left loose: an unwelded multi-part rifle
			-- explodes into its components the moment it lands.
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = root
		end
	end

	root.Anchored = false
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
	object:SetAttribute("ItemId", tostring(item.id))
	object:SetAttribute("DroppedBy", owner and owner.UserId or 0)

	object:PivotTo(cframe)   -- moves the hull and everything welded to it
	object.Parent = dropFolder

	if velocity then
		root.AssemblyLinearVelocity = velocity
		-- A random DIRECTION at a fixed magnitude, not three independent random
		-- components: the latter can land near zero on all three axes, and
		-- those are exactly the drops that come to rest flat and upright like
		-- a placed prop. The 0.7-1.3 factor keeps them from all tumbling at an
		-- identical rate.
		local spin = Config.Get("sv_dropSpin") or 0
		if spin > 0 then
			local dir = Vector3.new(
				math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
			if dir.Magnitude < 1e-3 then dir = Vector3.xAxis end
			root.AssemblyAngularVelocity = dir.Unit * spin * (0.7 + math.random() * 0.6)
		end
	end

	-- The WHOLE item is kept, not a copy of three of its fields. Its id is its
	-- identity and its data bag is everything that belongs to this particular
	-- weapon rather than to its class -- both have to come back out of the
	-- world unchanged, or a pickup silently mints a different gun.
	pickups[object] = {
		item    = item,
		class   = item.class,
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
-- carried is the thrower's own velocity, sent by the client with the request.
--
-- It has to come from there. The RawBody is ANCHORED and moved by CFrame, so
-- its AssemblyLinearVelocity is permanently zero -- reading it (which this did)
-- meant a weapon dropped at a full sprint was launched as if the player were
-- standing still, and promptly got left behind. Clamped to sv_maxvelocity on
-- arrival, which bounds a lying client to what a fast legitimate one could
-- already have.
local function throwFrom(plr, carried)
	local body = Glacier.RawBody(plr)
	if not body then return nil end

	local puppet = Glacier.PuppetOf(plr)
	local root = puppet and puppet.PrimaryPart
	local cframe = root and root.CFrame or body.CFrame

	local look = cframe.LookVector

	-- Thrown from a random orientation as well as with a random spin. A weapon
	-- released along a clean axis tends to settle onto one, and a rifle lying
	-- perfectly flat and square reads as scenery rather than something someone
	-- dropped mid-fight.
	local origin = CFrame.new(cframe.Position + look * 2 + Vector3.new(0, 1, 0))
		* CFrame.Angles(
			math.random() * math.pi * 2,
			math.random() * math.pi * 2,
			math.random() * math.pi * 2)

	local jitter = Config.Get("sv_dropJitter") or 0
	local velocity = look * (Config.Get("sv_dropForce") or 0)
		+ Vector3.new(0, Config.Get("sv_dropUpForce") or 0, 0)
		+ Vector3.new(
			(math.random() - 0.5) * jitter,
			(math.random() - 0.5) * jitter * 0.5,
			(math.random() - 0.5) * jitter)

	if typeof(carried) == "Vector3" and carried.Magnitude > 0 then
		local cap = Config.Get("sv_maxvelocity") or 320
		if carried.Magnitude > cap then carried = carried.Unit * cap end
		velocity += carried * (Config.Get("sv_dropInherit") or 1)
	end

	return origin, velocity
end

--=====================================================================
-- DROP
--=====================================================================

-- Returns ok, pickup | reason.
local function dropSlot(plr, slot, carried)
	if not Config.Get("sv_dropWeapons") then return false, "dropping is disabled" end
	if not Glacier.IsAlive(plr) then return false, "you're not alive" end

	slot = Inventory.SlotIndex(slot) or Glacier.ActiveSlot(plr)

	if slot == Inventory.SLOT_MELEE and not Config.Get("sv_dropMelee") then
		return false, "you can't drop your knife"
	end

	local item = Glacier.GetSlot(plr, slot)
	if not item then return false, "that slot is empty" end

	local origin, velocity = throwFrom(plr, carried)
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

-- Returns the nearest pickup and its distance REGARDLESS of range, so the
-- caller can tell "there's nothing here" apart from "it's four studs too far"
-- -- the second was the failure that looked exactly like a dead keybind.
local function nearestPickup(plr)
	local from = Glacier.PositionOf(plr, "player")
	if not from then return nil, nil, "you have no body" end

	local ownerDelay = Config.Get("sv_pickupOwnerDelay") or 0
	local now = os.clock()
	local floor = workspace.FallenPartsDestroyHeight

	local best, bestDist
	for object, info in pairs(pickups) do
		local position = object.Parent and positionOf(object) or nil

		if not position then
			pickups[object] = nil          -- destroyed out from under us
		elseif position.Y < floor then
			destroyPickup(object)          -- fell out of the world
		else
			-- Your own drop ignores you briefly, or the same keypress that
			-- threw it picks it straight back up.
			local blocked = info.owner == plr and (now - info.time) < ownerDelay
			if not blocked then
				local d = (position - from).Magnitude
				if not bestDist or d < bestDist then best, bestDist = object, d end
			end
		end
	end

	if not best then return nil, nil, "nothing on the ground near you" end
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

	-- id and data included: this is the same weapon coming back, not a fresh
	-- one of the same class.
	local ok, result = Glacier.GiveWeapon(plr, info.class, {
		id      = info.item.id,
		ammo    = info.item.ammo,
		reserve = info.item.reserve,
		data    = info.item.data,
	}, slot)

	if not ok then
		pickups[object] = info   -- put it back; nobody got anything
		return false, tostring(result)
	end

	destroyPickup(object)
	return true, info.class
end

-- The shared body of every pickup attempt. Returns ok, message -- the message
-- is worth showing either way, which is what makes a failed pickup diagnosable
-- instead of silent.
local function attemptPickup(plr, range, swap)
	local object, distance, reason = nearestPickup(plr)
	if not object then return false, reason end

	if distance > range then
		return false, ("nothing in reach -- nearest is %s, %.1f studs away (sv_pickupRange %s)")
			:format(tostring(pickups[object] and pickups[object].class), distance, tostring(range))
	end

	return takePickup(plr, object, swap)
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

-- A refused drop or pickup used to do nothing at all, which reads exactly
-- like a key that isn't bound. Saying why costs one console line and is the
-- difference between "it's broken" and "you're two studs short".
local function feedback(plr, verb, ok, message)
	if not Config.Get("sv_pickupFeedback") then return end
	if message == nil then return end
	Glacier.Tell(plr, ("[%s] %s"):format(verb, tostring(message)), not ok)
end

DropWeapon.OnServerEvent:Connect(function(plr, slot, velocity)
	if throttled(plr) then return end
	-- The slot is the client's own, and SlotIndex rejects anything that isn't
	-- one of the three, so there is nothing here worth validating harder. The
	-- velocity is clamped in throwFrom and only ever affects how far a prop
	-- flies, so it is not worth validating harder either.
	local ok, result = dropSlot(plr, slot, velocity)
	feedback(plr, "drop", ok, ok and ("dropped " .. result:GetAttribute("Class")) or result)
end)

PickupWeapon.OnServerEvent:Connect(function(plr)
	if throttled(plr) then return end

	local ok, result = attemptPickup(plr, Config.Get("sv_pickupRange") or 8, true)
	feedback(plr, "pickup", ok, ok and ("picked up " .. tostring(result)) or result)
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
					local object, distance = nearestPickup(plr)
					local inRange = object and distance and distance <= range
					local info = inRange and pickups[object] or nil
					if info then
						local slot = Inventory.SlotFor(info.class, Glacier.ActiveSlot(plr))
						-- Empty slots only. Auto-swapping is how you lose a
						-- rifle to a pistol lying in a doorway.
						if slot and not Glacier.GetSlot(plr, slot) then
							local ok, result = takePickup(plr, object, false)
							feedback(plr, "pickup", ok, ok and ("picked up " .. tostring(result)) or nil)
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

Config.Command("pickupweapon", {
	args = {},
	flag = Config.FCVAR.REPLICATED,
	help = "pick up the nearest weapon -- the same path +use takes, but it reports why it failed",
	run = function(ctx)
		local plr = ctx and ctx.player
		if not plr then return false, "pickupweapon needs a player" end

		local ok, result = attemptPickup(plr, Config.Get("sv_pickupRange") or 8, true)
		if not ok then return false, result end

		reply(ctx, ("[pickup] %s"):format(tostring(result)))
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
		local from = ctx and ctx.player and Glacier.PositionOf(ctx.player, "player")

		local lines = {}
		for object, info in pairs(pickups) do
			local position = positionOf(object)
			table.insert(lines, ("%-12s %3d/%-3d  %-18s %s"):format(
				info.class, info.item.ammo or 0, info.item.reserve or 0,
				position and ("%.0f %.0f %.0f"):format(position.X, position.Y, position.Z) or "?",
				(from and position)
					and ("%.1f studs away"):format((position - from).Magnitude) or ""))
		end

		if #lines == 0 then reply(ctx, "[drop] nothing on the ground") return true end
		table.sort(lines)
		reply(ctx, ("[drop] %d on the ground\n%s"):format(#lines, table.concat(lines, "\n")))
		return true
	end,
})
