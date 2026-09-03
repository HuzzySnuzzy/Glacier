-- ModuleScript: MovementMath
local MovementMath = {}

function MovementMath.QuakeGroundAccelerate(currentVelocity, wishDir, targetSpeed, accel, deltaTime)
	local currentSpeed = currentVelocity:Dot(wishDir)
	local addSpeed = targetSpeed - currentSpeed
	if addSpeed <= 0 then return currentVelocity end
	local accelSpeed = math.min(accel * deltaTime * targetSpeed, addSpeed)
	return currentVelocity + (wishDir * accelSpeed)
end

function MovementMath.QuakeAirAccelerate(currentVelocity, wishDir, wishSpeed, accel, deltaTime, airCap)
	local capped = math.min(wishSpeed, airCap)
	local currentSpeed = currentVelocity:Dot(wishDir)
	local addSpeed = capped - currentSpeed
	if addSpeed <= 0 then return currentVelocity end
	local accelSpeed = math.min(accel * wishSpeed * deltaTime, addSpeed)  -- full wishSpeed
	return currentVelocity + (wishDir * accelSpeed)
end

function MovementMath.ClipVelocity(inVel, normal, overbounce)
	local backoff = inVel:Dot(normal)
	if backoff >= 0 then return inVel end
	return inVel - (normal * backoff * overbounce)
end

return MovementMath