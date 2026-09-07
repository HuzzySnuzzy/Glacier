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

	viewmodelAnims = {},
	sounds = {},

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
