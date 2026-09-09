-- ModuleScript: Interact
-- Parent: Player (the LocalScript's module folder)
--
-- WHAT +USE WOULD DO RIGHT NOW -- decided once, shown to the player, and
-- acted on by whoever owns the thing.
--
-- Before this there was no such answer. The vehicle code scanned for a car,
-- the pickup code asked the server for the nearest weapon, and each of them
-- ate the keypress if it liked what it found. Two consequences, and both are
-- what "+use is broken" meant:
--
--   NOTHING TOLD YOU. A press either did something or did not, and the
--   difference between "there is nothing here", "it is two studs too far" and
--   "your rifle slot is full" was a silence you had to guess at.
--
--   NEAREST-BY-DISTANCE IS NOT WHAT YOU MEANT. Two guns a foot apart on the
--   floor, and which one you got came down to centimetres of standing
--   position rather than to the one you were looking at.
--
-- So: you point at a thing. The nearest thing you are pointing at is the
-- target, exactly one target exists at a time, it says what it is and what
-- pressing the key will do to it, and every consumer of +use asks HERE
-- rather than deciding for itself.
--
-- AIM COMES FROM THE CAMERA, REACH COMES FROM THE BODY. They are different
-- points and conflating them is a bug in both directions: in third person the
-- camera sits well behind you, so measuring reach from it would shorten your
-- arms as you pulled the camera back -- and the SERVER measures range from
-- the body, so a client that measured from the camera would offer things the
-- server then refuses.
--
-- ADDING A NEW KIND OF INTERACTION is a source:
--
--   Interact.AddSource("doors", function(add, ctx)
--       for _, door in ipairs(myDoors) do
--           add({ instance = door, verb = "Open", command = "+use",
--                 onUse = function() openIt(door) end })
--       end
--   end)
--
-- and anything tagged GlacierUse in CollectionService is already one, with
-- its label and verb read off its own attributes -- which is the hook a
-- plugin wants and the reason this is a registry rather than three branches.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local Recoil = require(ReplicatedStorage:WaitForChild("Recoil"))
local ItemRegistry = require(ReplicatedStorage:WaitForChild("ItemRegistry"))
local State = require(script.Parent.State)
local Input = require(script.Parent.Input)

local plr = Players.LocalPlayer

local Interact = {}

-- The tag a plugin puts on anything it wants +use to reach.
Interact.TAG = "GlacierUse"

local function num(v, fallback)
	local n = tonumber(v)
	return n or fallback
end

-- WHERE YOU ARE LOOKING, and it is NOT workspace.CurrentCamera.
--
-- This is the same aim the bullets use -- Weapons builds its shot from
-- exactly these two lines -- and using anything else is how the label ends up
-- describing something other than what the crosshair is over.
--
-- The camera was the first attempt and it was wrong twice over. It has the
-- viewbob baked into it, which must never move a bullet and must not move a
-- prompt either; and reading it here reported an eye over a thousand studs
-- from the player, which made every candidate in the world either behind them
-- or wide of the aim. Weapons already says so in as many words above
-- eyePosition, and this is the second thing to learn it the hard way.
--
-- So: the body's position plus the eye height, and the yaw and pitch the
-- engine actually steers with. Through Recoil.aimCFrame rather than rebuilt
-- from sin and cos, because the angle convention in this engine has been got
-- wrong five times and there is no reason for a sixth.
--
-- Recoil punch is deliberately NOT applied. Bullets travel along the punched
-- angle; a prompt that jittered off its target under recoil would be reading
-- the number for a different question.
local function aimFrom()
	local body = State.playerBody
	if not (body and body.Parent) then return nil end

	-- Interpolated between physics ticks exactly as the shot is, so the aim
	-- does not lag the picture at frame rates that are not a multiple of the
	-- tick.
	local base = (State.curBodyPos and State.prevBodyPos)
		and State.prevBodyPos:Lerp(State.curBodyPos, State.tickAlpha or 1)
		or (body:IsA("BasePart") and body.Position or body:GetPivot().Position)

	local eye = base + Vector3.new(0, State.currentCamHeight or 0, 0)
	local look = Recoil.aimCFrame(eye, State.cameraX or 0, State.cameraY or 0,
		Vector2.zero).LookVector

	-- REACH is measured from the body and AIM from the eye, which are a head's
	-- height apart. The server measures range from the body, so a client that
	-- measured from the eye would offer things the server then refuses.
	return eye, look, base
end

--=====================================================================
-- THE PICK
--=====================================================================

-- WHICH OF THESE IS THE PLAYER POINTING AT, and of those, which is nearest.
--
-- Pure, and separated from everything that gathers candidates or draws
-- labels, because it is the only part with any geometry in it and geometry is
-- where this engine's bugs live. It can be run against a table of made-up
-- positions with no Workspace in the room.
--
-- A candidate needs `position` and `radius`; everything else is carried
-- through untouched for the caller.
--
--   eye, look   where the CAMERA is and which way it faces
--   from        where the BODY is -- range is measured from here, see above
--
-- The test is a cylinder around the aim ray rather than an angle, because an
-- angle is the wrong shape for this: a fixed cone is a dinner plate at ten
-- studs and a pinhead at one, so a rifle at your feet becomes impossible to
-- look at while a distant one snaps on from halfway across the room. A
-- candidate qualifies when the aim ray passes within its own radius plus a
-- little -- which is "you are pointing at it" at every distance.
--
-- Ranked by SURFACE distance, not centre distance. A car and a cartridge case
-- ranked by their centres would have the car lose while you stand against its
-- door, which is not what "closest" means to the person standing there.
-- ONE JUDGEMENT, used by the pick and by the report.
--
-- Returns a verdict string and, when it is "ok", how good the candidate is.
-- Kept as one function on purpose: a report that recomputed the rules would
-- drift from them, and a report that disagrees with the thing it is reporting
-- on is worse than no report -- it sends you looking in the wrong place.
local function judge(c, eye, look, from, range, slack)
	local radius = num(c.radius, 1)

	-- REACH, from the body -- and a candidate may state its own, in both how
	-- far and how measured.
	--
	-- A car is the case. The server measures to the chassis BOX and this would
	-- measure to a sphere around it, which for a van is four studs of
	-- disagreement -- and every stud of it is a prompt offering something the
	-- server then refuses, which is worse than no prompt. So the vehicle
	-- source hands over the same number the server will compute, and its own
	-- cvar to check it against.
	local reach = num(c.reach, (c.position - from).Magnitude - radius)
	local limit = num(c.range, range)
	if reach > limit then
		return ("out of reach (%.1f > %.1f studs)"):format(reach, limit)
	end

	-- AIM, from the camera.
	local to = c.position - eye
	local along = to:Dot(look)

	-- Behind you is never a target. Allowed to be slightly negative so
	-- something you are standing inside still counts.
	if along <= -radius then return "behind you" end

	local perpendicular = (to - look * along).Magnitude
	local allowance = radius + slack
	if perpendicular > allowance then
		return ("not pointing at it (%.1f off, needs %.1f)")
			:format(perpendicular, allowance)
	end

	return "ok", math.max(reach, 0)
end

function Interact.Pick(candidates, eye, look, from, opts)
	opts = opts or {}
	local range = num(opts.range, 12)
	local slack = num(opts.slack, 1.5)

	local best, bestScore
	for _, c in ipairs(candidates) do
		local verdict, score = judge(c, eye, look, from, range, slack)
		if verdict == "ok" and (not bestScore or score < bestScore) then
			best, bestScore = c, score
		end
	end

	return best, bestScore
end

-- Every candidate and what happened to it. What `use_report` prints, and the
-- answer to "there is no prompt and I cannot tell why" -- which, on a system
-- whose whole failure mode is silence, is not a luxury.
function Interact.Explain(candidates, eye, look, from, opts)
	opts = opts or {}
	local range = num(opts.range, 12)
	local slack = num(opts.slack, 1.5)

	local out = {}
	for _, c in ipairs(candidates) do
		local verdict, score = judge(c, eye, look, from, range, slack)
		table.insert(out, { candidate = c, verdict = verdict, score = score })
	end
	return out
end

--=====================================================================
-- SOURCES
--=====================================================================

local sources = {}       -- ordered, so the list is stable between frames

-- Replaces a source of the same name rather than stacking a second copy of
-- it: a module that is required twice -- which happens in Studio -- would
-- otherwise offer everything it owns twice over.
function Interact.AddSource(name, fn)
	if type(name) ~= "string" or type(fn) ~= "function" then return end
	for _, entry in ipairs(sources) do
		if entry.name == name then entry.fn = fn return end
	end
	table.insert(sources, { name = name, fn = fn })
end

function Interact.RemoveSource(name)
	for i, entry in ipairs(sources) do
		if entry.name == name then table.remove(sources, i) return end
	end
end

--=====================================================================
-- MEASURING A CANDIDATE
--=====================================================================

-- Cached per instance and held WEAKLY, because a pickup is destroyed the
-- moment somebody takes it and a strong key here would keep the model -- and
-- everything welded to it -- alive for as long as the session.
local sizeCache = setmetatable({}, { __mode = "k" })

-- HOW BIG IT IS, measured once. Only the size is cached: where a thing is
-- changes -- a dropped rifle rolls, a car drives off -- and caching that is
-- exactly how a prompt ends up naming something that has left.
local function radiusOf(instance)
	local cached = sizeCache[instance]
	if cached then return cached end

	local radius
	if instance:IsA("BasePart") then
		radius = instance.Size.Magnitude * 0.5
	elseif instance:IsA("Model") then
		-- GetBoundingBox throws on a model with no parts in it, which a
		-- half-replicated drop briefly is.
		local ok, _, size = pcall(function()
			local c, s = instance:GetBoundingBox()
			return c, s
		end)
		if ok and size then radius = size.Magnitude * 0.5 end
	end

	if not radius then return nil end
	sizeCache[instance] = radius
	return radius
end

-- Where a candidate is NOW, with the radius measured once.
local function poseOf(instance)
	if not (instance and instance.Parent) then return nil end

	local radius = radiusOf(instance)
	if not radius then return nil end

	if instance:IsA("BasePart") then return instance.Position, radius end
	return instance:GetPivot().Position, radius
end

--=====================================================================
-- BUILT-IN SOURCES
--=====================================================================

-- A NAME A PLAYER RECOGNISES. The class is what the code calls it; an item
-- may declare something friendlier, and a model may have been renamed by
-- whoever placed it.
local function displayName(class)
	if type(class) ~= "string" or class == "" then return "item" end
	local stats = ItemRegistry.Stats(class)
	if type(stats) == "table" and type(stats.displayName) == "string" then
		return stats.displayName
	end
	return class
end

-- WEAPONS AND ITEMS ON THE GROUND. Found by the attribute the drop server
-- stamps on them rather than by a table this file would have to be told
-- about, so a drop made by anything at all is reachable.
Interact.AddSource("pickups", function(add)
	local folder = workspace:FindFirstChild("WeaponDrops")
	if not folder then return end

	for _, object in ipairs(folder:GetChildren()) do
		if object:GetAttribute("GlacierPickup") then
			local class = object:GetAttribute("Class")
			add({
				instance = object,
				kind = "pickup",
				command = "+use",
				verb = "Pick up",
				label = displayName(class),
				class = class,
			})
		end
	end
end)

-- ANYTHING A PLUGIN TAGGED. Its own attributes decide what the prompt says,
-- so adding a door or a ladder or a vending machine is a tag and two strings
-- rather than a change in here.
Interact.AddSource("tagged", function(add)
	for _, object in ipairs(CollectionService:GetTagged(Interact.TAG)) do
		-- Tagged instances are global; the ones in ReplicatedStorage or in
		-- somebody's Backpack are not in the world and must not be offered.
		if object:IsDescendantOf(workspace) then
			add({
				instance = object,
				kind = "tagged",
				command = "+use",
				verb = object:GetAttribute("UseVerb") or "Use",
				label = object:GetAttribute("UseLabel") or object.Name,
			})
		end
	end
end)

--=====================================================================
-- LINE OF SIGHT
--=====================================================================

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude

-- A WALL IS SOMETHING YOU COULD WALK INTO.
--
-- Without this the very first thing the ray hits is the weapon in your own
-- hands: the viewmodel is parented to the Camera, which is where this ray
-- starts, so it sat about a stud out and reported every rifle, every car and
-- every door in the world as being behind something. No prompt, anywhere,
-- ever -- and no way to tell that from the feature simply not working.
--
-- The same reasoning the movement and vehicle casts already use. Effects,
-- viewmodels and decoration are not geometry, and a sight test that treats
-- them as geometry is a sight test that always says no.
losParams.RespectCanCollide = true

-- Can we actually see it, or is there a wall in the way?
--
-- One cast, against the WINNER only. Casting per candidate would be a cast
-- per dropped weapon per frame for a test that changes the answer roughly
-- never -- and the case it exists for is singular: a rifle on the far side of
-- a door you are looking through the gap of.
local function visible(instance, eye, position)
	if Config.cl_useLos == false then return true end

	-- The camera, because the viewmodel hangs off it and a collidable one
	-- would get past RespectCanCollide above. Belt and braces on purpose:
	-- this is the failure that took the whole feature down, and it did it
	-- silently.
	local ignore = { instance }
	if State.playerBody then table.insert(ignore, State.playerBody) end
	if State.playerPuppet then table.insert(ignore, State.playerPuppet) end

	-- A pickup lying on the floor is not a wall. The whole drops folder is
	-- excluded rather than the winner alone, so two rifles side by side do not
	-- occlude each other and neither ever wins.
	local drops = workspace:FindFirstChild("WeaponDrops")
	if drops then table.insert(ignore, drops) end

	losParams.FilterDescendantsInstances = ignore

	local delta = position - eye
	local distance = delta.Magnitude
	if distance < 1e-3 then return true end

	local hit = workspace:Raycast(eye, delta, losParams)
	-- Short of the surface by a margin: the cast is aimed at the CENTRE of the
	-- thing, so its own near face would otherwise count as a wall for anything
	-- the filter missed.
	return not hit or (hit.Distance >= distance - 1)
end

--=====================================================================
-- THE PROMPT
--=====================================================================

local gui, panel, label

local function build()
	if gui then return end

	gui = Instance.new("ScreenGui")
	gui.Name = "UsePrompt"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	-- Under the console and the menu, over the crosshair.
	gui.DisplayOrder = 51
	gui.Parent = plr:WaitForChild("PlayerGui")

	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0)
	-- BELOW the crosshair, not on it. A label centred on the aim point covers
	-- the thing it is describing.
	panel.Position = UDim2.new(0.5, 0, 0.5, 42)
	panel.Size = UDim2.new(0, 10, 0, 26)
	panel.AutomaticSize = Enum.AutomaticSize.X
	panel.BackgroundColor3 = Color3.fromRGB(12, 12, 14)
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = panel

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = panel

	label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(0, 0, 1, 0)
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Font = Enum.Font.Code
	label.TextSize = 15
	label.TextColor3 = Color3.fromRGB(235, 235, 240)
	label.RichText = true
	label.Text = ""
	label.Parent = panel
