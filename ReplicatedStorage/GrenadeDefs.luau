-- ModuleScript: ReplicatedStorage.GrenadeDefs
--
-- WHAT A GRENADE IS, as numbers and pure functions.
--
-- Everything here is arithmetic on vectors: how hard it leaves your hand, how
-- it bounces, when it goes off, and who it hurts. None of it touches the
-- world, creates an instance or knows whether it is running on the server --
-- which is the point, because the server has to be the authority on all four
-- and the client has to predict the first two to draw an arc you can aim
-- with. Two implementations of a throw is two throws.
--
-- THE FOUR THROWS are CS's, and they are a big part of why grenades are a
-- skill: the same pin, four different lineups.
--
--   throw   full power, flat                 -- the one you use
--   lob     full power, up                   -- over a wall
--   drop    almost nothing                   -- at your feet
--   toss    half power, up                   -- the short lob
--
-- BLAST IS BY DISTANCE, NOT BY LINE OF SIGHT. The caller does the tracing --
-- it owns the world -- and hands over a distance and whether anything was in
-- the way. This decides what that is worth.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Config"))

local GrenadeDefs = {}

local function num(v, fallback)
	local n = tonumber(v)
	return n or fallback
end

--=====================================================================
-- THE GRENADES
--=====================================================================

GrenadeDefs.DEFAULTS = {
	-- How hard it leaves the hand, in studs/second, at full power.
	speed        = 68,
	-- How much of the throw goes upward, as a fraction of speed. CS's flat
	-- throw is not flat: it has a slight lift, which is why a flat throw
	-- still arcs over a box.
	lift         = 0.22,

	-- Seconds from the pin to the bang. CS's is 1.6 for an HE and the fuse
	-- starts when you THROW, which is what makes a cooked grenade a thing
	-- you cannot do here and a lineup something you can.
	fuse         = 1.6,

	-- What it does when it hits something. Restitution is how much speed
	-- survives the bounce along the normal, friction how much survives along
	-- the surface. A grenade that kept its speed would be a superball; one
	-- that kept none would be a beanbag.
	restitution  = 0.45,
	friction     = 0.78,

	-- Below this it has stopped bouncing and is rolling, and below the second
	-- it has stopped altogether. Without the first a grenade jitters on the
	-- floor for its whole fuse.
	restSpeed    = 4,
	rollFriction = 2.2,

	-- The blast.
	damage       = 98,     -- at the centre
	radius       = 28,     -- and nothing at all past here
	falloff      = 1.4,    -- >1 concentrates it near the middle

	-- How much of the blast a wall between you and it takes. Not all of it:
	-- a grenade round a corner still stings.
	cover        = 0.45,

	-- Self-damage, as a fraction. Your own grenade hurts you nearly as much
	-- as it hurts anybody else, which is the whole reason you learn the
	-- lineups rather than throwing them at your feet.
	selfDamage   = 0.85,
	teamDamage   = 0,      -- scaled by mp_friendlyfire at the call site
}

GrenadeDefs.KINDS = {
	hegrenade = {
		label = "HE Grenade",
	},

	flashbang = {
		label = "Flashbang",
		fuse = 1.5,
		damage = 0,
		-- A flash does not hurt; it blinds, and by ANGLE as much as by
		-- distance. Looking straight at it at ten studs is three seconds of
		-- nothing; having your back to it at the same range is a flicker.
		radius = 45,
		flashMax = 3.2,     -- seconds, staring straight at it point blank
		flashMin = 0.35,    -- the least a flash in view is worth
		-- How far off your view it can be and still count at all. Past this
		-- it is behind you.
		flashAngle = 100,   -- degrees, half-angle
	},

	smokegrenade = {
		label = "Smoke Grenade",
		fuse = 1.4,
		damage = 0,
		radius = 0,
		-- How big the cloud is and how long it lasts. The bloom is how long
		-- it takes to reach full size -- a smoke is not cover the instant it
		-- lands, and the gap is playable.
		smokeRadius = 22,
		smokeTime = 16,
		smokeBloom = 1.4,
	},
}

