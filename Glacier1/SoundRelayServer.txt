-- Script: Glacier1/SoundRelayServer
-- Relays cosmetic positional audio between clients.
--
-- Cosmetic, so: UnreliableRemoteEvent. A dropped footstep is a dropped
-- footstep, and ordering doesn't matter. Never route gameplay-authoritative
-- audio (hit confirms) through here.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local SoundKeys = require(ReplicatedStorage:WaitForChild("SoundKeys"))

local remote = Instance.new("UnreliableRemoteEvent")
remote.Name = "SoundFX"
remote.Parent = ReplicatedStorage

--------------------------------------------------------------------
-- AUTHORITATIVE POSITION
--------------------------------------------------------------------

-- Character.Spawn names the hull <UserId>RawBody, so the server can find it
-- directly. If you later expose WeaponServer's position history, swap this
-- for a lookup at the packet's game time -- it'll be tighter under lag.
local function bodyOf(player)
	return workspace:FindFirstChild(player.UserId .. "RawBody")
end

-- How far a client-claimed sound position may sit from the body the server
-- knows about. Generous enough for interpolation and RTT, tight enough that
-- a cheater can't throw phantom footsteps across the map.
local POSITION_TOLERANCE = 25

--------------------------------------------------------------------
-- RATE LIMIT
--------------------------------------------------------------------

-- Token bucket. Sprinting produces ~4 steps/sec; weapons add a handful more.
local RATE = 15        -- tokens/sec
local BURST = 25

local buckets = {}

local function allow(player, dt)
	local b = buckets[player]
	if not b then
		b = {tokens = BURST, last = os.clock()}
		buckets[player] = b
	end
	local now = os.clock()
	b.tokens = math.min(BURST, b.tokens + (now - b.last) * RATE)
	b.last = now
	if b.tokens < 1 then return false end
	b.tokens -= 1
	return true
end

Players.PlayerRemoving:Connect(function(p) buckets[p] = nil end)

--------------------------------------------------------------------
-- RECEIVE + RELAY
--------------------------------------------------------------------

remote.OnServerEvent:Connect(function(sender, key, position, pitch, volScale)
	--print("Receive:\n",sender, key, position, pitch, volScale,"\n")
	if type(key) ~= "string" then warn(key) return end
	if typeof(position) ~= "Vector3" then warn(position) return end

	local def = SoundKeys.Defs[key]
	if not def then warn("No Defs") return end
	if not allow(sender) then warn("Allow",sender) return end

	-- Sanitise the numerics rather than dropping: a NaN pitch would poison
	-- the receiving client's AudioPlayer.
	pitch = tonumber(pitch) or 1
	if pitch ~= pitch then pitch = 1 end
	pitch = math.clamp(pitch, 0.5, 2)

	volScale = tonumber(volScale) or 1
	if volScale ~= volScale then volScale = 1 end
	volScale = math.clamp(volScale, 0, 1)

	-- Clamp the claimed position to the body the server owns. Clamping rather
	-- than rejecting means honest packets that arrived late still play, just
	-- from where the server thinks the player is.
	local body = bodyOf(sender)
	if not body then return end
	local puppet = body:FindFirstChild("Puppet")
	if not puppet then warn("no puppet") return end
	position = puppet:GetPivot().Position
	

	-- Cull by audible range. Anyone who couldn't hear it doesn't get told
	-- it happened -- bandwidth, and it closes the packet-sniffing angle.
	local cull = def.range * 1.25

	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= sender then
			local otherBody = bodyOf(other)
			if otherBody and (otherBody.Position - position).Magnitude <= cull then
				remote:FireClient(other, key, position, pitch, volScale)
			end
		end
	end
end)