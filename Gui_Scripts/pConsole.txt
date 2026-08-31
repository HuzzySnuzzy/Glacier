-- LocalScript: Console
-- Parent: PlayerGui.Console  (a ScreenGui)
--
-- Visibility toggles ScreenGui.Enabled, not Frame.Visible. Input watches this
-- ScreenGui's Enabled property to decide whether to free the cursor and
-- suppress gameplay input, so a toggle it can't observe means an open console
-- with a locked cursor and the player still walking around behind it.
--
-- Autocomplete and dispatch across three sources:
--   Config.Values         cvars; set locally, or routed to the server if REPLICATED
--   Config.Commands       commands registered in THIS client's VM
--   Config.RemoteCommands server-owned commands, mirrored for autocomplete only
--
-- The registry rebuilds on change rather than snapshotting at load. Gamemodes
-- register commands long after this script runs and unregister them on switch,
-- so a one-time snapshot silently misses every one of them.
--
-- OUTPUT ROUTING: every Config.Exec call from here passes ctx.reply, and
-- Input.Reply is pointed at the same place. Without both, commands that answer
-- through ctx.reply land in the developer log instead of the console -- the
-- exact footgun ctx.reply exists to avoid.

local UserInputService  = game:GetService("UserInputService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LogService        = game:GetService("LogService")

local Config       = require(ReplicatedStorage:WaitForChild("Config"))
local ConsoleEvent = ReplicatedStorage:WaitForChild("ConsoleEvent")
local ConsoleLog   = ReplicatedStorage:WaitForChild("ConsoleLog")
local ConsoleBroadcast = ReplicatedStorage:WaitForChild("ConsoleBroadcast", 10)

local BROADCAST_PREFIX = "!"
local plr = Players.LocalPlayer

--=====================================================================
-- MODULE RESOLUTION
--=====================================================================

-- The hardcoded PlayerGui path was wrong and carried an "ADJUST THIS" note.
-- Searched instead, because getting the WRONG instance is worse than getting
-- none: ModuleScripts are cached per instance, so requiring a different copy
-- of Input yields a different BindableEvent and the toggle silently never
-- fires. Candidates are ordered most to least likely.
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
	-- Deliberately not a WaitForChild loop: if the folder isn't there by now
	-- the path is wrong, and hanging forever hides that.
	error("[Console] could not find the Player module folder. Add its parent " ..
		"to findClientModules() -- it must be the SAME instance the client " ..
		"controller requires, or Input's events won't match.", 0)
end

local Input = require(ClientModules:WaitForChild("Input"))
local State = require(ClientModules:WaitForChild("State"))

local function hasFlag(flag, want)
	return bit32.band(flag or Config.FCVAR.CLIENT, want) ~= 0
end

-- Timeout rather than an indefinite wait: if ConsoleManifestServer isn't in
-- yet, the console should still work for local cvars instead of never loading.
local Manifest = ReplicatedStorage:WaitForChild("ConsoleManifest", 10)

--=====================================================================
-- REGISTRY
--=====================================================================

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
		entries[name] = {
			kind = "command",
			flag = spec.flag,
			usage = Config.Usage(name),
			help = spec.help,
		}
		table.insert(names, name)
	end

	-- Server-owned. Skipped if a local entry already claims the name, since
	-- the local one is the thing that would actually run.
	for name, info in pairs(Config.RemoteCommands) do
		if not entries[name] then
			entries[name] = {
				kind = "remote",
				flag = info.flag,
				usage = info.usage,
				help = info.help,
			}
			table.insert(names, name)
		end
	end

	table.sort(names)
end

rebuild()
Config.OnCommandsChanged(rebuild)

if Manifest then
	Manifest.OnClientEvent:Connect(function(list)
		Config.SetRemoteCommands(list)   -- fires OnCommandsChanged -> rebuild
	end)
else
	warn("[Console] no ConsoleManifest remote; server commands won't autocomplete.")
end

--=====================================================================
-- UI
--=====================================================================

local screenGui    = script.Parent
local frame        = screenGui.Frame
local inputField   = frame.Input
local submitButton = frame.SubmitButton
local log          = frame.Log

-- The frame is always visible now; the ScreenGui is the toggle. Forced here
-- rather than trusted from Studio, because a Frame left Visible=false would
-- produce an "open" console that renders nothing.
frame.Visible = true
screenGui.Enabled = false

local listLayout = log:FindFirstChildOfClass("UIListLayout") or Instance.new("UIListLayout")
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = log
log.AutomaticCanvasSize = Enum.AutomaticSize.Y
log.CanvasSize = UDim2.new(0, 0, 0, 0)

local suggestionBox = frame:FindFirstChild("SuggestionBox") or Instance.new("ScrollingFrame")
suggestionBox.Name = "SuggestionBox"
suggestionBox.AnchorPoint = Vector2.new(0, 1)
suggestionBox.Position = UDim2.new(
	inputField.Position.X.Scale, inputField.Position.X.Offset,
	inputField.Position.Y.Scale, inputField.Position.Y.Offset - 2
)
suggestionBox.BackgroundColor3 = Color3.fromRGB(28, 28, 30)
suggestionBox.BorderColor3 = Color3.fromRGB(70, 70, 74)
suggestionBox.ScrollBarThickness = 6
suggestionBox.Visible = false
suggestionBox.ZIndex = 10
suggestionBox.AutomaticCanvasSize = Enum.AutomaticSize.Y
suggestionBox.CanvasSize = UDim2.new(0, 0, 0, 0)
suggestionBox.Parent = frame

local suggestListLayout = suggestionBox:FindFirstChildOfClass("UIListLayout") or Instance.new("UIListLayout")
suggestListLayout.SortOrder = Enum.SortOrder.LayoutOrder
suggestListLayout.Parent = suggestionBox

local ROW_HEIGHT = 20

--=====================================================================
-- LOG
--=====================================================================

-- Source's console colours: your own input is bright, replies are neutral,
-- warnings amber, errors red, server traffic tinted so a round trip is
-- visually distinct from something this VM answered.
local COLOURS = {
	echo    = Color3.fromRGB(235, 235, 235),
	reply   = Color3.fromRGB(190, 190, 190),
	info    = Color3.fromRGB(150, 200, 255),
	warn    = Color3.fromRGB(255, 210, 100),
	error   = Color3.fromRGB(255, 90, 90),
	server  = Color3.fromRGB(160, 230, 180),
	spew    = Color3.fromRGB(130, 130, 130),
}

local logLines = {}   -- FIFO of TextLabels
local logOrder = 0
local pendingScroll = false

local function scrollToBottom()
	if pendingScroll then return end
	pendingScroll = true
	-- Deferred and coalesced: a command that emits forty lines would otherwise
	-- queue forty layout reads in one frame.
	task.defer(function()
		pendingScroll = false
		log.CanvasPosition = Vector2.new(0, log.AbsoluteCanvasSize.Y)
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
	local label = Instance.new("TextLabel")
	-- AutomaticSize with TextWrapped, not a fixed 15px: bindlist and help
	-- emit lines wider than the frame, and a fixed height clipped them.
	label.Size = UDim2.new(1, 0, 0, 0)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.TextWrapped = true
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Font = Enum.Font.Code
	label.TextSize = 14
	label.Text = text
	label.TextColor3 = COLOURS[kind] or COLOURS.reply
	logOrder += 1
	label.LayoutOrder = logOrder
	label.Parent = log

	table.insert(logLines, label)
	trimLog()
	scrollToBottom()
end

-- Splits on newlines so multi-line command output lays out correctly.
local function addLog(message, kind)
	local text = tostring(message)
	local stamp = ""
	if Config.con_timestamp then
		stamp = ("[%7.2f] "):format(State.gameTime or 0)
	end

	for _, lineText in ipairs(string.split(text, "\n")) do
		addLine(stamp .. lineText, kind)
	end
end

local function clearLog()
	for _, label in ipairs(logLines) do label:Destroy() end
	table.clear(logLines)
	logOrder = 0
end

-- Bound commands and anything else outside this script answer through here.
-- Without it their output falls back to warn() and never reaches the console.
Input.Reply = function(msg) addLog(msg, "reply") end

--=====================================================================
-- SPEW CAPTURE
--=====================================================================

-- Source shows engine spew in the console. This mirrors client-side
-- print/warn/error into it, which is the closest thing to that here and makes
-- a warn() from any module visible in game rather than Studio-only.
--
-- CLIENT ONLY. Server-side print still goes to the server log; that is what
-- ctx.reply is for, and no capture here can change it.
local MESSAGE_KIND = {
	[Enum.MessageType.MessageOutput]  = "spew",
	[Enum.MessageType.MessageInfo]    = "info",
	[Enum.MessageType.MessageWarning] = "warn",
	[Enum.MessageType.MessageError]   = "error",
}

LogService.MessageOut:Connect(function(message, messageType)
	if not Config.con_spew then return end
	addLog(message, MESSAGE_KIND[messageType] or "spew")
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
-- VISIBILITY
--=====================================================================

local function isOpen()
	return screenGui.Enabled
end

local function setOpen(open)
	if screenGui.Enabled == open then return end
	screenGui.Enabled = open

	if open then
		-- Deferred: CaptureFocus on a ScreenGui that hasn't rendered yet is
		-- unreliable, and a frame's delay is imperceptible.
		task.defer(function()
			if screenGui.Enabled then inputField:CaptureFocus() end
		end)
	else
		-- Focus must be dropped explicitly. A focused TextBox is one of the
		-- three things Input counts as modal, so leaving it focused would keep
		-- the cursor free and gameplay input dead after the console closes.
		inputField:ReleaseFocus()
		suggestionBox.Visible = false
	end
end

-- Follows whatever key is bound to `toggleconsole` rather than hardcoding a
-- key, and keeps firing while open because the command is flagged
-- modalPassthrough in Input -- a disabled InputContext delivers no events.
--
-- Was checking for "Console", which no longer exists: the console could not
-- be opened at all.
Input.ActionPressed.Event:Connect(function(command)
	if command == "toggleconsole" then
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

local function tagFor(entry)
	local f = Config.FCVAR
	if entry.kind == "remote" then return " [SERVER CMD]" end

	local tags = {}
	if hasFlag(entry.flag, f.REPLICATED) then table.insert(tags, "SERVER") end
	if hasFlag(entry.flag, f.CHEAT)      then table.insert(tags, "CHEAT") end
	if #tags == 0 then return "" end
	return " [" .. table.concat(tags, "|") .. "]"
end

local function describe(name, entry)
	if entry.kind == "cvar" then
		return (" %s  [%s]%s"):format(name, tostring(entry.default), tagFor(entry))
	end
	-- Commands show their argument shape, which is what you actually need at
	-- the prompt: `jointeam <player> <string>` beats a default value.
	local line = (" %s%s"):format(entry.usage or name, tagFor(entry))
	return line
end

local function highlightSuggestion()
	for i, row in ipairs(suggestionRows) do
		local on = (i == selectedIndex)
		row.BackgroundTransparency = on and 0.4 or 1
		row.BackgroundColor3 = Color3.fromRGB(70, 100, 140)
		row.TextColor3 = on and Color3.new(1, 1, 1) or Color3.new(0.85, 0.85, 0.85)
	end

	-- Keep the selection inside the scroll window.
	local row = suggestionRows[selectedIndex]
	if row then
		local top = (selectedIndex - 1) * ROW_HEIGHT
		local view = suggestionBox.AbsoluteWindowSize.Y
		local pos = suggestionBox.CanvasPosition.Y
		if top < pos then
			suggestionBox.CanvasPosition = Vector2.new(0, top)
		elseif top + ROW_HEIGHT > pos + view then
			suggestionBox.CanvasPosition = Vector2.new(0, top + ROW_HEIGHT - view)
		end
	end
end

local function updateSuggestions()
	for _, row in ipairs(suggestionRows) do row:Destroy() end
	table.clear(suggestionRows)

	local text = inputField.Text
	currentMatches = {}
	selectedIndex = 1

	if text == "" or text:match("^%s*$") then
		suggestionBox.Visible = false
		return
	end

	-- Only complete the last segment of a semicolon chain.
	local segments = splitCommands(text)
	local active = string.match(segments[#segments], "^%s*(.-)%s*$")

	-- Match against the bare name; the prefix is re-attached on completion.
	currentPrefix = ""
	if string.sub(active, 1, 1) == BROADCAST_PREFIX then
		currentPrefix = BROADCAST_PREFIX
		active = string.sub(active, 2)
	end

	local searchCmd = string.split(active, " ")[1]
	if searchCmd == "" then
		suggestionBox.Visible = false
		return
	end

	-- Once a space has been typed the command is settled and you're on its
	-- arguments, so the dropdown gets out of the way.
	if string.find(active, " ") then
		suggestionBox.Visible = false
		return
	end

	local lowerSearch = string.lower(searchCmd)
	for _, name in ipairs(names) do
		if string.lower(string.sub(name, 1, #searchCmd)) == lowerSearch then
			table.insert(currentMatches, name)
		end
	end

	if #currentMatches == 0 then
		suggestionBox.Visible = false
		return
	end

	local shown = math.min(#currentMatches, math.max(Config.con_suggestions or 12, 1))
	for i = 1, shown do
		local name = currentMatches[i]
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		label.LayoutOrder = i
		label.BackgroundTransparency = 1
		label.BorderSizePixel = 0
		label.Text = describe(name, entries[name])
		label.TextColor3 = Color3.new(0.85, 0.85, 0.85)
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Font = Enum.Font.Code
		label.TextSize = 14
		label.ZIndex = 11
		label.Parent = suggestionBox
		table.insert(suggestionRows, label)
	end

	local boxHeight = math.min(shown, 8) * ROW_HEIGHT
	suggestionBox.Size = UDim2.new(inputField.Size.X.Scale, inputField.Size.X.Offset, 0, boxHeight)
	suggestionBox.Visible = true
	highlightSuggestion()
end

-- Connected ONCE. This used to be connected twice -- here and again at the
-- bottom of the file -- so every keystroke rebuilt the whole dropdown twice.
inputField:GetPropertyChangedSignal("Text"):Connect(function()
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
	inputField.CursorPosition = #inputField.Text + 1
	internalEdit = false

	updateSuggestions()
end

--=====================================================================
-- DISPATCH
--=====================================================================

-- Every local Exec gets this ctx. reply is the load-bearing field: without it
-- Config falls back to warn() and the command answers into the log.
local function makeCtx()
	return {
		player = plr,
		source = "console",
		reply = function(msg) addLog(msg, "reply") end,
	}
end

local function execOne(line)
	-- Broadcast lines are never resolved locally. The name may belong to a
	-- server-only command that this VM has no entry for, and even when it is
	-- a local cvar, the point of '!' is that the SERVER decides and pushes.
	if string.sub(line, 1, 1) == BROADCAST_PREFIX then
		if string.match(line, "^" .. BROADCAST_PREFIX .. "%s*$") then
			addLog("'!' needs a command after it", "error")
			return
		end
		ConsoleEvent:FireServer(line)
		return
	end

	local name = string.match(line, "^(%S+)")
	if not name then return end

	local entry = entries[name]
	if not entry then
		addLog(("Unknown command: %s"):format(name), "error")
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
		-- back on success just doubled every output line.
		local ok, reason = Config.Exec(line, makeCtx())
		if not ok and reason then addLog(reason, "error") end
		return
	end

	--- cvar ---

	local rest = string.match(line, "^%S+%s+(.*)$")

	-- No value: Source's report format, including the default and the flags.
	if not rest or rest:match("^%s*$") then
		local tags = {}
		if hasFlag(entry.flag, Config.FCVAR.REPLICATED) then table.insert(tags, "replicated") end
		if hasFlag(entry.flag, Config.FCVAR.CHEAT) then table.insert(tags, "cheat") end

		addLog(('"%s" = "%s" ( def. "%s" )%s'):format(
			name, tostring(Config.Get(name)), tostring(entry.default),
			#tags > 0 and ("  - " .. table.concat(tags, ", ")) or ""), "reply")
		return
	end

	-- Replicated cvars are rejected by Config.Set on the client by design, so
	-- route them to the server, which accepts them if you're an admin. The old
	-- console just printed "Access Denied" and stopped here.
	if hasFlag(entry.flag, Config.FCVAR.REPLICATED) then
		ConsoleEvent:FireServer(line)
		return
	end

	-- Config.Set now returns its own reason rather than warning, so the
	-- console no longer has to guess which rule was violated.
	local ok, reason = Config.Set(name, rest)
	if ok then
		addLog(('"%s" = "%s"'):format(name, tostring(Config.Get(name))), "reply")
	else
		addLog(reason or ("failed to set " .. name), "error")
	end
end

local function submitCommand()
	local rawText = inputField.Text
	if rawText == "" or rawText:match("^%s*$") then return end

	addLog("] " .. rawText, "echo")

	if commandHistory[#commandHistory] ~= rawText then
		table.insert(commandHistory, rawText)
		local maxHistory = math.max(Config.con_history or 64, 1)
		while #commandHistory > maxHistory do
			table.remove(commandHistory, 1)
		end
	end
	historyIndex = #commandHistory + 1

	for _, commandText in ipairs(splitCommands(rawText)) do
		commandText = string.match(commandText, "^%s*(.-)%s*$")
		if commandText and commandText ~= "" then
			execOne(commandText)
		end
	end

	internalEdit = true
	inputField.Text = ""
	internalEdit = false
	suggestionBox.Visible = false
end

ConsoleLog.OnClientEvent:Connect(function(message, isError)
	addLog(tostring(message), isError and "error" or "server")
end)

-- Admin force-push. The server has already validated the sender and run the
-- line on its own VM; this applies the same line locally with forceOverride,
-- which is what lets it override a CLIENT-flagged cvar the player owns.
if ConsoleBroadcast then
	ConsoleBroadcast.OnClientEvent:Connect(function(line)
		if type(line) ~= "string" then return end

		local name = string.match(line, "^(%S+)")
		if not name then return end

		-- Server-only commands (loadmap, spawns) don't exist in this VM. They
		-- already ran server-side, so dropping them here is the correct
		-- outcome, not a failure worth logging.
		if Config.Values[name] == nil and Config.Commands[name] == nil then return end

		-- admin = true because the server vouched for it: runCommand would
		-- otherwise reject a REPLICATED command on a non-server VM.
		local ctx = makeCtx()
		ctx.source = "server"
		ctx.admin = true
		ctx.forceOverride = true
		Config.Exec(line, ctx)

		addLog("! " .. tostring(line), "server")
	end)
else
	warn("[Console] no ConsoleBroadcast remote; '!' commands won't apply locally.")
end

--=====================================================================
-- INPUT
--=====================================================================

-- History, completion and close. The open key lives on the Input module.
--
-- Arrow keys drive the dropdown when it's showing and the history when it
-- isn't, which is how Source's console behaves -- one pair of keys, two
-- meanings, disambiguated by what's on screen.
UserInputService.InputBegan:Connect(function(input)
	if not inputField:IsFocused() then return end
	local key = input.KeyCode

	if key == Enum.KeyCode.Up then
		if suggestionBox.Visible and #currentMatches > 0 then
			selectedIndex = math.max(selectedIndex - 1, 1)
			highlightSuggestion()
		elseif #commandHistory > 0 then
			historyIndex = math.max(1, historyIndex - 1)
			internalEdit = true
			inputField.Text = commandHistory[historyIndex]
			internalEdit = false
			task.defer(function() inputField.CursorPosition = #inputField.Text + 1 end)
		end

	elseif key == Enum.KeyCode.Down then
		if suggestionBox.Visible and #currentMatches > 0 then
			selectedIndex = math.min(selectedIndex + 1, #suggestionRows)
			highlightSuggestion()
		elseif #commandHistory > 0 then
			historyIndex = math.min(#commandHistory + 1, historyIndex + 1)
			internalEdit = true
			inputField.Text = (historyIndex > #commandHistory) and ""
				or commandHistory[historyIndex]
			internalEdit = false
			if inputField.Text ~= "" then
				task.defer(function() inputField.CursorPosition = #inputField.Text + 1 end)
			end
		end

	elseif key == Enum.KeyCode.Tab then
		-- Deferred: Roblox inserts the tab character into the TextBox after
		-- this handler returns, and completing first would have it appended.
		task.defer(applyCompletion)

	elseif key == Enum.KeyCode.Escape then
		-- Roblox may also open its own menu on Escape; nothing here can stop
		-- that, but the console still closes underneath it.
		setOpen(false)
	end
end)

submitButton.Activated:Connect(submitCommand)

inputField.FocusLost:Connect(function(enterPressed)
	if not enterPressed then return end
	submitCommand()
	task.wait()
	-- Guarded: pressing the toggle key closes the console, which drops focus
	-- and fires FocusLost. Re-capturing unconditionally would yank focus back
	-- into a console the player just closed.
	if isOpen() then
		inputField:CaptureFocus()
	end
end)

--=====================================================================
-- CONSOLE-OWNED COMMANDS
--=====================================================================

Config.Command("clear", {
	args = {},
	help = "clear the console log",
	run = function()
		clearLog()
	end,
})

Config.Command("echo", {
	args = { "rest" },
	help = "print text to the console",
	run = function(ctx, text)
		ctx.reply(text)
	end,
})

Config.Command("toggleconsole", {
	args = {},
	help = "show or hide the console",
	run = function()
		setOpen(not isOpen())
	end,
})

addLog("Glacier1 console. `help` lists commands, `bindlist` lists binds.", "info")