-- A full def for one kind. Every DEFAULTS key present, so a caller never has
-- to write `def.fuse or 1.6` and two callers never disagree about it.
function GrenadeDefs.Get(kind)
	local raw = GrenadeDefs.KINDS[string.lower(tostring(kind or ""))]
	if not raw then return nil end

	local def = {}
	for k, v in pairs(GrenadeDefs.DEFAULTS) do def[k] = v end
	for k, v in pairs(raw) do def[k] = v end
	def.kind = string.lower(tostring(kind))
	return def
end

function GrenadeDefs.List()
	local out = {}
	for kind in pairs(GrenadeDefs.KINDS) do table.insert(out, kind) end
	table.sort(out)
	return out
end

--=====================================================================
-- THE THROW
--=====================================================================

-- How much of full power each throw is worth, and how much extra lift.
GrenadeDefs.THROWS = {
	throw = { power = 1.0,  lift = 0 },
	lob   = { power = 1.0,  lift = 0.55 },
	toss  = { power = 0.5,  lift = 0.35 },
	drop  = { power = 0.12, lift = 0 },
}

-- The velocity a grenade leaves with. `carried` is the thrower's own
-- velocity, which is added: a grenade thrown while running goes further, and
-- a player who has learned that is a player who has learned something real.
function GrenadeDefs.ThrowVelocity(def, look, style, carried)
	local throw = GrenadeDefs.THROWS[string.lower(tostring(style or "throw"))]
		or GrenadeDefs.THROWS.throw

	if not look or look.Magnitude < 1e-6 then look = Vector3.new(0, 0, -1) end
	look = look.Unit

	local speed = num(def.speed, 68) * throw.power
	local lift = num(def.lift, 0.22) + throw.lift

	-- THE LIFT REDIRECTS THE THROW, it does not add to it. Adding it would
	-- make a lob strictly faster than a flat throw as well as higher, which
	-- is not a trade and not a lineup -- you would lob everything. Aiming
	-- higher costs you the distance, exactly as your arm does.
	local direction = look + Vector3.yAxis * lift
	if direction.Magnitude < 1e-6 then direction = Vector3.yAxis end

	local velocity = direction.Unit * speed

	-- INHERITED, and only the part going the same way you threw. A player
	-- strafing sideways should not have the grenade leave at an angle to
	-- where they aimed -- that is not a skill, it is a surprise.
	if carried then
		local along = carried:Dot(look)
		if along > 0 then velocity += look * (along * num(Config.sv_nade_inherit, 0.6)) end
	end

	return velocity
end

--=====================================================================
-- THE BOUNCE
--=====================================================================

-- One bounce, as a pure function of the velocity coming in and the surface
-- it met. Returns the velocity going out and whether it has come to rest.
--
-- The two halves are separate on purpose: RESTITUTION is how much of the
-- speed INTO the surface comes back, and FRICTION is how much of the speed
-- ALONG it survives. A grenade that used one number for both either skids
-- like it is on ice or stops dead on a ramp.
function GrenadeDefs.Bounce(def, velocity, normal)
	if not normal or normal.Magnitude < 1e-6 then return velocity, false end
	normal = normal.Unit

	local into = velocity:Dot(normal)
	-- Leaving the surface already: nothing to bounce off.
	if into >= 0 then return velocity, false end

	local normalPart = normal * into
	local tangent = velocity - normalPart

	local out = tangent * num(def.friction, 0.78)
		- normalPart * num(def.restitution, 0.45)

	-- HAS IT STOPPED? Measured on the part going INTO the surface rather than
	-- on the whole speed: a grenade rolling fast along a floor is not at
	-- rest, and one dropping slowly onto it is.
	local rest = math.abs(out:Dot(normal)) < num(def.restSpeed, 4)
		and tangent.Magnitude < num(def.restSpeed, 4)

	if rest then return Vector3.zero, true end
	return out, false
end

--=====================================================================
-- THE BLAST
--=====================================================================

-- What the blast is worth at this distance, 0 to 1. `blocked` is whether
-- something solid is in the way -- the caller traces, because it owns the
-- world -- and costs a share rather than everything: a grenade round a corner
-- still stings.
function GrenadeDefs.BlastFraction(def, distance, blocked)
	local radius = num(def.radius, 28)
	if radius <= 0 then return 0 end

	local d = math.clamp(num(distance, 0), 0, radius)
	local fraction = (1 - d / radius) ^ num(def.falloff, 1.4)

	if blocked then fraction *= (1 - num(def.cover, 0.45)) end
	return math.clamp(fraction, 0, 1)
