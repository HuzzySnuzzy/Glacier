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
--   Chassis/TurboSpool      Sound   looped, volume and pitch from boost
--   Chassis/BOV             Sound   one shot when the valve vents
--   Chassis/EngineStart     Sound   one shot when a driver gets in
--   Exhaust/Backfire        ParticleEmitter   burst on an upshift
--   Exhaust/BackfireSmoke   ParticleEmitter   the cloud the flame leaves
--   Exhaust/Smoke           ParticleEmitter   idle haze, thicker under power
--   Wheels/<wheel>/Smoke    ParticleEmitter   per wheel, on slip or lock-up
--
-- EVERY Exhaust, not the first one. A car with twin pipes has two of them,
-- and firing only one is worse than firing none -- it reads as a broken
-- exhaust rather than as a stylistic choice.
--
-- THE TURBO is off unless the model says Turbo = true. Spool and the valve
-- are the two most recognisable noises a car can make, so putting them on
-- everything would make them mean nothing.
--
-- Names are matched anywhere in the subtree, not just on the top level: a
-- wheel here is a transparent cylinder with a detailed rim inside it, and an
-- emitter usually ends up on the rim or on an Attachment under it.
--
-- The backfire has a particle and a sound and they are found in different
-- places -- the emitter under Exhaust, where you would model it, and the
-- sound under Chassis, where the engine already is. Both are optional and
-- either alone is a complete effect.
--
-- Names are matched case-insensitively and by CONTAINMENT, so "EngineSound",
-- "engine_loop" and "Engine" all work. Art gets named by hand and this should
-- not be a spelling test.
--
-- EVERY SOUND HERE BECOMES A VOICE. A voice plays the artist's Sound through
-- the Advanced Audio API, so a car is occluded by the wall it is behind and
-- picks up the reverb of the tunnel it is in, like every movement sound
-- already does -- and falls back to driving the Sound itself where the API is
-- not there. See Player/AudioVoice; nothing below knows which it got.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VehicleDefs = require(ReplicatedStorage:WaitForChild("VehicleDefs"))

local VehicleFX = {}

--=====================================================================
-- LOOKUP
--=====================================================================

-- Direct children first, then the whole subtree.
--
-- Depth matters because of how these models are actually built. A wheel here
-- is a transparent cylinder with the detailed rim parented inside it, and an
-- emitter dropped onto the rim -- or onto an Attachment, which is how Studio
-- parents one if you use the Effects tab -- is two levels down, not one.
-- Searching only the top level found nothing and the tyres smoked never.
--
-- Shallowest match wins, so a Smoke on the wheel itself still beats one on
-- some decoration inside it.
-- `reject` excludes a name that would otherwise match. It exists because
-- matching by containment makes "smoke" find "BackfireSmoke", and which of
-- the two you get comes down to the order Studio happens to list them in --
-- so the idle haze and the backfire cloud would swap places at random.
local function findByName(parent, needle, className, reject)
	if not parent then return nil end
	local lower = string.lower(needle)

	local function matches(child)
		if not child:IsA(className) then return false end
		local name = string.lower(child.Name)
		if reject and string.find(name, reject, 1, true) then return false end
		return string.find(name, lower, 1, true) ~= nil
	end

	for _, child in ipairs(parent:GetChildren()) do
		if matches(child) then return child end
	end

	for _, child in ipairs(parent:GetChildren()) do
		local found = findByName(child, needle, className, reject)
		if found then return found end
	end
	return nil
end

