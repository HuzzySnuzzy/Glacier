-- ModuleScript: MenuKit
-- Parent: the `menu` ScreenGui  (a direct child of it -- see Locate below)
--
-- The look, the widgets and the motion shared by every screen hanging off the
-- main menu: the pause screen, the quit prompt, the settings panel.
--
-- WHY A MODULE AND NOT THREE COPIES. The settings panel alone needs a slider,
-- a toggle, a dropdown, a tab strip and a key-capture row; the quit prompt
-- needs the same buttons and the same open/close motion. Written twice they
-- would drift, and the one thing a menu cannot afford is two dialogs that
-- animate differently.
--
-- HOUSE STYLE. The palette is DevConsole's, shifted a little warmer and a lot
-- larger: a settings menu is read across the room, a console is read leaning
-- in. Everything else -- Code font, hairline strokes, no gradients on things
-- you press -- is deliberately the same, because this is one program.

local TweenService = game:GetService("TweenService")

local MenuKit = {}

--=====================================================================
-- PALETTE
--=====================================================================

MenuKit.C = {
	bg        = Color3.fromRGB(13, 14, 17),
	panel     = Color3.fromRGB(20, 22, 27),
	raised    = Color3.fromRGB(30, 33, 40),
	line      = Color3.fromRGB(52, 57, 66),
	lineSoft  = Color3.fromRGB(38, 42, 50),

	text      = Color3.fromRGB(226, 230, 238),
	dim       = Color3.fromRGB(132, 139, 152),
	faint     = Color3.fromRGB(88, 94, 105),

	accent    = Color3.fromRGB(90, 160, 255),
	accentDim = Color3.fromRGB(52, 96, 158),
	good      = Color3.fromRGB(130, 225, 150),
	warn      = Color3.fromRGB(255, 200, 90),
	danger    = Color3.fromRGB(255, 105, 105),
}

--=====================================================================
-- MOTION
--=====================================================================
-- One easing curve for everything that opens, one for everything that
-- responds to a pointer. Two curves is a house style; five is a mess.
--
-- Quint/Out for arrivals: it covers most of its distance immediately and
-- settles, which reads as fast even at a duration long enough to see. Quad/Out
-- for hovers, because a hover that takes as long as a panel opening feels
-- broken.

