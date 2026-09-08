-- LocalScript: menusettings
-- ui = menu / Frame / Settings / menusettings
--
-- The settings panel: Half-Life's shape -- a rail of tabs down the side, one
-- page of named rows each -- with the sharp edges taken off.
--
-- WHAT IT IS ACTUALLY EDITING. Nothing in here holds a value of its own. Every
-- control reads a cvar through Config and writes it back through Config.Set,
-- and every keybind row reads and writes the real bind table through Input.
-- That matters more than it sounds: it means the console and this panel can
-- never disagree, `sensitivity 0.4` typed while the panel is open moves the
-- slider, and nothing needs an Apply button because there is no pending state
-- to apply.
--
-- WHAT IT DELIBERATELY DOES NOT DO. It does not persist. Roblox gives a client
-- no local storage, so remembering settings between sessions needs a server
-- DataStore keyed by UserId -- a real feature with its own failure modes, not
-- something to bolt onto a menu script. Everything here lasts the session.
--
-- ONLY CLIENT CVARS APPEAR. Config.Set refuses REPLICATED and CHEAT vars from
-- a client, so a server-owned setting in this list would render as a control
-- that silently does nothing. The rows below are all FCVAR.CLIENT.

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local plr = Players.LocalPlayer

local button = script.Parent
local gui = button:FindFirstAncestorWhichIsA("ScreenGui")
if not gui then
	error("[menusettings] not under a ScreenGui -- expected menu / Frame / Settings / menusettings", 0)
end

--=====================================================================
-- DEPENDENCIES
--=====================================================================

local function locateKit()
	local found = gui:FindFirstChild("MenuKit", true)
	if found and found:IsA("ModuleScript") then return require(found) end
	found = ReplicatedStorage:FindFirstChild("MenuKit")
	if found and found:IsA("ModuleScript") then return require(found) end
	return nil
end

local Kit = locateKit()
if not Kit then
	error("[menusettings] MenuKit not found -- put it under the menu ScreenGui " ..
		"or in ReplicatedStorage", 0)
end

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
local Input = ClientModules and require(ClientModules:WaitForChild("Input"))

local C = Kit.C

--=====================================================================
-- SHELL
--=====================================================================

local PANEL_W, PANEL_H = 780, 540
local RAIL_W = 168

-- The scrim is deliberately NOT captured: this panel does not close on an
-- outside click. See the note above button.Activated at the foot of the file.
local panel, openPanel, closePanel = Kit.Overlay(gui, PANEL_W, PANEL_H)

-- Tooltips draw on the panel, above everything on it. Set before any row is
-- built, since Row attaches its hover as it goes.
Kit.SetTipLayer(panel)

local header = Instance.new("Frame")
header.BackgroundTransparency = 1
header.Size = UDim2.new(1, 0, 0, 56)
header.Parent = panel

local title = Kit.Label(header, "Settings", C.text, 20, true)
title.Position = UDim2.new(0, 22, 0, 0)
title.Size = UDim2.new(0, 300, 1, 0)

local headerRule = Instance.new("Frame")
headerRule.BackgroundColor3 = C.lineSoft
headerRule.BorderSizePixel = 0
headerRule.AnchorPoint = Vector2.new(0, 1)
headerRule.Position = UDim2.new(0, 0, 1, 0)
headerRule.Size = UDim2.new(1, 0, 0, 1)
headerRule.Parent = header

--=====================================================================
-- TAB RAIL
--=====================================================================

local rail = Instance.new("Frame")
rail.BackgroundTransparency = 1
rail.Position = UDim2.new(0, 0, 0, 56)
rail.Size = UDim2.new(0, RAIL_W, 1, -56 - 58)
rail.Parent = panel
Kit.Pad(rail, 12, 14, 8, 12)
Kit.List(rail, 3)

local railRule = Instance.new("Frame")
railRule.BackgroundColor3 = C.lineSoft
railRule.BorderSizePixel = 0
railRule.Position = UDim2.new(0, RAIL_W, 0, 56)
railRule.Size = UDim2.new(0, 1, 1, -56 - 58)
railRule.Parent = panel

-- The moving indicator. One instance that slides between tabs rather than a
-- highlight fading in and out per tab: the slide is what tells you the pages
-- are a list and which way you just moved through it.
local marker = Instance.new("Frame")
marker.BackgroundColor3 = C.accent
marker.BorderSizePixel = 0
marker.AnchorPoint = Vector2.new(0, 0.5)
marker.Size = UDim2.new(0, 3, 0, 18)
marker.Position = UDim2.new(0, 6, 0, 0)
marker.Visible = false
marker.ZIndex = 12
marker.Parent = panel
Kit.Corner(marker, 2)