end

-- THE KEY AS IT IS BOUND RIGHT NOW, not as it was shipped. A prompt that says
-- E to somebody who moved use to F is worse than no prompt: it is a wrong
-- answer to the one question it was put there to answer.
local function keyText(command)
	local keys = Input.GetKeysFor and Input.GetKeysFor(command)
	if type(keys) ~= "table" or #keys == 0 then return nil end
	return string.upper(tostring(keys[1]))
end

function Interact.PromptText(target)
	if not target then return "" end

	local what = target.label
	local verb = target.verb or "Use"
	local phrase = what and (verb .. " " .. what) or verb

	local key = keyText(target.command or "+use")
	-- UNBOUND IS SAID OUT LOUD rather than shown as an empty bracket. "[ ] Pick
	-- up AK-47" reads as a rendering fault; this reads as the thing to fix.
	if not key then
		return ("%s -- no key bound"):format(phrase)
	end
	return ("[%s] %s"):format(key, phrase)
end

--=====================================================================
-- UPDATE
--=====================================================================

local target = nil
local nextScanAt = 0
local scratch = {}

-- HOW MUCH BETTER a new candidate has to be before it takes the prompt off
-- the one that has it. Two rifles at almost the same distance would otherwise
-- swap the label back and forth as you breathe on the mouse.
local HYSTERESIS = 0.85

