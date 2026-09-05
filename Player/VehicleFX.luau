-- ModuleScript: VehicleFX
-- Parent: Player (the LocalScript's module folder)
--
-- Everything a car does that you can hear or see but that does not move it:
-- the engine note, the exhaust, the backfire, the smoke off a sliding tyre.
--
-- SEPARATE FROM THE SIM on purpose. The sim publishes numbers -- rpm, gear,
-- slip, whether it just shifted -- and this turns them into sound and
-- particles. Nothing here is allowed to feed back, so a missing emitter or a
-- muted sound can never change how a car drives, and the driving code never
-- has to know what art a model happens to carry.
--
-- WHAT IT LOOKS FOR, all of it optional. A model missing any of this simply
-- gets less, and a model with none of it is silent rather than broken:
--
--   Chassis/Engine          Sound   looped, pitched from rpm
--   Chassis/Backfire        Sound   one shot on a backfire
--   Chassis/TireScreech     Sound   looped, volume and pitch from slip
--   Exhaust/Backfire        ParticleEmitter   burst on an upshift
--   Exhaust/Smoke           ParticleEmitter   idle haze, thicker under power
--   Wheels/<wheel>/Smoke    ParticleEmitter   per wheel, on slip or lock-up
--
-- The backfire has a particle and a sound and they are found in different
-- places -- the emitter under Exhaust, where you would model it, and the
-- sound under Chassis, where the engine already is. Both are optional and
-- either alone is a complete effect.
--
-- Names are matched case-insensitively and by CONTAINMENT, so "EngineSound",
-- "engine_loop" and "Engine" all work. Art gets named by hand and this should
-- not be a spelling test.

local VehicleFX = {}

--=====================================================================
-- LOOKUP
--=====================================================================

local function findByName(parent, needle, className)
	if not parent then return nil end
	local lower = string.lower(needle)
	for _, child in ipairs(parent:GetChildren()) do
		if child:IsA(className) and string.find(string.lower(child.Name), lower, 1, true) then
			return child
		end
	end
	return nil
end

-- Measured once per model and hung off the rig, because walking the tree for
-- four emitters and a sound every frame is not free and none of it moves.
local function fxOf(model, rig)
	if rig.fx then return rig.fx end

	local chassis = rig.chassis
	local exhaust = model:FindFirstChild("Exhaust")

	local audio = model:FindFirstChild("Chassis") or chassis

	local fx = {
		engine = findByName(audio, "engine", "Sound")
			or findByName(chassis, "engine", "Sound"),

		-- "screech" rather than "tire", because the wheels are already called
		-- tyres and matching on that would pick up a rolling-noise loop or a
		-- tyre-blowout one-shot sitting beside it. Both spellings, since the
		-- part names in this model are American and the code is not.
		screech = findByName(audio, "screech", "Sound")
			or findByName(audio, "skid", "Sound")
			or findByName(chassis, "screech", "Sound"),

		backfireSound = findByName(audio, "backfire", "Sound")
			or findByName(chassis, "backfire", "Sound"),

		backfire = findByName(exhaust, "backfire", "ParticleEmitter"),
		exhaust = findByName(exhaust, "smoke", "ParticleEmitter"),
		wheelSmoke = {},
	}

	-- Per wheel, off the thing the rig actually found -- which is the child of
	-- the Wheels folder, so a wheel built as a Model has its emitter looked
	-- for under the Model rather than under its PrimaryPart.
	for i, wheel in ipairs(rig.wheels) do
		fx.wheelSmoke[i] = findByName(wheel.holder or wheel.part, "smoke", "ParticleEmitter")
	end

	-- The rates the artist set are the loud end; everything below scales
	-- toward zero from them, so tuning the look stays in Studio.
	fx.baseRates = {}
	if fx.exhaust then fx.baseRates.exhaust = fx.exhaust.Rate end

	-- The screech is a LOOP whose volume is the effect, so the artist's volume
	-- is the loud end the same way their Rate is. Captured before anything
	-- here touches it, or the first quiet frame would become the new maximum
	-- and the sound would fade away over the session.
	if fx.screech then
		fx.screechVolume = fx.screech.Volume
		fx.screechPitch = fx.screech.PlaybackSpeed
		fx.screech.Volume = 0
	end
	if fx.backfire then fx.baseRates.backfire = fx.backfire.Rate end
	for i, emitter in pairs(fx.wheelSmoke) do
		fx.baseRates[i] = emitter.Rate
	end

	-- Emitters are switched off to begin with. An artist leaves them enabled
	-- so they can see them while building, and a car should not arrive
	-- smoking from all four corners.
	if fx.exhaust then fx.exhaust.Rate = 0 end
	if fx.backfire then fx.backfire.Rate = 0 end
	for _, emitter in pairs(fx.wheelSmoke) do emitter.Rate = 0 end

	rig.fx = fx
	return fx
end

--=====================================================================
-- ENGINE
--=====================================================================

-- Playback speed for a given rpm. The sound was recorded at SOME rpm; without
-- knowing which, the only honest thing is to map the engine's whole range
-- onto a playback range that sounds like an engine, and let the artist move
-- it with the Sound's own PlaybackSpeed as a starting point.
local MIN_PITCH = 0.55
local MAX_PITCH = 2.2

-- Below this much slip the tyres are gripping as far as anyone listening is
-- concerned, and the screech stays silent. See the note where it is used.
local SCREECH_FLOOR = 0.18

local function enginePitch(def, rpm)
	local span = math.max(def.redlineRpm - def.idleRpm, 1)
	local fraction = math.clamp((rpm - def.idleRpm) / span, 0, 1.1)
	return MIN_PITCH + (MAX_PITCH - MIN_PITCH) * fraction
end

--=====================================================================
-- UPDATE
--=====================================================================

-- state carries what the sim published. Everything is optional so an observed
-- car -- which only has what came over the wire -- drives the same code as
-- the driver's own.
--
--   rpm, gear, throttle, slipFront, slipRear, grounded, shiftedUp, backfired
function VehicleFX.Update(model, rig, state, deltaTime)
	if not (model and rig and rig.chassis) then return end

	local def = rig.def
	local fx = fxOf(model, rig)
	local base = fx.baseRates

	--------------------------------------------------------------
	-- ENGINE NOTE
	--------------------------------------------------------------
	if fx.engine then
		local rpm = state.rpm or def.idleRpm
		fx.engine.PlaybackSpeed = enginePitch(def, rpm)

		-- Started here rather than assumed: a Sound left not-playing in the
		-- model would otherwise be silent forever with no clue why.
		if not fx.engine.IsPlaying then
			fx.engine.Looped = true
			fx.engine:Play()
		end
	end

	--------------------------------------------------------------
	-- BACKFIRE
	--------------------------------------------------------------
	-- A BURST, not a rate. The emitter is left at zero and given a one-shot
	-- of particles, which is what a backfire is -- a crack, not a plume.
	if fx.backfire and state.backfired then
		local count = math.clamp(math.floor((base.backfire or 12) * 0.5), 4, 40)
		fx.backfire:Emit(count)
	end

	-- The crack. Rewound rather than just played, because a second shift
	-- inside the length of the sample would otherwise be silent -- Play on an
	-- already-playing Sound does nothing, and two fast upshifts is exactly
	-- when you want to hear two bangs.
	if fx.backfireSound and state.backfired then
		fx.backfireSound.TimePosition = 0
		fx.backfireSound:Play()
	end

	--------------------------------------------------------------
	-- EXHAUST
	--------------------------------------------------------------
	-- Idles gently and thickens under load. Scaled off the rate the artist
	-- set, so the character of it stays theirs.
	if fx.exhaust then
		local throttle = math.clamp(state.throttle or 0, 0, 1)
		local revs = math.clamp(((state.rpm or def.idleRpm) - def.idleRpm)
			/ math.max(def.redlineRpm - def.idleRpm, 1), 0, 1)
		local load = math.clamp(0.25 + throttle * 0.5 + revs * 0.5, 0, 1)
		fx.exhaust.Rate = (base.exhaust or 6) * load
	end

	--------------------------------------------------------------
	-- TYRE SMOKE
	--------------------------------------------------------------
	-- Off the END that is actually sliding. A handbrake turn smokes the rear
	-- wheels and understeer smokes the fronts, and lighting all four whenever
	-- anything slips throws that away -- which is most of what the effect is
	-- worth telling you.
	local front = math.clamp(state.slipFront or 0, 0, 1)
	local rear = math.clamp(state.slipRear or 0, 0, 1)
	local grounded = state.grounded ~= false

	for i, emitter in pairs(fx.wheelSmoke) do
		local wheel = rig.wheels[i]
		local slip = (wheel and wheel.front) and front or rear

		-- A wheel in the air does not smoke, however hard the car is sliding.
		local amount = grounded and slip or 0
		emitter.Rate = (base[i] or 20) * math.clamp(amount, 0, 1)
	end

	--------------------------------------------------------------
	-- TYRE SCREECH
	--------------------------------------------------------------
	-- One loop for the whole car rather than one per wheel, driven by
	-- whichever end is sliding hardest. Four overlapping copies of the same
	-- sample is not four times the tyre noise, it is a phasing mess.
	if fx.screech then
		local slip = grounded and math.max(front, rear) or 0

		-- A DEAD BAND, because slip is never exactly zero: a car tracking
		-- straight down a road carries a percent or two of it, and mapping
		-- that straight to volume means the tyres howl quietly all the time
		-- and the effect stops meaning anything.
		local voice = math.clamp((slip - SCREECH_FLOOR) / (1 - SCREECH_FLOOR), 0, 1)

		fx.screech.Volume = (fx.screechVolume or 0.5) * voice
		-- Rising slightly as it gets worse, so a slow slide and a full lock-up
		-- are told apart by more than loudness.
		fx.screech.PlaybackSpeed = (fx.screechPitch or 1) * (0.9 + voice * 0.3)

		if voice > 0 then
			if not fx.screech.IsPlaying then
				fx.screech.Looped = true
				fx.screech:Play()
			end
		elseif fx.screech.IsPlaying then
			fx.screech:Stop()
		end
	end
end

-- Called when a car stops being driven or watched, so it does not sit there
-- revving and smoking with nobody in it.
function VehicleFX.Quiet(rig)
	local fx = rig and rig.fx
	if not fx then return end

	if fx.engine and fx.engine.IsPlaying then fx.engine:Stop() end
	if fx.screech then
		fx.screech.Volume = 0
		if fx.screech.IsPlaying then fx.screech:Stop() end
	end
	if fx.exhaust then fx.exhaust.Rate = 0 end
	if fx.backfire then fx.backfire.Rate = 0 end
	for _, emitter in pairs(fx.wheelSmoke) do emitter.Rate = 0 end
end

return VehicleFX
