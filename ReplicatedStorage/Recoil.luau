--!strict
--!native
--------------------------------------------------------------------------------
-- Glacier1 / Injection / ReplicatedStorage / Recoil.lua
-- Location: ReplicatedStorage.Recoil  (ModuleScript)
--
-- CS:GO-model recoil: accumulated aim punch + seeded inaccuracy.
-- PURE: no Instances, no globals, never os.clock()/tick(). All timing is
-- State.gameTime, so host_timescale is handled for free.
--
-- Run by BOTH client (prediction) and server (authority). Identical inputs must
-- produce identical outputs, so every tunable arrives via a Cfg table sourced
-- from REPLICATED cvars.
--
-- WHY THERE IS NO dt ANYWHERE:
-- Every decaying quantity is stored as a value-at-last-shot plus a closed-form
-- function of (gameTime - lastFire). A client stepping at 144Hz and a server
-- stepping once per fire handler therefore land on bit-identical numbers, and
-- punch is continuous at the moment of firing -- so a shot can never produce a
-- visual discontinuity. Frame-accumulated decay gives you neither property.
--------------------------------------------------------------------------------

local Recoil = {}

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

-- Patterns are authored as ABSOLUTE offsets in degrees (what a spray image
-- looks like). Per-shot deltas are derived, so weapon defs don't change.
--   .X = yaw   (+ = right)
--   .Y = pitch (+ = up)
-- pattern[1] must be Vector2.zero: the first bullet is always dead centre.
export type Pattern = { Vector2 }

export type State = {
	index: number,          -- fractional position in the pattern
	indexAtFire: number,    -- decay anchor
	punch: Vector2,         -- current aim punch, degrees
	punchAtFire: Vector2,   -- decay anchor
	accuracy: number,       -- accumulated inaccuracy penalty, radians
	accuracyAtFire: number, -- decay anchor
	lastFire: number,
	shotId: number,
}

