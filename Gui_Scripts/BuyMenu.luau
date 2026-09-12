-- LocalScript: BuyMenu
-- Parent: PlayerGui.Console  (the ScreenGui the server keeps topped up)
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
--
-- THIS SCRIPT RUNS MORE THAN ONCE PER SESSION. It lives inside the Console
-- ScreenGui, which PlayerGui resets on respawn and Glacier1 re-clones a second
-- later whenever it goes missing. Everything below that touches state outside
-- the script -- the ScreenGui, the modal count -- is therefore written to be
-- found and reused rather than created, because the first version created both
-- afresh and the leftovers are most of what was wrong with it. See build() and
-- setOpen().

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

-- THE MODAL OWNER NAME, and it being a constant string is the point: an owner
-- key can be cleared by a LATER instance of this script, where a PushModal
-- from a dead one can never be popped by anybody. Dying with the menu open
-- used to leave the cursor free and gameplay input dead for the rest of the
-- round because of exactly that.
local MODAL_OWNER = "BuyMenu"

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

-- KeyCode NAMES, not digits in them. Enum.KeyCode.One is named "One" and
-- Enum.KeyCode.KeypadOne is "KeypadOne" -- neither contains the character 1,
-- so the pattern this used to parse them with matched nothing and the number
-- keys, the entire reason a CS buy menu is fast, never bought anything.
local DIGIT_FOR = {}
do
	local words = { "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
	for digit, word in ipairs(words) do
		DIGIT_FOR[word] = digit
		DIGIT_FOR["Keypad" .. word] = digit
	end
end

--=====================================================================
-- BUILD
--=====================================================================

local gui, panel, moneyLabel, statusLabel, hintLabel
local rows = {}
local columnFrames = {}
local columnTitles = {}
local hotColumn = 0

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

	local row = { button = button, name = name, price = price, key = key, entry = entry }

	button.Activated:Connect(function()
		BuyRequest:FireServer("buy", entry.class)
	end)

	-- Hover, so the row under the cursor is the row you think you are clicking.
	button.MouseEnter:Connect(function()
		row.hovered = true
		if row.allowed then button.BackgroundTransparency = 0.12 end
	end)
	button.MouseLeave:Connect(function()
		row.hovered = false
		button.BackgroundTransparency = row.allowed and 0.35 or 0.72
	end)

	return row
end

local function build()
	if gui then return end

	-- FOUND OR MADE, and emptied if found.
	--
	-- The old version made a new ScreenGui every time the script ran, with
	-- ResetOnSpawn off so it would survive a respawn -- which meant every
	-- respawn added another one and none of them ever went away. Die with the
	-- menu open and the orphan stayed on screen, enabled, its script dead and
	-- nothing left alive that could close it: a buy menu that ignores the buy
	-- key, which is precisely what it looked like.
	local existing = playerGui:FindFirstChild("BuyMenu")
	if existing and existing:IsA("ScreenGui") then
		existing:ClearAllChildren()
		gui = existing
	else
		if existing then existing:Destroy() end
		gui = Instance.new("ScreenGui")
		gui.Name = "BuyMenu"
	end
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 40
	gui.Enabled = false
	gui.Parent = playerGui

	table.clear(rows)
	table.clear(columnFrames)
	table.clear(columnTitles)

	-- CLICK ANYWHERE ELSE TO CLOSE. A modal menu with no way out but one key
	-- is a menu that traps people, and this is the one thing every player
	-- tries first.
	local scrim = Instance.new("TextButton")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 0.55
	scrim.BorderSizePixel = 0
	scrim.AutoButtonColor = false
	scrim.Text = ""
	scrim.ZIndex = 0
	scrim.Parent = gui

	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.new(0.5, 0, 0.5, 0)
	panel.Size = UDim2.new(0, 720, 0, 420)
	panel.BackgroundColor3 = C.panel
	panel.BackgroundTransparency = 0.06
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
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
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 26)
	header.Parent = panel

	label(header, "BUY", C.text, 17, true).Size = UDim2.new(0, 80, 1, 0)

	moneyLabel = label(header, "", C.good, 17, true)
	moneyLabel.Size = UDim2.new(0, 200, 1, 0)
	moneyLabel.Position = UDim2.new(1, -230, 0, 0)
	moneyLabel.TextXAlignment = Enum.TextXAlignment.Right

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.Size = UDim2.new(0, 24, 0, 24)
	close.Position = UDim2.new(1, -24, 0, 0)
	close.BackgroundTransparency = 1
	close.Font = Enum.Font.GothamBold
	close.TextSize = 16
	close.TextColor3 = C.dim
	close.Text = "X"
	close.Parent = header

	-- WHY THE LAST ONE WAS REFUSED, and this line is most of the value of
	-- the menu. Everything the client cannot know -- the buy zone, the buy
	-- timer, a slot already full -- arrives here in the server's own words.
	statusLabel = label(panel, "", C.dim, 12)
	statusLabel.Size = UDim2.new(1, -220, 0, 18)
	statusLabel.Position = UDim2.new(0, 0, 1, -18)

	hintLabel = label(panel, "", C.faint, 12)
	hintLabel.Size = UDim2.new(0, 220, 0, 18)
	hintLabel.Position = UDim2.new(1, -220, 1, -18)
	hintLabel.TextXAlignment = Enum.TextXAlignment.Right

	local columns = Instance.new("Frame")
	columns.Name = "Columns"
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
		-- NAMED. Four Frames called "Frame" is what the Explorer showed
		-- before, and the number keys are aimed by these frames' geometry.
		holder.Name = "Column" .. index
		holder.BackgroundTransparency = 1
		holder.Size = UDim2.new(1 / #COLUMNS, -12, 1, 0)
		holder.LayoutOrder = index
		holder.Parent = columns

		local title = label(holder, column.title, C.faint, 11, true)
		title.Size = UDim2.new(1, 0, 0, 16)

		local list = Instance.new("ScrollingFrame")
		list.Name = "List"
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
		columnFrames[index] = holder
		columnTitles[index] = title
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
		row.column = column

		-- One to nine, per column, exactly as CS numbers them.
		if perColumn[column] <= 9 then
			row.hotkey = perColumn[column]
			row.key.Text = tostring(perColumn[column])
		end

		table.insert(rows, row)
	end

	return scrim, close
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

		row.allowed = allowed
		row.price.Text = row.entry.price > 0 and ("$%d"):format(row.entry.price) or "free"
		row.name.TextColor3 = allowed and C.text or C.faint
		row.price.TextColor3 = allowed and C.dim or C.danger
		row.button.BackgroundTransparency = (allowed and row.hovered and 0.12)
			or (allowed and 0.35)
			or 0.72
	end
end

local function setStatus(text, bad)
	if not statusLabel then return end
	statusLabel.Text = text or ""
	statusLabel.TextColor3 = bad and C.danger or C.dim
end

--=====================================================================
-- WHICH COLUMN THE NUMBER KEYS MEAN
--=====================================================================
-- The one the cursor is over, so 1-9 is "the first nine in the column I am
-- looking at" as CS's nested menus are. Read off the column frames rather
-- than by dividing the panel width: the panel has padding and the columns
-- have gaps between them, so the arithmetic version put the boundaries
-- roughly 20px away from where the eye puts them.
--
-- X only. GetMouseLocation and AbsolutePosition disagree by the topbar inset
-- vertically and not at all horizontally, and the columns are vertical.
local function columnUnderMouse()
	if #columnFrames == 0 then return 1 end
	local x = UserInputService:GetMouseLocation().X

	for index, holder in ipairs(columnFrames) do
		local pos, size = holder.AbsolutePosition, holder.AbsoluteSize
		if x >= pos.X and x <= pos.X + size.X then return index end
	end

	-- Off the side of the panel: the nearest column rather than nothing, so
	-- the keys still work while the cursor is out in the world.
	local best, bestGap = 1, math.huge
	for index, holder in ipairs(columnFrames) do
		local pos, size = holder.AbsolutePosition, holder.AbsoluteSize
		local gap = math.max(pos.X - x, x - (pos.X + size.X), 0)
		if gap < bestGap then best, bestGap = index, gap end
	end
	return best
end

-- WHICH COLUMN IS ARMED, shown rather than remembered. A hotkey whose meaning
-- depends on where the mouse is has to say so, or the first wrong purchase is
-- how you find out.
local function markColumn(index)
	if index == hotColumn then return end
	hotColumn = index

	for i, title in ipairs(columnTitles) do
		title.TextColor3 = (i == index) and C.accent or C.faint
	end
	for _, row in ipairs(rows) do
		if row.hotkey then
			row.key.TextColor3 = (row.column == index) and C.accent or C.faint
		end
	end
end

--=====================================================================
-- OPEN AND CLOSE
--=====================================================================

local open = false
local Input
local lastToggle = -1

local function keyHint()
	local keys = Input and Input.GetKeysFor and Input.GetKeysFor("buymenu")
	local key = keys and keys[1]
	return key and key:upper() or "the buy key"
end

local function setOpen(state)
	build()
	if state == open then return end
	open = state

	gui.Enabled = state

	-- OWNER-KEYED, not counted. SetModal is idempotent and the owner is a
	-- constant, so a later instance of this script can clear a modal an
	-- earlier one left behind -- which PushModal/PopModal could not, and
	-- which is why dying with the menu open froze the cursor for good.
	if Input then Input.SetModal(MODAL_OWNER, state) end

	if state then
		refresh()
		markColumn(0)
		markColumn(columnUnderMouse())
		setStatus("")
		if hintLabel then
			hintLabel.Text = ("1-9 buy  ·  Q refund  ·  %s closes"):format(keyHint())
		end
	end
end

-- EVERY WAY IN GOES THROUGH HERE, and the same-frame guard is why. The key
-- reaches this script by two routes on purpose (see the wiring below) and a
-- toggle that fired on both would open and close in one press, which is
-- indistinguishable from a key that does nothing.
local function requestToggle()
	local now = os.clock()
	if now - lastToggle < 0.05 then return end
	lastToggle = now
	setOpen(not open)
end

--=====================================================================
-- WIRING
--=====================================================================

local scrim, closeButton = build()
if scrim then scrim.Activated:Connect(function() setOpen(false) end) end
if closeButton then closeButton.Activated:Connect(function() setOpen(false) end) end

plr:GetAttributeChangedSignal("Money"):Connect(function()
	if open then refresh() end
end)

-- DYING CLOSES IT. Without this the menu outlives the character that opened
-- it, and because this script is reset on respawn, the one that could have
-- closed it is gone by the time anybody presses the key.
plr.CharacterRemoving:Connect(function()
	setOpen(false)
end)

BuyReport.OnClientEvent:Connect(function(ok, message, balance)
	if balance then refresh() end
	if message then setStatus(tostring(message), not ok) end
end)

-- The number keys, while the menu is open. Handled here rather than through
-- the bind table because they are a MENU's keys, not the game's: 1-9 are the
-- weapon slots everywhere else, and binding them globally would take them.
UserInputService.InputBegan:Connect(function(input)
	if not open then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end

	-- The console can be opened over the top of this. gameProcessed is no use
	-- here -- our own InputContext sinks keys and marks them processed -- so
	-- the question is asked directly: is anybody typing?
	if UserInputService:GetFocusedTextBox() then return end

	if input.KeyCode == Enum.KeyCode.Q then
		BuyRequest:FireServer("refund")
		return
	end

	local digit = DIGIT_FOR[input.KeyCode.Name]
	if not digit then return end

	local column = columnUnderMouse()
	for _, row in ipairs(rows) do
		if row.hotkey == digit and row.column == column then
			BuyRequest:FireServer("buy", row.entry.class)
			return
		end
	end
	setStatus(("nothing on %d in %s"):format(digit, COLUMNS[column].title), true)
end)

-- The armed column follows the cursor while the menu is up.
UserInputService.InputChanged:Connect(function(input)
	if not open then return end
	if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
	markColumn(columnUnderMouse())
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
-- TWO ROUTES, deliberately, both funnelled through requestToggle:
--
--   ActionPressed, which is the proper one and carries whatever the key has
--   been rebound to.
--
--   A raw InputBegan on the same key, because the proper one runs through
--   Input's modal passthrough while the menu is up -- and if anything in that
--   path is off, the key that opened the menu is the key that cannot close
--   it. A close key is not a thing to leave resting on one mechanism.
--
-- FOUND THE WAY EVERY OTHER PANEL FINDS IT, and looked for in all three
-- places rather than only under PlayerGui. Getting the WRONG instance is
-- worse than getting none: ModuleScripts cache per instance, so a second copy
-- of Input has different BindableEvents and the key silently never fires.
--
-- NOT a list walked with ipairs, which is how the other three write it: the
-- first candidate is a FindFirstChild that can come back nil, and a table
-- constructor with nil in slot one has length zero -- so the loop looks at
-- NOTHING and the answer is always "no modules anywhere". It only ever works
-- because PlayerScripts happens to exist on a real client.
local function modulesIn(parent)
	if not parent then return nil end
	local folder = parent:FindFirstChild("Player")
	if folder and folder:FindFirstChild("Input") then return folder end
	return nil
end

local function findClientModules()
	return modulesIn(plr:FindFirstChild("PlayerScripts"))
		or modulesIn(ReplicatedStorage)
		or modulesIn(plr:FindFirstChild("PlayerGui"))
end

-- RETRIED, with a ceiling. This script and the Player folder are both dropped
-- into the player by other things on their own schedule, so a single look on
-- the wrong frame is a buy key that never works -- and a wait with no timeout
-- is a thread parked forever if the folder is not coming at all.
task.spawn(function()
	local modules = findClientModules()
	local waited = 0
	while not modules and waited < 10 do
		waited += task.wait(0.25)
		modules = findClientModules()
	end

	if not modules then
		warn("[BuyMenu] no Input module -- the buy key will not work; "
			.. "the buy console command still does")
		return
	end

	Input = require(modules:WaitForChild("Input"))

	-- A previous life may have died with the menu open and the game modal.
	-- This is the call that lets it out.
	Input.SetModal(MODAL_OWNER, false)

	Input.ActionPressed.Event:Connect(function(name)
		if name == "buymenu" then requestToggle() end
	end)

	UserInputService.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
		if UserInputService:GetFocusedTextBox() then return end

		local keyName = Input.NormalizeKey(input.KeyCode.Name)
		if keyName and Input.GetBind(keyName) == "buymenu" then
			requestToggle()
		end
	end)
end)

-- And from the console, which is also how a script or a bind to something
-- Input does not know about reaches it.
Config.Command("buy_menu", {
	args = { "string?" },
	help = "open, close, toggle or report on the buy menu",
	run = function(ctx, how)
		how = how and string.lower(how) or "toggle"

		if how == "status" or how == "report" then
			local keys = Input and Input.GetKeysFor and Input.GetKeysFor("buymenu") or {}
			local lines = {
				"=== buy menu ===",
				("  open        : %s"):format(tostring(open)),
				("  screengui   : %s"):format(gui and gui:GetFullName() or "<none>"),
				("  copies in PlayerGui: %d"):format((function()
					local n = 0
					for _, child in ipairs(playerGui:GetChildren()) do
						if child.Name == "BuyMenu" then n += 1 end
					end
					return n
				end)()),
				("  rows        : %d"):format(#rows),
				("  input module: %s"):format(Input and "found" or "NOT FOUND"),
				("  bound to    : %s"):format(#keys > 0 and table.concat(keys, ", ") or "<nothing>"),
				("  modal       : %s"):format(Input and tostring(Input.IsModal()) or "?"),
				("  money       : $%d"):format(money()),
			}
			ctx.reply(table.concat(lines, "\n"))
			return
		end

		if how == "open" then setOpen(true)
		elseif how == "close" then setOpen(false)
		else requestToggle() end
		ctx.reply(open and "buy menu open" or "buy menu closed")
	end,
})
