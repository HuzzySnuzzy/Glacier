-- ModuleScript: Input
-- Source-style binding: a key maps to a COMMAND STRING, not to a named action.
-- `bind mwheeldown +duck` is the same mechanism as `bind x noclip`.
--
-- BUTTON COMMANDS carry a + prefix and come in pairs: +jump presses, -jump
-- releases. A button is held while ANY source holds it -- keyboard, wheel, or
-- the console -- so binding two keys to +duck, or holding C while the wheel
-- pulses, behaves the way you'd expect instead of the last release winning.
--
-- TWO DISPATCH PATHS, split by whether the command is one of ours:
--   known commands  -> InputAction/InputBinding. The sinking InputContext is
--                      what stops Roblox's own controller eating WASD.
--   everything else -> raw InputBegan into Config.Exec.
-- A key bound to an arbitrary command gets no InputBinding, so nothing can
-- fire down both paths.
--
-- Input only translates hardware into intent. Anything timed or stateful
-- belongs in Physics or Weapons.

local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
local State  = require(script.Parent.State)

local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera

local MODAL_GUIS = { "Console", "menu" }

local Input = {}

-- Set by the console module so bound commands can answer into it. Without
-- this, output from a bind lands in the log rather than the console.
Input.Reply = nil

-- Same idea, for the other direction. Set by the console to its own dispatcher
-- so a bound line takes the same local/remote split a typed line does. Without
-- it, execLine below resolves in this VM only, and `bind f "give ak47"` dies as
-- an unknown command because give is registered on the SERVER -- the console
-- would have forwarded it.
Input.Exec = nil

local MOUSE_TYPE_TO_KEYCODE = {
	[Enum.UserInputType.MouseButton1] = Enum.KeyCode.MouseLeftButton,
	[Enum.UserInputType.MouseButton2] = Enum.KeyCode.MouseRightButton,
	[Enum.UserInputType.MouseButton3] = Enum.KeyCode.MouseMiddleButton,
}

--=====================================================================
-- KEY NAMES
--=====================================================================
-- Source key names, so muscle memory and pasted configs work. Built from the
-- enum so every key is nameable, then overlaid with the short aliases.

local NAME_TO_KEY = {}   -- "mouse1" -> Enum.KeyCode
local KEY_TO_NAME = {}   -- Enum.KeyCode -> "mouse1"  (preferred spelling)

-- Wheel directions are not KeyCodes -- the engine reports the wheel as
-- UserInputType.MouseWheel with the direction in Position.Z -- so they live
-- alongside as pseudo-keys and are dispatched by the scroll layer.
local SCROLL_KEYS = { mwheelup = "Up", mwheeldown = "Down" }

-- Written as enum NAMES rather than values: not every KeyCode below exists on
-- every engine version, and indexing a missing one would error at require.
local ALIASES = {
	mouse1 = "MouseLeftButton", mouse2 = "MouseRightButton",
	mouse3 = "MouseMiddleButton", mouse4 = "MouseX1", mouse5 = "MouseX2",

	ctrl = "LeftControl", lctrl = "LeftControl", rctrl = "RightControl",
	shift = "LeftShift", lshift = "LeftShift", rshift = "RightShift",
	alt = "LeftAlt", lalt = "LeftAlt", ralt = "RightAlt",

	enter = "Return", escape = "Escape", space = "Space",
	backspace = "Backspace", tab = "Tab", capslock = "CapsLock",

	uparrow = "Up", downarrow = "Down", leftarrow = "Left", rightarrow = "Right",
	ins = "Insert", del = "Delete", pgup = "PageUp", pgdn = "PageDown",
	home = "Home", ["end"] = "End",

	semicolon = "Semicolon", comma = "Comma", period = "Period",
	slash = "Slash", backslash = "BackSlash", minus = "Minus", equal = "Equals",
	["["] = "LeftBracket", ["]"] = "RightBracket", ["'"] = "Quote",
	["`"] = "Backquote",

	["0"] = "Zero", ["1"] = "One", ["2"] = "Two", ["3"] = "Three",
	["4"] = "Four", ["5"] = "Five", ["6"] = "Six", ["7"] = "Seven",
	["8"] = "Eight", ["9"] = "Nine",
}

-- Which alias wins when several point at one key, and therefore what
-- bindlist and a settings menu display.
local PREFERRED = {
	MouseLeftButton = "mouse1", MouseRightButton = "mouse2",
	MouseMiddleButton = "mouse3", MouseX1 = "mouse4", MouseX2 = "mouse5",
	LeftControl = "ctrl", LeftShift = "shift", LeftAlt = "alt",
	RightControl = "rctrl", RightShift = "rshift", RightAlt = "ralt",
	Return = "enter", Up = "uparrow", Down = "downarrow",
	Left = "leftarrow", Right = "rightarrow",
	Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
	Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
}

