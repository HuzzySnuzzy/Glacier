-- ModuleScript: Visuals  (R6)
-- Third-person puppet, camera, first-person viewmodel, and remote puppets.
--
-- Animation replication is STATE-based, not event-based: the current
-- locomotion state rides along in the PuppetSync packet that already fires
-- every frame. A dropped packet then costs one frame instead of leaving a
-- puppet stuck in the wrong animation until its next state change.
-- AnimationSync carries only genuine one-shots (Jump, Fire, Reload).
--
-- RECOIL: Visuals is a pure CONSUMER. It reads State.recoilViewPunch, which
-- Weapons.PreRender publishes earlier in the same frame, and never computes,
-- scales, or writes recoil itself. It also never reads the recoil cvars --
-- view_ratio and view_punch_extra are already folded in upstream, and applying
-- them a second time here would square the scaling.
--
-- FRAME ORDER (set in Player):
--   Weapons.PreRender(dt)   -- publishes State.recoilViewPunch
--   Visuals.Update(dt)      -- builds the camera from it
--   Weapons.Update(dt)      -- fire/reload state machine

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config   = require(ReplicatedStorage:WaitForChild("Config"))
local AnimDefs = require(ReplicatedStorage:WaitForChild("AnimDefs"))
local State    = require(script.Parent.State)
local Sounds   = require(script.Parent.Sounds)
local ViewBob  = require(script.Parent.ViewBob)
local ViewSway = require(script.Parent.ViewSway)
local Inventory = require(ReplicatedStorage:WaitForChild("Inventory"))
local WeaponRegistry = require(ReplicatedStorage:WaitForChild("WeaponRegistry"))

local cam = workspace.CurrentCamera

local AnimationSync    = ReplicatedStorage:WaitForChild("AnimationSync", 10)
local EquipWeaponEvent = ReplicatedStorage:WaitForChild("EquipWeaponEvent", 10)

if not AnimationSync then
	warn("[Visuals] AnimationSync missing -- one-shots will not replicate.")
end

local Visuals = {}

--=====================================================================
-- CONSTANTS
--=====================================================================

local GRIP_PART   = "Right Arm"
local GRIP_ATT    = "RightGripAttachment"
local GRIP_OFFSET = Vector3.new(0, -1, 0)

local vmParts = {}
local vmConnections = {}
local puppetOneShot = nil

