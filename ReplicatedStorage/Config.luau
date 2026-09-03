-- ModuleScript: Config
-- Every tunable in one place. Change at runtime with Config.Set("key", value)
-- from the console; types are coerced from strings automatically.
--
-- Units: 1 stud is roughly 11 GoldSrc units. CS 1.6 cvar values are noted in
-- comments where a setting has a direct counterpart, so it's clear what is
-- faithful and what is a deliberate departure.
--
-- FLAG DISCIPLINE, since the two are easy to conflate:
--   CHEAT      gates a write behind sv_cheats. It does NOT replicate.
--   REPLICATED means the server owns the value and pushes it to clients.
-- Anything the movement simulation reads must be REPLICATED, or a server-side
-- change never reaches the predicting client and validation diverges from
-- prediction. Most sim cvars want both flags.

local RunService = game:GetService("RunService")
local isServer = RunService:IsServer()

local Config = {}

-- Store actual values here so we can separate them from metadata
Config.Values = {}
Config.Defaults = {}    -- pristine values, for `reset`
Config.Flags = {}
Config.Listeners = {}   -- [key] = { fn, fn, ... }
Config.Commands = {}
Config.CommandListeners = {}
Config.RemoteCommands = {}

-- FCVAR enum equivalents
local FCVAR = {
	CLIENT     = 1, -- Client can change freely
	REPLICATED = 2, -- Server enforces; syncs to clients
	CHEAT      = 4, -- Locked behind sv_cheats 1
}

function Config.HasFlag(key, flag)
	return bit32.band(Config.Flags[key] or FCVAR.CLIENT, flag) ~= 0
end

Config.FCVAR = FCVAR

-- Helper to cleanly define cvars with their flags
local function Define(key, default, flag)
	Config.Values[key] = default
	Config.Defaults[key] = default
	Config.Flags[key] = flag or FCVAR.CLIENT
end

--=====================================================================
-- MOVEMENT  (CS 1.6 / GoldSrc)
--=====================================================================
-- REPLICATED + CHEAT throughout: the client predicts movement locally, so it
-- needs the same numbers the server validates against.

Define("mv_walkSpeed", 22.7, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_walkKeySpeed", 11, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_crouchSpeed", 7.5, FCVAR.REPLICATED + FCVAR.CHEAT) -- ~0.33x walk
Define("mv_proneSpeed", 9, FCVAR.REPLICATED + FCVAR.CHEAT)

Define("mv_groundAcceleration", 5, FCVAR.REPLICATED + FCVAR.CHEAT)   -- sv_accelerate 5
Define("mv_airAcceleration", 10, FCVAR.REPLICATED + FCVAR.CHEAT)     -- sv_airaccelerate 10
Define("mv_airSpeedCap", 2.72, FCVAR.REPLICATED + FCVAR.CHEAT)       -- 30 units
Define("mv_groundFriction", 4, FCVAR.REPLICATED + FCVAR.CHEAT)       -- sv_friction 4
Define("mv_stopSpeed", 9.1, FCVAR.REPLICATED + FCVAR.CHEAT)          -- sv_stopspeed 100
Define("mv_landFrictionMult", 1.5, FCVAR.REPLICATED + FCVAR.CHEAT)   -- extra bite on the landing tick

Define("mv_gravity", 72.7, FCVAR.REPLICATED)              -- sv_gravity 800
Define("mv_jumpForce", 24.4, FCVAR.REPLICATED)            -- 268 units; apex = v^2/2g = 4.09 studs
Define("mv_maxFallSpeed", 181, FCVAR.REPLICATED)          -- terminal velocity, 2000 units
Define("mv_maxStepHeight", 1.63, FCVAR.REPLICATED)        -- 18 units

Define("mv_surfOverbounce", 1.0, FCVAR.REPLICATED)        -- 1.0 exactly; anything more mints speed
Define("mv_maxHorizontalSpeed", 0, FCVAR.REPLICATED)      -- 0 = uncapped

-- sv_maxvelocity 3500. Source clamps each AXIS independently rather than the
-- magnitude, so a diagonal legitimately reaches cap * sqrt(2). Distinct from
-- mv_maxFallSpeed, which is the tighter terminal-velocity clamp on Y alone.
Define("mv_maxVelocity", 320, FCVAR.REPLICATED + FCVAR.CHEAT)

-- Source steps DOWN only a fraction of max step height; below that you enter
-- air-move and let gravity do it. 1.0 keeps the current glued-to-slopes feel.
Define("mv_stepDownFraction", 1.0, FCVAR.REPLICATED + FCVAR.CHEAT)

-- HandleSlopeBoosting: clamps a clip that RAISES speed back to the incoming
-- magnitude. That gain IS surf, so leaving this false is what keeps surf maps
-- working. Only turn it on for a mode that shouldn't have surf at all.
Define("mv_slopeBoostFix", false, FCVAR.REPLICATED + FCVAR.CHEAT)

