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

-- Action3, not Action2: same-priority tracks blend by weight in Roblox, so a
-- Reload sharing Action2 with the held Idle pose underneath averages the two
-- and reads as a half-hearted reload. Action3 fully overrides the joints it
-- keys; joints it omits still fall through to the cycle track.
local ONE_SHOT_PRIORITY = Enum.AnimationPriority.Action3

-- Keys that are fired once by Visuals.PlayAnim rather than held by
-- updateLocomotion. Used only to pick a sane default priority.
local ONE_SHOTS = {
	Fire = true, FireAim = true, Reload = true, ReloadEmpty = true,
	Equip = true, Holster = true, Inspect = true, Jump = true,
	-- Eating, lighting a torch, applying a bandage.
	Use = true,
}

-- Is this pose fired once, or held?
--
-- The NAME LIST above cannot answer for an item, because an item may name its
-- animations anything it likes -- Bite, Chop, Swig -- and the whole point of
-- letting it is that the engine has never heard of them. So the shape of the
-- animation answers instead: a pose that is not looped is played once.
--
-- The list still wins where it applies, so nothing an existing weapon ships
-- changes priority underneath it. It is a fallback for a def that does not
-- say whether it loops, not a veto over one that does.
local function isOneShot(name, def)
	if ONE_SHOTS[name] then return true end
	return def.looped == false
end

-- Stamps the one-shot priority on anything that needs it and has not asked
-- for its own.
--
-- Action3, not Action2: same-priority tracks blend by weight in Roblox, so a
-- one-shot sharing Action2 with the held pose underneath averages the two and
-- reads as half-hearted. Copied before stamping, because `defs` may be the
-- item module's own table and mutating it would leak across every consumer of
-- that module for the session.
local function stamped(defs)
	local out = {}
	for name, def in pairs(defs or {}) do
		if type(def) == "table" and def.priority == nil and isOneShot(name, def) then
			out[name] = {
				id = def.id,
				looped = def.looped,
				priority = ONE_SHOT_PRIORITY,
			}
		else
			out[name] = def
		end
	end
	return out
end

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

	return stamped(out)
end

-- The FIRST-PERSON set, which used to be handed to the animator raw.
--
-- Every shipped weapon spells `priority = Action3` out by hand on each of its
-- one-shots, because nothing was stamping this side. That is fine for eight
-- weapons written by the person who knows to do it and a trap for the tenth
-- item somebody adds -- their Bite loads at Action2, blends with the held
-- pose, and looks like the animation is wrong rather than the priority.
--
-- An explicit priority still wins, so those eight weapons are unaffected.
function AnimDefs.ViewmodelSet(stats)
	if type(stats) ~= "table" then return {} end
	return stamped(stats.viewmodelAnims)
end

return AnimDefs