-- The value the artist set, remembered on the instance itself.
--
-- Everything here scales DOWN from what is in the model, which means the
-- original has to survive being scaled. It is read once and stamped on the
-- emitter as an attribute, because the rig this cache hangs off is held
-- weakly: let it be collected between one drive and the next and the next
-- lookup would read the zero this code left behind and take it for the
-- artist's intent. The tyres would then smoke once per session and never
-- again -- which is the kind of bug that looks like bad luck.
local function rememberedRate(emitter, fallback)
	local saved = emitter:GetAttribute("FXBaseRate")
	if saved == nil then
		saved = emitter.Rate
		emitter:SetAttribute("FXBaseRate", saved)
	end

	-- A rate of ZERO is treated as "not set" rather than as "never emit".
	--
	-- An emitter authored at 0 is indistinguishable from a broken one to the
	-- player, and it is a normal way to leave one: you set Rate to 0, or you
	-- untick Enabled, so the thing does not spew all over the model while you
	-- are building it. Neither is a statement that this effect should not
	-- exist -- the effect existing at all is that statement.
	if not saved or saved <= 0 then return fallback or 0 end
	return saved
end

-- Rate AND Enabled, together, always.
--
-- This is the whole of why the tyres never smoked. Rate does NOTHING on an
-- emitter whose Enabled is false, and false is how every one of these arrives
-- from Studio -- you untick it so the car is not smoking from all four
-- corners while you work on it. Emit() ignores Enabled, which is why the
-- backfire burst worked the whole time and the smoke, which is rate-driven,
-- never did: the two failure modes look identical from the code and opposite
-- from the driver's seat.
--
-- Disabling at zero rather than leaving it enabled at zero is also just
-- correct: an emitter at Rate 0 still costs a slot every frame.
local function setRate(emitter, rate)
	if not emitter then return end
	emitter.Rate = rate
	emitter.Enabled = rate > 0
end

