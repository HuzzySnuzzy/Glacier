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

local Config  = require(ReplicatedStorage:WaitForChild("Config"))
local Glacier = require(ReplicatedStorage:WaitForChild("Glacier"))

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

local function setMode(value)
	gui:SetAttribute(MODE, value)
end

-- WHETHER YOU ARE IN THE GAME, from the world rather than from the menu.
--
-- This is the fix for the third separate report of "Resume does nothing".
-- The mode attribute is a CACHE of the last thing the server said, and the
-- server does not always say it: with SHOW_UI_ON_RESPAWN off -- the shipped
-- setting -- dying fires no ShowJoinUI at all, so the attribute is still
-- reading "pause" from the spawn before. Resume in pause mode means "put me
-- back", which for a player with no body is closing the menu and nothing
-- else. Press it while dead and the menu shuts on an empty world.
--
-- A RawBody is the ground truth: the server owns it, it exists exactly when
-- you are alive, and no message has to arrive for this to be right.
local function alive()
	return Glacier.RawBody(plr) ~= nil
end

-- Kept in step with the world, because menuquit and menusettings read it and
-- would otherwise inherit the same staleness. Derived rather than remembered
-- -- which is the whole point.
local function syncMode()
	local value = alive() and "pause" or "join"
	if gui:GetAttribute(MODE) ~= value then setMode(value) end
	return value
end

local function mode()
	return gui:GetAttribute(MODE) or "pause"
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

-- Guards a double click during the request's round trip.
--
-- Cleared by the server's answer -- OR by a timeout, which is the part that
-- matters. The server can refuse a request without saying so: mid-round
-- intermission and an unexpired respawn timer both drop their latch and
-- return, sending nothing back. A client that only ever unlatches on a reply
-- is then stuck with a dead Resume button until the next round happens to
-- push the join screen at it again.
--
-- Two seconds is far longer than a round trip and far shorter than anyone's
-- patience. Re-arming does not spawn anything twice: the server ignores a
-- request from a player who is already alive.
local RETRY_AFTER = 2

local sent = false
local sentToken = 0

button.Activated:Connect(function()
	if not gui.Enabled then return end

	-- DECIDED FROM THE WORLD. See alive(): the mode attribute goes stale on
	-- every death the server does not announce, and trusting it is what made
	-- Resume a button that closed the menu while you lay dead behind it.
	if syncMode() == "join" then
		if sent then return end
		sent = true

		sentToken += 1
		local token = sentToken
		task.delay(RETRY_AFTER, function()
			-- Tokened, so a timeout from an EARLIER click cannot re-arm the
			-- button in the middle of a later request that is still in flight.
			if token == sentToken then sent = false end
		end)

		RequestSpawn:FireServer()
		-- NOT closed here: the server answers with ShowJoinUI(false) when the
		-- spawn actually happens, and closing early on a refused request would
		-- drop the player into a game they were never put into.
		return
	end

	close()
end)

ShowJoinUI.OnClientEvent:Connect(function(visible)
	-- Bumped either way, so a timeout still pending from the click that
	-- caused this answer cannot fire afterwards and unlatch a fresh request.
	sentToken += 1
	sent = false

	if visible then
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
	-- OPENING is always allowed. CLOSING is not.
	--
	-- The distinction matters and the single guard this replaces did not make
	-- it: it refused the whole toggle in join mode, which was harmless only
	-- because the mode was stale and read "pause" while you were dead. With
	-- the mode telling the truth, that same guard stopped a dead player from
	-- opening the menu at all -- so the key that is supposed to get you back
	-- into the game did nothing.
	--
	-- The rule is about the CLOSE: there is no game behind the join screen,
	-- and a player who dismissed it would be left looking at an empty world
	-- with no way back except another server event -- which, when the server
	-- has already said everything it is going to say, never comes.
	if gui.Enabled then
		if syncMode() == "join" then return end
		close()
	else
		open(syncMode())
	end
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
