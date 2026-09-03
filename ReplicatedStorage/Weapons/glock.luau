-- ModuleScript: Glock
-- Location: ReplicatedStorage.Weapons.Glock
--
-- Self-contained: stats, recoil pattern, accuracy, animations, sounds, FX.
--
-- Design note: the Glock's identity is NOT its recoil, which is the mildest of
-- any pistol here. It is the base accuracy -- markedly worse than the USP-S --
-- traded against 20 rounds and a fast draw. Nerfing its pattern instead of its
-- cone would make it feel like a worse USP rather than a different gun.

local Name = "glock"

return {
	name = Name,

	-- Which inventory slot this weapon may occupy: "primary", "secondary",
	-- "melee", or "any" (also the meaning of leaving it out) for a weapon
	-- that fits wherever it is put. Give/primary/secondary/melee all refuse
	-- a slot this forbids, so a pistol can never end up in the rifle slot.
	slot = "secondary",

	-- Movement speed while this is the ACTIVE weapon, in studs/second.
	-- CS:GO's MaxPlayerSpeed of 240 units -- pistol.
	-- Applied as a ratio of mv_walkSpeed, so crouch and walk-key speeds
	-- scale with it. Omit the field for no penalty at all.
	maxPlayerSpeed = 21.82,
	isAuto = false,
	fireRate = 400,
	magSize = 20,
	maxReserve = 120,
	reloadTime = 2.2,
	equipTime = 0.5,      -- fastest draw of the pistols

	damage = 30,
	range = 500,

	armorRatio = 0.47,    -- lower = armour absorbs more; CS pistols ~0.5, rifles ~1.5+
	piercesHelmet = false,
	falloffStart = 100,   -- studs before damage starts dropping
	falloffEnd = 400,
	falloffMin = 0.5,

	--=================================================================
	-- RECOIL
	--=================================================================
	-- Absolute view offsets in degrees; the Recoil module derives per-shot
	-- deltas. pattern[1] must be zero so the first bullet is dead centre.
	--   .X = yaw (+ right), .Y = pitch (+ up)
	--
	-- 20 entries for the magazine. Total climb ~4 deg spread over 20 shots,
	-- so the per-shot step is smaller than the USP's despite reaching a
	-- similar endpoint -- a Glock spray drifts rather than climbs.
	recoil = {
		scale = 1.0,
		variance = 0.75,       -- looser than the silenced USP-S
		jitterDegrees = 0.18,
		cooldownMul = 0.45,    -- NOTE: inside recoil, not at module top level.
		-- Semi-autos need a short cooldown or a normal
		-- tap rhythm never resets the pattern index.
		pattern = {
			Vector2.new( 0.00, 0.00), Vector2.new( 0.02, 0.45), Vector2.new( 0.06, 0.90),
			Vector2.new( 0.08, 1.35), Vector2.new( 0.06, 1.75), Vector2.new( 0.00, 2.10),
			Vector2.new(-0.10, 2.45), Vector2.new(-0.22, 2.75), Vector2.new(-0.35, 3.00),
			Vector2.new(-0.45, 3.20), Vector2.new(-0.50, 3.38), Vector2.new(-0.48, 3.52),
			Vector2.new(-0.40, 3.64), Vector2.new(-0.26, 3.74), Vector2.new(-0.08, 3.82),
			Vector2.new( 0.12, 3.88), Vector2.new( 0.32, 3.94), Vector2.new( 0.48, 3.98),
			Vector2.new( 0.58, 4.02), Vector2.new( 0.60, 4.05),
		},
	},

	--=================================================================
	-- ACCURACY (the cone -- separate from recoil, seeded server-side)
	--=================================================================
	-- Half-angles in RADIANS. maxSpeed is studs/sec and must match the
	-- weapon's carry speed, or the movement penalty saturates before the
	-- player actually reaches full speed.
	--
	-- `base` is the whole balance lever here: ~60% wider than the USP-S even
	-- standing still and untapped. `air` stays low so jump-shooting remains a
	-- pistol thing.
	accuracy = {
		base = 0.0032,
		moving = 0.052,
		air = 0.19,
		crouchMul = 0.82,
		perShot = 0.0048,    -- big penalty, bled off fast: pace your taps
		max = 0.14,
		recovery = 0.075,
		maxSpeed = 17.9,
	},

	--=================================================================
	-- VIEWMODEL
	--=================================================================
	-- Overrides the shared viewmodel set. Anything omitted falls back to
	-- VM_ANIMS in AnimDefs, so a new weapon only needs its own poses.
	viewmodelAnims = {
		Idle   = { id = "rbxassetid://74870650445409",  looped = true },
		Walk   = { id = "rbxassetid://74870650445409",  looped = true },
		Jump   = { id = "rbxassetid://74870650445409",  looped = true },
		Equip  = { id = "rbxassetid://117708407458597", looped = false, priority = Enum.AnimationPriority.Action3 },
		Fire   = { id = "rbxassetid://74652839617591",  looped = false, priority = Enum.AnimationPriority.Action3 },
		Reload = { id = "rbxassetid://114696730123250", looped = false, priority = Enum.AnimationPriority.Action3 },
	},

	-- Third-person hold pose, if you want one.
	puppetAnims = {},

	--=================================================================
	-- AUDIO / FX
	--=================================================================
	sounds = {
		Fire     = { id = "rbxassetid://139943212269145", volume = 0.7, pitch = 1.0, pitchVar = 0.12, netKey = "fire_" .. Name },
		DryFire  = { id = "rbxassetid://96880586397913",  volume = 0.4, netKey = "dryfire_" .. Name },
		Reload   = { id = "rbxassetid://5445945972",      volume = 0.7, netKey = "reload_" .. Name },
		Equip    = { id = "rbxassetid://137595180744957",  volume = 0.65, netKey = "equip_" .. Name },
		Inspect  = { id = "rbxassetid://0", volume = 0.5 },
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