-- Measured once per model and hung off the rig, because walking the tree for
-- four emitters and a sound every frame is not free and none of it moves.
local function fxOf(model, rig)
	if rig.fx then return rig.fx end

	local chassis = rig.chassis
	local audio = model:FindFirstChild("Chassis") or chassis

	-- ALL of them. FindFirstChild took the first and left the second silent,
	-- which on a twin-pipe car reads as one of them being broken.
	local exhausts = {}
	for _, child in ipairs(model:GetChildren()) do
		if string.find(string.lower(child.Name), "exhaust", 1, true) then
			table.insert(exhausts, {
				backfire = findByName(child, "backfire", "ParticleEmitter"),
				-- "backfiresmoke" FIRST, then plain smoke: findByName matches by
				-- containment, so searching for "smoke" would happily return
				-- the backfire cloud and leave the idle haze unfound.
				smoke = findByName(child, "smoke", "ParticleEmitter", "backfire"),
				backfireSmoke = findByName(child, "backfiresmoke", "ParticleEmitter"),
			})
		end
	end

	local fx = {
		-- "fan" REJECTED, or the radiator fan wins this lookup half the time.
		--
		-- Matching is by containment, so "engine" finds both Engine and
		-- Engine_Fan and which one you get is the order Studio happens to
		-- list them in -- the same trap that made the idle haze and the
		-- backfire cloud swap places, and the reason `reject` exists.
		engine = findByName(audio, "engine", "Sound", "fan")
			or findByName(chassis, "engine", "Sound", "fan"),

		-- The radiator fan. Searched for on its own terms rather than as a
		-- second "engine": a car without one simply has no fan sound, which
		-- is a normal car, not a broken one.
		fan = findByName(audio, "fan", "Sound")
			or findByName(chassis, "fan", "Sound"),

		-- "screech" rather than "tire", because the wheels are already called
		-- tyres and matching on that would pick up a rolling-noise loop or a
		-- tyre-blowout one-shot sitting beside it. Both spellings, since the
		-- part names in this model are American and the code is not.
		screech = findByName(audio, "screech", "Sound")
			or findByName(audio, "skid", "Sound")
			or findByName(chassis, "screech", "Sound"),

		backfireSound = findByName(audio, "backfire", "Sound")
			or findByName(chassis, "backfire", "Sound"),

		turboSpool = findByName(audio, "turbospool", "Sound")
			or findByName(audio, "spool", "Sound"),
		bov = findByName(audio, "bov", "Sound")
			or findByName(audio, "blowoff", "Sound"),

		-- "start" rather than "engine", or it would match the engine loop --
		-- which sits beside it and is what the misspelling in this model
		-- ("EgineStart") would otherwise fall back to.
		engineStart = findByName(audio, "start", "Sound"),

		exhausts = exhausts,
		wheelSmoke = {},
	}

	-- Per wheel, off the thing the rig actually found -- which is the child of
	-- the Wheels folder, so a wheel built as a Model has its emitter looked
	-- for under the Model rather than under its PrimaryPart.
	for i, wheel in ipairs(rig.wheels) do
		fx.wheelSmoke[i] = findByName(wheel.holder or wheel.part, "smoke", "ParticleEmitter")
	end

	-- SOUNDS BECOME VOICES.
	--
	-- A voice plays the artist's Sound through the Advanced Audio API, so it
	-- goes through the engine's acoustic simulation the same way every
	-- movement sound already does -- and falls back to driving the Sound
	-- itself where the API is not available, so nothing below has to know
	-- which it got. See Player/AudioVoice.
	--
	-- It also owns the artist's volume and pitch, which is why the
	-- remembering that used to live here does not any more.
	fx.engine = AudioVoice.From(fx.engine)
	fx.fan = AudioVoice.From(fx.fan)
	fx.screech = AudioVoice.From(fx.screech)
	fx.backfireSound = AudioVoice.From(fx.backfireSound)
	fx.turboSpool = AudioVoice.From(fx.turboSpool)
	fx.bov = AudioVoice.From(fx.bov)
	fx.engineStart = AudioVoice.From(fx.engineStart)

	-- The rates the artist set are the loud end; everything below scales
	-- toward zero from them, so tuning the look stays in Studio.
	fx.baseRates = {}

	-- Per pipe, since two exhausts can be authored at different rates and
	-- averaging them would make the quieter one wrong in both directions.
	for _, pipe in ipairs(fx.exhausts) do
		pipe.baseSmoke = pipe.smoke and rememberedRate(pipe.smoke, 6) or 0
		pipe.baseBackfire = pipe.backfire and rememberedRate(pipe.backfire, 24) or 0
		pipe.baseBackfireSmoke = pipe.backfireSmoke
			and rememberedRate(pipe.backfireSmoke, 40) or 0
	end

	for i, emitter in pairs(fx.wheelSmoke) do
		fx.baseRates[i] = rememberedRate(emitter, 20)
	end

	-- Emitters are switched off to begin with. An artist leaves them enabled
	-- so they can see them while building, and a car should not arrive
	-- smoking from all four corners.
	for _, pipe in ipairs(fx.exhausts) do
		setRate(pipe.smoke, 0)
		setRate(pipe.backfire, 0)
		setRate(pipe.backfireSmoke, 0)
	end
	for _, emitter in pairs(fx.wheelSmoke) do setRate(emitter, 0) end

	rig.fx = fx
	return fx
end

--=====================================================================
-- ENGINE
--=====================================================================

-- Below this much slip the tyres are gripping as far as anyone can hear or
-- see, and both the noise and the smoke stay off.
--
-- A DEAD BAND, because slip is never exactly zero: a car tracking straight
-- down a road carries a percent or two of it, and mapping that straight onto
-- an effect means the tyres howl and smoulder quietly all the time, which
-- costs the effect the only thing it was for.
local SLIP_FLOOR = 0.18

-- How hard a tyre is sliding, as 0 to 1 above the dead band. ONE curve, used
-- by both the noise and the smoke, so a tyre that screeches also smokes.
-- Having them on separate mappings is what let a car be audibly sideways with
-- nothing coming off the tyres.
local function slipVoice(slip)
	return math.clamp((slip - SLIP_FLOOR) / (1 - SLIP_FLOOR), 0, 1)
end

