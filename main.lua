local module = {}

-- ============================================================
--  CONFIGURATION
-- ============================================================

local KEY_TO_SLOT = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.Zero] = 0,
}

-- ============================================================
--  SERVICES
-- ============================================================

local Plrs = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")

-- ============================================================
--  FOLDERS
-- ============================================================

local AssetsFolder = RS:WaitForChild("Assets")
local UIFolder = AssetsFolder:WaitForChild("UI")
local VFXFolder = AssetsFolder:WaitForChild("VFX")
local SFXFolder = AssetsFolder:WaitForChild("SFX")

local SharedFolder = RS:WaitForChild("Shared")
local ConfigFolder = SharedFolder:WaitForChild("Config")
local UtilsFolder = SharedFolder:WaitForChild("Utils")
local ClientModulesFolder = SharedFolder:WaitForChild("ClientModules")

local RemotesFolder = RS:WaitForChild("Remotes")
local GunMechanicsRemotes = RemotesFolder:WaitForChild("GunMechanics")

-- ============================================================
--  MODULES
-- ============================================================

local Weapons = require(ConfigFolder:WaitForChild("Weapons"))

local DebugService = require(UtilsFolder:WaitForChild("DebugService"))
local DeviceService = require(UtilsFolder:WaitForChild("DeviceService"))
local UIService = require(UtilsFolder:WaitForChild("UIService"))

local SFX = require(ClientModulesFolder:WaitForChild("SFXHandler"))
local WeaponHUD = require(ClientModulesFolder:WaitForChild("WeaponHUDHandler"))
local Camera = require(ClientModulesFolder:WaitForChild("CameraHandler"))
local Crosshair = require(ClientModulesFolder:WaitForChild("CrosshairHandler"))
local PlayerStatsHandler = require(ClientModulesFolder:WaitForChild("PlayerStatsHandler"))

-- ============================================================
--  CONSTANTS
-- ============================================================

local player = Plrs.LocalPlayer

local camera = workspace.CurrentCamera

-- ============================================================
--  VARIABLES
-- ============================================================

local weaponData = {}

local lastShot = 0
local damageIndicators = {}

-- Object pooling to reuse particle parts for better performance
-- This prevents lag from creating/destroying hundreds of parts during combat
local particlePartPool = {}
local activeParticleParts = {}

-- ============================================================
--  FUNCTIONS
-- ============================================================

local function isAlive()
	local char = player.Character; if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid"); if not hum then return end
	return hum.Health > 0
end

local function returnPartToPool(part)
	-- Clean up children before returning to pool
	-- Prevents memory leaks and ensures parts are fresh when reused
	for _, child in part:GetChildren() do
		if child:IsA("Attachment") or child:IsA("BillboardGui") then
			child:Destroy()
		end
	end
	
	part.Parent = nil
	activeParticleParts[part] = nil
	table.insert(particlePartPool, part)
end

local function getPartFromPool()
	if #particlePartPool > 0 then
		return table.remove(particlePartPool)
	else
		-- Create new part if pool is empty
		local part = Instance.new("Part")
		part.Size = Vector3.new(0, 0, 0)
		part.Transparency = 1
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Anchored = true
		return part
	end
end

local function createTempParticlePart(lifetime, pos, nonVolatile)
	local part = getPartFromPool()
	part.Position = pos
	part.Parent = workspace
	
	-- nonVolatile parts are managed manually (like damage indicators)
	if not nonVolatile then
		local cleanupTask = task.delay(lifetime, function()
			if part.Parent then
				returnPartToPool(part)
			end
		end)
		activeParticleParts[part] = cleanupTask
	end

	return part
end

local function pulseVisual(guiObject)
	local popTween = TS:Create(guiObject, TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = UDim2.fromScale(3, 1.5)})
	local settleTween = TS:Create(guiObject, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {Size = UDim2.fromScale(2, 1)})

	popTween:Play()
	popTween.Completed:Once(function()
		settleTween:Play()
	end)
