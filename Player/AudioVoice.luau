-- ModuleScript: AudioVoice
-- Parent: Player (the LocalScript's module folder)
--
-- Turns a Sound somebody authored in Studio into the Advanced Audio API, so
-- it goes through the engine's acoustic simulation -- occlusion through walls,
-- diffraction round corners, reverb off whatever room it is in -- instead of
-- Roblox's flat 3D panner.
--
-- WHY A CONVERTER AND NOT AN AUTHORING CHANGE. A Sound is one instance with a
-- picker for the asset and a volume slider. The equivalent graph is an
-- AudioPlayer, an Attachment, an AudioEmitter and a Wire, correctly parented,
-- and asking an artist to build four instances per engine note -- on a car
-- that has six of them -- would be a worse tool for a better renderer. So the
-- Sound stays the thing you author and this is what runs.
--
--   Sound  ->  AudioPlayer -> Wire -> AudioEmitter (on an Attachment)
--                                       |
--                                       v
--              the AudioListener Sounds.Init put on the Camera -> Output
--
-- The emitter reaches the listener through the shared AudioInteractionGroup
-- rather than a Wire, which is why nothing here has to know where the
-- listener is. Sounds.Init has to have run; if it has not, this still builds
-- the graph and the graph is simply inaudible, which is the same failure the
-- movement audio would have.
--
-- WHAT IT COPIES, and it is deliberately everything the artist can set:
-- the asset, the volume, the playback speed, looping, and the roll-off
-- distances -- turned into the distance curve an AudioEmitter wants.
--
-- IT ALWAYS WORKS. If the classes are not available -- an older client, or
-- the feature turned off -- From() hands back a voice that drives the
-- original Sound instead, with the same methods. Callers never branch.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))

local AudioVoice = {}
AudioVoice.__index = AudioVoice

local function trySet(inst, prop, value)
	pcall(function() inst[prop] = value end)
end

--=====================================================================
-- AVAILABILITY
--=====================================================================

-- Asked once. Instance.new on a class the client does not have is an ERROR,
-- not a nil, so this is a pcall rather than a version check -- and a version
-- check would be a guess about which build shipped what.
local available

local function apiAvailable()
	if available ~= nil then return available end

	local ok = pcall(function()
		local probe = Instance.new("AudioPlayer")
		local emitter = Instance.new("AudioEmitter")
		local wire = Instance.new("Wire")
		probe:Destroy()
		emitter:Destroy()
		wire:Destroy()
	end)

	available = ok
	if not ok then
		warn("[AudioVoice] no Advanced Audio API on this client -- " ..
			"vehicle audio falls back to Sound instances")
	end
	return available
end

--=====================================================================
-- THE ARTIST'S VALUES
--=====================================================================

-- Remembered on the Sound itself, for the same reason the emitter rates are:
-- this code SILENCES the original once it has taken over, so a second read --
-- after a rig was collected and rebuilt -- would find the zero it wrote and
-- take that for what the artist wanted. The sound would then work once per
-- session and never again.
local function remembered(sound, attribute, property, fallback)
	local saved = sound:GetAttribute(attribute)
	if saved == nil then
		saved = sound[property]
		sound:SetAttribute(attribute, saved)
	end
	if type(saved) ~= "number" or saved <= 0 then return fallback end
	return saved
end

--=====================================================================
-- THE CURVE
--=====================================================================

-- A Sound falls off between RollOffMinDistance and RollOffMaxDistance; an
-- AudioEmitter wants a table of distance -> gain. Translated rather than
-- replaced with a house default, because roll-off is the one acoustic
-- property people really do tune per sound: an engine that carries across
-- the map and a valve chirp you only hear beside the car are the same
-- instance type with different numbers.
local function curveFor(minDistance, maxDistance)
	local near = math.max(minDistance or 10, 0.1)
	local far = math.max(maxDistance or 120, near + 1)

	return {
		[0] = 1,
		[near] = 1,
		[near + (far - near) * 0.35] = 0.55,
		[near + (far - near) * 0.7] = 0.2,
		[far] = 0,
	}
end

--=====================================================================
-- BUILD
--=====================================================================