MenuKit.OPEN  = TweenInfo.new(0.28, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
MenuKit.CLOSE = TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
MenuKit.HOVER = TweenInfo.new(0.12, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)
MenuKit.SNAP  = TweenInfo.new(0.07, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out)

function MenuKit.Tween(inst, info, props)
	local t = TweenService:Create(inst, info, props)
	t:Play()
	return t
end

--=====================================================================
-- PRIMITIVES
--=====================================================================

function MenuKit.Corner(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = inst
	return c
end

function MenuKit.Stroke(inst, colour, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = colour or MenuKit.C.line
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = inst
	return s
end

function MenuKit.Pad(inst, all, left, right, bottom)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, all or 0)
	p.PaddingLeft = UDim.new(0, left or all or 0)
	p.PaddingRight = UDim.new(0, right or left or all or 0)
	p.PaddingBottom = UDim.new(0, bottom or all or 0)
	p.Parent = inst
	return p
end

-- Next in line under `parent`.
--
-- UIListLayout sorted by LayoutOrder falls back to NAME when the orders are
-- equal, and every row this kit builds is a Frame called "Frame" -- so leaving
-- them all at 0 scrambles a settings page into alphabetical order, which for
-- identically-named children is no order at all. Counting the existing
-- children gives a monotonic sequence for free; the layout objects among them
-- inflate the count and change nothing that matters.
function MenuKit.Order(parent, inst)
	inst.LayoutOrder = #parent:GetChildren()
	return inst
end

function MenuKit.List(parent, padding, direction)
	local l = Instance.new("UIListLayout")
	l.Padding = UDim.new(0, padding or 6)
	l.FillDirection = direction or Enum.FillDirection.Vertical
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.Parent = parent
	return l
end

function MenuKit.Label(parent, text, colour, size, bold)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextSize = size or 14
	l.TextColor3 = colour or MenuKit.C.text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.RichText = true
	l.Text = text or ""
	l.Parent = parent
	return l
end

--=====================================================================
-- BUTTON
--=====================================================================

-- kind: "normal" | "primary" | "danger". The colour says what pressing it
-- does; nothing else about the button changes, so a row of them still reads
-- as a row.
function MenuKit.Button(parent, text, kind, onClick)
	local C = MenuKit.C
	local accent = C.accent
	if kind == "danger" then accent = C.danger end

	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BackgroundColor3 = (kind == "primary") and accent or C.raised
	b.BackgroundTransparency = (kind == "primary") and 0.15 or 0.35
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 14
	b.TextColor3 = (kind == "primary") and Color3.fromRGB(8, 12, 20) or C.text
	b.Text = text
	b.Size = UDim2.new(1, 0, 0, 34)
	b.Parent = parent

	MenuKit.Corner(b, 6)
	local stroke = MenuKit.Stroke(b, C.line, 1, 0.4)

	-- Hover and press are on the STROKE and the fill, never on the size.
	-- A button that grows under the pointer moves the thing you are aiming at,
	-- which is the one place motion actively costs you.
	b.MouseEnter:Connect(function()
		MenuKit.Tween(b, MenuKit.HOVER, {
			BackgroundTransparency = (kind == "primary") and 0 or 0.12,
		})
		MenuKit.Tween(stroke, MenuKit.HOVER, { Transparency = 0, Color = accent })
	end)
	b.MouseLeave:Connect(function()
		MenuKit.Tween(b, MenuKit.HOVER, {
			BackgroundTransparency = (kind == "primary") and 0.15 or 0.35,
		})
		MenuKit.Tween(stroke, MenuKit.HOVER, { Transparency = 0.4, Color = C.line })
	end)
	b.MouseButton1Down:Connect(function()
		MenuKit.Tween(b, MenuKit.SNAP, { BackgroundTransparency = 0.45 })
	end)
	b.MouseButton1Up:Connect(function()
		MenuKit.Tween(b, MenuKit.SNAP, {
			BackgroundTransparency = (kind == "primary") and 0 or 0.12,
		})
	end)

	if onClick then b.Activated:Connect(onClick) end
	return b
end

--=====================================================================
-- ROW
--=====================================================================
-- A labelled setting: name on the left, control on the right, description
-- underneath when there is one. Every control below is built on it, so they
-- all line up without anyone measuring anything.

local ROW_HEIGHT = 34

function MenuKit.Row(parent, name, description)
	local C = MenuKit.C
	local tall = description ~= nil and description ~= ""

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, tall and 50 or ROW_HEIGHT)
	MenuKit.Order(parent, row)
	row.Parent = parent

	local title = MenuKit.Label(row, name, C.text, 14)
	title.Size = UDim2.new(0.5, -8, 0, tall and 20 or ROW_HEIGHT)
	title.Position = UDim2.new(0, 0, 0, 0)

	if tall then
		local sub = MenuKit.Label(row, description, C.faint, 11)
		sub.Size = UDim2.new(0.62, -8, 0, 16)
		sub.Position = UDim2.new(0, 0, 0, 19)
		sub.TextTruncate = Enum.TextTruncate.AtEnd
	end

	-- Where the control goes. Right-aligned and fixed width, because controls
	-- that size themselves to their content make a settings list look ragged.
	local slot = Instance.new("Frame")
	slot.BackgroundTransparency = 1
	slot.AnchorPoint = Vector2.new(1, 0)
	slot.Position = UDim2.new(1, 0, 0, tall and 8 or 0)
	slot.Size = UDim2.new(0, 210, 0, ROW_HEIGHT)
	slot.Parent = row

	return row, slot
end

--=====================================================================
-- TOGGLE
--=====================================================================

function MenuKit.Toggle(slot, initial, onChange)
	local C = MenuKit.C
	local state = initial and true or false

	local track = Instance.new("TextButton")
	track.AutoButtonColor = false
	track.Text = ""
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.new(1, 0, 0.5, 0)
	track.Size = UDim2.new(0, 46, 0, 24)
	track.BackgroundColor3 = state and C.accent or C.raised
	track.BorderSizePixel = 0
	track.Parent = slot
	MenuKit.Corner(track, 12)
	local stroke = MenuKit.Stroke(track, C.line, 1, 0.4)

	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0, 0.5)
	knob.Size = UDim2.new(0, 18, 0, 18)
	knob.Position = UDim2.new(0, state and 25 or 3, 0.5, 0)
	knob.BackgroundColor3 = state and Color3.fromRGB(10, 14, 22) or C.dim
	knob.BorderSizePixel = 0
	knob.Parent = track
	MenuKit.Corner(knob, 9)

	local function paint(animated)
		local info = animated and MenuKit.HOVER or TweenInfo.new(0)
		MenuKit.Tween(track, info, { BackgroundColor3 = state and C.accent or C.raised })
		MenuKit.Tween(knob, info, {
			Position = UDim2.new(0, state and 25 or 3, 0.5, 0),
			BackgroundColor3 = state and Color3.fromRGB(10, 14, 22) or C.dim,
		})
	end

	track.Activated:Connect(function()
		state = not state
		paint(true)
		if onChange then onChange(state) end
	end)

	track.MouseEnter:Connect(function()
		MenuKit.Tween(stroke, MenuKit.HOVER, { Transparency = 0 })
	end)
	track.MouseLeave:Connect(function()
		MenuKit.Tween(stroke, MenuKit.HOVER, { Transparency = 0.4 })
	end)

	-- Returned so an external change (a console `sensitivity 0.3`) can put the
	-- widget back in step without rebuilding the panel.
	return function(value)
		state = value and true or false
		paint(true)
	end
