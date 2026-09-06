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

	-- The screech is a LOOP whose volume is the effect, so the artist's volume
	-- is the loud end the same way their Rate is. Captured before anything
	-- here touches it, or the first quiet frame would become the new maximum
	-- and the sound would fade away over the session.
	if fx.engine then
		-- Same reasoning as the rates: remembered on the instance, because
		-- this code overwrites PlaybackSpeed every frame and a rebuilt rig
		-- would otherwise read last frame's pitch as the artist's.
		local saved = fx.engine:GetAttribute("FXBasePitch")
		if saved == nil then
			saved = fx.engine.PlaybackSpeed
			fx.engine:SetAttribute("FXBasePitch", saved)
		end
		fx.enginePitch = saved
	end

	if fx.screech then
		local saved = fx.screech:GetAttribute("FXBaseVolume")
		if saved == nil then
			saved = fx.screech.Volume
			fx.screech:SetAttribute("FXBaseVolume", saved)
		end
		fx.screechVolume = saved
		fx.screechPitch = fx.screech.PlaybackSpeed
		fx.screech.Volume = 0
	end
	-- The spool is a LOOP whose volume is the effect, exactly like the
	-- screech, so the artist's volume is its loud end.
	if fx.turboSpool then
		local saved = fx.turboSpool:GetAttribute("FXBaseVolume")
		if saved == nil then
			saved = fx.turboSpool.Volume
			fx.turboSpool:SetAttribute("FXBaseVolume", saved)
		end
		fx.spoolVolume = saved
		fx.spoolPitch = fx.turboSpool.PlaybackSpeed
		fx.turboSpool.Volume = 0
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
	return (fx.enginePitch or 1) * VehicleDefs.EnginePitch(def, rpm)
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
		fx.engine.PlaybackSpeed = enginePitch(fx, def, rpm)

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
		fx.backfireSound.TimePosition = 0
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

		fx.turboSpool.Volume = (fx.spoolVolume or 0.5) * spool
		-- Rising as it comes on song. A spool that only got louder sounds
		-- like a volume knob; the pitch is what makes it sound like it is
		-- spinning up.
		fx.turboSpool.PlaybackSpeed = (fx.spoolPitch or 1) * (0.75 + spool * 0.5)

		if spool > 0.02 then
			if not fx.turboSpool.IsPlaying then
				fx.turboSpool.Looped = true
				fx.turboSpool:Play()
			end
		elseif fx.turboSpool.IsPlaying then
			fx.turboSpool:Stop()
		end
	end

	-- The valve. Rewound for the same reason the backfire is: an upshift and
	-- a lift can land inside one sample's length, and the second one is the
	-- one you were listening for.
	if fx.bov and turbo and state.bov then
		fx.bov.TimePosition = 0
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

	for i, emitter in pairs(fx.wheelSmoke) do
		local wheel = rig.wheels[i]
		local slip = (wheel and wheel.front) and front or rear

		-- A wheel in the air does not smoke, however hard the car is sliding.
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

-- What this layer actually resolved on a given car, as lines of text.
--
-- Every piece of art here is optional and matched by name, which is the right
-- trade for a system art has to be dropped into -- but it means the failure
-- mode is silence. An emitter named something unexpected, or parented
-- somewhere the search does not reach, produces a car that drives correctly
-- and does nothing else, with no error anywhere to say why. This turns that
-- into a question you can answer from the console.
function VehicleFX.Report(model, rig)
	if not (model and rig and rig.chassis) then return { "[fx] no rig" } end

	local fx = fxOf(model, rig)
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

	local lines = {
		("[fx] %s"):format(model.Name),
		("  engine        %s"):format(state(fx.engine)),
		("  backfire snd  %s"):format(state(fx.backfireSound)),
		("  screech snd   %s%s"):format(state(fx.screech),
			fx.screech and (" (volume %.2f)"):format(fx.screechVolume or 0) or ""),
		("  turbo spool   %s%s"):format(state(fx.turboSpool),
			fx.turboSpool and (" (volume %.2f)"):format(fx.spoolVolume or 0) or ""),
		("  bov snd       %s"):format(state(fx.bov)),
		("  engine start  %s"):format(state(fx.engineStart)),
		("  turbo on car  %s"):format(rig.def.turbo == true and "yes" or "no"),
		("  exhausts      %d"):format(#fx.exhausts),
	}

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
	if not fx.engineStart then return end

	fx.engineStart.TimePosition = 0
	fx.engineStart:Play()
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
	if fx.turboSpool then
		fx.turboSpool.Volume = 0
		if fx.turboSpool.IsPlaying then fx.turboSpool:Stop() end
	end

	for _, pipe in ipairs(fx.exhausts) do
		setRate(pipe.smoke, 0)
		setRate(pipe.backfire, 0)
		setRate(pipe.backfireSmoke, 0)
	end
	for _, emitter in pairs(fx.wheelSmoke) do setRate(emitter, 0) end
end

return VehicleFX