do
	for _, item in ipairs(Enum.KeyCode:GetEnumItems()) do
		if item ~= Enum.KeyCode.Unknown then
			local lower = item.Name:lower()
			NAME_TO_KEY[lower] = item
			KEY_TO_NAME[item] = PREFERRED[item.Name] or lower
		end
	end

	for alias, enumName in pairs(ALIASES) do
		local ok, kc = pcall(function() return Enum.KeyCode[enumName] end)
		if ok and kc then NAME_TO_KEY[alias] = kc end
	end
end

-- Returns the canonical name, or nil if this isn't a bindable key.
local function normalizeKey(name)
	if type(name) ~= "string" then return nil end
	local lower = name:lower()
	if SCROLL_KEYS[lower] then return lower end
	local kc = NAME_TO_KEY[lower]
	return kc and KEY_TO_NAME[kc] or nil
end

local function keyNameFor(keyCode)
	return KEY_TO_NAME[keyCode]
end

Input.NormalizeKey = normalizeKey

--=====================================================================
-- COMMAND DEFINITIONS
--=====================================================================

-- button = true : a +/- pair. Held state, released when every source lets go.
-- button = false: fires once on press. No - variant.
--
-- Names follow Source/CS where the semantics match, so a pasted cfg lands
-- on the right thing.
local COMMANDS = {
	["+forward"]   = { order = 1,  label = "Move Forward", button = true },
	["+back"]      = { order = 2,  label = "Move Back",    button = true },
	["+moveleft"]  = { order = 3,  label = "Move Left",    button = true },
	["+moveright"] = { order = 4,  label = "Move Right",   button = true },

	["+jump"]  = { order = 5, label = "Jump",  button = true },
	-- keepOnModal: releasing these on modal enter would flip them in toggle
	-- mode, so the source set is dropped without running the release handler.
	["+duck"]  = { order = 6, label = "Duck",  button = true, keepOnModal = true },
	["+speed"] = { order = 7, label = "Walk",  button = true, keepOnModal = true },

	["prone"] = { order = 8, label = "Prone", button = false },
	["dive"]  = { order = 9, label = "Dive",  button = false },

	["+attack"]  = { order = 10, label = "Fire",      button = true },
	["+attack2"] = { order = 11, label = "Alt Fire",  button = true },
	["+reload"]  = { order = 12, label = "Reload",    button = true },

	["slot1"] = { order = 13, label = "Primary",   button = false },
	["slot2"] = { order = 14, label = "Secondary", button = false },
	["slot3"] = { order = 15, label = "Melee",     button = false },

	["thirdperson"] = { order = 16, label = "Third Person", button = false },
	-- Must survive modal or the console can be opened and never closed.
	["toggleconsole"] = { order = 17, label = "Console", button = false, modalPassthrough = true },
	["+lookatweapon"] = { order = 18, label = "Inspect", button = true },
}

-- Ordered so bind_defaults and a fresh config write out predictably.
local DEFAULT_BINDS = {
	{ "w", "+forward" }, { "s", "+back" }, { "a", "+moveleft" }, { "d", "+moveright" },
	{ "space", "+jump" }, { "c", "+duck" }, { "shift", "+speed" },
	{ "x", "prone" }, { "ctrl", "dive" },
	{ "mouse1", "+attack" }, { "mouse2", "+attack2" }, { "r", "+reload" },
	{ "1", "slot1" }, { "2", "slot2" }, { "3", "slot3" },
	{ "v", "thirdperson" }, { "f3", "toggleconsole" }, { "f", "+lookatweapon" },
}

local GAMEPAD_DEFAULTS = {
	{ "buttona", "+jump" }, { "buttonb", "+duck" }, { "buttonl3", "+speed" },
	{ "buttonr2", "+attack" }, { "buttonl2", "+attack2" }, { "buttonx", "+reload" },
}

--=====================================================================
-- INTERNAL
--=====================================================================

local context
local actions = {}         -- [command] = InputAction
local actionBindings = {}  -- [command] = { InputBinding, ... }
local binds = {}           -- [keyName] = commandString   (authoritative)

local buttonSources = {}   -- [command] = { [source] = true }
local buttonDown = {}      -- [command] = bool
local scrollPulse = {}     -- [command] = gameTime expiry

local conns = {}
local modalCount = 0
local modalActive = false

Input.BindingChanged = Instance.new("BindableEvent")
Input.ActionPressed = Instance.new("BindableEvent")

local function isDown(name)
	return buttonDown[name] == true
end

Input.IsDown = isDown

local function replyTo(msg)
	if type(Input.Reply) == "function" then
		Input.Reply(msg)
	else
		warn("[Input] " .. msg)
	end
end

--=====================================================================
-- STATE APPLICATION
--=====================================================================

