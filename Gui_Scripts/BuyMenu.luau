-- LocalScript: BuyMenu
-- Parent: PlayerGui (its own ScreenGui, built in code)
--
-- CS's buy menu, and the reason it is worth writing carefully is that it is a
-- menu you use under fire: the whole of its job is to be readable in half a
-- second and to never lie about what will happen when you press the button.
--
-- IT DOES NOT DECIDE ANYTHING. Every rule -- the price, the balance, whether
-- you are alive, whether you are standing in a buy zone -- is in
-- ReplicatedStorage.Economy and enforced by the server. This asks the same
-- module the server does, so a row it greys out is exactly a row the server
-- would refuse, and a row it offers is one that will work. A menu that gets
-- that wrong is worse than no menu: it teaches you to distrust it.
--
-- What it CANNOT know is where you are standing. The server answers that, and
-- rather than guess, the menu shows the reason the last purchase was refused.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Config  = require(ReplicatedStorage:WaitForChild("Config"))
local Economy = require(ReplicatedStorage:WaitForChild("Economy"))

local plr = Players.LocalPlayer
local playerGui = plr:WaitForChild("PlayerGui")

local Kit = ReplicatedStorage:FindFirstChild("MenuKit")
	or playerGui:FindFirstChild("MainMenu") and playerGui.MainMenu:FindFirstChild("MenuKit")
-- The kit lives with the main menu. Found rather than required by path,
-- because this script is not under it and hard-coding the path is how a
-- file move turns into a crash on join.
local C
if Kit then
	Kit = require(Kit)
	C = Kit.C
else
	C = {
		panel = Color3.fromRGB(20, 22, 27),
		raised = Color3.fromRGB(30, 33, 40),
		line = Color3.fromRGB(52, 57, 66),
		text = Color3.fromRGB(226, 230, 238),
		dim = Color3.fromRGB(132, 139, 152),
		faint = Color3.fromRGB(88, 94, 105),
		accent = Color3.fromRGB(90, 160, 255),
		good = Color3.fromRGB(130, 225, 150),
		warn = Color3.fromRGB(255, 200, 90),
		danger = Color3.fromRGB(255, 105, 105),
	}
end

local BuyRequest = ReplicatedStorage:WaitForChild("BuyRequest")
local BuyReport  = ReplicatedStorage:WaitForChild("BuyReport")

--=====================================================================
-- HOW THE ROWS ARE GROUPED
--=====================================================================
-- By SLOT, which the catalogue already carries, so a gun added to the
-- registry with a price lands in the right column without this file being
-- told about it. The order is CS's: what you reach for first is leftmost.
local COLUMNS = {
	{ slot = "secondary", title = "PISTOLS" },
	{ slot = "primary",   title = "RIFLES & HEAVY" },
	{ slot = "utility",   title = "GRENADES" },
	{ slot = "gear",      title = "EQUIPMENT" },
}

local COLUMN_FOR = {}
for index, column in ipairs(COLUMNS) do COLUMN_FOR[column.slot] = index end

--=====================================================================
-- BUILD
--=====================================================================

local gui, panel, moneyLabel, statusLabel
local rows = {}

local function money()
	return Economy.Clamp(plr:GetAttribute("Money"))
end

local function label(parent, text, colour, size, bold)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextSize = size or 14
	l.TextColor3 = colour or C.text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text or ""
	l.Parent = parent
	return l
end

local function buildRow(parent, entry, index)
	local button = Instance.new("TextButton")
	button.Name = entry.class
	button.Size = UDim2.new(1, 0, 0, 30)
	button.LayoutOrder = index
	button.BackgroundColor3 = C.raised
	button.BackgroundTransparency = 0.35
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Text = ""
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 5)
	corner.Parent = button

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 9)
	pad.PaddingRight = UDim.new(0, 9)
	pad.Parent = button

	local name = label(button, entry.class, C.text, 14)
	name.Size = UDim2.new(1, -70, 1, 0)

	local price = label(button, "", C.dim, 13)
	price.Size = UDim2.new(0, 62, 1, 0)
	price.Position = UDim2.new(1, -62, 0, 0)
	price.TextXAlignment = Enum.TextXAlignment.Right

	-- THE NUMBER KEY, because that is how anybody who has played CS buys: the
	-- mouse is for aiming and the menu is muscle memory. Shown so it can be
	-- learned rather than discovered.
	local key = label(button, "", C.faint, 11)
	key.Size = UDim2.new(0, 16, 1, 0)
	key.Position = UDim2.new(1, -62 - 18, 0, 0)
	key.TextXAlignment = Enum.TextXAlignment.Right

	button.Activated:Connect(function()
		BuyRequest:FireServer("buy", entry.class)
	end)

	return { button = button, name = name, price = price, key = key, entry = entry }
