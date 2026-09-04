-- LocalScript: WeaponEditor
-- Parent: PlayerGui  (it builds its own ScreenGui; the parent needs no children)
--
-- A panel for the weapon you are holding. Type a number, press Enter, fire the
-- gun -- no reload, no restart. `wedit` opens it.
--
-- WHY THE EDIT GOES TO THE SERVER: a weapon module's table is cached per VM.
-- Writing to it here would change this client's copy only, so the server would
-- still validate hits against the shipped numbers and everyone else would see
-- the old weapon. Every edit is sent, applied there, and broadcast back -- this
-- panel deliberately applies NOTHING locally, so what you see is always what
-- the server agreed to.
--
-- Its ScreenGui is NOT named "Console" or "menu": Input treats those as modal,
-- and this panel wants the cursor without freezing the game. It manages that
-- itself through Input.SetModal while it is open.

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config         = require(ReplicatedStorage:WaitForChild("Config"))
local WeaponTuning   = require(ReplicatedStorage:WaitForChild("WeaponTuning"))
local WeaponRegistry = require(ReplicatedStorage:WaitForChild("WeaponRegistry"))

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
	error("[WeaponEditor] could not find the Player module folder.", 0)
end

local Input = require(ClientModules:WaitForChild("Input"))
local State = require(ClientModules:WaitForChild("State"))

local WeaponTune = ReplicatedStorage:WaitForChild("WeaponTune", 20)
if not WeaponTune then
	warn("[WeaponEditor] no WeaponTune remote -- is WeaponTuneServer in ServerScriptService.Glacier1?")
end

--=====================================================================
-- PALETTE  (matching DevConsole, so the two read as one tool)
--=====================================================================

local C = {
	bg       = Color3.fromRGB(14, 15, 18),
	bgLight  = Color3.fromRGB(24, 26, 31),
	line     = Color3.fromRGB(48, 52, 60),
	accent   = Color3.fromRGB(90, 160, 255),
	name     = Color3.fromRGB(105, 180, 255),
	value    = Color3.fromRGB(255, 200, 90),
	changed  = Color3.fromRGB(130, 225, 150),
	dim      = Color3.fromRGB(125, 130, 140),
	error    = Color3.fromRGB(255, 110, 110),
}

--=====================================================================
-- UI
--=====================================================================

local gui = plr:WaitForChild("PlayerGui"):FindFirstChild("WeaponEditor")
if gui then
	gui:ClearAllChildren()
else
	gui = Instance.new("ScreenGui")
	gui.Name = "WeaponEditor"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 98
	gui.Parent = plr.PlayerGui
end
gui.Enabled = false

local ROW_HEIGHT = 24

local panel = Instance.new("Frame")
panel.Size = UDim2.new(0, 460, 0, 520)
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

local title = label(header, "  weapon editor", C.dim, 13)
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

local closeButton  = button(header, "close",  -6,  42)
local exportButton = button(header, "export", -52, 48)
local resetButton  = button(header, "reset",  -104, 42)

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

local currentClass = nil
local rows = {}          -- [path] = { box, mark }

local function reply(text, isError)
	if type(Input.Reply) == "function" then
		Input.Reply(text)
	elseif isError then warn(text) else print(text) end
end

local function send(action, class, path, value)
	if not WeaponTune then
		reply("[wedit] the WeaponTune remote is missing", true)
		return
	end
	WeaponTune:FireServer(action, class, path, value)
end

-- The green mark is the honest bit of the panel: it says a field differs from
-- what the module shipped with, which is the only thing that will be lost when
-- the server restarts.
local function refreshRow(path)
	local row = rows[path]
	if not row then return end

	local value = WeaponTuning.Get(currentClass, path)
	if not row.box:IsFocused() then
		row.box.Text = tostring(value)
	end

	local changed = WeaponTuning.IsChanged(currentClass, path)
	row.box.TextColor3 = changed and C.changed or C.value
	row.mark.Text = changed
		and ("was " .. tostring(WeaponTuning.Original(currentClass, path)))
		or ""
