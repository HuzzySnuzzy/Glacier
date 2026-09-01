-- ModuleScript: AK47
-- Location: ReplicatedStorage.Weapons.AK47
--
-- Self-contained: stats, recoil pattern, accuracy, animations, sounds, FX.
-- Nothing about this weapon lives anywhere else.
local Name = "ak47"
return {
	name = Name,

	-- Which inventory slot this weapon may occupy: "primary", "secondary",
	-- "melee", or "any" (also the meaning of leaving it out) for a weapon
	-- that fits wherever it is put. Give/primary/secondary/melee all refuse
	-- a slot this forbids, so a pistol can never end up in the rifle slot.
	slot = "primary",
	isAuto = true,
	fireRate = 600,
	magSize = 30,
	maxReserve = 90,
	reloadTime = 2.4,
	equipTime = 1.0,      -- seconds before you can fire after drawing

	damage = 36,
	range = 500,

	-- Rifle armour ratio: armour absorbs relatively little, unlike the ~0.5
	-- of a pistol. Combined with piercesHelmet, this is what makes the AK a
	-- one-tap headshot through a helmet -- its defining property.
	armorRatio = 1.55,
	piercesHelmet = true,

	falloffStart = 200,   -- studs before damage starts dropping
	falloffEnd = 550,
	falloffMin = 0.62,

	--=================================================================
	-- RECOIL
	--=================================================================
	-- Pattern entries are ABSOLUTE view offsets in degrees; per-shot deltas
	-- are derived by the Recoil module. pattern[1] must be zero so the first
	-- bullet is always dead centre.
	--   .X = yaw   (+ right)
	--   .Y = pitch (+ up)
	--
	-- Shape: nine shots almost straight up to ~8.6 deg, then the horizontal
	-- sweep -- left, right, left. Peak climb 9.5 deg, wander +/-4.6 deg. That
	-- horizontal range is roughly double the M4's, which is the whole reason
	-- the AK spray is harder to hold.
	recoil = {
		scale = 1.0,
		variance = 1.0,        -- unsuppressed: less consistent than the M4A1-S
		jitterDegrees = 0.35,
		cooldownMul = 1.0,     -- NOTE: inside recoil, not at module top level
		pattern = {
			Vector2.new( 0.00, 0.00), Vector2.new( 0.05, 1.00), Vector2.new( 0.10, 2.10),
			Vector2.new( 0.15, 3.30), Vector2.new( 0.10, 4.60), Vector2.new( 0.00, 5.90),
			Vector2.new(-0.20, 7.00), Vector2.new(-0.50, 7.90), Vector2.new(-1.10, 8.60),
			Vector2.new(-2.00, 9.10), Vector2.new(-3.00, 9.40), Vector2.new(-3.90, 9.50),
			Vector2.new(-4.50, 9.40), Vector2.new(-4.60, 9.20), Vector2.new(-4.20, 9.00),
			Vector2.new(-3.30, 8.80), Vector2.new(-2.10, 8.70), Vector2.new(-0.80, 8.70),
			Vector2.new( 0.60, 8.80), Vector2.new( 2.00, 9.00), Vector2.new( 3.20, 9.20),
			Vector2.new( 4.10, 9.30), Vector2.new( 4.60, 9.30), Vector2.new( 4.50, 9.20),
			Vector2.new( 3.90, 9.00), Vector2.new( 2.90, 8.80), Vector2.new( 1.70, 8.70),
			Vector2.new( 0.50, 8.70), Vector2.new(-0.60, 8.80), Vector2.new(-1.50, 9.00),
		},
	},

	--=================================================================
	-- ACCURACY (the cone -- separate from recoil, and seeded server-side)
	--=================================================================
	-- All values are half-angles in RADIANS. maxSpeed is studs/sec and must
	-- match the weapon's carry speed, or the movement penalty saturates before
	-- the player actually reaches full speed.
	accuracy = {
		base = 0.0025,       -- standing, first shot
		moving = 0.055,      -- added at full run, scaled by (speed/maxSpeed)^2
		air = 0.28,          -- the big one: airborne AK fire should be useless
		crouchMul = 0.75,
		perShot = 0.0015,    -- sustained-fire penalty, accumulates
		max = 0.25,
		recovery = 0.02,     -- radians/sec bled off after weapon_accuracy_delay
		maxSpeed = 16.0,
	},

	--=================================================================
	-- VIEWMODEL
	--=================================================================
	-- Overrides the shared viewmodel set. Anything omitted falls back to
	-- VM_ANIMS in AnimDefs, so a new weapon only needs its own poses.
	viewmodelAnims = {
		Idle   = { id = "rbxassetid://133400284253431", looped = true },
		Walk   = { id = "rbxassetid://133400284253431", looped = true },
		Jump   = { id = "rbxassetid://133400284253431", looped = true },
		Equip  = { id = "rbxassetid://102768111616257", looped = false, priority = Enum.AnimationPriority.Action3 },
		Fire   = { id = "rbxassetid://129844445349153", looped = false, priority = Enum.AnimationPriority.Action3 },
		Reload = { id = "rbxassetid://113364825280995", looped = false, priority = Enum.AnimationPriority.Action3 },
		Inspect = { id = "rbxassetid://102736398418428", looped = false, priority = Enum.AnimationPriority.Action3 },
	},

	-- Third-person hold pose, if you want one.
	puppetAnims = {},

	--=================================================================
	-- AUDIO / FX
	--=================================================================
	sounds = {
		Fire     = { id = "rbxassetid://76827549463931",    volume = 0.7, pitch = 1.0, pitchVar = 0.09,netKey = "fire_"..Name },
		DryFire  = { id = "rbxassetid://484110242",      volume = 0.4 },
		Reload   = { id = "rbxassetid://132828889771041", volume = 0.6, pitchVar = 0.05 ,netKey = "reload_"..Name  },
		Equip    = { id = "rbxassetid://137661611017878", volume = 0.5,pitchVar = 0.06 },
		Inspect  = { id = "rbxassetid://118779505214540", volume = 0.5,pitchVar = 0.12 },
		ScopeIn  = { id = "rbxassetid://0", volume = 0.4 },
		ScopeOut = { id = "rbxassetid://0", volume = 0.4 },
	},

	tracer = {
		color = Color3.fromRGB(255, 230, 150),
		width = 0.05,
		life = 0.06,
		chance = 1,          -- 0.25 = every fourth round, like real tracer belts
	},

	impact = {
		particles = 8,
		holeSize = 0.25,
	},
}