local Name = "M4A1"
return {
	name = Name,

	-- Which inventory slot this weapon may occupy: "primary", "secondary",
	-- "melee", or "any" (also the meaning of leaving it out) for a weapon
	-- that fits wherever it is put. Give/primary/secondary/melee all refuse
	-- a slot this forbids, so a pistol can never end up in the rifle slot.
	slot = "primary",

	-- Movement speed while this is the ACTIVE weapon, in studs/second.
	-- CS:GO's MaxPlayerSpeed of 225 units -- rifle.
	-- Applied as a ratio of mv_walkSpeed, so crouch and walk-key speeds
	-- scale with it. Omit the field for no penalty at all.
	maxPlayerSpeed = 20.45,
	isAuto = true,
	fireRate = 600,
	magSize = 24,
	maxReserve = math.huge,
	reloadTime = 3,
	damage = 22,
	range = 500,
	recoilPitch = 20.0,
	recoilRoll = 6.0,
	equipTime = .6, -- seconds before you can fire after drawing
	
	armorRatio = 0.5,     -- lower = armour absorbs more; CS pistols ~0.5, rifles ~1.5+
	piercesHelmet = false,
	falloffStart = 100,   -- studs before damage starts dropping
	falloffEnd = 400,
	falloffMin = 0.5,
	
	-- Overrides the shared viewmodel set. Anything omitted falls back to
	-- VM_ANIMS in Visuals, so a new weapon only needs its own poses.
	viewmodelAnims = {
		Idle = { id = "rbxassetid://137559072639289", looped = true },
		Walk = { id = "rbxassetid://137559072639289", looped = true },
		Jump = { id = "rbxassetid://137559072639289", looped = true },
		Equip = { id = "rbxassetid://136139380549535", looped = false, priority = Enum.AnimationPriority.Action3 },
		Fire   = { id = "rbxassetid://119868839472239", looped = false, priority = Enum.AnimationPriority.Action3 },
		Reload = { id = "rbxassetid://120131888397596", looped = false, priority = Enum.AnimationPriority.Action3 },
	},
	sounds = {
		Fire    = { id = "rbxassetid://18511610136", volume = 0.7, pitch = 1.0, pitchVar = 0.06,netKey = "fire_"..Name },
		DryFire = { id = "rbxassetid://484110242", volume = 0.4 },
		Reload  = { id = "rbxassetid://138089881272812", volume = 0.6,netKey = "reload_"..Name  },
		Equip   = { id = "rbxassetid://79849506844140", volume = 0.5 },
		Inspect = { id = "rbxassetid://0", volume = 0.5 },
		ScopeIn = { id = "rbxassetid://0", volume = 0.4 },
		ScopeOut= { id = "rbxassetid://0", volume = 0.4 },
	},

	recoil = {
		scale = 1.0,
		variance = 0.85,       -- silenced: more consistent than the AK
		jitterDegrees = 0.22,
		pattern = {
			Vector2.new( 0.00, 0.00), Vector2.new( 0.02, 0.85), Vector2.new( 0.06, 1.80),
			Vector2.new( 0.12, 2.80), Vector2.new( 0.14, 3.80), Vector2.new( 0.10, 4.75),
			Vector2.new( 0.00, 5.60), Vector2.new(-0.18, 6.30), Vector2.new(-0.45, 6.85),
			Vector2.new(-0.85, 7.25), Vector2.new(-1.35, 7.50), Vector2.new(-1.90, 7.65),
			Vector2.new(-2.35, 7.70), Vector2.new(-2.55, 7.65), Vector2.new(-2.45, 7.55),
			Vector2.new(-2.05, 7.45), Vector2.new(-1.40, 7.40), Vector2.new(-0.60, 7.40),
			Vector2.new( 0.25, 7.45), Vector2.new( 1.10, 7.55), Vector2.new( 1.80, 7.65),
			Vector2.new( 2.25, 7.70), Vector2.new( 2.40, 7.65), Vector2.new( 2.20, 7.55),
			Vector2.new( 1.70, 7.45),
		},
	},
	accuracy = {
		base = 0.0021, moving = 0.045, air = 0.24, crouchMul = 0.72,
		perShot = 0.0012, max = 0.22, recovery = 0.024, maxSpeed = 16.7,
	},
	cooldownMul = 1,
	
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
	
	-- Third-person hold pose, if you want one.
	puppetAnims = {},
}