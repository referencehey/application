--[[
	WeaponSystemHandler.lua
	Description: A modular client-side weapon controller handling procedural viewmodels, 
	raycasting logic, ammo management, and HUD synchronization.
--]]

local module = {}

-- [[ CONFIGURATION & MAPPINGS ]]
local KEY_TO_SLOT = {
	[Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5, [Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8, [Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.Zero] = 0,
}

-- [[ SERVICES ]]
local Plrs = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")
local SG = game:GetService("StarterGui")
local UIS = game:GetService("UserInputService")
local RunS = game:GetService("RunService")
local L = game:GetService("Lighting")
local Debris = game:GetService("Debris")
local CAS = game:GetService("ContextActionService")

-- [[ RESOURCE PATHS ]]
local AssetsFolder = RS:WaitForChild("Assets")
local UIFolder = AssetsFolder:WaitForChild("UI")
local GunsFolder = AssetsFolder:WaitForChild("Guns")
local WeaponModelsFolder = AssetsFolder:WaitForChild("WeaponModels")
local VFXFolder = AssetsFolder:WaitForChild("VFX")
local SFXFolder = AssetsFolder:WaitForChild("SFX")

local SharedFolder = RS:WaitForChild("Shared")
local ConfigFolder = SharedFolder:WaitForChild("Config")
local UtilsFolder = SharedFolder:WaitForChild("Utils")
local ClientModulesFolder = SharedFolder:WaitForChild("ClientModules")

local RemotesFolder = RS:WaitForChild("Remotes")
local GunMechanicsRemotes = RemotesFolder:WaitForChild("GunMechanics")

-- [[ MODULE DEPENDENCIES ]]
local Weapons = require(ConfigFolder:WaitForChild("Weapons"))
local DebugService = require(UtilsFolder:WaitForChild("DebugService"))
local DeviceService = require(UtilsFolder:WaitForChild("DeviceService"))
local Crosshair = require(ClientModulesFolder:WaitForChild("CrosshairHandler"))
local SFX = require(ClientModulesFolder:WaitForChild("SFXHandler"))

-- [[ CONSTANTS ]]
local player = Plrs.LocalPlayer
local pGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- [[ UI REFERENCES ]]
local gui = pGui:WaitForChild("WeaponHUD")
local slotsContainer = gui:WaitForChild("Slots")
local ammoFrame = gui:WaitForChild("Ammo")
local ammoLabel = ammoFrame:WaitForChild("Ammo")
local weaponSlotTemplate = UIFolder:WaitForChild("WeaponSlotTemplate")

-- [[ STATE MANAGEMENT ]]
local slots = {}
local equippedWeapon
local weaponData = {}

-- Viewmodel States
local currentViewmodel, viewmodelCon
local jumpOffset = 0
local recoilOffset = CFrame.new()
local bobWeight = 0
local lastShot = 0

-- Firing/Movement States
local isFiring = false
local isReloading = false
local currentSpread = 0
local lastFireTime = 0
local camRecoil = CFrame.new()
local swayOffset = CFrame.new()

-- ADS (Aim Down Sights) States
local isAiming = false
local adsAlpha = 0 -- Interpolation factor: 0 (Hip) to 1 (ADS)
local defaultFOV = 70

-- UI Visual States
local ammoShake = 0 
local originalAmmoPos = ammoLabel.Position
local isFlashing = false

-- [[ HELPER FUNCTIONS ]]

--- Creates a temporary proxy part to host attachments/particles for VFX
local function createTempParticlePart(lifetime, pos)
	local part = Instance.new("Part")
	part.Size = Vector3.new(0, 0, 0); part.Transparency = 1; part.Anchored = true
	part.CanCollide = false; part.CanQuery = false; part.CanTouch = false
	part.Position = pos; part.Parent = workspace
	Debris:AddItem(part, lifetime)
	return part
end

--- Triggers UI feedback when attempting to fire with an empty clip
local function noAmmoVisuals()
	if isFlashing then return end
	isFlashing = true
	
	SFX.PlaySoundEffect(SFXFolder.NoAmmo)
	ammoShake = 24 -- Trigger RenderStepped shake logic

	local originalColor = Color3.fromRGB(255, 255, 255) 
	local flashColor = Color3.fromRGB(255, 50, 50)

	local flashInfo = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true)
	local flashTween = TS:Create(ammoLabel, flashInfo, {TextColor3 = flashColor})

	task.spawn(function()
		flashTween:Play()
		flashTween.Completed:Wait()
		ammoLabel.TextColor3 = originalColor
		isFlashing = false
	end)
end

--- Procedural Visual Effects: Impact, Blood, and Tracers
local function impactEffect(pos)
	local hitPart = createTempParticlePart(0.5, pos)
	local attachment = Instance.new("Attachment", hitPart)
	local sparks = VFXFolder.BulletSparks:Clone()
	sparks.Parent = attachment
	sparks:Emit(3)
end

local function bloodSplatter(pos)
	local hitPart = createTempParticlePart(1, pos)
	local attachment = VFXFolder.BloodSplatter:Clone()
	attachment.Parent = hitPart
	for _, particle in attachment:GetChildren() do
		particle:Emit(particle:GetAttribute("EmitAmount") or 3)
	end
end

--- Logic for rendering 3D tracers using Beams and Attachments
local function createBeam(startMuzzle, endPos)
	if not startMuzzle then return end
	local distance = (startMuzzle.WorldPosition - endPos).Magnitude
	if distance < 1 then return end 

	local part = createTempParticlePart(0.2, endPos)
	local att0 = Instance.new("Attachment", part); att0.WorldPosition = startMuzzle.WorldPosition
	local att1 = Instance.new("Attachment", part); att1.WorldPosition = endPos

	local beam = VFXFolder.BulletBeam:Clone()
	beam.Attachment0 = att0; beam.Attachment1 = att1
	beam.Parent = part

	TS:Create(beam, TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Width0 = 0, Width1 = 0, TextureSpeed = 5
	}):Play()
