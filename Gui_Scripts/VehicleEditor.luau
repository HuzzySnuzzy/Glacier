-- LocalScript: VehicleEditor
-- Parent: PlayerGui  (it builds its own ScreenGui; the parent needs no children)
--
-- A panel for the car you are driving. Type a number, press Enter, keep
-- driving -- no respawn, no restart. `vedit` opens it.
--
-- WHY IT IS SO MUCH SMALLER THAN THE WEAPON EDITOR. A weapon module's table is
-- cached per VM, so every edit has to be applied on the server and broadcast
-- field by field, and a joining player has to have the whole set replayed at
-- them. A vehicle's tuning lives in ATTRIBUTES ON THE MODEL, and Roblox
-- replicates those: the server writes one attribute and every machine finds
-- out, including ones that join later.
--
-- So this panel has no local model of what has been changed and no receive
-- path. It reads the model's attributes, sends edits to the server, and
-- redraws when the model says something changed -- which is the same signal
-- that fires for somebody editing the same car in Studio's properties panel,
-- so the two cannot disagree.
--
-- Its ScreenGui is NOT named "Console" or "menu": Input treats those as modal,
-- and this panel wants the cursor without freezing the game. It manages that
-- itself through Input.SetModal while it is open.

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config      = require(ReplicatedStorage:WaitForChild("Config"))
local VehicleDefs = require(ReplicatedStorage:WaitForChild("VehicleDefs"))

local plr = Players.LocalPlayer

local function findClientModules()
	local candidates = {
		plr:FindFirstChild("PlayerScripts"),
		ReplicatedStorage,
		plr:FindFirstChild("PlayerGui"),
	}
	for _, parent in ipairs(candidates) do
		if parent then
			local folder = parent:FindFirstChild("Player")
			if folder and folder:FindFirstChild("Input") then return folder end
		end
	end
	return nil
end

local ClientModules = findClientModules()
if not ClientModules then
	error("[VehicleEditor] could not find the Player module folder.", 0)
end

local Input = require(ClientModules:WaitForChild("Input"))
local State = require(ClientModules:WaitForChild("State"))

local VehicleTune = ReplicatedStorage:WaitForChild("VehicleTune", 20)
if not VehicleTune then
	warn("[VehicleEditor] no VehicleTune remote -- is VehicleTuneServer in ServerScriptService.Glacier1?")
end

--=====================================================================
-- PALETTE  (matching WeaponEditor, so the two read as one tool)
--=====================================================================

local C = {
	bg       = Color3.fromRGB(14, 15, 18),
	bgLight  = Color3.fromRGB(24, 26, 31),
	line     = Color3.fromRGB(48, 52, 60),
	name     = Color3.fromRGB(105, 180, 255),
	value    = Color3.fromRGB(255, 200, 90),
	changed  = Color3.fromRGB(130, 225, 150),
	dim      = Color3.fromRGB(125, 130, 140),
}

--=====================================================================
-- UI
--=====================================================================

local gui = plr:WaitForChild("PlayerGui"):FindFirstChild("VehicleEditor")
if gui then
	gui:ClearAllChildren()
else
	gui = Instance.new("ScreenGui")
	gui.Name = "VehicleEditor"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 98
	gui.Parent = plr.PlayerGui
end
gui.Enabled = false

local ROW_HEIGHT = 24

local panel = Instance.new("Frame")
panel.Size = UDim2.new(0, 470, 0, 520)
panel.Position = UDim2.new(0, 24, 0, 120)
panel.BackgroundColor3 = C.bg
panel.BackgroundTransparency = 0.08
panel.BorderSizePixel = 0
panel.Parent = gui

local function corner(inst, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 5)
	c.Parent = inst
end
corner(panel)

local stroke = Instance.new("UIStroke")
stroke.Color = C.line
stroke.Parent = panel

local function label(parent, text, colour, size)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.Code
	l.TextSize = size or 14
	l.TextColor3 = colour or C.dim
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text or ""
	l.Parent = parent
	return l
end

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 26)
header.BackgroundColor3 = C.bgLight
header.BorderSizePixel = 0
header.Parent = panel
corner(header)

local title = label(header, "  vehicle editor", C.dim, 13)
title.Size = UDim2.new(1, -150, 1, 0)

local function button(parent, text, x, width)
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, x, 0.5, 0)
	b.Size = UDim2.new(0, width, 0, 17)
	b.BackgroundColor3 = C.line
	b.BackgroundTransparency = 0.35
	b.BorderSizePixel = 0
	b.Font = Enum.Font.Code
	b.TextSize = 12
	b.TextColor3 = C.dim
	b.Text = text
	b.Parent = parent
	corner(b, 3)
	return b
end

