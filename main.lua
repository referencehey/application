--// made by referncehey

--// VIDEO EXAMPLE LINK: https://drive.google.com/file/d/1Ozu-wyZjwD6uYKHXEqRPPLxR3Wj-m8mD/view?usp=sharing

local module = {
	Inventory = nil,
	Equipped = nil,
}

-- services
local Plrs = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TS = game:GetService("TweenService")

-- folders
local remotesF = RS:WaitForChild("Remotes")
local dataRelatedR = remotesF:WaitForChild("DataRelated")

-- modules
local ClientFunctions = require(script.Parent.Parent.ClientFunctions)

-- constants
local player = Plrs.LocalPlayer
local pGui = player:WaitForChild("PlayerGui")

local camera = workspace.CurrentCamera

-- directories
local menusGui = pGui:WaitForChild("MenusUI")
local inventoryFrame = menusGui.Menus.Inventory
local container = inventoryFrame.Container
local filterOptionsFrame = container.FilterOptions
local itemsFrame = container.Items
local searchContainer = container.SearchContainer
local filterButton = searchContainer.Filter
local searchBar = searchContainer.SearchBar

local exitButton = inventoryFrame.Exit

-- variables
local equipDB = false
local filterToggled = false
local filtersApplied = {}

local origThickness = itemsFrame.ScrollBarThickness
local origPaddingScale = itemsFrame.UIGridLayout.CellPadding.X.Scale
local origSizeScale = itemsFrame.UIGridLayout.CellSize.X.Scale

-- functions
local function ToggleEquipped(catergory, item)
	if not catergory or not item or equipDB then return end
	
	if module.Equipped then if module.Equipped[catergory] then if item == module.Equipped[catergory] then warn("Item '"..item.."' is already equipped!") return end end end
	
	equipDB = true
	dataRelatedR.EquipCosmetic:FireServer(catergory, item)
end

local function Adjust()
	if itemsFrame.AbsoluteSize.X == 0 then return end
	itemsFrame.ScrollBarThickness = origThickness * (camera.ViewportSize.X / 1920)

	local finalSize = math.round(itemsFrame.AbsoluteSize.X * origPaddingScale)
	itemsFrame.UIGridLayout.CellPadding = UDim2.fromOffset(finalSize, finalSize)

	local finalSize = math.round(itemsFrame.AbsoluteSize.X * origSizeScale)
	itemsFrame.UIGridLayout.CellSize = UDim2.fromOffset(finalSize, finalSize)
end

local function FilterItems()
	local searchText = searchBar.Text:lower()
	local usedSearch = searchText ~= ""
	local usedFilters = #filtersApplied > 0
	
	for _, item in itemsFrame:GetChildren() do
		if not item:IsA("ImageButton") then continue end
		
		local itemName = item.Name:lower()
		local visible = true

		-- search check
		if usedSearch and not itemName:find(searchText) then visible = false end
		
		-- filter check
		if visible and usedFilters then
			local passedCheck = false
			
			for _, filter in filtersApplied do
				if item:GetAttribute("Catergory") ~= filter then continue end
				passedCheck = true
				break
			end
			
			visible = passedCheck
		end
		
		item.Visible = visible
	end
end

local function ToggleFilter(filterObj)
	local found = table.find(filtersApplied, filterObj.Name)
	if found then table.remove(filtersApplied, found)
	else table.insert(filtersApplied, filterObj.Name) end
	
	filterObj.ImageColor3 = if found then Color3.fromRGB(255, 255, 255) else Color3.fromRGB(255, 255, 0)
	FilterItems()
end

-- module functions
function module:Init()
	Adjust()
	
	for _, button in filterOptionsFrame:GetChildren() do
		if not button:IsA("ImageButton") then continue end
		button.MouseButton1Click:Connect(function() ToggleFilter(button) end)
	end
end

-- connections
camera:GetPropertyChangedSignal("ViewportSize"):Connect(Adjust)