end

--- Procedural Recoil: Updates CFrame offsets for the viewmodel and camera
local function applyRecoil()
	local weaponInfo = Weapons[equippedWeapon]
	if not weaponInfo then return end

	-- Convert config degrees to radians for CFrame math
	local vKick = math.rad(math.random(weaponInfo.VRecoil[1], weaponInfo.VRecoil[2]) * 5)
	local hKick = math.rad(math.random(weaponInfo.HRecoil[1], weaponInfo.HRecoil[2]) * 5)

	recoilOffset = recoilOffset * CFrame.Angles(vKick, hKick, 0) * CFrame.new(0, 0, 0.2)
	camRecoil = camRecoil * CFrame.Angles(vKick * 0.3, hKick * 0.3, 0)
end

local function updateAmmoCount(weaponName: string)
	local data = weaponData[weaponName]
	if not data then return end
	ammoLabel.Text = "Ammo: "..data.Ammo.."/"..data.StoredAmmo
	ammoFrame.Visible = true
end

-- [[ CORE WEAPON LOGIC ]]

--- Primary Shooting Logic: Handles ammo, spread expansion, and Raycast validation
local function shoot()
	if not equippedWeapon or isReloading then return end
	local weaponInfo = Weapons[equippedWeapon]
	
	if weaponData[equippedWeapon].Ammo <= 0 then noAmmoVisuals() return end
	weaponData[equippedWeapon].Ammo -= weaponInfo.Bullets
	
	SFX.PlaySoundEffect(SFXFolder.Gunshot)
	updateAmmoCount(equippedWeapon)

	-- Procedural Spread Expansion
	if os.clock() - lastShot > weaponInfo.FireRate * 2 then 
		currentSpread = weaponInfo.MinSpread
	else 
		currentSpread = math.clamp(currentSpread + weaponInfo.SpreadIncrement, weaponInfo.MinSpread, weaponInfo.MaxSpread) 
	end
	
	lastShot = os.clock()

	-- Raycast Projection from Camera Viewport
	local viewportRay = camera:ViewportPointToRay(camera.ViewportSize.X/2, camera.ViewportSize.Y/2)
	local randomSpread = Vector3.new(
		(math.random() - 0.5) * currentSpread,
		(math.random() - 0.5) * currentSpread,
		(math.random() - 0.5) * currentSpread
	)
	local shootDir = (viewportRay.Direction + randomSpread).Unit

	-- Filtering Logic: Ignore user's character and non-collidable accessories
	local rayParams = RaycastParams.new()
	local blacklist = {player.Character, currentViewmodel}

	for _, otherPlayer in Plrs:GetPlayers() do
		local char = otherPlayer.Character; if not char then continue end
		for _, item in char:GetChildren() do
			if item:IsA("Accessory") or item:IsA("Tool") then table.insert(blacklist, item) end
		end
	end

	rayParams.FilterDescendantsInstances = blacklist
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	
	local result = workspace:Raycast(viewportRay.Origin, shootDir * 500, rayParams)
	local endPos = result and result.Position or viewportRay.Origin + (shootDir * 500)

	-- Apply Visuals
	local muzzle = currentViewmodel:FindFirstChild("Muzzle", true)
	createBeam(muzzle, endPos)
	applyRecoil()
	
	-- Hit Processing
	if result and result.Instance then
		local char = result.Instance.Parent
		local hum = char:FindFirstChild("Humanoid") or char.Parent:FindFirstChild("Humanoid")
		if hum then bloodSplatter(endPos) else impactEffect(endPos) end
	end

	-- Notify Server for damage processing
	GunMechanicsRemotes.Shoot:FireServer(equippedWeapon, endPos, result and result.Instance)