-- The rpm-to-pitch CURVE is VehicleDefs.EnginePitch, so it can be tuned per
-- car -- RevScale, EnginePitchMin, EnginePitchMax -- and tested without a
-- Sound instance in the room.
--
-- What stays here is the one thing that is not the car's business: the speed
-- the SAMPLE was authored at. It is read once and multiplied rather than
-- overwritten, so setting PlaybackSpeed on the Sound in Studio still does
-- what it looks like it does. Overwriting it, against a fixed span of more
-- than a factor of four, is what made a loop already recorded at high revs
-- sound like a motorway in first gear.
local function enginePitch(fx, def, rpm)
	return fx.engine.basePitch * VehicleDefs.EnginePitch(def, rpm)
end

--=====================================================================
-- IGNITION
--=====================================================================

-- How far before the end of the crank the engine comes in under it. About a
-- fifth of a second: long enough to overlap audibly, short enough that the
-- starter is clearly finishing rather than being talked over.
local START_OVERLAP = 0.18

-- A crank that never reports finishing must not silence the engine forever.
-- Reached only when the sound's length is unknowable AND it claims to still
-- be playing, which should not happen -- but "should not happen" is how a car
-- ends up permanently silent with nothing in the log.
local CRANK_TIMEOUT = 5

local function cranking(fx)
	local start = fx.engineStart
	if not (start and fx.crankAt) then return false end

	if os.clock() - fx.crankAt > CRANK_TIMEOUT then return false end

	-- Remaining is 0 for a sound that has stopped, finished, or has not yet
	-- said how long it is -- and all three mean the same thing here: there is
	-- nothing left to wait for.
	return start:Remaining() > START_OVERLAP
end

--=====================================================================
-- UPDATE
--=====================================================================

