-- ModuleScript: State
return {
	
	surfaceFriction       = 1,      -- last known ground material friction, 0..1
	brakingWindowElapsed  = 0,      -- grounded time, gates friction
	ladderTimeout         = 0,      -- blocks ladder re-grab after pushing off
	prevCrouchStance      = false,  -- edge detect for the duck-lift trigger
	duckFraction          = 0,      -- 0 standing .. 1 fully ducked (Visuals reads this)
	isDucked              = false,  -- hull has FINISHED shrinking
	isProneStance         = false,
	isInStanceTransition  = false,
	cameraRoll            = 0,      -- degrees (Visuals reads this)
	noclip                = false,
	groundInstance        = nil,
	-- Player Objects
	playerBody = nil,
	playerPuppet = nil,
	viewmodel = nil,
	prevBodyPos  = nil,
	curBodyPos   = nil,
	pos = nil,
	stepInterval = 1/60,
	tickAlpha    = 1,
	snapRender   = false,
	recoilPunch = Vector2.zero,
	recoil      = nil,
	
	baseSize = Vector3.new(2, 5, 2),
	gameTime  = 0,
	timeScale = 1,
	-- Movement States
	isSprinting = false,
	isCrouching = false,
	isProne = false,
	isGrounded = false,
	isJumping = false,
	isDiving = false,
	velocity = Vector3.new(),
	lastSafePos = nil,
	stuckTicks = 0,
	dbgWishCalls = 0,
	forwardMoveAxis = 0,   -- -1 (S), 0, or 1 (W)
	-- Ladder
	onLadder = false,
	ladderNormal = Vector3.zAxis,
	-- Timers
	coyoteTimer = 0,        -- seconds of grace remaining since last grounded
	jumpBufferTimer = 0,    -- seconds of grace remaining since space was pressed
	dbgAirtime = 0,
	dbgJumpHeight = 0,
	stepUpCount = 0,
	-- Input States
	spaceHeld = false,
	cPressTime = 0,
	cIsHeld = false,
	holdThreshold = 0.25,
	wishDir = Vector3.new(),
	duckLift = 0,
	-- Camera & Visuals
	cameraX = 0,
	cameraY = 0,
	isThirdPerson = false,
	currentCamHeight = 2,
	currentPuppetPitch = 0,

	-- Animations
	tracks = {},
	currentTrack = nil,
	vmTracks = {},
	currentVmTrack = nil,

	-- Loadout (UPDATED FOR CS 1.6 STYLE)
	primary = "ak47", 
	secondary = "USP", 
	melee = "Knife",
	activeSlot = 1, -- Starts with Slot 1 (Primary) equipped
	currentWeaponStats = nil, -- Holds the data from the weapon module
	currentAmmo = 0,
	reserveAmmo = 0,
	isShooting = false,       -- True if holding left click
	isReloading = false,
	lastFireTime = 0,         -- Used to calculate fire rate
	
	
	-- weapons
	triggerDown = false,
	reloadRequested = false,
	inspectRequested = false,
	-- Set by Input on a keypress, consumed by Weapons, which fires the remote.
	dropRequested = false,
	useRequested = false,

	-- CS:GO jump fatigue. Only read when mv_stamina is on; 0 is "rested".
	stamina = 0,
	nextFireTime = 0,
	reloadEndTime = 0,
	equipEndTime = 0,
}