--=====================================================================
-- PAGES
--=====================================================================

local body = Instance.new("Frame")
body.BackgroundTransparency = 1
body.Position = UDim2.new(0, RAIL_W + 1, 0, 56)
body.Size = UDim2.new(1, -(RAIL_W + 1), 1, -56 - 58)
body.ClipsDescendants = true
body.Parent = panel

local pages = {}
local tabs = {}
local current = nil

local function newPage(name)
	local page = Instance.new("ScrollingFrame")
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.Size = UDim2.fromScale(1, 1)
	page.Visible = false
	page.ScrollBarThickness = 3
	page.ScrollBarImageColor3 = C.line
	page.CanvasSize = UDim2.new()
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.ScrollingDirection = Enum.ScrollingDirection.Y
	page.Parent = body
	Kit.Pad(page, 14, 22, 22, 22)

	local list = Kit.List(page, 2)
	list.SortOrder = Enum.SortOrder.LayoutOrder

	pages[name] = page
	return page
end

local function selectTab(name, animated)
	if current == name then return end
	current = name

	for tabName, tab in pairs(tabs) do
		local on = tabName == name
		Kit.Tween(tab.label, Kit.HOVER, { TextColor3 = on and C.text or C.dim })
		Kit.Tween(tab.button, Kit.HOVER, { BackgroundTransparency = on and 0.6 or 1 })
	end

	for pageName, page in pairs(pages) do
		page.Visible = pageName == name
	end

	local tab = tabs[name]
	if not tab then return end

	-- Positioned from the button's absolute placement rather than from a
	-- running total, so the rail can be reordered or padded without this
	-- needing to know.
	local y = (tab.button.AbsolutePosition.Y - panel.AbsolutePosition.Y)
		+ tab.button.AbsoluteSize.Y * 0.5
	local target = UDim2.new(0, 6, 0, y)

	if animated and marker.Visible then
		Kit.Tween(marker, Kit.OPEN, { Position = target })
	else
		marker.Position = target
		marker.Visible = true
	end
end

local tabOrder = 0

-- sub: a page that belongs UNDER the one above it rather than beside it.
-- Indented and a size smaller, which is the whole of what "sub" has to mean
-- in a rail this short -- a nested, collapsible tree for six pages would be
-- more mechanism than the thing it organises.
local function newTab(name, sub)
	tabOrder += 1

	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BackgroundColor3 = C.raised
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.Text = ""
	b.Size = UDim2.new(1, 0, 0, sub and 28 or 32)
	b.LayoutOrder = tabOrder
	b.Parent = rail
	Kit.Corner(b, 5)

	local l = Kit.Label(b, name, C.dim, sub and 13 or 14)
	l.Position = UDim2.new(0, sub and 26 or 12, 0, 0)
	l.Size = UDim2.new(1, sub and -26 or -12, 1, 0)

	if sub then
		-- A short rule from the tab above, so the indent reads as nesting
		-- rather than as a typo.
		local tick = Instance.new("Frame")
		tick.BackgroundColor3 = C.lineSoft
		tick.BorderSizePixel = 0
		tick.AnchorPoint = Vector2.new(0, 0.5)
		tick.Position = UDim2.new(0, 15, 0.5, 0)
		tick.Size = UDim2.new(0, 6, 0, 1)
		tick.Parent = b
	end

	b.MouseEnter:Connect(function()
		if current ~= name then
			Kit.Tween(l, Kit.HOVER, { TextColor3 = C.text })
		end
	end)
	b.MouseLeave:Connect(function()
		if current ~= name then
			Kit.Tween(l, Kit.HOVER, { TextColor3 = C.dim })
		end
	end)
	b.Activated:Connect(function() selectTab(name, true) end)

	tabs[name] = { button = b, label = l }
	return newPage(name)
end

-- Tabs that only exist when cl_developer is on. Hidden rather than disabled,
-- because a page of switches you cannot reach is clutter, not information --
-- and the switch that brings them back is in Controls, which is never hidden.
local devTabs = {}

local function refreshDevTabs()
	local on = Config.cl_developer ~= false
	for _, name in ipairs(devTabs) do
		local tab = tabs[name]
		if tab then tab.button.Visible = on end
	end

	-- Sitting on a page that just disappeared, go somewhere that still
	-- exists rather than leaving the body empty with no tab lit.
	if not on then
		for _, name in ipairs(devTabs) do
			if current == name then
				current = nil
				selectTab("Controls", true)
				break
			end
		end
	end
end

