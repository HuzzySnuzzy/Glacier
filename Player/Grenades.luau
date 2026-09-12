-- ModuleScript: Grenades
-- Parent: Player (the LocalScript's module folder)
--
-- WHAT A GRENADE LOOKS LIKE FROM INSIDE ONE.
--
-- Three things, and the first is the only one anybody will describe if you
-- ask them what grenades feel like:
--
--   THE FLASH   a wall of white that fades, and how long it lasts is the
--               server's answer to where you were looking
--   THE ARC     where the one in your hand would land, so a lineup is
--               something you can learn rather than guess
--   THE NOISE   bounces and bangs, positioned in the world
--
-- The flash duration is NOT computed here. It depends on where the victim was
-- looking, which is a thing the client could lie about very profitably --
-- "I was facing away" is worth three seconds of not being blind. The server
-- reads the aim it already has and sends a number.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config      = require(ReplicatedStorage:WaitForChild("Config"))
local GrenadeDefs = require(ReplicatedStorage:WaitForChild("GrenadeDefs"))
local State       = require(script.Parent.State)
local Sounds      = require(script.Parent.Sounds)

local plr = Players.LocalPlayer

local Grenades = {}

local function num(v, fallback)
	local n = tonumber(v)
	return n or fallback
end

--=====================================================================
-- THE FLASH
--=====================================================================

local gui, sheet
local blindUntil = 0
local blindFor = 0

local function build()
	if gui then return end

	gui = Instance.new("ScreenGui")
	gui.Name = "Flash"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- OVER EVERYTHING, including the console and the menu. A flash you can
	-- read your inventory through is not a flash.
	gui.DisplayOrder = 200
	gui.Parent = plr:WaitForChild("PlayerGui")

	sheet = Instance.new("Frame")
	sheet.Name = "White"
	sheet.Size = UDim2.new(1, 0, 1, 0)
	sheet.BackgroundColor3 = Color3.new(1, 1, 1)
	sheet.BackgroundTransparency = 1
	sheet.BorderSizePixel = 0
	sheet.Visible = false
	sheet.Parent = gui
end

-- HOW WHITE THE SCREEN IS, from how much of the blind is left.
--
-- NOT LINEAR, and this is the whole character of a flash. A full one is solid
-- white for the first part of it and then clears quickly -- what you remember
-- is the moment it lifts, not a long grey smear. A linear fade reads as a
-- screen effect; this reads as being flashed.
function Grenades.Opacity(remaining, total)
	if total <= 0 or remaining <= 0 then return 0 end

	local fraction = math.clamp(remaining / total, 0, 1)

	-- Solid for the first stretch, then a curve down. The knee is a fraction
	-- of the flash rather than a fixed number of seconds, so a glancing flash
	-- is a brief flicker rather than a short version of a full one.
	local solid = 0.45
	if fraction >= solid then return 1 end

	return (fraction / solid) ^ 0.6
end

-- TWO FLASHES ARE ONE FLASH, as long as the worse of them.
--
-- Not the sum: a pair of cheap flashes would then be worse than one perfect
-- one, and the skill would be throwing more rather than throwing better. Not
-- the newer either: a bad flash would CURE a good one, which is the same bug
-- pointing the other way.
--
-- Returns how long the flash should now last, and nil when the one already
-- running is worth more than the new one.
function Grenades.Longer(remaining, incoming)
	incoming = num(incoming, 0)
	if incoming <= 0 then return nil end
	if incoming <= math.max(num(remaining, 0), 0) then return nil end
	return incoming
end

function Grenades.Blind(seconds, kind)
	build()
	if Config.cl_flash_effect == false then return end

	seconds = num(seconds, 0)
	if seconds <= 0 then return end

	-- THE LONGER OF THE TWO, not the sum and not the newer. Two flashes in a
	-- second is one flash that lasts as long as the worse of them; adding
	-- them would make a pair of cheap ones worse than a perfect one, and
	-- replacing would let a bad flash CURE a good one.
	local now = os.clock()
	local lasts = Grenades.Longer(blindUntil - now, seconds)
	if not lasts then return end

	blindFor = lasts
	blindUntil = now + lasts

	Sounds.Push("world", "Flash")
	State.blindUntil = blindUntil
end

function Grenades.Update()
	if not sheet then return end

	local remaining = blindUntil - os.clock()
	if remaining <= 0 then
		if sheet.Visible then sheet.Visible = false end
		State.blind = 0
		return
	end

	local opacity = Grenades.Opacity(remaining, blindFor)
	sheet.Visible = true
	sheet.BackgroundTransparency = 1 - opacity
	State.blind = opacity
end

--=====================================================================
-- THE ARC
--=====================================================================

-- Where the grenade in your hand would land, as a list of points.
--
-- The SAME throw the server uses -- GrenadeDefs.ThrowVelocity -- and the same
-- gravity, because an arc drawn from a second copy of the maths is an arc
-- that lies, and a lineup you practised against a lie is worse than no arc
-- at all. What it does NOT do is bounce: the first surface is where it ends,
-- because predicting a bounce off geometry the server may disagree about is
-- exactly where a drawn line stops being trustworthy.
function Grenades.Arc(def, origin, look, style, gravity, points, dt)
	local out = {}
	if not def then return out end

	local velocity = GrenadeDefs.ThrowVelocity(def, look, style, nil)
	local position = origin

	for _ = 1, points do
		table.insert(out, position)
		velocity += Vector3.new(0, -gravity * dt, 0)
		position += velocity * dt
	end

	return out
end

--=====================================================================
-- WIRING
--=====================================================================

function Grenades.Init()
	build()

	local flashed = ReplicatedStorage:FindFirstChild("Flashed")
	if flashed then
		flashed.OnClientEvent:Connect(function(seconds, kind)
			Grenades.Blind(seconds, kind)
		end)
	end

	local event = ReplicatedStorage:FindFirstChild("NadeEvent")
	if event then
		event.OnClientEvent:Connect(function(what, kind, position)
			-- FLAT, for now. Sounds.Push has no positional form, and a bounce
			-- round a corner that sounds like it is in your head is worth
			-- less than one that is simply quiet -- but it is worth more than
			-- silence, which is what a grenade had before this. Positioning
			-- these is a job for the audio layer the vehicles already use.
			if what == "bounce" then
				Sounds.Push("world", "NadeBounce")
			elseif what == "detonate" then
				Sounds.Push("world", kind == "hegrenade" and "Explode" or "NadePop")
			end
		end)
	end
end

return Grenades