end

--- Handles Semi and Full-Auto firing cycles
local function startFiring()
	if isFiring or not equippedWeapon then return end
	local weaponInfo = Weapons[equippedWeapon]

	if weaponInfo.Auto then
		isFiring = true
		task.spawn(function()
			while isFiring and equippedWeapon do
				if os.clock() - lastShot >= weaponInfo.FireRate then shoot() end
				task.wait() -- Minimal wait to prevent thread exhaustion
			end
		end)
	else
		if os.clock() - lastShot >= weaponInfo.FireRate then shoot() end
	end
end

local function stopFiring()
	isFiring = false
	currentSpread = 0 
end

-- [[ VIEWMODEL ENGINE ]]

--- Procedural Animation System: Handles ADS interpolation, Bobbing, and Sway
local function setViewmodel(weaponName)
	if currentViewmodel then currentViewmodel:Destroy() end
	if viewmodelCon then viewmodelCon:Disconnect() end

	local weaponModel = WeaponModelsFolder:FindFirstChild(weaponName)
	if weaponModel then
		currentViewmodel = weaponModel:Clone()

		-- Sanitize Viewmodel for client rendering
		for _, part in currentViewmodel:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false; part.CastShadow = false
				part.CanQuery = false; part.CanTouch = false
				part.LocalTransparencyModifier = 0 
			end
		end

		currentViewmodel.Parent = camera 

		viewmodelCon = RunS.RenderStepped:Connect(function(dt)
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")

			if currentViewmodel and root and hum then
				local weaponInfo = Weapons[equippedWeapon]
				if not weaponInfo then return end

				-- 1. Spread Recovery Interpolation
				if not isFiring then
					currentSpread = math.lerp(currentSpread, weaponInfo.MinSpread, dt * weaponInfo.SpreadRecovery)
				end

				-- 2. ADS Logic & Smooth FOV Transition
				local aimSpeed = weaponInfo.AimSpeed or 10
				local targetAlpha = (isAiming and not isReloading) and 1 or 0
				adsAlpha = math.lerp(adsAlpha, targetAlpha, dt * aimSpeed)

				local targetFOVValue = (isAiming and not isReloading) and (weaponInfo.AimFOV or 50) or defaultFOV
				camera.FieldOfView = math.lerp(camera.FieldOfView, targetFOVValue, dt * aimSpeed)

				-- 3. Procedural Bobbing & Velocity-based Jump Sway
				local verticalVel = root.AssemblyLinearVelocity.Y
				local targetJump = math.clamp(verticalVel * -0.015, -0.5, 0.5)
				jumpOffset = math.lerp(jumpOffset, targetJump, dt * 10)

				local horizontalSpeed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
				bobWeight = math.lerp(bobWeight, (horizontalSpeed > 0.5 and 1 or 0), dt * 5)

				local idleX, idleY = math.sin(os.clock() * 1.5) * 0.05, math.cos(os.clock() * 0.75) * 0.03
				local walkX, walkY = math.sin(os.clock() * 10) * 0.15, math.cos(os.clock() * 14) * 0.12
				local finalBob = CFrame.new(math.lerp(idleX, walkX, bobWeight), math.lerp(idleY, walkY, bobWeight) + jumpOffset, 0)

				-- 4. Calculate Final Transformation
				recoilOffset = recoilOffset:Lerp(CFrame.new(), dt * 8)
				local currentOffset = weaponInfo.ViewmodelOffset:Lerp(weaponInfo.AimOffset or CFrame.new(0, -1, -2), adsAlpha)
				local adjustedBob = finalBob:Lerp(CFrame.new(finalBob.Position * 0.1), adsAlpha)

				-- 5. Positioning viewmodel relative to Camera
				local finalCF = camera.CFrame * currentOffset * adjustedBob * recoilOffset
				currentViewmodel:PivotTo(finalCF)
			end
		end)
	end
