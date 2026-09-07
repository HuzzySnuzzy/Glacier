-- ModuleScript: ReplicatedStorage.Items.Torch
--
-- The other half of the example: an item that is not spent, and that carries
-- STATE.
--
-- `item.data` is the per-instance bag Inventory already gives every item, and
-- it survives a drop and a pickup -- so a lit torch thrown on the floor is
-- still lit when somebody else takes it, without this file knowing that drops
-- exist. The fields below are shared by every torch; anything in data belongs
-- to THIS one.

local LIGHT_NAME = "TorchLight"

-- Named so the hooks can read the item's own tuning without a self-require.
-- A module cannot require itself while it is still loading, and a hook that
-- tried would work in Studio and deadlock on a server under load.
local Torch = {
	name = "Torch",
	slot = "utility",

	-- Long enough to read as a deliberate action, short enough that toggling
	-- twice is not a chore.
	useTime = 0.35,

	brightness = 2.4,
	lightRange = 34,
	lightColor = Color3.fromRGB(255, 190, 120),

	viewmodelAnims = {},
	sounds = {},
}

Torch.server = {
	-- Toggles, and keeps itself: "keep" rather than "consume". The hook is
	-- handed the real item, not a copy, so this is the value that goes out in
	-- the inventory push ItemServer sends straight after.
	OnUse = function(plr, item, ctx)
		item.data.lit = not item.data.lit
		return "keep"
	end,
}

Torch.client = {
	-- Called with whatever model is currently representing this item -- today
	-- the viewmodel, and the puppet and the dropped pickup as those learn to
	-- call it. Which is why it takes the model rather than going looking for
	-- one: "the torch in your hands" and "the torch on the floor" are
	-- different searches and the item should not have to know either.
	--
	-- Idempotent on purpose. It runs on every rebuild, and a version that
	-- created a light each time would stack them until the scene glowed.
	OnRender = function(model, item, where)
		if not (model and model.PrimaryPart) then return end

		local light = model.PrimaryPart:FindFirstChild(LIGHT_NAME)
		if not light then
			light = Instance.new("PointLight")
			light.Name = LIGHT_NAME
			light.Parent = model.PrimaryPart
		end

		light.Brightness = Torch.brightness
		light.Range = Torch.lightRange
		light.Color = Torch.lightColor
		light.Shadows = true
		light.Enabled = (item and item.data and item.data.lit) == true
	end,
}

return Torch