local function applyPressInner(name)
	if name == "+jump" then
		State.spaceHeld = true
		State.jumpBufferTimer = Config.mv_jumpBuffer or 0

	elseif name == "+duck" then
		if State.isDiving then return end
		State.cIsHeld = true
		State.wantsStand = false
		-- Virtual clock, not os.clock(): every other gameplay timestamp in
		-- the project is gameTime, and mixing the two makes a host_timescale
		-- session impossible to reason about.
		State.cPressTime = State.gameTime or 0
		if Config.mv_crouchHold then
			State.isCrouching = true
			State.isProne = false
		end

	elseif name == "+speed" then
		if not Config.mv_canWalk then return end
		if Config.mv_walkKeyToggle then
			State.isWalking = not State.isWalking
		else
			State.isWalking = true
		end

	elseif name == "prone" then
		if not Config.mv_canProne then return end
		State.isProne = not State.isProne
		if State.isProne then State.isCrouching = false end

	elseif name == "dive" then
		if not Config.mv_canDive then return end
		if State.isDiving or not State.isGrounded then return end
		State.isDiving = true
		local dir = State.wishDir
		if dir.Magnitude < 0.1 then
			dir = CFrame.Angles(0, math.rad(State.cameraX or 0), 0).LookVector
		end
		-- The one place Input writes velocity, which the header above says it
		-- shouldn't. Left as-is to avoid changing dive behaviour in a binding
		-- rewrite; it belongs in Physics behind a State.diveRequested flag.
		State.velocity = (dir * Config.mv_diveForceForward)
			+ Vector3.new(0, Config.mv_diveForceUp, 0)

	elseif name == "+attack" then
		State.triggerDown = true
	elseif name == "+attack2" then
		State.trigger2Down = true
	elseif name == "+reload" then
		State.reloadRequested = true

	elseif name == "slot1" then State.activeSlot = 1
	elseif name == "slot2" then State.activeSlot = 2
	elseif name == "slot3" then State.activeSlot = 3

	elseif name == "thirdperson" then
		State.isThirdPerson = not State.isThirdPerson
	elseif name == "+lookatweapon" then
		-- One-shot today. The held state is tracked regardless, so
		-- hold-to-inspect only needs Weapons to read Input.IsDown.
		State.inspectRequested = true
	end
end

-- Wrapped rather than firing inside the body because several branches return
-- early (duck while diving, walk with mv_canWalk off) and listeners still
-- need to see the press -- a UI toggle shouldn't be conditional on a movement
-- cvar.
local function applyPress(name)
	applyPressInner(name)
	Input.ActionPressed:Fire(name)
end

local function applyRelease(name)
	if name == "+jump" then
		State.spaceHeld = false

	elseif name == "+duck" then
		State.cIsHeld = false
		if Config.mv_crouchHold then
			-- Physics owns standing up: it must check headroom, and keep
			-- trying if there isn't any.
			State.wantsStand = true
		else
			State.isCrouching = not State.isCrouching
			if State.isCrouching then State.isProne = false end
		end

	elseif name == "+speed" then
		if not Config.mv_walkKeyToggle then
			State.isWalking = false
		end

	elseif name == "+attack" then
		State.triggerDown = false
	elseif name == "+attack2" then
		State.trigger2Down = false
	end
end

--=====================================================================
-- BUTTON HOLD COUNTING
--=====================================================================

-- Source's kbutton, generalised past its two key slots. Sources are "action"
-- (any InputBinding on the InputAction), "scroll:Up"/"scroll:Down", and
-- "console". The button is down while any of them holds it, which is what
-- makes two keys on +duck -- or a wheel pulse overlapping a held C -- behave
-- correctly instead of the first release winning.
local function buttonPress(cmd, source)
	local set = buttonSources[cmd]
	if not set then set = {} buttonSources[cmd] = set end
	if set[source] then return end

	local wasEmpty = next(set) == nil
	set[source] = true
	if wasEmpty then
		buttonDown[cmd] = true
		applyPress(cmd)
	end
end

local function buttonRelease(cmd, source, silent)
	local set = buttonSources[cmd]
	if not (set and set[source]) then return end

	set[source] = nil
	if next(set) == nil then
		buttonDown[cmd] = false
		if not silent then applyRelease(cmd) end
	end
end

--=====================================================================
-- COMMAND DISPATCH
--=====================================================================

local function execLine(line)
	-- Semicolons separate commands inside one bind, as in Source. Config.Exec
	-- has no notion of them, so the split happens here.
	for chunk in string.gmatch(line, "[^;]+") do
		local trimmed = chunk:match("^%s*(.-)%s*$")
		if trimmed ~= "" then
			if type(Input.Exec) == "function" then
				Input.Exec(trimmed)
			else
				Config.Exec(trimmed, { source = "bind", reply = replyTo })
			end
		end
	end
end

-- A bound key going down. `source` identifies the holder for button counting.
local function dispatchDown(cmd, source)
	local def = COMMANDS[cmd]
	if def then
		if def.button then
			buttonPress(cmd, source)
		else
			applyPress(cmd)
		end
		return
	end
	execLine(cmd)
end

local function dispatchUp(cmd, source)
	local def = COMMANDS[cmd]
	if def then
		if def.button then buttonRelease(cmd, source) end
		return
	end
	-- An arbitrary +command bound to a key still gets its - counterpart, so
	-- console commands written as a pair work without being declared here.
	local minus = cmd:match("^%+(.+)$")
	if minus then execLine("-" .. minus) end
end

--=====================================================================
-- BINDING
--=====================================================================