-- state carries what the sim published. Everything is optional so an observed
-- car -- which only has what came over the wire -- drives the same code as
-- the driver's own.
--
--   rpm, gear, throttle, slipFront, slipRear, grounded, shiftedUp, backfired
--   wheelSlip   -- optional, one per wheel; the driver's own car only
--   fanSpeed    -- 0..1, how fast the radiator fan's blades are turning
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
		fx.engine:SetPitch(enginePitch(fx, def, rpm))
		fx.engine:SetVolume(fx.engine.baseVolume)

		-- HELD OFF WHILE THE STARTER IS TURNING.
		--
		-- The loop used to start on the same frame the crank did, so the two
		-- played over each other from the first sample and the ignition was
		-- an idle with a noise on top of it.
		--
		-- Not a gap and not a fade, though. A real engine CATCHES while the
		-- starter is still turning, so the loop comes in under the crank's
		-- last fraction of a second and the crank's tail covers the join. A
		-- gap reads as a cut; a fade reads as somebody turning a volume knob.
		if not cranking(fx) then
			-- Started here rather than assumed: a sound left not-playing in
			-- the model would otherwise be silent forever with no clue why.
			fx.engine:Resume()
		end
	end

	--------------------------------------------------------------
	-- RADIATOR FAN
	--------------------------------------------------------------
	-- Driven by the BLADE SPEED rather than by the switch, because that is
	-- what a fan winding up sounds like -- and because the cooling follows
	-- the same number, so what you hear and what is happening cannot drift.
	--
	-- Pitch as well as volume. A fan coming on is a rising note, and one that
	-- only got louder sounds like somebody turning it up.
	if fx.fan then
		local speed = math.clamp(state.fanSpeed or 0, 0, 1)

		fx.fan:SetVolume(fx.fan.baseVolume * speed)
		fx.fan:SetPitch(fx.fan.basePitch * (0.8 + speed * 0.25))

		if speed > 0.02 then
			fx.fan:Resume()
		elseif fx.fan:IsPlaying() then
			fx.fan:Stop()
		end
	end

	--------------------------------------------------------------
	-- BACKFIRE
	--------------------------------------------------------------
	-- A BURST, not a rate. The emitter is left at zero and given a one-shot
	-- of particles, which is what a backfire is -- a crack, not a plume.
	--
	-- Every pipe, together. A twin-pipe car that flamed out of one side would
	-- read as a fault rather than as a feature.
	if state.backfired then
		for _, pipe in ipairs(fx.exhausts) do
			if pipe.backfire then
				pipe.backfire:Emit(
					math.clamp(math.floor(pipe.baseBackfire * 0.5), 4, 40))
			end
			-- The cloud the flame leaves behind: more particles than the
			-- flame and no brighter, which is what makes a bang read as a
			-- bang rather than as a sparkle.
			if pipe.backfireSmoke then
				pipe.backfireSmoke:Emit(
					math.clamp(math.floor(pipe.baseBackfireSmoke * 0.8), 6, 60))
			end
		end
	end

	-- The crack. Rewound rather than just played, because a second shift
	-- inside the length of the sample would otherwise be silent -- Play on an
	-- already-playing Sound does nothing, and two fast upshifts is exactly
	-- when you want to hear two bangs.
	if fx.backfireSound and state.backfired then
		fx.backfireSound:Play()
	end

	--------------------------------------------------------------
	-- EXHAUST
	--------------------------------------------------------------
	-- Idles gently and thickens under load. Scaled off the rate the artist
	-- set, so the character of it stays theirs.
	do
		local throttle = math.clamp(state.throttle or 0, 0, 1)
		local revs = math.clamp(((state.rpm or def.idleRpm) - def.idleRpm)
			/ math.max(def.redlineRpm - def.idleRpm, 1), 0, 1)
		local load = math.clamp(0.25 + throttle * 0.5 + revs * 0.5, 0, 1)

		for _, pipe in ipairs(fx.exhausts) do
			setRate(pipe.smoke, pipe.baseSmoke * load)
		end
	end

	--------------------------------------------------------------
	-- TURBO
	--------------------------------------------------------------
	-- Both of these are gated on the car HAVING a turbo, not merely on the
	-- sounds existing: state.spool is zero on a car without one, so the loop
	-- would sit silent anyway -- but the valve is a one-shot and a car with a
	-- BOV sound and no turbo would chirp on every lift for no reason.
	local turbo = def.turbo == true

	if fx.turboSpool then
		local spool = turbo and math.clamp(state.spool or 0, 0, 1) or 0

		fx.turboSpool:SetVolume(fx.turboSpool.baseVolume * spool)
		-- Rising as it comes on song. A spool that only got louder sounds
		-- like a volume knob; the pitch is what makes it sound like it is
		-- spinning up.
		fx.turboSpool:SetPitch(fx.turboSpool.basePitch * (0.75 + spool * 0.5))

		if spool > 0.02 then
			fx.turboSpool:Resume()
		elseif fx.turboSpool:IsPlaying() then
			fx.turboSpool:Stop()
		end
	end

	-- The valve. Rewound for the same reason the backfire is: an upshift and
	-- a lift can land inside one sample's length, and the second one is the
	-- one you were listening for.
	if fx.bov and turbo and state.bov then
		fx.bov:Play()
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

	-- PER WHEEL when the sim gave us that, per END when it did not.
	--
	-- Only the driver's own car has the per-wheel numbers: an observed car is
	-- drawn from a packet carrying the two end values, and widening the wire
	-- format to carry four more floats per car per tick to smoke one tyre
	-- differently at a distance is not a trade worth making. So the fallback
	-- is not a degraded mode, it is the same behaviour this had before, and
	-- it is what everybody else sees.
	local perWheel = state.wheelSlip

	for i, emitter in pairs(fx.wheelSmoke) do
		local wheel = rig.wheels[i]
		local slip = perWheel and perWheel[i]
		if not slip then
			slip = (wheel and wheel.front) and front or rear
		end
		slip = math.clamp(slip, 0, 1)

		-- A wheel in the air does not smoke, however hard the car is sliding.
		-- Read per wheel where we can: with the per-wheel numbers, a wheel
		-- off the ground already reports zero slip, so this only matters for
		-- the end-value fallback.
		local voice = grounded and slipVoice(slip) or 0

		-- SQUARE ROOT, because a tyre either smokes or it does not. Scaling
		-- the artist's rate linearly means a car visibly sideways at a third
		-- of full slip gets a third of the particles, which at any sane
		-- authored rate is a handful a second and reads as nothing at all --
		-- you hear the tyres let go and see no smoke.
		setRate(emitter, (base[i] or 20) * math.sqrt(voice))
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
		local voice = slipVoice(slip)

		fx.screech:SetVolume(fx.screech.baseVolume * voice)
		-- Rising slightly as it gets worse, so a slow slide and a full lock-up
		-- are told apart by more than loudness.
		fx.screech:SetPitch(fx.screech.basePitch * (0.9 + voice * 0.3))

		if voice > 0 then
			fx.screech:Resume()
		elseif fx.screech:IsPlaying() then
			fx.screech:Stop()
		end
	end
