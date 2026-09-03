local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))

local sndR = {}

function sndR.Init()
	print("Started")
	local SoundReceiverEvent = game.ReplicatedStorage:WaitForChild("SoundReceiver")
	SoundReceiverEvent.OnClientEvent:Connect(function(pos,id)
		local loc = Instance.new("Part")
		loc.CanCollide = false loc.Anchored = true loc.CanQuery = false loc.CanTouch = false
		loc.Position = pos loc.Parent = workspace loc.Transparency = .8
		local sound = Instance.new("Sound")
		sound.SoundId = "rbxassetid://"..id
		sound.Volume = 1
		sound.RollOffMaxDistance = 10000
		sound.RollOffMinDistance = 10000
		sound.Parent = loc sound.PlayOnRemove = true
		
		
		
		loc:Destroy()
	end)
	
end

return sndR