end

local function build()
	if gui then return end

	gui = Instance.new("ScreenGui")
	gui.Name = "BuyMenu"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 40
	gui.Enabled = false
	gui.Parent = playerGui

	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 720, 0, 420)
	panel.BackgroundColor3 = C.panel
	panel.BackgroundTransparency = 0.06
	panel.BorderSizePixel = 0
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = C.line
	stroke.Transparency = 0.35
	stroke.Parent = panel

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 14)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = panel

	local header = Instance.new("Frame")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 26)
	header.Parent = panel

	label(header, "BUY", C.text, 17, true).Size = UDim2.new(0, 80, 1, 0)

	moneyLabel = label(header, "", C.good, 17, true)
	moneyLabel.Size = UDim2.new(0, 200, 1, 0)
	moneyLabel.Position = UDim2.new(1, -200, 0, 0)
	moneyLabel.TextXAlignment = Enum.TextXAlignment.Right

	-- WHY THE LAST ONE WAS REFUSED, and this line is most of the value of
	-- the menu. Everything the client cannot know -- the buy zone, the buy
	-- timer, a slot already full -- arrives here in the server's own words.
	statusLabel = label(panel, "", C.dim, 12)
	statusLabel.Size = UDim2.new(1, 0, 0, 18)
	statusLabel.Position = UDim2.new(0, 0, 1, -18)

	local columns = Instance.new("Frame")
	columns.BackgroundTransparency = 1
	columns.Position = UDim2.new(0, 0, 0, 34)
	columns.Size = UDim2.new(1, 0, 1, -58)
	columns.Parent = panel

	local across = Instance.new("UIListLayout")
	across.FillDirection = Enum.FillDirection.Horizontal
	across.Padding = UDim.new(0, 12)
	across.Parent = columns

	local lists = {}
	for index, column in ipairs(COLUMNS) do
		local holder = Instance.new("Frame")
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.new(1 / #COLUMNS, -12, 1, 0)
		holder.LayoutOrder = index
		holder.Parent = columns

		local title = label(holder, column.title, C.faint, 11, true)
		title.Size = UDim2.new(1, 0, 0, 16)

		local list = Instance.new("ScrollingFrame")
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.Position = UDim2.new(0, 0, 0, 20)
		list.Size = UDim2.new(1, 0, 1, -20)
		list.ScrollBarThickness = 3
		list.ScrollBarImageColor3 = C.line
		list.CanvasSize = UDim2.new()
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.Parent = holder

		local down = Instance.new("UIListLayout")
		down.Padding = UDim.new(0, 4)
		down.SortOrder = Enum.SortOrder.LayoutOrder
		down.Parent = list

		lists[index] = list
	end

	-- THE CATALOGUE DECIDES WHAT IS HERE, not this file. A gun given a price
	-- appears; one without a price does not.
	local perColumn = {}
	for _, entry in ipairs(Economy.Catalogue()) do
		local column = COLUMN_FOR[entry.slot]
		-- A slot with no column of its own -- a melee weapon, anything a
		-- plugin invents -- goes in with the equipment rather than vanishing.
		-- A buyable thing that is not on the menu is a bug you cannot see.
		if not column then column = COLUMN_FOR.gear end

		perColumn[column] = (perColumn[column] or 0) + 1
		local row = buildRow(lists[column], entry, perColumn[column])

		-- One to nine, per column, exactly as CS numbers them.
		if perColumn[column] <= 9 then
			row.hotkey = perColumn[column]
			row.column = column
			row.key.Text = tostring(perColumn[column])
		end

		table.insert(rows, row)
	end
end

--=====================================================================
-- WHAT THE ROWS SAY
--=====================================================================

local function refresh()
	if not gui then return end

	local have = money()
	moneyLabel.Text = ("$%d"):format(have)

	for _, row in ipairs(rows) do
		-- THE SAME QUESTION THE SERVER ASKS, minus the two things only it
		-- can answer. Passing those as nil rather than guessing is the point:
		-- a menu that assumed you were in a buy zone would grey rows in and
		-- out as you walked, and be wrong in both directions.
		local allowed = Economy.CanBuy({
			class = row.entry.class,
			money = have,
			alive = true,
		})

		row.price.Text = row.entry.price > 0 and ("$%d"):format(row.entry.price) or "free"
		row.name.TextColor3 = allowed and C.text or C.faint
		row.price.TextColor3 = allowed and C.dim or C.danger
		row.button.BackgroundTransparency = allowed and 0.35 or 0.72
	end
end

local function setStatus(text, bad)
	if not statusLabel then return end
	statusLabel.Text = text or ""
	statusLabel.TextColor3 = bad and C.danger or C.dim
end

--=====================================================================
-- OPEN AND CLOSE
--=====================================================================

local open = false
local Input

local function setOpen(state)
	build()
	if state == open then return end
	open = state

	gui.Enabled = state
	if state then
		refresh()
		setStatus("1-9 to buy from a column, Q to refund, B to close")
		if Input then Input.PushModal() end
	else
		if Input then Input.PopModal() end
	end
end

--=====================================================================
-- WIRING
--=====================================================================

build()

plr:GetAttributeChangedSignal("Money"):Connect(function()
	if open then refresh() end
end)

BuyReport.OnClientEvent:Connect(function(ok, message, balance)
	if balance then refresh() end
	if message then setStatus(tostring(message), not ok) end
end)

-- The number keys, while the menu is open. Handled here rather than through
-- the bind table because they are a MENU's keys, not the game's: 1-9 are the
-- weapon slots everywhere else, and binding them globally would take them.
UserInputService.InputBegan:Connect(function(input, processed)
	if not open or processed then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

	if input.KeyCode == Enum.KeyCode.Q then
		BuyRequest:FireServer("refund")
		return
	end

	local digit = tonumber(string.match(input.KeyCode.Name, "^%a+(%d)$"))
	if not digit then return end

	-- The column under the mouse, so 1-9 means "the first nine in the column
	-- I am looking at" exactly as CS's nested menus do.
	local column = 1
	local mouse = UserInputService:GetMouseLocation().X
	local width = panel.AbsoluteSize.X / #COLUMNS
	if width > 0 then
		column = math.clamp(
			math.floor((mouse - panel.AbsolutePosition.X) / width) + 1, 1, #COLUMNS)
	end

	for _, row in ipairs(rows) do
		if row.hotkey == digit and row.column == column then
			BuyRequest:FireServer("buy", row.entry.class)
			return
		end
	end
end)

--=====================================================================
-- THE KEY
--=====================================================================
-- `buymenu` is a command in Input's table, so it is rebindable like
-- everything else and the settings menu lists it beside Use and Drop. B by
-- default, as in CS.
--
-- Listened for rather than registered here: a Config command of the same
-- name would collide with the one Input already declares, and the settings
-- page builds its rows from Input's table rather than from Config's.
--
-- WAITED FOR, with a ceiling. This script and the Player module are both
-- injected into PlayerGui and the order is not ours to choose; a
-- FindFirstChild on the wrong frame is a buy key that never works, and a
-- WaitForChild with no timeout is a thread parked forever if the module is
-- not there at all.
task.spawn(function()
	local modules = playerGui:WaitForChild("Player", 10)
	local found = modules and modules:WaitForChild("Input", 10)
	if not found then
		warn("[BuyMenu] no Input module -- the buy key will not work; "
			.. "the buy console command still does")
		return
	end

	Input = require(found)
	Input.ActionPressed.Event:Connect(function(name)
		if name == "buymenu" then setOpen(not open) end
	end)
end)

-- And from the console, which is also how a script or a bind to something
-- Input does not know about reaches it.
Config.Command("buy_menu", {
	args = { "string?" },
	help = "open, close or toggle the buy menu",
	run = function(ctx, how)
		how = how and string.lower(how) or "toggle"
		if how == "open" then setOpen(true)
		elseif how == "close" then setOpen(false)
		else setOpen(not open) end
		ctx.reply(open and "buy menu open" or "buy menu closed")
	end,
})