end

--- Cleanup state and viewmodel when unequipped or died
local function clearViewmodel()
	if currentViewmodel then
		currentViewmodel:Destroy()
		currentViewmodel = nil
		if viewmodelCon then viewmodelCon:Disconnect() end
	end
	
	isAiming = false; adsAlpha = 0
	
	-- Visual cleanup for FOV reset
	local transitionBack
	transitionBack = RunS.RenderStepped:Connect(function(dt)
		camera.FieldOfView = math.lerp(camera.FieldOfView, defaultFOV, dt * 10)
		if math.abs(camera.FieldOfView - defaultFOV) < 0.1 then
			camera.FieldOfView = defaultFOV
			transitionBack:Disconnect()
		end
	end)
	
	isFiring = false; currentSpread = 0
	recoilOffset = CFrame.new(); camRecoil = CFrame.new(); lastShot = 0
end

-- [[ INVENTORY & UI HANDLING ]]

--- Tweens slot visibility and highlight when switching weapons
local function updateSlotVisuals()
	for _, slotFrame in slotsContainer:GetChildren() do
		if not slotFrame:IsA("Frame") then continue end

		local isEquipped = (equippedWeapon == slots[tonumber(slotFrame.Name)])
		local targetSize = isEquipped and UDim2.fromScale(1.2, 1.2) or UDim2.fromScale(1, 1)
		local targetTextTransparency = isEquipped and 0 or 0.5
		local targetColor = isEquipped and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(0, 0, 0)

		local info = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TS:Create(slotFrame, info, {Size = targetSize, BackgroundColor3 = targetColor}):Play()

		local nameLabel = slotFrame:FindFirstChild("WeaponName")
		if nameLabel then
			TS:Create(nameLabel, info, {TextTransparency = targetTextTransparency}):Play()
		end
	end
end

--- Core Logic for Equipping/Unequipping Tools and Viewmodels
local function toggleWeapon(weaponName: string)
	local char = player.Character; if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local backpack = player:WaitForChild("Backpack")
	
	isReloading = false
	local currentHeldTool = char:FindFirstChildOfClass("Tool")

	-- Holster logic if clicking the same weapon
	if currentHeldTool and currentHeldTool.Name == weaponName then
		currentHeldTool.Parent = backpack
		equippedWeapon = nil
		clearViewmodel(); updateSlotVisuals(); Crosshair.ToggleCrosshair(false); ammoFrame.Visible = false
		return 
	end

	local newTool = backpack:FindFirstChild(weaponName) or char:FindFirstChild(weaponName)
	if newTool and newTool:IsA("Tool") then
		updateAmmoCount(weaponName)
		SFX.PlaySoundEffect(SFXFolder.Equip)
		
		clearViewmodel() 
		hum:UnequipTools() 

		Crosshair.ToggleCrosshair(true)
		equippedWeapon = weaponName
		newTool.Parent = char
		setViewmodel(weaponName)

		-- Hide world-model for the local player to prevent clipping with the Viewmodel
		for _, part in newTool:GetDescendants() do
			if part:IsA("BasePart") then part.LocalTransparencyModifier = 1 end
		end
	else
		DebugService.DebugWarn("Weapon " .. weaponName .. " not found!", script)
	end
	
	updateSlotVisuals()
end

