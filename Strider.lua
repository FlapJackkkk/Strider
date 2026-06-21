local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local character = player.Character or player.CharacterAdded:Wait()
local rootPart = character:WaitForChild("HumanoidRootPart")

-- // CONFIGURACIÓN \\ --
local SETTINGS = {
	SeatHeight = 0,       -- set 0
	UpperLegLen = 55,
	LowerLegLen = 75,     
	HipWidthX = 10,       
	HipWidthZ = 12,       
	LegThickness = 2.5,
	
	WalkSpeed = 20, 
	RunSpeed = 65,
	RotationSpeed = 2.5,
	Acceleration = 2,
	
	MinHeight = 40,
	MaxHeight = 120,
	HeightChangeSpeed = 15,
	HeightAdaptSpeed = 4,
	
	StepDistance = 30,    
	StepHeight = 28,      
	StepDuration = 0.55,  
	StepOvershoot = 4,
	
	JumpForceMin = 90,
	JumpForceMax = 200,
	MaxChargeTime = 1.0,
	Gravity = 130,
	CrouchDepth = 30,
	AirControl = 0.3
}

-- Resolve body height. SeatHeight > 0 lets you dial it in manually.
-- Auto formula ensures knees never invert above the hip (which causes legs to cross).
do
	local L1, L2 = SETTINGS.UpperLegLen, SETTINGS.LowerLegLen
	local reach   = L1 + L2
	local minSafe = math.sqrt(math.max(0, L2^2 - L1^2)) + 15
	local autoH   = math.max(reach * 0.70, minSafe)
	local chosen  = SETTINGS.SeatHeight > 0 and SETTINGS.SeatHeight or autoH
	-- Clamp: never below minSafe (knee inversion) or above reach-5 (legs can't reach floor)
	SETTINGS.BodyHeight = math.clamp(chosen, minSafe, reach - 5)
	SETTINGS.MinHeight  = math.max(reach * 0.38, minSafe)
	SETTINGS.MaxHeight  = reach - 5
end

-- // CREATE TOOL \\ --
local tool = Instance.new("Tool")
tool.Name = "Strider Controller"
tool.RequiresHandle = false
tool.Parent = player.Backpack

local isEquipped = false
tool.Equipped:Connect(function() isEquipped = true end)
tool.Unequipped:Connect(function() isEquipped = false end)

-- // CLEANUP \\ --
local mechName = "Strider_Unit"
if workspace:FindFirstChild(mechName) then workspace[mechName]:Destroy() end
local mechModel = Instance.new("Model", workspace); mechModel.Name = mechName

-- // BUILDER \\ --
local function createPart(size, color, name, mat, shape)
	local p = Instance.new("Part")
	p.Size = size; p.Color = color; p.Name = name
	p.Anchored = true; p.CanCollide = false; p.CastShadow = true
	p.Material = mat or Enum.Material.Metal
	p.Shape = shape or Enum.PartType.Block
	p.Parent = mechModel
	return p
end

-- // STRIDER PARTS \\ --
local shellColor = Color3.fromRGB(150, 130, 110) 

local eyeCF = CFrame.identity

-- // 3 LEGS GENERATION (CORRECCIÓN DE POSTURA) \\ --
local Legs = {}
local darkMetal = Color3.fromRGB(40, 40, 45)

-- En Roblox, el eje -Z es "Adelante" (LookVector) y +Z es "Atrás".
local legConfigs = {
	-- Pata Delantera Izquierda: Rodilla hacia ADELANTE (-Z) y AFUERA (-X)
	{name = "FrontLeft",  ox = -1.2, oz = -0.5, kneeDir = Vector3.new(-1, 0, -1.5)}, 
	-- Pata Delantera Derecha: Rodilla hacia ADELANTE (-Z) y AFUERA (+X)
	{name = "FrontRight", ox = 1.2,  oz = -0.5, kneeDir = Vector3.new(1, 0, -1.5)},  
	-- Pata Trasera: Rodilla hacia ATRÁS (+Z)
	{name = "BackCenter", ox = 0,    oz = 1.5,  kneeDir = Vector3.new(0, 0, 2)}   
}

for i, cfg in ipairs(legConfigs) do
	local leg = {
		Upper = createPart(Vector3.new(SETTINGS.LegThickness, SETTINGS.UpperLegLen, SETTINGS.LegThickness), shellColor, cfg.name.."_Upper", Enum.Material.SmoothPlastic, Enum.PartType.Cylinder),
		Lower = createPart(Vector3.new(SETTINGS.LegThickness*0.7, SETTINGS.LowerLegLen, SETTINGS.LegThickness*0.7), darkMetal, cfg.name.."_Lower", Enum.Material.Metal, Enum.PartType.Cylinder),
		Spike = createPart(Vector3.new(0.8, 15, 0.8), Color3.fromRGB(60, 60, 60), cfg.name.."_Spike", Enum.Material.Metal, Enum.PartType.Cylinder),
		
		OffsetX = cfg.ox, OffsetZ = cfg.oz, KneeDir = cfg.kneeDir,
		FootPos = Vector3.new(), StepStart = Vector3.new(), StepEnd = Vector3.new(),
		StepAlpha = 1, Stepping = false,
		ID = i
	}
	table.insert(Legs, leg)
end

-- // STATE VARIABLES \\ --
local mechPos = rootPart.Position + Vector3.new(0, SETTINGS.BodyHeight, 0)
local mechRot, currentPitch, currentRoll = 0, 0, 0
local velocity, vVel = Vector3.new(), 0
local isChargingJump, isJumping, chargeStartTime = false, false, 0
local lastShot = 0
local bodyBobOffset = 0
local bodySway = Vector3.new()
local idleTime = 0
local terrainNormal = Vector3.yAxis

-- // RAYCASTING // --
local acModel = workspace:FindFirstChild(player.Name .. " Aircraft")
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Blacklist

-- Explicit exclude list: everything the mech and player are made of
local rayFilter = {
	character,
	mechModel,
}
for _, leg in ipairs(Legs) do
	table.insert(rayFilter, leg.Upper)
	table.insert(rayFilter, leg.Lower)
	table.insert(rayFilter, leg.Spike)
end
if acModel then table.insert(rayFilter, acModel) end
rayParams.FilterDescendantsInstances = rayFilter

local function getFloor(pos)
	local res = workspace:Raycast(pos + Vector3.new(0, 500, 0), Vector3.new(0, -1000, 0), rayParams)
	return res and res.Position or (pos - Vector3.new(0, SETTINGS.BodyHeight, 0))
end

local function getFloorNormal(pos)
	local res = workspace:Raycast(pos + Vector3.new(0, 500, 0), Vector3.new(0, -1000, 0), rayParams)
	return res and res.Normal or Vector3.yAxis
end

-- Snap body to the actual floor height immediately so it doesn't lerp from a bad spawn position
local initFloor = getFloor(mechPos)
mechPos = Vector3.new(mechPos.X, initFloor.Y + SETTINGS.BodyHeight, mechPos.Z)

for _, leg in ipairs(Legs) do
	leg.FootPos = getFloor(mechPos + Vector3.new(leg.OffsetX * SETTINGS.HipWidthX, -SETTINGS.BodyHeight, leg.OffsetZ * SETTINGS.HipWidthZ))
end

-- // IK SOLVER // --
local function solveIK(hip, foot, L1, L2, bendDir)
	local targetVec = foot - hip
	local dist = math.clamp(targetVec.Magnitude, math.abs(L1 - L2) + 0.1, L1 + L2 - 0.1)
	local alpha = math.acos(math.clamp((L1^2 + dist^2 - L2^2) / (2 * L1 * dist), -1, 1))
	local baseAxis = targetVec.Unit
	local rightAxis = baseAxis:Cross(bendDir)
	if rightAxis.Magnitude < 0.001 then rightAxis = Vector3.xAxis end
	rightAxis = rightAxis.Unit
	local upAxis = rightAxis:Cross(baseAxis).Unit
	return hip + (baseAxis * math.cos(alpha) * L1) + (upAxis * math.sin(alpha) * L1)
end

local function positionLimb(part, p0, p1)
	local dist = (p1 - p0).Magnitude
	if dist < 0.01 then return end
	part.Size = Vector3.new(part.Size.X, dist, part.Size.Z)
	part.CFrame = CFrame.lookAt((p0 + p1) / 2, p1) * CFrame.Angles(math.pi/2, 0, 0)
end

-- // INTEGRATION LOGIC // --
local f1, f2, f3, torso, turret, bullets = {}, {}, {}, nil, nil, {}
if acModel then
	for _, v in pairs(acModel:GetDescendants()) do
		if v.Name=="Post" and v.Parent.Name == "Post" and v.Color==Color3.fromRGB(127,127,127) then table.insert(f1, v)
		elseif v.Name=="Post" and v.Parent.Name == "Post" and v.Color==Color3.fromRGB(0,0,0) then table.insert(f2, v)
		elseif v.Name=="BlockStd" and v.Parent.Name=="HalfPlate" and v.Color == Color3.fromRGB(0,0,0) then table.insert(f3, v)
		elseif v.Name=="BlockStd" and v.Parent.Name=="HalfBlock" then torso = v
		elseif v.Name=="Part" and v.Parent.Name=="Cylinder" then turret = v
		elseif v.Name=="BlockStd" and v.Parent.Name=="TinyBall" then table.insert(bullets, v) end
		
		if v:IsA("BasePart") then
			v.CanCollide = false; v.Anchored = false
			local bf = v:FindFirstChild("ZeroGravityForce") or Instance.new("BodyForce", v)
			bf.Name = "ZeroGravityForce"; bf.Force = Vector3.new(0, v:GetMass() * workspace.Gravity, 0)
		end
	end
end

local bMovers = {}
local function updateBMove(part, tCF, offCF)
	if not part then return end
	if not bMovers[part] then
		bMovers[part] = {bp=Instance.new("BodyPosition",part), bg=Instance.new("BodyGyro",part)}
		bMovers[part].bp.MaxForce, bMovers[part].bp.P = Vector3.one*1e6, 50000
		bMovers[part].bg.MaxTorque, bMovers[part].bg.P = Vector3.one*1e6, 30000
	end
	bMovers[part].bp.Position = (tCF * (offCF or CFrame.identity)).Position
	bMovers[part].bg.CFrame = tCF * (offCF or CFrame.identity)
end

-- // INPUTS // --
UserInputService.InputBegan:Connect(function(input, gpe)
	if gpe or not isEquipped then return end
	if input.KeyCode == Enum.KeyCode.F and not isJumping then isChargingJump, chargeStartTime = true, tick() end
end)
UserInputService.InputEnded:Connect(function(input, gpe)
	if isEquipped and input.KeyCode == Enum.KeyCode.F and isChargingJump then
		isChargingJump, isJumping = false, true
		local alpha = math.clamp((tick() - chargeStartTime) / SETTINGS.MaxChargeTime, 0, 1)
		vVel = SETTINGS.JumpForceMin + (SETTINGS.JumpForceMax - SETTINGS.JumpForceMin) * alpha
	end
end)

-- // MAIN LOOP // --
RunService.RenderStepped:Connect(function(dt)
	local tVel = Vector3.new()
	local currentSpeed = SETTINGS.WalkSpeed
	
	if isEquipped then
		if not isChargingJump then
			if UserInputService:IsKeyDown(Enum.KeyCode.Q) then SETTINGS.BodyHeight = math.max(SETTINGS.MinHeight, SETTINGS.BodyHeight - SETTINGS.HeightChangeSpeed * dt) end
			if UserInputService:IsKeyDown(Enum.KeyCode.E) then SETTINGS.BodyHeight = math.min(SETTINGS.MaxHeight, SETTINGS.BodyHeight + SETTINGS.HeightChangeSpeed * dt) end
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then currentSpeed = SETTINGS.RunSpeed end
		
		local dir = mouse.Hit.Position - mechPos
		local targetRot = math.atan2(-dir.X, -dir.Z)
		local rotDiff = math.atan2(math.sin(targetRot - mechRot), math.cos(targetRot - mechRot))
		mechRot = mechRot + rotDiff * SETTINGS.RotationSpeed * dt
		
		local tPitch = math.clamp(math.atan2(dir.Y, math.sqrt(dir.X^2+dir.Z^2)), -0.3, 0.3)
		currentPitch = currentPitch + (tPitch - currentPitch) * 4 * dt
		
		local rCF = CFrame.Angles(0, mechRot, 0)
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then tVel += rCF.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then tVel -= rCF.LookVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then tVel -= rCF.RightVector end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then tVel += rCF.RightVector end
		if tVel.Magnitude > 0 then tVel = tVel.Unit * currentSpeed end
		
		if UserInputService:IsMouseButtonPressed(0) and tick()-lastShot > 0.1 and #bullets > 0 then
			local b = bullets[math.random(#bullets)]
			if b then
				b.CFrame, b.CanCollide = eyeCF * CFrame.new(0, 0, -5), true
				local bv = b:FindFirstChild("ShotVelocity") or Instance.new("BodyVelocity", b)
				bv.Name = "ShotVelocity"; bv.MaxForce = Vector3.one*1e6; bv.Velocity = eyeCF.LookVector * 600
				task.delay(0.1, function() if bv then bv:Destroy() end end); lastShot = tick()
			end
		end
	end
	
	-- PHYSICS & PROCEDURAL ANIMATION
	local floorData = getFloor(mechPos)
	local flr = floorData.Y
	local targetAbsY = flr + SETTINGS.BodyHeight
	
	if isJumping then
		vVel -= SETTINGS.Gravity * dt
		velocity = velocity:Lerp(tVel, SETTINGS.Acceleration * SETTINGS.AirControl * dt)
		mechPos += Vector3.new(0, vVel * dt, 0)
		if vVel < 0 and mechPos.Y <= targetAbsY then
			mechPos = Vector3.new(mechPos.X, targetAbsY, mechPos.Z)
			bodyBobOffset = math.clamp(vVel * 0.12, -22, 0)
			isJumping, vVel = false, 0
		end
	else
		local tH = SETTINGS.BodyHeight
		if isChargingJump then
			local alpha = math.clamp((tick() - chargeStartTime) / SETTINGS.MaxChargeTime, 0, 1)
			tH = math.max(SETTINGS.CrouchDepth, tH - (alpha * 30))
		end
		mechPos = mechPos:Lerp(Vector3.new(mechPos.X, flr + tH + bodyBobOffset, mechPos.Z), SETTINGS.HeightAdaptSpeed * dt)
		velocity = velocity:Lerp(tVel, SETTINGS.Acceleration * dt)
	end
	mechPos += Vector3.new(velocity.X * dt, 0, velocity.Z * dt)
	
	local tRoll = (velocity.Magnitude > 1 and not isJumping) and math.clamp(velocity:Dot(CFrame.Angles(0,mechRot,0).RightVector)/SETTINGS.RunSpeed * 0.15, -0.15, 0.15) or 0
	currentRoll = currentRoll + (tRoll - currentRoll) * 3 * dt
	
	local avgNorm = Vector3.zero
	for _, l in ipairs(Legs) do avgNorm += getFloorNormal(l.FootPos) end
	avgNorm = avgNorm / #Legs
	if avgNorm.Magnitude > 0.001 then avgNorm = avgNorm.Unit end
	terrainNormal = terrainNormal:Lerp(avgNorm, 5 * dt)

	local up = terrainNormal
	local yawLook = CFrame.Angles(0, mechRot, 0).LookVector
	local surfLook = yawLook - yawLook:Dot(up) * up
	surfLook = surfLook.Magnitude > 0.001 and surfLook.Unit or yawLook
	local surfRight = surfLook:Cross(up).Unit
	local terrainCF = CFrame.fromMatrix(mechPos, surfRight, up, -surfLook)
	local baseCF = terrainCF * CFrame.Angles(currentPitch, 0, currentRoll)
	local mechCF = baseCF * CFrame.new(bodySway)
	
	local eyePos = (mechCF * CFrame.new(0, -2, -9)).Position
	eyeCF = CFrame.lookAt(eyePos, mouse.Hit.Position)

	updateBMove(torso, mechCF)
	updateBMove(turret, eyeCF)

	-- GAIT & LEGS
	local lead = velocity * 0.75
	local currentlyStepping = 0
	local targetBob = 0
	local targetSway = Vector3.new()
	
	for _, l in ipairs(Legs) do if l.Stepping then currentlyStepping = l.ID end end
	
	for i, l in ipairs(Legs) do
		local hip = mechCF * CFrame.new(l.OffsetX * SETTINGS.HipWidthX, -2, l.OffsetZ * SETTINGS.HipWidthZ)
		
		if isJumping then
			l.Stepping = false
			local naturalFoot = hip.Position - Vector3.new(0, SETTINGS.BodyHeight, 0)
			l.FootPos = l.FootPos:Lerp(naturalFoot, 4 * dt)
		else
			local gTar = getFloor(hip.Position + lead + (mechCF.LookVector * l.OffsetZ * 5))
			
			if velocity.Magnitude > 0.5 and not l.Stepping and (currentlyStepping == 0 or currentlyStepping == i) then
				if (l.FootPos - gTar).Magnitude > SETTINGS.StepDistance then
					l.Stepping, currentlyStepping = true, i
					local stepDiff = gTar - l.FootPos
					local overshoot = stepDiff.Magnitude > 0.01 and stepDiff.Unit * SETTINGS.StepOvershoot or Vector3.zero
					l.StepStart, l.StepEnd, l.StepAlpha = l.FootPos, gTar + overshoot, 0
				end
			end
			
			if l.Stepping then
				l.StepAlpha += dt / SETTINGS.StepDuration
				targetSway = Vector3.new(-l.OffsetX * 3, 0, -l.OffsetZ * 3) * math.sin(l.StepAlpha * math.pi)
				targetBob = -math.sin(l.StepAlpha * math.pi) * 4 
				
				if l.StepAlpha >= 1 then 
					l.Stepping, l.FootPos, currentlyStepping = false, getFloor(l.StepEnd), 0
				else 
					local availableVertical = math.max(0, hip.Position.Y - l.StepStart.Y)
					local safeStepHeight = math.min(SETTINGS.StepHeight, availableVertical * 0.45)
					local stepHeightAnim = math.sin(l.StepAlpha * math.pi) * safeStepHeight
					l.FootPos = l.StepStart:Lerp(l.StepEnd, l.StepAlpha) + Vector3.new(0, stepHeightAnim, 0)
					-- Never let the foot clip below the terrain mid-step
					local groundY = getFloor(l.FootPos).Y
					if l.FootPos.Y < groundY then
						l.FootPos = Vector3.new(l.FootPos.X, groundY, l.FootPos.Z)
					end
				end
			else
				l.FootPos = l.FootPos:Lerp(getFloor(l.FootPos), 20 * dt)
			end
		end
		
		-- // CÁLCULO DE LA DIRECCIÓN DE LA RODILLA \\ --
		local worldKneeDir = mechCF:VectorToWorldSpace(l.KneeDir).Unit
		local bendDir = (worldKneeDir + Vector3.new(0, 0.6, 0)).Unit
		
		local knee = solveIK(hip.Position, l.FootPos, SETTINGS.UpperLegLen, SETTINGS.LowerLegLen, bendDir)
		
		positionLimb(l.Upper, hip.Position, knee)
		positionLimb(l.Lower, knee, l.FootPos)
		l.Spike.CFrame = CFrame.new(l.FootPos)
		
		if f1[i] then updateBMove(f1[i], l.Upper.CFrame * CFrame.Angles(math.pi/2, 0, 0), CFrame.Angles(math.pi/2,0,0)) end
		if f2[i] then updateBMove(f2[i], l.Lower.CFrame, CFrame.Angles(0, 0, 0), CFrame.Angles(math.pi/2,0,0)) end
		if f3[i] then updateBMove(f3[i], l.Lower.CFrame * CFrame.new(0, -l.Lower.Size.Y/2, 0), CFrame.Angles(math.pi/2,0,0)) end
	end
	
	-- Idle sway: blends in when stationary, fades out when moving
	idleTime += dt
	local idleAlpha = math.clamp(1 - velocity.Magnitude / 4, 0, 1)
	targetBob += math.sin(idleTime * 1.4) * 2.5 * idleAlpha
	targetSway += Vector3.new(
		math.sin(idleTime * 0.7) * 2 * idleAlpha,
		0,
		math.sin(idleTime * 1.1) * 1.2 * idleAlpha
	)

	bodyBobOffset = bodyBobOffset + (targetBob - bodyBobOffset) * 8 * dt
	bodySway = bodySway:Lerp(targetSway, 8 * dt)
end)
