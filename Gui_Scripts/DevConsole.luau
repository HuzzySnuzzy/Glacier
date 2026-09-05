-- LocalScript: DevConsole
-- Parent: PlayerGui.Console  (a ScreenGui -- it may be completely empty)
--
-- Replaces pConsole. Same dispatch, same registry, same remotes; a different
-- surface. Everything is built in code, so the ScreenGui needs no children --
-- there is no Studio-side layout to keep in sync with this file.
--
-- SHAPE
--   A thin command line across the TOP of the screen, CoD-style.
--   A separate output panel on the right, draggable by its header.
--
-- The panel lives in its own ScreenGui ("ConsoleOutput"), NOT this one. Input
-- treats a ScreenGui named "Console" as modal, so a pinned log inside it would
-- hold the cursor free and gameplay input dead with the prompt closed. Two
-- ScreenGuis is what lets con_pin exist at all.
--
-- ANYONE CAN OPEN IT. Whether a line does anything is decided downstream: the
-- server gates forwarded lines on its own admin list, and CHEAT-flagged cvars
-- refuse to move without sv_cheats. This is a window, not a permission.
--
-- COLOUR IS THE INTERFACE. A line is legible before it runs:
--   name blue (a cvar), teal (a command here), green (a command on the
--   server), red (nothing by that name -- it will fail, and you can see that
--   before pressing Enter); values gold; the ! prefix amber.
-- The badges say the same thing in text for anyone who can't rely on hue.

local UserInputService  = game:GetService("UserInputService")
local StarterGui        = game:GetService("StarterGui")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LogService        = game:GetService("LogService")

local Config       = require(ReplicatedStorage:WaitForChild("Config"))
local ConsoleEvent = ReplicatedStorage:WaitForChild("ConsoleEvent")
local ConsoleLog   = ReplicatedStorage:WaitForChild("ConsoleLog")
local ConsoleBroadcast = ReplicatedStorage:WaitForChild("ConsoleBroadcast", 10)
local Manifest     = ReplicatedStorage:WaitForChild("ConsoleManifest", 10)

local BROADCAST_PREFIX = "!"
local plr = Players.LocalPlayer

--=====================================================================
-- MODULE RESOLUTION
--=====================================================================
-- Getting the WRONG instance is worse than getting none: ModuleScripts cache
-- per instance, so a second copy of Input has different BindableEvents and the
-- toggle silently never fires.
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
	error("[DevConsole] could not find the Player module folder. It must be the " ..
		"SAME instance the client controller requires, or Input's events won't match.", 0)
end

local Input = require(ClientModules:WaitForChild("Input"))
local State = require(ClientModules:WaitForChild("State"))

local function hasFlag(flag, want)
	return bit32.band(flag or Config.FCVAR.CLIENT, want) ~= 0
end

--=====================================================================
-- THE TILDE KEY
--=====================================================================
-- Roblox's Backpack owns the backquote/tilde key and opens the inventory with
-- it. That binding belongs to the CoreGui and cannot be unbound, so the only
-- way to have the key is to switch the Backpack off -- which costs this game
-- nothing, since weapons live in the Inventory module and are rendered by
-- Visuals; the Roblox backpack has never held anything.
--
-- Retried once a second because SetCoreGuiEnabled throws if the CoreGui is not
-- ready yet, and a console you cannot open is not a small failure.
task.spawn(function()
	for _ = 1, 10 do
		if Config.con_freeToggleKey == false then return end
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
		end)
		if ok then return end
		task.wait(1)
	end
	warn("[DevConsole] could not disable the Backpack CoreGui; tilde may still open the inventory.")
end)

--=====================================================================
-- PALETTE
--=====================================================================

local C = {
	bg        = Color3.fromRGB(14, 15, 18),
	bgLight   = Color3.fromRGB(24, 26, 31),
	line      = Color3.fromRGB(48, 52, 60),
	accent    = Color3.fromRGB(90, 160, 255),

	nameCvar  = Color3.fromRGB(105, 180, 255),   -- blue    : a setting
	nameLocal = Color3.fromRGB(120, 220, 190),   -- teal    : a command in this VM
	nameRemote= Color3.fromRGB(130, 225, 150),   -- green   : a command on the server
	nameBad   = Color3.fromRGB(255, 110, 110),   -- red     : no such thing
	value     = Color3.fromRGB(255, 200, 90),    -- gold    : the value
	punct     = Color3.fromRGB(125, 130, 140),
	bang      = Color3.fromRGB(255, 160, 80),    -- the ! prefix

	echo    = Color3.fromRGB(235, 235, 235),
	reply   = Color3.fromRGB(190, 190, 190),
	info    = Color3.fromRGB(150, 200, 255),
	warn    = Color3.fromRGB(255, 210, 100),
	error   = Color3.fromRGB(255, 90, 90),
	server  = Color3.fromRGB(160, 230, 180),
	spew    = Color3.fromRGB(125, 125, 130),
}

local function hex(colour)
	return ("#%02X%02X%02X"):format(
		math.floor(colour.R * 255 + 0.5),
		math.floor(colour.G * 255 + 0.5),
		math.floor(colour.B * 255 + 0.5))
end