export type Cfg = {
	scale: number,         -- weapon_recoil_scale
	variance: number,      -- weapon_recoil_variance         (0 = pattern exact)
	cooldown: number,      -- weapon_recoil_cooldown         (s idle before index bleeds)
	resetRate: number,     -- weapon_recoil_reset_rate       (index/s)
	decayExp: number,      -- weapon_recoil_decay_exp        (punch exponential rate)
	decayLin: number,      -- weapon_recoil_decay_lin        (punch linear floor, deg/s)
	accuracyDelay: number, -- weapon_accuracy_delay          (s before accuracy recovers)
	viewExtra: number,     -- weapon_recoil_view_punch_extra
	viewRatio: number,     -- weapon_recoil_view_ratio       (presentational only)
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

function Recoil.newState(): State
	return {
		index = 0,
		indexAtFire = 0,
		punch = Vector2.zero,
		punchAtFire = Vector2.zero,
		accuracy = 0,
		accuracyAtFire = 0,
		lastFire = -1e9,
		shotId = 0,
	}
end

-- Spawn, death, reload completion, weapon switch, RecoilSync correction.
-- Every anchor must be cleared, not just the live value: leaving indexAtFire
-- behind makes the next step() snap the index back to a stale number.
function Recoil.reset(s: State, gameTime: number)
	s.index = 0
	s.indexAtFire = 0
	s.punch = Vector2.zero
	s.punchAtFire = Vector2.zero
	s.accuracy = 0
	s.accuracyAtFire = 0
	s.lastFire = -1e9
	-- shotId deliberately NOT reset: it is the seed basis and must stay
	-- monotonic for the whole life, or two shots share a spread vector.
end

--------------------------------------------------------------------------------
-- Cfg
--------------------------------------------------------------------------------

function Recoil.readCfg(Config: any): Cfg
	local v = Config.Values
	return {
		scale         = v.weapon_recoil_scale or 1,
		variance      = v.weapon_recoil_variance or 0,
		cooldown      = v.weapon_recoil_cooldown or 0.55,
		resetRate     = v.weapon_recoil_reset_rate or 14,
		decayExp      = v.weapon_recoil_decay_exp or 2,
		decayLin      = v.weapon_recoil_decay_lin or 6,
		accuracyDelay = v.weapon_accuracy_delay or 0.15,
		viewExtra     = v.weapon_recoil_view_punch_extra or 0.055,
		viewRatio     = v.weapon_recoil_view_ratio or 0.5,
	}
end

--------------------------------------------------------------------------------
-- Seeding
--------------------------------------------------------------------------------

function Recoil.shotSeed(salt: number, shotId: number): number
	return (salt % 2147483647) + shotId * 1000003
end

--------------------------------------------------------------------------------
-- Pattern
--------------------------------------------------------------------------------

local function patternAt(pattern: Pattern, i: number): Vector2
	if i < 1 then return Vector2.zero end
	local n = #pattern
	if i >= n then return pattern[n] end
	local lo = math.floor(i)
	local frac = i - lo
	if frac <= 0 then return pattern[lo] end
	return pattern[lo]:Lerp(pattern[lo + 1], frac)
end

--------------------------------------------------------------------------------
-- Step -- closed-form decay. Safe to call any number of times per frame.
--------------------------------------------------------------------------------

function Recoil.step(s: State, gameTime: number, weapon: any, cfg: Cfg)
	local rec = weapon.recoil
	local since = gameTime - s.lastFire
	if since < 0 then since = 0 end

	-- ---- aim punch: exponential decay with a linear floor ----
	-- The exponential alone asymptotes and never quite reaches zero, leaving a
	-- permanent sub-degree tilt on the view. The linear term is what actually
	-- lands it back on centre.
	local anchor = s.punchAtFire
	local mag = anchor.Magnitude
	if mag > 1e-6 then
		local m = mag * math.exp(-cfg.decayExp * since) - cfg.decayLin * since
		s.punch = (m > 0) and (anchor * (m / mag)) or Vector2.zero
	else
		s.punch = Vector2.zero
	end

	-- ---- recoil index: holds during fire, bleeds once idle past cooldown ----
	local cooldown = cfg.cooldown * (rec.cooldownMul or 1)
	if since > cooldown then
		s.index = math.max(0, s.indexAtFire - cfg.resetRate * (since - cooldown))
	else
		s.index = s.indexAtFire
	end

	-- ---- accuracy penalty ----
	if since > cfg.accuracyDelay then
		local rate = weapon.accuracy.recovery or 0.02
		local a = s.accuracyAtFire
		local d = rate * (since - cfg.accuracyDelay)
		s.accuracy = (a > 0) and math.max(0, a - d) or math.min(0, a + d)
	else
		s.accuracy = s.accuracyAtFire
	end
end

--------------------------------------------------------------------------------
-- Fire
--------------------------------------------------------------------------------

-- Returns the aim punch (degrees) that this shot's bullet travels along.
function Recoil.fire(s: State, gameTime: number, weapon: any, cfg: Cfg, seed: number): Vector2
	Recoil.step(s, gameTime, weapon, cfg)

	local rec = weapon.recoil
	local n = math.floor(s.index) + 1

	-- Per-shot DELTA off the authored absolute pattern. Accumulating deltas is
	-- what lets decay coexist with a pattern: punch never jumps to an absolute
	-- value, it only ever moves by the step between two adjacent points.
	local delta = patternAt(rec.pattern, n) - patternAt(rec.pattern, n - 1)

	-- Variance ramps in over the first few shots. Shot 1's delta is zero and
	-- gets zero jitter, so the opening bullet is always exactly on the
	-- crosshair -- non-negotiable for a tap-fire game.
	local ramp = math.clamp((n - 1) / 3, 0, 1)
	local v = cfg.variance * (rec.variance or 1) * ramp
	if v > 0 then
		local rng = Random.new(seed)
		local ang = rng:NextNumber(0, math.pi * 2)
		local jit = rng:NextNumber() * v * (rec.jitterDegrees or 0.3)
		delta += Vector2.new(math.cos(ang), math.sin(ang)) * jit
	end

	s.punch = s.punch + delta * (cfg.scale * rec.scale)
	s.punchAtFire = s.punch
	s.index = n
	s.indexAtFire = n
	s.shotId += 1
	s.lastFire = gameTime

	local acc = weapon.accuracy
	s.accuracy = math.clamp(s.accuracy + (acc.perShot or 0), acc.min or 0, acc.max or 0.25)
	s.accuracyAtFire = s.accuracy

	return s.punch
end

--------------------------------------------------------------------------------
-- View punch -- what the CAMERA shows. Never feed this to a bullet.
--------------------------------------------------------------------------------

-- viewRatio 1.0 = CS:GO (camera follows the punch fully).
-- viewRatio 0.5 = half the kick on the camera, the rest shown by the crosshair
--                 drifting off centre. Purely presentational: the server has no
--                 camera and rebuilds bullet direction from the full punch, so
--                 this cvar cannot desync hit registration.
function Recoil.viewPunch(s: State, cfg: Cfg): Vector2
	return s.punch * (cfg.viewRatio * (1 + cfg.viewExtra))
end

-- The residual the crosshair must render, in degrees, so the player can still
-- see where the gun points when viewRatio < 1.
function Recoil.crosshairPunch(s: State, cfg: Cfg): Vector2
	return s.punch - Recoil.viewPunch(s, cfg)
end

--------------------------------------------------------------------------------
-- Inaccuracy (the cone)
--------------------------------------------------------------------------------

function Recoil.inaccuracy(s: State, weapon: any, speed: number, grounded: boolean, ducked: boolean): number
	local acc = weapon.accuracy
	local inacc = acc.base + s.accuracy

	local moveFrac = math.clamp(speed / (acc.maxSpeed or 16), 0, 1)
	inacc += acc.moving * moveFrac * moveFrac

	if not grounded then
		inacc += acc.air
	elseif ducked then
		inacc *= (acc.crouchMul or 1)
	end

	return inacc
end

-- inacc is a half-angle in radians. Two summed samples give the centre-biased
-- distribution CS:GO-style spread has (most bullets near centre, tail outward).
function Recoil.spreadDirection(aimCF: CFrame, inacc: number, seed: number): Vector3
	if inacc <= 0 then return aimCF.LookVector end

	local rng = Random.new(seed + 7919)
	local a1, r1 = rng:NextNumber(0, math.pi * 2), rng:NextNumber() * inacc
	local a2, r2 = rng:NextNumber(0, math.pi * 2), rng:NextNumber() * inacc

	local x = r1 * math.cos(a1) + r2 * math.cos(a2)
	local y = r1 * math.sin(a1) + r2 * math.sin(a2)

	return (aimCF.LookVector
		+ aimCF.RightVector * math.tan(x)
		+ aimCF.UpVector    * math.tan(y)).Unit
end

--------------------------------------------------------------------------------
-- Angle helper -- the ONE place the yaw/pitch sign convention lives
--------------------------------------------------------------------------------

-- yaw/pitch are the stored base view angles in degrees: pure mouse input, with
-- punch NOT baked in. Pass the full punch for bullets, Recoil.viewPunch() for
-- the camera.
function Recoil.aimCFrame(eyePos: Vector3, yaw: number, pitch: number, punch: Vector2): CFrame
	local y = math.rad(yaw - punch.X)
	local p = math.rad(pitch + punch.Y)
	return CFrame.new(eyePos) * CFrame.fromEulerAnglesYXZ(0, y, 0) * CFrame.Angles(p, 0, 0)
end

return Recoil