local function gather(ctx)
	table.clear(scratch)

	local function add(candidate)
		if type(candidate) ~= "table" then return end
		local position, radius = poseOf(candidate.instance)
		if not position then return end
		candidate.position = candidate.position or position
		candidate.radius = candidate.radius or radius
		table.insert(scratch, candidate)
	end

	for _, entry in ipairs(sources) do
		-- One broken source must not take the whole prompt down with it --
		-- especially once these come from plugins.
		local ok, why = pcall(entry.fn, add, ctx)
		if not ok then
			warn(("[Interact] source %q errored: %s"):format(entry.name, tostring(why)))
		end
	end

	return scratch
end

-- What happened to the candidate the player most likely meant: the nearest
-- one, whether or not it qualified. Reported when nothing won, because "three
-- things nearby and none of them chosen" is the state that needs a reason.
local function nearestVerdict(candidates, ctx, opts)
	if #candidates == 0 then return "nothing nearby" end

	local closest, closestDistance
	for _, c in ipairs(candidates) do
		local d = (c.position - ctx.from).Magnitude
		if not closestDistance or d < closestDistance then
			closest, closestDistance = c, d
		end
	end

	local report = Interact.Explain({ closest }, ctx.eye, ctx.look, ctx.from, opts)
	return ("%s: %s"):format(tostring(closest.label), report[1].verdict)