-- RichText is markup, so anything the player types has to be neutralised or a
-- stray '<' eats the rest of the line.
local function escape(text)
	return (tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function paint(text, colour)
	return ('<font color="%s">%s</font>'):format(hex(colour), escape(text))
end

--=====================================================================
-- REGISTRY
--=====================================================================
-- Rebuilt on change rather than snapshotted at load: gamemodes register
-- commands long after this script runs and unregister them on switch, so a
-- one-time snapshot silently misses every one of them.

local entries = {}   -- [name] = { kind, default, flag, usage, help }
local names   = {}

local function rebuild()
	entries, names = {}, {}

	for key, value in pairs(Config.Values) do
		if type(value) ~= "function" then
			entries[key] = {
				kind = "cvar",
				default = Config.Defaults and Config.Defaults[key] or value,
				flag = Config.Flags[key],
			}
			table.insert(names, key)
		end
	end

	for name, spec in pairs(Config.Commands) do
		entries[name] = { kind = "command", flag = spec.flag,
			usage = Config.Usage(name), help = spec.help }
		table.insert(names, name)
	end

	-- Server-owned. Skipped where a local entry already claims the name, since
	-- the local one is what would actually run.
	for name, info in pairs(Config.RemoteCommands) do
		if not entries[name] then
			entries[name] = { kind = "remote", flag = info.flag,
				usage = info.usage, help = info.help }
			table.insert(names, name)
		end
	end

	table.sort(names)
end

rebuild()
Config.OnCommandsChanged(rebuild)

if Manifest then
	Manifest.OnClientEvent:Connect(function(list)
		Config.SetRemoteCommands(list)
	end)
else
	warn("[DevConsole] no ConsoleManifest remote; server commands won't autocomplete.")
end

-- Where a name will actually run. This is the whole point of the badges: the
-- same word can be a local cvar, a local command, or something only the server
-- has, and they behave completely differently -- a REPLICATED cvar looks local
-- but is refused by Config.Set here and forwarded instead.
--
-- ONE answer, feeding both the badge and the colour, so the two can never
-- disagree. They did at first: the badge read SV for a replicated cvar while
-- the name stayed local-blue.
local function localityOf(name)
	local entry = entries[name]
	if not entry then return "??", C.nameBad end

	if entry.kind == "remote" or hasFlag(entry.flag, Config.FCVAR.REPLICATED) then
		return "SV", C.nameRemote
	end
	-- A verb and a setting read differently even when both are local.
	if entry.kind == "command" then return "CL", C.nameLocal end
	return "CL", C.nameCvar
end

local function contextOf(name) return localityOf(name) end

local function colourFor(name)
	local _, colour = localityOf(name)
	return colour
end

--=====================================================================
-- UI
--=====================================================================

local screenGui = script.Parent
screenGui.ResetOnSpawn = false
-- NOT IgnoreGuiInset: at y = 0 with the inset ignored, the left end of the bar
-- sits under Roblox's own topbar buttons and cannot be clicked.
screenGui.IgnoreGuiInset = false
screenGui.DisplayOrder = 100
screenGui.Enabled = false

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 4)
	c.Parent = parent
	return c
end

local function stroke(parent, colour, thickness)
	local s = Instance.new("UIStroke")
	s.Color = colour or C.line
	s.Thickness = thickness or 1
	s.Parent = parent
	return s
end

local function label(parent, text, colour, size)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.Code
	l.TextSize = size or 14
	l.TextColor3 = colour or C.reply
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.Text = text or ""
	l.Parent = parent
	return l
end

--------------------------------------------------------------
-- top bar
--------------------------------------------------------------

local BAR_HEIGHT = 30

local bar = Instance.new("Frame")
bar.Name = "CommandLine"
bar.Size = UDim2.new(1, 0, 0, BAR_HEIGHT)
bar.Position = UDim2.new(0, 0, 0, 0)
bar.BackgroundColor3 = C.bg
bar.BackgroundTransparency = 0.05
bar.BorderSizePixel = 0
bar.Parent = screenGui

local barLine = Instance.new("Frame")   -- a hairline under the bar, not a border
barLine.Size = UDim2.new(1, 0, 0, 1)
barLine.Position = UDim2.new(0, 0, 1, -1)
barLine.BackgroundColor3 = C.accent
barLine.BackgroundTransparency = 0.55
barLine.BorderSizePixel = 0
barLine.Parent = bar

-- Prompt glyph doubles as the destination badge: it says where the line goes
-- BEFORE you send it, which is the one thing a shared console has to make
-- obvious. Turns amber the moment a '!' is typed.
local prompt = label(bar, "]", C.accent, 16)
prompt.Position = UDim2.new(0, 10, 0, 0)
prompt.Size = UDim2.new(0, 58, 1, 0)
prompt.Font = Enum.Font.Code

local inputHolder = Instance.new("Frame")
inputHolder.BackgroundTransparency = 1
inputHolder.Position = UDim2.new(0, 70, 0, 0)
inputHolder.Size = UDim2.new(1, -324, 1, 0)
inputHolder.ClipsDescendants = true
inputHolder.Parent = bar

-- The TextBox carries the caret and the selection; its own glyphs are hidden
-- and an overlay draws them in colour instead. Roblox renders the caret
-- independently of TextTransparency, which is the only reason live syntax
-- colouring is possible in a TextBox at all.
local inputField = Instance.new("TextBox")
inputField.Name = "Input"
inputField.Size = UDim2.new(1, 0, 1, 0)
inputField.BackgroundTransparency = 1
inputField.ClearTextOnFocus = false
inputField.Font = Enum.Font.Code
inputField.TextSize = 15
inputField.TextColor3 = C.echo
inputField.TextXAlignment = Enum.TextXAlignment.Left
inputField.TextYAlignment = Enum.TextYAlignment.Center
inputField.PlaceholderText = "type a command -- Tab completes, Up recalls, ! broadcasts"
inputField.PlaceholderColor3 = Color3.fromRGB(95, 100, 110)
inputField.Text = ""
inputField.Parent = inputHolder

