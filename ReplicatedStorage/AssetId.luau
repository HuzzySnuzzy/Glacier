-- ModuleScript: ReplicatedStorage.AssetId
--
-- Whatever an author wrote, as the string Roblox actually wants.
--
-- The canonical form is "rbxassetid://116630545706868" and everything that
-- ships in this engine is written that way. But the thing in front of you
-- when you are adding an item is a NUMBER -- it is what the Toolbox shows,
-- what the URL ends in, and what you copy -- so writing the number is the
-- obvious mistake, and the two places that consume one both handled it badly:
-- the animation loader called it "Malformed AnimationId", which reads as
-- "your id is wrong" rather than "your id is missing a prefix", and the sound
-- player just assigned it and played nothing at all.
--
-- One rule, in one place, for both. An item author should not have to know
-- that the engine wanted a prefix.

local AssetId = {}

-- Returns a canonical rbxassetid:// string, or nil.
--
-- Accepted:
--   rbxassetid://123        the canonical form, returned unchanged
--   123, "123"              a bare id, from the Toolbox or the URL bar
--   a roblox.com asset URL  what Copy Link on the website gives you
--
-- nil for everything else, INCLUDING the empty string and nil itself: a def
-- with no id is a deliberate stub -- an item that is playable before anybody
-- has animated it -- and telling that apart from a genuinely unusable id is
-- the caller's business, since only the caller knows whether to warn.
function AssetId.Resolve(value)
	if type(value) == "number" then
		-- NaN fails every comparison, so it is caught by the <= rather than
		-- reaching string.format and coming out as an id made of nonsense.
		if not (value > 0) then return nil end
		return ("rbxassetid://%d"):format(math.floor(value))
	end

	if type(value) ~= "string" then return nil end

	local trimmed = value:match("^%s*(.-)%s*$")
	if trimmed == "" then return nil end

	if trimmed:match("^rbxassetid://%d+$") then return trimmed end

	local bare = trimmed:match("^(%d+)$")
	if bare then return "rbxassetid://" .. bare end

	-- A pasted link, in both shapes the website hands out:
	--   https://www.roblox.com/library/123/Some-Name
	--   https://www.roblox.com/asset/?id=123
	local fromUrl = trimmed:match("roblox%.com/library/(%d+)")
		or trimmed:match("[?&]id=(%d+)")
	if fromUrl then return "rbxassetid://" .. fromUrl end

	return nil
end

-- "Did the author mean to leave this out?" Kept next to Resolve because the
-- two are always asked together, and a caller that rolled its own emptiness
-- check would disagree with this one about a string of spaces.
function AssetId.IsBlank(value)
	if value == nil then return true end
	if type(value) ~= "string" then return false end
	return value:match("^%s*$") ~= nil
end

return AssetId