end

-- And in hit points, for one victim. `relation` is "self", "team" or "enemy",
-- which is the only thing this needs to know about who they are.
function GrenadeDefs.BlastDamage(def, distance, blocked, relation, friendlyFire)
	local fraction = GrenadeDefs.BlastFraction(def, distance, blocked)
	if fraction <= 0 then return 0 end

	local damage = num(def.damage, 98) * fraction

	if relation == "self" then
		damage *= num(def.selfDamage, 0.85)
	elseif relation == "team" then
		-- Friendly fire is the server's switch, and a team-damage scale on
		-- the def lets one grenade be gentler than another under it.
		if not friendlyFire then return 0 end
		damage *= math.max(num(def.teamDamage, 0), 0)
		if damage <= 0 then damage = num(def.damage, 98) * fraction end
	end

	return math.max(damage, 0)
end

--=====================================================================
-- THE FLASH
--=====================================================================

-- How long a flashbang blinds somebody for, in seconds. 0 is not blinded.
--
-- BY ANGLE AS MUCH AS BY DISTANCE, which is the whole of what makes flashes
-- a skill on both ends: you turn away from one, and you throw one where
-- somebody is looking. Staring at it point blank is the full duration;
-- having your back to it is nothing at all, at any range.
--
-- `look` is the victim's view direction and `toFlash` the direction from
-- them to the bang. Both are directions, and neither has to be normalised.
function GrenadeDefs.FlashDuration(def, distance, look, toFlash, blocked)
	local radius = num(def.radius, 45)
	if radius <= 0 then return 0 end

	local d = math.clamp(num(distance, 0), 0, radius)
	local byDistance = 1 - d / radius
	if byDistance <= 0 then return 0 end

	-- NOTHING THROUGH A WALL. Unlike a blast, a flash is light: a wall does
	-- not take a share of it, it takes all of it.
	if blocked then return 0 end

	if not (look and toFlash) or look.Magnitude < 1e-6 or toFlash.Magnitude < 1e-6 then
		return 0
	end

	local cosine = look.Unit:Dot(toFlash.Unit)
	local angle = math.deg(math.acos(math.clamp(cosine, -1, 1)))

	local limit = num(def.flashAngle, 100)
	if angle >= limit then return 0 end

	-- 1 looking straight at it, 0 at the edge of vision. Squared, because
	-- the difference between dead-on and half-turned should be most of the
	-- effect rather than a linear share of it.
	local byAngle = (1 - angle / limit) ^ 2

	local full = num(def.flashMax, 3.2)
	local least = num(def.flashMin, 0.35)

	local seconds = full * byDistance * byAngle
	if seconds <= 0 then return 0 end

	-- Anything worth calling a flash is worth at least the floor: a
	-- hundredth of a second of white is a rendering glitch, not a flash.
	return math.max(seconds, math.min(least, full))
end

--=====================================================================
-- THE SMOKE
--=====================================================================

-- How big the cloud is at `elapsed` seconds, and 0 once it is gone. The bloom
-- is deliberate: a smoke is not cover the instant it lands, and that gap is
-- playable in both directions.
function GrenadeDefs.SmokeRadius(def, elapsed)
	local full = num(def.smokeRadius, 0)
	if full <= 0 then return 0 end

	local life = num(def.smokeTime, 16)
	local t = num(elapsed, 0)
	if t < 0 or t > life then return 0 end

	local bloom = math.max(num(def.smokeBloom, 1.4), 1e-3)
	local growing = math.min(t / bloom, 1)

	-- And it thins at the end rather than vanishing, for the same reason.
	local fade = math.clamp((life - t) / math.max(life * 0.15, 1e-3), 0, 1)

	return full * growing * fade
end

-- Whether a line from a to b passes through the cloud. What a bot's vision
-- check wants, and what a smoke has to actually DO to be worth having.
function GrenadeDefs.SmokeBlocks(centre, radius, a, b)
	if radius <= 0 then return false end

	local along = b - a
	local length = along.Magnitude
	if length < 1e-6 then return (a - centre).Magnitude <= radius end

	local unit = along / length
	local t = math.clamp((centre - a):Dot(unit), 0, length)
	local closest = a + unit * t
	return (closest - centre).Magnitude <= radius
end

return GrenadeDefs