end

--=====================================================================
-- SLIDER
--=====================================================================

-- Dragged on the whole track rather than on the knob: a 12-pixel knob is a
-- fiddly target, and every slider anyone actually likes lets you click the
-- bar. `format` turns the value into the number shown beside it.
function MenuKit.Slider(slot, min, max, initial, step, format, onChange)
	local C = MenuKit.C
	local UserInputService = game:GetService("UserInputService")

	local value = math.clamp(initial or min, min, max)
	format = format or function(v) return string.format("%.2f", v) end

	local readout = MenuKit.Label(slot, format(value), C.warn, 13)
	readout.AnchorPoint = Vector2.new(1, 0.5)
	readout.Position = UDim2.new(1, 0, 0.5, 0)
	readout.Size = UDim2.new(0, 54, 1, 0)
	readout.TextXAlignment = Enum.TextXAlignment.Right
	readout.Font = Enum.Font.Code

	local track = Instance.new("TextButton")
	track.AutoButtonColor = false
	track.Text = ""
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.new(1, -62, 0.5, 0)
	track.Size = UDim2.new(1, -62, 0, 6)
	track.BackgroundColor3 = C.raised
	track.BorderSizePixel = 0
	track.Parent = slot
	MenuKit.Corner(track, 3)

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = C.accent
	fill.BorderSizePixel = 0
	fill.Size = UDim2.new((value - min) / (max - min), 0, 1, 0)
	fill.Parent = track
	MenuKit.Corner(fill, 3)

	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new((value - min) / (max - min), 0, 0.5, 0)
	knob.Size = UDim2.new(0, 14, 0, 14)
	knob.BackgroundColor3 = C.text
	knob.BorderSizePixel = 0
	knob.ZIndex = 2
	knob.Parent = track
	MenuKit.Corner(knob, 7)

	local function apply(v, animated, notify)
		if step and step > 0 then
			v = min + math.floor((v - min) / step + 0.5) * step
		end
		v = math.clamp(v, min, max)
		value = v

		local alpha = (max > min) and (v - min) / (max - min) or 0
		local info = animated and MenuKit.SNAP or TweenInfo.new(0)
		MenuKit.Tween(fill, info, { Size = UDim2.new(alpha, 0, 1, 0) })
		MenuKit.Tween(knob, info, { Position = UDim2.new(alpha, 0, 0.5, 0) })
		readout.Text = format(v)

		if notify and onChange then onChange(v) end
	end

	local dragging = false
	local moveConn, endConn

	local function sample(x)
		local left = track.AbsolutePosition.X
		local width = math.max(track.AbsoluteSize.X, 1)
		apply(min + (max - min) * math.clamp((x - left) / width, 0, 1), true, true)
	end

	local function stopDrag()
		if not dragging then return end
		dragging = false
		if moveConn then moveConn:Disconnect() moveConn = nil end
		if endConn then endConn:Disconnect() endConn = nil end
		MenuKit.Tween(knob, MenuKit.HOVER, { Size = UDim2.new(0, 14, 0, 14) })
	end

	-- The drag is tracked on UserInputService rather than on the track's own
	-- Move events, because a drag that leaves a 6-pixel-tall bar has to keep
	-- working and it always does leave it.
	--
	-- Connected on press and dropped on release, not held for the life of the
	-- slider: a settings page has twenty of these, and forty permanent
	-- listeners waking on every mouse move to immediately return is a cost
	-- paid whenever the game is running, menu open or not.
	track.MouseButton1Down:Connect(function(x)
		if dragging then return end
		dragging = true
		MenuKit.Tween(knob, MenuKit.HOVER, { Size = UDim2.new(0, 18, 0, 18) })
		sample(x)

		moveConn = UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseMovement
				and input.UserInputType ~= Enum.UserInputType.Touch then return end
			sample(input.Position.X)
		end)

		endConn = UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch then return end
			stopDrag()
		end)
	end)

	track.MouseEnter:Connect(function()
		MenuKit.Tween(knob, MenuKit.HOVER, { BackgroundColor3 = C.accent })
	end)
	track.MouseLeave:Connect(function()
		if not dragging then
			MenuKit.Tween(knob, MenuKit.HOVER, { BackgroundColor3 = C.text })
		end
	end)

	-- A slider whose panel is hidden mid-drag never sees the button come back
	-- up, so it would stay latched and jump the next time the mouse moved
	-- anywhere near it.
	track.AncestryChanged:Connect(function()
		if not track:IsDescendantOf(game) then stopDrag() end
	end)
	slot:GetPropertyChangedSignal("Visible"):Connect(function()
		if not slot.Visible then stopDrag() end
	end)

	return function(v) apply(v, true, false) end
