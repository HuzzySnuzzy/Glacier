-- Script: HullGenerator (child of glacier1)
-- Converts parts tagged "slope" into invisible, perfectly flush OBB clip brushes.

local CollectionService = game:GetService("CollectionService")

local function GenerateWedgeCollision(wedge)
	-- Prevent duplicate generations
	if wedge:GetAttribute("ClipBrushGenerated") then return end
	wedge:SetAttribute("ClipBrushGenerated", true)

	-- Disable original mesh physics
	wedge.CanCollide = false
	wedge.CanQuery = false

	local width = wedge.Size.X
	local height = wedge.Size.Y
	local depth = wedge.Size.Z

	-- 1. Calculate the Local Vectors for the sloped face.
	-- Standard Roblox wedges are thick at the back (+Z) and thin at the front (-Z).
	local N_local = Vector3.new(0, depth, -height).Unit  -- Normal (Points Up and Forward)
	local D_local = Vector3.new(0, -height, -depth).Unit -- Downward slope direction
	local R_local = Vector3.new(1, 0, 0)                 -- Right direction

	-- If the custom mesh was modeled backwards (thick front, thin back), flip the math.
	if wedge:GetAttribute("FlipSlope") == true then
		N_local = Vector3.new(0, depth, height).Unit
		D_local = Vector3.new(0, -height, depth).Unit
		R_local = Vector3.new(-1, 0, 0)
	end

	-- 2. Convert Local Vectors to World Space using the mesh's rotation
	local n_world = wedge.CFrame:VectorToWorldSpace(N_local)
	local d_world = wedge.CFrame:VectorToWorldSpace(D_local)
	local r_world = wedge.CFrame:VectorToWorldSpace(R_local)

	-- 3. Calculate Brush Dimensions
	local brushThickness = 2
	local slopeLength = math.sqrt(height^2 + depth^2)

	local slopeBrush = Instance.new("Part")
	slopeBrush.Name = "WedgeClipBrush_" .. wedge.Name
	slopeBrush.Anchored = true
	slopeBrush.CanCollide = true
	slopeBrush.CanQuery = true
	slopeBrush.Size = Vector3.new(width, brushThickness, slopeLength)

	-- 4. Position and Align the Brush
	-- The center of the bounding box lies exactly on the sloped plane.
	-- We push the brush down its local Y-axis by half its thickness so its top face is flush.
	local brushPos = wedge.Position - (n_world * (brushThickness / 2))

	-- CFrame.fromMatrix maps (Position, Right, Up, -Look)
	slopeBrush.CFrame = CFrame.fromMatrix(brushPos, r_world, n_world, -d_world)

	-- Visual debugging (Set Transparency to 1 when you are ready to hide them)
	slopeBrush.Transparency = 1 
	slopeBrush.Color = Color3.new(1, 0, 0)
	slopeBrush.Parent = wedge.Parent
end

for _, obj in ipairs(CollectionService:GetTagged("slope")) do
	GenerateWedgeCollision(obj)
end

CollectionService:GetInstanceAddedSignal("slope"):Connect(function(obj)
	GenerateWedgeCollision(obj)
end)

print("[HullGenerator] Clip brushes generated correctly.")