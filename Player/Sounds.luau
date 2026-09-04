-- ModuleScript: Sounds inside Player.lua
-- Movement audio. Reads State, never writes movement state.
--
-- Setup:
--   local Sounds = require(script.Sounds)
--   Sounds.Init()
--   -- in RenderStepped:
--   Sounds.Update(deltaTime)
--
-- Requires in Physics.Step:
--   State.groundMaterial = groundHit and groundHit.Instance.Material or nil
--   Sounds.Push("jump")                    -- in the jump block
--   Sounds.Push("land", impactSpeed)       -- on the airborne -> grounded edge
--
-- Physics pushes into a queue rather than setting a flag, because Physics runs
-- at sv_PhysicsHz and this drains at render rate: a flag set and cleared
-- between two frames would be silently lost.
--
-- Uses Roblox's Advanced Audio API rather than Sound instances, so the engine's
-- Acoustic Simulation applies: occlusion through walls, diffraction around
-- corners, reverb off surrounding geometry. Requires
-- SoundService.AcousticSimulationEnabled = true (set it on the server).
--
-- Two emitter paths:
--   BODY  -- one emitter on the local hull, for sounds you make yourself
--   WORLD -- a pool of free-floating emitters, for relayed sounds from others
-- Both feed the same listener on the Camera, so both get room acoustics.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local SoundKeys = require(ReplicatedStorage:WaitForChild("SoundKeys"))
local State = require(script.Parent.State)

local Sounds = {}

local queue = {}
local strideAccum = 0
local lastFootIndex = 0
local remote 

--------------------------------------------------------------------
-- SOUND SETS
--------------------------------------------------------------------