--- Generates a new HUD slot for a weapon
local function newSlot(slot: number, weaponName: string)
	local weaponInfo = Weapons[weaponName]
	if not weaponInfo then return end
	
	local slotUI = weaponSlotTemplate:Clone()
	slotUI.Name = slot; slotUI.Parent = slotsContainer; slotUI.LayoutOrder = slot
	
	slotUI:WaitForChild("Slot").Text = slot
	slotUI:WaitForChild("WeaponName").Text = weaponName
	slotUI:WaitForChild("Image").Image = weaponInfo.ImageID
	
	slots[slot] = weaponName
	
	-- Handle UI interactions for Mobile/Desktop
	local clickBtn = Instance.new("TextButton")
	clickBtn.Size = UDim2.fromScale(1, 1); clickBtn.BackgroundTransparency = 1; clickBtn.Text = ""
	clickBtn.Parent = slotUI
	clickBtn.Activated:Connect(function() stopFiring(); toggleWeapon(weaponName) end)
	
	slotUI.Visible = true
end

-- [[ INPUT & SYSTEM INITIALIZATION ]]

local function handleAction(actionName, inputState, inputObject)
	local isBegin = (inputState == Enum.UserInputState.Begin)

	if actionName == "ShootAction" then
		if isBegin then startFiring() else stopFiring() end
	elseif actionName == "ADSAction" then
		if DeviceService.IsMobile() then
			if isBegin then isAiming = not isAiming end
		else
			isAiming = isBegin
		end
	elseif actionName == "ReloadAction" then
		if isBegin and not isReloading and equippedWeapon then
			local data = weaponData[equippedWeapon]
			local weaponInfo = Weapons[equippedWeapon]

			if data.StoredAmmo > 0 and data.Ammo < weaponInfo.Ammo then
				stopFiring(); isAiming = false; isReloading = true
				ammoLabel.Text = "RELOADING..."
				SFX.PlaySoundEffect(SFXFolder.Reload, nil, 1 / weaponInfo.ReloadWaitTime)
				GunMechanicsRemotes.Reload:FireServer(equippedWeapon)
			end
		end
	end
	return Enum.ContextActionResult.Pass
end

function module.Init()
	pcall(function() SG:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false) end)
	gui.Enabled = true

	player.CharacterAdded:Connect(characterAdded)
	if player.Character then characterAdded(player.Character) end
	
	-- Bind Unified Action Handling
	CAS:BindAction("ShootAction", handleAction, true, Enum.UserInputType.MouseButton1)
	CAS:BindAction("ADSAction", handleAction, true, Enum.UserInputType.MouseButton2)
	CAS:BindAction("ReloadAction", handleAction, true, Enum.KeyCode.R)

	-- HUD Shake Logic (RenderStepped)
	RunS.RenderStepped:Connect(function(dt)
		if ammoShake > 0.1 then
			local offset = math.sin(os.clock() * 45) * ammoShake
			ammoLabel.Position = originalAmmoPos + UDim2.fromOffset(offset, 0)
			ammoShake = math.lerp(ammoShake, 0, dt * 15)
		else
			ammoLabel.Position = originalAmmoPos
		end
	end)
end

-- [[ NETWORKING ]]

-- Handles replication of tracers and effects from other players
GunMechanicsRemotes.ReplicateEffectsClient.OnClientEvent:Connect(function(shotPlayer, hitPart, endPos)
	local char = shotPlayer.Character; if not char then return end
	local tool = char:FindFirstChildOfClass("Tool"); if not tool then return end
	local muzzle = tool:FindFirstChild("Muzzle"); if not muzzle then return end
	
	SFX.PlaySoundEffect(SFXFolder.Gunshot, muzzle)
	createBeam(muzzle, endPos)
	
	if hitPart and hitPart.Parent then
		local char = hitPart.Parent
		local hum = char:FindFirstChild("Humanoid") or char.Parent:FindFirstChild("Humanoid")
		if hum then bloodSplatter(endPos) else impactEffect(endPos) end
		SFX.PlaySoundEffect(SFXFolder.Hit, hitPart)
	end
end)

-- Initial data sync from Server
GunMechanicsRemotes.LoadWeaponDataClient.OnClientEvent:Connect(function(data)
	weaponData = data
	for weaponName, d in weaponData do newSlot(d.Slot, weaponName) end
end)

return module
