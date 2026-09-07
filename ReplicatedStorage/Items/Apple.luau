-- ModuleScript: ReplicatedStorage.Items.Apple
--
-- The smallest complete item, kept in the engine as the worked example: it is
-- what an author copies to make food, and it is what the harness runs to prove
-- the use path still works end to end.
--
-- Note what is NOT here. No slot bookkeeping, no remote, no "am I allowed to
-- do this" -- ItemServer has already decided the player is alive, is holding
-- this, and is off cooldown by the time OnUse runs. The item states what
-- happens and how it ends; the engine owns the rest.

-- REQUIRED IN BOTH VMs. The registry loads every item module on the client
-- too -- that is where the stats, the animations and the world model come
-- from -- so anything at the top of an item file has to be safe to require on
-- a client. Glacier is (its server verbs refuse rather than fail to load); a
-- ServerScriptService module is not, and an item that reaches for one fails
-- to register on the client and then has no viewmodel at all.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Glacier = require(ReplicatedStorage:WaitForChild("Glacier"))

local HEAL = 12

return {
	name = "Apple",
	slot = "utility",

	-- Having a useTime rather than a fireRate is what makes the trigger mean
	-- "eat" instead of "shoot". It is also the window the animation plays in
	-- and the floor on how often this can be used.
	useTime = 1.1,

	-- THE POSES, by whatever name this item wants to call them.
	--
	--   Idle    the holding pose. Looped, and played whenever nothing else
	--           is: this is what "holding an apple" looks like.
	--   Use     the default the engine plays when the trigger is pulled and
	--           the item does not choose something else itself.
	--   Bite    a name the engine has never heard of, played by the hook
	--           below. Anything not looped is treated as a one-shot and gets
	--           the priority that lets it override the held pose.
	--
	-- Ids may be written however you have them: the bare number the Toolbox
	-- shows, a pasted roblox.com link, or the full rbxassetid:// string. A
	-- BLANK id is a deliberate stub -- the track is skipped silently, so an
	-- item is playable before anybody has animated it.
	viewmodelAnims = {
		Idle = { id = 116630545706868, looped = true },
		Use  = { id = 116630545706868, looped = false },
		Bite = { id = 116630545706868, looped = false },
	},
	sounds = {},

	client = {
		-- PREDICTION. Runs the instant the key goes down, before the server
		-- has ruled on anything, which is what makes eating feel immediate.
		-- Playing it here rather than declaring Use and leaving it is the
		-- difference between "the engine's use animation" and this item's.
		OnUseStart = function(item, ctx)
			ctx.PlayAnim("Bite")
		end,
	},

	server = {
		OnUse = function(plr, item, ctx)
			-- SATURATION IS NOT BUILT YET, so this heals instead. When a
			-- hunger system lands, this line becomes Stats.AddSaturation and
			-- nothing else in the file changes -- which is the point of the
			-- item owning only its own effect.
			local before = Glacier.HealthOf(plr)
			if before and before.health and before.health >= 100 then
				-- A deliberate refusal, so the apple is not spent on nothing
				-- and the player is not put on a cooldown for asking.
				return false
			end

			Glacier.Heal(plr, HEAL)
			return "consume"
		end,
	},
}
