local Name = "Non"
return {
	name = Name,

	-- Which inventory slot this weapon may occupy: "primary", "secondary",
	-- "melee", or "any" (also the meaning of leaving it out) for a weapon
	-- that fits wherever it is put. Give/primary/secondary/melee all refuse
	-- a slot this forbids, so a pistol can never end up in the rifle slot.
	slot = "any",

	-- Movement speed while this is the ACTIVE weapon, in studs/second.
	-- CS:GO's MaxPlayerSpeed of 250 units -- the fastest thing you can hold, which is the point of switching to it.
	-- Applied as a ratio of sv_maxspeed, so crouch and walk-key speeds
	-- scale with it. Omit the field for no penalty at all.
	maxPlayerSpeed = 25.73,
	isAuto = false,
	fireRate = 100,
	magSize = math.huge,
	maxReserve = math.huge,
	reloadTime = 0,
	damage = 5.2,
	range = 5,
	recoilPitch = 0.0,
	recoilRoll = 0.0,
	equipTime = .5, -- seconds before you can fire after drawing

	armorRatio = 0.5,     -- lower = armour absorbs more; CS pistols ~0.5, rifles ~1.5+
	piercesHelmet = true,
	falloffStart = 100,   -- studs before damage starts dropping
	falloffEnd = 400,
	falloffMin = 0.5,

	-- Overrides the shared viewmodel set. Anything omitted falls back to
	-- VM_ANIMS in Visuals, so a new weapon only needs its own poses.
	viewmodelAnims = {
		Idle = { id = "rbxassetid://180435571", looped = true },
		Walk = { id = "rbxassetid://180426354", looped = true },
		Jump = { id = "rbxassetid://125750702", looped = true },
		Equip = { id = "rbxassetid://180435792", looped = false, priority = Enum.AnimationPriority.Action3 },
		Fire   = { id = "rbxassetid://128853357", looped = false, priority = Enum.AnimationPriority.Action3 },
		Inspect = { id = "rbxassetid://128777973", looped = false, priority = Enum.AnimationPriority.Action3 },
	},
	sounds = {
		Fire    = { id = "rbxassetid://137832890763917", volume = 0.7, pitch = 1.0, pitchVar = 0.06,netKey = "fire_"..Name },
		DryFire = { id = "rbxassetid://118786671060829", volume = 0.4 },
		Reload  = { id = "rbxassetid://118786671060829", volume = 0.6,netKey = "reload_"..Name },
		Equip   = { id = "rbxassetid://120927697011937", volume = 0.5 },
		Inspect = { id = "rbxassetid://134342749421977", volume = 0.5, pitchVar = 0.06, netKey = "inspect_"..Name },
		ScopeIn = { id = "rbxassetid://0", volume = 0.4 },
		ScopeOut= { id = "rbxassetid://0", volume = 0.4 },
	},
	recoil = {
		scale = 1.0,
		variance = 0.6,
		jitterDegrees = 0.12,
		pattern = {
			Vector2.new( 0.00, 0.00), Vector2.new( 0.03, 0.55), Vector2.new( 0.08, 1.10),
			Vector2.new( 0.10, 1.65), Vector2.new( 0.05, 2.15), Vector2.new(-0.05, 2.60),
			Vector2.new(-0.20, 3.00), Vector2.new(-0.35, 3.35), Vector2.new(-0.45, 3.60),
			Vector2.new(-0.45, 3.80), Vector2.new(-0.35, 3.95), Vector2.new(-0.20, 4.05),
		},
	},
	accuracy = {
		base = 0.0020, moving = 0.048, air = 0.16, crouchMul = 0.80,
		perShot = 0.0060, max = 0.12, recovery = 0.080, maxSpeed = 17.9,
	},
	cooldownMul = 0.45,

	tracer = {
		color = Color3.fromRGB(255, 230, 150),
		width = 0.05,
		life = 0.06,
		chance = 0,          -- 0.25 = every fourth round, like real tracer belts
	},
	impact = {
		particles = 8,
		holeSize = 0.25,
	},

	-- Third-person hold pose, if you want one.
	puppetAnims = {},
}