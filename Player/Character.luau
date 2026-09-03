	-- ModuleScript: Character
	local State = require(script.Parent.State)
	local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"))
	local Character = {}
	local Inventory = require(game.ReplicatedStorage:WaitForChild("Inventory"))
	local plr = game.Players.LocalPlayer
	-- Input.lua, module scope


	-- Everything Spawn does locally, MINUS the CreateBody/CreatePuppet requests.
	-- The server-driven path (Lifecycle ADOPT) builds the rig itself and then
	-- calls this; the client-driven path (Character.Spawn) requests the rig first
	-- and then calls the same function. Previously ADOPT inlined a partial copy of
	-- this, which is why a server-spawned player got a body but no weapons.
	function Character.Adopt(body, puppet)
		if not body then return false end
		puppet = puppet or body:WaitForChild("Puppet", 5)
		if not puppet then
			warn("[Character] Adopt: no Puppet under " .. body.Name)
			return false
		end

		body.CanCollide = false
		body.Anchored   = true

		local hum = puppet:FindFirstChild("Humanoid")
		if hum then
			hum:ChangeState(Enum.HumanoidStateType.Physics)
			hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.Running, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		end

		-- The hand-rolled animator/track block that used to live here is gone.
		-- Visuals.SetupPuppet loads State.tracks from AnimDefs the moment it sees
		-- a new puppet, so building a second set here only burned Animator slots
		-- against the 64-track cap and left orphaned tracks playing underneath.

		State.playerBody   = body
		State.playerPuppet = puppet
		State.activeSlot   = State.activeSlot or Inventory.SLOT_PRIMARY

		if State.baseSize then body.Size = State.baseSize end
		if State.velocity then State.velocity = Vector3.zero end

		workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
		Character.UpdateVisibility()

		-- CLIENT-SIDE PREDICTION. A player with an executor can call this and
		-- issue themselves an AWP; WeaponServer still takes packet.weapon on
		-- trust. Move to a server InventorySync push before shipping.
		-- Inventory.ApplyLoadout(State, DEFAULT_LOADOUT)

		return true
	end

	function Character.UpdateVisibility()
		if not State.playerPuppet then return end

		for _, child in ipairs(State.playerPuppet:GetDescendants()) do
			if child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" then
				if State.isThirdPerson then
					child.LocalTransparencyModifier = 0
				else
					local isHead = (child.Name == "Head")
					local isAccessory = child:FindFirstAncestorOfClass("Accessory") ~= nil
					if isHead or isAccessory then
						child.LocalTransparencyModifier = 1
					else
						child.LocalTransparencyModifier = Config.cl_showLimbsInFirstPerson and 0 or 1
					end
				end
			elseif child:IsA("Decal") and child.Name == "face" then
				child.LocalTransparencyModifier = State.isThirdPerson and 0 or 1
			end
		end
	end

	function Character.Spawn()
		game.ReplicatedStorage.CreateBody:FireServer()
		local body = workspace:WaitForChild(plr.UserId..'RawBody')
		body.Parent = workspace
		--body.CustomPhysicalProperties = PhysicalProperties.new(0, 0, 0, 0, 0)
		body.CanCollide = false
		body.Anchored = true

		game.ReplicatedStorage.CreatePuppet:FireServer()
		local puppet = workspace:WaitForChild(plr.UserId..'RawBody'):WaitForChild("Puppet")
		puppet.Parent = body

		local attachment = Instance.new("Attachment", body)
		

		local hum = puppet:FindFirstChild("Humanoid")
		if hum then
			hum:ChangeState(Enum.HumanoidStateType.Physics)
			hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.Running, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)

			local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
			local anims = {
				Idle = Instance.new("Animation"), Walk = Instance.new("Animation"),
				Sprint = Instance.new("Animation"), CrouchIdle = Instance.new("Animation"),
				CrouchWalk = Instance.new("Animation"),
			}

			anims.Idle.AnimationId = "rbxassetid://180435571"
			anims.Walk.AnimationId = "rbxassetid://180426354"
			anims.Sprint.AnimationId = "rbxassetid://180426354"
			anims.CrouchIdle.AnimationId = "rbxassetid://180435571"
			anims.CrouchWalk.AnimationId = "rbxassetid://180426354"

			State.tracks = {
				Idle = animator:LoadAnimation(anims.Idle), Walk = animator:LoadAnimation(anims.Walk),
				Sprint = animator:LoadAnimation(anims.Sprint), CrouchIdle = animator:LoadAnimation(anims.CrouchIdle),
				CrouchWalk = animator:LoadAnimation(anims.CrouchWalk),
			}

			State.currentTrack = State.tracks.Idle
			State.currentTrack:Play()
		end

		State.playerBody = body
		State.playerPuppet = puppet
		body.Size = State.baseSize
		workspace.CurrentCamera.CameraType = Enum.CameraType.Scriptable
		print("baseSize:", State.baseSize, "-> probeRadius:", math.max(math.min(State.baseSize.X, State.baseSize.Z)/2 - 0.05, 0.05))
	Character.UpdateVisibility()
	
	
		
		warn("SPAWNED!")
		return Character.Adopt(body, puppet)
	end

	return Character