-- Script: Glacier1/AudioSetupServer.lua
-- Enables Roblox Acoustic Simulation. Must run before any AudioEmitter is heard.

local SoundService = game:GetService("SoundService")

local function trySet(inst, prop, value)
	local ok = pcall(function() inst[prop] = value end)
	if not ok then
		warn(("[Audio] %s.%s unavailable on this engine version"):format(inst.Name, prop))
	end
	return ok
end

-- Global master switch. Defaults to FALSE, so this line is mandatory.
trySet(SoundService, "AcousticSimulationEnabled", true)

-- Glacier drives its own character audio; don't let Roblox's default
-- character Sounds get converted and doubled up on top of ours.
trySet(SoundService, "CharacterSoundsUseNewApi", false)

-- Legacy FMOD reverb applies to old Sound instances only. Leave it off so
-- it doesn't stack with simulated reverb on anything still using Sound.
SoundService.AmbientReverb = Enum.ReverbType.NoReverb