local function clearActionBindings(cmd)
	local list = actionBindings[cmd]
	if not list then return end
	for _, b in ipairs(list) do
		if b.Parent then b:Destroy() end
	end
	table.clear(list)
end

-- InputBindings are derived state, rebuilt wholesale from the bind table.
-- Binds change only when someone types `bind`, so the churn is irrelevant and
-- a single source of truth is worth far more than incremental updates.
local function syncActionBindings()
	if not context then return end

	for cmd in pairs(actions) do
		clearActionBindings(cmd)
	end

	for keyName, cmd in pairs(binds) do
		local action = actions[cmd]
		local kc = NAME_TO_KEY[keyName]
		if action and kc then
			local b = Instance.new("InputBinding")
			b.Name = keyName
			b.KeyCode = kc
			b.Parent = action

			local list = actionBindings[cmd]
			if not list then list = {} actionBindings[cmd] = list end
			table.insert(list, b)
		end
	end
end

-- command = nil unbinds. Returns ok, reason.
function Input.Bind(key, command)
	local keyName = normalizeKey(key)
	if not keyName then
		return false, ("unknown key '%s'"):format(tostring(key))
	end

	if command == nil or command == "" then
		return Input.Unbind(keyName)
	end

	command = command:match("^%s*(.-)%s*$")
	-- Exec's tokenizer has no quote handling, so a quoted command arrives with
	-- its quotes attached. Strip them rather than binding to a literal quote.
	command = command:match('^"(.*)"$') or command:match("^'(.*)'$") or command

	local previous = binds[keyName]
	binds[keyName] = command

	-- A key that moved off a button must release it, or the button stays
	-- latched forever with no key able to clear it.
	if previous and previous ~= command then
		local def = COMMANDS[previous]
		if def and def.button then
			buttonRelease(previous, "action")
			buttonRelease(previous, "scroll:" .. (SCROLL_KEYS[keyName] or ""))
		end
	end

	syncActionBindings()
	Input.BindingChanged:Fire(keyName, command)
	return true
end

function Input.Unbind(key)
	local keyName = normalizeKey(key)
	if not keyName then
		return false, ("unknown key '%s'"):format(tostring(key))
	end

	local previous = binds[keyName]
	binds[keyName] = nil

	if previous then
		local def = COMMANDS[previous]
		if def and def.button then
			buttonRelease(previous, "action")
			buttonRelease(previous, "scroll:" .. (SCROLL_KEYS[keyName] or ""))
		end
	end

	syncActionBindings()
	Input.BindingChanged:Fire(keyName, nil)
	return true
end

function Input.UnbindAll()
	for keyName in pairs(binds) do
		binds[keyName] = nil
		Input.BindingChanged:Fire(keyName, nil)
	end
	for cmd, set in pairs(buttonSources) do
		table.clear(set)
		buttonDown[cmd] = false
	end
	table.clear(scrollPulse)
	syncActionBindings()
end

function Input.BindDefaults()
	for _, pair in ipairs(DEFAULT_BINDS) do
		Input.Bind(pair[1], pair[2])
	end
	for _, pair in ipairs(GAMEPAD_DEFAULTS) do
		Input.Bind(pair[1], pair[2])
	end
	-- Ground strafing needs duck on the wheel; this is the cvar's whole
	-- meaning, now expressed as an ordinary pair of binds.
	if Config.cl_defaultScrollCrouch then
		Input.Bind("mwheelup", "+duck")
		Input.Bind("mwheeldown", "+duck")
	end
end

function Input.GetBind(key)
	local keyName = normalizeKey(key)
	return keyName and binds[keyName] or nil
end

-- Every key bound to a command. A command can have several -- that is the
-- point of a bind table -- so this returns a list, not a single key.
function Input.GetKeysFor(command)
	local out = {}
	for keyName, cmd in pairs(binds) do
		if cmd == command then table.insert(out, keyName) end
	end
	table.sort(out)
	return out
end

-- For a settings menu. Only known commands appear; arbitrary binds are listed
-- by `bindlist` instead.
function Input.GetBindingList()
	local out = {}
	for cmd, def in pairs(COMMANDS) do
		table.insert(out, {
			command = cmd,
			label = def.label,
			order = def.order,
			button = def.button or false,
			keys = Input.GetKeysFor(cmd),
		})
	end
	table.sort(out, function(a, b) return a.order < b.order end)
	return out
end

function Input.SaveBindings()
	return table.clone(binds)
end

function Input.LoadBindings(data)
	if type(data) ~= "table" then return end
	Input.UnbindAll()
	for keyName, cmd in pairs(data) do
		if type(cmd) == "string" then Input.Bind(keyName, cmd) end
	end
end

-- Bind syntax, so the output pastes straight back into the console or a cfg.
function Input.WriteBinds()
	local keys = {}
	for keyName in pairs(binds) do table.insert(keys, keyName) end
	table.sort(keys)

	local lines = {}
	for _, keyName in ipairs(keys) do
		table.insert(lines, ('bind %s "%s"'):format(keyName, binds[keyName]))
	end
	return lines
