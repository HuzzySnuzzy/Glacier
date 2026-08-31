-- ModuleScript: ServerDebug
-- Parent: CustomController
--
-- Top-right readout of server state. Purely a viewer: every value comes from
-- the ServerDebug snapshot, nothing is computed locally except staleness.

local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Remote = ReplicatedStorage:WaitForChild("ServerDebug")

local ServerDebug = {}

local gui, label
local snapshot, lastRecv = nil, 0

--=====================================================================

local function fmtTime(seconds)
	if not seconds then return "--:--" end
	local m = math.floor(seconds / 60)
	local s = math.floor(seconds % 60)
	return ("%d:%02d"):format(m, s)
end

local function build()
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")

	gui = Instance.new("ScreenGui")
	gui.Name = "ServerDebugHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.Enabled = false
	gui.Parent = pg

	label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(1, 0)
	label.Position = UDim2.new(1, -12, 0, 12)
	label.Size = UDim2.new(0, 300, 0, 400)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.Code
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextColor3 = Color3.fromRGB(220, 220, 220)
	label.TextStrokeTransparency = 0.4
	label.RichText = true
	label.Text = ""
	label.Parent = gui
end

local function colour(text, rgb)
	return ("<font color=\"rgb(%d,%d,%d)\">%s</font>"):format(rgb[1], rgb[2], rgb[3], text)
end

local function render()
	local s = snapshot
	if not s then
		label.Text = colour("awaiting server snapshot...", { 200, 160, 60 })
		return
	end

	local age = os.clock() - lastRecv
	local lines = {}

	-- Stale is the single most useful signal here: it means the server loop
	-- has stalled or the remote isn't arriving, which reframes every other
	-- number on screen as historical.
	if age > 1.5 then
		table.insert(lines, colour(("STALE %.1fs"):format(age), { 255, 90, 90 }))
	end

	table.insert(lines, "<b>SERVER</b>")
	table.insert(lines, ("fps %6.1f   mem %5.0f MB"):format(s.fps or 0, s.mem or 0))
	table.insert(lines, ("ping %5d ms  up %s"):format(s.ping or -1, fmtTime(s.uptime)))
	table.insert(lines, ("players %d"):format(s.players or 0))

	if s.cheats then
		table.insert(lines, colour("sv_cheats 1", { 255, 170, 60 }))
	end

	table.insert(lines, "")
	table.insert(lines, ("<b>%s</b>"):format(s.mode or "no gamemode"))

	local st = s.status
	if st then
		local phaseColour = (st.phase == "live") and { 120, 255, 120 }
			or (st.phase == "freeze") and { 120, 180, 255 }
			or { 200, 200, 200 }
		table.insert(lines, ("%s  %s"):format(
			colour(string.upper(st.phase or "?"), phaseColour),
			fmtTime(st.remaining)))

		if st.round then
			table.insert(lines, ("round %d / %d"):format(st.round, st.maxRounds or 0))
		end
		if st.score then
			table.insert(lines, ("T %d : %d CT"):format(st.score.T or 0, st.score.CT or 0))
		end
		if st.alive then
			table.insert(lines, ("alive  T %d / %d   CT %d / %d"):format(
				st.alive.T or 0, (st.teams and st.teams.T) or 0,
				st.alive.CT or 0, (st.teams and st.teams.CT) or 0))
		end
	end

	if Config.cl_serverDebugPlayers and s.roster then
		table.insert(lines, "")
		for _, row in ipairs(s.roster) do
			local mark = row.alive and "" or colour(" DEAD", { 255, 90, 90 })
			table.insert(lines, ("%s  %s  %dms%s"):format(row.name, row.team, row.ping, mark))
		end
	end

	label.Text = table.concat(lines, "\n")
end

--=====================================================================

function ServerDebug.Init()
	build()

	Remote.OnClientEvent:Connect(function(snap)
		if type(snap) ~= "table" then return end
		snapshot = snap
		lastRecv = os.clock()
	end)

	-- F9 is Roblox's own dev console, so F10.
	UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.KeyCode == Enum.KeyCode.F10 then
			Config.Set("cl_serverDebug", not Config.cl_serverDebug)
		end
	end)
end

function ServerDebug.Update(dt)
	local on = Config.cl_serverDebug == true
	gui.Enabled = on
	if not on then return end

	label.TextSize = math.floor(13 * Config.cl_serverDebugScale)
	render()
end

return ServerDebug