end

local function buildRow(path, index)
	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.LayoutOrder = index
	row.BackgroundTransparency = 1
	row.Parent = list

	local name = label(row, path, C.name, 14)
	name.Position = UDim2.new(0, 6, 0, 0)
	name.Size = UDim2.new(0, 190, 1, 0)

	local box = Instance.new("TextBox")
	box.Position = UDim2.new(0, 200, 0, 2)
	box.Size = UDim2.new(0, 90, 0, ROW_HEIGHT - 4)
	box.BackgroundColor3 = C.bgLight
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Enum.Font.Code
	box.TextSize = 14
	box.TextColor3 = C.value
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Text = tostring(WeaponTuning.Get(currentClass, path))
	box.Parent = row
	corner(box, 3)

	local mark = label(row, "", C.dim, 12)
	mark.Position = UDim2.new(0, 298, 0, 0)
	mark.Size = UDim2.new(1, -302, 1, 0)

	rows[path] = { box = box, mark = mark }

	box.FocusLost:Connect(function(enterPressed)
		if not enterPressed then
			-- Abandoned edit: put the live value back rather than leaving a
			-- half-typed number sitting there looking authoritative.
			refreshRow(path)
			return
		end
		send("set", currentClass, path, box.Text)
	end)

	return row
end

local function rebuild()
	for _, child in ipairs(list:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	table.clear(rows)

	if not currentClass then
		subtitle.Text = "not holding a weapon"
		return
	end

	local fields = WeaponTuning.Fields(currentClass)
	subtitle.Text = ('<font color="#69B4FF">%s</font><font color="#7D828C">   %d fields   edits are live and NOT saved -- export before you stop</font>')
		:format(currentClass, #fields)

	for i, path in ipairs(fields) do
		buildRow(path, i)
		refreshRow(path)
	end
end

--=====================================================================
-- OPEN / CLOSE
--=====================================================================

local function heldClass()
	local stats = State.currentWeaponStats
	return stats and WeaponRegistry.Class(stats.name) or nil
end

local function setOpen(open)
	if gui.Enabled == open then return end
	gui.Enabled = open

	-- The panel needs the cursor but not a frozen game, so it takes modal
	-- ownership by name rather than being listed in Input.MODAL_GUIS.
	Input.SetModal("WeaponEditor", open)

	if open then
		currentClass = heldClass()
		rebuild()
	end
end

closeButton.Activated:Connect(function() setOpen(false) end)

resetButton.Activated:Connect(function()
	if currentClass then send("resetall", currentClass) end
end)

exportButton.Activated:Connect(function()
	local text = currentClass and WeaponTuning.Export(currentClass)
	reply(text or "[wedit] nothing has been changed")
end)

-- The server applied it; this is where every VM finds out, including the one
-- that asked. Nothing is written locally anywhere else.
if WeaponTune then
	WeaponTune.OnClientEvent:Connect(function(action, class, path, value)
		if action ~= "set" then return end

		local applied = WeaponTuning.Set(class, path, value)
		if applied and class == currentClass and gui.Enabled then
			refreshRow(path)
		end
	end)
end

--=====================================================================
-- COMMANDS
--=====================================================================

Config.Command("wedit", {
	args = {},
	help = "open the weapon editor for the weapon you are holding",
	run = function(ctx)
		local class = heldClass()
		if not class then return false, "not holding a weapon" end

		setOpen(true)
		if ctx and ctx.reply then
			ctx.reply(("[wedit] editing %s -- changes are live, and lost on restart unless exported")
				:format(class))
		end
		return true
	end,
})

Config.Command("wedit_close", {
	args = {},
	help = "close the weapon editor",
	run = function() setOpen(false) end,
})

-- Switching weapons with the panel open should follow the weapon, or you end
-- up editing a rifle while holding a knife.
task.spawn(function()
	while true do
		task.wait(0.25)
		if gui.Enabled then
			local class = heldClass()
			if class and class ~= currentClass then
				currentClass = class
				rebuild()
			end
		end
	end
end)
