-- ModuleScript: ReplicatedStorage/SoundKeys
-- Shared client/server registry. The wire carries these keys; only the client
-- ever resolves one to an asset. Server requires this purely to allowlist
-- incoming keys and to know each sound's audible range for recipient culling.

local SoundKeys = {}

-- range is in studs. At Glacier's 1 stud = 11 units, 90 studs = ~1000 units,
-- which is roughly CS:GO footstep audibility.
SoundKeys.Defs = {
	step_default = { ids = {"rbxassetid://107959629397549"}, volume = 0.5, range = 90 },
	step_metal   = { ids = {"rbxassetid://107959629397549"}, volume = 0.6, range = 110 },
	step_soft    = { ids = {"rbxassetid://107959629397549"}, volume = 0.35, range = 60 },

	jump         = { ids = {"rbxasset://sounds/action_jump.mp3"}, volume = 0.5, range = 60 },
	land         = { ids = {"rbxassetid://137033663835090"}, volume = 0.6, range = 80 },

	-- Weapon keys. Add one per weapon; WeaponServer already speaks in keys.
	fire_default = { ids = {"rbxasset://sounds/action_get_up.mp3"}, volume = 0.8, range = 250 },
	dryfire      = { ids = {"rbxasset://sounds/action_get_up.mp3"}, volume = 0.3, range = 30 },
	
	
	fire_ak47 = { ids = {"rbxassetid://76827549463931"}, volume = 0.85, range = 300 },
	fire_M4A1 = { ids = {"rbxassetid://18511610136"}, volume = 0.85, range = 250 },
	fire_USP = { ids = {"rbxassetid://118438076092471"}, volume = 0.85, range = 250 },
	fire_Knife = { ids = {"rbxassetid://118786671060829"}, volume = 0.85, range = 50 },
	fire_glock = { ids = {"rbxassetid://139943212269145"}, volume = 0.85, range = 300 },
	
	reload_ak47 = { ids = {"rbxassetid://132828889771041"}, volume = 0.85, range = 55 },
	reload_M4A1 = { ids = {"rbxassetid://138089881272812"}, volume = 0.85, range = 55 },
	reload_USP = { ids = {"rbxassetid://3603370582"}, volume = 0.85, range = 55 },
	reload_Knife = { ids = {"rbxassetid://118786671060829"}, volume = 0.85, range = 50 },
	reload_glock = { ids = {"rbxassetid://5445945972"}, volume = 0.85, range = 55 },
}

-- Material -> step key. Anything unlisted falls back to step_default.
SoundKeys.MaterialStep = {
	[Enum.Material.Metal]        = "step_metal",
	[Enum.Material.DiamondPlate] = "step_metal",
	[Enum.Material.CorrodedMetal]= "step_metal",
	[Enum.Material.Grass]        = "step_soft",
	[Enum.Material.Sand]         = "step_soft",
	[Enum.Material.Snow]         = "step_soft",
	[Enum.Material.Fabric]       = "step_soft",
	[Enum.Material.Concrete]     = "step_default",
	[Enum.Material.Wood]         = "step_default",
	[Enum.Material.WoodPlanks]   = "step_default",
}

function SoundKeys.StepFor(material)
	return (material and SoundKeys.MaterialStep[material]) or "step_default"
end

return SoundKeys