end

function Interact.Update(deltaTime)
	build()

	local now = os.clock()
	local rate = math.max(num(Config.cl_useRate, 20), 1)

	-- THE PRESS FRAME IS ALWAYS FRESH.
	--
	-- Scanning at twenty a second is right for a label -- it does not need
	-- your frame rate -- but it is wrong for the one frame the key goes down,
	-- where a target up to fifty milliseconds old is a flick of the mouse ago.
	-- Both consumers run later in the same frame than this does, so forcing
	-- the scan here is enough to make what you pressed and what you were
	-- pointing at the same thing.
	if State.useRequested then nextScanAt = 0 end

	if now >= nextScanAt then
		nextScanAt = now + 1 / rate

		local body = State.playerBody
		-- SEATED IS NOT A TIME FOR PROMPTS. The vehicle source already
		-- excludes the car you are in, and offering the rifle lying beside it
		-- would be offering something you cannot reach from the seat.
		if State.inVehicle then
			target = nil
		elseif not (body and body.Parent) then
			-- No body: nothing to point with, and a prompt left on screen
			-- through a death is a prompt nobody trusts again. Aliveness is
			-- the body's presence here because that is what the rest of the
			-- client uses to decide whether it is drawing a player at all.
			target = nil
		else
			local eye, look, from = aimFrom()
			local ctx = { eye = eye, look = look, from = from }

			local candidates = gather(ctx)
			local opts = {
				range = num(Config.sv_pickupRange, 12),
				slack = num(Config.cl_useSlack, 1.5),
			}

			local best, score = Interact.Pick(candidates, ctx.eye, ctx.look, from, opts)

			-- The one we already had keeps it unless the new one is clearly
			-- better AND we can see it.
			if best and target and best.instance ~= target.instance then
				local _, hadScore = Interact.Pick({ target }, ctx.eye, ctx.look, from, opts)
				if hadScore and score and score > hadScore * HYSTERESIS then
					best = target
				end
			end

			-- WHY THERE IS NO PROMPT, published rather than worked out later.
			--
			-- Everything here fails by showing nothing, which is also what it
			-- does when there is genuinely nothing to use -- so "it is not
			-- working" and "you are not pointing at anything" look identical
			-- from the outside. The debug HUD shows this line, and it is the
			-- difference between a screenshot answering the question and a
			-- screenshot raising it.
			local why
			if best and not visible(best.instance, ctx.eye, best.position) then
				best = nil
				why = "behind something"
			elseif not best then
				why = nearestVerdict(candidates, ctx, opts)
			end

			target = best

			State.useScans = (State.useScans or 0) + 1
			State.useCandidates = #candidates
			State.useTarget = best
				and ("%s %s"):format(best.kind or "?", tostring(best.label))
				or nil
			State.useWhy = why
		end
	end

	--------------------------------------------------------------
	-- DRAW
	--------------------------------------------------------------
	-- The TARGET is kept whatever this says. Turning the labels off is a
	-- preference about the screen, not about whether +use works -- and a
	-- setting that quietly disabled picking things up would be a bug report
	-- nobody could connect to the checkbox they ticked.
	if not target or Config.cl_usePrompts == false then
		panel.Visible = false
		return
	end

	label.Text = Interact.PromptText(target)
	panel.Visible = true
