-- ModuleScript: Weapons  (client)
-- Owns the fire/reload/equip state machine. Input only sets intent flags;
-- everything timed or stateful happens here, at a fixed point in the frame.
--
-- FRAME ORDER -- this is a contract, not a suggestion:
--   Weapons.PreRender(dt)   -- publishes State.recoilViewPunch
--   Visuals.Update(dt)      -- builds the camera from it
--   Weapons.Update(dt)      -- fire/reload state machine
-- If PreRender runs after Visuals, every kick renders a frame late and reads
-- as a flick on the first shot.
--
-- WIRING (in Player, after both modules are required):
--   Visuals.onWeaponEquipped = Weapons.OnEquipped
--   Bullets.onRecoilSync     = Weapons.ApplyRecoilSync
-- Both are callbacks rather than requires because Weapons already requires
-- Visuals and Bullets, so a direct require either way would be circular.
--
-- Per-weapon hooks (all optional) on the stats module:
--   OnFire(stats, ctx)     -- ctx.origin / ctx.direction; return false to veto
--   OnReloadStart(stats)
--   OnReloadEnd(stats)
--   OnEquip(stats)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config  = require(ReplicatedStorage:WaitForChild("Config"))
local Recoil  = require(ReplicatedStorage:WaitForChild("Recoil"))
local State   = require(script.Parent.State)
local Visuals = require(script.Parent.Visuals)
local Sounds  = require(script.Parent.Sounds)
local Bullets = require(script.Parent.Bullets)
local Inventory = require(ReplicatedStorage:WaitForChild("Inventory"))

local ReloadWeapon = ReplicatedStorage:WaitForChild("ReloadWeapon", 10)

local Weapons = {}

local lastTriggerDown = false

-- Rebuilt once per frame in PreRender, reused by fire() in the same frame.
-- Reading nine cvars per bullet at 600 RPM is pure waste.
local cfg = nil

-- Throttles the "no salt yet" retry so a client that hasn't been handed its
-- seed doesn't re-enter fire() every single frame while the trigger is held.
local nextSaltComplaint = 0

--=====================================================================
-- HELPERS
--=====================================================================

local function stats()
	return State.currentWeaponStats
end

local function busy()
	local now = State.gameTime
	if now < (State.equipEndTime or 0) then return true, "equipping" end
	if State.isReloading then return true, "reloading" end
	return false
end

local function fireInterval(s)
	return 60 / math.max(s.fireRate or 600, 1)
end

-- Created lazily: the module can be required before the player has a body,
-- and Recoil.reset on a nil state would throw.
local function recoilState()
	if not State.recoil then
		State.recoil = Recoil.newState()
	end
	return State.recoil
end

local function resetRecoil()
	Recoil.reset(recoilState(), State.gameTime or 0)
end

-- Eye position, NOT cam.CFrame.Position: the camera has viewbob baked in and
-- bob must never move a bullet.
local function eyePosition()
	local body = State.playerBody
	if not body then return nil end
	local base = (State.curBodyPos and State.prevBodyPos)
		and State.prevBodyPos:Lerp(State.curBodyPos, State.tickAlpha)
		or body.Position
	return base + Vector3.new(0, State.currentCamHeight or 0, 0)
end

--=====================================================================
-- PER-FRAME RECOIL  (runs before Visuals)
--=====================================================================

-- Three values, and they are NOT interchangeable:
--   recoilPunch     -- full punch; the angle bullets travel along
--   recoilViewPunch -- scaled by view_ratio and view_punch_extra; the camera
--   recoilCrosshair -- the residual the crosshair must draw
-- Feeding recoilViewPunch to a bullet silently desyncs it from the server,
-- because the server has no camera and always uses the full punch.
local function publishRecoil(st)
	State.recoilPunch     = st.punch
	State.recoilViewPunch = Recoil.viewPunch(st, cfg)
	State.recoilCrosshair = Recoil.crosshairPunch(st, cfg)
end

local function clearRecoilPublish()
	State.recoilPunch     = Vector2.zero
	State.recoilViewPunch = Vector2.zero
	State.recoilCrosshair = Vector2.zero
	State.spreadDegrees   = 0
end