end

--=====================================================================
-- CHOICE
--=====================================================================
-- A cycling button rather than a dropdown. Dropdowns need a layer above
-- everything, click-outside handling and scroll clipping; a settings menu
-- with three-option lists does not earn any of that.
function MenuKit.Choice(slot, options, initialIndex, onChange)
	local C = MenuKit.C
	local index = math.clamp(initialIndex or 1, 1, #options)

	local b = MenuKit.Button(slot, options[index].label, "normal", nil)
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, 0, 0.5, 0)
	b.Size = UDim2.new(0, 150, 0, 28)

	local function set(i, notify)
		index = ((i - 1) % #options) + 1
		b.Text = options[index].label
		if notify and onChange then onChange(options[index].value, index) end
	end

	b.Activated:Connect(function() set(index + 1, true) end)
	b.MouseButton2Click:Connect(function() set(index - 1, true) end)

	return function(value)
		for i, opt in ipairs(options) do
			if opt.value == value then set(i, false) return end
		end
	end
end

--=====================================================================
-- SECTION
--=====================================================================

function MenuKit.Section(parent, title)
	local C = MenuKit.C

	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 26)
	MenuKit.Order(parent, holder)
	holder.Parent = parent

	local l = MenuKit.Label(holder, string.upper(title), C.faint, 11, true)
	l.Size = UDim2.new(1, 0, 1, 0)
	l.Position = UDim2.new(0, 0, 0, 6)

	local rule = Instance.new("Frame")
	rule.BackgroundColor3 = C.lineSoft
	rule.BorderSizePixel = 0
	rule.AnchorPoint = Vector2.new(0, 1)
	rule.Position = UDim2.new(0, 0, 1, 0)
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.Parent = holder

	return holder
