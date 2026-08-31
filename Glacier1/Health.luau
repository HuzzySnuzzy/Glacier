-- ModuleScript: Health  (server)
-- Health, armour and hitgroup damage, modelled on CS 1.6.
--
-- child of Glacier1
--
-- State lives in Attributes on the target model, so it replicates to every
-- client for free -- a HUD just reads Attributes rather than needing its own
-- sync remote. Nothing writes those attributes except this module.
--
-- Works for anything with a Humanoid: player puppets, bots, test dummies.

local Players = game:GetService("Players")

local Health = {}

--=====================================================================
-- TUNING
--=====================================================================

Health.MAX_HEALTH = 100
Health.MAX_ARMOR  = 100

-- CS 1.6 hitgroup multipliers. Legs hurt less, stomach more.
local HITGROUP = {
	Head           = { mult = 4.0,  group = "head" },
	Torso          = { mult = 1.0,  group = "chest" },
	HumanoidRootPart = { mult = 1.0, group = "chest" },
	["Left Arm"]   = { mult = 1.0,  group = "arm" },
	["Right Arm"]  = { mult = 1.0,  group = "arm" },
	["Left Leg"]   = { mult = 0.75, group = "leg" },
	["Right Leg"]  = { mult = 0.75, group = "leg" },
}

-- How much of the damage armour soaks. GoldSrc's flArmorBonus.
local ARMOR_BONUS = 0.5

--=====================================================================
-- ATTRIBUTES
--=====================================================================

local function humanoidOf(model)
	return model and model:FindFirstChildOfClass("Humanoid")
end

function Health.Setup(model, opts)
	opts = opts or {}
	local hum = humanoidOf(model)
	if not hum then return false end

	local maxHp = opts.maxHealth or Health.MAX_HEALTH

	model:SetAttribute("MaxHealth", maxHp)
	model:SetAttribute("Health", opts.health or maxHp)
	model:SetAttribute("Armor", opts.armor or 0)
	model:SetAttribute("Helmet", opts.helmet or false)
	model:SetAttribute("Dead", false)

	-- The Humanoid is kept in sync so Roblox's own systems (nameplates,
	-- ragdoll on death) still behave, but this module is the source of truth.
	hum.MaxHealth = maxHp
	hum.Health = model:GetAttribute("Health")
	hum.BreakJointsOnDeath = false

	return true
end

function Health.Get(model)
	if not model then return nil end
	return {
		health = model:GetAttribute("Health") or 0,
		armor  = model:GetAttribute("Armor") or 0,
		helmet = model:GetAttribute("Helmet") == true,
		dead   = model:GetAttribute("Dead") == true,
	}
end

--=====================================================================
-- HITGROUP
--=====================================================================

function Health.HitgroupFor(partName)
	local entry = HITGROUP[partName]
	if entry then return entry.group, entry.mult end
	return "chest", 1.0
end

--=====================================================================
-- DAMAGE
--=====================================================================

-- GoldSrc armour: armour absorbs a share of the damage and is itself consumed.
-- Once it runs out the remainder passes through in full, so armour softens
-- rather than caps.
local function applyArmor(model, damage, armorRatio)
	local armor = model:GetAttribute("Armor") or 0
	if armor <= 0 then return damage, 0 end

	local reduced = damage * armorRatio
	local armorDamage = (damage - reduced) * ARMOR_BONUS

	if armorDamage > armor then
		-- Armour breaks partway through: only what it could absorb counts.
		reduced = damage - (armor / ARMOR_BONUS)
		armorDamage = armor
	end

	model:SetAttribute("Armor", math.max(armor - armorDamage, 0))
	return math.max(reduced, 0), armorDamage
end

