-- ModuleScript: Crosshair
-- CS 1.6 style crosshair. Static or dynamic; when dynamic the gap is the
-- weapon's actual spread cone projected to screen space, so what you see is
-- literally where bullets can land.
--
-- Setup:
--   local Crosshair = require(script.Crosshair)
--   Crosshair.Init()
--   -- in RenderStepped:
--   Crosshair.Update(deltaTime)
--
-- Weapons calls Crosshair.HitMarker() on a confirmed hit.

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
local State  = require(script.Parent.State)

local Players = game:GetService("Players")
local plr = Players.LocalPlayer
local cam = workspace.CurrentCamera

local Crosshair = {}

local gui
local top, bottom, left, right, dot
local hitTop, hitBottom, hitLeft, hitRight
local hitFade = 0
local smoothedGap = 0

--=====================================================================
-- CONSTRUCTION
--=====================================================================

local function makeBar(parent, name)
	local f = Instance.new("Frame")
	f.Name = name
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.BorderSizePixel = 0
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.Parent = parent

	local stroke = Instance.new("UIStroke")
	stroke.Name = "Outline"
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = f

	return f
end

function Crosshair.Init()
	if gui then return end

	gui = Instance.new("ScreenGui")
	gui.Name = "Crosshair"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = plr:WaitForChild("PlayerGui")

	top    = makeBar(gui, "Top")
	bottom = makeBar(gui, "Bottom")
	left   = makeBar(gui, "Left")
	right  = makeBar(gui, "Right")
	dot    = makeBar(gui, "Dot")

	-- Hit marker: four diagonal ticks. Separate frames so they can fade
	-- independently of the crosshair itself.
	hitTop    = makeBar(gui, "HitTL")
	hitBottom = makeBar(gui, "HitTR")
	hitLeft   = makeBar(gui, "HitBL")
	hitRight  = makeBar(gui, "HitBR")

	for _, f in ipairs({hitTop, hitBottom, hitLeft, hitRight}) do
		f.Rotation = 45
		f.BackgroundTransparency = 1
		f.Outline.Transparency = 1
	end
	hitBottom.Rotation = -45
	hitLeft.Rotation = -45
	
	
end

--=====================================================================
-- SPREAD -> PIXELS
--=====================================================================

-- Roblox FieldOfView is the VERTICAL fov in degrees. A cone half-angle theta
-- lands at this many pixels from the centre:
local function degreesToPixels(deg)
	local viewport = cam.ViewportSize
	local halfFov = math.rad(cam.FieldOfView) / 2
	if halfFov <= 0 then return 0 end
	return (viewport.Y / 2) * math.tan(math.rad(deg)) / math.tan(halfFov)
end

--=====================================================================
-- PUBLIC
--=====================================================================

function Crosshair.HitMarker()
	if Config.cl_crosshairHitMarker == false then return end
	hitFade = Config.cl_crosshairHitTime or 0.25
end

--=====================================================================
-- UPDATE
--=====================================================================

-- WHERE THE BARS GO, as offsets from the centre, for one set of numbers.
--
-- Pulled out of Update so the settings menu's preview can call it. A preview
-- that re-derived this geometry would be a second implementation of it, and
-- the whole value of a preview is that it shows you what you are about to
-- get -- which it stops doing the first time the two drift apart.
--
-- Deliberately takes the numbers rather than reading the cvars: the preview
-- needs to draw a value the player is dragging toward, not the one currently
-- committed.
function Crosshair.Layout(gap, length, thickness, wantDot)
	local offset = gap + length / 2

	local bars = {
		{ name = "top",    dx = 0,       dy = -offset, w = thickness, h = length },
		{ name = "bottom", dx = 0,       dy =  offset, w = thickness, h = length },
		{ name = "left",   dx = -offset, dy = 0,       w = length,    h = thickness },
		{ name = "right",  dx =  offset, dy = 0,       w = length,    h = thickness },
	}

	if wantDot then
		table.insert(bars, { name = "dot", dx = 0, dy = 0, w = thickness, h = thickness })
	end

	return bars