-- Assets now live in ReplicatedStorage/SoundKeys so the server can validate
-- keys without knowing IDs. Resolve a key to one of its samples, avoiding
-- the same sample twice running.
local function pickSample(key)
	local def = SoundKeys.Defs[key]
	if not def or #def.ids == 0 then return nil, nil end

	local idx = math.random(1, #def.ids)
	if #def.ids > 1 and idx == lastFootIndex then
		idx = (idx % #def.ids) + 1
	end
	lastFootIndex = idx
	return def.ids[idx], def
end

--------------------------------------------------------------------
-- SIGNAL GRAPH
--------------------------------------------------------------------
-- AudioPlayer -> AudioEmitter -> (engine acoustics) -> AudioListener -> Output

local graph        -- Folder under SoundService holding the graph
local deviceOut    -- the sink
local listener     -- on the Camera
local emitter      -- on the local body
local emitterAtt
local anchor       -- host part for the world emitter attachments

local function trySet(inst, prop, value)
	pcall(function() inst[prop] = value end)
end

local function wire(from, to)
	local w = Instance.new("Wire")
	w.SourceInstance = from
	w.TargetInstance = to
	w.Parent = from
	return w
end

local function curveFor(range)
	return {
		[0]            = 1.0,
		[range * 0.25] = 0.70,
		[range * 0.60] = 0.30,
		[range]        = 0.0,
	}
end

--------------------------------------------------------------------
-- PLAYBACK: BODY POOL
--------------------------------------------------------------------

-- Pool so rapid footsteps don't cut each other off. A single reused player
-- restarts on every Play, which at high speed sounds like a stutter rather
-- than footsteps.
local pool = {}
local POOL_SIZE = 8
local poolIndex = 1

local function acquire()
	local p = pool[poolIndex]
	poolIndex = (poolIndex % POOL_SIZE) + 1
	return p
end

local function play(id, volume, pitch)
	if not id or id == "" then return end
	if Config.cl_soundsEnabled == false then return end

	local p = acquire()
	p.Asset = id
	p.Volume = math.clamp(volume * (Config.volume or 1), 0, 10)
	p.PlaybackSpeed = math.clamp(pitch, 0.05, 20)
	-- AudioPlayer:Play() resumes from TimePosition; Sound:Play() rewound.
	p.TimePosition = 0
	p:Play()
end

--------------------------------------------------------------------
-- PLAYBACK: WORLD POOL
--------------------------------------------------------------------

-- Same round-robin idea as the body pool, but each slot owns its own emitter
-- so it can sit anywhere in the world. Reused rather than created per sound:
-- churning emitters would mean churning the acoustic solver's state too.
local worldPool = {}
local WORLD_POOL_SIZE = 12
local worldIndex = 1

local function acquireWorld(range)
	local slot = worldPool[worldIndex]
	worldIndex = (worldIndex % WORLD_POOL_SIZE) + 1

	-- Re-curving is not free, so only when the range actually differs.
	if slot.range ~= range then
		slot.emitter:SetDistanceAttenuation(curveFor(range))
		slot.range = range
	end
	return slot
end

-- Plays a keyed sound at a world position. Used by the relay handler, and
-- available directly for anything detached (grenade bounce, bullet impact).
function Sounds.PlayAt(key, position, pitch, volScale)
	if not worldPool[1] then return end
	if Config.cl_soundsEnabled == false then return end

	local id, def = pickSample(key)
	if not id then return end

	local slot = acquireWorld(def.range)
	slot.att.Position = position

	local p = slot.player
	p.Asset = id
	p.Volume = math.clamp(
		def.volume * (volScale or 1) * (Config.volume or 1), 0, 10)
	p.PlaybackSpeed = math.clamp(pitch or 1, 0.05, 20)
	p.TimePosition = 0
	p:Play()
end

--------------------------------------------------------------------
-- NETWORK
--------------------------------------------------------------------

-- Tells the server "I made this sound here"; the server clamps the position,
-- culls by range and relays to everyone else. Does NOT play locally -- your
-- own copy already went out through the body emitter.
function Sounds.Broadcast(key, position, pitch, volScale)
	if not remote or not position then return end
	if Config.snd_broadcast == false then return end
--	warn("Broadcast:",key)
	remote:FireServer(key, position, pitch or 1, volScale or 1)
end

-- Feet, not centre: a crouched player behind a low wall should occlude, and
-- a centre-mounted source wouldn't.
local function feetPos()
	local body = State.playerBody
	if not body then return nil end
	return body.Position - Vector3.new(0, body.Size.Y * 0.5 - 0.2, 0)
end

--------------------------------------------------------------------
-- EVENT QUEUE
--------------------------------------------------------------------

-- Position is captured here rather than at drain time, because Push is called
-- from the physics step and this is the position at that tick -- the render
-- frame that drains the queue may be several studs later.
function Sounds.Push(kind, value)
	queue[#queue + 1] = {kind = kind, value = value, pos = feetPos()}
end

--------------------------------------------------------------------
-- INIT
--------------------------------------------------------------------

function Sounds.Init()
	if pool[1] then return end

	graph = Instance.new("Folder")
	graph.Name = "GlacierAudio"
	graph.Parent = SoundService

	deviceOut = Instance.new("AudioDeviceOutput")
	deviceOut.Name = "Output"
	deviceOut.Parent = graph

	listener = Instance.new("AudioListener")
	listener.Name = "Listener"
	listener.AudioInteractionGroup = "Default"
	trySet(listener, "AcousticSimulationEnabled", Config.snd_acousticSim ~= false)
	listener.Parent = Workspace.CurrentCamera
	wire(listener, deviceOut)

	-- ---- body emitter ----
	-- Parked on the Camera until the body exists, so the wiring below can be
	-- done once and never touched again -- Update just reparents the
	-- attachment when State.playerBody shows up.
	emitterAtt = Instance.new("Attachment")
	emitterAtt.Name = "GlacierAudioSource"
	emitterAtt.Parent = Workspace.CurrentCamera

	emitter = Instance.new("AudioEmitter")
	emitter.Name = "Emitter"
	emitter.AudioInteractionGroup = "Default"
	trySet(emitter, "AcousticSimulationEnabled", Config.snd_acousticSim ~= false)
	-- Short curve: these are your own sounds, they shouldn't fall off with
	-- distance in any meaningful way, but the emitter still needs a curve.
	emitter:SetDistanceAttenuation({[0] = 1, [20] = 1, [60] = 0})
	emitter.Parent = emitterAtt

	for i = 1, POOL_SIZE do
		local p = Instance.new("AudioPlayer")
		p.Name = "MoveSfx" .. i
		p.Volume = 1
		p.Parent = graph
		wire(p, emitter)
		pool[i] = p
	end

	-- in Init, after the pool
	runLoop = Instance.new("AudioPlayer")
	runLoop.Name = "MoveRunLoop"
	runLoop.Looping = true
	runLoop.Volume = 0
	runLoop.Parent = graph
	wire(runLoop, emitter)

	-- ---- world emitters ----
	-- One anchor part hosting every world attachment. CanQuery is off so it
	-- never shows up in a Blockcast sweep; AudioCanCollide is off so it never
	-- occludes anything.
	anchor = Instance.new("Part")
	anchor.Name = "GlacierAudioAnchors"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.CFrame = CFrame.new()  -- identity, so Attachment.Position IS world
	trySet(anchor, "AudioCanCollide", false)
	anchor.Parent = Workspace

	for i = 1, WORLD_POOL_SIZE do
		local att = Instance.new("Attachment")
		att.Name = "World" .. i
		att.Parent = anchor

		local em = Instance.new("AudioEmitter")
		em.Name = "Emitter"
		em.AudioInteractionGroup = "Default"
		trySet(em, "AcousticSimulationEnabled", Config.snd_acousticSim ~= false)
		em:SetDistanceAttenuation(curveFor(90))
		em.Parent = att

		local p = Instance.new("AudioPlayer")
		p.Name = "WorldSfx" .. i
		p.Volume = 1
		p.Parent = graph
		wire(p, em)

		worldPool[i] = {att = att, emitter = em, player = p, range = 90}
	end

	-- ---- relay receiver ----
	remote = ReplicatedStorage:WaitForChild("SoundFX", 10)
	if remote then
		print("[Sounds] Listening to",remote)
		remote.OnClientEvent:Connect(function(key, position, pitch, volScale)
			--print("\nReceived:",key,"\ndist:",math.floor((position - State.pos.Position).Magnitude),"\n")
			warn(position,State.pos.Position)
			Sounds.PlayAt(key, position, pitch, volScale)
		end)
	else
		warn("[Sounds] SoundFX remote missing -- relayed audio disabled")
	end
end

--------------------------------------------------------------------
-- UPDATE
--------------------------------------------------------------------
-- Falls back to these when the weapon doesn't define its own.
local DEFAULT_WEAPON_SOUNDS = {
	DryFire = { id = "rbxasset://sounds/action_get_up.mp3", volume = 0.3, pitch = 2.0 },
}

local function weaponSound(kind)
	local s = State.currentWeaponStats
	local def = s and s.sounds and s.sounds[kind]
	return def or DEFAULT_WEAPON_SOUNDS[kind]
end

-- Keeps the ear on the current Camera and the mouth on the current body.
-- Both can be swapped at runtime (respawn, spectate), so this is checked
-- rather than bound once.
local function followBody()
	local cam = Workspace.CurrentCamera
	if listener and cam and listener.Parent ~= cam then
		listener.Parent = cam
	end

	local body = State.playerBody
	if body and emitterAtt.Parent ~= body then
		emitterAtt.Parent = body
		-- Your own collision hull would otherwise occlude your own footsteps.
		trySet(body, "AudioCanCollide", false)
	end
	if body then
		emitterAtt.Position = Vector3.new(0, -body.Size.Y * 0.5 + 0.2, 0)
	end
end

local function crouchScale()
	return (State.isCrouching or State.isProne) and 0.4 or 1
end

local function playFootstep(speed)
	local key = SoundKeys.StepFor(State.groundMaterial)
	local id, def = pickSample(key)
	if not id then return end

	-- Quieter when crouched, louder the faster you move, with a little pitch
	-- scatter so a long run doesn't sound mechanical.
	local walk = Config.sv_maxspeed
	local vol = math.clamp(speed / walk, 0.25, 1.2) * crouchScale()

	play(id, vol * (Config.cl_footstepVolume or 0.5), 0.9 + math.random() * 0.2)
end

function Sounds.Update(deltaTime)
	--print("SND update, pool:", pool[1] ~= nil, "queued:", #queue)
	if not pool[1] then return end

	followBody()

	local vel = State.velocity or Vector3.zero
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude

	-- ---- discrete events ----
	for _, e in ipairs(queue) do
		if e.kind == "jump" then
			local pitch = 0.95 + math.random() * 0.1
			play(JUMP_SOUND_FALLBACK or select(1, pickSample("jump")),
				Config.cl_jumpVolume or 0.5, pitch)
			Sounds.Broadcast("jump", e.pos, pitch, 1)

		elseif e.kind == "land" then

			-- Scale with impact so a hop off a kerb and a long fall differ.
			local impact = math.abs(e.value or 0)
			local ref = Config.sv_jump_impulse
			local t = math.clamp(impact / (ref * 2), 0, 1)
			if impact > ref * 0.3 then
				local pitch = 1.1 - t * 0.3
				local id = select(1, pickSample("land"))
				play(id, (Config.cl_landVolume or 0.6) * (0.3 + t), pitch)
				Sounds.Broadcast("land", e.pos, pitch, 0.3 + t)
			end
			-- A landing resets the stride so the next footstep isn't
			-- immediate -- otherwise landing mid-stride double-taps.
			strideAccum = 0

		elseif e.kind == "weapon" then
			local def = weaponSound(e.value)
			if def then
				local var = def.pitchVar or 0
				local pitch = (def.pitch or 1) + (math.random() - 0.5) * 2 * var
				play(def.id, (def.volume or 0.5) * (Config.cl_weaponVolume or 1), pitch)
				-- Weapon modules carry a netKey so others hear the gunshot at
				-- its full range rather than the viewmodel's close mix.
				if def.netKey then
					Sounds.Broadcast(def.netKey, e.pos, pitch, 1)
				end
			end
		end
	end
	table.clear(queue)

	-- ---- footsteps ----
	-- Distance-based, like GoldSrc: the interval falls out of speed rather
	-- than being a timer, so steps stay in sync whether you walk or sprint.
	local silent = Config.cl_silentCrouch
		and (State.isCrouching or State.isProne or State.isWalking)

	-- Network stride. Your own feet run off a pitched loop, but remote
	-- listeners need discrete events, so accumulate distance and fire one
	-- step per stride length. This is what strideAccum was always for.
	if State.isGrounded and speed > 1 then
		strideAccum += speed * deltaTime
		local strideLen = Config.cl_strideLength or 4.5
		while strideAccum >= strideLen do
			strideAccum -= strideLen
			if not silent then
				Sounds.Broadcast(
					SoundKeys.StepFor(State.groundMaterial),
					feetPos(),
					0.9 + math.random() * 0.2,
					math.clamp(speed / Config.sv_maxspeed, 0.3, 1) * crouchScale())
			end
		end
	else
		strideAccum = 0
	end

	if Config.cl_footstepLoop then
		local moving = State.isGrounded and speed > 1
		local key = SoundKeys.StepFor(State.groundMaterial)
		local def = SoundKeys.Defs[key]
		local loopId = def and def.ids[1]

		if moving then

			if silent then
				if runLoop.IsPlaying then runLoop:Stop() end
				return
			end

			if runLoop.Asset ~= loopId then
				runLoop.Asset = loopId
				runLoop:Play()
			elseif not runLoop.IsPlaying then
				runLoop:Play()
			end
			-- Pitch tracks speed so the stride rate matches how fast you move.
			local ratio = (speed / Config.sv_maxspeed) * (Config.cl_footstepRatio or 1)
			runLoop.PlaybackSpeed = math.clamp(0.85 + ratio * 0.25, 0.85, 10.25)
			local vol = math.clamp(speed / Config.sv_maxspeed, 0.3, 1) * crouchScale()
			runLoop.Volume = math.clamp(
				vol * (Config.cl_footstepVolume or 0.5) * (Config.volume or 1), 0, 10)
		else
			if runLoop.IsPlaying then runLoop:Stop() end
		end
	end
end

return Sounds