-- opts:
--   hitPart   BasePart or name  -- picks the hitgroup multiplier
--   attacker  Player or nil
--   stats     weapon module     -- armorRatio, falloff
--   distance  studs             -- for falloff
--
-- Returns dealt, killed, hitgroup.
function Health.Damage(model, amount, opts)
	opts = opts or {}
	local hum = humanoidOf(model)
	if not hum then return 0, false, nil end
	if model:GetAttribute("Dead") then return 0, false, nil end

	local hp = model:GetAttribute("Health")
	if hp == nil then
		-- Never set up. Do it now rather than silently no-op.
		Health.Setup(model)
		hp = model:GetAttribute("Health")
	end
	if hp <= 0 then return 0, false, nil end

	-- ---- hitgroup ----
	local partName = typeof(opts.hitPart) == "Instance" and opts.hitPart.Name or opts.hitPart
	local group, mult = Health.HitgroupFor(partName)

	-- A helmet negates the headshot multiplier for most weapons. In CS it's
	-- the single most valuable purchase for exactly this reason.
	if group == "head" and model:GetAttribute("Helmet") then
		local pierces = opts.stats and opts.stats.piercesHelmet
		if not pierces then
			mult = 1.0
			model:SetAttribute("Helmet", false) -- helmet is consumed
		end
	end

	local damage = amount * mult

	-- ---- range falloff ----
	local stats = opts.stats
	if stats and stats.falloffStart and opts.distance then
		local d = opts.distance
		if d > stats.falloffStart then
			local span = math.max((stats.falloffEnd or stats.range or 500) - stats.falloffStart, 1)
			local t = math.clamp((d - stats.falloffStart) / span, 0, 1)
			local floor = stats.falloffMin or 0.4
			damage = damage * (1 - t * (1 - floor))
		end
	end

	-- ---- armour ----
	local armorDamage = 0
	if group ~= "leg" then
		-- Kevlar doesn't cover legs, same as CS.
		damage, armorDamage = applyArmor(model, damage, (stats and stats.armorRatio) or 0.5)
	end

	damage = math.floor(damage + 0.5)

	-- ---- apply ----
	local newHp = math.max(hp - damage, 0)
	model:SetAttribute("Health", newHp)
	hum.Health = newHp

	local killed = newHp <= 0
	if killed then
		model:SetAttribute("Dead", true)
		Health.Killed:Fire(model, opts.attacker, group)
	end
	
	
	Health.Damaged:Fire(model, damage, opts.attacker, group, armorDamage)

	return damage, killed, group
end

function Health.Heal(model, amount)
	if not model or model:GetAttribute("Dead") then return end
	local hp = model:GetAttribute("Health") or 0
	local maxHp = model:GetAttribute("MaxHealth") or Health.MAX_HEALTH
	local newHp = math.min(hp + amount, maxHp)
	model:SetAttribute("Health", newHp)
	local hum = humanoidOf(model)
	if hum then hum.Health = newHp end
end

function Health.GiveArmor(model, amount, helmet)
	if not model then return end
	local armor = model:GetAttribute("Armor") or 0
	model:SetAttribute("Armor", math.min(armor + amount, Health.MAX_ARMOR))
	if helmet ~= nil then
		model:SetAttribute("Helmet", helmet)
	end
end

-- Direct kill, bypassing armour, hitgroups and falloff. For round-end cleanup,
-- world kills (fall damage, out-of-bounds) and admin commands.
--
-- Deliberately does NOT route through Damage(): armour would soak part of it,
-- and Damaged would fire with a fabricated hitgroup that the killfeed would
-- then have to special-case.
function Health.Kill(model, attacker, reason)
	if not model then return false end
	local hum = humanoidOf(model)
	if not hum then return false end
	if model:GetAttribute("Dead") then return false end

	model:SetAttribute("Health", 0)
	model:SetAttribute("Dead", true)
	hum.Health = 0

	Health.Killed:Fire(model, attacker, reason or "world")
	return true
end

function Health.Revive(model, opts)
	Health.Setup(model, opts)
end

--=====================================================================
-- EVENTS
--=====================================================================

-- BindableEvents so game logic (scoring, killfeed, respawn) can subscribe
-- without this module knowing anything about it.
Health.Damaged = Instance.new("BindableEvent",game.ReplicatedStorage)
Health.Killed  = Instance.new("BindableEvent")
Health.Damaged.Name = "OnDamage"
return Health