local function buildGraph(sound, volume, pitch)
	-- Hosted on the Sound's own parent, so the emitter is wherever the artist
	-- put the Sound and moves with it. On these cars that is the chassis,
	-- which is the part the whole vehicle is drawn from.
	local host = sound.Parent
	if not host then return nil end

	local attachmentName = sound.Name .. "_AudioSource"

	-- REUSED IF IT IS ALREADY THERE.
	--
	-- The rig this hangs off is held weakly, so a car can be measured again
	-- mid-session -- and a From() that built unconditionally would leave the
	-- previous player and emitter parented, orphaned, and still wired. That
	-- is a leak that grows for as long as anyone drives, and the audible half
	-- is worse than the cost: the abandoned loop is still playing, so the car
	-- ends up with two engines running slightly out of step.
	local existing = host:FindFirstChild(attachmentName)
	if existing then
		local player = existing:FindFirstChildOfClass("AudioPlayer")
		local emitter = existing:FindFirstChildOfClass("AudioEmitter")
		if player and emitter then
			player.Volume = volume
			player.PlaybackSpeed = pitch
			return { player = player, emitter = emitter, attachment = existing }
		end
		-- Half-built: start over rather than reason about which half.
		existing:Destroy()
	end

	local attachment
	if host:IsA("BasePart") then
		attachment = Instance.new("Attachment")
		attachment.Name = attachmentName
		attachment.Parent = host
	end

	local emitter = Instance.new("AudioEmitter")
	emitter.Name = sound.Name .. "_Emitter"
	emitter.AudioInteractionGroup = "Default"
	trySet(emitter, "AcousticSimulationEnabled", Config.snd_acousticSim ~= false)
	pcall(function()
		emitter:SetDistanceAttenuation(
			curveFor(sound.RollOffMinDistance, sound.RollOffMaxDistance))
	end)
	emitter.Parent = attachment or host

	local player = Instance.new("AudioPlayer")
	player.Name = sound.Name .. "_Player"
	player.Asset = sound.SoundId
	player.Volume = volume
	player.PlaybackSpeed = pitch
	trySet(player, "Looping", sound.Looped)
	player.Parent = attachment or host

	local wire = Instance.new("Wire")
	wire.SourceInstance = player
	wire.TargetInstance = emitter
	wire.Parent = player

	return { player = player, emitter = emitter, attachment = attachment }
end

--=====================================================================
-- VOICE
--=====================================================================

-- nil in, nil out: every caller here treats a missing sound as "this car does
-- not have that effect", and making them nil-check a constructor as well
-- would just move the same branch somewhere less obvious.
function AudioVoice.From(sound)
	if not sound then return nil end

	local self = setmetatable({}, AudioVoice)
	self.sound = sound
	self.baseVolume = remembered(sound, "FXBaseVolume", "Volume", 0.5)
	self.basePitch = remembered(sound, "FXBasePitch", "PlaybackSpeed", 1)

	if Config.snd_audioApi ~= false and apiAvailable() then
		local graph = buildGraph(sound, self.baseVolume, self.basePitch)
		if graph then
			self.mode = "audio"
			self.player = graph.player
			self.emitter = graph.emitter

			-- The original is SILENCED, not destroyed. It is the artist's
			-- instance and the thing they will come back to edit; destroying
			-- it would mean a car that cannot be re-tuned in Studio without
			-- first understanding what this module did to it.
			pcall(function() sound:Stop() end)
			sound.Volume = 0
			return self
		end
	end

	self.mode = "sound"
	return self
end

function AudioVoice:SetVolume(volume)
	-- The game's own master, applied in BOTH modes so switching between them
	-- cannot change how loud the car is. Roblox does not scale Sound.Volume
	-- by anything, so without this the Audio tab's master slider would move
	-- the movement audio and leave the vehicles where they were.
	local scaled = math.clamp(volume * (Config.volume or 1), 0, 10)

	if self.mode == "audio" then
		self.player.Volume = scaled
	else
		self.sound.Volume = scaled
	end
end

function AudioVoice:SetPitch(pitch)
	local clamped = math.clamp(pitch, 0.05, 20)
	if self.mode == "audio" then
		self.player.PlaybackSpeed = clamped
	else
		self.sound.PlaybackSpeed = clamped
	end
end

function AudioVoice:IsPlaying()
	if self.mode == "audio" then return self.player.IsPlaying == true end
	return self.sound.IsPlaying == true
end

function AudioVoice:SetLooping(looping)
	if self.mode == "audio" then
		trySet(self.player, "Looping", looping)
	else
		self.sound.Looped = looping
	end
end

-- Start from the beginning, every time.
--
-- AudioPlayer:Play() RESUMES from TimePosition where Sound:Play() rewinds, so
-- the two disagree about what "play again" means -- and the difference only
-- shows on the second one-shot, which is exactly the backfire landing twice
-- in quick succession that this had to get right.
function AudioVoice:Play()
	if self.mode == "audio" then
		self.player.TimePosition = 0
		self.player:Play()
	else
		self.sound.TimePosition = 0
		self.sound:Play()
	end
end

-- Start only if it is not already going. For loops, where Play would restart
-- the sample every frame.
function AudioVoice:Resume()
	if self:IsPlaying() then return end
	self:SetLooping(true)
	if self.mode == "audio" then
		self.player:Play()
	else
		self.sound:Play()
	end
end

function AudioVoice:Stop()
	if self.mode == "audio" then
		self.player:Stop()
	else
		self.sound:Stop()
	end
end

-- For diagnostics: what this voice is actually driving.
function AudioVoice:Describe()
	return ("%s [%s]"):format(self.sound.Name,
		self.mode == "audio" and "acoustic" or "plain Sound")
end

return AudioVoice
