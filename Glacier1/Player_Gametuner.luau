-- Player_GameTuner 
-- Child of Glacier1
-- Owns creation of the shared bind/remote surface. Runs early so every other
-- system can WaitForChild on these without ordering assumptions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local setPlayerDefaultLoadout = Instance.new("BindableEvent", ReplicatedStorage)
setPlayerDefaultLoadout.Name = "setPlayerDefaultLoadout"
setPlayerDefaultLoadout.Event:Connect(function(plr, primary, secondary, melee)
	local GT = plr:FindFirstChild("GT") if not GT then GT = Instance.new("Configuration", plr) GT.Name = "GT" end
	local weapon_Primary = GT:FindFirstChild("weapon_Primary") if not weapon_Primary then weapon_Primary = Instance.new("StringValue", GT) weapon_Primary.Name = "weapon_Primary" end
	local weapon_Secondary = GT:FindFirstChild("weapon_Secondary") if not weapon_Secondary then weapon_Secondary = Instance.new("StringValue", GT) weapon_Secondary.Name = "weapon_Secondary" end
	local weapon_Melee = GT:FindFirstChild("weapon_Melee") if not weapon_Melee then weapon_Melee = Instance.new("StringValue", GT) weapon_Melee.Name = "weapon_Melee" end
	weapon_Primary.Value = primary
	weapon_Secondary.Value = secondary
	weapon_Melee.Value = melee
end)

local setPlayerSpawnReq = Instance.new("BindableEvent", ReplicatedStorage)
setPlayerSpawnReq.Name = "setPlayerSpawnReq"
setPlayerSpawnReq.Event:Connect(function(plr, value)
	local GT = plr:FindFirstChild("GT") if not GT then GT = Instance.new("Configuration", plr) GT.Name = "GT" end
	local spawn_Requested = GT:FindFirstChild("spawn_Requested") if not spawn_Requested then spawn_Requested = Instance.new("BoolValue", GT) spawn_Requested.Name = "spawn_Requested" end
	spawn_Requested.Value = value
end)

-- Gun game progression. Lives on the Player (not the rawbody) so it survives
-- death, and replicates to the client automatically for HUD use.
local setPlayerGGLevel = Instance.new("BindableEvent", ReplicatedStorage)
setPlayerGGLevel.Name = "setPlayerGGLevel"
setPlayerGGLevel.Event:Connect(function(plr, value)
	local GT = plr:FindFirstChild("GT") if not GT then GT = Instance.new("Configuration", plr) GT.Name = "GT" end
	local gg_Level = GT:FindFirstChild("gg_Level") if not gg_Level then gg_Level = Instance.new("IntValue", GT) gg_Level.Name = "gg_Level" end
	gg_Level.Value = value
end)

--==========================================================
-- Join UI plumbing
--==========================================================

-- Server -> client. Arg is a bool: show or hide the join panel.
local showJoinUI = ReplicatedStorage:FindFirstChild("ShowJoinUI")
if not showJoinUI then
	showJoinUI = Instance.new("RemoteEvent", ReplicatedStorage)
	showJoinUI.Name = "ShowJoinUI"
end

-- Client -> server. No payload; the sender is the payload. Never trust this
-- for anything beyond "player pressed the button" - the gamemode validates.
local requestSpawn = ReplicatedStorage:FindFirstChild("RequestSpawn")
if not requestSpawn then
	requestSpawn = Instance.new("RemoteEvent", ReplicatedStorage)
	requestSpawn.Name = "RequestSpawn"
end