function Weapons.PreRender()
	cfg = Recoil.readCfg(Config)

	local s = stats()
	if not s then
		clearRecoilPublish()
		return
	end

	local st = recoilState()

	-- Unconditional. Decay must run whether or not the player can currently
	-- shoot -- gating it behind the fire checks is what leaves the view stuck
	-- kicked up after a burst, or the index stuck mid-pattern.
	Recoil.step(st, State.gameTime, s, cfg)
	publishRecoil(st)

	-- Crosshair gap shows the authoritative cone, so what the player sees is
	-- what the server will actually roll against.
	State.spreadDegrees = math.deg(Recoil.inaccuracy(st, s,
		Visuals.lastSpeed or 0, State.isGrounded, State.isCrouching))
end

--=====================================================================
-- FIRING
--=====================================================================

local function fire(s)
	-- The salt seeds every spread vector. Without it the client would roll a
	-- different cone than the server, so refuse before anything is consumed.
	if not State.recoilSalt then
		if State.gameTime >= nextSaltComplaint then
			nextSaltComplaint = State.gameTime + 1
			warn("[Weapons] no recoil salt yet -- shot suppressed.")
		end
		State.nextFireTime = State.gameTime + 0.1
		return false
	end

	local eye = eyePosition()
	if not eye then return false end

	local st = recoilState()

	-- Veto hook sees the pre-shot aim, before any state is mutated. Vetoing
	-- after Recoil.fire would consume a pattern index for a shot that never
	-- happened and desync the whole rest of the magazine.
	if type(s.OnFire) == "function" then
		local ctx = {
			origin = eye,
			direction = Recoil.aimCFrame(eye, State.cameraX, State.cameraY, st.punch).LookVector,
		}
		local ok, result = pcall(s.OnFire, s, ctx)
		if not ok then
			warn("[Weapons] OnFire error on " .. tostring(s.name) .. ": " .. tostring(result))
		elseif result == false then
			return false
		end
	end

	-- ---- commit ----
	State.currentAmmo = math.max((State.currentAmmo or 0) - 1, 0)
	Inventory.Push(State)   -- ADD: write through, don't wait for unequip
	State.nextFireTime = State.gameTime + fireInterval(s)

	-- PRE-increment shotId; Recoil.fire bumps it internally. Reading it after
	-- offsets every bullet's spread by one seed from the server's.
	local shotId = st.shotId
	local seed   = Recoil.shotSeed(State.recoilSalt, shotId)

	local punch = Recoil.fire(st, State.gameTime, s, cfg, seed)
	publishRecoil(st)

	local aimCF = Recoil.aimCFrame(eye, State.cameraX, State.cameraY, punch)
	local inacc = Recoil.inaccuracy(st, s,
		Visuals.lastSpeed or 0, State.isGrounded, State.isCrouching)
	local dir   = Recoil.spreadDirection(aimCF, inacc, seed)

	State.spreadDegrees = math.deg(inacc)

	Visuals.PlayAnim("Fire", 0.02, nil, false)
	Sounds.Push("weapon", "Fire")

	-- dir is for the local tracer only. Bullets puts the BASE angles on the
	-- wire and the server rebuilds direction from its own recoil state, so a
	-- modified client cannot zero its own spread.
	Bullets.Fire(s, eye, dir, shotId, State.cameraX, State.cameraY)

	return true
end

--=====================================================================
-- RELOAD
--=====================================================================

local function beginReload(s)
	if State.isReloading then return end
	if type(s.magSize) ~= "number" then return end
	if (State.currentAmmo or 0) >= s.magSize then return end
	if (State.reserveAmmo or 0) <= 0 then return end

	State.isReloading = true
	State.reloadEndTime = State.gameTime + (s.reloadTime or 2)

	if ReloadWeapon then
		ReloadWeapon:FireServer(s.name)
	end

	if type(s.OnReloadStart) == "function" then
		pcall(s.OnReloadStart, s)
	end

	Visuals.PlayAnim("Reload", 0.05)
	Sounds.Push("weapon", "Reload")
end

local function finishReload(s)
	State.isReloading = false

	-- Fresh mag, fresh spray. The server resets on its own reload timer and
	-- pushes a RecoilSync, so both sides re-enter the pattern at index 0.
	resetRecoil()

	local need = s.magSize - (State.currentAmmo or 0)
	local take = math.min(need, State.reserveAmmo or 0)
	State.currentAmmo = (State.currentAmmo or 0) + take
	State.reserveAmmo = (State.reserveAmmo or 0) - take
	Inventory.Push(State)

	if type(s.OnReloadEnd) == "function" then
		pcall(s.OnReloadEnd, s)
	end