-- surface friction  (Source m_surfaceFriction)
-- Source scales BOTH the friction term and ground acceleration by the
-- surface's value, which is why ice is slippery to stop on AND slow to get
-- moving on. Roblox Plastic sits at 0.3 friction, so that is our stand-in for
-- Source's 1.0 reference.
Define("mv_surfaceFriction", true, FCVAR.REPLICATED)
Define("mv_surfaceFrictionRef", 0.3, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_minSurfaceFriction", 0.1, FCVAR.REPLICATED + FCVAR.CHEAT) -- floor; ice never goes frictionless

-- edge friction  (sv_edgefriction)
-- Doubled friction when there's nothing under the point ahead of your feet.
-- This is the entire reason Source players stop on a crate rim instead of
-- sliding off it. Set to 1 to disable.
Define("mv_edgeFriction", 2.0, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_edgeFrictionDist", 1.45, FCVAR.REPLICATED + FCVAR.CHEAT)   -- 16 units ahead
Define("mv_edgeFrictionHeight", 3.1, FCVAR.REPLICATED + FCVAR.CHEAT)  -- 34 units of probe depth
Define("mv_edgeFrictionOnlyWhenBraking", true, FCVAR.REPLICATED)      -- PB behaviour; GoldSrc applied it always
Define("mv_edgeFrictionAlwaysWhenCrouching", true, FCVAR.REPLICATED)

-- Grounded time before friction is allowed to bite at all. This is what lets
-- a frame-perfect bhop keep all its speed rather than paying one tick.
Define("mv_brakingWindow", 0.015, FCVAR.REPLICATED + FCVAR.CHEAT)

-- stance transitions  (Source TIME_TO_DUCK / TIME_TO_UNDUCK)
-- Ducking is timed on the ground but INSTANT in the air, which is what snaps
-- the feet up in a crouch-jump. Uncrouch inverts it: fast on the ground, slow
-- in the air, so you can't insta-extend to grab a ledge. Set all four to 0
-- for instant, pre-Source stance changes.
Define("mv_crouchTime", 0.4, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_uncrouchTime", 0.2, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_crouchJumpTime", 0.0, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_uncrouchJumpTime", 0.8, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_crouchHeightFrac", 0.6, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_proneHeightFrac", 0.3, FCVAR.REPLICATED + FCVAR.CHEAT)
-- false = speed follows the HULL, so you keep run speed until the duck
-- actually completes (Source). true = speed follows the keypress.
Define("mv_instantCrouchSpeed", false, FCVAR.REPLICATED)

-- ladder
Define("mv_ladderClimbSpeed", 18.2, FCVAR.REPLICATED + FCVAR.CHEAT)  -- 200 units
Define("mv_ladderPushOff", 24.5, FCVAR.REPLICATED + FCVAR.CHEAT)     -- 270 units, the jump-off impulse
Define("mv_ladderGrabRange", 0.6, FCVAR.REPLICATED + FCVAR.CHEAT)    -- studs of reach past the hull
-- LADDER_MOUNT_TIMEOUT. Without it, pushing off re-grabs on the next tick
-- because you're still inside the grab volume.
Define("mv_ladderTimeout", 0.2, FCVAR.REPLICATED + FCVAR.CHEAT)

Define("mv_noclipSpeed", 45, FCVAR.CHEAT)

--=====================================================================
-- MOVEMENT TOGGLES
--=====================================================================

Define("mv_autoBhop", false, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_crouchHold", true, FCVAR.CLIENT)               -- false = toggle crouch
Define("mv_walkKeyToggle", false, FCVAR.CLIENT)           -- false = hold to walk
-- Per-weapon movement speed (CS:GO MaxPlayerSpeed). Each weapon module may
-- carry maxPlayerSpeed in studs/second; the held weapon's value becomes a
-- ratio of mv_walkSpeed and scales every stance with it. A knife runs at the
-- full 250 units, a rifle at 215, a Negev at 150 -- which is what makes
-- switching to the knife to rotate an actual decision. Off = every weapon
-- moves at mv_walkSpeed.
Define("mv_weaponSpeed", true, FCVAR.REPLICATED)

Define("mv_canWalk", true, FCVAR.REPLICATED)
Define("mv_canProne", false, FCVAR.REPLICATED)
Define("mv_canDive", false, FCVAR.REPLICATED)

Define("mv_coyoteTime", 0.05, FCVAR.REPLICATED)           -- grace after leaving ground
Define("mv_jumpBuffer", 0.05, FCVAR.REPLICATED)           -- early jump press still fires

-- Departure from GoldSrc: lets step-up keep working at supersonic speeds.
Define("mv_scaleStepWithSpeed", true, FCVAR.REPLICATED)

-- Stepping while AIRBORNE. Source only steps in WalkMove, which is why a lip
-- an inch high stops a bhop dead and a seam between two surf brushes ends the
-- run. Airborne steps carry no walkable-surface requirement (there is nothing
-- to stand on) and hand the lift back in full when nothing is under the
-- landing, so clearing an edge never grants height -- only the horizontal
-- progress is kept. A lift that buys no distance is discarded, which is what
-- stops it becoming a way to climb walls.
Define("mv_airStep", true, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_airStepHeight", 1.63, FCVAR.REPLICATED + FCVAR.CHEAT)  -- 18 units, same as the ground step
-- How steep a blocking surface has to be before an airborne step will try to
-- get over it, as |normal.Y|. 0.3 is about 72 degrees. Anything flatter is a
-- ramp and must be CLIPPED rather than stepped -- clipping along a ramp is
-- what surf is, and stepping over one instead skips it entirely.
Define("mv_airStepMaxNormalY", 0.3, FCVAR.REPLICATED + FCVAR.CHEAT)

-- Reports, once a second at most, every time the slide resolver costs you more
-- than half your horizontal speed in a single tick -- naming which branch did
-- it and how many planes were involved. The console captures client warnings,
-- so this answers "what just ate my run" without a debug build.
Define("mv_debugStops", false, FCVAR.CLIENT)

Define("mv_diveForceForward", 155, FCVAR.REPLICATED)
Define("mv_diveForceUp", 35, FCVAR.REPLICATED)

--=====================================================================
-- ADVANCED MOVEMENT TECH
--=====================================================================

-- Accelerated Back Hopping (Source PM_Jump bug). The speed cap correction is
-- applied along the VIEW vector rather than the movement vector, so moving
-- backwards turns a reduction into a gain.
Define("mv_abh", false, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_abhBoostPerc", 0.5, FCVAR.REPLICATED + FCVAR.CHEAT)         -- normal stance
Define("mv_abhBoostPercDucked", 0.1, FCVAR.REPLICATED + FCVAR.CHEAT)   -- ducked/walking: lower cap, more gain

-- Ground strafing. Ducking briefly unglues you from the floor; those airborne
-- frames run air-accel instead of friction.
Define("mv_groundStrafe", true, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("mv_duckLiftTime", 0.12, FCVAR.REPLICATED + FCVAR.CHEAT)        -- SECONDS of airborne window per duck
Define("mv_sgsCapMult", 4, FCVAR.REPLICATED + FCVAR.CHEAT)             -- raises the air cap during lift frames
Define("mv_sgsFrictionMult", 0.3, FCVAR.REPLICATED + FCVAR.CHEAT)      -- friction between notches; 1 = authentic
Define("mv_sgsGraceTime", 0.15, FCVAR.REPLICATED + FCVAR.CHEAT)        -- how long that softening lasts

-- 0 = raw input (authentic), 1 = the optimal strafe angle computed for you.
-- Server-owned: this is an aim assist for movement.
Define("mv_strafeAssist", 0, FCVAR.REPLICATED + FCVAR.CHEAT)

--=====================================================================
-- CS:GO JUMP LIMITS  (stamina, PreventBunnyJumping)
--=====================================================================
-- The two things CS:GO added on top of GoldSrc movement, and the reason
-- bunnyhopping does not work there. BOTH SHIP OFF: this engine's surf, ABH
-- and ground-strafe tech all assume a jump you can repeat, and turning either
-- of these on by default would quietly undo work that has been tuned around
-- their absence. Turn them on for CS:GO-accurate movement.
--
-- Modelled on CS:GO's behaviour and named after its cvars. The costs are
-- expressed as a FRACTION of sv_staminamax, and recovery in stamina per
-- second; CS:GO's internal float scaling is not reproduced exactly.

Define("mv_stamina", false, FCVAR.REPLICATED + FCVAR.CHEAT)  -- master toggle
Define("sv_staminamax", 80, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("sv_staminajumpcost", 0.08, FCVAR.REPLICATED + FCVAR.CHEAT)   -- per jump
Define("sv_staminalandcost", 0.05, FCVAR.REPLICATED + FCVAR.CHEAT)   -- per landing
Define("sv_staminarecoveryrate", 60, FCVAR.REPLICATED + FCVAR.CHEAT) -- per second

-- CS:GO's PreventBunnyJumping: horizontal speed is clamped to this multiple of
-- your max speed at the moment you jump, which is what stops a chain of hops
-- compounding. 1.2 is CS:GO's number; 0 disables the clamp entirely.
Define("mv_bunnyJumpCap", 0, FCVAR.REPLICATED + FCVAR.CHEAT)

--=====================================================================
-- SERVER / TICKRATE
--=====================================================================

Define("sv_PhysicsHz", 240, FCVAR.REPLICATED)             -- CS 1.6 ran 100; KZ servers pin theirs
Define("sv_MaxCatchupSteps", 20, FCVAR.REPLICATED)        -- accumulator clamp; raise for 240Hz

--=====================================================================
-- CAMERA
--=====================================================================

Define("cam_fov", 80, FCVAR.CLIENT)
Define("cl_mouseSensitivity", 0.2, FCVAR.CLIENT)

-- REPLICATED as well as CHEAT: eye height is a wallhack vector, and CHEAT
-- alone only holds while sv_cheats is 0.
Define("cl_standingCamHeight", 2, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("cl_crouchingCamHeight", 1, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("cl_proneCamHeight", 0, FCVAR.REPLICATED + FCVAR.CHEAT)

--=====================================================================
-- VIEW BOB  (GoldSrc cvar names)
--=====================================================================

Define("cl_bobEnabled", true, FCVAR.CLIENT)
Define("cl_bob", 0.005, FCVAR.CLIENT)                 -- Source coefficient; leave it, the clamp is just above
Define("cl_bobcycle", 0.6, FCVAR.CLIENT)
Define("cl_bobup", 0.5, FCVAR.CLIENT)

Define("cl_rollangle", 0, FCVAR.CLIENT)
Define("cl_rollspeed", 18.2, FCVAR.CLIENT)
Define("cl_idleScale", 0, FCVAR.CLIENT)

-- Master amplitude over the Source bob term, applied AFTER the (-7,+4) unit
-- clamp so it can exceed it without clipping the sine. 1.0 = Source-exact,
-- which reads as nearly nothing at this FOV and viewmodel distance.
Define("cl_bobAmtVert", 2.5, FCVAR.CLIENT)
Define("cl_bobAmtLat", 2.5, FCVAR.CLIENT)

-- Source translates the gun by only 0.1x the bob and lets the ANGLES carry
-- the motion. Faithful, and invisible here. This scales translation alone,
-- so the angle-dominant character survives while the slide becomes readable.
Define("cl_bobTrans", 3.0, FCVAR.CLIENT)

-- CS:GO lowers the viewmodel while you move (cl_bob_lower_amt, which ships at
-- 21 of 30 there -- it is not a subtle effect in that game). This shipped at 0,
-- so the gun sat at exactly the same height standing still and sprinting.
-- 0.03 is the settle this file's own note recommends; raise toward 0.06 for
-- something closer to CS:GO's droop.
Define("cl_bobLowerAmt", 0.03, FCVAR.CLIENT)

-- Set to walk speed, not 320 units. Source's 320 leaves a running player at a
-- 0.78 ratio, which stretches every cycle by 28%. At walk speed the ratio
-- reaches 1.0 and cl_bobcycle means what it says.
Define("cl_bobMaxSpeed", 22.7, FCVAR.CLIENT)
Define("cl_bobSpeedSlew", 60, FCVAR.CLIENT)           -- Source's 320u/s^2 takes 0.78s to spin up; too slow to feel
Define("cl_bobInAir", true, FCVAR.CLIENT)
Define("cl_bobCamera", false, FCVAR.CLIENT)           -- true restores GoldSrc camera bob

Define("cl_punchStiffness", 65, FCVAR.CLIENT)
Define("cl_punchDamping", 9, FCVAR.CLIENT)

-- PUNCH_SPRING_CONSTANT / PUNCH_DAMPING from CBasePlayer::DecayPunchAngle.
Define("cl_punchStiffness", 65, FCVAR.CLIENT)
Define("cl_punchDamping", 9, FCVAR.CLIENT)

--=====================================================================
-- VIEWMODEL
--=====================================================================

Define("vm_offsetX", 0, FCVAR.CLIENT)
Define("vm_offsetY", -1.62, FCVAR.CLIENT)
Define("vm_offsetZ", 0, FCVAR.CLIENT)
Define("vm_pitch", 0, FCVAR.CLIENT)
Define("vm_yaw", 0, FCVAR.CLIENT)
Define("vm_roll", 0, FCVAR.CLIENT)
Define("vp_lockPitch", false, FCVAR.CLIENT)               -- arms stay level when looking up/down

Define("vm_pushback", true)         -- master toggle
Define("vm_pushbackMax", 1.5)       -- studs, hard clamp on retraction
Define("vm_pushbackMargin", 0.25)   -- clearance the muzzle keeps off the surface
Define("vm_pushbackRadius", 0.3)    -- spherecast radius; handles corners/edges
Define("vm_pushbackInSpeed", 30)    -- retract rate (fast)
Define("vm_pushbackOutSpeed", 12)   -- return rate (slower, CS-ish)
Define("vm_pushbackRotate", 0)      -- deg of downward pitch at full push; 5-8 for a CoD-style lower

Define("cl_showViewmodelMode", 0, FCVAR.CLIENT)           -- 0 show, 1 hide, 2 serverside
Define("cl_showLimbsInFirstPerson", false, FCVAR.CLIENT)
Define("cl_sharedWeaponAnims", true, FCVAR.CLIENT)        -- puppet reuses viewmodel weapon poses

-- Viewmodel sway (master toggle)
Define("vm_sway", true)

-- Rotational lag from mouse movement
Define("vm_lagYaw", -0.010)       -- deg of gun yaw per deg/s of mouse yaw
Define("vm_lagPitch", -0.008)
Define("vm_lagMax", 6)            -- deg clamp, both axes
Define("vm_lagPosX", -0.0022)     -- studs of lateral slide per deg/s
Define("vm_lagPosY", -0.0018)
Define("vm_lagPosMax", 0.35)      -- studs clamp
Define("vm_lagSmooth", 11)        -- response rate; lower = floatier

-- Movement sway
Define("vm_moveSide", 0.020)      -- studs per stud/s of strafe velocity
Define("vm_moveFwd", 0.01)
Define("vm_moveVert", 0.008)
Define("vm_moveRoll", 1.0)        -- deg of bank per stud/s of strafe
Define("vm_moveMax", 0.50)        -- studs clamp per axis
Define("vm_moveRollMax", 15)      -- deg clamp
Define("vm_moveSmooth", 7)

-- Fire kick. CS:GO jolts the VIEWMODEL on every shot, separately from the aim
-- punch it puts on the camera -- this engine had the camera half only, so the
-- gun itself never moved when you pulled the trigger.
--
-- The kick scales with the current inaccuracy cone, and the cone is mostly
-- movement, so firing on the run visibly throws the gun around more than
-- firing planted. That is the velocity connection: it is the same number the
-- crosshair gap is drawn from.
Define("vm_fireKick", 0.055)          -- studs of backward travel per shot, at rest
Define("vm_fireKickPitch", 85)        -- deg of muzzle rise per stud of kick
Define("vm_fireKickYaw", 10)          -- deg of random lateral whip
Define("vm_fireKickRoll", 7)
Define("vm_fireKickFreq", 9)          -- Hz; stiffer than the landing spring
Define("vm_fireKickDamp", 0.5)
Define("vm_fireKickMoveMult", 1.5)    -- extra kick at a full-size cone; 0 = ignore movement
Define("vm_fireKickSpreadRef", 3)     -- degrees of cone that counts as "full"

-- Jump / land impulses
Define("vm_jumpKick", 0.05)       -- studs, downward on takeoff
Define("vm_landDip", 0.0015)      -- studs per stud/s of impact speed
Define("vm_landDipMax", 0.55)
Define("vm_landPitch", 45)        -- deg of pitch per stud of dip
Define("vm_springFreq", 4.5)      -- Hz
Define("vm_springDamp", 0.42)     -- <1 underdamped, gives the bounce back

-- Sprint pose
Define("vm_sprintPose", true)
Define("vm_sprintX", 0.25)
Define("vm_sprintY", -0.18)
Define("vm_sprintZ", 0.15)
Define("vm_sprintPitch", -8)
Define("vm_sprintYaw", 22)
Define("vm_sprintRoll", -12)
Define("vm_sprintBlend", 8)       -- blend rate in/out

--=====================================================================
-- CHARACTER RENDERING
--=====================================================================

--=====================================================================
-- REMOTE INTERPOLATION  (Source cl_interp)
--=====================================================================
-- Remote puppets are rendered in the PAST, between the two snapshots that
-- bracket now - cl_interp, rather than snapped to the newest packet. PuppetSync
-- is unreliable and fires from a RenderStepped loop, so packets arrive at an
-- irregular rate and some never arrive at all -- snapping to each one shows
-- every bit of that as jitter.
--
-- The cost is latency: a remote player is drawn cl_interp seconds behind where
-- they say they are. Hit registration already rewinds, so this does not cost
-- accuracy -- only the size of the lead you have to give a moving target.

Define("cl_interpolateRemotes", true, FCVAR.CLIENT)
Define("cl_interp", 0.1, FCVAR.CLIENT)            -- seconds of buffer
-- Ran dry (a gap longer than cl_interp): coast on the last known velocity for
-- up to this long before freezing. Beyond it, a stale pose beats a wrong one.
Define("cl_extrapolate", true, FCVAR.CLIENT)
Define("cl_extrapolateMax", 0.25, FCVAR.CLIENT)

Define("cl_noOrient", false, FCVAR.CLIENT)
Define("cl_hidepuppet", false, FCVAR.CLIENT)
Define("cl_showbody", false, FCVAR.CLIENT)

--=====================================================================
-- WEAPONS
--=====================================================================

Define("wp_noFireWhileSprinting", true, FCVAR.REPLICATED) -- Game mechanic, must be enforced globally
Define("wp_autoReloadOnEmpty", false, FCVAR.CLIENT)       -- CS doesn't
Define("weapon_recoil_scale", 1.5, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("weapon_recoil_variance", 0.0, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("weapon_recoil_cooldown", 0.25, FCVAR.REPLICATED)
Define("weapon_recoil_reset_rate", 14, FCVAR.REPLICATED)
Define("weapon_recoil_decay_exp", 2.0, FCVAR.REPLICATED)
Define("weapon_recoil_decay_lin", 6.0, FCVAR.REPLICATED)
Define("weapon_accuracy_delay", 0.15, FCVAR.REPLICATED)
Define("weapon_recoil_view_punch_extra", 0, FCVAR.REPLICATED)
Define("weapon_recoil_view_ratio", 1, FCVAR.REPLICATED)
-- Was the number 1, which made `cl_spray_debug false` fail type coercion.
Define("cl_spray_debug", false, FCVAR.CLIENT + FCVAR.CHEAT)

--=====================================================================
-- DROP / PICKUP
--=====================================================================
-- REPLICATED throughout: the server owns every inventory change, and the
-- client only needs these to decide whether to show a prompt.

Define("sv_dropWeapons", true, FCVAR.REPLICATED)    -- master toggle for dropping
-- Gentle on purpose. A hard throw lands the weapon well outside pickup range,
-- which looks exactly like a broken pickup: you drop a rifle, walk to where
-- you think it went, and nothing happens.
Define("sv_dropForce", 14, FCVAR.REPLICATED)        -- studs/s of forward toss
Define("sv_dropUpForce", 6, FCVAR.REPLICATED)       -- studs/s of lift, so it arcs
Define("sv_dropSpin", 9, FCVAR.REPLICATED)          -- rad/s of tumble; 0 = none
Define("sv_dropJitter", 3, FCVAR.REPLICATED)        -- studs/s of random scatter on the toss
Define("sv_dropInherit", 1, FCVAR.REPLICATED)       -- how much of the thrower's velocity carries
Define("sv_dropOnDeath", true, FCVAR.REPLICATED)    -- a corpse leaves its weapon behind
Define("sv_dropMelee", false, FCVAR.REPLICATED)     -- CS won't let you drop the knife

-- Measured from the RawBody's centre, not the player's feet or hands, so this
-- wants to be roomier than the arm's-length number it looks like.
Define("sv_pickupRange", 12, FCVAR.REPLICATED)      -- studs from the body to +use
Define("sv_pickupFeedback", true, FCVAR.REPLICATED) -- say why a drop or pickup was refused
Define("sv_pickupAuto", false, FCVAR.REPLICATED)    -- walk-over pickup into an EMPTY slot
Define("sv_pickupAutoRange", 4, FCVAR.REPLICATED)   -- tighter: you must walk onto it
Define("sv_pickupOwnerDelay", 1, FCVAR.REPLICATED)  -- seconds before you can re-grab your own drop
Define("sv_pickupLifetime", 90, FCVAR.REPLICATED)   -- seconds before a drop despawns; 0 = never
Define("sv_pickupMax", 40, FCVAR.REPLICATED)        -- oldest is culled past this; 0 = unlimited

--=====================================================================
-- CROSSHAIR  (CS 1.6 cvar names)
--=====================================================================

Define("cl_crosshair", true, FCVAR.CLIENT)
Define("cl_crosshairthickness", 2, FCVAR.CLIENT)
Define("cl_crosshairlength", 7, FCVAR.CLIENT)
Define("cl_crosshairgap", 4, FCVAR.CLIENT)
Define("cl_crosshairalpha", 1, FCVAR.CLIENT)
Define("cl_crosshairdot", false, FCVAR.CLIENT)
Define("cl_crosshairoutline", true, FCVAR.CLIENT)
Define("cl_dynamiccrosshair", true, FCVAR.CLIENT)

Define("cl_crosshaircolor", Color3.fromRGB(0, 255, 0), FCVAR.CLIENT)
Define("cl_crosshairHitColor", Color3.fromRGB(255, 60, 60), FCVAR.CLIENT)
Define("cl_crosshairHitMarker", true, FCVAR.CLIENT)
Define("cl_crosshairHitTime", 0.25, FCVAR.CLIENT)

--=====================================================================
-- BULLET FX
--=====================================================================

Define("cl_tracers", true, FCVAR.CLIENT)
Define("cl_tracerColor", Color3.fromRGB(255, 230, 150), FCVAR.CLIENT)
Define("cl_tracerWidth", 0.05, FCVAR.CLIENT)
Define("cl_tracerLife", 0.06, FCVAR.CLIENT)

Define("cl_impactFX", true, FCVAR.CLIENT)
Define("cl_impactParticles", 8, FCVAR.CLIENT)
Define("cl_bulletHoles", true, FCVAR.CLIENT)
Define("cl_bulletHoleLife", 12, FCVAR.CLIENT)
Define("cl_bulletHoleTexture", "rbxassetid://5713307085", FCVAR.CLIENT)

--=====================================================================
-- SOUND
--=====================================================================

Define("cl_soundsEnabled", true, FCVAR.CLIENT)
Define("cl_soundVolume", 1, FCVAR.CLIENT)
Define("cl_weaponVolume", 1, FCVAR.CLIENT)
Define("cl_jumpVolume", 0.5, FCVAR.CLIENT)
Define("cl_landVolume", 0.6, FCVAR.CLIENT)

Define("cl_footstepVolume", 0.5, FCVAR.CLIENT)
Define("cl_footstepStride", 3.2, FCVAR.CLIENT)            -- studs between steps
Define("cl_footstepLoop", true, FCVAR.CLIENT)             -- one continuous loop vs discrete steps
Define("cl_silentCrouch", true, FCVAR.REPLICATED)         -- local changes would desync audio feedback

Define("snd_hitsound", true, FCVAR.CLIENT)
Define("snd_hitsound_volume", 1, FCVAR.CLIENT)
Define("snd_impact_volume", 1, FCVAR.CLIENT)

Define("snd_acousticSim", true, FCVAR.CLIENT)             -- per-emitter/listener acoustic sim
Define("snd_broadcast", true, FCVAR.CHEAT)                -- mute your own network audio
Define("cl_strideLength", 4.5, FCVAR.CLIENT)              -- studs travelled per networked footstep event

--=====================================================================
-- INPUT
--=====================================================================

Define("cl_scrollPulseTime", 0.01, FCVAR.CLIENT)          -- SECONDS a wheel notch holds an action
--Define("cl_defaultScrollCrouch", true, FCVAR.CLIENT)      -- bind duck to both wheel directions

--=====================================================================
-- SPAWNS
--=====================================================================

Define("sv_spawnHeight", 3.5, FCVAR.REPLICATED)       -- studs above the part's centre; clear the hull's feet
Define("sv_spawnClearRadius", 4, FCVAR.REPLICATED)    -- a spawn with a live body inside this is skipped
Define("sv_spawnAvoidRepeat", true, FCVAR.REPLICATED) -- don't hand out the same point twice running
Define("sv_spawnHideParts", true, FCVAR.REPLICATED)   -- make tagged parts invisible/non-solid on load
Define("sv_spawnDebug", false, FCVAR.CHEAT)           -- log every resolution
Define("sv_spawnStrict", true, FCVAR.REPLICATED)      -- false = allow any-team fallback (map testing only)

--=====================================================================
-- GAMEMODE  (mp_* , CS convention)
--=====================================================================

-- REPLICATED: clients branch on the active mode for HUD and scoring.
Define("mp_gamemode", "Custom", FCVAR.REPLICATED + FCVAR.CHEAT)   -- module name under Glacier1.Gamemode

Define("mp_freezetime", 6, FCVAR.REPLICATED)
Define("mp_roundtime", 115, FCVAR.REPLICATED)
Define("mp_maxrounds", 24, FCVAR.REPLICATED)
Define("mp_halftime", true, FCVAR.REPLICATED)      -- swap sides at maxrounds/2
Define("mp_autoteambalance", true, FCVAR.REPLICATED)
Define("mp_limitteams", 1, FCVAR.REPLICATED)       -- max size difference; 0 = no limit
Define("mp_autojoin", true, FCVAR.REPLICATED)      -- false = players must pick a side
Define("mp_respawn", false, FCVAR.REPLICATED)      -- true = deathmatch respawning
Define("mp_respawnDelay", 3, FCVAR.REPLICATED)     -- only used when mp_respawn is true
Define("mp_endRoundDelay", 5, FCVAR.REPLICATED)
Define("mp_minPlayers", 2, FCVAR.REPLICATED)                    -- 1 = solo testing
Define("mp_ignoreRoundWinConditions", false, FCVAR.REPLICATED)  -- rounds only end on the clock
Define("mp_deathUnloadDelay", 0, FCVAR.REPLICATED)              -- corpse lingers before cleanup

Define("mp_warmupTime", 15, FCVAR.REPLICATED)        -- grace period AFTER enough players join
Define("mp_warmupInfinite", false, FCVAR.REPLICATED) -- true = never leave warmup (map testing)
Define("mp_warmupRespawnDelay", 1, FCVAR.REPLICATED)
-- Read every frame by the client to gate input during freezetime. Persistent
-- state, so a cvar is right here -- unlike spawn, which is a verb.
Define("mp_frozen", false, FCVAR.REPLICATED)

Define("mp_map", "", FCVAR.REPLICATED)
Define("mp_startmap", "Mirage", FCVAR.REPLICATED)   -- loaded once at boot

--=====================================================================
-- SPECTATOR  (CS:GO observer-mode flavoured)
--=====================================================================

-- Game rules. Server-hard-locked: a client flipping these locally would be
-- ghosting the enemy team.
Define("spec_everyone", true, FCVAR.REPLICATED)      -- false = same team only
Define("spec_allowFreecam", true, FCVAR.REPLICATED)  -- false = roaming cam disabled
Define("spec_deathCamTime", 1.5, FCVAR.REPLICATED)   -- SECONDS frozen before spectating starts

-- 0 = first person (in-eye), 1 = third person (chase), 2 = freecam (roaming)
Define("spec_mode", 1, FCVAR.CLIENT)
Define("spec_hud", true, FCVAR.CLIENT)
Define("spec_fov", 0, FCVAR.CLIENT)                  -- 0 = inherit cam_fov
Define("spec_mouseSensitivity", 0, FCVAR.CLIENT)     -- 0 = inherit cl_mouseSensitivity
Define("spec_lerp", 18, FCVAR.CLIENT)                -- camera follow rate; 0 = snap (raw puppet jitter)
Define("spec_cycleOnTargetLost", true, FCVAR.CLIENT) -- auto-advance when your target dies

-- First person
Define("spec_firstPersonHeight", 0.8, FCVAR.CLIENT)  -- fallback eye offset if the rig has no Head

-- Third person / chase
Define("spec_thirdPersonDist", 6, FCVAR.CLIENT)
Define("spec_thirdPersonHeight", 1.2, FCVAR.CLIENT)
Define("spec_thirdPersonSide", 1.0, FCVAR.CLIENT)      -- shoulder offset; 0 = centred
Define("spec_thirdPersonFreeLook", true, FCVAR.CLIENT) -- false = camera rides the target's aim
Define("spec_thirdPersonCollide", true, FCVAR.CLIENT)
Define("spec_collideRadius", 0.4, FCVAR.CLIENT)        -- pull-in margin off the hit surface

-- Freecam (roaming). Speeds are studs/sec, so ~11x these numbers in GoldSrc units.
Define("spec_freecamSpeed", 30, FCVAR.CLIENT)
Define("spec_freecamFastMult", 3, FCVAR.CLIENT)      -- LeftShift
Define("spec_freecamSlowMult", 0.25, FCVAR.CLIENT)   -- LeftAlt
Define("spec_freecamAccel", 14, FCVAR.CLIENT)        -- velocity smoothing rate; 0 = instant
Define("spec_freecamScrollStep", 1.15, FCVAR.CLIENT) -- speed multiplier per wheel notch
Define("spec_freecamMinSpeed", 1, FCVAR.CLIENT)
Define("spec_freecamMaxSpeed", 300, FCVAR.CLIENT)

--=====================================================================
-- DEBUG
--=====================================================================

Define("cl_debugHud", true, FCVAR.CLIENT)
Define("cl_debugGraph", true, FCVAR.CLIENT)
Define("cl_debugWeapon", true, FCVAR.CLIENT)
Define("cl_debugHull", false, FCVAR.CLIENT)
Define("cl_debugVectors", false, FCVAR.CLIENT)
Define("cl_debugGraphScale", 0, FCVAR.CLIENT)             -- 0 = auto ceiling

Define("cl_serverDebug", true, FCVAR.CLIENT)
Define("cl_serverDebugPlayers", false, FCVAR.CLIENT)      -- per-player rows; needs sv_cheats
Define("cl_serverDebugScale", 1, FCVAR.CLIENT)
Define("sv_debugSnapshotHz", 5, FCVAR.REPLICATED)         -- broadcast rate; 0 = off

--=====================================================================
-- ENGINE DEVELOPMENT
--=====================================================================
-- These four are verbs stored as state, which the ConVar/ConCommand split
-- below says they shouldn't be. Left as cvars because other modules poll
-- them; convert to Config.Command when you next touch the lifecycle code.
Define("loadhere", false, FCVAR.CHEAT)
Define("unload", false, FCVAR.CHEAT)
Define("loadhere_matchEye", true, FCVAR.CHEAT)
Define("unload_keepCamera", true, FCVAR.CHEAT)

--=====================================================================
-- CONSOLE
--=====================================================================

Define("con_maxlines", 512, FCVAR.CLIENT)      -- ring buffer; oldest lines are destroyed
Define("con_history", 64, FCVAR.CLIENT)        -- recalled with Up/Down
Define("con_suggestions", 12, FCVAR.CLIENT)    -- rows in the autocomplete dropdown
-- Mirrors client print/warn into the console, the way Source shows engine
-- spew. Does NOT capture server output -- that still needs ctx.reply.
Define("con_spew", true, FCVAR.CLIENT)
Define("con_timestamp", false, FCVAR.CLIENT)

-- DevConsole: a command line across the top of the screen and a separate,
-- draggable output panel. The panel lives in its own ScreenGui so it can stay
-- up with the prompt closed -- Input treats a ScreenGui named "Console" as
-- modal, so keeping output in that one would mean a pinned log held the cursor
-- free and gameplay input dead.
Define("con_pin", false, FCVAR.CLIENT)        -- keep the output panel up when the prompt is closed
-- Roblox's Backpack owns the backquote/tilde key and opens the inventory with
-- it; that CoreGui binding cannot be unbound, so the console switches the
-- Backpack off to take the key. Costs this game nothing -- weapons live in the
-- Inventory module, not in a Roblox backpack. Set false to keep the backpack
-- and bind the console elsewhere.
Define("con_freeToggleKey", true, FCVAR.CLIENT)
Define("con_syntax", true, FCVAR.CLIENT)      -- colour the command line as you type
Define("con_hint", true, FCVAR.CLIENT)        -- show the live value/usage beside the prompt
Define("con_opacity", 0.12, FCVAR.CLIENT)     -- panel background transparency
-- Panel geometry in pixels. X of -1 means "dock to the right edge"; dragging
-- writes real coordinates here, so the panel keeps its place for the session.
Define("con_panelX", -1, FCVAR.CLIENT)
Define("con_panelY", 88, FCVAR.CLIENT)
Define("con_panelW", 440, FCVAR.CLIENT)
Define("con_panelH", 540, FCVAR.CLIENT)
Define("sv_lifecycleDebug", false, FCVAR.CHEAT)   -- announce body/puppet create and destroy

--=====================================================================
-- SERVER DEFINITIONS
--=====================================================================

-- Ships FALSE. Every FCVAR.CHEAT lock in this file is a no-op while this is
-- true, including the camera heights above.
Define("sv_cheats", false, FCVAR.REPLICATED)
Define("host_timescale", 1, FCVAR.REPLICATED + FCVAR.CHEAT)
Define("host_timescaleMin", 0.05, FCVAR.REPLICATED + FCVAR.CHEAT) -- hard floor; 0 stalls the accumulator entirely
Define("host_timescaleHz", 20, FCVAR.REPLICATED + FCVAR.CHEAT)    -- network step rate during a ramp
Define("sv_lockLoadout", false, FCVAR.REPLICATED + FCVAR.CHEAT)


--=====================================================================
-- CONSOLE / SETTER
--=====================================================================

-- Routes every message to the player's console when there is one, and to the
-- server log when there isn't (boot-time Exec, autoexec, server-to-server).
-- print() would only ever reach the log, which is the recurring footgun.
local function reply(ctx, msg)
	if ctx and type(ctx.reply) == "function" then
		ctx.reply(msg)
	else
		warn("[Config] " .. msg)
	end
end

Config.Reply = reply

-- Returns (ok, reason). Deliberately does NOT warn: the caller decides where
-- the message goes. Exec sends it to the console; __newindex warns, since a
-- direct assignment has nobody to reply to.
-- forceOverride is used internally by the RemoteEvent listener to bypass locks.
function Config.Set(key, value, forceOverride)
	local oldValue = Config.Values[key]

	if oldValue == nil then
		return false, ("'%s' does not exist."):format(tostring(key))
	end

	-- PERMISSION CHECKS (Only restrict clients)
	if not isServer and not forceOverride then
		local flag = Config.Flags[key] or FCVAR.CLIENT

		if bit32.band(flag, FCVAR.REPLICATED) ~= 0 then
			return false, ("'%s' is controlled by the server."):format(key)
		end
		if bit32.band(flag, FCVAR.CHEAT) ~= 0 and not Config.Values.sv_cheats then
			return false, ("'%s' is locked. Enable sv_cheats 1."):format(key)
		end
	end

	local t = typeof(oldValue)

	-- Type Coercion Logic
	if type(value) == "string" then
		local cleaned = string.match(value, "^%s*(.-)%s*$") or value

		if t == "number" then
			value = tonumber(cleaned)
		elseif t == "boolean" then
			local lower = string.lower(cleaned)
			if lower == "true" or lower == "1" then
				value = true
			elseif lower == "false" or lower == "0" then
				value = false
			end
		elseif t == "Color3" then
			local r, g, b = string.match(cleaned, "(%d+)[%s,]+(%d+)[%s,]+(%d+)")
			if r then
				value = Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b))
			end
		end
	end

	if typeof(value) ~= t then
		return false, ("type mismatch for %s: expected %s, got %s")
			:format(key, t, typeof(value))
	end

	Config.Values[key] = value

	-- If the SERVER changes a replicated/cheat variable, broadcast it.
	if isServer and Config.OnServerVarChanged then
		Config.OnServerVarChanged(key, value)
	end

	-- Snapshot first, so a listener that disconnects itself doesn't reindex
	-- the list mid-iteration. pcall so one bad handler can't poison every
	-- other cvar write.
	local listeners = Config.Listeners[key]
	if listeners then
		for _, fn in ipairs(table.clone(listeners)) do
			local ok, err = pcall(fn, value, oldValue, key)
			if not ok then
				warn(("[Config] listener for '%s' errored: %s"):format(key, tostring(err)))
			end
		end
	end

	return true
end

function Config.Get(key)
	return Config.Values[key]
end

function Config.GetDefault(key)
	return Config.Defaults[key]
end

-- Subscribe to changes on a single cvar. Fires for console sets, server
-- replication, and direct assignment alike, since everything routes through Set.
-- Returns a disconnect function.
function Config.OnChange(key, fn)
	if Config.Values[key] == nil then
		warn(("[Config] OnChange on unknown cvar '%s'."):format(tostring(key)))
		return function() end
	end

	local list = Config.Listeners[key]
	if not list then
		list = {}
		Config.Listeners[key] = list
	end
	table.insert(list, fn)

	return function()
		for i, f in ipairs(list) do
			if f == fn then
				table.remove(list, i)
				return
			end
		end
	end
end

-- Sorted key list for console autocomplete or a settings menu.
-- prefix: "mv_", "cl_", "sv_", etc. Omit for everything.
function Config.List(prefix)
	local out = {}
	for k in pairs(Config.Values) do
		if not prefix or string.sub(k, 1, #prefix) == prefix then
			table.insert(out, k)
		end
	end
	table.sort(out)
	return out
end

-- Commands live in a separate table, so List() stays settings-only. The
-- console needs both for autocomplete.
function Config.ListCommands(prefix)
	local out = {}
	for k in pairs(Config.Commands) do
		if not prefix or string.sub(k, 1, #prefix) == prefix then
			table.insert(out, k)
		end
	end
	table.sort(out)
	return out
end

--=====================================================================
-- CONSOLE COMMANDS  (ConCommand, as distinct from ConVar)
--=====================================================================
-- A cvar is state. A command is a verb with arguments. Registering commands
-- separately keeps Config.List() returning only settings, and means two
-- callers firing the same command can't stomp each other's arguments.

local Players = game:GetService("Players")

-- Each parser eats one or more tokens and returns (value, tokensConsumed).
-- On failure: (nil, 0, reason).
local ArgParsers = {}

ArgParsers.number = function(tokens, i)
	local n = tonumber(tokens[i])
	if not n then return nil, 0, ("expected a number, got '%s'"):format(tostring(tokens[i])) end
	return n, 1
end

ArgParsers.string = function(tokens, i)
	if tokens[i] == nil then return nil, 0, "expected a string" end
	return tokens[i], 1
end

ArgParsers.bool = function(tokens, i)
	local t = string.lower(tokens[i] or "")
	if t == "1" or t == "true"  then return true,  1 end
	if t == "0" or t == "false" then return false, 1 end
	return nil, 0, ("expected 0/1, got '%s'"):format(tostring(tokens[i]))
end

-- Three tokens, Source-style: `move huzz 100 20 -300`
ArgParsers.vector3 = function(tokens, i)
	local x, y, z = tonumber(tokens[i]), tonumber(tokens[i + 1]), tonumber(tokens[i + 2])
	if not (x and y and z) then return nil, 0, "expected three numbers (x y z)" end
	return Vector3.new(x, y, z), 3
end

-- Consumes every remaining token as one string. Must be declared last.
-- This is how a bound command reaches `bind` intact: Exec tokenizes on
-- whitespace with no concept of quoting, so the command rejoins them itself.
ArgParsers.rest = function(tokens, i)
	if tokens[i] == nil then return nil, 0, "expected a command" end
	return table.concat(tokens, " ", i), #tokens - i + 1
end

-- Exported so a command that takes a player ALONGSIDE other spellings -- an
-- "all" keyword, a team name -- can reuse the same partial matching and
-- ambiguity rules instead of hand-rolling a weaker copy.
-- Returns player | nil, reason.
function Config.ResolvePlayer(query)
	if type(query) ~= "string" or query == "" then
		return nil, "expected a player name"
	end

	local lower = string.lower(query)
	local matches = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if string.lower(plr.Name) == lower then
			return plr   -- exact match always wins outright
		end
		if string.find(string.lower(plr.Name), lower, 1, true) then
			table.insert(matches, plr)
		end
	end

	if #matches == 0 then return nil, ("no player matching '%s'"):format(query) end
	if #matches > 1 then
		local names = {}
		for _, p in ipairs(matches) do table.insert(names, p.Name) end
		return nil, ("'%s' is ambiguous: %s"):format(query, table.concat(names, ", "))
	end
	return matches[1]
end

-- Partial, case-insensitive, and AMBIGUITY IS AN ERROR. Silently picking the
-- first of two matches is how you respawn the wrong player mid-round.
ArgParsers.player = function(tokens, i)
	if tokens[i] == nil then return nil, 0, "expected a player name" end
	local plr, reason = Config.ResolvePlayer(tokens[i])
	if not plr then return nil, 0, reason end
	return plr, 1
end

-- A trailing "?" marks an arg optional: "string?" parses a string if a token
-- is there and stops the arg loop cleanly if it isn't.
local function splitArg(decl)
	if string.sub(decl, -1) == "?" then
		return string.sub(decl, 1, -2), true
	end
	return decl, false
end

function Config.OnCommandsChanged(fn)
	table.insert(Config.CommandListeners, fn)
	return function()
		for i, f in ipairs(Config.CommandListeners) do
			if f == fn then table.remove(Config.CommandListeners, i) return end
		end
	end
end

local function notifyCommandsChanged()
	for _, fn in ipairs(table.clone(Config.CommandListeners)) do
		pcall(fn)
	end
end

-- spec: { args = {"player", "vector3", "string?"}, flag = FCVAR.CHEAT,
--         help = "...", run = fn }
-- run receives (ctx, ...parsed args). Returning nothing counts as success;
-- return false, "reason" to fail.
function Config.Command(name, spec)
	if type(spec) ~= "table" then
		warn(("[Config] Command('%s', ...) takes a spec TABLE, not a function. "
			.. "Use { flag = ..., args = {...}, run = fn }."):format(tostring(name)))
		return
	end
	if type(spec.run) ~= "function" then
		warn(("[Config] command '%s' has no run function."):format(name))
		return
	end
	if Config.Values[name] ~= nil then
		warn(("[Config] '%s' is already a cvar; pick another command name."):format(name))
		return
	end
	if Config.Commands[name] ~= nil then
		warn(("[Config] command '%s' is being redefined."):format(name))
	end

	spec.args = spec.args or {}
	spec.flag = spec.flag or FCVAR.CLIENT

	local sawOptional = false
	for idx, decl in ipairs(spec.args) do
		local argType, optional = splitArg(decl)
		if not ArgParsers[argType] then
			warn(("[Config] command '%s' declares unknown arg type '%s'."):format(name, argType))
			return
		end
		-- 'rest' swallows the remainder, so anything after it is unreachable.
		if argType == "rest" and idx ~= #spec.args then
			warn(("[Config] command '%s': 'rest' must be the last arg."):format(name))
			return
		end
		if sawOptional and not optional then
			warn(("[Config] command '%s': required arg '%s' follows an optional one.")
				:format(name, decl))
			return
		end
		sawOptional = sawOptional or optional
	end

	Config.Commands[name] = spec
	notifyCommandsChanged()
end

function Config.RemoveCommand(name)
	if Config.Commands[name] == nil then return end
	Config.Commands[name] = nil
	notifyCommandsChanged()
end

function Config.SetRemoteCommands(list)
	Config.RemoteCommands = list or {}
	notifyCommandsChanged()
end

function Config.Usage(name)
	local cmd = Config.Commands[name]
	if not cmd then return nil end
	local parts = { name }
	for _, decl in ipairs(cmd.args) do
		local argType, optional = splitArg(decl)
		local body = (argType == "vector3") and "x y z"
			or (argType == "rest") and "command..."
			or argType
		table.insert(parts, optional and ("[" .. body .. "]") or ("<" .. body .. ">"))
	end
	return table.concat(parts, " ") .. (cmd.help and ("  -- " .. cmd.help) or "")
end

-- ctx = { player = <who typed it>, admin = <bool>, reply = fn, source = "console"|"server" }
local function runCommand(name, tokens, ctx)
	local cmd = Config.Commands[name]
	if not cmd then return false, ("unknown command '%s'"):format(name) end

	if bit32.band(cmd.flag, FCVAR.CHEAT) ~= 0 and not Config.Values.sv_cheats then
		return false, ("'%s' is locked. Enable sv_cheats 1."):format(name)
	end
	if bit32.band(cmd.flag, FCVAR.REPLICATED) ~= 0 and not isServer and not ctx.admin then
		return false, ("'%s' is server-only."):format(name)
	end

	local parsed, i = {}, 2   -- tokens[1] is the command name
	for _, decl in ipairs(cmd.args) do
		local argType, optional = splitArg(decl)
		if optional and tokens[i] == nil then break end

		local value, consumed, reason = ArgParsers[argType](tokens, i)
		if consumed == 0 then
			return false, ("%s: %s\n  usage: %s"):format(name, reason, Config.Usage(name))
		end
		table.insert(parsed, value)
		i += consumed
	end

	-- A command that returns nothing has succeeded. Passing nil straight
	-- through made every well-behaved command read as a failure with no
	-- reason attached, so the console printed nothing at all.
	local ok, reason = cmd.run(ctx, table.unpack(parsed))
	if ok == nil then return true end
	return ok, reason
end

-- Single entry point for a typed line. Dispatches to a command if one matches,
-- otherwise falls through to a cvar set, so `mv_gravity 50` still works.
function Config.Exec(line, ctx)
	ctx = ctx or {}
	if type(line) ~= "string" then return false, "not a string" end

	local tokens = {}
	for token in string.gmatch(line, "%S+") do table.insert(tokens, token) end
	if #tokens == 0 then return false end

	local name = tokens[1]

	if Config.Commands[name] then
		local ok, reason = runCommand(name, tokens, ctx)
		if not ok and reason then reply(ctx, reason) end
		return ok, reason
	end

	if Config.Values[name] ~= nil then
		if tokens[2] == nil then
			local def = Config.Defaults[name]
			reply(ctx, ("%s = %s  (default %s)")
				:format(name, tostring(Config.Values[name]), tostring(def)))
			return true
		end
		-- Rejoin the tail so `cl_crosshaircolor 0 255 0` still parses.
		local ok, reason = Config.Set(name, table.concat(tokens, " ", 2), ctx.forceOverride)
		if not ok and reason then reply(ctx, reason) end
		return ok, reason
	end

	reply(ctx, ("unknown command or cvar: '%s'"):format(name))
	return false
end

--=====================================================================
-- BUILT-IN COMMANDS
--=====================================================================

Config.Command("help", {
	args = { "string?" },
	help = "list commands, or show usage for one",
	run = function(ctx, name)
		if name then
			local usage = Config.Usage(name)
			if usage then reply(ctx, usage) return end
			if Config.Values[name] ~= nil then
				return Config.Exec(name, ctx)
			end
			return false, ("no command or cvar named '%s'"):format(name)
		end

		local names = Config.ListCommands()
		reply(ctx, ("%d commands: %s"):format(#names, table.concat(names, ", ")))
	end,
})

Config.Command("reset", {
	args = { "string" },
	help = "restore a cvar to its declared default",
	run = function(ctx, key)
		local def = Config.Defaults[key]
		if def == nil then return false, ("'%s' does not exist."):format(key) end

		local ok, reason = Config.Set(key, def, ctx.forceOverride)
		if not ok then return false, reason end
		reply(ctx, ("%s = %s"):format(key, tostring(def)))
	end,
})

Config.Command("toggle", {
	args = { "string" },
	help = "flip a boolean cvar",
	run = function(ctx, key)
		local cur = Config.Values[key]
		if cur == nil then return false, ("'%s' does not exist."):format(key) end
		if typeof(cur) ~= "boolean" then
			return false, ("'%s' is a %s, not a boolean."):format(key, typeof(cur))
		end

		local ok, reason = Config.Set(key, not cur, ctx.forceOverride)
		if not ok then return false, reason end
		reply(ctx, ("%s = %s"):format(key, tostring(not cur)))
	end,
})

Config.Command("find", {
	args = { "string" },
	help = "search cvar and command names",
	run = function(ctx, needle)
		local lower = string.lower(needle)
		local hits = {}
		for _, k in ipairs(Config.List()) do
			if string.find(string.lower(k), lower, 1, true) then table.insert(hits, k) end
		end
		for _, k in ipairs(Config.ListCommands()) do
			if string.find(string.lower(k), lower, 1, true) then table.insert(hits, k .. "()") end
		end

		if #hits == 0 then reply(ctx, ("nothing matching '%s'"):format(needle)) return end
		table.sort(hits)
		reply(ctx, table.concat(hits, "\n"))
	end,
})

--=====================================================================
-- CVAR ALIASES  (Source / GoldSrc names over Glacier's own)
--=====================================================================
-- Glacier's movement cvars are mv_* and measured in STUDS. Everything a CS
-- player already has muscle memory for is sv_* and measured in GoldSrc UNITS.
-- Renaming the engine's own tunables is off the table -- every module reads
-- mv_gravity by name -- so an alias is registered instead, as a COMMAND that
-- reads and writes the real cvar with the unit conversion applied:
--
--   sv_gravity          -> "sv_gravity" = "800"  ( mv_gravity 72.7 )
--   sv_gravity 400      -> mv_gravity = 36.3636
--
-- A command rather than a second cvar, for two reasons: Config.List() stays
-- the list of things that actually exist, so a settings menu can't show the
-- same number twice under two names; and the console picks commands up for
-- autocomplete for free through OnCommandsChanged.
--
-- VM OWNERSHIP: an alias onto a REPLICATED cvar registers on the SERVER ONLY.
-- runCommand rejects a REPLICATED command in the client VM rather than
-- forwarding it, so a client-side registration would answer "server-only",
-- while NO local entry at all makes the console forward the whole line to the
-- server -- which is exactly how loadmap already reaches it.

Config.Aliases = {}   -- [alias] = { target = key, scale = n }

-- 1 stud ~ 11 GoldSrc units, the same conversion the comments above use.
local UNITS_PER_STUD = 11
Config.UNITS_PER_STUD = UNITS_PER_STUD

-- 800 units of gravity divided by 11 and multiplied back is 799.9999...;
-- printing that as the value of sv_gravity would look like a rounding bug.
local function tidy(n)
	if typeof(n) ~= "number" then return n end
	return math.floor(n * 10000 + 0.5) / 10000
end

local function aliasReport(name, target, scale, isNumber)
	local raw = Config.Values[target]
	local shown = isNumber and tidy(raw / scale) or raw
	return ('"%s" = "%s"  ( %s %s )'):format(name, tostring(shown), target, tostring(raw))
end

-- opts = { scale = number, flag = number, help = string }
--   aliasValue * scale = engineValue
-- so a cvar held in studs and typed in GoldSrc units takes scale 1/11.
function Config.Alias(name, target, opts)
	opts = opts or {}

	if Config.Values[target] == nil then
		warn(("[Config] alias '%s' points at unknown cvar '%s'."):format(name, tostring(target)))
		return
	end
	if Config.Values[name] ~= nil then
		warn(("[Config] '%s' is already a cvar; it cannot also be an alias."):format(name))
		return
	end

	local flag = opts.flag or Config.Flags[target] or FCVAR.CLIENT

	-- See VM OWNERSHIP above. Returning quietly is the point: the client is
	-- meant to end up with no entry for this name.
	if not isServer and bit32.band(flag, FCVAR.REPLICATED) ~= 0 then
		return
	end

	local scale = opts.scale or 1
	local isNumber = typeof(Config.Values[target]) == "number"
	Config.Aliases[name] = { target = target, scale = scale }

	Config.Command(name, {
		args = { "string?" },
		flag = flag,
		help = opts.help or (scale == 1
			and ("alias of " .. target)
			or ("alias of %s, in GoldSrc units"):format(target)),
		run = function(ctx, value)
			if value == nil then
				reply(ctx, aliasReport(name, target, scale, isNumber))
				return true
			end

			local converted = value
			if isNumber then
				local n = tonumber(value)
				if not n then
					return false, ("%s: expected a number, got '%s'"):format(name, tostring(value))
				end
				converted = n * scale
			end

			local ok, reason = Config.Set(target, converted, ctx.forceOverride)
			if not ok then return false, reason end

			reply(ctx, aliasReport(name, target, scale, isNumber))
			return true
		end,
	})
end

local GOLDSRC = 1 / UNITS_PER_STUD

--------------------------------------------------------------
-- movement  (server-owned: every target below is REPLICATED)
--------------------------------------------------------------

Config.Alias("sv_gravity",            "mv_gravity",             { scale = GOLDSRC })
Config.Alias("sv_maxspeed",           "mv_walkSpeed",           { scale = GOLDSRC })
Config.Alias("sv_stopspeed",          "mv_stopSpeed",           { scale = GOLDSRC })
Config.Alias("sv_maxvelocity",        "mv_maxVelocity",         { scale = GOLDSRC })
Config.Alias("sv_stepsize",           "mv_maxStepHeight",       { scale = GOLDSRC })
Config.Alias("sv_jump_impulse",       "mv_jumpForce",           { scale = GOLDSRC })
Config.Alias("sv_air_max_wishspeed",  "mv_airSpeedCap",         { scale = GOLDSRC })
Config.Alias("sv_accelerate",         "mv_groundAcceleration")
Config.Alias("sv_airaccelerate",      "mv_airAcceleration")
Config.Alias("sv_friction",           "mv_groundFriction")
Config.Alias("sv_edgefriction",       "mv_edgeFriction")
Config.Alias("sv_noclipspeed",        "mv_noclipSpeed",         { scale = GOLDSRC })

-- Both spellings exist in the wild -- GoldSrc/CSS shipped the first, CS:GO the
-- second -- and players type whichever they learned.
Config.Alias("sv_enablebunnyhopping", "mv_autoBhop")
Config.Alias("sv_autobunnyhopping",   "mv_autoBhop")

--------------------------------------------------------------
-- match rules  (server-owned)
--------------------------------------------------------------

Config.Alias("mp_warmuptime",          "mp_warmupTime")
Config.Alias("mp_warmup_pausetimer",   "mp_warmupInfinite")
Config.Alias("mp_round_restart_delay", "mp_endRoundDelay")
Config.Alias("mp_respawnwavetime",     "mp_respawnDelay")
Config.Alias("spec_freeze_time",       "spec_deathCamTime")

--------------------------------------------------------------
-- client  (registered in BOTH VMs; these targets are FCVAR.CLIENT)
--------------------------------------------------------------

Config.Alias("fov",                    "cam_fov")
Config.Alias("cl_crosshairsize",       "cl_crosshairlength")
Config.Alias("cl_crosshair_drawoutline", "cl_crosshairoutline")
Config.Alias("cl_bobamt_vert",         "cl_bobAmtVert")
Config.Alias("cl_bobamt_lat",          "cl_bobAmtLat")
Config.Alias("viewmodel_offset_x",     "vm_offsetX")
Config.Alias("viewmodel_offset_y",     "vm_offsetY")
Config.Alias("viewmodel_offset_z",     "vm_offsetZ")
Config.Alias("volume",                 "cl_soundVolume")

-- CS ships sensitivity around 2.5 where this engine wants 0.25, so the alias
-- carries the factor rather than asking anyone to move a decimal point.
Config.Alias("sensitivity",            "cl_mouseSensitivity", { scale = 0.1 })

--=====================================================================
-- USER ALIASES  (Source `alias`)
--=====================================================================
-- alias bhop "+jump; -jump"
-- alias arms "primary ak47; secondary usp; melee knife"
--
-- The body is stored verbatim and re-tokenised on every run, so an alias that
-- names a command registered later still works once it exists.

Config.UserAliases = {}

local ALIAS_MAX_DEPTH = 8
local aliasDepth = 0

-- ctx.exec is the console's own dispatcher when there is one. Going through it
-- matters on the client: Config.Exec resolves in THIS VM only, so an alias
-- containing a server command would die as "unknown command" instead of being
-- forwarded up the same path a typed line takes.
local function execLine(line, ctx)
	if ctx and type(ctx.exec) == "function" then
		return ctx.exec(line)
	end
	return Config.Exec(line, ctx)
end

local function runAliasBody(body, ctx)
	if aliasDepth >= ALIAS_MAX_DEPTH then
		return false, ("alias recursion deeper than %d; stopped"):format(ALIAS_MAX_DEPTH)
	end

	aliasDepth += 1
	-- Semicolons split here rather than in the console, because an alias body
	-- arrives as ONE token stream and never passes the console's own splitter.
	local ok, err = pcall(function()
		for part in string.gmatch(body, "[^;]+") do
			if not part:match("^%s*$") then
				execLine((part:gsub("^%s+", ""):gsub("%s+$", "")), ctx)
			end
		end
	end)
	aliasDepth -= 1

	if not ok then return false, tostring(err) end
	return true
end

function Config.DefineAlias(name, body)
	if type(name) ~= "string" or name == "" then return false, "expected an alias name" end
	if Config.Values[name] ~= nil then
		return false, ("'%s' is a cvar."):format(name)
	end
	-- Overwriting a real command with a macro is how you lose `kill` to a typo.
	if Config.Commands[name] and not Config.UserAliases[name] then
		return false, ("'%s' is already a command."):format(name)
	end

	Config.UserAliases[name] = body
	Config.Command(name, {
		args = {},
		flag = FCVAR.CLIENT,
		help = ("alias: %s"):format(body),
		run = function(ctx)
			return runAliasBody(Config.UserAliases[name] or "", ctx)
		end,
	})
	return true
end

function Config.RemoveAlias(name)
	if not Config.UserAliases[name] then return false end
	Config.UserAliases[name] = nil
	Config.RemoveCommand(name)
	return true
end

Config.Command("alias", {
	args = { "string?", "rest?" },
	help = "define a command that runs other commands, separated by ';'",
	run = function(ctx, name, body)
		if name == nil then
			local names = {}
			for key in pairs(Config.UserAliases) do table.insert(names, key) end
			if #names == 0 then reply(ctx, "no aliases defined") return true end
			table.sort(names)

			local lines = {}
			for _, key in ipairs(names) do
				table.insert(lines, ('%s = "%s"'):format(key, Config.UserAliases[key]))
			end
			reply(ctx, table.concat(lines, "\n"))
			return true
		end

		if body == nil then
			local existing = Config.UserAliases[name]
			if not existing then return false, ("no alias named '%s'"):format(name) end
			reply(ctx, ('%s = "%s"'):format(name, existing))
			return true
		end

		-- Quoting the body the way Source does is habit for anyone coming from
		-- CS, and the tokeniser has no concept of quotes, so strip them here.
		body = body:gsub('^"(.*)"$', "%1")

		local ok, reason = Config.DefineAlias(name, body)
		if not ok then return false, reason end
		reply(ctx, ('alias %s = "%s"'):format(name, body))
		return true
	end,
})

Config.Command("unalias", {
	args = { "string" },
	help = "remove an alias",
	run = function(ctx, name)
		if not Config.RemoveAlias(name) then
			return false, ("no alias named '%s'"):format(name)
		end
		reply(ctx, ("removed alias %s"):format(name))
		return true
	end,
})

--=====================================================================
-- MORE BUILT-INS  (Source names)
--=====================================================================

Config.Command("cvarlist", {
	args = { "string?" },
	help = "list cvars with their values; give a prefix to narrow it",
	run = function(ctx, prefix)
		local keys = Config.List(prefix)
		if #keys == 0 then
			reply(ctx, ("no cvars matching '%s'"):format(tostring(prefix)))
			return true
		end

		-- A full dump is 300-odd lines into a ring buffer that holds 512, which
		-- costs you every line of scrollback you had. Truncate and say so.
		local LIMIT = 60
		local lines = {}
		for i = 1, math.min(#keys, LIMIT) do
			local key = keys[i]
			local tags = {}
			if Config.HasFlag(key, FCVAR.REPLICATED) then table.insert(tags, "rep") end
			if Config.HasFlag(key, FCVAR.CHEAT) then table.insert(tags, "cheat") end
			table.insert(lines, ("%-32s %s%s"):format(
				key, tostring(Config.Values[key]),
				#tags > 0 and ("  [" .. table.concat(tags, ",") .. "]") or ""))
		end
		if #keys > LIMIT then
			table.insert(lines, ("... %d more; narrow it with a prefix"):format(#keys - LIMIT))
		end

		reply(ctx, table.concat(lines, "\n"))
		return true
	end,
})

Config.Command("differences", {
	args = {},
	help = "list every cvar that no longer matches its default",
	run = function(ctx)
		local lines = {}
		for _, key in ipairs(Config.List()) do
			local now, def = Config.Values[key], Config.Defaults[key]
			if now ~= def then
				table.insert(lines, ("%-32s %s  (default %s)")
					:format(key, tostring(now), tostring(def)))
			end
		end

		if #lines == 0 then reply(ctx, "everything is at its default") return true end
		reply(ctx, table.concat(lines, "\n"))
		return true
	end,
})

Config.Command("incrementvar", {
	args = { "string", "number", "number", "number" },
	help = "step a numeric cvar, wrapping at the bounds (Source's bind helper)",
	run = function(ctx, key, minValue, maxValue, delta)
		local current = Config.Values[key]
		if current == nil then return false, ("'%s' does not exist."):format(key) end
		if typeof(current) ~= "number" then
			return false, ("'%s' is a %s, not a number."):format(key, typeof(current))
		end

		local next_ = current + delta
		-- Source wraps rather than clamps, which is what makes a single key
		-- cycle a setting instead of parking it at one end.
		if next_ > maxValue then next_ = minValue
		elseif next_ < minValue then next_ = maxValue end

		local ok, reason = Config.Set(key, next_, ctx.forceOverride)
		if not ok then return false, reason end
		reply(ctx, ("%s = %s"):format(key, tostring(next_)))
		return true
	end,
})

--=====================================================================
-- METATABLE (Backward Compatibility)
--=====================================================================
setmetatable(Config, {
	-- Triggers when a script tries to READ a value that isn't directly in the Config table
	__index = function(self, key)
		if self.Values[key] ~= nil then
			return self.Values[key]
		end
		return nil
	end,

	-- Triggers when a script tries to WRITE to a value (e.g., Config.mv_gravity = 50)
	__newindex = function(self, key, value)
		if self.Values[key] ~= nil then
			-- Direct assignment has no console attached, so this is the one
			-- path that warns on its own behalf.
			local ok, reason = self.Set(key, value)
			if not ok and reason then warn("[Config] " .. reason) end
		else
			rawset(self, key, value)
		end
	end
})

return Config