end

--=====================================================================
-- BUILD
--=====================================================================

local function buildContext()
	context = Instance.new("InputContext")
	context.Name = "GlacierGameplay"
	-- High priority with Sink so our bindings consume input before the default
	-- PlayerScripts contexts see it -- otherwise Roblox's own character
	-- controller competes for the movement keys.
	context.Priority = 2000
	context.Sink = true
	context.Parent = plr

	for cmd, def in pairs(COMMANDS) do
		local action = Instance.new("InputAction")
		action.Name = cmd
		action.Type = Enum.InputActionType.Bool
		action.Parent = context

		actions[cmd] = action
		actionBindings[cmd] = {}

		action.Pressed:Connect(function()
			if modalActive then return end
			if def.button then
				-- One source for every InputBinding on this action: the action
				-- already collapses multiple keys into one Pressed/Released
				-- pair, so counting them individually would double-count.
				buttonPress(cmd, "action")
			else
				applyPress(cmd)
			end
		end)

		action.Released:Connect(function()
			if def.button then buttonRelease(cmd, "action") end
		end)
	end
end

--=====================================================================
-- SCROLL LAYER
--=====================================================================

local function bindScroll()
	table.insert(conns, UserInputService.InputChanged:Connect(function(input, processed)
		if processed or modalActive then return end
		if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end

		local keyName = input.Position.Z > 0 and "mwheelup" or "mwheeldown"
		local cmd = binds[keyName]
		if not cmd then return end

		local def = COMMANDS[cmd]
		if def and def.button then
			-- The wheel has no held state, so an expiry timestamp stands in for
			-- one. This is how CS players bind duck to the wheel for ground
			-- strafing: each notch is a brief press.
			--
			-- GAME time, not os.clock(): the pulse has to span a consistent
			-- number of physics ticks, and under host_timescale 0.25 a wall
			-- clock pulse would cover a quarter as many.
			scrollPulse[cmd] = (State.gameTime or 0) + (Config.cl_scrollPulseTime or 0.14)
			buttonPress(cmd, "scroll:" .. SCROLL_KEYS[keyName])
		else
			dispatchDown(cmd, "scroll:" .. SCROLL_KEYS[keyName])
		end
	end))
end

-- Decays pulses. Called from UpdateWishDir, which runs once per physics frame.
local function tickScroll()
	local now = State.gameTime or 0
	for cmd, expiry in pairs(scrollPulse) do
		if now >= expiry then
			scrollPulse[cmd] = nil
			buttonRelease(cmd, "scroll:Up")
			buttonRelease(cmd, "scroll:Down")
		end
	end
end

--=====================================================================
-- RAW DISPATCH  (arbitrary bound commands)
--=====================================================================

-- Returns the KeyCode this input represents, or nil if it isn't a discrete
-- press. Filtering on UserInputType rather than testing the KeyCode against
-- Unknown: Unknown is deprecated, and the type is the authoritative answer to
-- "is there a bindable key here" anyway.
local function keyCodeFor(input)
	local t = input.UserInputType
	if t == Enum.UserInputType.Keyboard or t == Enum.UserInputType.Gamepad1 then
		return input.KeyCode
	end
	return MOUSE_TYPE_TO_KEYCODE[t]
end

-- Only for commands with no InputAction. Those DO have one and are dispatched
-- by the context, so handling them here as well would fire everything twice.
local function bindRawDispatch()
	table.insert(conns, UserInputService.InputBegan:Connect(function(input)
		if modalActive then return end
		local kc = keyCodeFor(input)
		if not kc then return end

		local cmd = binds[keyNameFor(kc)]
		if not cmd or COMMANDS[cmd] then return end
		dispatchDown(cmd, "action")
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input)
		local kc = keyCodeFor(input)
		if not kc then return end

		local cmd = binds[keyNameFor(kc)]
		if not cmd or COMMANDS[cmd] then return end
		dispatchUp(cmd, "action")
	end))
end

--=====================================================================
-- MODAL PASSTHROUGH
--=====================================================================

-- Commands flagged modalPassthrough have to keep working while input is
-- suppressed, or the console can be opened and never closed: Refresh disables
-- the InputContext, and a disabled context delivers no Pressed events.
--
-- gameProcessed is deliberately ignored. The console focuses a TextBox, which
-- marks every subsequent keypress as processed; honouring it would make the
-- close key dead exactly when it's needed.
local function bindModalPassthrough()
	table.insert(conns, UserInputService.InputBegan:Connect(function(input)
		if not modalActive then return end

		local kc = keyCodeFor(input)
		if not kc then return end

		local cmd = binds[keyNameFor(kc)]
		local def = cmd and COMMANDS[cmd]
		if def and def.modalPassthrough then
			-- Press only. A held command here would need release tracking the
			-- disabled context can't provide.
			applyPress(cmd)
		end
	end))
end

--=====================================================================
-- CAPTURE (for a "press an input" rebind prompt)
--=====================================================================