local inputPaint = label(inputHolder, "", C.echo, 15)
inputPaint.Size = UDim2.new(1, 0, 1, 0)
inputPaint.RichText = true
inputPaint.ZIndex = 2
inputPaint.Visible = false

-- Live value of whatever you are typing, right-aligned: `= 0, 255, 0`.
local hint = label(bar, "", C.punct, 14)
hint.RichText = true
hint.AnchorPoint = Vector2.new(1, 0)
hint.Position = UDim2.new(1, -12, 0, 0)
hint.Size = UDim2.new(0, 240, 1, 0)
hint.TextXAlignment = Enum.TextXAlignment.Right

--------------------------------------------------------------
-- suggestions
--------------------------------------------------------------

local ROW_HEIGHT = 22

local suggestions = Instance.new("Frame")
suggestions.Name = "Suggestions"
suggestions.Position = UDim2.new(0, 70, 0, BAR_HEIGHT + 2)
suggestions.Size = UDim2.new(0, 560, 0, 0)
suggestions.BackgroundColor3 = C.bgLight
suggestions.BackgroundTransparency = 0.05
suggestions.BorderSizePixel = 0
suggestions.Visible = false
suggestions.Parent = screenGui
corner(suggestions, 4)
stroke(suggestions)

local suggestionList = Instance.new("ScrollingFrame")
suggestionList.Size = UDim2.new(1, 0, 1, 0)
suggestionList.BackgroundTransparency = 1
suggestionList.BorderSizePixel = 0
suggestionList.ScrollBarThickness = 4
suggestionList.AutomaticCanvasSize = Enum.AutomaticSize.Y
suggestionList.CanvasSize = UDim2.new(0, 0, 0, 0)
suggestionList.Parent = suggestions

local suggestionLayout = Instance.new("UIListLayout")
suggestionLayout.SortOrder = Enum.SortOrder.LayoutOrder
suggestionLayout.Parent = suggestionList

--------------------------------------------------------------
-- output panel  (its own ScreenGui -- see the header)
--------------------------------------------------------------

local outputGui = plr:WaitForChild("PlayerGui"):FindFirstChild("ConsoleOutput")
if outputGui then
	-- Reused, not adopted. The panel survives a respawn (ResetOnSpawn is off),
	-- but Glacier1 re-clones the Console ScreenGui whenever it goes missing --
	-- so this script can run a second time, and without this the new panel
	-- would stack on top of a dead one still holding the old log.
	outputGui:ClearAllChildren()
else
	outputGui = Instance.new("ScreenGui")
	outputGui.Name = "ConsoleOutput"
	outputGui.ResetOnSpawn = false
	outputGui.IgnoreGuiInset = true
	outputGui.DisplayOrder = 99
	outputGui.Parent = plr.PlayerGui
end
outputGui.Enabled = false

local panel = Instance.new("Frame")
panel.Name = "Output"
panel.BackgroundColor3 = C.bg
panel.BorderSizePixel = 0
panel.Parent = outputGui
corner(panel, 5)
stroke(panel)

local header = Instance.new("Frame")
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 24)
header.BackgroundColor3 = C.bgLight
header.BorderSizePixel = 0
header.Parent = panel
corner(header, 5)

local title = label(header, "  console output", C.punct, 13)
title.Size = UDim2.new(1, -60, 1, 0)

local pinButton = Instance.new("TextButton")
pinButton.AnchorPoint = Vector2.new(1, 0.5)
pinButton.Position = UDim2.new(1, -6, 0.5, 0)
pinButton.Size = UDim2.new(0, 44, 0, 16)
pinButton.BackgroundColor3 = C.line
pinButton.BackgroundTransparency = 0.4
pinButton.BorderSizePixel = 0
pinButton.Font = Enum.Font.Code
pinButton.TextSize = 12
pinButton.TextColor3 = C.punct
pinButton.Text = "pin"
pinButton.Parent = header
corner(pinButton, 3)

local logView = Instance.new("ScrollingFrame")
logView.Name = "Log"
logView.Position = UDim2.new(0, 6, 0, 28)
logView.Size = UDim2.new(1, -12, 1, -34)
logView.BackgroundTransparency = 1
logView.BorderSizePixel = 0
logView.ScrollBarThickness = 5
logView.ScrollBarImageColor3 = C.line
logView.AutomaticCanvasSize = Enum.AutomaticSize.Y
logView.CanvasSize = UDim2.new(0, 0, 0, 0)
logView.Parent = panel

local logLayout = Instance.new("UIListLayout")
logLayout.SortOrder = Enum.SortOrder.LayoutOrder
logLayout.Padding = UDim.new(0, 1)
logLayout.Parent = logView

-- Bottom-right grip. Resizing is worth the twenty lines: the panel is where
-- you read wrapped output, and a fixed width makes bindlist unreadable.
local grip = Instance.new("TextButton")
grip.AnchorPoint = Vector2.new(1, 1)
grip.Position = UDim2.new(1, -2, 1, -2)
grip.Size = UDim2.new(0, 14, 0, 14)
grip.BackgroundTransparency = 1
grip.Font = Enum.Font.Code
grip.TextSize = 14
grip.TextColor3 = C.line
grip.Text = "/"
grip.Parent = panel

local function applyPanelGeometry()
	local w = math.clamp(Config.con_panelW or 440, 220, 1600)
	local h = math.clamp(Config.con_panelH or 540, 140, 1200)
	local x = Config.con_panelX or -1
	local y = Config.con_panelY or 88

	panel.Size = UDim2.new(0, w, 0, h)
	if x < 0 then
		-- Sentinel: dock to the right edge, which is where it starts life.
		panel.AnchorPoint = Vector2.new(1, 0)
		panel.Position = UDim2.new(1, -16, 0, y)
	else
		panel.AnchorPoint = Vector2.new(0, 0)
		panel.Position = UDim2.new(0, x, 0, y)
	end
	panel.BackgroundTransparency = math.clamp(Config.con_opacity or 0.12, 0, 1)