end

function Crosshair.Update(deltaTime)
	if not gui then return end

	-- The crosshair belongs to a weapon. In a car there is nothing to aim,
	-- and a dot pinned to the middle of the screen while you are looking
	-- through a corner is something in the way -- so it is off by default and
	-- cl_vehicle_crosshair brings it back for anyone shooting out of a window.
	local inVehicle = State.inVehicle == true
	local visible = Config.cl_crosshair ~= false
		and not State.isThirdPerson
		and (not inVehicle or Config.cl_vehicle_crosshair == true)
	gui.Enabled = visible
	if not visible then return end

	local viewport = cam.ViewportSize
	local cx, cy = viewport.X / 2, viewport.Y / 2

	local thickness = Config.cl_crosshairthickness or 2
	local length    = Config.cl_crosshairsize or 7
	local baseGap   = Config.cl_crosshairgap or 4
	local colour    = Config.cl_crosshaircolor or Color3.fromRGB(0, 255, 0)
	local alpha     = 1 - (Config.cl_crosshairalpha or 1)

	-- ---- gap ----
	local gap = baseGap

	if Config.cl_dynamiccrosshair ~= false then
		-- State.spreadDegrees is the current cone half-angle, maintained by
		-- Weapons. Projecting it means the gap grows exactly as fast as the
		-- weapon actually loses accuracy.
		local spreadPx = degreesToPixels(State.spreadDegrees or 0)
		gap = baseGap + spreadPx

		-- Smooth so single shots read as a pulse rather than a flicker. CS 1.6
		-- snaps outward and eases back; matching that reads better than
		-- symmetric smoothing.
		local rate = (gap > smoothedGap) and 40 or 12
		smoothedGap = smoothedGap + (gap - smoothedGap) * (1 - math.exp(-rate * deltaTime))
		gap = smoothedGap
	else
		smoothedGap = baseGap
	end

	gap = math.clamp(gap, 0, viewport.Y * 0.45)

	-- ---- bars ----
	local outlineThickness = Config.cl_crosshair_drawoutline and 1 or 0

	local function place(bar, spec)
		bar.Position = UDim2.fromOffset(cx + spec.dx, cy + spec.dy)
		bar.Size = UDim2.fromOffset(spec.w, spec.h)
		bar.BackgroundColor3 = colour
		bar.BackgroundTransparency = alpha
		bar.Outline.Thickness = outlineThickness
		bar.Visible = true
	end

	local bars = { top = top, bottom = bottom, left = left, right = right, dot = dot }
	dot.Visible = false

	for _, spec in ipairs(Crosshair.Layout(gap, length, thickness, Config.cl_crosshairdot)) do
		place(bars[spec.name], spec)
	end

	-- ---- hit marker ----
	if hitFade > 0 then
		hitFade = math.max(hitFade - deltaTime, 0)
		local t = hitFade / (Config.cl_crosshairHitTime or 0.25)
		local hitOffset = gap + length
		local hitColour = Config.cl_crosshairHitColor or Color3.fromRGB(255, 60, 60)

		local function placeHit(bar, dx, dy)
			bar.Position = UDim2.fromOffset(cx + dx, cy + dy)
			bar.Size = UDim2.fromOffset(thickness, length * 0.8)
			bar.BackgroundColor3 = hitColour
			bar.BackgroundTransparency = 1 - t
			-- UIStroke has its own transparency; it does not follow the
			-- frame's BackgroundTransparency.
			bar.Outline.Transparency = 1 - t
			bar.Outline.Thickness = outlineThickness
		end

		local d = hitOffset * 0.7
		placeHit(hitTop,    -d, -d)
		placeHit(hitBottom,  d, -d)
		placeHit(hitLeft,   -d,  d)
		placeHit(hitRight,   d,  d)
	else
		for _, f in ipairs({hitTop, hitBottom, hitLeft, hitRight}) do
			f.BackgroundTransparency = 1
			f.Outline.Transparency = 1
		end
	end
end

return Crosshair