end

local function damageIndicator(pos, damage, hitPart)
    local hitChar = hitPart.Parent
    local indicatorData = damageIndicators[hitChar]
    local valTi = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

    -- Nested function to handle fading out the damage label

    local function startFadeOut(data)
        if not data.DamageLabel or not data.DamageLabel.Parent then return end
        
        local fadeTi = TweenInfo.new(1, Enum.EasingStyle.Cubic, Enum.EasingDirection.In)
        
        TS:Create(data.DamageLabel, fadeTi, {Position = UDim2.fromScale(0.5, -0.5)}):Play()
        
        UIService.FadeGuiObject({
            Object = data.DamageLabel,
            TweenInfo = fadeTi,
        })

        task.delay(1, function()
            if data.Part then returnPartToPool(data.Part) end
        end)
        damageIndicators[hitChar] = nil
    end

    -- Update existing indicator if already showing damage for this character
    -- This stacks damage numbers instead of creating multiple overlapping labels
    if indicatorData and indicatorData.DamageLabel.Parent then
        indicatorData.Part.Position = pos
        indicatorData.Damage += damage

        if indicatorData.TimeEndedTask then 
            task.cancel(indicatorData.TimeEndedTask) 
        end

        pulseVisual(indicatorData.DamageLabel)
        TS:Create(indicatorData.DisplayValue, valTi, {Value = indicatorData.Damage}):Play()

        indicatorData.TimeEndedTask = task.delay(1, function()
            startFadeOut(indicatorData)
        end)
        
        return
    end
    
    -- Create new damage indicator
    local part = createTempParticlePart(5, pos, true) 
    local billing = UIFolder.DamageIndicator:Clone()
    local label = billing.Damage
    
	billing.Parent = part

    local displayValue = Instance.new("NumberValue")
    displayValue.Value = 0
    displayValue.Parent = label
    
    displayValue:GetPropertyChangedSignal("Value"):Connect(function()
        local currentVal = displayValue.Value
        label.Text = "-"..math.round(currentVal)
        label.TextColor3 = UIService.GetGradientColor(UIFolder.DamageColor, currentVal / 100)
    end)

    label.Position = UDim2.fromScale(0.5, 0.5)
    label.Text = "-0"
    
    pulseVisual(label)
    TS:Create(displayValue, valTi, {Value = damage}):Play()

    local newData = {
        Part = part,
        DamageLabel = label,
        HitChar = hitChar,
        Damage = damage,
        DisplayValue = displayValue,
    }
    
    damageIndicators[hitChar] = newData
    newData.TimeEndedTask = task.delay(1, function()
        startFadeOut(newData)
    end)
end

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
		if particle:IsA("ParticleEmitter") then particle:Emit(particle:GetAttribute("EmitAmount") or 3) end
	end
end

local function createBeam(startMuzzle, endPos)
	if not startMuzzle then return end

	local distance = (startMuzzle.WorldPosition - endPos).Magnitude
	if distance < 1 then return end

	local part = createTempParticlePart(0.2, endPos)
	local att0 = Instance.new("Attachment", part)
	local att1 = Instance.new("Attachment", part)
	att0.WorldPosition = startMuzzle.WorldPosition
	att1.WorldPosition = endPos

	local beam = VFXFolder.BulletBeam:Clone()
	beam.Attachment0 = att0
	beam.Attachment1 = att1

	beam.Parent = part

	TS:Create(beam, TweenInfo.new(0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Width0 = 0, 
		Width1 = 0,
		TextureSpeed = 5
	}):Play()
end