end

--=====================================================================
-- UPDATE
--=====================================================================

function Weapons.Update()
	local s = stats()

	local triggerDown = State.triggerDown == true
	local pressedThisFrame = triggerDown and not lastTriggerDown
	lastTriggerDown = triggerDown

	if not s then
		State.reloadRequested = false
		return
	end

	-- PreRender should have built this; guard in case the call order is wrong.
	cfg = cfg or Recoil.readCfg(Config)

	-- ---- reload completion ----
	if State.isReloading and State.gameTime >= (State.reloadEndTime or 0) then
		finishReload(s)
	end

	local isBusy = busy()

	-- ---- reload request ----
	if State.reloadRequested then
		State.reloadRequested = false
		if not isBusy then
			beginReload(s)
			isBusy = true
		end
	end
	-- ---- inspect ----
	-- Consumed unconditionally, even when refused: a queued inspect that
	-- fires the moment a reload ends is not what the player asked for.
	if State.inspectRequested then
		State.inspectRequested = false
		if not isBusy and s.viewmodelAnims and s.viewmodelAnims.Inspect then
			Visuals.PlayAnim("Inspect", 0.1)
			Sounds.Push("weapon", "Inspect")
		end
	end
	
	-- ---- firing ----
	if isBusy or State.isDiving then return end

	-- Sprinting lowers the weapon in most shooters; firing from it feels wrong
	-- and it gives sprint a real cost.
	if State.isSprinting and Config.wp_noFireWhileSprinting ~= false then
		return
	end

	local wantsShot = (s.isAuto and triggerDown) or pressedThisFrame
	if not wantsShot then return end

	if State.gameTime < (State.nextFireTime or 0) then return end

	local item = Inventory.Active(State)
	if item and item.usesAmmo and (State.currentAmmo or 0) <= 0 then
		-- Dry fire once per trigger pull, not once per frame.
		if pressedThisFrame then
			Sounds.Push("weapon", "DryFire")
			if Config.wp_autoReloadOnEmpty then
				beginReload(s)
			end
		end
		return
	end

	fire(s)
end

--=====================================================================
-- PUBLIC
--=====================================================================

-- Called by Visuals via onWeaponEquipped when the active slot changes.
function Weapons.OnEquipped(s)
	State.isReloading = false
	State.nextFireTime = 0
	lastTriggerDown = true   -- swallow a held trigger across the swap

	-- Switching mid-spray must not carry the index onto the new weapon: its
	-- pattern is a different length and the indices don't correspond.
	resetRecoil()

	if s and type(s.OnEquip) == "function" then
		pcall(s.OnEquip, s)
	end
end

-- Called by Bullets via onRecoilSync whenever the server pushes authoritative
-- recoil state: salt on spawn, and a correction whenever it rejects a shot the
-- client already predicted.
function Weapons.ApplyRecoilSync(packet)
	if type(packet) ~= "table" then return end

	if packet.salt then
		State.recoilSalt = packet.salt
	end

	if packet.shotId == nil then return end

	local st = recoilState()

	-- shotId is the seed basis: if it drifts, every subsequent bullet rolls a
	-- different cone than the server and tracers stop matching hits. This is
	-- the field that actually has to be right.
	st.shotId = packet.shotId

	local idx = packet.index or 0
	st.index = idx
	st.indexAtFire = idx   -- the anchor, not the live value, is what step() reads

	-- Punch is deliberately left to decay on its own rather than being
	-- recomputed. It is at most one pattern step out after a rejected shot,
	-- it is cosmetic on this side (the server owns bullet direction), and any
	-- attempt to reconstruct it would have to guess how much decay the server
	-- applied between the two clocks.
end

function Weapons.CancelReload()
	State.isReloading = false
	State.reloadEndTime = 0
end

-- Death, respawn, round start.
function Weapons.ResetRecoil()
	resetRecoil()
end

function Weapons.Debug()
	local st = State.recoil
	if not st then
		print("[Weapons] no recoil state yet")
		return
	end
	print(("[Weapons] salt=%s shotId=%d index=%.2f (anchor %.2f) punch=(%.2f, %.2f) cone=%.3f deg")
		:format(tostring(State.recoilSalt), st.shotId, st.index, st.indexAtFire,
			st.punch.X, st.punch.Y, State.spreadDegrees or 0))
end

return Weapons