local closeButton = button(header, "close", -6, 42)
local resetButton = button(header, "reset", -52, 42)

local subtitle = label(panel, "", C.dim, 13)
subtitle.Position = UDim2.new(0, 10, 0, 28)
subtitle.Size = UDim2.new(1, -20, 0, 18)
subtitle.RichText = true

local list = Instance.new("ScrollingFrame")
list.Position = UDim2.new(0, 6, 0, 50)
list.Size = UDim2.new(1, -12, 1, -58)
list.BackgroundTransparency = 1
list.BorderSizePixel = 0
list.ScrollBarThickness = 5
list.ScrollBarImageColor3 = C.line
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new(0, 0, 0, 0)
list.Parent = panel

local listLayout = Instance.new("UIListLayout")
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding = UDim.new(0, 2)
listLayout.Parent = list

--------------------------------------------------------------
-- dragging
--------------------------------------------------------------

local dragging, dragStart, panelStart = false, nil, nil

header.InputBegan:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
	dragging = true
	dragStart = input.Position
	panelStart = panel.AbsolutePosition
end)

UserInputService.InputChanged:Connect(function(input)
	if not dragging or input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	local delta = input.Position - dragStart
	panel.Position = UDim2.new(0, panelStart.X + delta.X, 0, panelStart.Y + delta.Y)
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
end)

--=====================================================================
-- ROWS
--=====================================================================

local currentModel = nil
local currentConn = nil
local rows = {}          -- [attribute name] = { box, mark, field, default }

local function reply(text, isError)
	if type(Input.Reply) == "function" then
		Input.Reply(text)
	elseif isError then warn(text) else print(text) end
end

local function send(action, name, text)
	if not VehicleTune then
		reply("[vedit] the VehicleTune remote is missing", true)
		return
	end
	VehicleTune:FireServer(action, currentModel, name, text)
end

-- The green mark is the honest bit of the panel: it says this field has an
-- ATTRIBUTE on the model, overriding what the class ships. Which is also
-- exactly what survives -- attributes are saved with the model, so unlike the
-- weapon editor there is nothing here to export before you stop.
local function refreshRow(name)
	local row = rows[name]
	if not (row and currentModel) then return end

	local override = currentModel:GetAttribute(name)
	local value = override
	if value == nil then value = row.default end

	if not row.box:IsFocused() then
		row.box.Text = tostring(value)
	end

	row.box.TextColor3 = (override ~= nil) and C.changed or C.value
	row.mark.Text = (override ~= nil)
		and ("class " .. tostring(row.default))
		or ""
end

local function buildRow(entry, index)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.LayoutOrder = index
	row.BackgroundTransparency = 1
	row.Parent = list

	local name = label(row, entry.name, C.name, 14)
	name.Position = UDim2.new(0, 6, 0, 0)
	name.Size = UDim2.new(0, 180, 1, 0)

	local box = Instance.new("TextBox")
	box.Position = UDim2.new(0, 190, 0, 2)
	box.Size = UDim2.new(0, 90, 0, ROW_HEIGHT - 4)
	box.BackgroundColor3 = C.bgLight
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.Code
	box.TextSize = 14
	box.TextColor3 = C.value
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Text = tostring(entry.value)
	box.Parent = row
	corner(box, 3)

	-- One per row rather than a single reset button, because the useful
	-- gesture while tuning is "put THAT one back", not "start again".
	local clear = button(row, "x", -6, 18)
	clear.Position = UDim2.new(0, 286, 0.5, 0)
	clear.AnchorPoint = Vector2.new(0, 0.5)

	local mark = label(row, "", C.dim, 12)
	mark.Position = UDim2.new(0, 312, 0, 0)
	mark.Size = UDim2.new(1, -316, 1, 0)

	rows[entry.name] = {
		box = box, mark = mark, field = entry.field, default = entry.value,
	}

	box.FocusLost:Connect(function(enterPressed)
		if not enterPressed then
			-- Abandoned edit: put the live value back rather than leaving a
			-- half-typed number sitting there looking authoritative.
			refreshRow(entry.name)
			return
		end
		send("set", entry.name, box.Text)

		-- PUT THE LIVE VALUE BACK, immediately, rather than leaving what was
		-- typed sitting in the box.
		--
		-- The edit has not happened yet -- it is a request, and the server
		-- can refuse it: cheats off, not an admin, a number that is not a
		-- number. Leaving the typed text there shows a value the car is not
		-- using and makes the green override mark a lie, which is exactly how
		-- "vedit does not apply changes" looks from the outside.
		--
		-- An ACCEPTED edit comes straight back through AttributeChanged and
		-- redraws this row with the new number, so the only thing this costs
		-- is a frame. A REFUSED one visibly snaps back, which is the feedback
		-- that was missing entirely.
		refreshRow(entry.name)
	end)

	clear.Activated:Connect(function() send("reset", entry.name) end)

	return row