local function shoot()
	if not isAlive() then return end
	
	local equippedWeapon = WeaponHUD.EquippedWeapon
	
	if not equippedWeapon or Camera.IsReloading then return end
	
	local weaponInfo = Weapons[equippedWeapon]; if not weaponInfo then return end
	local data = weaponData[equippedWeapon]; if not data then return end
	
	if data.Ammo <= 0 then WeaponHUD.NoAmmoVisuals(); return end
	data.Ammo -= weaponInfo.Bullets

	SFX.PlaySoundEffect(SFXFolder.Gunshot)
	WeaponHUD.UpdateAmmoCount(data)

	-- Reset spread if player hasn't shot in a while
	-- Rewards controlled bursts instead of spray and pray
	if tick() - lastShot > weaponInfo.FireRate * 2 then  Camera.CurrentSpread = weaponInfo.MinSpread
	else  Camera.CurrentSpread = math.clamp(Camera.CurrentSpread + weaponInfo.SpreadIncrement, weaponInfo.MinSpread, weaponInfo.MaxSpread) end

	lastShot = tick()

	-- Cast ray from center of screen
	local viewportRay = camera:ViewportPointToRay(camera.ViewportSize.X/2, camera.ViewportSize.Y/2)

	local randomSpread = Vector3.new(
		(math.random() - 0.5) * Camera.CurrentSpread,
		(math.random() - 0.5) * Camera.CurrentSpread,
		(math.random() - 0.5) * Camera.CurrentSpread
	)

	local shootDir = (viewportRay.Direction + randomSpread).Unit

	-- Setup raycast to ignore player and accessories
	-- Prevents shooting yourself or having shots blocked by cosmetics
	local rayParams = RaycastParams.new()
	local blacklist = {player.Character, Camera.CurrentViewmodel}

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

	local muzzle = Camera.CurrentViewmodel:FindFirstChild("Muzzle", true)
	createBeam(muzzle, endPos)
	Camera.ApplyRecoil(WeaponHUD.EquippedWeapon)

	-- Apply visual effects and check for hits
	if result and result.Instance then
		local char = result.Instance.Parent
		-- Protect newly spawned players from being killed immediately
		if char:GetAttribute("SpawnImmunity") then return end

		local hum = char:FindFirstChild("Humanoid") or char.Parent:FindFirstChild("Humanoid")
		if hum then bloodSplatter(endPos) else impactEffect(endPos) end
	end

	GunMechanicsRemotes.Shoot:FireServer(equippedWeapon, endPos, result and result.Instance)
end

local function startFiring()
	local equippedWeapon = WeaponHUD.EquippedWeapon
	
	if Camera.IsFiring or not equippedWeapon then return end
	local weaponInfo = Weapons[equippedWeapon]

	-- Automatic weapons fire continuously
	if weaponInfo.Auto then
		Camera.IsFiring = true
		task.spawn(function()
			while Camera.IsFiring and equippedWeapon do
				if tick() - lastShot >= weaponInfo.FireRate then shoot() end
				task.wait()
			end
		end)
	else
		-- Semi-automatic weapons fire once per click
		if tick() - lastShot >= weaponInfo.FireRate then shoot() end
	end
end

local function stopFiring()
	Camera.IsFiring = false
	-- Reset spread for next engagement
	Camera.CurrentSpread = 0
end

