-- Script: TeamsSetup
-- Parent: Glacier1
--
-- Real Roblox Teams, not attributes. Player.Team replicates for free, which is
-- what Spectate.sameTeam already reads -- spec_everyone starts working the
-- moment these exist.

local Teams = game:GetService("Teams")

local DEFS = {
	--{ name = "T",         color = BrickColor.new("Bright orange") },
	--{ name = "CT",        color = BrickColor.new("Bright blue")   },
	{ name = "Spectator", color = BrickColor.new("Medium stone grey") },
}

for _, def in ipairs(DEFS) do
	if not Teams:FindFirstChild(def.name) then
		local team = Instance.new("Team")
		team.Name = def.name
		team.TeamColor = def.color
		team.AutoAssignable = false   -- the roster decides, not Roblox
		team.Parent = Teams
	end
end