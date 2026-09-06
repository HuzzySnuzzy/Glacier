-- LocalScript: menuresume
-- ui = menu / Frame / Resume / menuresume
--
-- The Resume button, and -- because it already owned gui.Enabled -- the shell
-- the other two buttons hang off: what mode the menu is in, and the key that
-- opens it.
--
-- TWO MODES, and the difference is the whole reason this file grew.
--
--   join   the server is asking you to pick a side or spawn. The menu was
--          opened by ShowJoinUI, Resume means "deploy me", and F1 must not
--          dismiss it -- there is nothing behind it to go back to.
--   pause  you are alive and pressed F1. Resume means "put me back", and
--          firing RequestSpawn here would respawn a living player, which
--          reads as the menu killing you.
--
-- The mode lives as an attribute on the ScreenGui rather than in a local, so
-- menuquit and menusettings can read it without this script having to export
-- anything to them.
--
-- MODAL. "menu" is in Input's MODAL_GUIS list, so the cursor and the movement
-- suppression are handled the moment gui.Enabled flips. Nothing here has to
-- ask for them.

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local plr = Players.LocalPlayer

local RequestSpawn = ReplicatedStorage:WaitForChild("RequestSpawn")
local ShowJoinUI   = ReplicatedStorage:WaitForChild("ShowJoinUI")

local button = script.Parent
local gui = button:FindFirstAncestorWhichIsA("ScreenGui")
if not gui then
	error("[menuresume] not under a ScreenGui -- expected menu / Frame / Resume / menuresume", 0)
end

-- The panel to animate. Whatever sits between the button and the ScreenGui is
-- the frame the player sees, and walking up to it means the layout can be
-- rearranged in Studio without this breaking.
local panel = button.Parent

--=====================================================================
-- CLIENT MODULES
--=====================================================================
-- Same search WeaponEditor does: the module folder moves depending on how the
-- place is built, and hard-coding one path is how a menu ends up working on
-- one machine only.

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

--=====================================================================
-- MODE
--=====================================================================

local MODE = "Mode"   -- attribute name, shared with menuquit and menusettings

local function mode()
	return gui:GetAttribute(MODE) or "pause"
end

local function setMode(value)
	gui:SetAttribute(MODE, value)
end

setMode("join")   -- how a session starts: you have not spawned yet

--=====================================================================
-- OPEN AND CLOSE
--=====================================================================

local TweenService = game:GetService("TweenService")
local OPEN_INFO  = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
local CLOSE_INFO = TweenInfo.new(0.14, Enum.EasingStyle.Quint, Enum.EasingDirection.In)

-- A UIScale rather than a transparency fade: fading a Frame does not fade its
-- children, so the buttons would hang at full opacity over a vanishing panel.
local scale = panel:FindFirstChildOfClass("UIScale")
if not scale then
	scale = Instance.new("UIScale")
	scale.Parent = panel
end

local closeTween

local function open(newMode)
	if newMode then setMode(newMode) end
	if closeTween then closeTween:Cancel() closeTween = nil end

	gui.Enabled = true
	panel.Visible = true
	scale.Scale = 0.97
	TweenService:Create(scale, OPEN_INFO, { Scale = 1 }):Play()
end

local function close()
	if not gui.Enabled then return end

	closeTween = TweenService:Create(scale, CLOSE_INFO, { Scale = 0.97 })
	closeTween:Play()

	-- Disabled only after the motion finishes, or the panel vanishes on the
	-- first frame and the tween plays to an empty screen.
	local thisTween = closeTween
	task.delay(CLOSE_INFO.Time, function()
		-- Guarded, because open() may have run inside those 140ms -- F1
		-- pressed twice quickly -- and disabling then would leave the menu
		-- open as far as every caller is concerned and gone as far as the
		-- player is.
		if closeTween == thisTween then
			gui.Enabled = false
			closeTween = nil
		end
	end)
end

--=====================================================================
-- RESUME
--=====================================================================

-- Guards a double click during the request's round trip. Cleared by the
-- server's answer, not by a timer, so a slow server cannot leave the button
-- dead nor let two spawns through.
local sent = false

button.Activated:Connect(function()
	if not gui.Enabled then return end

	if mode() == "join" then
		if sent then return end
		sent = true
		RequestSpawn:FireServer()
		-- NOT closed here: the server answers with ShowJoinUI(false) when the
		-- spawn actually happens, and closing early on a refused request would
		-- drop the player into a game they were never put into.
		return
	end

	close()
end)

ShowJoinUI.OnClientEvent:Connect(function(visible)
	if visible then
		sent = false
		open("join")
	else
		setMode("pause")
		close()
	end
end)

--=====================================================================
-- F1
--=====================================================================

local function toggle()
	-- The join screen is not dismissable. There is no game behind it yet, and
	-- a player who closed it would be left looking at an empty world with no
	-- way back except another server event.
	if mode() == "join" then return end

	if gui.Enabled then close() else open("pause") end
end

if Input then
	-- The bind (f1 by default) resolves to this command through the console
	-- dispatcher, exactly like toggleconsole. Registered here rather than in
	-- Input because the menu, not the input system, is what knows how to open.
	Input.ActionPressed.Event:Connect(function(command)
		if command == "togglemenu" then toggle() end
	end)
else
	warn("[menuresume] client modules not found -- F1 will not open the menu")
end

-- Also a console command, so it can be bound to anything else without this
-- script knowing, and so `togglemenu` typed into the console works.
Config.Command("togglemenu", {
	args = {},
	help = "open or close the main menu",
	run = function()
		toggle()
	end,
})