local function handleAction(actionName, inputState)
	if not isAlive() then return end
	
	local isBegin = (inputState == Enum.UserInputState.Begin)

	if actionName == "ShootAction" then
		if isBegin then startFiring() else stopFiring() end

	elseif actionName == "ADSAction" then
		if DeviceService.IsMobile() then
			if isBegin then Camera.IsAiming = not Camera.IsAiming end
		else
			Camera.IsAiming = isBegin
		end

		if not Camera.IsAiming then Crosshair.ToggleScope(false) end

	elseif actionName == "ReloadAction" then
		local equippedWeapon = WeaponHUD.EquippedWeapon
		local weaponInfo = Weapons[equippedWeapon]; if not weaponInfo then return end

		if isBegin and not Camera.IsReloading and equippedWeapon then
			local data = weaponData[equippedWeapon]; if not data then return end

			if data.StoredAmmo > 0 and data.Ammo < weaponInfo.Ammo then
				stopFiring()

				Camera.IsAiming = false

				Camera.IsReloading = true

				WeaponHUD.ReloadingUI()
				SFX.PlaySoundEffect(SFXFolder.Reload, nil, 1 / weaponInfo.ReloadWaitTime)

				GunMechanicsRemotes.Reload:FireServer(equippedWeapon)
			end
		end

		if not Camera.IsAiming then Crosshair.ToggleScope(false) end

	elseif actionName == "SprintAction" then
		if DeviceService.IsMobile() then
			if isBegin then Camera.IsSprinting = not Camera.IsSprinting end
		else
			Camera.IsSprinting = isBegin
		end

		if not Camera.CurrentViewmodel then PlayerStatsHandler.ChangeWalkSpeed(Camera.IsSprinting and PlayerStatsHandler.SPRINT_SPEED or PlayerStatsHandler.WALK_SPEED) end
	end

	-- Pass allows other input handlers to also process this action if needed
	return Enum.ContextActionResult.Pass
end

local function toggleWeapon(weaponName)
	local char = player.Character; if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local backpack = player:WaitForChild("Backpack")

	Camera.IsReloading = false

	local currentHeldTool = char:FindFirstChildOfClass("Tool")

	-- Unequip if trying to toggle the same weapon
	if currentHeldTool and currentHeldTool.Name == weaponName then
		currentHeldTool.Parent = backpack
		WeaponHUD.EquippedWeapon = nil

		Camera.ClearViewmodel()
		WeaponHUD.UpdateSlotVisuals()
		WeaponHUD.ToggleMobileGunButtons(false)

		Crosshair.ToggleCrosshair(false)
		WeaponHUD.HideAmmoUI()

		return
	end

	-- Equip the new weapon
	local newTool = backpack:FindFirstChild(weaponName) or char:FindFirstChild(weaponName)

	if newTool and newTool:IsA("Tool") then
		WeaponHUD.UpdateAmmoCount(weaponData[weaponName])
		WeaponHUD.ToggleMobileGunButtons(true)

		SFX.PlaySoundEffect(SFXFolder.Equip)

		-- Must clear old viewmodel before equipping to prevent conflicts
		Camera.ClearViewmodel() 
		hum:UnequipTools()

		Crosshair.ToggleCrosshair(true)
		WeaponHUD.EquippedWeapon = weaponName

		newTool.Parent = char
		Camera.SetViewmodel(weaponName)

		-- Hide world model for local player
		-- Others see the gun on your character, but you only see your viewmodel
		for _, part in newTool:GetDescendants() do
			if part:IsA("BasePart") then 
				part.LocalTransparencyModifier = 1
			end
		end
	else
		DebugService.DebugWarn("Weapon " .. weaponName .. " not found in Backpack or Character!", script)
	end

	WeaponHUD.UpdateSlotVisuals()
end

local function characterAdded(char)
	PlayerStatsHandler.ChangeWalkSpeed(PlayerStatsHandler.WALK_SPEED)

	WeaponHUD.CharacterAdded()
	Camera.SetPerspective(true)

	camera.FieldOfView = Camera.BASE_FOV

	local hum = char:WaitForChild("Humanoid")
	hum.Died:Connect(function()
		Camera.ClearViewmodel()
		Camera.SetPerspective(false)
		
		Camera.IsFiring = false
		Camera.IsReloading = false
		Camera.IsAiming = false
		Camera.IsSprinting = false

		Crosshair.ToggleScope(false)
		Crosshair.ToggleCrosshair(false)
		
		WeaponHUD.PlayedDied()
	end)
end

-- ============================================================
--  MODULE FUNCTIONS
-- ============================================================

function module.Init()
	player.CharacterAdded:Connect(characterAdded)
	if player.Character then characterAdded(player.Character) end
	
	WeaponHUD.BindMobileButtons(handleAction)