end

applyPanelGeometry()
for _, key in ipairs({ "con_panelW", "con_panelH", "con_panelX", "con_panelY", "con_opacity" }) do
	Config.OnChange(key, applyPanelGeometry)
end

--------------------------------------------------------------
-- dragging and resizing
--------------------------------------------------------------
-- Written to the cvars rather than held in a local, so the position survives
-- a respawn and can be read back or set from the console itself.

local dragging, dragStart, panelStart = false, nil, nil
local resizing, resizeStart, sizeStart = false, nil, nil

header.InputBegan:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then return end
	dragging = true
	dragStart = input.Position
	panelStart = panel.AbsolutePosition
end)

grip.InputBegan:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton1
		and input.UserInputType ~= Enum.UserInputType.Touch then return end
	resizing = true
	resizeStart = input.Position
	sizeStart = panel.AbsoluteSize
end)

UserInputService.InputChanged:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseMovement
		and input.UserInputType ~= Enum.UserInputType.Touch then return end

	if dragging then
		local delta = input.Position - dragStart
		local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
			or Vector2.new(1920, 1080)
		-- Clamped so the header can never be dragged off screen, which would
		-- leave the panel unrecoverable without editing a cvar by hand.
		local x = math.clamp(panelStart.X + delta.X, 0, math.max(viewport.X - 60, 0))
		local y = math.clamp(panelStart.Y + delta.Y, 0, math.max(viewport.Y - 40, 0))
		Config.Set("con_panelX", math.floor(x))
		Config.Set("con_panelY", math.floor(y))

	elseif resizing then
		local delta = input.Position - resizeStart
		Config.Set("con_panelW", math.floor(math.clamp(sizeStart.X + delta.X, 220, 1600)))
		Config.Set("con_panelH", math.floor(math.clamp(sizeStart.Y + delta.Y, 140, 1200)))
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging, resizing = false, false
	end
end)

--=====================================================================
-- LOG
--=====================================================================

local logLines = {}
local logOrder = 0
local pendingScroll = false

local BADGE = {
	echo   = { "  ]", C.accent },
	reply  = { " CL", C.nameCvar },
	server = { " SV", C.nameRemote },
	info   = { "  i", C.info },
	warn   = { "  !", C.warn },
	error  = { "  x", C.error },
	spew   = { "   ", C.spew },
	bang   = { "  !", C.bang },
}

local function scrollToBottom()
	if pendingScroll then return end
	pendingScroll = true
	-- Deferred and coalesced: a command that emits forty lines would otherwise
	-- queue forty layout reads in one frame.
	task.defer(function()
		pendingScroll = false
		logView.CanvasPosition = Vector2.new(0, logView.AbsoluteCanvasSize.Y)
	end)
end

local function trimLog()
	local maxLines = math.max(Config.con_maxlines or 512, 16)
	while #logLines > maxLines do
		local oldest = table.remove(logLines, 1)
		if oldest then oldest:Destroy() end
	end
end

local function addLine(text, kind)
	local badge = BADGE[kind] or BADGE.reply

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	logOrder += 1
	row.LayoutOrder = logOrder
	row.Parent = logView

	local tag = label(row, badge[1], badge[2], 13)
	tag.Size = UDim2.new(0, 26, 0, 16)
	tag.TextYAlignment = Enum.TextYAlignment.Top

	local body = label(row, "", C[kind] or C.reply, 14)
	body.Position = UDim2.new(0, 30, 0, 0)
	body.Size = UDim2.new(1, -30, 0, 0)
	-- AutomaticSize with TextWrapped, not a fixed height: bindlist and help
	-- emit lines wider than the panel, and a fixed height clips them.
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.TextWrapped = true
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.RichText = true
	body.Text = text

	table.insert(logLines, row)
	trimLog()
	scrollToBottom()
end

-- rich = the text is already markup and must not be escaped again.
local function addLog(message, kind, rich)
	local text = tostring(message)
	local stamp = ""
	if Config.con_timestamp then
		-- Wall clock, not State.gameTime. A timestamp exists so a line can be
		-- matched against something that happened outside the game -- a crash,
		-- a screenshot, a message from someone else -- and gameTime is useless
		-- for that: it starts at zero every join and host_timescale bends it.
		stamp = paint(os.date("[%H:%M:%S] "), C.spew)
	end

	for _, lineText in ipairs(string.split(text, "\n")) do
		addLine(stamp .. (rich and lineText or escape(lineText)), kind)
	end
end

local function clearLog()
	for _, row in ipairs(logLines) do row:Destroy() end
	table.clear(logLines)
	logOrder = 0
end

-- Bound commands and anything else outside this script answer through here.
-- Without it their output falls back to warn() and never reaches the console.
Input.Reply = function(msg) addLog(msg, "reply") end

--=====================================================================
-- SPEW CAPTURE
--=====================================================================
-- CLIENT ONLY. Server-side print still goes to the server log; that is what
-- ctx.reply is for, and no capture here can change it.

local MESSAGE_KIND = {
	[Enum.MessageType.MessageOutput]  = "spew",
	[Enum.MessageType.MessageInfo]    = "info",
	[Enum.MessageType.MessageWarning] = "warn",
	[Enum.MessageType.MessageError]   = "error",
}

