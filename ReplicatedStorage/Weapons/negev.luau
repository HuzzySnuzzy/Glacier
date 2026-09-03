-- ModuleScript: Negev
-- Location: ReplicatedStorage.Weapons.Negev
--
-- The spin-up gun. Cold, it is the least accurate weapon in the game; after
-- roughly seven rounds of sustained fire it is the most accurate. That is
-- carried by a NEGATIVE accuracy.perShot -- see accuracy.min below -- and it
-- requires the signed-accumulation edit in Recoil.fire/Recoil.step.
--
-- Consequences worth knowing:
--  * The pattern deliberately stops moving after entry 40. patternAt clamps to
--    the last entry, so shots 41-150 produce a zero delta and the gun holds
--    steady rather than climbing off the top of the screen.
--  * cooldownMul is short, so the index (and with it the spin-up) is lost
--    quickly after the trigger releases. Tapping a Negev should feel awful.

local Name = "negev"

return {
	name = Name,

	-- Which inventory slot this weapon may occupy: "primary", "secondary",
	-- "melee", or "any" (also the meaning of leaving it out) for a weapon
	-- that fits wherever it is put. Give/primary/secondary/melee all refuse
	-- a slot this forbids, so a pistol can never end up in the rifle slot.
	slot = "primary",

	-- Movement speed while this is the ACTIVE weapon, in studs/second.
	-- CS:GO's MaxPlayerSpeed of 150 units -- an LMG should feel like carrying an LMG.
	-- Applied as a ratio of mv_walkSpeed, so crouch and walk-key speeds
	-- scale with it. Omit the field for no penalty at all.
	maxPlayerSpeed = 13.64,
	isAuto = true,
	fireRate = 800,
	magSize = 150,
	maxReserve = 200,
	reloadTime = 5.7,
	equipTime = 1.4,      -- heaviest deploy in the game

	damage = 35,
	range = 500,

	armorRatio = 1.75,    -- lower = armour absorbs more; CS pistols ~0.5, rifles ~1.5+
	piercesHelmet = false,
	falloffStart = 180,   -- studs before damage starts dropping
	falloffEnd = 520,
	falloffMin = 0.60,

	--=================================================================
	-- RECOIL
	--=================================================================
	-- Absolute view offsets in degrees; the Recoil module derives per-shot
	-- deltas. pattern[1] must be zero so the first bullet is dead centre.
	--   .X = yaw (+ right), .Y = pitch (+ up)
	--
	-- Shots 1-10 thrash: the horizontal swings past +/-2.8 deg while climbing
	-- almost the full 9 deg. From 11 on it converges to a near-vertical hold
	-- around 10 deg and stays there. Holding the trigger is the reward.
	recoil = {
		scale = 1.0,
		variance = 1.0,
		jitterDegrees = 0.30,
		cooldownMul = 0.6,     -- NOTE: inside recoil, not at module top level
		pattern = {
			Vector2.new( 0.00,  0.00), Vector2.new( 0.80,  1.60), Vector2.new(-1.20,  3.20),
			Vector2.new( 1.90,  4.70), Vector2.new(-2.40,  6.00), Vector2.new( 2.80,  7.00),
			Vector2.new(-2.60,  7.80), Vector2.new( 2.20,  8.40), Vector2.new(-1.70,  8.80),
			Vector2.new( 1.20,  9.10), Vector2.new(-0.80,  9.30), Vector2.new( 0.50,  9.45),
			Vector2.new(-0.30,  9.55), Vector2.new( 0.20,  9.62), Vector2.new(-0.15,  9.68),
			Vector2.new( 0.10,  9.72), Vector2.new(-0.08,  9.75), Vector2.new( 0.06,  9.78),
			Vector2.new(-0.05,  9.80), Vector2.new( 0.04,  9.82), Vector2.new(-0.03,  9.84),
			Vector2.new( 0.03,  9.86), Vector2.new(-0.02,  9.87), Vector2.new( 0.02,  9.89),
			Vector2.new(-0.02,  9.90), Vector2.new( 0.02,  9.92), Vector2.new(-0.02,  9.93),
			Vector2.new( 0.02,  9.94), Vector2.new(-0.02,  9.96), Vector2.new( 0.02,  9.97),
			Vector2.new(-0.02,  9.98), Vector2.new( 0.02,  9.99), Vector2.new(-0.02, 10.00),
			Vector2.new( 0.02, 10.01), Vector2.new(-0.02, 10.02), Vector2.new( 0.02, 10.03),
			Vector2.new(-0.02, 10.04), Vector2.new( 0.02, 10.05), Vector2.new(-0.02, 10.06),
			Vector2.new( 0.02, 10.07),
		},
	},

	--=================================================================
	-- ACCURACY -- the spin-up
	--=================================================================
	-- Half-angles in RADIANS.
	--
	-- base 0.021 rad is ~1.2 degrees of cone before you have fired a shot,
	-- roughly ten times the AK's. perShot is NEGATIVE, so each round pulls the
	-- total down; min caps how far, landing at 0.002 (tighter than any rifle)
	-- after about seven rounds.
	--
	-- recovery runs the penalty back toward zero from either side, so ~0.6s
	-- off the trigger throws the spin-up away entirely.
	accuracy = {
		base = 0.0210,
		min = -0.0190,       -- REQUIRES the signed clamp in Recoil.fire
		max = 0.0210,
		perShot = -0.0035,   -- negative: sustained fire TIGHTENS the cone
		recovery = 0.0300,
		moving = 0.075,      -- heaviest gun: moving hurts more than a rifle
		air = 0.34,
		crouchMul = 0.70,
		maxSpeed = 14.5,     -- slowest carry speed in the game
	},

	--=================================================================
	-- VIEWMODEL
	--=================================================================
	-- All six currently point at one asset. Equip/Fire/Reload are one-shots on
	-- Action3 and will hard-cut the looped Idle using the same clip until they
	-- get their own animations.
	viewmodelAnims = {
		Idle   = { id = "rbxassetid://113582821442827", looped = true },
		Walk   = { id = "rbxassetid://113582821442827", looped = true },
		Jump   = { id = "rbxassetid://113582821442827", looped = true },
		Equip  = { id = "rbxassetid://113582821442827", looped = false, priority = Enum.AnimationPriority.Action3 },
		Fire   = { id = "rbxassetid://72304062356227", looped = false, priority = Enum.AnimationPriority.Action3 },
		Reload = { id = "rbxassetid://113582821442827", looped = false, priority = Enum.AnimationPriority.Action3 },
		Inspect = { id = "rbxassetid://102736398418428", looped = false, priority = Enum.AnimationPriority.Action3 },
	},

	-- Third-person hold pose, if you want one.
	puppetAnims = {},

	--=================================================================
	-- AUDIO / FX
	--=================================================================
	sounds = {
		Fire     = { id = "rbxassetid://1112852139",     volume = 0.7, pitch = 0.92, pitchVar = 0.05, netKey = "fire_" .. Name },
		DryFire  = { id = "rbxassetid://484110242",       volume = 0.4, netKey = "dryfire_" .. Name },
		Reload   = { id = "rbxassetid://128335101203632", volume = 0.6, netKey = "reload_" .. Name },
		Equip    = { id = "rbxassetid://79849506844140",  volume = 0.5, netKey = "equip_" .. Name },
		Inspect  = { id = "rbxassetid://0", volume = 0.5 },
		ScopeIn  = { id = "rbxassetid://0", volume = 0.4 },
		ScopeOut = { id = "rbxassetid://0", volume = 0.4 },
	},

	tracer = {
		color = Color3.fromRGB(255, 225, 140),
		width = 0.06,
		life = 0.05,
		chance = 1,       -- belt-fed: every fourth round, like real tracer belts
	},

	impact = {
		particles = 8,
		holeSize = 0.25,
	},
}