local function cacheViewmodelParts(vm)
	for _, c in ipairs(vmConnections) do c:Disconnect() end
	table.clear(vmConnections)
	table.clear(vmParts)

	for _, d in ipairs(vm:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			table.insert(vmParts, d)
			table.insert(vmConnections,
				d:GetPropertyChangedSignal("CanCollide"):Connect(function()
					if d.CanCollide then d.CanCollide = false end
				end))
		end
	end
end

local function renderPosition(body)
	local cur, prev = State.curBodyPos, State.prevBodyPos
	if not (cur and prev) or State.snapRender then
		State.snapRender = false
		return body.Position
	end
	return prev:Lerp(cur, State.tickAlpha)
end
--=====================================================================
-- PUBLIC STATE
--=====================================================================

Visuals.currentPuppet      = nil
Visuals.renderedPuppetSlot = -1
Visuals.renderedVmSlot     = -1
Visuals.renderedPuppetRev  = -1 
Visuals.renderedVmRev      = -1
Visuals.puppetGripAtt      = nil

-- Hysteresis band. Without the gap, Walk/Idle flaps during friction decay.
Visuals.moveThreshold      = 0.5   -- stop moving below this
Visuals.moveThresholdHigh  = 1.5   -- start moving above this
Visuals.lastMoving         = false

-- STUDS PER SECOND, not per frame. Weapons feeds this straight into
-- Recoil.inaccuracy against weapon.accuracy.maxSpeed, so the unit matters:
-- per-frame values would make the movement penalty round to nothing.
Visuals.lastSpeed          = 0
Visuals.lastSpeedSource    = "none"

-- Read by CustomController and sent in the PuppetSync packet.
Visuals.lastTargetState    = "Idle"
Visuals.lastAnimSpeed      = 1

-- Set by Player to Weapons.OnEquipped. A direct require would be circular
-- (Weapons already requires Visuals), and without this the recoil index and
-- ammo state survive a weapon switch.
Visuals.onWeaponEquipped   = nil



--=====================================================================
-- HELPERS
--=====================================================================


local weaponStatsCache = {}
local weaponNameIndex  = nil   -- lowercased instance name -> real instance name

-- Weapon modules carry a lowercase `name` field ("ak47") while the
-- ModuleScript itself is "AK47". That lowercase value is what rides in the
-- PuppetSync and AnimationSync packets, and FindFirstChild is case-sensitive,
-- so a direct lookup misses and every remote puppet ends up with an empty
-- weapon track set. Resolve case-insensitively instead of forcing every
-- weapon module to rename (netKey strings are derived from `name`).
local function resolveWeaponInstance(name)
	local folder = ReplicatedStorage:FindFirstChild("Weapons")
	if not folder then return nil end

	local direct = folder:FindFirstChild(name)
	if direct and direct:IsA("ModuleScript") then return direct end

	if not weaponNameIndex then
		weaponNameIndex = {}
		for _, m in ipairs(folder:GetChildren()) do
			if m:IsA("ModuleScript") then
				weaponNameIndex[m.Name:lower()] = m
			end
		end
	end

	local hit = weaponNameIndex[name:lower()]
	return (hit and hit.Parent) and hit or nil
end

local function statsFor(name)
	return WeaponRegistry.Stats(name)
end

local warned = {}
local function warnOnce(key, msg, ...)
	if warned[key] then return end
	warned[key] = true
	warn("[Visuals] " .. msg:format(...))
end

function Visuals.ResetWarnings()
	warned = {}
end

local function getAnimator(model)
	if not model then return nil end
	local holder = model:FindFirstChildOfClass("Humanoid")
		or model:FindFirstChildOfClass("AnimationController")
	if not holder then return nil end

	local animator = holder:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = holder
	end
	return animator
end

local function trackAlive(track)
	return track ~= nil and typeof(track) == "Instance" and track:IsA("AnimationTrack")
end

-- Base (unscaled) speed per track, so a timescale change can re-derive the
-- correct rate without the caller re-supplying it.
local baseSpeed = {}

local function safePlay(track, fade, key)
	if not trackAlive(track) then return false end
	local ok, err = pcall(track.Play, track, fade or 0.15)
	if not ok then
		warnOnce("play_" .. tostring(key), "Play failed on %s: %s", tostring(key), tostring(err))
		return false
	end
	-- One-shots (Fire, Reload, Equip) never call safeSpeed, so they'd play at
	-- real time. Cycle tracks get overwritten by the safeSpeed call that
	-- follows, so this is harmless there.
	baseSpeed[track] = baseSpeed[track] or 1
	pcall(track.AdjustSpeed, track, baseSpeed[track] * (State.timeScale or 1))
	return true
end

local function safeStop(track, fade)
	if not trackAlive(track) then return end
	pcall(track.Stop, track, fade or 0.15)
end

local function safeSpeed(track, speed)
	if not trackAlive(track) then return end
	local base = speed or 1
	baseSpeed[track] = base
	pcall(track.AdjustSpeed, track, base * (State.timeScale or 1))
end

local function loadTrackSet(animator, defs, defaultPriority)
	local out = {}
	if not (animator and defs) then return out end

	for name, def in pairs(defs) do
		if type(def.id) ~= "string" or def.id == "" then
			-- Deliberate stub; skip silently.
		elseif not def.id:match("^rbxassetid://%d+$") then
			warnOnce("malformed_" .. name, "Malformed AnimationId for '%s': %s", name, tostring(def.id))
		else
			local anim = Instance.new("Animation")
			anim.AnimationId = def.id
			local ok, track = pcall(animator.LoadAnimation, animator, anim)

			if ok and track then
				if def.looped ~= nil then track.Looped = def.looped end
				pcall(function() track.Priority = def.priority or defaultPriority end)
				out[name] = track

				local capturedName, capturedId = name, def.id
				task.delay(5, function()
					if trackAlive(track) and track.Length == 0 then
						warnOnce("badasset_" .. capturedName,
							"'%s' (%s) never loaded -- wrong owner, deleted asset, or restricted.",
							capturedName, capturedId)
					end
				end)
			else
				warnOnce("load_" .. name, "LoadAnimation failed for '%s' (%s): %s",
					name, def.id, tostring(track))
			end
		end
	end
	return out
end

local function playPuppetOneShot(track, fade)
	if not trackAlive(track) then return false end

	if puppetOneShot ~= track then
		safeStop(puppetOneShot, 0.05)
	end

	pcall(function() track.TimePosition = 0 end)
	if safePlay(track, fade or 0.05, "puppetOneShot") then
		puppetOneShot = track
		return true
	end
	return false
end

local function stripPhysics(model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery   = false
			d.CanTouch   = false
			d.CastShadow = false
			d.Massless   = true
		end
	end
end

local function weaponNameForSlot(slot)
	local item = Inventory.Get(State, slot)
	return item and item.class or nil
end





local lastAppliedScale = 1

local function rescaleSet(set)
	if type(set) ~= "table" then return end
	for _, t in pairs(set) do
		if trackAlive(t) then
			pcall(t.AdjustSpeed, t, (baseSpeed[t] or 1) * (State.timeScale or 1))
		end
	end
end

--=====================================================================
-- RIG PREP
--=====================================================================

local function prepareR6Rig(puppet)
	local root = puppet.PrimaryPart or puppet:FindFirstChild("HumanoidRootPart")

	for _, d in ipairs(puppet:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored   = (d == root)
			d.CanCollide = false
			d.CanQuery   = false
			d.CanTouch   = false
			d.Massless   = (d ~= root)
		end
	end

	local humanoid = puppet:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.RequiresNeck = false
		humanoid.BreakJointsOnDeath = false
		humanoid.EvaluateStateMachine = false
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end

	local motorCount = 0
	for _, d in ipairs(puppet:GetDescendants()) do
		if d:IsA("Motor6D") then motorCount += 1 end
	end
	if motorCount < 6 then
		warnOnce("motors", "Only %d Motor6D(s) on the puppet -- R6 needs 6. Limbs will not animate.", motorCount)
	end
end

local function ensureGripAttachment(puppet)
	local limb = puppet:FindFirstChild(GRIP_PART)
	if not limb then return nil end

	local att = limb:FindFirstChild(GRIP_ATT)
	if not att then
		att = Instance.new("Attachment")
		att.Name = GRIP_ATT
		att.Position = GRIP_OFFSET
		att.Parent = limb
	end
	return att
end

--=====================================================================
-- SETUP
--=====================================================================

function Visuals.SetupPuppet(puppet)
	Visuals.currentPuppet = puppet

	if not puppet:IsDescendantOf(workspace) then
		while not puppet:IsDescendantOf(workspace) do task.wait() end
	end

	local animate = puppet:FindFirstChild("Animate")
	if animate then animate:Destroy() end

	local animator = getAnimator(puppet)
	if not animator then
		warnOnce("no_animator", "Puppet has no Humanoid or AnimationController.")
		State.tracks = {}
		State.currentTrack = nil
		return
	end

	pcall(prepareR6Rig, puppet)

	safeStop(State.currentTrack, 0)
	safeStop(State.currentPuppetOverlay, 0)
	safeStop(puppetOneShot, 0)   
	puppetOneShot = nil          
	
	State.tracks = loadTrackSet(animator, AnimDefs.PUPPET, Enum.AnimationPriority.Movement)
	State.puppetWeaponTracks = loadTrackSet(animator,
		AnimDefs.WeaponSet(State.currentWeaponStats, Config.cl_sharedWeaponAnims),
		Enum.AnimationPriority.Action2)

	State.currentTrack = nil
	State.currentPuppetOverlay = nil

	local _, grip = pcall(ensureGripAttachment, puppet)
	Visuals.puppetGripAtt = grip
	Visuals.renderedPuppetSlot = -1
end

local clothingApplied = false

local function applyViewmodelClothing(viewmodel)
	local src = Visuals.currentPuppet
	if not (src and viewmodel) then return false end

	local shirt = src:FindFirstChildWhichIsA("Shirt")
	local pants = src:FindFirstChildWhichIsA("Pants")
	local colors = src:FindFirstChild("Body Colors")

	-- Clothing arrives asynchronously via ApplyDescription, so the viewmodel
	-- can be built before it exists. Retry until something shows up.
	if not (shirt or pants or colors) then return false end

	if shirt and not viewmodel:FindFirstChildWhichIsA("Shirt") then
		shirt:Clone().Parent = viewmodel
	end
	if pants and not viewmodel:FindFirstChildWhichIsA("Pants") then
		pants:Clone().Parent = viewmodel
	end
	if colors then
		local existing = viewmodel:FindFirstChild("Body Colors")
		if existing then existing:Destroy() end
		colors:Clone().Parent = viewmodel
	end

	return true
end

function Visuals.SetupViewmodel(viewmodel)
	local animator = getAnimator(viewmodel)
	if not animator then return end

	-- Match the player's own appearance so the arms look like their character.
	local src = Visuals.currentPuppet
	if src then
		clothingApplied = applyViewmodelClothing(viewmodel)

		local colors = src:FindFirstChild("Body Colors")
		if colors then
			local existing = viewmodel:FindFirstChild("Body Colors")
			if existing then existing:Destroy() end
			colors:Clone().Parent = viewmodel
		end
	end

	State.vmTracks = loadTrackSet(animator, AnimDefs.VIEWMODEL, Enum.AnimationPriority.Movement)
	State.vmWeaponTracks = loadTrackSet(animator,
		(State.currentWeaponStats and State.currentWeaponStats.viewmodelAnims) or {},
		Enum.AnimationPriority.Action2)

	local idle = State.vmTracks.Idle
	if idle then
		State.currentVmTrack = idle
		safePlay(idle, 0, "Idle")
	end
	
	ViewSway.Reset()
end

--=====================================================================
-- TRACK SWITCHING
--=====================================================================

local vmOneShot = nil

local function playVmOneShot(track, fade)
	if not trackAlive(track) then return false end
	safeStop(vmOneShot, 0.05)
	pcall(function() track.TimePosition = 0 end)
	if safePlay(track, fade or 0.05, "oneshot") then
		vmOneShot = track
		return true
	end
	return false
end

function Visuals.PlayVmOneShot(name, fade)
	local track = State.vmWeaponTracks and State.vmWeaponTracks[name]
	if not track then return false end
	return playVmOneShot(track, fade)
end

local function switchTrack(nextTrack, fade)
	if not trackAlive(nextTrack) then return false end
	if State.currentTrack == nextTrack then return false end

	safeStop(State.currentTrack, fade)
	if safePlay(nextTrack, fade, "puppet") then
		State.currentTrack = nextTrack
		return true
	end
	State.currentTrack = nil
	return false
end

local function switchVmTrack(nextTrack, fade)
	if not trackAlive(nextTrack) then return false end
	if State.currentVmTrack == nextTrack then return false end

	safeStop(State.currentVmTrack, fade)
	if safePlay(nextTrack, fade, "vm") then
		State.currentVmTrack = nextTrack
		return true
	end
	State.currentVmTrack = nil
	return false
end

local function setVmOverlay(track, fade)
	if State.currentVmOverlay == track then return end
	safeStop(State.currentVmOverlay, fade or 0.15)
	State.currentVmOverlay = nil
	if safePlay(track, fade or 0.15, "vmOverlay") then
		State.currentVmOverlay = track
	end
end

local function setPuppetOverlay(track, fade)
	if State.currentPuppetOverlay == track then return end
	safeStop(State.currentPuppetOverlay, fade or 0.15)
	State.currentPuppetOverlay = nil
	if safePlay(track, fade or 0.15, "puppetOverlay") then
		State.currentPuppetOverlay = track
	end
end

-- One-shots only. Continuous state rides in the PuppetSync packet.
local function syncOneShot(trackName)
	if not (AnimationSync and trackName) then return end
	AnimationSync:FireServer({
		track = trackName,
		weapon = State.currentWeaponStats and State.currentWeaponStats.name or nil,
	})
end

--=====================================================================
-- LOCOMOTION
--=====================================================================

local function walkRatio(speed)
	return math.clamp(speed / math.max(Config.mv_walkSpeed or 16, 0.01), 0.1, 2)
end

local function isCycleState(name)
	return name == "Walk" or name == "Sprint" or name == "CrouchWalk"
end

local function updateLocomotion(speed, isMoving)
	local tracks = State.tracks
	if not tracks or not tracks.Idle then return end

	local isGrounded = State.isGrounded
	if isGrounded == nil then
		isGrounded = math.abs((State.velocity or Vector3.zero).Y) < 1.0
	end

	-- ---- decide the state ----
	local targetState = "Idle"

	if not isGrounded then
		targetState = "Fall"
	elseif State.isProne and tracks.Prone then
		targetState = "Prone"
	elseif State.isCrouching then
		targetState = isMoving and "CrouchWalk" or "CrouchIdle"
	elseif isMoving then
		targetState = (State.isWalking and tracks.Walk) and "Walk"
			or (State.isSprinting and tracks.Sprint) and "Sprint"
			or "Walk"
	end

	local ratio = isCycleState(targetState) and walkRatio(speed) or 1

	-- Published for the PuppetSync packet.
	Visuals.lastTargetState = targetState
	Visuals.lastAnimSpeed = ratio

	-- ---- puppet base layer ----
	local nextTrack = tracks[targetState]
	if not nextTrack then
		warnOnce("missing_" .. targetState, "No '%s' track -- falling back to Idle.", targetState)
		nextTrack, targetState = tracks.Idle, "Idle"
	end

	switchTrack(nextTrack, 0.15)
	if isCycleState(targetState) then
		safeSpeed(nextTrack, ratio)
	end

	-- ---- puppet weapon layer ----
	-- Same state name at higher priority. It keys only the right shoulder and
	-- the grip, so joints it omits fall through to the base track underneath.
	local pwt = State.puppetWeaponTracks
	if pwt then
		local track = pwt[targetState] or pwt.Idle
		if track then
			setPuppetOverlay(track, 0.15)
			if isCycleState(targetState) then safeSpeed(track, ratio) end
		end
	end

	-- ---- viewmodel base layer ----
	local vmTracks = State.vmTracks
	if vmTracks and vmTracks.Idle then
		local vmTarget = targetState
		if not vmTracks[vmTarget] then
			vmTarget = (vmTarget == "Sprint" or vmTarget == "CrouchWalk") and "Walk" or "Idle"
			if not vmTracks[vmTarget] then vmTarget = "Idle" end
		end

		local nextVm = vmTracks[vmTarget]
		switchVmTrack(nextVm, 0.15)
		if isCycleState(vmTarget) then safeSpeed(nextVm, ratio) end

		-- ---- viewmodel weapon layer ----
		local wt = State.vmWeaponTracks
		if wt then
			-- A one-shot (equip, reload, fire) owns the arms while it plays.
			local busy = trackAlive(vmOneShot) and vmOneShot.IsPlaying
			if not busy then
				local weaponTrack = wt[vmTarget] or wt.Idle
				if weaponTrack then
					setVmOverlay(weaponTrack, 0.15)
					if isCycleState(vmTarget) then safeSpeed(weaponTrack, ratio) end
				end
			end
		end
	end
end

--=====================================================================
-- REMOTE PUPPETS
--=====================================================================

local remoteState = {}

local function applyTimescaleToTracks()
	local ts = State.timeScale or 1
	if ts == lastAppliedScale then return end
	lastAppliedScale = ts

	rescaleSet(State.tracks)
	rescaleSet(State.puppetWeaponTracks)
	rescaleSet(State.vmTracks)
	rescaleSet(State.vmWeaponTracks)
	for _, entry in pairs(remoteState) do
		rescaleSet(entry.base)
		rescaleSet(entry.weaponTracks)
	end
end

-- Tracks are not garbage-collected promptly and the Animator caps at 64, so
-- a set must be explicitly torn down before its replacement is loaded.
local function destroyTrackSet(set)
	if type(set) ~= "table" then return end
	for _, t in pairs(set) do
		if trackAlive(t) then
			pcall(t.Stop, t, 0)
			pcall(t.Destroy, t)
		end
		baseSpeed[t] = nil
	end
end

-- Weak keys let the GC drop entries whose puppet is still alive, which
-- silently reloads every track set. Clean up on death instead.
local function forgetRemote(puppet)
	local entry = remoteState[puppet]
	if not entry then return end
	if entry.conn then entry.conn:Disconnect() end
	destroyTrackSet(entry.base)
	destroyTrackSet(entry.weaponTracks)
	remoteState[puppet] = nil
end

local function remoteSetFor(puppet, weaponName)
	local entry = remoteState[puppet]
	local animator = getAnimator(puppet)
	if not animator then return nil end

	if not entry then
		entry = {
			weapon = "\0",   -- sentinel: never equal to a real name or nil
			base = loadTrackSet(animator, AnimDefs.PUPPET, Enum.AnimationPriority.Movement),
			weaponTracks = {},
			currentBase = nil,
			currentOverlay = nil,
		}
		remoteState[puppet] = entry

		-- Connected ONCE, at creation. This used to be connected on every
		-- call, so a 60Hz PuppetSync stream leaked 60 connections a second
		-- per remote player and fired forgetRemote hundreds of times on death.
		entry.conn = puppet.AncestryChanged:Connect(function(_, parent)
			if not parent then forgetRemote(puppet) end
		end)
	end

	if entry.weapon ~= weaponName then
		safeStop(entry.currentOverlay, 0.1)
		entry.currentOverlay = nil
		destroyTrackSet(entry.weaponTracks)
		entry.weapon = weaponName
		entry.weaponTracks = loadTrackSet(animator,
			AnimDefs.WeaponSet(statsFor(weaponName), Config.cl_sharedWeaponAnims),
			Enum.AnimationPriority.Action2)
	end

	return entry
end

-- Called every PuppetSync packet. Idempotent: re-sending the same state does
-- nothing, so a dropped packet self-corrects on the next one.
function Visuals.ApplyRemoteState(puppet, stateName, animSpeed, weaponName)
	if not (puppet and stateName) then return end

	local entry = remoteSetFor(puppet, weaponName)
	if not entry then return end

	local base = entry.base[stateName] or entry.base.Idle
	if base and entry.currentBase ~= base then
		safeStop(entry.currentBase, 0.15)
		if safePlay(base, 0.15, "remoteBase") then
			entry.currentBase = base
		end
	end
	if base and isCycleState(stateName) then
		safeSpeed(base, animSpeed or 1)
	end

	local overlay = entry.weaponTracks[stateName] or entry.weaponTracks.Idle
	if overlay and entry.currentOverlay ~= overlay then
		safeStop(entry.currentOverlay, 0.15)
		if safePlay(overlay, 0.15, "remoteOverlay") then
			entry.currentOverlay = overlay
		end
	end
	if overlay and isCycleState(stateName) then
		safeSpeed(overlay, animSpeed or 1)
	end
end

-- One-shots from AnimationSync. These interrupt, then hand back to state.
function Visuals.PlayRemoteOneShot(puppet, name, weaponName)
	if not (puppet and name) then return end

	local entry = remoteSetFor(puppet, weaponName)
	if not entry then return end

	local track = entry.weaponTracks[name] or entry.base[name]
	if not trackAlive(track) then return end

	safeStop(entry.currentOneShot, 0.05)
	pcall(function() track.TimePosition = 0 end)
	if safePlay(track, 0.05, "remoteOneShot") then
		entry.currentOneShot = track
	end
end

--=====================================================================
-- SPEED SOURCING
--=====================================================================

local lastBodyPos = nil
local measuredSpeed = 0

-- Returns studs per second. Weapons uses this for movement inaccuracy, so the
-- unit contract matters more than it does for animation playback rates.
local function getHorizontalSpeed(body, deltaTime)
	local stateVel = State.velocity
	if typeof(stateVel) == "Vector3" then
		local flat = Vector3.new(stateVel.X, 0, stateVel.Z).Magnitude
		if flat > 0.01 then
			lastBodyPos = body.Position
			return flat, "State.velocity"
		end
	end

	local pos = body.Position
	if lastBodyPos and deltaTime > 0 then
		local delta = Vector3.new(pos.X - lastBodyPos.X, 0, pos.Z - lastBodyPos.Z)
		local raw = delta.Magnitude / deltaTime
		measuredSpeed = measuredSpeed + (raw - measuredSpeed) * math.min(deltaTime * 15, 1)
	end
	lastBodyPos = pos

	return measuredSpeed, "positionDelta"
end

--=====================================================================
-- WEAPONS
--=====================================================================

local function loadWeaponStats(weaponName)
	local s = statsFor(weaponName)
	if s then
		State.currentWeaponStats = s
		State.currentAmmo = s.magSize
		State.reserveAmmo = s.maxReserve
	else
		State.currentWeaponStats = nil
		State.currentAmmo, State.reserveAmmo = 0, 0
	end
	State.isReloading = false
end

-- Was: reset currentAmmo to s.magSize on every equip. That is the ammo-reset
-- bug -- it treated a full magazine as a property of the weapon CLASS rather
-- than of the instance the player is carrying.
local function loadActiveWeapon()
	local item = Inventory.Active(State)

	if not item then
		State.currentWeaponStats = nil
		State.currentAmmo, State.reserveAmmo = 0, 0
		State.isReloading = false
		return
	end

	State.currentWeaponStats = Inventory.Stats(item)
	Inventory.Pull(State)   -- ammo comes FROM the item, not from magSize

	-- Reload progress is deliberately not preserved. Swapping out of a reload
	-- cancels it in CS, and a half-elapsed reloadEndTime would resume against
	-- a stale clock anyway.
	State.isReloading = false
end

local function updatePuppetWeapon()
	local rev = State.inventoryRev or 0
	if Visuals.renderedPuppetSlot == State.activeSlot
		and Visuals.renderedPuppetRev == rev then
		return
	end

	-- Flush the OUTGOING weapon before the active slot moves. Inventory.Push
	-- reads the ACTIVE item, so this has to happen while activeSlot still
	-- points at the old one -- hence the guard on renderedPuppetSlot rather
	-- than just calling Push unconditionally.
	if Visuals.renderedPuppetSlot >= 0
		and Visuals.renderedPuppetSlot ~= State.activeSlot then
		local prev = State.activeSlot
		State.activeSlot = Visuals.renderedPuppetSlot
		Inventory.Push(State)
		State.activeSlot = prev
	end

	Visuals.renderedPuppetSlot = State.activeSlot
	Visuals.renderedPuppetRev  = rev

	loadActiveWeapon()

	-- Hand off to Weapons so the recoil index, reload flag and next-fire gate
	-- reset with the slot.
	if type(Visuals.onWeaponEquipped) == "function" then
		pcall(Visuals.onWeaponEquipped, State.currentWeaponStats)
	end

	if EquipWeaponEvent then
		EquipWeaponEvent:FireServer(weaponNameForSlot(State.activeSlot) or "")
	end

	local animator = getAnimator(State.playerPuppet)
	if animator then
		safeStop(State.currentPuppetOverlay, 0.1)
		State.currentPuppetOverlay = nil
		safeStop(puppetOneShot, 0.1)
		puppetOneShot = nil
		destroyTrackSet(State.puppetWeaponTracks)
		State.puppetWeaponTracks = loadTrackSet(animator,
			AnimDefs.WeaponSet(State.currentWeaponStats, Config.cl_sharedWeaponAnims),
			Enum.AnimationPriority.Action2)
	end
end

local function updateViewmodelWeapon(viewmodel)
	local rev = State.inventoryRev or 0
	if Visuals.renderedVmSlot == State.activeSlot
		and Visuals.renderedVmRev == rev then
		return
	end

	local vmHand = viewmodel:FindFirstChild("Right Arm")
	if not vmHand then return end

	Visuals.renderedVmSlot = State.activeSlot
	Visuals.renderedVmRev  = rev

	local old = viewmodel:FindFirstChild("LocalWeapon")
	if old then old:Destroy() end

	local targetWeapon = weaponNameForSlot(State.activeSlot)
	if not targetWeapon or targetWeapon == "" then return end

	-- Registry, not a raw FindFirstChild: targetWeapon is now guaranteed to be
	-- the canonical class, but routing through Model() keeps the one lookup
	-- rule in one place when pickups start naming things.
	local template = WeaponRegistry.Model(targetWeapon)
	if not template then return end

	local weapon = template:Clone()
	weapon.Name = "LocalWeapon"
	weapon.Parent = viewmodel
	stripPhysics(weapon)
	cacheViewmodelParts(viewmodel)   -- re-cache: the weapon's parts are new

	local handle = weapon.PrimaryPart
	if not handle then
		warnOnce("no_primary_" .. targetWeapon, "'%s' has no PrimaryPart.", targetWeapon)
		return
	end

	local armGrip = vmHand:FindFirstChild(GRIP_ATT)
	local weaponGrip = handle:FindFirstChild("GripAttachment")
	if not (armGrip and weaponGrip) then
		warnOnce("no_grip_" .. targetWeapon, "Missing grip attachment for '%s'.", targetWeapon)
		return
	end

	-- Motor6D, not RigidConstraint: only Motor6Ds are animatable, and the
	-- joint name is what the Animation Editor keys against.
	local grip = Instance.new("Motor6D")
	grip.Name  = "WeaponGrip"
	grip.Part0 = vmHand
	grip.Part1 = handle
	grip.C0 = armGrip.CFrame
	grip.C1 = weaponGrip.CFrame
	grip.Parent = vmHand

	-- Weapon poses live on the weapon module, so the set is rebuilt per swap.
	local animator = getAnimator(viewmodel)
	if animator then
		safeStop(State.currentVmTrack, 0.1)
		safeStop(State.currentVmOverlay, 0.1)
		State.currentVmTrack = nil
		State.currentVmOverlay = nil
		vmOneShot = nil
		destroyTrackSet(State.vmTracks)
		destroyTrackSet(State.vmWeaponTracks)
		State.vmTracks = loadTrackSet(animator, AnimDefs.VIEWMODEL, Enum.AnimationPriority.Movement)
		State.vmWeaponTracks = loadTrackSet(animator,
			(State.currentWeaponStats and State.currentWeaponStats.viewmodelAnims) or {},
			Enum.AnimationPriority.Action2)

		local idle = State.vmTracks.Idle
		if idle then
			State.currentVmTrack = idle
			safePlay(idle, 0.1, "Idle")
		end
	end

	if State.vmWeaponTracks and State.vmWeaponTracks.Equip then
		Sounds.Push("weapon", "Equip")
		Visuals.PlayAnim("Equip", 0)
	end

	-- Gate firing on a config value rather than the animation length: a draw
	-- animation usually runs longer than the point you can realistically
	-- shoot from, and CS sets deploy time independently for the same reason.
	local s = State.currentWeaponStats
	State.equipEndTime = State.gameTime + ((s and s.equipTime) or 0)
end

--=====================================================================
-- VIEWMODEL
--=====================================================================

--=====================================================================
-- WALL PUSHBACK
--=====================================================================
-- Source keeps the viewmodel out of geometry by giving it its own depth
-- range. Roblox has no such thing, so the gun is retracted along the
-- camera's forward axis instead until the muzzle clears the obstruction.
--
-- Measurement point is MuzzleAttachment on the barrel. Models without one
-- (knives) fall back to the most-forward corner of the weapon's bounding
-- box, so the attachment is an accuracy upgrade, not a requirement.
--
-- The viewmodel lives under Camera, not workspace, so it can never be hit
-- by the cast. Only the local body and puppet need excluding.

local MUZZLE_ATT = "MuzzleAttachment"

local vmPushback     = 0     -- smoothed, studs
local vmMuzzleWeapon = nil   -- LocalWeapon instance the cache was built from
local vmMuzzleAtt    = nil
local vmMuzzleLocal  = nil   -- fallback offset, relative to the vm pivot

local pushParams = RaycastParams.new()
pushParams.FilterType       = Enum.RaycastFilterType.Exclude
pushParams.IgnoreWater      = true
pushParams.RespectCanCollide = true

local pushFilterBody, pushFilterPuppet, pushFilterDrops

-- pushParams has RespectCanCollide set, and a dropped weapon's hull collides --
-- so without this, walking over a rifle on the floor retracts your viewmodel as
-- if you had put the muzzle against a wall. Resolved lazily: the server owns
-- the folder, and a map reload replaces it.
local function dropsFolder()
	if pushFilterDrops and pushFilterDrops.Parent then return pushFilterDrops end
	return workspace:FindFirstChild("WeaponDrops")
end

local function refreshPushFilter()
	local body, puppet = State.playerBody, State.playerPuppet
	local drops = dropsFolder()
	if body == pushFilterBody and puppet == pushFilterPuppet and drops == pushFilterDrops then
		return
	end
	pushFilterBody, pushFilterPuppet, pushFilterDrops = body, puppet, drops

	local list = {}
	if body   then table.insert(list, body)   end
	if puppet then table.insert(list, puppet) end
	if drops  then table.insert(list, drops)  end
	pushParams.FilterDescendantsInstances = list
end

-- Most-forward corner of the model, in pivot space. -Z is forward.
local function measureFallbackOffset(vm, weapon)
	local ok, cf, size = pcall(weapon.GetBoundingBox, weapon)
	if not ok or not cf then return CFrame.new(0, 0, -2) end

	local pivot = vm:GetPivot()
	local best, bestZ = nil, math.huge
	for x = -1, 1, 2 do
		for y = -1, 1, 2 do
			for z = -1, 1, 2 do
				local world = cf:PointToWorldSpace(size * Vector3.new(x, y, z) * 0.5)
				local lp = pivot:PointToObjectSpace(world)
				if lp.Z < bestZ then bestZ, best = lp.Z, lp end
			end
		end
	end
	return CFrame.new(best or Vector3.new(0, 0, -2))
end

-- Returns studs to retract. desiredPivot is the UNPUSHED pose: measuring
-- against the pushed one would feed the result back into its own input and
-- oscillate.
local function pushbackOffset(vm, desiredPivot, deltaTime)
	if Config.vm_pushback == false then
		vmPushback = 0
		return 0
	end

	local weapon = vm:FindFirstChild("LocalWeapon")
	if weapon ~= vmMuzzleWeapon then
		vmMuzzleWeapon, vmMuzzleAtt, vmMuzzleLocal = weapon, nil, nil
		if weapon then
			local att = weapon:FindFirstChild(MUZZLE_ATT, true)
			if att and att:IsA("Attachment") then
				vmMuzzleAtt = att
			else
				vmMuzzleLocal = measureFallbackOffset(vm, weapon)
			end
		end
	end

	local muzzleWorld
	if vmMuzzleAtt and vmMuzzleAtt.Parent then
		-- Relative to the CURRENT pivot, which already contains last frame's
		-- pushback -- so the offset itself comes out pushback-free, and it
		-- tracks the reload/fire animations for free.
		local rel = vm:GetPivot():ToObjectSpace(vmMuzzleAtt.WorldCFrame)
		muzzleWorld = (desiredPivot * rel).Position
	elseif vmMuzzleLocal then
		muzzleWorld = (desiredPivot * vmMuzzleLocal).Position
	else
		vmPushback = 0
		return 0
	end

	local camCF   = cam.CFrame
	local reach   = -camCF:PointToObjectSpace(muzzleWorld).Z
	local castLen = math.max(reach + (Config.vm_pushbackMargin or 0.25), 0.05)

	refreshPushFilter()

	local radius = math.max(Config.vm_pushbackRadius or 0.3, 0.05)
	local ok, hit = pcall(workspace.Spherecast, workspace,
		camCF.Position, radius, camCF.LookVector * castLen, pushParams)

	local target = 0
	if ok and hit then
		target = math.clamp(castLen - hit.Distance, 0, Config.vm_pushbackMax or 1.5)
	end
	
	-- Retract fast, return slow.
	local rate = (target > vmPushback)
		and (Config.vm_pushbackInSpeed or 30)
		or  (Config.vm_pushbackOutSpeed or 12)

	local dt = math.max(deltaTime or 0, 0) * (State.timeScale or 1)
	vmPushback += (target - vmPushback) * (1 - math.exp(-rate * dt))
	if vmPushback < 0.001 then vmPushback = 0 end

	return vmPushback
end

local function buildViewmodel()
	local template = ReplicatedStorage:FindFirstChild("viewmodel")
	if not template then
		warnOnce("no_vm", "No 'viewmodel' model in ReplicatedStorage.")
		return nil
	end

	local vm = template:Clone()
	if not vm.PrimaryPart then
		vm.PrimaryPart = vm:FindFirstChild("Torso")
		if not vm.PrimaryPart then
			warnOnce("no_vm_root", "Viewmodel has no Torso to use as PrimaryPart.")
		end
	end

	local animate = vm:FindFirstChild("Animate")
	if animate then animate:Destroy() end

	-- Keep the Humanoid: Shirt, Pants and Body Colors are applied by it.
	-- An AnimationController can play animations but won't render clothing.
	-- Disable the state machine instead, so it doesn't fight hand-authored
	-- animations or try to ragdoll.
	local hum = vm:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.EvaluateStateMachine = false
		hum.RequiresNeck = false
		hum.BreakJointsOnDeath = false
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		if not hum:FindFirstChildOfClass("Animator") then
			Instance.new("Animator").Parent = hum
		end
	end

	vm.Parent = cam

	for _, d in ipairs(vm:GetDescendants()) do
		if d:IsA("BasePart") then d.Anchored = false end
	end

	if vm.PrimaryPart then
		vm.PrimaryPart.Anchored = true
	end
	stripPhysics(vm)
	cacheViewmodelParts(vm)

	Visuals.SetupViewmodel(vm)
	return vm
end

local function destroyViewmodel()
	if not State.viewmodel then return end
	for _, c in ipairs(vmConnections) do c:Disconnect() end
	table.clear(vmParts)
	table.clear(vmConnections)
	destroyTrackSet(State.vmTracks)
	destroyTrackSet(State.vmWeaponTracks)
	State.viewmodel:Destroy()
	State.viewmodel = nil
	State.vmTracks = nil
	State.vmWeaponTracks = nil
	State.currentVmTrack = nil
	State.currentVmOverlay = nil
	
	
	vmOneShot = nil
	vmPushback     = 0
	vmMuzzleWeapon = nil
	vmMuzzleAtt    = nil
	vmMuzzleLocal  = nil
	Visuals.renderedVmSlot = -1
end

-- viewPunch is passed in rather than re-read, so the arms and the camera
-- always agree even mid-frame.
local function updateViewmodel(viewPunch, deltaTime)
	if not State.viewmodel then
		State.viewmodel = buildViewmodel()
	end

	local vm = State.viewmodel
	if not (vm and vm.PrimaryPart) then return end

	if not clothingApplied then
		clothingApplied = applyViewmodelClothing(vm)
	end

	local offset = CFrame.new(
		Config.vm_offsetX or 0,
		Config.vm_offsetY or -1.5,
		Config.vm_offsetZ or 0
	) * CFrame.Angles(
		math.rad(Config.vm_pitch or 0),
		math.rad(Config.vm_yaw or 0),
		math.rad(Config.vm_roll or 0)
	)

	local base = cam.CFrame
	if Config.vp_lockPitch then
		-- Camera position, yaw only: the arms stay level while you look up and
		-- down. The yaw punch still has to be folded in by hand here, since
		-- this path rebuilds the rotation from scratch instead of inheriting
		-- it from cam.CFrame.
		base = CFrame.new(cam.CFrame.Position)
			* CFrame.Angles(0, math.rad((State.cameraX or 0) - viewPunch.X), 0)
	end

	local desired = base * offset * ViewBob.vmOffset * ViewSway.offset

	-- Retract along the CAMERA's forward axis, not the viewmodel's: the vm
	-- carries pitch/yaw/roll tweaks and bob, and pushing along those would
	-- drift the gun sideways as it retracts.
	local push  = pushbackOffset(vm, desired, deltaTime)
	local final = desired - cam.CFrame.LookVector * push

	local rot = Config.vm_pushbackRotate or 0
	if rot ~= 0 and push > 0 then
		local maxPush = math.max(Config.vm_pushbackMax or 1.5, 0.001)
		final = final * CFrame.Angles(math.rad(rot * (push / maxPush)), 0, 0)
	end

	vm:PivotTo(final)
	updateViewmodelWeapon(vm)
end

--=====================================================================
-- MAIN UPDATE
--=====================================================================

local function guard(key, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then warnOnce("section_" .. key, "%s error: %s", key, tostring(err)) end
end

function Visuals.Update(deltaTime)
	local body   = State.playerBody
	local puppet = State.playerPuppet
	if not body or not puppet or not puppet.PrimaryPart then return end

	if Visuals.currentPuppet ~= puppet then
		if not puppet:GetAttribute("VisualsTag") then
			-- Virtual clock, not os.clock(): every other timestamp in the
			-- project is gameTime, and mixing the two makes host_timescale
			-- sessions impossible to reason about.
			puppet:SetAttribute("VisualsTag", State.gameTime or 0)
		end
		Visuals.SetupPuppet(puppet)
	end

	applyTimescaleToTracks()

	local scaleValue = puppet:FindFirstChild("BodyScale")
	local bodyScale = (scaleValue and scaleValue:IsA("NumberValue")) and scaleValue.Value or 1

	--------------------------------------------------------------
	-- 1. PUPPET PLACEMENT
	--------------------------------------------------------------
	local targetPitch, targetHeightOffset, forcedHeight = 0, 0, 0

	local fh = puppet:FindFirstChild("forcedheightoffset")
	if fh then forcedHeight = fh.Value end

	local fch = puppet:FindFirstChild("forcedcrouchedheightoffset")
	if fch and State.isCrouching then forcedHeight += fch.Value end

	if State.isDiving or State.isProne then
		targetPitch = math.rad(-80)
		targetHeightOffset = -(body.Size.Y / 2) + (0.8 * bodyScale)
	end

	local alpha = 1 - math.exp(-10 * deltaTime)
	State.currentPuppetPitch = (State.currentPuppetPitch or 0)
		+ (targetPitch - (State.currentPuppetPitch or 0)) * alpha

	puppet.PrimaryPart.CFrame = body.CFrame
		* CFrame.new(0, targetHeightOffset + forcedHeight, 0)
		* CFrame.Angles(State.currentPuppetPitch, 0, 0)

	--------------------------------------------------------------
	-- 2. SPEED + ANIMATION
	--------------------------------------------------------------
	local speed, source = getHorizontalSpeed(body, deltaTime)
	Visuals.lastSpeed = speed
	Visuals.lastSpeedSource = source

	local isMoving = (Visuals.lastMoving and speed > Visuals.moveThreshold)
		or (speed > Visuals.moveThresholdHigh)
	Visuals.lastMoving = isMoving

	guard("animation", updateLocomotion, speed, isMoving)

	--------------------------------------------------------------
	-- 3. CAMERA
	--------------------------------------------------------------
	local standH  = Config.cl_standingCamHeight * bodyScale
	local duckH   = Config.cl_crouchingCamHeight * bodyScale
	local proneH  = Config.cl_proneCamHeight * bodyScale
	local targetCamHeight = State.isProne and proneH
		or (standH + (duckH - standH) * (State.duckFraction or 0))
	local targetCamHeight = Config.cl_standingCamHeight * bodyScale
	if State.isCrouching then
		targetCamHeight = Config.cl_crouchingCamHeight * bodyScale
	elseif State.isProne then
		targetCamHeight = Config.cl_proneCamHeight * bodyScale
	end

	local camAlpha = 1 - math.exp(-12 * deltaTime)
	State.currentCamHeight = (State.currentCamHeight or targetCamHeight)
		+ (targetCamHeight - (State.currentCamHeight or targetCamHeight)) * camAlpha
	
	local renderPos = renderPosition(body)

	puppet.PrimaryPart.CFrame = CFrame.new(renderPos)
		* CFrame.Angles(0, select(2, body.CFrame:ToEulerAnglesYXZ()), 0)
		* CFrame.new(0, targetHeightOffset + forcedHeight, 0)
		* CFrame.Angles(State.currentPuppetPitch, 0, 0)
	-- Recoil view punch. Already scaled by view_ratio and view_punch_extra by
	-- Weapons.PreRender -- do NOT scale it again here, and do NOT substitute
	-- State.recoilPunch (that one is the full punch, for bullets only).
	--
	-- Nothing is folded back into State.cameraX/Y: those stay pure mouse
	-- input, which is exactly what makes the view snap back to true aim when
	-- the trigger is released.
	local viewPunch = State.recoilViewPunch or Vector2.zero

	local camRotation = CFrame.Angles(0, math.rad(State.cameraX - viewPunch.X), 0)
		* CFrame.Angles(math.rad(State.cameraY + viewPunch.Y), 0, 0)
	local baseCamCFrame = CFrame.new(renderPos + Vector3.new(0, State.currentCamHeight, 0))
		* camRotation
	-- Roll pivots around the FINAL view axis, so it goes on after pitch, yaw
	-- and view punch. Physics computes the angle from lateral velocity.
	if (State.cameraRoll or 0) ~= 0 then
		baseCamCFrame = baseCamCFrame * CFrame.Angles(0, 0, -math.rad(State.cameraRoll))
	end
	
	cam.FieldOfView = Config.cam_fov or 70
	ViewBob.Update(deltaTime, speed)
	ViewSway.Update(deltaTime, speed)

	if State.isThirdPerson then
		cam.CFrame = baseCamCFrame * CFrame.new(2 * bodyScale, 0, 10 * bodyScale)
	else
		cam.CFrame = baseCamCFrame * ViewBob.camOffset
	end

	--------------------------------------------------------------
	-- 4. WEAPONS
	--------------------------------------------------------------
	Inventory.MigrateLegacy(State)

	guard("weapon", updatePuppetWeapon) -- replaced???

	--------------------------------------------------------------
	-- 5. VIEWMODEL
	--------------------------------------------------------------
	if State.isThirdPerson then
		guard("viewmodel", destroyViewmodel)
	else
		guard("viewmodel", updateViewmodel, viewPunch, deltaTime)
	end
end

--=====================================================================
-- PUBLIC PLAYBACK
--=====================================================================

-- One-shot on both the local puppet and viewmodel, replicated.
function Visuals.PlayAnim(name, fadeTime, speed, replicate)
	fadeTime = fadeTime or 0.15

	--------------------------------------------------------------
	-- viewmodel
	--------------------------------------------------------------
	local vmTrack = (State.vmWeaponTracks and State.vmWeaponTracks[name])
		or (State.vmTracks and State.vmTracks[name])
	if vmTrack and not vmTrack.Looped then
		playVmOneShot(vmTrack, fadeTime)
	end

	--------------------------------------------------------------
	-- puppet: weapon layer first, base layer as fallback.
	--------------------------------------------------------------
	-- This used to read State.tracks only. WeaponSet has always handed the
	-- Fire/Reload/Equip poses to State.puppetWeaponTracks, but nothing read
	-- that table for one-shots -- the tracks loaded, counted against the
	-- 64-track Animator cap, and never played.
	local track = State.puppetWeaponTracks and State.puppetWeaponTracks[name]
	local fromWeaponLayer = trackAlive(track)

	if not fromWeaponLayer then
		track = State.tracks and State.tracks[name]
	end

	if trackAlive(track) then
		if not track.Looped then
			safeSpeed(track, speed)
			if fromWeaponLayer then
				playPuppetOneShot(track, fadeTime)
			else
				pcall(function() track.TimePosition = 0 end)
				safePlay(track, fadeTime, name)
			end
		else
			switchTrack(track, fadeTime)
			safeSpeed(track, speed)
		end
	end

	if replicate ~= false then
		syncOneShot(name)
	end
end

function Visuals.PlayVmAnim(name, fadeTime, speed)
	local track = State.vmTracks and State.vmTracks[name]
	if not trackAlive(track) then return end
	safeSpeed(track, speed)
	pcall(function() track.TimePosition = 0 end)
	safePlay(track, fadeTime or 0.1, name)
end

--=====================================================================
-- DEBUG
--=====================================================================

function Visuals.Debug()
	print("=== Visuals debug ===")
	print("puppet:", State.playerPuppet)
	print("state:", Visuals.lastTargetState, "animSpeed:", Visuals.lastAnimSpeed)
	print(("speed: %.2f studs/s (%s)"):format(Visuals.lastSpeed, Visuals.lastSpeedSource))

	local p  = State.recoilPunch or Vector2.zero
	local vp = State.recoilViewPunch or Vector2.zero
	print(("recoil: aim(%.2f, %.2f) view(%.2f, %.2f) cone %.2f deg")
		:format(p.X, p.Y, vp.X, vp.Y, State.spreadDegrees or 0))

	if not State.tracks then
		print("State.tracks is nil -- has SetupPuppet run?")
		return
	end

	for name, def in pairs(AnimDefs.PUPPET) do
		local t = State.tracks[name]
		if not t then
			print(("  %-12s -- %s"):format(name,
				def.id == "" and "stub, no id" or "FAILED TO LOAD"))
		else
			print(("  %-12s len=%.2f playing=%-5s %s"):format(
				name, t.Length, tostring(t.IsPlaying),
				t.Length == 0 and "ASSET NOT LOADED" or "ok"))
		end
	end
end

return Visuals