-- Output that is Roblox's rather than this game's. Its CoreScripts and the
-- Studio Assistant chat among themselves constantly, none of it is actionable
-- from here, and it was most of what made startup unreadable.
local ROBLOX_NOISE = {
	"^%[Roblox%]",
	"BuiltIn_",
	"CorePackages",
	"CoreScript",
	"AssistantUI",
	"rbxasset://",
	"^Requested module",
}

local function isRobloxNoise(message)
	for _, pattern in ipairs(ROBLOX_NOISE) do
		if string.find(message, pattern) then return true end
	end
	return false
end

-- The console loads while the rest of the client is still starting, so it
-- catches the whole boot in its first second. Ordinary output is held back
-- until that settles; warnings and errors are NOT held, because those are
-- exactly the ones worth seeing at startup.
local spewReadyAt = os.clock() + math.max(Config.con_spewDelay or 3, 0)

LogService.MessageOut:Connect(function(message, messageType)
	if not Config.con_spew then return end

	local kind = MESSAGE_KIND[messageType] or "spew"
	local serious = (kind == "warn" or kind == "error")

	if not serious and os.clock() < spewReadyAt then return end
	if not Config.con_spewRoblox and isRobloxNoise(message) then return end

	-- One printed Instance can be two thousand characters and eat the whole
	-- ring buffer on its own. Cut, with the real length said out loud so it is
	-- clear something was cut rather than that the message ended oddly.
	local limit = math.max(Config.con_maxlinelength or 300, 40)
	if #message > limit then
		message = message:sub(1, limit) .. ("  ... (%d chars)"):format(#message)
	end

	addLog(message, kind)
end)

--=====================================================================
-- TOKENISING
--=====================================================================

-- Quote-aware, unlike a plain split on ";". A bind carrying several commands
-- -- bind mwheeldown "+duck; +jump" -- would otherwise be torn in half before
-- the bind command ever saw it.
local function splitCommands(text)
	local out, current, inQuotes = {}, {}, false

	for i = 1, #text do
		local c = string.sub(text, i, i)
		if c == '"' then
			inQuotes = not inQuotes
			table.insert(current, c)
		elseif c == ";" and not inQuotes then
			table.insert(out, table.concat(current))
			table.clear(current)
		else
			table.insert(current, c)
		end
	end

	table.insert(out, table.concat(current))
	return out
end

--=====================================================================
-- SYNTAX COLOURING
--=====================================================================

-- One segment: [!] name value...
-- The name is coloured by what it actually resolves to, so a typo turns red
-- while you type it rather than after you press Enter.
local function paintSegment(segment)
	local lead, rest = segment:match("^(%s*)(.*)$")
	local out = { escape(lead) }

	local bang = ""
	if rest:sub(1, 1) == BROADCAST_PREFIX then
		bang = BROADCAST_PREFIX
		rest = rest:sub(2)
		table.insert(out, paint(bang, C.bang))
	end

	local name, gap, args = rest:match("^(%S*)(%s*)(.*)$")
	if name and name ~= "" then
		table.insert(out, paint(name, colourFor(name)))
	end
	if gap and gap ~= "" then table.insert(out, escape(gap)) end
	if args and args ~= "" then
		table.insert(out, paint(args, C.value))
	end

	return table.concat(out)
end

local function paintLine(text)
	local segments = splitCommands(text)
	local painted = {}
	for i, segment in ipairs(segments) do
		painted[i] = paintSegment(segment)
	end
	return table.concat(painted, paint(";", C.punct))
end

-- The hint beside the prompt: a cvar's live value in gold, or a command's
-- argument shape. This is the `name = value` readout, live as you type.
local function updateHint()
	if Config.con_hint == false then hint.Text = "" return end

	local segments = splitCommands(inputField.Text)
	local active = (segments[#segments] or ""):match("^%s*(.-)%s*$")
	if active:sub(1, 1) == BROADCAST_PREFIX then active = active:sub(2) end

	local name = active:match("^(%S+)")
	local entry = name and entries[name]
	if not entry then hint.Text = "" return end

	if entry.kind == "cvar" then
		hint.Text = paint(name, C.nameCvar) .. paint(" = ", C.punct)
			.. paint(tostring(Config.Values[name]), C.value)
	else
		hint.Text = paint(entry.usage or name, C.punct)
	end
end

local function updatePrompt()
	local text = inputField.Text
	local first = (splitCommands(text)[1] or ""):match("^%s*(.-)%s*$")

	if first:sub(1, 1) == BROADCAST_PREFIX then
		prompt.Text = "ALL ]"
		prompt.TextColor3 = C.bang
		return
	end

	local name = first:match("^(%S+)")
	if name and entries[name] then
		local tagText, tagColour = contextOf(name)
		prompt.Text = tagText .. " ]"
		prompt.TextColor3 = tagColour
	else
		prompt.Text = "]"
		prompt.TextColor3 = C.accent
	end
end

local function repaintInput()
	local plain = Config.con_syntax == false or inputField.Text == ""

	if not plain then
		inputPaint.Text = paintLine(inputField.Text)

		-- The overlay cannot follow the TextBox's horizontal scroll, so once a
		-- line is longer than the box the colours would sit still while the
		-- caret walked off the end. Past that width the real TextBox draws
		-- itself and the colour is given up -- being able to see what you are
		-- typing beats being able to see it in blue.
		if inputPaint.TextBounds.X > inputHolder.AbsoluteSize.X - 4 then
			plain = true
		end
	end

	if plain then
		inputPaint.Visible = false
		inputField.TextTransparency = 0
	else
		inputPaint.Visible = true
		-- The caret and selection still draw at full opacity; only the glyphs
		-- are hidden, and the overlay redraws them in colour on top.
		inputField.TextTransparency = 1
	end

	updatePrompt()
	updateHint()
end

--=====================================================================
-- VISIBILITY
--=====================================================================

local function syncOutputVisible()
	outputGui.Enabled = screenGui.Enabled or (Config.con_pin == true)
	pinButton.Text = Config.con_pin and "pinned" or "pin"
	pinButton.TextColor3 = Config.con_pin and C.accent or C.punct
end

local function isOpen()
	return screenGui.Enabled
end

-- Set the moment the toggle key is seen. sanitiseInput drops the key's own
-- glyph only inside a short window after this, which is what keeps a tilde
-- someone actually typed -- `echo ~` -- out of it.
local lastToggleClock = -1

-- Forward-declared: setOpen re-runs the cleaner after a toggle, and the cleaner
-- lives further down with the rest of the text handling. repaintInput is NOT
-- declared again here -- it is already in scope, and a second `local` would
-- shadow it with nil for the whole rest of the file.
local sanitiseInput

local function setOpen(open)
	if screenGui.Enabled == open then return end
	screenGui.Enabled = open
	syncOutputVisible()

	-- Deferred rather than immediate, because the glyph can arrive on either
	-- side of this handler: Roblox may type it into the focused box before the
	-- action fires or after. One pass a frame later catches both.
	task.defer(function()
		if sanitiseInput then sanitiseInput() end
		repaintInput()
	end)

	if open then
		-- Deferred: CaptureFocus on a ScreenGui that hasn't rendered yet is
		-- unreliable, and a frame's delay is imperceptible.
		task.defer(function()
			if screenGui.Enabled then inputField:CaptureFocus() end
		end)
	else
		-- Focus must be dropped explicitly. A focused TextBox is one of the
		-- things Input counts as modal, so leaving it focused would keep the
		-- cursor free and gameplay input dead after the console closes.
		inputField:ReleaseFocus()
		suggestions.Visible = false
	end
end

pinButton.Activated:Connect(function()
	Config.Set("con_pin", not Config.con_pin)
	syncOutputVisible()
end)
Config.OnChange("con_pin", syncOutputVisible)
syncOutputVisible()

-- Follows whatever key is bound to `toggleconsole` rather than hardcoding one,
-- and keeps firing while open because that command is flagged
-- modalPassthrough in Input -- a disabled InputContext delivers no events.
Input.ActionPressed.Event:Connect(function(command)
	if command == "toggleconsole" then
		lastToggleClock = os.clock()
		setOpen(not isOpen())
	end
end)

--=====================================================================
-- SUGGESTIONS
--=====================================================================

local commandHistory = {}
local historyIndex = 0
local currentPrefix = ""
local currentMatches = {}
local selectedIndex = 1
local suggestionRows = {}
local internalEdit = false

local function highlightSuggestion()
	for i, row in ipairs(suggestionRows) do
		local on = (i == selectedIndex)
		row.BackgroundTransparency = on and 0.75 or 1
		row.BackgroundColor3 = C.accent
	end

	local row = suggestionRows[selectedIndex]
	if row then
		local top = (selectedIndex - 1) * ROW_HEIGHT
		local view = suggestionList.AbsoluteWindowSize.Y
		local pos = suggestionList.CanvasPosition.Y
		if top < pos then
			suggestionList.CanvasPosition = Vector2.new(0, top)
		elseif top + ROW_HEIGHT > pos + view then
			suggestionList.CanvasPosition = Vector2.new(0, top + ROW_HEIGHT - view)
		end
	end
end

-- One row: [CL] name = value          (or the usage line for a command)
local function buildRow(name, index)
	local entry = entries[name]
	local tagText, tagColour = contextOf(name)

	local row = Instance.new("Frame")
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.LayoutOrder = index
	row.BackgroundColor3 = C.accent
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.Parent = suggestionList

	local tag = label(row, tagText, tagColour, 12)
	tag.Position = UDim2.new(0, 8, 0, 0)
	tag.Size = UDim2.new(0, 26, 1, 0)

	local cheat = hasFlag(entry.flag, Config.FCVAR.CHEAT)
	local body = label(row, "", C.reply, 14)
	body.Position = UDim2.new(0, 38, 0, 0)
	body.Size = UDim2.new(1, -46, 1, 0)
	body.RichText = true

	if entry.kind == "cvar" then
		body.Text = paint(name, C.nameCvar) .. paint(" = ", C.punct)
			.. paint(tostring(Config.Values[name]), C.value)
			.. paint(("   default %s"):format(tostring(entry.default)), C.spew)
			.. (cheat and paint("  CHEAT", C.warn) or "")
	else
		body.Text = paint(entry.usage or name, colourFor(name))
			.. (cheat and paint("  CHEAT", C.warn) or "")
	end

	table.insert(suggestionRows, row)
	return row
end

local function updateSuggestions()
	for _, row in ipairs(suggestionRows) do row:Destroy() end
	table.clear(suggestionRows)

	local text = inputField.Text
	currentMatches = {}
	selectedIndex = 1

	if text == "" or text:match("^%s*$") then
		suggestions.Visible = false
		return
	end

	-- Only complete the last segment of a semicolon chain.
	local segments = splitCommands(text)
	local active = (segments[#segments] or ""):match("^%s*(.-)%s*$")

	currentPrefix = ""
	if active:sub(1, 1) == BROADCAST_PREFIX then
		currentPrefix = BROADCAST_PREFIX
		active = active:sub(2)
	end

	local searchCmd = string.split(active, " ")[1]
	-- Once a space has been typed the command is settled and you are on its
	-- arguments, so the dropdown gets out of the way.
	if searchCmd == "" or string.find(active, " ") then
		suggestions.Visible = false
		return
	end

	local lowerSearch = string.lower(searchCmd)
	for _, name in ipairs(names) do
		if string.lower(string.sub(name, 1, #searchCmd)) == lowerSearch then
			table.insert(currentMatches, name)
		end
	end

	if #currentMatches == 0 then
		suggestions.Visible = false
		return
	end

	local shown = math.min(#currentMatches, math.max(Config.con_suggestions or 12, 1))
	for i = 1, shown do
		buildRow(currentMatches[i], i)
	end

	suggestions.Size = UDim2.new(0, 560, 0, math.min(shown, 10) * ROW_HEIGHT)
	suggestions.Visible = true
	highlightSuggestion()
end

-- Tab completes, but Roblox ALSO types the tab character into the box, and a
-- literal \t renders as a wide blank that throws the whole line's spacing out
-- (and the colour overlay's alignment with it). Newlines and carriage returns
-- arrive the same way from a paste. None of the three ever mean anything on a
-- command line, so they are removed wherever they come from rather than only
-- where completion put them.
function sanitiseInput()
	local text = inputField.Text
	local cleaned = text:gsub("[\t\n\r]", "")

	-- The toggle key types its own glyph into the box when the console is
	-- closed from a focused prompt, and it is still there on the next open.
	-- Scoped to a moment after the key was seen, so a tilde typed on purpose --
	-- `echo ~`, `say ~` -- is never touched. Tripping it by accident means
	-- typing a tilde in the same breath as the key that just opened the
	-- console, which is not something anyone means.
	if os.clock() - lastToggleClock < 0.25 then
		cleaned = cleaned:gsub("[`~]+$", "")
	end

	if cleaned == text then return false end

	internalEdit = true
	inputField.Text = cleaned
	internalEdit = false
	-- Deferred: a CursorPosition written in the same frame as Text is
	-- overwritten by the TextBox's own update.
	task.defer(function() inputField.CursorPosition = #inputField.Text + 1 end)
	return true
end

inputField:GetPropertyChangedSignal("Text"):Connect(function()
	-- The assignment inside sanitiseInput re-enters this handler with
	-- internalEdit set, so that pass repaints and stops; finish the job here.
	if sanitiseInput() then
		repaintInput()
		updateSuggestions()
		return
	end

	repaintInput()
	if internalEdit then return end
	updateSuggestions()
end)

local function applyCompletion()
	local name = currentMatches[selectedIndex]
	if not name then return end

	-- Preserve everything before the last semicolon and the '!' if one was
	-- typed; only the active segment is replaced.
	local segments = splitCommands(inputField.Text)
	segments[#segments] = " " .. currentPrefix .. name .. " "

	internalEdit = true
	inputField.Text = table.concat(segments, ";")
	internalEdit = false
	-- Deferred: a CursorPosition written in the same frame as Text is
	-- overwritten by the TextBox's own update.
	task.defer(function() inputField.CursorPosition = #inputField.Text + 1 end)

	suggestions.Visible = false
	repaintInput()
end

--=====================================================================
-- DISPATCH
--=====================================================================

-- Forward-declared so makeCtx can hand it out as ctx.exec.
local execOne

-- ctx.reply is the load-bearing field: without it Config falls back to warn()
-- and the command answers into the developer log.
--
-- ctx.exec is the second: a command that runs other command LINES (an alias
-- body) has to route each of them through the same local/remote split a typed
-- line takes, or `alias arms "primary ak47"` dies as an unknown command
-- instead of being forwarded.
local function makeCtx()
	return {
		player = plr,
		source = "console",
		reply = function(msg) addLog(msg, "reply") end,
		exec = function(line) return execOne(line) end,
	}
end

function execOne(line)
	-- Broadcast lines are never resolved locally. The name may belong to a
	-- server-only command this VM has no entry for, and even when it is a
	-- local cvar, the point of '!' is that the SERVER decides and pushes.
	if line:sub(1, 1) == BROADCAST_PREFIX then
		if line:match("^" .. BROADCAST_PREFIX .. "%s*$") then
			addLog("'!' needs a command after it", "error")
			return
		end
		ConsoleEvent:FireServer(line)
		return
	end

	local name = line:match("^(%S+)")
	if not name then return end

	local entry = entries[name]
	if not entry then
		addLog(("unknown command or cvar: %s"):format(name), "error")
		return
	end

	-- No local implementation. Hand the raw line over; ConsoleLog brings the
	-- reply back, so nothing is logged here.
	if entry.kind == "remote" then
		ConsoleEvent:FireServer(line)
		return
	end

	if entry.kind == "command" then
		-- The command speaks for itself through ctx.reply. Echoing the line
		-- back on success would double every output line.
		local ok, reason = Config.Exec(line, makeCtx())
		if not ok and reason then addLog(reason, "error") end
		return
	end

	--- cvar ---
	local rest = line:match("^%S+%s+(.*)$")

	if not rest or rest:match("^%s*$") then
		local tags = {}
		if hasFlag(entry.flag, Config.FCVAR.REPLICATED) then table.insert(tags, "server") end
		if hasFlag(entry.flag, Config.FCVAR.CHEAT) then table.insert(tags, "cheat") end

		addLog(paint(name, C.nameCvar) .. paint(" = ", C.punct)
			.. paint(tostring(Config.Get(name)), C.value)
			.. paint(("   default %s"):format(tostring(entry.default)), C.spew)
			.. (#tags > 0 and paint("   " .. table.concat(tags, ", "), C.warn) or ""),
			"reply", true)
		return
	end

	-- Replicated cvars are rejected by Config.Set on the client by design, so
	-- route them to the server, which accepts them from an admin.
	if hasFlag(entry.flag, Config.FCVAR.REPLICATED) then
		ConsoleEvent:FireServer(line)
		return
	end

	local ok, reason = Config.Set(name, rest)
	if ok then
		addLog(paint(name, C.nameCvar) .. paint(" = ", C.punct)
			.. paint(tostring(Config.Get(name)), C.value), "reply", true)
	else
		addLog(reason or ("failed to set " .. name), "error")
	end
end

-- Handed to Input here rather than beside Input.Reply, because execOne has to
-- be declared before this line can capture it. Bound keys then take the same
-- local/remote split a typed line does.
Input.Exec = function(line) execOne(line) end

local function submitCommand()
	local rawText = inputField.Text
	if rawText == "" or rawText:match("^%s*$") then return end

	addLog(paintLine(rawText), "echo", true)

	if commandHistory[#commandHistory] ~= rawText then
		table.insert(commandHistory, rawText)
		local maxHistory = math.max(Config.con_history or 64, 1)
		while #commandHistory > maxHistory do table.remove(commandHistory, 1) end
	end
	historyIndex = #commandHistory + 1

	for _, commandText in ipairs(splitCommands(rawText)) do
		commandText = commandText:match("^%s*(.-)%s*$")
		if commandText and commandText ~= "" then execOne(commandText) end
	end

	internalEdit = true
	inputField.Text = ""
	internalEdit = false
	suggestions.Visible = false
	repaintInput()
end

--=====================================================================
-- REMOTES IN
--=====================================================================

ConsoleLog.OnClientEvent:Connect(function(message, isError)
	addLog(tostring(message), isError and "error" or "server")
end)

-- Admin force-push. The server has already validated the sender and run the
-- line on its own VM; this applies the same line locally with forceOverride,
-- which is what lets it override a CLIENT-flagged cvar the player owns.
if ConsoleBroadcast then
	ConsoleBroadcast.OnClientEvent:Connect(function(line)
		if type(line) ~= "string" then return end

		local name = line:match("^(%S+)")
		if not name then return end

		-- Server-only commands don't exist in this VM. They already ran
		-- server-side, so dropping them here is correct, not a failure.
		if Config.Values[name] == nil and Config.Commands[name] == nil then return end

		local ctx = makeCtx()
		ctx.source = "server"
		ctx.admin = true
		ctx.forceOverride = true
		Config.Exec(line, ctx)

		addLog(line, "bang")
	end)
else
	warn("[DevConsole] no ConsoleBroadcast remote; '!' commands won't apply locally.")
end

--=====================================================================
-- KEYS
--=====================================================================
-- Arrow keys drive the dropdown when it is showing and the history when it is
-- not: one pair of keys, two meanings, disambiguated by what is on screen.

UserInputService.InputBegan:Connect(function(input)
	if not inputField:IsFocused() then return end
	local key = input.KeyCode

	if key == Enum.KeyCode.Up then
		if suggestions.Visible and #currentMatches > 0 then
			selectedIndex = math.max(selectedIndex - 1, 1)
			highlightSuggestion()
		elseif #commandHistory > 0 then
			historyIndex = math.max(1, historyIndex - 1)
			internalEdit = true
			inputField.Text = commandHistory[historyIndex]
			internalEdit = false
			repaintInput()
			task.defer(function() inputField.CursorPosition = #inputField.Text + 1 end)
		end

	elseif key == Enum.KeyCode.Down then
		if suggestions.Visible and #currentMatches > 0 then
			selectedIndex = math.min(selectedIndex + 1, #suggestionRows)
			highlightSuggestion()
		elseif #commandHistory > 0 then
			historyIndex = math.min(#commandHistory + 1, historyIndex + 1)
			internalEdit = true
			inputField.Text = commandHistory[historyIndex] or ""
			internalEdit = false
			repaintInput()
			task.defer(function() inputField.CursorPosition = #inputField.Text + 1 end)
		end

	elseif key == Enum.KeyCode.Tab then
		applyCompletion()

	elseif key == Enum.KeyCode.Escape then
		setOpen(false)
	end
end)

inputField.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		submitCommand()
		-- Refocused so a burst of commands does not need the key pressed
		-- between each one, which is how every console since Quake behaves.
		task.defer(function()
			if screenGui.Enabled then inputField:CaptureFocus() end
		end)
	end
end)

--=====================================================================
-- COMMANDS
--=====================================================================

-- Taken over rather than added alongside. If pConsole is still in the place,
-- both scripts register these names and Config warns about the redefinition on
-- every boot -- which is noise about a real problem, but noise all the same.
for _, name in ipairs({ "clear", "echo", "toggleconsole", "con_reset" }) do
	Config.RemoveCommand(name)
end

Config.Command("clear", {
	args = {},
	help = "empty the console output",
	run = function() clearLog() end,
})

Config.Command("echo", {
	args = { "rest" },
	help = "print a line to your own console",
	run = function(_, message) addLog(message, "reply") end,
})

Config.Command("toggleconsole", {
	args = {},
	help = "open or close the console",
	run = function()
		lastToggleClock = os.clock()
		setOpen(not isOpen())
	end,
})

Config.Command("con_reset", {
	args = {},
	help = "put the output panel back on the right edge at its default size",
	run = function(ctx)
		Config.Set("con_panelX", -1)
		Config.Set("con_panelY", 88)
		Config.Set("con_panelW", 440)
		Config.Set("con_panelH", 540)
		if ctx and ctx.reply then ctx.reply("[console] panel reset") end
	end,
})

repaintInput()
addLog("Glacier console. `help` lists commands, `find <text>` searches, `!` runs on the server.", "info")