--=====================================================================
-- CVAR-BACKED CONTROLS
--=====================================================================
-- Each of these owns one cvar end to end: it reads the live value to build
-- itself, writes through Config.Set, and subscribes to Config.OnChange so a
-- console set moves the widget. That subscription is the whole reason these
-- are helpers rather than three lines at each call site -- forgetting it on
-- one row is how a settings panel starts lying about the game's state.

local pageCvars = {}   -- [page name] = { cvar, ... }, for Reset

local function track(pageName, cvar)
	pageCvars[pageName] = pageCvars[pageName] or {}
	table.insert(pageCvars[pageName], cvar)
end

local function cvarSlider(pageName, cvar, label, desc, min, max, step, fmt)
	local page = pages[pageName]
	if Config.Values[cvar] == nil then
		warn(("[menusettings] no cvar %q -- row skipped"):format(cvar))
		return
	end
	track(pageName, cvar)

	local _, slot = Kit.Row(page, label, desc)
	local setWidget = Kit.Slider(slot, min, max, Config[cvar], step, fmt, function(v)
		local ok, why = Config.Set(cvar, v)
		if not ok then warn(("[menusettings] %s: %s"):format(cvar, why)) end
	end)

	Config.OnChange(cvar, function(value) setWidget(value) end)
end

local function cvarToggle(pageName, cvar, label, desc)
	local page = pages[pageName]
	if Config.Values[cvar] == nil then
		warn(("[menusettings] no cvar %q -- row skipped"):format(cvar))
		return
	end
	track(pageName, cvar)

	local _, slot = Kit.Row(page, label, desc)
	local setWidget = Kit.Toggle(slot, Config[cvar], function(v)
		local ok, why = Config.Set(cvar, v)
		if not ok then warn(("[menusettings] %s: %s"):format(cvar, why)) end
	end)

	Config.OnChange(cvar, function(value) setWidget(value) end)
end

local function cvarChoice(pageName, cvar, label, desc, options)
	local page = pages[pageName]
	if Config.Values[cvar] == nil then
		warn(("[menusettings] no cvar %q -- row skipped"):format(cvar))
		return
	end
	track(pageName, cvar)

	local _, slot = Kit.Row(page, label, desc)

	local index = 1
	for i, opt in ipairs(options) do
		if opt.value == Config[cvar] then index = i break end
	end

	local setWidget = Kit.Choice(slot, options, index, function(value)
		local ok, why = Config.Set(cvar, value)
		if not ok then warn(("[menusettings] %s: %s"):format(cvar, why)) end
	end)

	Config.OnChange(cvar, function(value) setWidget(value) end)
end

-- R, G and B as three sliders over ONE Color3 cvar.
--
-- A colour is one value to Config and three numbers to a person, and the gap
-- between those is this helper. Each slider reads its own channel out of the
-- live cvar and writes a whole new Color3 back with only that channel
-- changed -- rebuilt from the CURRENT value each time rather than from a
-- remembered one, so a console `cl_crosshaircolor 255 0 0` between two drags
-- is not quietly undone by the next slider that moves.
--
-- 0..255 because that is what everyone else calls a colour channel, even
-- though Color3 stores 0..1 and the conversion has to happen twice per edit.
local function colourSliders(pageName, cvar, labels)
	local page = pages[pageName]
	if Config.Values[cvar] == nil then
		warn(("[menusettings] no cvar %q -- rows skipped"):format(cvar))
		return
	end
	track(pageName, cvar)

	local setters = {}
	local writing = false

	local function byte(v) return string.format("%d", v) end

	local startBytes = Kit.ColourBytes(Config[cvar])

	for i = 1, 3 do
		local _, slot = Kit.Row(page, labels[i])

		setters[i] = Kit.Slider(slot, 0, 255, startBytes[i], 1, byte, function(v)
			-- Latched across the write, because Config.Set fires OnChange
			-- synchronously and the handler below would push all three
			-- sliders back -- including this one, mid-drag, to the value it
			-- just sent. The knob would fight the pointer.
			writing = true
			local ok, why = Config.Set(cvar, Kit.WithChannel(Config[cvar], i, v))
			writing = false
			if not ok then warn(("[menusettings] %s: %s"):format(cvar, why)) end
		end)
	end

	Config.OnChange(cvar, function(value)
		if writing then return end
		local bytes = Kit.ColourBytes(value)
		for i = 1, 3 do setters[i](bytes[i]) end
	end)
end

local function section(pageName, name)
	Kit.Section(pages[pageName], name)
end

--=====================================================================
-- CONTROLS
--=====================================================================

local controls = newTab("Controls")

local capturing = nil   -- the row currently waiting for a key