end

-- The current target, or nil. What Weapons and Vehicle ask instead of each
-- running their own scan and each eating the keypress.
function Interact.Target()
	return target
end

-- The target IF it is of this kind, which is what a consumer actually wants
-- to know: Vehicle asks for a vehicle, Weapons asks for a pickup, and neither
-- has to inspect a table it did not build.
function Interact.TargetOfKind(kind)
	if target and target.kind == kind then return target end
	return nil
end

function Interact.Init()
	build()
end

--=====================================================================
-- CONSOLE
--=====================================================================

-- WHY THERE IS NO PROMPT.
--
-- Everything here fails by showing nothing, which is the same thing it does
-- when there is genuinely nothing to use -- and the same thing it did when a
-- line-of-sight test was quietly stopped by the player's own viewmodel. One
-- command that lists every candidate and what happened to it is the
-- difference between that being a five-second answer and an afternoon.
Config.Command("use_report", {
	args = {},
	help = "list what +use can see, and why each candidate did or did not win",
	run = function(ctx)
		local body = State.playerBody
		if not (body and body.Parent) then
			ctx.reply("[use] no body")
			return
		end
		if State.inVehicle then
			ctx.reply("[use] seated -- prompts are off while you are in a car")
			return
		end

		local eye, look, from = aimFrom()
		local ctxInfo = { eye = eye, look = look, from = from }

		local candidates = gather(ctxInfo)
		local opts = {
			range = num(Config.sv_pickupRange, 12),
			slack = num(Config.cl_useSlack, 1.5),
		}

		local lines = {
			("[use] %d candidate%s   prompts %s   sight check %s"):format(
				#candidates, #candidates == 1 and "" or "s",
				Config.cl_usePrompts == false and "OFF" or "on",
				Config.cl_useLos == false and "off" or "ON"),
		}

		for _, entry in ipairs(Interact.Explain(candidates, ctxInfo.eye,
			ctxInfo.look, from, opts)) do
			local c = entry.candidate
			local verdict = entry.verdict

			-- The sight test is only run on the winner in the real update --
			-- one cast, not one per rifle on the floor -- but the report runs
			-- it on everything, because "it qualified and then something was
			-- in the way" is exactly the state that has no other symptom.
			if verdict == "ok" and not visible(c.instance, ctxInfo.eye, c.position) then
				verdict = "BEHIND SOMETHING"
			end

			table.insert(lines, ("  %-9s %-22s %s"):format(
				c.kind or "?", tostring(c.label or c.instance.Name), verdict))
		end

		if #candidates == 0 then
			table.insert(lines,
				"  nothing offered -- no drops, no cars with a free seat, " ..
				"nothing tagged " .. Interact.TAG .. " near you")
		end

		local current = Interact.Target()
		table.insert(lines, ("  target: %s"):format(
			current and Interact.PromptText(current) or "none"))

		ctx.reply(table.concat(lines, "\n"))
	end,
})

return Interact