end

-- What this layer actually resolved on a given car, as lines of text.
--
-- Every piece of art here is optional and matched by name, which is the right
-- trade for a system art has to be dropped into -- but it means the failure
-- mode is silence. An emitter named something unexpected, or parented
-- somewhere the search does not reach, produces a car that drives correctly
-- and does nothing else, with no error anywhere to say why. This turns that
-- into a question you can answer from the console.
function VehicleFX.Report(model, rig, live)
	if not (model and rig and rig.chassis) then return { "[fx] no rig" } end

	local fx = fxOf(model, rig)
	-- A voice knows whether it is going through the acoustic simulation or
	-- driving a plain Sound, and that is the first thing you want to know
	-- when a car sounds flat.
	local function voice(v)
		if not v then return "MISSING" end
		return ("%s  volume %.2f"):format(v:Describe(), v.baseVolume)
	end

	local function state(instance, rate)
		if not instance then return "MISSING" end
		if rate then
			-- Enabled is shown because "found, at a sensible rate, and
			-- switched off" is a real state and is invisible from the rate
			-- alone -- it is what kept the tyres from ever smoking.
			return ("%s (rate %.1f, %s)"):format(instance.Name, rate,
				instance.Enabled and "on" or "OFF")
		end
		return instance.Name
	end

	local def = rig.def
	live = live or {}

	local lines = {
		("[fx] %s"):format(model.Name),
	}

	-- WHERE THE NUMBERS CAME FROM, before what they are.
	--
	-- "I changed the class and the car sounds identical" has never once been
	-- the sound code. It is one of these three lines every time: the model is
	-- not that class, VehicleDefs has never heard of the class and quietly
	-- handed out sedan handling, or an attribute left on the model is beating
	-- the class -- which is what attributes are FOR, and is invisible unless
	-- something says so.
	do
		local class = model:GetAttribute("Class")
		table.insert(lines, ("  class         %s%s"):format(
			tostring(class or "(none set -- sedan handling)"),
			(class and not VehicleDefs.IsClass(class))
				and "  NOT IN VehicleDefs -- sedan handling" or ""))

		local overrides = VehicleDefs.Overrides(model, def)
		if #overrides == 0 then
			table.insert(lines, "  overrides     none (the class is what you hear)")
		else
			local parts = {}
			for _, entry in ipairs(overrides) do
				table.insert(parts, ("%s=%s"):format(entry.name, tostring(entry.value)))
			end
			table.insert(lines, ("  overrides     %s"):format(table.concat(parts, ", ")))
			table.insert(lines, "                (attributes on this model BEAT the class)")
		end

		-- The pitch curve, spelled out with the rpm range it is stretched
		-- over -- because half of "the pitch settings do nothing" turns out
		-- to be a redline that did not change either.
		table.insert(lines, ("  engine note   %.0f-%.0f rpm  ->  pitch %.2f-%.2f  x base %.2f"):format(
			def.idleRpm, def.redlineRpm,
			VehicleDefs.EnginePitch(def, def.idleRpm),
			VehicleDefs.EnginePitch(def, def.redlineRpm),
			fx.engine and fx.engine.basePitch or 1))

		if live.rpm then
			table.insert(lines, ("  right now     %.0f rpm  ->  pitch %.3f"):format(
				live.rpm, enginePitch(fx, def, live.rpm)))
		end
	end

	table.insert(lines, ("  engine        %s"):format(voice(fx.engine)))
	table.insert(lines, ("  fan           %s"):format(voice(fx.fan)))

	-- The fan is the one effect that is CORRECTLY silent most of the time, so
	-- "found, and not running" and "not found" look the same from the driver's
	-- seat. Printing the thresholds beside the temperature is the difference
	-- between a bug and a car that simply is not hot yet.
	if live.coolantTemp then
		table.insert(lines, ("  cooling       coolant %.0f  oil %.0f  fan %s at %.0f%%  (on %.0f / off %.0f)"):format(
			live.coolantTemp, live.oilTemp or 0,
			live.fanOn and "ON" or "off", (live.fanSpeed or 0) * 100,
			def.fanOnTemp or 97, def.fanOffTemp or 92))
	end

	local rest = {
		("  backfire snd  %s"):format(voice(fx.backfireSound)),
		("  screech snd   %s"):format(voice(fx.screech)),
		("  turbo spool   %s"):format(voice(fx.turboSpool)),
		("  bov snd       %s"):format(voice(fx.bov)),
		("  engine start  %s"):format(voice(fx.engineStart)),
		("  turbo on car  %s"):format(def.turbo == true and "yes" or "no"),
		("  exhausts      %d"):format(#fx.exhausts),
	}
	for _, line in ipairs(rest) do table.insert(lines, line) end

	-- Listed per pipe, because "exhausts 2" and a silent second one is the
	-- shape of the bug this report exists to name.
	for i, pipe in ipairs(fx.exhausts) do
		table.insert(lines, ("    #%d smoke %s | flame %s | cloud %s"):format(i,
			state(pipe.smoke, pipe.baseSmoke),
			state(pipe.backfire, pipe.baseBackfire),
			state(pipe.backfireSmoke, pipe.baseBackfireSmoke)))
	end

	for i, wheel in ipairs(rig.wheels) do
		table.insert(lines, ("  wheel %-8s %s"):format(
			wheel.name or ("#" .. i),
			state(fx.wheelSmoke[i], fx.baseRates[i])))
	end

	return lines
end

-- The ignition, on getting in. Separate from Update because it is an EVENT
-- and Update is a per-frame state function -- a one-shot driven from a state
-- flag would need the flag cleared by whoever set it, and forgetting that is
-- a starter motor that grinds every frame.
function VehicleFX.Start(model, rig)
	if not (model and rig and rig.chassis) then return end

	local fx = fxOf(model, rig)

	-- Recorded even when there is no crank sound, so the timeout below has a
	-- clock to measure from and the engine is never gated on a nil.
	fx.crankAt = os.clock()

	if not fx.engineStart then return end
	fx.engineStart:Play()
end

-- Called when a car stops being driven or watched, so it does not sit there
-- revving and smoking with nobody in it.
function VehicleFX.Quiet(rig)
	local fx = rig and rig.fx
	if not fx then return end

	-- Or getting straight back in inherits the last drive's ignition clock
	-- and the engine either waits for a crank that is not playing or starts
	-- under one that is.
	fx.crankAt = nil
	if fx.engineStart then fx.engineStart:Stop() end

	if fx.engine then fx.engine:Stop() end
	if fx.screech then
		fx.screech:SetVolume(0)
		fx.screech:Stop()
	end
	if fx.turboSpool then
		fx.turboSpool:SetVolume(0)
		fx.turboSpool:Stop()
	end
	if fx.fan then
		fx.fan:SetVolume(0)
		fx.fan:Stop()
	end

	for _, pipe in ipairs(fx.exhausts) do
		setRate(pipe.smoke, 0)
		setRate(pipe.backfire, 0)
		setRate(pipe.backfireSmoke, 0)
	end
	for _, emitter in pairs(fx.wheelSmoke) do setRate(emitter, 0) end
end

return VehicleFX