-- Disables gameplay input, waits for one input, restores.
-- Returns a canonical key name ("mouse1", "mwheeldown", "w"), or nil if the
-- player pressed Escape or it timed out.
function Input.CaptureNextInput(timeout)
	local release = Input.PushModal()

	local result, done = nil, false
	local local_conns = {}

	table.insert(local_conns, UserInputService.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.Keyboard and input.KeyCode == Enum.KeyCode.Escape then
			done = true
			return
		end
		local kc = keyCodeFor(input)
		if kc then
			result = keyNameFor(kc)
			done = true
		end
	end))

	table.insert(local_conns, UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
		result = input.Position.Z > 0 and "mwheelup" or "mwheeldown"
		done = true
	end))

	-- Real clock: this is a UI timeout, not gameplay timing.
	local start = os.clock()
	while not done and (not timeout or os.clock() - start < timeout) do
		task.wait()
	end

	for _, c in ipairs(local_conns) do c:Disconnect() end
	release()
	return result
end

--=====================================================================
-- MODAL
--=====================================================================

-- Modal state has three independent sources, OR'd together:
--   1. MODAL_GUIS -- polled once per frame
--   2. PushModal/PopModal or SetModal -- for anything without a GUI to watch
--   3. A focused TextBox
local modalOwners = {}
local playerGui
local guiCache = {}
local nextGuiScan = 0
local initClock = 0
local guiWarned = {}

local function resolveGui(name)
	local cached = guiCache[name]
	if cached and cached.Parent and cached:IsDescendantOf(playerGui) then
		return cached
	end
	guiCache[name] = nil
	return nil
end

-- A recursive FindFirstChild per missing name per frame is wasteful when the
-- list contains GUIs that don't exist yet (or at all), so misses are rescanned
-- on a timer instead. A quarter second is far below the time it takes anyone
-- to notice a cursor.
local function scanForMissingGuis()
	if not playerGui then return end
	local now = os.clock()
	if now < nextGuiScan then return end
	nextGuiScan = now + 0.25

	for _, name in ipairs(MODAL_GUIS) do
		if not guiCache[name] then
			local found = playerGui:FindFirstChild(name, true)
			if found then
				guiCache[name] = found
				guiWarned[name] = nil
			elseif not guiWarned[name] and os.clock() - initClock > 5 then
				-- Five seconds of grace: GUIs are cloned into PlayerGui by other
				-- scripts on their own schedule, so a miss during the first
				-- moments after Init is expected and not worth a warning.
				guiWarned[name] = true
				warn(("[Input] MODAL_GUIS entry %q still not found under PlayerGui " ..
					"after 5s -- run Input.DumpGuis() with it open"):format(name))
			end
		end
	end
end

local function anyModalGuiOpen()
	if not playerGui then return false end
	scanForMissingGuis()

	for _, name in ipairs(MODAL_GUIS) do
		local gui = resolveGui(name)
		if gui then
			-- ScreenGui and friends use Enabled; Frames and other GuiObjects use
			-- Visible. Anything that is neither is a name collision -- a Folder or
			-- a layout object caught by the recursive search -- and defaulting it
			-- to "open" would pin the cursor free forever with no visible cause.
			if gui:IsA("LayerCollector") then
				if gui.Enabled then return true end
			elseif gui:IsA("GuiObject") then
				if gui.Visible then return true end
			else
				warn(("[Input] MODAL_GUIS entry %q resolved to a %s, which has no " ..
					"Enabled or Visible property -- ignoring"):format(name, gui.ClassName))
				guiCache[name] = nil
			end
		end
	end
	return false
end

function Input.PushModal()
	modalCount += 1
	Input.Refresh()

	-- Returned so a caller can do `local release = Input.PushModal()` and call
	-- release() from a single cleanup path. Calling it twice is a no-op, so a
	-- double-close can't underflow the count.
	local released = false
	return function()
		if released then return end
		released = true
		Input.PopModal()
	end
end

function Input.PopModal()
	modalCount = math.max(modalCount - 1, 0)
	Input.Refresh()
end

-- owner: any unique key (a string, or the instance itself). Idempotent, so
-- calling it with the same value twice can't skew the count.
function Input.SetModal(owner, active)
	if active then
		if modalOwners[owner] then return end
		modalOwners[owner] = true
		Input.PushModal()
	else
		if not modalOwners[owner] then return end
		modalOwners[owner] = nil
		Input.PopModal()
	end
end

function Input.IsModal()
	return modalActive
end

-- A held button can't deliver its release once the context is disabled, so
-- every hardware source is dropped by hand. The console source is left alone:
-- a +jump typed into the console is meant to latch until -jump.
local function releaseHardwareButtons()
	for cmd, def in pairs(COMMANDS) do
		if def.button then
			local silent = def.keepOnModal or false
			buttonRelease(cmd, "action", silent)
			buttonRelease(cmd, "scroll:Up", silent)
			buttonRelease(cmd, "scroll:Down", silent)
		end
	end
	table.clear(scrollPulse)
end