end

-- ============================================================
--  REMOTES
-- ============================================================

GunMechanicsRemotes.LoadWeaponDataClient.OnClientEvent:Connect(function(data)
	weaponData = data

	-- Create UI slots for each weapon
	-- Dynamically generates inventory based on what player owns
	for weaponName, d in weaponData do
		local slot = WeaponHUD.NewSlot(d.Slot, weaponName)
		
		local button = slot:FindFirstChild("Button")
		button.Activated:Connect(function()
			stopFiring()
			toggleWeapon(weaponName)
		end)
	end
end)

GunMechanicsRemotes.UpdateAmmoClient.OnClientEvent:Connect(function(weaponName, amount)
	weaponData[weaponName].Ammo = amount
	if weaponName == WeaponHUD.EquippedWeapon then WeaponHUD.UpdateAmmoCount(weaponData[weaponName]) end
end)

GunMechanicsRemotes.UpdateStoredAmmoClient.OnClientEvent:Connect(function(weaponName, amount)
	weaponData[weaponName].StoredAmmo = amount
	if weaponName == WeaponHUD.EquippedWeapon and not Camera.IsFiring then WeaponHUD.UpdateAmmoCount(weaponData[weaponName]) end
end)

-- Replicate gun effects from other players
-- Shows visual/audio feedback when others shoot, making gameplay feel responsive
GunMechanicsRemotes.ReplicateEffectsClient.OnClientEvent:Connect(function(shotPlayer, hitPart, endPos)
	local char = shotPlayer.Character; if not char then return end
	local tool = char:FindFirstChildOfClass("Tool"); if not tool then return end
	local muzzle = tool:FindFirstChild("Muzzle"); if not muzzle then return end

	SFX.PlaySoundEffect(SFXFolder.Gunshot, muzzle)
	createBeam(muzzle, endPos)

	if hitPart and hitPart.Parent then
		char = hitPart.Parent
		local hum = char:FindFirstChild("Humanoid") or char.Parent:FindFirstChild("Humanoid")

		if hum then bloodSplatter(endPos) else impactEffect(endPos) end
		SFX.PlaySoundEffect(SFXFolder.Hit, hitPart)
	end
end)

GunMechanicsRemotes.Shoot.OnClientEvent:Connect(function(hitPart, damage, playerDied, endPos)
	Crosshair.FlashHitMarker()
	damageIndicator(endPos, damage, hitPart)
	if playerDied then SFX.PlaySoundEffect(if hitPart.Name == "Head" then SFXFolder.Headshot else SFXFolder.Killed) end

	SFX.PlaySoundEffect(SFXFolder.Hit, hitPart)
end)

-- ============================================================
--  CONNECTIONS
-- ============================================================

UIS.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		handleAction("ShootAction", Enum.UserInputState.Begin)
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		handleAction("ADSAction", Enum.UserInputState.Begin)
	elseif input.KeyCode == Enum.KeyCode.R then
		handleAction("ReloadAction", Enum.UserInputState.Begin)
	elseif input.KeyCode == Enum.KeyCode.LeftShift then
		handleAction("SprintAction", Enum.UserInputState.Begin)
	end

	local slot = KEY_TO_SLOT[input.KeyCode]
	if slot and WeaponHUD.Slots[slot] and isAlive() then
		stopFiring()
		toggleWeapon(WeaponHUD.Slots[slot])
	end
end)

UIS.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		handleAction("ShootAction", Enum.UserInputState.End)
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		handleAction("ADSAction", Enum.UserInputState.End)
	elseif input.KeyCode == Enum.KeyCode.LeftShift then
		handleAction("SprintAction", Enum.UserInputState.End)
	end
end)

player:GetAttributeChangedSignal("Reloading"):Connect(function()
	if not player:GetAttribute("Reloading") then SFX.StopSoundEffect(SFXFolder.Reload) end
end)

return module