local function keyText(keys)
	if #keys == 0 then return "unbound" end
	return table.concat(keys, ", ")
end

-- THREE CONTROLS PER ROW: the keys, Clear, Reset.
--
-- One button doing all of it was too clever. Left click to rebind and right
-- click to clear is a thing you have to be told, and there was no way at all
-- to put a single row back to its default -- the only reset was the page
-- button, which throws away nine deliberate binds to recover the tenth.
--
--   keys    click to add an input, then press one
--   Clear   every key off this action
--   Reset   back to what the game shipped with, this row only
local BIND_SLOT_W = 262

local function bindRow(entry)
	local _, slot = Kit.Row(controls, entry.label, nil, BIND_SLOT_W)

	local keysButton = Kit.Button(slot, "", "normal", nil)
	keysButton.AnchorPoint = Vector2.new(0, 0.5)
	keysButton.Position = UDim2.new(0, 0, 0.5, 0)
	keysButton.Size = UDim2.new(0, 140, 0, 28)
	keysButton.Font = Enum.Font.Code
	keysButton.TextSize = 12

	local clear = Kit.Button(slot, "Clear", "normal", nil)
	clear.AnchorPoint = Vector2.new(0, 0.5)
	clear.Position = UDim2.new(0, 146, 0.5, 0)
	clear.Size = UDim2.new(0, 55, 0, 28)
	clear.TextSize = 12

	local reset = Kit.Button(slot, "Reset", "normal", nil)
	reset.AnchorPoint = Vector2.new(0, 0.5)
	reset.Position = UDim2.new(0, 207, 0.5, 0)
	reset.Size = UDim2.new(0, 55, 0, 28)
	reset.TextSize = 12

	local function refresh()
		-- Left alone mid-capture, or the "press a key" prompt is overwritten
		-- by a refresh triggered from some other row's rebind.
		if capturing == entry.command then return end

		local keys = Input.GetKeysFor(entry.command)
		keysButton.Text = keyText(keys)
		keysButton.TextColor3 = (#keys == 0) and C.faint or C.text

		-- Dimmed when there is nothing to undo. Both still WORK -- a disabled
		-- button that silently does nothing is worse than one that no-ops --
		-- but the colour says which rows have been touched.
		local defaults = Input.DefaultKeysFor(entry.command)
		local isDefault = (#keys == #defaults)
		if isDefault then
			for i, key in ipairs(defaults) do
				if keys[i] ~= key then isDefault = false break end
			end
		end
		reset.TextColor3 = isDefault and C.faint or C.text
		clear.TextColor3 = (#keys == 0) and C.faint or C.text
	end
	refresh()

	keysButton.Activated:Connect(function()
		if capturing then return end
		capturing = entry.command
		keysButton.Text = "press a key..."
		keysButton.TextColor3 = C.warn

		task.spawn(function()
			-- CaptureNextInput goes modal on its own and returns nil on Escape
			-- or timeout, which is the cancel path. Ten seconds so a player
			-- who wandered off does not leave the game input-dead.
			local key = Input.CaptureNextInput(10)
			capturing = nil

			if key then
				local ok, why = Input.Bind(key, entry.command)
				if not ok then warn(("[menusettings] bind: %s"):format(why)) end
			end
			refresh()
		end)
	end)

	clear.Activated:Connect(function()
		if capturing then return end
		Input.ClearBind(entry.command)
		refresh()
	end)

	reset.Activated:Connect(function()
		if capturing then return end
		Input.ResetBind(entry.command)
		refresh()
	end)

	-- Kept from before, because it costs nothing and anyone who learned it
	-- once should not have to unlearn it.
	keysButton.MouseButton2Click:Connect(function()
		if capturing then return end
		Input.ClearBind(entry.command)
		refresh()
	end)

	return refresh
end

local bindRefreshers = {}

if Input then
	section("Controls", "Movement")

	for _, entry in ipairs(Input.GetBindingList()) do
		-- Sectioned by the order numbers the command table already carries,
		-- rather than by a second list here that would drift from it.
		if entry.order == 10 then section("Controls", "Combat") end
		if entry.order == 13 then section("Controls", "Weapons") end
		if entry.order == 16 then section("Controls", "Interface") end

		table.insert(bindRefreshers, bindRow(entry))
	end

	-- Anything rebound from the console lands here too.
	Input.BindingChanged.Event:Connect(function()
		for _, refresh in ipairs(bindRefreshers) do refresh() end
	end)

	-- Not a binding, but it belongs beside the Console key it governs: with
	-- this off that key does nothing, and looking for the reason anywhere
	-- other than next to the row is a waste of somebody's afternoon.
	--
	-- It also has to live OUTSIDE the console, because the console is the one
	-- place you can no longer reach once it is off.
	section("Controls", "Developer")
	cvarToggle("Controls", "cl_developer", "Developer menu",
		"Lets the console open. What it can change is still gated by " ..
		"sv_cheats and by the server; this only decides whether the key works.")
else
	local warning = Kit.Label(controls,
		"Input module not found -- keybinds unavailable.", C.danger, 13)
	warning.Size = UDim2.new(1, 0, 0, 40)
end

--=====================================================================
-- MOUSE
--=====================================================================

newTab("Mouse")
section("Mouse", "Aim")

local function two(v) return string.format("%.2f", v) end

cvarSlider("Mouse", "sensitivity", "Sensitivity", nil, 0.02, 1.5, 0.01, two)
cvarSlider("Mouse", "m_yaw", "Horizontal multiplier",
	"Trims left/right only. Leave at 1 unless you know why.", 0.25, 3, 0.05, two)
cvarSlider("Mouse", "m_pitch", "Vertical multiplier",
	"Trims up/down only.", 0.25, 3, 0.05, two)

section("Mouse", "Behaviour")

cvarToggle("Mouse", "m_invert", "Reverse mouse", "Pushing forward looks down.")
cvarToggle("Mouse", "m_filter", "Mouse filter",
	"Averages each frame with the last. Smoother, and half a frame slower.")

do
	-- Said plainly rather than offered as a switch that does nothing. Roblox
	-- reports mouse movement as a relative delta with no acceleration applied,
	-- so raw input is the only mode there is.
	local note = Kit.Label(pages["Mouse"],
		"Raw input is always on: the engine receives unaccelerated mouse deltas " ..
		"and there is no smoothed mode to turn off.", C.faint, 11)
	note.Size = UDim2.new(1, 0, 0, 30)
	note.TextWrapped = true
	note.TextYAlignment = Enum.TextYAlignment.Top
	-- Added straight to the page rather than through Row, so it needs its
	-- place in the order set by hand. See MenuKit.Order.
	note.LayoutOrder = #pages["Mouse"]:GetChildren()
end

--=====================================================================
-- VIDEO
--=====================================================================

newTab("Video")
section("Video", "Camera")

cvarSlider("Video", "fov", "Field of view", nil, 60, 120, 1,
	function(v) return string.format("%d", v) end)

cvarChoice("Video", "cl_showViewmodelMode", "Viewmodel", "What you see of your own weapon.", {
	{ label = "Shown",      value = 0 },
	{ label = "Hidden",     value = 1 },
	{ label = "World only", value = 2 },
})

cvarToggle("Video", "cl_showbody", "Show body", "Your own legs in first person.")

section("Video", "View bob")

cvarToggle("Video", "cl_bobEnabled", "Weapon bob")
cvarSlider("Video", "cl_bobamt_vert", "Bob amount, vertical", nil, 0, 8, 0.1, two)
cvarSlider("Video", "cl_bobamt_lat", "Bob amount, lateral", nil, 0, 8, 0.1, two)
cvarToggle("Video", "cl_bobCamera", "Bob the camera too", "GoldSrc behaviour.")

section("Video", "Crosshair")

--=====================================================================
-- CROSSHAIR PREVIEW
--=====================================================================
-- Numbers alone are guesswork: nobody knows what a gap of 4 and a size of 7
-- look like together until they close the menu and shoot something. This is
-- the same crosshair, drawn from the same geometry function the real one
-- uses -- see Crosshair.Layout -- so it cannot drift from what you get.
--
-- The spread is not simulated. The live crosshair opens with the weapon's
-- actual cone, and faking that here would show a number the player cannot
-- set; what the preview shows is the RESTING shape, which is what these
-- sliders control.

do
	local Crosshair = ClientModules and ClientModules:FindFirstChild("Crosshair")
	Crosshair = Crosshair and require(Crosshair)

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 132)
	Kit.Order(pages["Video"], row)
	row.Parent = pages["Video"]

	local canvas = Instance.new("Frame")
	canvas.AnchorPoint = Vector2.new(0.5, 0)
	canvas.Position = UDim2.new(0.5, 0, 0, 4)
	canvas.Size = UDim2.new(0, 260, 0, 120)
	canvas.BackgroundColor3 = Color3.fromRGB(46, 52, 44)
	canvas.BorderSizePixel = 0
	canvas.ClipsDescendants = true
	canvas.Parent = row
	Kit.Corner(canvas, 6)
	Kit.Stroke(canvas, C.line, 1, 0.35)

	-- Something to be legible AGAINST. A crosshair on flat grey tells you
	-- nothing about whether it disappears on a wall, and picking a colour is
	-- most of what these settings are for.
	local swatch = Instance.new("Frame")
	swatch.BackgroundColor3 = Color3.fromRGB(120, 116, 104)
	swatch.BorderSizePixel = 0
	swatch.Position = UDim2.fromScale(0.5, 0)
	swatch.Size = UDim2.fromScale(0.5, 1)
	swatch.Parent = canvas

	local bars = {}
	for _, name in ipairs({ "top", "bottom", "left", "right", "dot" }) do
		local bar = Instance.new("Frame")
		bar.Name = name
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.BorderSizePixel = 0
		bar.ZIndex = 3
		bar.Visible = false
		bar.Parent = canvas

		local outline = Instance.new("UIStroke")
		outline.Color = Color3.new(0, 0, 0)
		outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		outline.Parent = bar

		bars[name] = { frame = bar, outline = outline }
	end

	local function redraw()
		for _, bar in pairs(bars) do bar.frame.Visible = false end
		if Config.cl_crosshair == false then return end
		if not Crosshair then return end

		local thickness = Config.cl_crosshairthickness or 2
		local length    = Config.cl_crosshairsize or 7
		local gap       = Config.cl_crosshairgap or 4
		local colour    = Config.cl_crosshaircolor or Color3.fromRGB(0, 255, 0)
		local alpha     = 1 - (Config.cl_crosshairalpha or 1)
		local outline   = Config.cl_crosshair_drawoutline and 1 or 0

		for _, spec in ipairs(Crosshair.Layout(gap, length, thickness, Config.cl_crosshairdot)) do
			local bar = bars[spec.name]
			if bar then
				bar.frame.Position = UDim2.new(0.5, spec.dx, 0.5, spec.dy)
				bar.frame.Size = UDim2.fromOffset(spec.w, spec.h)
				bar.frame.BackgroundColor3 = colour
				bar.frame.BackgroundTransparency = alpha
				bar.outline.Thickness = outline
				bar.frame.Visible = true
			end
		end
	end

	if not Crosshair then
		local warning = Kit.Label(canvas,
			"Crosshair module not found -- no preview.", C.faint, 12)
		warning.Size = UDim2.fromScale(1, 1)
		warning.TextXAlignment = Enum.TextXAlignment.Center
	end

	-- Redrawn from the cvars whichever way they moved -- this panel, the
	-- console, or a server override -- so the preview is never showing a
	-- state the game is not in.
	for _, cvar in ipairs({
		"cl_crosshair", "cl_crosshairsize", "cl_crosshairgap",
		"cl_crosshairthickness", "cl_crosshairalpha", "cl_crosshairdot",
		"cl_crosshair_drawoutline", "cl_crosshaircolor",
	}) do
		if Config.Values[cvar] ~= nil then
			Config.OnChange(cvar, redraw)
		end
	end

	redraw()
end


cvarToggle("Video", "cl_crosshair", "Crosshair")
cvarToggle("Video", "cl_dynamiccrosshair", "Opens while moving")
cvarSlider("Video", "cl_crosshairsize", "Size", nil, 0, 20, 1,
	function(v) return string.format("%d", v) end)
cvarSlider("Video", "cl_crosshairgap", "Gap", nil, 0, 20, 1,
	function(v) return string.format("%d", v) end)
cvarSlider("Video", "cl_crosshairthickness", "Thickness", nil, 1, 8, 1,
	function(v) return string.format("%d", v) end)
cvarToggle("Video", "cl_crosshairdot", "Centre dot")
cvarToggle("Video", "cl_crosshair_drawoutline", "Outline")

section("Video", "Crosshair colour")

colourSliders("Video", "cl_crosshaircolor", { "Red", "Green", "Blue" })

-- Alpha sits with R, G and B because that is where anyone looks for it, even
-- though it is a separate cvar: Color3 has no alpha channel, and the game
-- draws the crosshair's transparency from its own number.
cvarSlider("Video", "cl_crosshairalpha", "Alpha",
	"1 is solid, 0 is invisible.", 0, 1, 0.01, two)

section("Video", "World")

cvarToggle("Video", "cl_tracers", "Bullet tracers")

--=====================================================================
-- VEHICLES
--=====================================================================
-- A SUBTAB under Video rather than a page of its own: everything here is a
-- camera or a crosshair, and a top-level Vehicles tab that turned out to hold
-- four camera settings would be a promise the page does not keep.

newTab("Vehicles", true)
section("Vehicles", "Camera")

cvarSlider("Vehicles", "cl_vehicle_sensitivity", "Mouse sensitivity",
	"Multiplier on your usual sensitivity while driving. A chase camera " ..
	"sweeps a wider arc for the same wrist movement than aiming does.",
	0.1, 2, 0.05, two)

cvarToggle("Vehicles", "cl_vehicle_freelook", "Free look",
	"The mouse orbits the camera. Off, it stays behind the car.")

cvarSlider("Vehicles", "cl_vehicle_camautocenter", "Recentre after",
	"Seconds of not touching the mouse before the camera swings back behind " ..
	"the car. 0 leaves it where you pointed it.",
	0, 6, 0.2, function(v)
		if v <= 0 then return "off" end
		return string.format("%.1f s", v)
	end)

cvarSlider("Vehicles", "cl_vehicle_camautorate", "Recentre speed",
	"How quickly it swings back once it starts.", 0.5, 10, 0.1, two)

section("Vehicles", "View")

cvarSlider("Vehicles", "cl_vehicle_camdist", "Camera distance", nil, 8, 32, 0.5, two)
cvarSlider("Vehicles", "cl_vehicle_camheight", "Camera height", nil, 1, 12, 0.2, two)
cvarSlider("Vehicles", "cl_vehicle_campitch", "Camera pitch",
	"Degrees. Negative looks down at the car.", -35, 10, 1, two)
cvarSlider("Vehicles", "cl_vehicle_camlag", "Camera lag",
	"Higher is stiffer; the camera follows the car more tightly.", 1, 20, 0.5, two)
cvarSlider("Vehicles", "cl_vehicle_camfovgain", "Speed FOV",
	"Extra field of view at the car's top speed.", 0, 40, 1, two)

cvarToggle("Vehicles", "cl_vehicle_crosshair", "Show crosshair",
	"There is nothing to aim while driving, so it is off by default.")

--=====================================================================
-- AUDIO
--=====================================================================

newTab("Audio")
section("Audio", "Levels")

cvarSlider("Audio", "volume", "Master volume", nil, 0, 1, 0.05, two)
cvarSlider("Audio", "snd_impact_volume", "Impacts", nil, 0, 1, 0.05, two)

section("Audio", "Feedback")

cvarToggle("Audio", "snd_hitsound", "Hit sound", "A tone when you damage someone.")
cvarSlider("Audio", "snd_hitsound_volume", "Hit sound volume", nil, 0, 1, 0.05, two)

section("Audio", "Simulation")

cvarToggle("Audio", "snd_acousticSim", "Acoustic simulation",
	"Occlusion and reverb from the geometry around each sound.")

--=====================================================================
-- NETWORK
--=====================================================================

newTab("Network")
section("Network", "Interpolation")

cvarSlider("Network", "cl_interp", "Interpolation buffer",
	"Seconds other players are drawn behind. Higher is smoother, later.",
	0, 0.3, 0.005, function(v) return string.format("%.3f", v) end)

cvarToggle("Network", "cl_extrapolate", "Extrapolate",
	"Guess ahead when a packet is late instead of freezing.")

--=====================================================================
-- DEBUG
--=====================================================================
-- A sub-tab of Network in the rail's order, and gated on cl_developer with
-- the console: "developer menu" meaning the console but not the debug
-- overlays would be a distinction nobody asked for.
--
-- These are all overlays and readouts. Nothing here changes how the game
-- plays, which is why they are CLIENT cvars a player may set freely -- the
-- things that WOULD change play (cl_spray_debug and friends) are CHEAT
-- flagged, would be refused by Config.Set, and are deliberately not listed:
-- a control that silently does nothing is worse than no control.

newTab("Debug", true)
table.insert(devTabs, "Debug")

section("Debug", "Overlays")

cvarToggle("Debug", "cl_debugHud", "Debug HUD",
	"Position, speed, stance and the rest, top left.")
cvarToggle("Debug", "cl_debugGraph", "Frame graph")
cvarSlider("Debug", "cl_debugGraphScale", "Graph ceiling",
	"Studs per second at the top of the graph. 0 scales to whatever is happening.",
	0, 400, 5, function(v) return string.format("%d", v) end)
cvarToggle("Debug", "cl_debugWeapon", "Weapon panel",
	"Spread, recoil and the state of the gun in your hands.")

section("Debug", "In the world")

cvarToggle("Debug", "cl_debugHull", "Draw collision hull",
	"The box the movement code actually collides with, which is not the model.")
cvarToggle("Debug", "cl_debugVectors", "Draw movement vectors",
	"Velocity, wish direction and the ground normal.")
cvarToggle("Debug", "cl_vehicle_debug", "Vehicle rays",
	"Suspension casts and tyre forces on the car you are driving.")

section("Debug", "Server")

cvarToggle("Debug", "cl_serverDebug", "Server panel",
	"What the server thinks is happening, beside what you think is.")
cvarToggle("Debug", "cl_serverDebugPlayers", "Per-player rows",
	"Needs sv_cheats on the server; without it the server sends nothing.")
cvarSlider("Debug", "cl_serverDebugScale", "Server panel scale", nil,
	0.5, 2, 0.05, two)

section("Debug", "Movement")

cvarToggle("Debug", "mv_debugStops", "Warn on lost speed",
	"Prints to the console when a collision eats most of your velocity.")

refreshDevTabs()
Config.OnChange("cl_developer", refreshDevTabs)

--=====================================================================
-- FOOTER
--=====================================================================

local footer = Instance.new("Frame")
footer.BackgroundTransparency = 1
footer.AnchorPoint = Vector2.new(0, 1)
footer.Position = UDim2.new(0, 0, 1, 0)
footer.Size = UDim2.new(1, 0, 0, 58)
footer.Parent = panel
Kit.Pad(footer, 12, 22, 22, 12)

-- Parented to the panel, not to the padded footer, or the hairline would be
-- inset by the padding and stop reading as a divider.
local footerRule = Instance.new("Frame")
footerRule.BackgroundColor3 = C.lineSoft
footerRule.BorderSizePixel = 0
footerRule.AnchorPoint = Vector2.new(0, 1)
footerRule.Position = UDim2.new(0, 0, 1, -58)
footerRule.Size = UDim2.new(1, 0, 0, 1)
footerRule.Parent = panel

local footerButtons = Instance.new("Frame")
footerButtons.BackgroundTransparency = 1
footerButtons.Size = UDim2.fromScale(1, 1)
footerButtons.Parent = footer

local footerLayout = Kit.List(footerButtons, 10, Enum.FillDirection.Horizontal)
footerLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
footerLayout.VerticalAlignment = Enum.VerticalAlignment.Center

local function resetPage()
	if current == "Controls" then
		if Input then
			Input.UnbindAll()
			Input.BindDefaults()
		end
		return
	end

	-- Config.GetDefault is the shipped value, so this restores what the game
	-- came with rather than what it happened to be when the panel opened.
	for _, cvar in ipairs(pageCvars[current] or {}) do
		local default = Config.GetDefault(cvar)
		if default ~= nil then Config.Set(cvar, default) end
	end
end

local reset = Kit.Button(footerButtons, "Reset this page", "normal", resetPage)
reset.Size = UDim2.new(0, 140, 0, 34)
reset.LayoutOrder = 1

local open = false

local escapeListener   -- assigned below; declared here for hide()

local function hide()
	if not open then return end
	open = false
	if escapeListener then escapeListener:Disconnect() escapeListener = nil end
	closePanel()
end

local done = Kit.Button(footerButtons, "Done", "primary", function() hide() end)
done.Size = UDim2.new(0, 100, 0, 34)
done.LayoutOrder = 2

--=====================================================================
-- OPEN / CLOSE
--=====================================================================

-- DELIBERATELY NOT CLOSED by a click on the scrim, unlike the quit prompt.
--
-- The pointer leaves this panel constantly -- every slider drag that runs
-- past the end of its bar ends outside it -- and losing a page of settings to
-- a stray click is the most irritating thing a settings menu can do. It
-- closes on Done, on Escape, and when the menu behind it closes.
--
-- The scrim still SWALLOWS the click, which is the other half of its job:
-- without it a click beside the panel would reach the menu buttons behind.
button.Activated:Connect(function()
	if open then return end
	open = true
	openPanel()

	escapeListener = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode ~= Enum.KeyCode.Escape then return end

		-- Escape is CaptureNextInput's cancel, and a rebind prompt is the one
		-- place it must not also close the panel: you would press Escape to
		-- back out of "press a key" and lose the whole page with it.
		if capturing then return end

		hide()
	end)

	-- Deferred one frame: the marker is positioned from the tab button's
	-- ABSOLUTE placement, and on the first open the rail has not been laid
	-- out yet, so it would land at the top of the panel.
	task.defer(function()
		if not current then
			selectTab("Controls", false)
		else
			selectTab(current, false)
		end
	end)
end)

-- The panel is a child of the menu, so it goes when the menu goes. Without
-- this it would survive a spawn and sit over the running game.
gui:GetPropertyChangedSignal("Enabled"):Connect(function()
	if not gui.Enabled then hide() end
end)