end

local function rebuild()
	if currentConn then currentConn:Disconnect() currentConn = nil end

	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	table.clear(rows)

	if not currentModel then
		subtitle.Text = "not driving"
		return
	end

	-- The CLASS def, not the tuned one: the row's "class" mark has to show
	-- what the car would be without its attributes, and reading the live def
	-- would show it what it already is.
	local def = VehicleDefs.GetOrDerive(currentModel:GetAttribute("Class"))
	local entries = VehicleDefs.TunableList(def)

	-- WHETHER EDITS WILL EVEN BE TAKEN, said up front.
	--
	-- The server gates this on sv_cheats and on being an admin, the same bar
	-- the weapon editor sits behind -- and sv_cheats is OFF by default. A
	-- panel that opens, lists everything, accepts typing and silently drops
	-- every edit is the worst possible way to communicate that.
	--
	-- The admin half cannot be checked from here (the list is the server's),
	-- so this reports the half it can see and names the other.
	local note = "live, and saved with the model"
	if Config.sv_cheats ~= true then
		note = "READ ONLY -- sv_cheats is 0, so the server will refuse edits"
	end

	subtitle.Text = ('<font color="#69B4FF">%s</font><font color="#7D828C">   %d settings   %s</font>')
		:format(currentModel.Name, #entries, note)

	for i, entry in ipairs(entries) do
		buildRow(entry, i)
		refreshRow(entry.name)
	end

	-- Redrawn from the MODEL rather than from our own send, so an edit made
	-- in Studio's properties panel, or by another admin, moves these rows too.
	-- It is the same signal the sim retunes on, so the panel cannot show a
	-- number the car is not using.
	currentConn = currentModel.AttributeChanged:Connect(function(name)
		if rows[name] then refreshRow(name) end
	end)
end

--=====================================================================
-- OPEN / CLOSE
--=====================================================================

local function drivenModel()
	-- Seat 1 only. A passenger is a passenger; letting them retune the car
	-- from the back seat is a different feature.
	if not State.inVehicle or State.vehicleSeat ~= 1 then return nil end
	return State.vehicleModel
end

local function setOpen(open)
	if gui.Enabled == open then return end
	gui.Enabled = open

	Input.SetModal("VehicleEditor", open)

	if open then
		currentModel = drivenModel()
		rebuild()
	elseif currentConn then
		currentConn:Disconnect()
		currentConn = nil
	end
end

-- Or the panel keeps saying READ ONLY after somebody turns cheats on, which
-- is the same failure in the other direction.
Config.OnChange("sv_cheats", function()
	if gui.Enabled and currentModel then rebuild() end
end)

closeButton.Activated:Connect(function() setOpen(false) end)
resetButton.Activated:Connect(function()
	if currentModel then send("resetall") end
end)

--=====================================================================
-- COMMANDS
--=====================================================================

Config.Command("vedit", {
	args = {},
	help = "open the tuning panel for the vehicle you are driving",
	run = function(ctx)
		local model = drivenModel()
		if not model then return false, "not driving a vehicle" end

		setOpen(true)
		if ctx and ctx.reply then
			ctx.reply(("[vedit] tuning %s -- changes are live and are saved with the model")
				:format(model.Name))
		end
		return true
	end,
})

-- The same list without the panel, for anyone setting attributes in Studio
-- rather than in game: "which knobs are there" should be answerable without
-- reading VehicleDefs.
Config.Command("vehicle_attrs", {
	args = { "string?" },
	help = "list the attributes a vehicle class accepts",
	run = function(ctx, class)
		local def = VehicleDefs.GetOrDerive(class
			or (State.vehicleModel and State.vehicleModel:GetAttribute("Class")))
		if not def then return false, "no such vehicle class" end

		local out = {}
		for _, entry in ipairs(VehicleDefs.TunableList(def)) do
			table.insert(out, ("  %-22s %s"):format(entry.name, tostring(entry.value)))
		end
		ctx.reply(("%s accepts %d attributes:\n%s")
			:format(def.label or "vehicle", #out, table.concat(out, "\n")))
		return true
	end,
})

Config.Command("vedit_close", {
	args = {},
	help = "close the vehicle editor",
	run = function() setOpen(false) end,
})

-- Getting out, or into a different car, with the panel open should follow --
-- or you end up editing a car you are no longer in.
task.spawn(function()
	while true do
		task.wait(0.25)
		if gui.Enabled then
			local model = drivenModel()
			if model ~= currentModel then
				currentModel = model
				rebuild()
			end
		end
	end
end)