-- Recomputes modal state and applies it. Safe and cheap to call every frame;
-- everything below writes only on an actual change.
function Input.Refresh()
	-- Each source is evaluated into its own local rather than chained with `or`.
	-- Short-circuiting would skip anyModalGuiOpen(), which is what drives the
	-- GUI rescan -- so a focused TextBox or any Push/SetModal would freeze the
	-- cache and the names would never resolve after a startup miss.
	local textFocused = UserInputService:GetFocusedTextBox() ~= nil
	local guiOpen = anyModalGuiOpen()
	local active = modalCount > 0 or textFocused or guiOpen

	if active ~= modalActive then
		modalActive = active
		if context then context.Enabled = not active end
		if active then releaseHardwareButtons() end
	end

	-- Compared against the live properties rather than a cached copy on purpose:
	-- the engine resets MouseBehavior to Default on window focus loss or when a
	-- Modal GuiButton appears, and a cache would never see it.
	local behavior = active and Enum.MouseBehavior.Default or Enum.MouseBehavior.LockCenter
	if UserInputService.MouseBehavior ~= behavior then
		UserInputService.MouseBehavior = behavior
	end
	if UserInputService.MouseIconEnabled ~= active then
		UserInputService.MouseIconEnabled = active
	end
end

Input.UpdateMouse = Input.Refresh

