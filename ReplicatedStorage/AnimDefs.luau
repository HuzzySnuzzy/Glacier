-- ModuleScript: ReplicatedStorage.AnimDefs
local AnimDefs = {}

AnimDefs.PUPPET = {
	Idle       = { id = "rbxassetid://180435571", looped = true },
	Walk       = { id = "rbxassetid://180426354", looped = true },
	Sprint     = { id = "rbxassetid://180426354", looped = true },
	CrouchIdle = { id = "rbxassetid://93982763269456", looped = true },
	CrouchWalk = { id = "rbxassetid://96717730795568", looped = true },
	Jump       = { id = "rbxassetid://125750702", looped = false },
	Fall       = { id = "rbxassetid://180436148", looped = true },
}

AnimDefs.VIEWMODEL = {
	Idle       = { id = "rbxassetid://125750544", looped = true },
	Walk       = { id = "rbxassetid://125749145", looped = true },
	-- ...
}

-- Keys that are fired once by Visuals.PlayAnim rather than held by
-- updateLocomotion. Used only to pick a sane default priority.
local ONE_SHOTS = {
	Fire = true, FireAim = true, Reload = true, ReloadEmpty = true,
	Equip = true, Holster = true, Inspect = true, Jump = true,
}

-- Action3, not Action2: same-priority tracks blend by weight in Roblox, so a
-- Reload sharing Action2 with the held Idle pose underneath averages the two
-- and reads as a half-hearted reload. Action3 fully overrides the joints it
-- keys; joints it omits still fall through to the cycle track.
local ONE_SHOT_PRIORITY = Enum.AnimationPriority.Action3

-- Which set a weapon contributes to the third-person puppet.
-- shared = true starts from the viewmodel poses; puppetAnims layers on top
-- either way, so a weapon can override one pose without disabling the cvar.
function AnimDefs.WeaponSet(stats, shared)
	if type(stats) ~= "table" then return {} end

	local out = {}

	if shared then
		for name, def in pairs(stats.viewmodelAnims or {}) do
			out[name] = def
		end
	end

	for name, def in pairs(stats.puppetAnims or {}) do
		out[name] = def
	end

	-- `stats.puppetAnims or stats.viewmodelAnims` never fell through, because
	-- an empty table is truthy in Lua -- and AK47 ships `puppetAnims = {}`.
	-- With shared off, that silently produced no weapon layer at all.
	if next(out) == nil then
		for name, def in pairs(stats.viewmodelAnims or {}) do
			out[name] = def
		end
	end

	-- Copy before stamping a priority: `out` may still hold references to the
	-- weapon module's own table, and mutating those would leak across every
	-- consumer of that module for the session.
	for name, def in pairs(out) do
		if ONE_SHOTS[name] and type(def) == "table" and def.priority == nil then
			out[name] = {
				id = def.id,
				looped = def.looped,
				priority = ONE_SHOT_PRIORITY,
			}
		end
	end

	return out
end

return AnimDefs