filterButton.MouseButton1Click:Connect(function()
	TS:Create(filterButton.Icon, TweenInfo.new(0.3), {Rotation = if filterToggled then 0 else 180}):Play()
	
	if filterToggled then
		filterToggled = not filterToggled
		
		TS:Create(filterOptionsFrame, TweenInfo.new(0.3), {Size = UDim2.fromScale(0.2, 0)}):Play()
		task.wait(0.3)
		filterOptionsFrame.Visible = false
	else
		filterToggled = not filterToggled
		
		filterOptionsFrame.Size = UDim2.fromScale(0.2, 0)
		filterOptionsFrame.Visible = true
		TS:Create(filterOptionsFrame, TweenInfo.new(0.3), {Size = UDim2.fromScale(0.2, 0.2)}):Play()
	end
end)

searchBar:GetPropertyChangedSignal("Text"):Connect(FilterItems)

inventoryFrame:GetPropertyChangedSignal("Visible"):Connect(function()
	filterToggled = false
	filterOptionsFrame.Visible = false
	filterButton.Icon.Rotation = 0
end)

-- events
dataRelatedR.LoadInventory.OnClientEvent:Connect(function(data)
	module.Equipped = data.Equipped
	module.Inventory = data.Inventory

	for catergory, items in module.Inventory do
		for name, amount in items do
			task.spawn(function()
				local clone = ClientFunctions.CreateItem({
					Amount = amount,
					Catergory = catergory,
					ItemName = name,
					Parent = itemsFrame,
					Equipped = name == module.Equipped[catergory]
				})
				if not clone then return end
				
				clone.MouseButton1Click:Connect(function() ToggleEquipped(catergory, name) end)
			end)
		end
	end
end)

dataRelatedR.UpdateInventory.OnClientEvent:Connect(function(data)
	local oldItems = module.Inventory
	module.Inventory = data.Inventory
	
	for catergory, newItems in module.Inventory do
		-- check for new items/items added
		for name, amount in newItems do
			if oldItems[catergory][name] then
				-- existed beforehand
				local itemObj = itemsFrame:FindFirstChild(name)
				if not itemObj then
					warn("Item '"..name.."' does not exist!")
					
					-- new item
					task.spawn(function()
						local clone = ClientFunctions.CreateItem({
							Amount = amount,
							Catergory = catergory,
							ItemName = name,
							Parent = itemsFrame,
						})
						if not clone then return end
						
						clone.MouseButton1Click:Connect(function() ToggleEquipped(catergory, name) end)
					end)
				else
					itemObj.InfoFrame.Amount.Text = if amount > 99 then "x99+" else "x"..amount
				end
			else
				-- new item
				task.spawn(function()
					local clone = ClientFunctions.CreateItem({
						Amount = amount,
						Catergory = catergory,
						ItemName = name,
						Parent = itemsFrame,
					})
					if not clone then return end
					
					clone.MouseButton1Click:Connect(function() ToggleEquipped(catergory, name) end)
				end)
			end
		end

		-- check for items removed
		for name, _ in oldItems[catergory] do
			if newItems[name] then continue end

			local itemObj = itemsFrame:FindFirstChild(name)
			if not itemObj then warn("Item '"..name.."' does not exist!") continue end
			itemObj:Destroy()
		end

		-- check if equipped item changed
		if data.Equipped[catergory] == module.Equipped[catergory] then continue end
		ToggleEquipped(catergory, data.Equipped[catergory])
	end
end)

dataRelatedR.EquipCosmetic.OnClientEvent:Connect(function(catergory, item)
	equipDB = false
	
	if not catergory or not item then return end
	if not module.Inventory or not module.Equipped then return end
	
	-- check if item object exists
	local itemObj = itemsFrame:FindFirstChild(item)
	if not itemObj then warn("Item object '"..item.."' is not found in catergory '"..catergory.."' in "..player.Name.."'s inventory!") return end

	itemObj.Equipped.Enabled = true

	task.spawn(function()
		local prevObj = itemsFrame:FindFirstChild(module.Equipped[catergory])
		if not prevObj then warn("Item object '"..module.Equipped[catergory].."' is not found in catergory '"..catergory.."' in "..player.Name.."'s inventory!") return end

		prevObj.Equipped.Enabled = false
	end)

	module.Equipped[catergory] = item
end)

return module
