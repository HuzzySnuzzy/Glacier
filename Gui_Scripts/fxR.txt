-- screengui fx
-- localscript fxR.lua

const ReplicatedStorage = game:GetService("ReplicatedStorage")
const gui = script.Parent
local fx_Death = ReplicatedStorage:WaitForChild("fx_Death")

fx_Death.OnClientEvent:Connect(function()
	gui.Black.Visible = true
	wait(1)
	gui.Black.Visible = false
end)