-- ModuleScript: ReplicatedStorage.Items.SmokeGrenade
--
-- A grenade is an ITEM whose use throws it. Everything about carrying one --
-- the slot, the cooldown, the animation, the fact that it is consumed -- is
-- the item system's job and none of it is restated here; what this file says
-- is which grenade it is and what happens when the pin comes out.
--
-- The THROW STYLE comes from the item's own data rather than from a second
-- key: a smoke grenade carries a `style` that the four-throw binds set, so
-- lobbing one is the same use path as throwing it. Default is a flat throw.
--
-- REQUIRED IN BOTH VMs. The registry loads every item module on the client
-- too -- that is where the stats, the animations and the world model come
-- from -- so nothing here may reach for a server-only module. The grenade
-- server is reached through the Registry, which is nil on a client and is
-- exactly why the hook below refuses rather than errors.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

return {
	name = "SmokeGrenade",
	slot = "utility",

	-- Having a useTime rather than a fireRate is what makes the trigger mean
	-- "throw" instead of "shoot". It is also the window the animation plays
	-- in and the floor on how often this can be used.
	useTime = 0.9,

	-- What it costs in the buy menu, beside everything else about it. See
	-- ReplicatedStorage.Economy.
	price = 300,
	killReward = 0,

	viewmodelAnims = {
		Idle  = { id = 0, looped = true },
		Use   = { id = 0, looped = false },
		Throw = { id = 0, looped = false },
	},

	server = {
		-- Returns "consume", because a thrown grenade is gone. The item
		-- system takes the slot and pushes the inventory; this does not have
		-- to know how either works.
		OnUse = function(plr, item, ctx)
			ctx.Animate("Throw")

			-- Found rather than required: this module is loaded on the
			-- client too, and a client reaching into Glacier1 is a module
			-- that fails to register and then has no viewmodel at all.
			local server = game:GetService("ServerScriptService")
			local glacier = server:FindFirstChild("Glacier1")
			local registry = glacier and glacier:FindFirstChild("Registry")
			local grenades = registry and require(registry).Grenades

			if not grenades then return false end

			-- ALT FIRE LOBS, exactly as CS:GO does it. The hint comes off
			-- the wire and is a name; GrenadeDefs falls back to a flat
			-- throw for anything it does not recognise, so a typo in a
			-- bind costs you a lineup rather than the grenade.
			local style = ctx.hint or (item.data and item.data.style) or "throw"
			local ok = grenades.Throw(plr, "smokegrenade", style)
			if not ok then return false end

			return "consume"
		end,
	},
}