end

--=====================================================================
-- OVERLAY
--=====================================================================

-- A dimmed sheet with a panel on it, opening from slightly below and slightly
-- small. Returns the panel plus Open/Close, which are what the callers want.
--
-- The scrim is a real button so a click anywhere outside the panel is caught
-- rather than falling through to whatever is behind the menu.
function MenuKit.Overlay(parent, width, height)
	local C = MenuKit.C

	local scrim = Instance.new("TextButton")
	scrim.Text = ""
	scrim.AutoButtonColor = false
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 1
	scrim.BorderSizePixel = 0
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.Visible = false
	scrim.ZIndex = 10
	scrim.Parent = parent

	local panel = Instance.new("Frame")
	-- ACTIVE, or a click on the panel's own background falls through to the
	-- scrim and closes the dialog you were reaching into. A Frame does not
	-- consume input by default; this is the property that makes it.
	panel.Active = true
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(width, height)
	panel.BackgroundColor3 = C.panel
	panel.BorderSizePixel = 0
	panel.ZIndex = 11
	panel.Parent = scrim
	MenuKit.Corner(panel, 10)
	MenuKit.Stroke(panel, C.line, 1, 0.25)

	local closing = false

	local function Open()
		closing = false
		scrim.Visible = true
		scrim.BackgroundTransparency = 1
		panel.Size = UDim2.fromOffset(width, height)
		panel.Position = UDim2.new(0.5, 0, 0.5, 18)

		-- Scale rather than transparency, and only a little of it. Fading a
		-- Frame does not fade its children, so a transparency open leaves the
		-- text at full opacity over a ghost panel; scaling moves everything
		-- together for free. 0.96 because the point is to suggest the panel
		-- arriving, not to zoom it in from the middle distance.
		local group = panel:FindFirstChildOfClass("UIScale")
		if not group then
			group = Instance.new("UIScale")
			group.Parent = panel
		end
		group.Scale = 0.96

		MenuKit.Tween(scrim, MenuKit.OPEN, { BackgroundTransparency = 0.45 })
		MenuKit.Tween(panel, MenuKit.OPEN, { Position = UDim2.fromScale(0.5, 0.5) })
		MenuKit.Tween(group, MenuKit.OPEN, { Scale = 1 })
	end

	local function Close(onDone)
		if closing then return end
		closing = true

		local group = panel:FindFirstChildOfClass("UIScale")
		MenuKit.Tween(scrim, MenuKit.CLOSE, { BackgroundTransparency = 1 })
		MenuKit.Tween(panel, MenuKit.CLOSE, { Position = UDim2.new(0.5, 0, 0.5, 12) })
		if group then MenuKit.Tween(group, MenuKit.CLOSE, { Scale = 0.97 }) end

		task.delay(MenuKit.CLOSE.Time, function()
			-- Guarded: Open may have run again inside the close, and hiding it
			-- then would leave a panel that is open according to every caller
			-- and invisible according to the screen.
			if closing then scrim.Visible = false end
			if onDone then onDone() end
		end)
	end

	return panel, Open, Close, scrim
end

return MenuKit