function Input.DebugModal()
	local out = {
		"=== Input modal state ===",
		("  modalActive   : %s"):format(tostring(modalActive)),
		("  modalCount    : %d"):format(modalCount),
		("  textFocused   : %s"):format(tostring(UserInputService:GetFocusedTextBox() ~= nil)),
		("  contextEnabled: %s"):format(context and tostring(context.Enabled) or "<no context>"),
		("  playerGui     : %s"):format(playerGui and playerGui:GetFullName() or "<nil -- Init not run>"),
	}

	local owners = {}
	for owner in pairs(modalOwners) do table.insert(owners, tostring(owner)) end
	table.insert(out, ("  setModal      : %s"):format(#owners > 0 and table.concat(owners, ", ") or "<none>"))

	table.insert(out, "  MODAL_GUIS:")
	for _, name in ipairs(MODAL_GUIS) do
		local gui = playerGui and playerGui:FindFirstChild(name, true)
		if not gui then
			table.insert(out, ("    %-16s NOT FOUND"):format(name))
		elseif gui:IsA("LayerCollector") then
			table.insert(out, ("    %-16s %s  Enabled=%s"):format(name, gui.ClassName, tostring(gui.Enabled)))
		elseif gui:IsA("GuiObject") then
			table.insert(out, ("    %-16s %s  Visible=%s"):format(name, gui.ClassName, tostring(gui.Visible)))
		else
			table.insert(out, ("    %-16s %s  <no Enabled/Visible>"):format(name, gui.ClassName))
		end
	end

	table.insert(out, ("  MouseBehavior   : %s"):format(UserInputService.MouseBehavior.Name))
	table.insert(out, ("  MouseIconEnabled: %s"):format(tostring(UserInputService.MouseIconEnabled)))

	local held = {}
	for cmd, down in pairs(buttonDown) do
		if down then
			local srcs = {}
			for s in pairs(buttonSources[cmd] or {}) do table.insert(srcs, s) end
			table.insert(held, ("%s [%s]"):format(cmd, table.concat(srcs, ",")))
		end
	end
	table.insert(out, ("  held buttons    : %s"):format(#held > 0 and table.concat(held, ", ") or "<none>"))

	return table.concat(out, "\n")
end

--=====================================================================
-- WISH DIRECTION
--=====================================================================

function Input.UpdateWishDir()
	Input.Refresh()
	State.dbgWishCalls = (State.dbgWishCalls or 0) + 1
	tickScroll()

	-- Two freeze mechanisms exist: the per-player attribute and the mp_frozen
	-- cvar the gamemode replicates. Honour both -- checking only one meant a
	-- freezetime set through the other did nothing.
	local frozen = plr:GetAttribute("Frozen") or Config.mp_frozen

	if frozen or modalActive or State.isDiving then
		State.wishDir = Vector3.zero
		-- Was omitted on the frozen path, so a freezetime jump fed ABH the
		-- last held direction.
		State.forwardMoveAxis = 0
		return
	end

	local fwd, side = 0, 0
	if isDown("+forward")   then fwd += 1 end
	if isDown("+back")      then fwd -= 1 end
	if isDown("+moveright") then side += 1 end
	if isDown("+moveleft")  then side -= 1 end

	-- The signed forward axis survives separately: wishDir is normalised and
	-- rotated, so ABH can't recover the sign from it.
	State.forwardMoveAxis = fwd

	local inputVector = Vector3.new(side, 0, -fwd)
	if inputVector.Magnitude > 0 then
		local flatCam = CFrame.new(cam.CFrame.Position)
			* CFrame.Angles(0, math.rad(State.cameraX or 0), 0)
		State.wishDir = flatCam:VectorToWorldSpace(inputVector.Unit)
	else
		State.wishDir = Vector3.zero
	end
end

--=====================================================================
-- MOUSE LOOK
--=====================================================================

-- Mouse delta stays on UserInputService: the action system handles discrete
-- actions and axes, not raw relative motion.
local function bindMouseLook()
	table.insert(conns, UserInputService.InputChanged:Connect(function(input)
		if modalActive then return end
		if UserInputService:GetFocusedTextBox() then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end

		local sens = Config.cl_mouseSensitivity or 0.2
		State.cameraX = (State.cameraX or 0) - input.Delta.X * sens
		State.cameraY = math.clamp((State.cameraY or 0) - input.Delta.Y * sens, -89, 89)
	end))
end

--=====================================================================
-- INIT
--=====================================================================

function Input.Init()
	if context then return end
	playerGui = plr:WaitForChild("PlayerGui")
	initClock = os.clock()

	buildContext()
	bindScroll()
	bindMouseLook()
	bindRawDispatch()
	bindModalPassthrough()

	Input.BindDefaults()
	Input.Refresh()
end

function Input.Destroy()
	-- These were never stored, so Destroy left three UserInputService
	-- connections live: a Destroy/Init cycle doubled mouse sensitivity and
	-- fired every scroll bind twice.
	for _, c in ipairs(conns) do c:Disconnect() end
	table.clear(conns)

	if context then
		context:Destroy()
		context = nil
	end

	playerGui = nil
	nextGuiScan = 0
	initClock = 0
	table.clear(actions)
	table.clear(actionBindings)
	table.clear(buttonSources)
	table.clear(buttonDown)
	table.clear(scrollPulse)
	table.clear(guiCache)
	table.clear(guiWarned)
	modalActive = false
end

--=====================================================================
-- CONSOLE COMMANDS
--=====================================================================

Config.Command("bind", {
	args = { "string", "rest?" },
	help = "bind a key to a command, or show what it's bound to",
	run = function(ctx, key, command)
		local keyName = normalizeKey(key)
		if not keyName then
			return false, ("unknown key '%s'"):format(key)
		end

		if command == nil then
			local cur = binds[keyName]
			ctx.reply(cur and ('bind %s "%s"'):format(keyName, cur)
				or ("%s is not bound"):format(keyName))
			return
		end

		local ok, reason = Input.Bind(keyName, command)
		if not ok then return false, reason end
		ctx.reply(('bind %s "%s"'):format(keyName, binds[keyName]))
	end,
})

Config.Command("unbind", {
	args = { "string" },
	help = "clear a key's binding",
	run = function(ctx, key)
		local ok, reason = Input.Unbind(key)
		if not ok then return false, reason end
		ctx.reply(("unbound %s"):format(normalizeKey(key)))
	end,
})

Config.Command("unbindall", {
	args = {},
	help = "clear every binding",
	run = function(ctx)
		Input.UnbindAll()
		ctx.reply("all keys unbound -- run bind_defaults to restore")
	end,
})

Config.Command("bind_defaults", {
	args = {},
	help = "restore the default bindings",
	run = function(ctx)
		Input.BindDefaults()
		ctx.reply("default bindings restored")
	end,
})

Config.Command("bindlist", {
	args = {},
	help = "list every binding, in bind syntax",
	run = function(ctx)
		local lines = Input.WriteBinds()
		ctx.reply(#lines > 0 and table.concat(lines, "\n") or "nothing bound")
	end,
})

Config.Command("bind_commands", {
	args = {},
	help = "list the commands a key can be bound to",
	run = function(ctx)
		local list = Input.GetBindingList()
		local lines = {}
		for _, entry in ipairs(list) do
			table.insert(lines, ("%-16s %-14s %s")
				:format(entry.command, entry.label,
					#entry.keys > 0 and table.concat(entry.keys, ", ") or "-"))
		end
		ctx.reply(table.concat(lines, "\n"))
	end,
})

Config.Command("input_debug", {
	args = {},
	help = "dump modal state and held buttons",
	run = function(ctx)
		ctx.reply(Input.DebugModal())
	end,
})

-- The +/- pairs, registered so they work typed into the console and so
-- autocomplete lists them. Source latches a console-pressed button until its
-- - counterpart runs; that is faithful and useful for testing, so the console
-- source is deliberately not cleared on modal.
for cmd, def in pairs(COMMANDS) do
	if def.button then
		local base = cmd:sub(2)

		Config.Command(cmd, {
			args = {},
			help = ("hold %s"):format(def.label:lower()),
			run = function() buttonPress(cmd, "console") end,
		})

		Config.Command("-" .. base, {
			args = {},
			help = ("release %s"):format(def.label:lower()),
			run = function() buttonRelease(cmd, "console") end,
		})
	else
		Config.Command(cmd, {
			args = {},
			help = def.label,
			run = function() applyPress(cmd) end,
		})
	end
end

Config.Command("noclip", {
	flag = Config.FCVAR.CHEAT,
	help = "toggle collision-free movement",
	run = function(ctx)
		State.noclip = not State.noclip
		ctx.reply(State.noclip and "noclip ON" or "noclip OFF")
	end,
})

return Input