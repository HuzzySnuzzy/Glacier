-- LocalScript: menuquit
-- ui = menu / Frame / Quit / menuquit
--
-- Leaving the game, behind a confirmation.
--
-- WHAT QUIT MEANS HERE. Roblox has no "exit to desktop" a game can call: a
-- place cannot close the client. What it can do is disconnect the player, and
-- Player:Kick from the client's own LocalScript does exactly that for the
-- player who pressed it -- they land back on the website. That is as close to
-- Quit as the platform has, so that is what this is.
--
-- WHY A PROMPT. Quit sits one button below Resume in a menu people open with
-- a key, and the cost of a misclick is a rejoin and a lost round. Two clicks
-- is the standard price for anything you cannot undo.
--
-- Enter confirms and Escape cancels, because a dialog you have to reach for
-- the mouse to dismiss is the thing everyone complains about.

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer

local button = script.Parent
local gui = button:FindFirstAncestorWhichIsA("ScreenGui")
if not gui then
	error("[menuquit] not under a ScreenGui -- expected menu / Frame / Quit / menuquit", 0)
end

--=====================================================================
-- MENUKIT
--=====================================================================
-- Found rather than required by path: where the module sits is a decision
-- made in Studio. A direct child of the menu ScreenGui is the intended home;
-- ReplicatedStorage is accepted so it can be shared more widely.

local function locateKit()
	local found = gui:FindFirstChild("MenuKit", true)
	if found and found:IsA("ModuleScript") then return require(found) end
	found = ReplicatedStorage:FindFirstChild("MenuKit")
	if found and found:IsA("ModuleScript") then return require(found) end
	return nil
end

local Kit = locateKit()
if not Kit then
	error("[menuquit] MenuKit not found -- put it under the menu ScreenGui " ..
		"or in ReplicatedStorage", 0)
end

--=====================================================================
-- DIALOG
--=====================================================================

local panel, openPanel, closePanel, scrim = Kit.Overlay(gui, 380, 176)
Kit.Pad(panel, 22)

local title = Kit.Label(panel, "Leave the game?", Kit.C.text, 18, true)
title.Size = UDim2.new(1, 0, 0, 24)

local body = Kit.Label(panel,
	"You will be disconnected and returned to Roblox. " ..
	"Rejoining puts you back in the queue.", Kit.C.dim, 13)
body.Position = UDim2.new(0, 0, 0, 34)
body.Size = UDim2.new(1, 0, 0, 42)
body.TextWrapped = true
body.TextYAlignment = Enum.TextYAlignment.Top

local buttons = Instance.new("Frame")
buttons.BackgroundTransparency = 1
buttons.AnchorPoint = Vector2.new(0, 1)
buttons.Position = UDim2.new(0, 0, 1, 0)
buttons.Size = UDim2.new(1, 0, 0, 36)
buttons.Parent = panel

local layout = Kit.List(buttons, 10, Enum.FillDirection.Horizontal)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
layout.VerticalAlignment = Enum.VerticalAlignment.Center

local open = false
local quitting = false

local escapeConn

local function hide()
	if not open then return end
	open = false
	if escapeConn then escapeConn:Disconnect() escapeConn = nil end
	closePanel()
end

local function confirm()
	-- Latched, because the kick is not instant and the dialog stays on screen
	-- while it lands. Two Enters would otherwise queue two kicks, and the
	-- second arrives after the player object is gone.
	if quitting then return end
	quitting = true

	plr:Kick("You left the game.")
end

local cancel = Kit.Button(buttons, "Cancel", "normal", hide)
cancel.Size = UDim2.new(0, 100, 0, 34)
cancel.LayoutOrder = 1

local leave = Kit.Button(buttons, "Leave", "danger", confirm)
leave.Size = UDim2.new(0, 110, 0, 34)
leave.LayoutOrder = 2

-- Clicking the dimmed area is a cancel. Any dialog that traps you until you
-- find the right button is worse than the misclick it was guarding against.
scrim.Activated:Connect(hide)

local function show()
	if open then return end
	open = true
	openPanel()

	escapeConn = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.Escape then
			hide()
		elseif input.KeyCode == Enum.KeyCode.Return
			or input.KeyCode == Enum.KeyCode.KeypadEnter then
			confirm()
		end
	end)
end

button.Activated:Connect(show)

-- The menu closing under us -- the player spawned, or pressed F1 -- takes the
-- dialog with it. A confirmation left floating over a running game is the
-- worst possible place for a button that disconnects you.
gui:GetPropertyChangedSignal("Enabled"):Connect(function()
	if not gui.Enabled then hide() end
end)
