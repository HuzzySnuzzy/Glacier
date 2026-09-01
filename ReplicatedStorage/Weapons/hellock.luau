-- ModuleScript: Flintlock
-- Location: ReplicatedStorage.Weapons.Flintlock
--
-- One shot, then four seconds of muzzle-loading. Its character is carried
-- entirely by the accuracy cone, not the recoil pattern -- see the note on
-- pattern[1] below.
--
-- Smoothbore: no rifling, so `base` is roughly six times a rifle's and the
-- damage falls off fast and hard. Point blank it deletes people; past thirty
-- studs it is a coin toss.

local Name = "hellock"

return {
	name = Name,

	-- Which inventory slot this weapon may occupy: "primary", "secondary",
	-- "melee", or "any" (also the meaning of leaving it out) for a weapon
	-- that fits wherever it is put. Give/primary/secondary/melee all refuse
	-- a slot this forbids, so a pistol can never end up in the rifle slot.
	slot = "secondary",

	-- Movement speed while this is the ACTIVE weapon, in studs/second.
	-- CS:GO's MaxPlayerSpeed of 240 units -- pistol-weight.
	-- Applied as a ratio of mv_walkSpeed, so crouch and walk-key speeds
	-- scale with it. Omit the field for no penalty at all.
	maxPlayerSpeed = 21.82,
	isAuto = true,
	fireRate = 1610,        -- academic with a one-round magazine; the reload gates you
	magSize = 3,
	maxReserve = 24,
	reloadTime = 5.3,
	equipTime = 1,

	damage = 200,
	range = 700,

	armorRatio = 0.4,     -- lower = armour absorbs more; a soft lead ball does badly vs kevlar
	piercesHelmet = true, -- the one concession: it has to be able to one-tap, or why carry it
	falloffStart = 30,    -- studs before damage starts dropping
	falloffEnd = 140,
	falloffMin = 0.35,

	--=================================================================
	-- RECOIL
	--=================================================================
	-- IMPORTANT, and not a mistake: pattern[1] is zero, and with magSize = 1
	-- that is the ONLY entry this weapon will ever reach. Recoil.fire takes
	-- the delta between pattern[n] and pattern[n-1], so shot one always
	-- produces zero punch, and finishReload resets the index before the next.
	--
	-- The flintlock therefore has NO view kick. That is a real consequence of
	-- the model, not something these numbers can tune around: aim punch and
	-- view punch are the same angle, so any kick on shot one would also throw
	-- the bullet off the crosshair by the same amount. See the note below the
	-- module if you want the kick anyway.
	--
	-- Entries 2-4 are kept so the table is well-formed and so the weapon still
	-- behaves sanely if it is ever given a larger magazine.
	recoil = {
		scale = 1.0,
		variance = 0.6,
		jitterDegrees = 0.12,
		cooldownMul = 1.0,     -- NOTE: inside recoil, not at module top level
		pattern = {
			Vector2.new(0.00, 0.00),
			Vector2.new(0.40, 5.50),
			Vector2.new(0.90, 9.00),
			Vector2.new(1.30, 11.00),
		},
	},

	--=================================================================
	-- ACCURACY
	--=================================================================
	-- Half-angles in RADIANS. `base` is where the whole weapon lives: 0.012
	-- rad is about 0.7 degrees standing still, roughly six times the AK's, so
	-- even a perfectly still shot can miss a head at range.
	--
	-- perShot and recovery barely matter with one round in the gun, but they
	-- are left consistent so nothing behaves oddly if the magazine grows.
	accuracy = {
		base = 0.0020,
		moving = 0.090,      -- unwieldy: firing on the move is close to hopeless
		air = 0.70,
		crouchMul = 0.65,    -- bracing helps this weapon more than any other
		perShot = 0.0060,
		max = 0.14,
		recovery = 0.080,
		maxSpeed = 15.5,
	},

	--=================================================================
	-- VIEWMODEL
	--=================================================================
	viewmodelAnims = {
		Idle   = { id = "rbxassetid://122680614106220",  looped = true },
		Walk   = { id = "rbxassetid://122680614106220",  looped = true },
		Jump   = { id = "rbxassetid://122680614106220",  looped = true },
		Equip  = { id = "rbxassetid://94707324673914",  looped = false, priority = Enum.AnimationPriority.Action3 },
		Fire   = { id = "rbxassetid://94848668794888",  looped = false, priority = Enum.AnimationPriority.Action3 },
		Reload = { id = "rbxassetid://107110705834051", looped = false, priority = Enum.AnimationPriority.Action3 },
	},

	-- Third-person hold pose, if you want one.
	puppetAnims = {},

	--=================================================================
	-- AUDIO / FX
	--=================================================================
	sounds = {
		Fire     = { id = "rbxassetid://130315587754040", volume = 1.9, pitch = 0.72, pitchVar = 0.04, netKey = "fire_" .. Name },
		DryFire  = { id = "rbxassetid://96880586397913",  volume = 0.4, netKey = "dryfire_" .. Name },
		Reload   = { id = "rbxassetid://120851351364764",      volume = 0.6, netKey = "reload_" .. Name },
		Equip    = { id = "rbxassetid://120442595241809",  volume = 0.5, netKey = "equip_" .. Name },
		Inspect  = { id = "rbxassetid://0", volume = 0.5 },
		ScopeIn  = { id = "rbxassetid://0", volume = 0.4 },
		ScopeOut = { id = "rbxassetid://0", volume = 0.4 },
	},

	tracer = {
		color = Color3.fromRGB(255, 98, 46),
		width = 0.08,
		life = 0.09,
		chance = 1,
	},

	impact = {
		particles = 32,
		holeSize = 0.4,
	},
}