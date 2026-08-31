-- ui = menu / Resume / LocalScript.lua

const ReplicatedStorage = game:GetService("ReplicatedStorage")
local RequestSpawn = ReplicatedStorage:WaitForChild("RequestSpawn")
local ShowJoinUI  = ReplicatedStorage:WaitForChild("ShowJoinUI")
local sent = false
local gui = script.Parent.Parent
script.Parent.Activated:Connect(function()
	if sent or not gui.Enabled then return end
	sent = true
	script.Parent.Visible = false
	gui.Enabled = false
	print("Sent")
	
	RequestSpawn:FireServer()
end)

ShowJoinUI.OnClientEvent:Connect(function(visible)
	print("Got")
	if visible then
		sent = false
	end
	gui.Enabled = visible and true or false
end)