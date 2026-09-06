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

local panel, openPanel, closePanel, scrim = Kit.Overlay(gui, PANEL_W, PANEL_H)

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
local function newTab(name)
	tabOrder += 1

	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BackgroundColor3 = C.raised
	b.BackgroundTransparency = 1
	b.BorderSizePixel = 0
	b.Text = ""
	b.Size = UDim2.new(1, 0, 0, 32)
	b.LayoutOrder = tabOrder
	b.Parent = rail
	Kit.Corner(b, 5)

	local l = Kit.Label(b, name, C.dim, 14)
	l.Position = UDim2.new(0, 12, 0, 0)
	l.Size = UDim2.new(1, -12, 1, 0)

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

local function bindRow(entry)
	local _, slot = Kit.Row(controls, entry.label)

	local b = Kit.Button(slot, "", "normal", nil)
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, 0, 0.5, 0)
	b.Size = UDim2.new(0, 150, 0, 28)
	b.Font = Enum.Font.Code

	local function refresh()
		if capturing == entry.command then return end
		local keys = Input.GetKeysFor(entry.command)
		b.Text = keyText(keys)
		b.TextColor3 = (#keys == 0) and C.faint or C.text
	end
	refresh()

	b.Activated:Connect(function()
		if capturing then return end
		capturing = entry.command
		b.Text = "press a key..."
		b.TextColor3 = C.warn

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

	-- Right-click clears every key on this action. HL made you bind a key to
	-- something else to get rid of it; this is the same idea with one less step.
	b.MouseButton2Click:Connect(function()
		if capturing then return end
		for _, key in ipairs(Input.GetKeysFor(entry.command)) do
			Input.Unbind(key)
		end
		refresh()
	end)

	return refresh
end

local bindRefreshers = {}

if Input then
	section("Controls", "Movement")

	local shown = {}
	for _, entry in ipairs(Input.GetBindingList()) do
		-- Sectioned by the order numbers the command table already carries,
		-- rather than by a second list here that would drift from it.
		if entry.order == 10 then section("Controls", "Combat") end
		if entry.order == 13 then section("Controls", "Weapons") end
		if entry.order == 16 then section("Controls", "Interface") end

		table.insert(bindRefreshers, bindRow(entry))
		shown[entry.command] = true
	end

	-- Anything rebound from the console lands here too.
	Input.BindingChanged.Event:Connect(function()
		for _, refresh in ipairs(bindRefreshers) do refresh() end
	end)
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

cvarToggle("Video", "cl_crosshair", "Crosshair")
cvarToggle("Video", "cl_dynamiccrosshair", "Opens while moving")
cvarSlider("Video", "cl_crosshairsize", "Size", nil, 0, 20, 1,
	function(v) return string.format("%d", v) end)
cvarSlider("Video", "cl_crosshairgap", "Gap", nil, 0, 20, 1,
	function(v) return string.format("%d", v) end)
cvarSlider("Video", "cl_crosshairthickness", "Thickness", nil, 1, 8, 1,
	function(v) return string.format("%d", v) end)
cvarSlider("Video", "cl_crosshairalpha", "Opacity", nil, 0, 1, 0.05, two)
cvarToggle("Video", "cl_crosshairdot", "Centre dot")
cvarToggle("Video", "cl_crosshair_drawoutline", "Outline")

section("Video", "World")

cvarToggle("Video", "cl_tracers", "Bullet tracers")

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

local function hide()
	if not open then return end
	open = false
	closePanel()
end

local done = Kit.Button(footerButtons, "Done", "primary", function() hide() end)
done.Size = UDim2.new(0, 100, 0, 34)
done.LayoutOrder = 2

--=====================================================================
-- OPEN / CLOSE
--=====================================================================

scrim.Activated:Connect(hide)

button.Activated:Connect(function()
	if open then return end
	open = true
	openPanel()

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
