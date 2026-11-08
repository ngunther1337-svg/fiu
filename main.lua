-- =========================================================================
-- Fix It Up Garage Manager — Delta Android
-- =========================================================================
local Players             = game:GetService("Players")
local VirtualInputManager = game:GetService("VirtualInputManager")
local Gui                 = game:GetService("GuiService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local Workspace           = game:GetService("Workspace")
local RunService          = game:GetService("RunService")
local UserInputService    = game:GetService("UserInputService")

local Player        = Players.LocalPlayer
local VehFolder     = Workspace:WaitForChild("Vehicles")
local GarageFolder  = Player:WaitForChild("PlayerData"):WaitForChild("Garage")
local MoveableParts = Workspace:WaitForChild("MoveableParts")

local camera   = Workspace.CurrentCamera
-- Trust TouchEnabled over MouseEnabled on Delta mobile
local isMobile = UserInputService.TouchEnabled

warn(string.format("[Delta Debug] TouchEnabled=%s MouseEnabled=%s isMobile=%s",
    tostring(UserInputService.TouchEnabled),
    tostring(UserInputService.MouseEnabled),
    tostring(isMobile)))

-- =========================================================================
-- Tunables
-- =========================================================================
local REPAIR_WAIT        = 18
local REMOVE_DELAY       = 0.15
local POST_REMOVE_WAIT   = 2
local WARP_SETTLE        = 1.5
local SAFE_OFFSET        = 15
local FIND_PART_TIMEOUT  = 15
local REINSTALL_TIMEOUT  = 10
local SELL_TIMEOUT       = 12

local TOUCH_MAX_ATTEMPTS = 30
local TOUCH_SWIPE_RADIUS = 12
local TOUCH_GESTURE_DUR  = 0.5
local TOUCH_GAP          = 0.15
local PC_HOLD_MAX        = 20

local REPAIR_BASE_POS = CFrame.new(-1076, 5, -414)
local PAINT_POS = CFrame.new(
    -990.619568, 4.53032351, -387.379364,
    0.350393713, -8.45001722e-08, -0.936602473,
    -4.68328265e-09, 1, -9.19719554e-08,
    0.936602473, 3.66127715e-08, 0.350393713
)
local SELL_POS = CFrame.new(-1915, 4, -785)

-- Load WindUI with pcall so failure is visible in console
local WindUI
do
    local ok, result = pcall(function()
        return loadstring(game:HttpGet(
            "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"
        ))()
    end)
    if not ok or not result then
        warn("[FATAL] WindUI failed to load: " .. tostring(result))
        return
    end
    WindUI = result
end

-- =========================================================================
-- Utilities
-- =========================================================================
local function notify(content, icon, duration)
    WindUI:Notify({
        Title    = "Garage Manager",
        Content  = content,
        Duration = duration or 3,
        Icon     = icon or "info",
    })
end

local function getRoot()
    local char = Player.Character
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function waitForRoot(timeout)
    timeout = timeout or 20
    local elapsed = 0
    while elapsed < timeout do
        local char = Player.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if root and hum and hum.Health > 0 then return root end
        task.wait(0.25)
        elapsed = elapsed + 0.25
    end
    return nil
end

local function teleportTo(cframe)
    local root = getRoot()
    if not root then return false end
    root.CFrame = cframe
    return true
end

local function findPlayerVehicle()
    for _, v in pairs(VehFolder:GetChildren()) do
        if v:GetAttribute("Owner") == Player.Name then
            return v
        end
    end
    return nil
end

local function pressEnter(btn)
    if not btn or not btn.Parent or not btn:IsDescendantOf(game) then
        return false
    end
    local ok = pcall(function()
        Gui.SelectedCoreObject = btn
    end)
    if not ok then return false end
    VirtualInputManager:SendKeyEvent(true,  Enum.KeyCode.Return, false, game)
    task.wait(0.4)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Return, false, game)
    task.wait(0.1)
    Gui.SelectedCoreObject = nil
    return true
end

local function findConfirmButton()
    local pg     = Player:FindFirstChild("PlayerGui")
    local hud    = pg and pg:FindFirstChild("HUD")
    local frames = hud and hud:FindFirstChild("Frames")
    local conf   = frames and frames:FindFirstChild("Confirmation")
    local btn    = conf and conf:FindFirstChild("Confirm")
    return btn
end

local function waitForConfirmButton(timeout)
    timeout = timeout or 3
    local elapsed = 0
    while elapsed < timeout do
        local btn = findConfirmButton()
        if btn and btn:IsDescendantOf(game) then return btn end
        task.wait(0.1)
        elapsed = elapsed + 0.1
    end
    return nil
end

local function worldToScreen(worldPos)
    if not camera then return nil end
    local screenPos, onScreen = camera:WorldToViewportPoint(worldPos)
    if onScreen then
        return Vector2.new(screenPos.X, screenPos.Y)
    end
    return nil
end

local function waitForPartModel(partName, timeout, vehicleName)
    timeout = timeout or FIND_PART_TIMEOUT
    local elapsed = 0
    local POLL    = 0.3
    while elapsed < timeout do
        if vehicleName and not VehFolder:FindFirstChild(vehicleName) then
            warn(string.format("[waitForPartModel] Vehicle '%s' gone — abort", vehicleName))
            return nil
        end
        for _, child in pairs(MoveableParts:GetChildren()) do
            if child.Name == partName and child:GetAttribute("Owner") == Player.Name then
                return child
            end
        end
        task.wait(POLL)
        elapsed = elapsed + POLL
    end
    warn(string.format("[waitForPartModel] Timed out on '%s' (%ds)", partName, timeout))
    return nil
end

local function storeVehicle(vehName)
    local data = GarageFolder:FindFirstChild(vehName)
    if not data then return end
    pcall(function()
        ReplicatedStorage.Events.Vehicles.RemoteStore:InvokeServer(data)
    end)
    task.wait(1.5)
end

local function spawnVehicle(vehName, spawnCFrame)
    local data = GarageFolder:FindFirstChild(vehName) or GarageFolder:WaitForChild(vehName, 5)
    if not data then
        warn("[spawnVehicle] No garage data for: " .. vehName)
        return false
    end
    local ok = pcall(function()
        ReplicatedStorage.Events.Vehicles.RemoteLoad:InvokeServer(data, spawnCFrame)
    end)
    task.wait(2)
    return ok
end

local function killPlayer()
    local char = Player.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if hum then hum.Health = 0 end
end

local function leaveGarageIfInside()
    if #GarageFolder:GetChildren() == 0 then return end
    local garages = Workspace:FindFirstChild("Garages")
    local default = garages and garages:FindFirstChild("Default")
    local leave   = default and default:FindFirstChild("Leave")
    local attach  = leave and leave:FindFirstChild("Attachment")
    local prompt  = attach and attach:FindFirstChild("LeavePrompt")
    if prompt then
        pcall(fireproximityprompt, prompt)
        task.wait(1.5)
    else
        warn("[leaveGarageIfInside] LeavePrompt not found")
    end
end

local function findNearestPrompt(modelFolder)
    local root = getRoot()
    if not root then return nil end
    local nearest, nearestDist = nil, math.huge
    for _, child in pairs(modelFolder:GetChildren()) do
        local promptPart = child:FindFirstChild("Prompt")
        if promptPart then
            local pp = promptPart:FindFirstChildWhichIsA("ProximityPrompt")
            if pp then
                local ok, pos = pcall(function() return child:GetPivot().Position end)
                if not ok then
                    local bp = child:FindFirstChildWhichIsA("BasePart")
                    if bp then ok = true; pos = bp.Position end
                end
                if ok then
                    local dist = (pos - root.Position).Magnitude
                    if dist < nearestDist then
                        nearestDist = dist
                        nearest     = pp
                    end
                end
            end
        end
    end
    return nearest
end

-- =========================================================================
-- Touch / Mouse repair input (Delta-safe)
-- =========================================================================
local touchSupported = true

local function simulateTouchSwipe(screenPos, radius, duration, touchId)
    if not touchSupported then return false end
    radius   = radius   or TOUCH_SWIPE_RADIUS
    duration = duration or TOUCH_GESTURE_DUR
    touchId  = touchId  or 1

    local ok = pcall(function()
        VirtualInputManager:SendTouchEvent(touchId, 0, screenPos.X, screenPos.Y)
    end)
    if not ok then
        touchSupported = false
        warn("[Delta] SendTouchEvent failed — falling back to ClickDetector")
        return false
    end

    task.wait(0.05)
    local steps = 6
    for i = 1, steps do
        local angle = (i / steps) * math.pi * 2
        local dx = math.cos(angle) * radius
        local dy = math.sin(angle) * radius
        pcall(function()
            VirtualInputManager:SendTouchEvent(touchId, 1, screenPos.X + dx, screenPos.Y + dy)
        end)
        task.wait(duration / steps)
    end
    pcall(function()
        VirtualInputManager:SendTouchEvent(touchId, 2, screenPos.X, screenPos.Y)
    end)
    return true
end

local function simulateMouseHold(screenPos, maxHold)
    maxHold = maxHold or PC_HOLD_MAX
    VirtualInputManager:SendMouseButtonEvent(screenPos.X, screenPos.Y, 0, true, game, 1)
    local elapsed = 0
    while elapsed < maxHold do
        task.wait(0.25)
        elapsed = elapsed + 0.25
    end
    VirtualInputManager:SendMouseButtonEvent(screenPos.X, screenPos.Y, 0, false, game, 1)
end

local function performRepairInput(targetWorldPos, clickDetector, partModel)
    local screenPos = worldToScreen(targetWorldPos)

    if isMobile then
        if not screenPos then
            pcall(fireclickdetector, clickDetector)
            return
        end
        for _ = 1, TOUCH_MAX_ATTEMPTS do
            if partModel.Parent == nil then break end
            local ok = simulateTouchSwipe(screenPos, TOUCH_SWIPE_RADIUS, TOUCH_GESTURE_DUR, 1)
            if not ok then
                pcall(fireclickdetector, clickDetector)
                return
            end
            task.wait(TOUCH_GAP)
        end
    else
        if not screenPos then
            pcall(fireclickdetector, clickDetector)
            return
        end
        simulateMouseHold(screenPos, PC_HOLD_MAX)
    end
end

-- =========================================================================
-- VehicleScanner
-- =========================================================================
local VehicleScanner = {}
VehicleScanner.__index = VehicleScanner

function VehicleScanner.scan()
    local labels    = {}
    local instances = {}
    for _, veh in pairs(VehFolder:GetChildren()) do
        if veh:GetAttribute("Junkyard") and not veh:GetAttribute("ExclusivePrice") then
            local modelName = veh:GetAttribute("Model")
            if modelName then
                local sc       = veh:GetAttribute("SpawnChance") or "?"
                local priceRaw = veh:GetAttribute("Price")
                local priceStr = ""
                if typeof(priceRaw) == "Vector2" then
                    priceStr = string.format("%d-%d", priceRaw.X, priceRaw.Y)
                else
                    priceStr = tostring(priceRaw or "?")
                end
                local label = string.format("[SC:%s] [$ %s]", tostring(sc), priceStr)
                table.insert(labels, label)
                instances[label] = veh
            end
        end
    end
    return labels, instances
end

-- =========================================================================
-- RepairManager
-- =========================================================================
local RepairManager = {}
RepairManager.__index = RepairManager

function RepairManager.new()
    return setmetatable({}, RepairManager)
end

function RepairManager:_buildMachineSlots(building)
    local slots = {
        GrindingMachine = {},
        PartsWasher     = {},
        BatteryCharger  = {}
    }
    for _, station in pairs(building:GetChildren()) do
        if station.Name:match("^Station%d+$") then
            for _, machine in pairs(station:GetChildren()) do
                if slots[machine.Name] then
                    table.insert(slots[machine.Name], { station = station, model = machine })
                end
            end
        end
    end
    return slots
end

function RepairManager:_resolveMachineIO(machine)
    local detector = machine:FindFirstChild("Detector")
    local cd       = machine:FindFirstChildWhichIsA("ClickDetector", true)
    if not cd then
        local btn = machine:FindFirstChild("Button")
        if btn then cd = btn:FindFirstChildWhichIsA("ClickDetector", true) end
    end
    if not cd then
        local faucet = machine:FindFirstChild("Faucet")
        if faucet then cd = faucet:FindFirstChildWhichIsA("ClickDetector", true) end
    end
    if not detector then
        detector = machine:FindFirstChildWhichIsA("BasePart")
    end
    return detector, cd
end

function RepairManager:_repairSinglePart(partModel, detector, clickDetector, safeBase, index, vehicleName)
    local targetCF = detector.CFrame
    local ok = pcall(function()
        if partModel:IsA("Model") then
            partModel:PivotTo(targetCF)
        else
            partModel.CFrame = targetCF
        end
    end)
    if not ok then return end

    task.wait(WARP_SETTLE)

    local elapsed = 0
    local POLL    = 0.2
    while elapsed < 10 do
        local pos = partModel:IsA("Model") and partModel:GetPivot().Position or partModel.Position
        if (pos - detector.CFrame.Position).Magnitude < 3 then break end
        task.wait(POLL)
        elapsed = elapsed + POLL
    end

    performRepairInput(detector.Position, clickDetector, partModel)
    task.wait(REPAIR_WAIT)

    local safePos = CFrame.new(safeBase + Vector3.new(index * SAFE_OFFSET, 0, 0))
    pcall(function()
        if partModel:IsA("Model") then
            partModel:PivotTo(safePos)
        else
            partModel.CFrame = safePos
        end
    end)
    task.wait(0.3)
end

function RepairManager:_runSlot(slotInfo, partSubList, safeBase, slotIndex, vehicleName)
    local detector, cd = self:_resolveMachineIO(slotInfo.model)
    if not detector or not cd then
        warn(string.format("[RepairManager] Slot %s/%s: no IO", slotInfo.station.Name, slotInfo.model.Name))
        return
    end
    for i, partData in ipairs(partSubList) do
        local model = waitForPartModel(partData.Name, FIND_PART_TIMEOUT, vehicleName)
        if model then
            self:_repairSinglePart(model, detector, cd, safeBase, slotIndex * 100 + i, vehicleName)
        else
            warn(string.format("[RepairManager] Skipping '%s' (timeout)", partData.Name))
        end
    end
end

function RepairManager:_distributeToSlots(slots, queues)
    local assignments = {}
    for machineType, partList in pairs(queues) do
        local machineSlots = slots[machineType]
        if not machineSlots or #machineSlots == 0 then
            warn(string.format("[RepairManager] No slots for '%s'", machineType))
        else
            local slotAssign = {}
            for _, slot in ipairs(machineSlots) do
                local entry = { slot = slot, parts = {} }
                table.insert(slotAssign, entry)
                table.insert(assignments, entry)
            end
            for i, partData in ipairs(partList) do
                local idx = ((i - 1) % #slotAssign) + 1
                table.insert(slotAssign[idx].parts, partData)
            end
        end
    end
    return assignments
end

function RepairManager:removeAllParts(engineBay)
    local vehicle = findPlayerVehicle()
    if not vehicle then return end
    for _, part in pairs(engineBay:GetChildren()) do
        if vehicle:FindFirstChild("PartsEvent") then
            vehicle.PartsEvent:FireServer("RemovePart", part.Name)
            task.wait(REMOVE_DELAY)
        end
    end
    task.wait(POST_REMOVE_WAIT)
end

function RepairManager:reinstallAllParts()
    local playerVehicle = findPlayerVehicle()
    if not playerVehicle then
        warn("[RepairManager] No vehicle for reinstall.")
        return 0
    end
    local partsEvent = playerVehicle:FindFirstChild("PartsEvent")
    if not partsEvent then
        warn("[RepairManager] No PartsEvent on vehicle.")
        return 0
    end
    local count = 0
    for _, v in pairs(MoveableParts:GetChildren()) do
        if v:GetAttribute("Owner") == Player.Name then
            pcall(function() partsEvent:FireServer("ReapplyPart", v) end)
            count = count + 1
            task.wait(0.1)
        end
    end
    return count
end

function RepairManager:reinstallAndVerify(timeout)
    timeout = timeout or REINSTALL_TIMEOUT
    local fired = self:reinstallAllParts()
    if fired == 0 then return true end

    local elapsed = 0
    while elapsed < timeout do
        task.wait(0.5)
        elapsed = elapsed + 0.5
        local remaining = 0
        for _, v in pairs(MoveableParts:GetChildren()) do
            if v:GetAttribute("Owner") == Player.Name then remaining += 1 end
        end
        if remaining == 0 then return true end
    end

    self:reinstallAllParts()
    task.wait(1.5)
    for _, v in pairs(MoveableParts:GetChildren()) do
        if v:GetAttribute("Owner") == Player.Name then return false end
    end
    return true
end

function RepairManager:runFullRepair(vehicle, building)
    local engineBay = vehicle.Body.EngineBay
    local root      = getRoot()
    local safeBase  = root and root.Position or Vector3.new(0, 100, 0)
    local slots     = self:_buildMachineSlots(building)

    self:removeAllParts(engineBay)

    local queues = {
        GrindingMachine = {},
        PartsWasher     = {},
        BatteryCharger  = {}
    }
    local total = 0

    for _, child in pairs(MoveableParts:GetChildren()) do
        if child:GetAttribute("Owner") == Player.Name then
            local rType = child:GetAttribute("RepairMachine")
            if rType and queues[rType] then
                table.insert(queues[rType], { Name = child.Name })
                total = total + 1
            end
        end
    end

    if total == 0 then
        notify("No repairable parts found.", "info")
        return
    end

    local assignments = self:_distributeToSlots(slots, queues)
    local done        = 0
    local total_slots = #assignments
    local vehicleName = vehicle.Name

    for idx, assign in ipairs(assignments) do
        if #assign.parts > 0 then
            task.spawn(function()
                self:_runSlot(assign.slot, assign.parts, safeBase, idx, vehicleName)
                done = done + 1
            end)
        else
            done = done + 1
        end
    end

    while done < total_slots do
        task.wait(0.5)
    end
end

-- =========================================================================
-- FarmSession
-- =========================================================================
local FarmSession = {}
FarmSession.__index = FarmSession

function FarmSession.new(config)
    return setmetatable({
        running        = false,
        sessionId      = 0,
        config         = config,
        repairManager  = RepairManager.new(),
        _cdConn        = nil,
        _targetEndTime = 0,
    }, FarmSession)
end

function FarmSession:_alive()
    return self.running and (_G._farmSessionId == self.sessionId)
end

function FarmSession:stop()
    self.running = false
    _G._farmSessionId = nil
    if self._cdConn then
        self._cdConn:Disconnect()
        self._cdConn = nil
    end
    self._targetEndTime = 0
end

function FarmSession:_phase1_acquire()
    notify("Phase 1: Acquire vehicles (target: 3)", "search")

    while self:_alive() do
        task.wait(0.3)
        local owned = #GarageFolder:GetChildren()
        if owned >= 3 then
            notify(string.format("Acquisition complete. Owned: %d", owned), "check")
            break
        end

        local _, instances = VehicleScanner.scan()
        local targetLabel, targetVeh, bestMatchChance = nil, nil, -1

        for label, veh in pairs(instances) do
            local sc = veh:GetAttribute("SpawnChance") or 0
            if sc <= self.config.maxSpawnChance and sc > bestMatchChance then
                bestMatchChance = sc
                targetLabel     = label
                targetVeh       = veh
            end
        end

        if not targetVeh then
            task.wait(2)
            continue
        end

        local vehName = targetVeh.Name
        if targetVeh:FindFirstChild("Body") and targetVeh.Body:FindFirstChild("Plate") then
            teleportTo(targetVeh.Body.Plate.CFrame)
        end
        task.wait(0.6)

        pcall(function()
            if targetVeh:FindFirstChild("ClickDetector") then
                fireclickdetector(targetVeh.ClickDetector)
            end
        end)
        task.wait(0.6)

        local confirmBtn = waitForConfirmButton(2.5)
        if not confirmBtn then
            warn("[FarmSession] Confirm UI timeout — retrying.")
            task.wait(0.5)
            continue
        end

        local pressElapsed = 0
        repeat
            pressEnter(confirmBtn)
            task.wait(0.3)
            pressElapsed = pressElapsed + 0.3
            local confirm = findConfirmButton()
            if not confirm or not confirm.Visible then break end
        until pressElapsed > 6 or not self:_alive()

        local bought, elapsed = false, 0
        repeat
            task.wait(0.1)
            elapsed = elapsed + 0.1
            if GarageFolder:FindFirstChild(vehName) then bought = true end
        until bought or elapsed > 5 or not self:_alive()

        if bought then
            notify("Purchased: " .. targetLabel, "shopping-cart")
            leaveGarageIfInside()
            teleportTo(REPAIR_BASE_POS)
            task.wait(1)
        else
            warn("[FarmSession] Purchase unconfirmed — retrying.")
            task.wait(1)
        end
    end
end

function FarmSession:_washVehicle(vehicleName)
    pcall(function()
        ReplicatedStorage.Events.Vehicles.SetDirt:FireServer(0)
    end)
    task.wait(1)

    local carWash = Workspace:FindFirstChild("CarWash")
    if carWash then
        local prompt = findNearestPrompt(carWash)
        if prompt then
            pcall(fireproximityprompt, prompt)
            task.wait(2)
        end
    end
end

function FarmSession:_phase2_restore(sessionVehicles)
    notify("Phase 2: Restore & Paint " .. #sessionVehicles .. " vehicle(s)", "wrench")

    local buildingsFolder = Workspace.Map.FirstCity.Buildings
    local building = buildingsFolder:FindFirstChild("PitStop(Large)")
        or buildingsFolder:FindFirstChild("PitStop (Large)")
        or buildingsFolder:FindFirstChild("Pitstop(Large)")
        or buildingsFolder:FindFirstChild("PitStop")

    if not building then
        warn("[FarmSession] PitStop building not found. Available:")
        for _, c in pairs(buildingsFolder:GetChildren()) do warn("  - " .. c.Name) end
        return
    end

    for carIdx, vehName in ipairs(sessionVehicles) do
        if not self:_alive() then break end
        notify(string.format("Restoring %d/%d: %s", carIdx, #sessionVehicles, vehName), "settings")

        local activeVeh = findPlayerVehicle()
        if activeVeh then storeVehicle(activeVeh.Name) end

        if not teleportTo(REPAIR_BASE_POS) then
            if not waitForRoot() then break end
            teleportTo(REPAIR_BASE_POS)
        end
        task.wait(0.5)

        spawnVehicle(vehName, getRoot().CFrame * CFrame.new(0, 0, 15))
        self:_washVehicle(vehName)

        local vehicle = findPlayerVehicle()
        if not vehicle then
            warn("[FarmSession] Vehicle not found after spawn: " .. vehName)
        else
            local ok, err = pcall(function()
                self.repairManager:runFullRepair(vehicle, building)
            end)
            if not ok then warn("[Farm] repair error: " .. tostring(err)) end

            if not self.repairManager:reinstallAndVerify() then
                warn("[Farm] Parts still loose after repair — will retry after paint")
            end
            notify("Repair complete: " .. vehName, "check")
        end

        task.wait(1)
        if not self:_alive() then break end
        notify("Painting: " .. vehName, "paintbrush")

        local prePaintVeh = findPlayerVehicle()
        if prePaintVeh then storeVehicle(prePaintVeh.Name) end

        if not teleportTo(PAINT_POS) then
            if not waitForRoot() then break end
            teleportTo(PAINT_POS)
        end
        task.wait(0.5)

        spawnVehicle(vehName, getRoot().CFrame * CFrame.new(0, 0, 15))
        task.wait(1)
        self:_washVehicle(vehName)

        local model       = building.Model
        local paintPrompt = findNearestPrompt(model)
        if paintPrompt then
            pcall(fireproximityprompt, paintPrompt)
        else
            warn("[FarmSession] No paint prompt found.")
        end
        task.wait(0.5)

        local pg      = Player:FindFirstChild("PlayerGui")
        local hud     = pg and pg:FindFirstChild("HUD")
        local frames  = hud and hud:FindFirstChild("Frames")
        local paintUI = frames and frames:FindFirstChild("Paint")
        local pConf   = paintUI and paintUI:FindFirstChild("Confirm")
        if pConf then pressEnter(pConf) end

        notify("Paint applied: " .. vehName, "paintbrush")
        task.wait(2)
    end
end

function FarmSession:_phase3_hold()
    notify(string.format("Phase 3: Holding for %ds", self.config.holdDuration), "clock")
    self._targetEndTime = os.clock() + self.config.holdDuration

    local finished, lastSecText = false, -1
    if self._cdConn then self._cdConn:Disconnect() end

    self._cdConn = RunService.RenderStepped:Connect(function()
        if not self:_alive() then
            finished = true
            if self._cdConn then self._cdConn:Disconnect(); self._cdConn = nil end
            return
        end
        local remaining = math.ceil(self._targetEndTime - os.clock())
        if remaining <= 0 then
            finished = true
            if self._cdConn then self._cdConn:Disconnect(); self._cdConn = nil end
            return
        end
        if remaining ~= lastSecText then
            lastSecText = remaining
            if self.config.onCountdownTick then
                self.config.onCountdownTick(remaining, self.config.holdDuration)
            end
        end
    end)

    while not finished do task.wait() end
    self._targetEndTime = 0
end

function FarmSession:adjustHold(delta)
    if self._targetEndTime > 0 then
        self._targetEndTime = self._targetEndTime + delta
    end
end

function FarmSession:_phase4_sellAndDie(sessionVehicles)
    notify("Phase 4: Sequential sell then death reset", "dollar-sign")

    for i = #sessionVehicles, 1, -1 do
        if not self:_alive() then break end
        local targetName = sessionVehicles[i]
        notify(string.format("Selling %d/%d: %s", #sessionVehicles - i + 1, #sessionVehicles, targetName), "dollar-sign")

        local activeVeh = findPlayerVehicle()
        if activeVeh then storeVehicle(activeVeh.Name) end

        if not teleportTo(SELL_POS) then
            if not waitForRoot() then break end
            teleportTo(SELL_POS)
        end
        task.wait(0.5)

        spawnVehicle(targetName, getRoot().CFrame * CFrame.new(0, 0, 15))
        task.wait(1)

        pcall(function()
            fireproximityprompt(workspace.Utils.SellCar.Prompt.ProximityPrompt)
        end)
        task.wait(0.8)

        local sellConfirm = findConfirmButton()
        if sellConfirm then pressEnter(sellConfirm) end
        task.wait(0.5)
        Gui.SelectedCoreObject = nil

        local sellOk, sellElapsed, confirmRetried = false, 0, false
        repeat
            task.wait(0.25)
            sellElapsed = sellElapsed + 0.25
            if not GarageFolder:FindFirstChild(targetName) then
                sellOk = true
                break
            end
            if not confirmRetried then
                local c = findConfirmButton()
                if c and c.Visible then
                    confirmRetried = true
                    pressEnter(c)
                end
            end
        until sellElapsed > SELL_TIMEOUT or not self:_alive()

        if sellOk then
            notify("Sale confirmed: " .. targetName, "check")
        else
            warn("[FarmSession] Sale uncertain for: " .. targetName)
        end
        task.wait(1)
    end

    if self:_alive() then
        notify("All sold. Triggering death reset...", "skull")
        killPlayer()
        if not waitForRoot(20) then
            warn("[FarmSession] No respawn within 20s — aborting cycle")
            return
        end
        task.wait(2)
        notify("Respawned. Starting next batch cycle.", "repeat")
    end
end

function FarmSession:start()
    self.running   = true
    self.sessionId = self.sessionId + 1
    _G._farmSessionId = self.sessionId

    local id = self.sessionId
    notify("Started. Session ID: " .. id .. (isMobile and " (Mobile)" or " (PC)"), "play")

    task.spawn(function()
        local staleVeh = findPlayerVehicle()
        if staleVeh then storeVehicle(staleVeh.Name) end

        leaveGarageIfInside()

        while self:_alive() do
            self:_phase1_acquire()
            if not self:_alive() then break end

            local sessionVehicles = {}
            for _, child in pairs(GarageFolder:GetChildren()) do
                if #sessionVehicles < 3 then
                    table.insert(sessionVehicles, child.Name)
                end
            end

            if #sessionVehicles == 0 then
                warn("[FarmSession] No vehicles after acquisition. Retrying.")
                task.wait(3)
                continue
            end

            self:_phase2_restore(sessionVehicles)
            if not self:_alive() then break end

            self:_phase3_hold()
            if not self:_alive() then break end

            self:_phase4_sellAndDie(sessionVehicles)
            task.wait(2)
        end

        if self.config.onStopped then self.config.onStopped() end
        notify("Loop exited. Session ID was: " .. id, "stop-circle")
    end)
end

-- =========================================================================
-- Manual purchase
-- =========================================================================
local function purchaseVehicle(targetVeh, selectedLabel, onSuccess)
    if not targetVeh or not targetVeh:IsDescendantOf(VehFolder) then
        notify("Vehicle no longer in junkyard.", "alert-triangle")
        return
    end
    local vehName = targetVeh.Name
    if targetVeh:FindFirstChild("Body") and targetVeh.Body:FindFirstChild("Plate") then
        teleportTo(targetVeh.Body.Plate.CFrame)
    end
    task.wait(0.4)

    pcall(function()
        if targetVeh:FindFirstChild("ClickDetector") then
            fireclickdetector(targetVeh.ClickDetector)
        end
    end)
    task.wait(0.4)

    local confirmBtn = waitForConfirmButton(3)
    if not confirmBtn then
        notify("Confirmation UI didn't appear.", "alert-triangle")
        return
    end
    pressEnter(confirmBtn)

    local success, elapsed = false, 0
    repeat
        task.wait(0.1)
        elapsed = elapsed + 0.1
        if not VehFolder:FindFirstChild(vehName) and GarageFolder:FindFirstChild(vehName) then
            success = true
        end
    until success or elapsed > 5

    if success then
        notify("Purchased: " .. selectedLabel, "shopping-cart")
        leaveGarageIfInside()
        if onSuccess then onSuccess() end
    else
        notify("Purchase failed or timed out.", "alert-triangle")
    end
end

-- =========================================================================
-- UI
-- =========================================================================
local Window = WindUI:CreateWindow({
    Title  = "Garage Manager",
    Icon   = "wrench",
    Author = "Auto Script",
    Folder = "GarageManager",
    Size   = UDim2.fromOffset(580, 460),
    Theme  = "Dark"
})

local JunkTab = Window:Tab({ Title = "Junkyard", Icon = "car" })
local currentLabels, currentInstances = VehicleScanner.scan()
local selectedVehicle = nil

local Dropdown = JunkTab:Dropdown({
    Title    = "Available Vehicles",
    Values   = currentLabels,
    Callback = function(selected)
        selectedVehicle = selected
        notify("Selected: " .. selected, "car")
    end
})

JunkTab:Button({
    Title    = "Refresh Listings",
    Icon     = "refresh-ccw",
    Callback = function()
        currentLabels, currentInstances = VehicleScanner.scan()
        Dropdown:Refresh(currentLabels)
        selectedVehicle = nil
        notify("Refreshed. Found " .. #currentLabels .. " vehicle(s).", "refresh-ccw")
    end
})

JunkTab:Button({
    Title    = "Inspect Vehicle",
    Icon     = "arrow-up-right",
    Callback = function()
        if not selectedVehicle then
            notify("Nothing selected.", "alert-triangle")
            return
        end
        local targetVeh = currentInstances[selectedVehicle]
        if targetVeh and targetVeh:FindFirstChild("Body") and targetVeh.Body:FindFirstChild("Plate") then
            if teleportTo(targetVeh.Body.Plate.CFrame) then
                notify("Teleported to: " .. selectedVehicle, "map-pin")
            else
                notify("Character not ready.", "alert-triangle")
            end
        else
            notify("Vehicle no longer available.", "alert-triangle")
        end
    end
})

JunkTab:Button({
    Title    = "Purchase Vehicle",
    Icon     = "shopping-cart",
    Callback = function()
        if not selectedVehicle then
            notify("Nothing selected.", "alert-triangle")
            return
        end
        task.spawn(function()
            purchaseVehicle(currentInstances[selectedVehicle], selectedVehicle, function()
                currentLabels, currentInstances = VehicleScanner.scan()
                Dropdown:Refresh(currentLabels)
                selectedVehicle = nil
            end)
        end)
    end
})

-- Automation tab
local AutoTab = Window:Tab({ Title = "Automation", Icon = "bot" })
_G.minSpawnChance = 50
_G.WaitAfterPaint = 150
local activeFarm  = nil

AutoTab:Slider({
    Title = "Max Spawn Chance Filter",
    Step  = 1,
    Value = { Min = 1, Max = 50, Default = 50 },
    Callback = function(val)
        _G.minSpawnChance = val
        if activeFarm then activeFarm.config.maxSpawnChance = val end
        notify("SpawnChance filter: " .. val, "filter")
    end
})

local lastSliderVal = 150
local HoldSlider = AutoTab:Slider({
    Title = "Hold Duration Before Sale (s)",
    Desc  = "Duration: 150s",
    Step  = 1,
    Value = { Min = 1, Max = 200, Default = 150 },
    Callback = function(val)
        local delta = val - lastSliderVal
        _G.WaitAfterPaint = val
        lastSliderVal = val
        if activeFarm then
            activeFarm.config.holdDuration = val
            activeFarm:adjustHold(delta)
        else
            HoldSlider:SetDesc(string.format("Duration: %ds", val))
        end
    end
})

AutoTab:Toggle({
    Title    = "Auto Farm — Acquire · Restore · Paint · Sell · Respawn",
    Icon     = "repeat",
    Default  = false,
    Callback = function(state)
        if not state then
            if activeFarm then
                activeFarm:stop()
                activeFarm = nil
            end
            HoldSlider:SetDesc(string.format("Duration: %ds", _G.WaitAfterPaint))
            notify("Auto Farm stopped.", "stop-circle")
            return
        end

        if activeFarm then activeFarm:stop() end

        activeFarm = FarmSession.new({
            maxSpawnChance  = _G.minSpawnChance,
            holdDuration    = _G.WaitAfterPaint,
            onCountdownTick = function(remaining, total)
                HoldSlider:SetDesc(string.format("Remaining: %ds / %ds", remaining, total))
            end,
            onStopped = function()
                HoldSlider:SetDesc(string.format("Duration: %ds", _G.WaitAfterPaint))
            end
        })
        activeFarm:start()
    end
})

AutoTab:Divider()

_G.autoBuyRunning   = false
_G.targetPercentage = 5

AutoTab:Input({
    Title       = "Spawn Chance Threshold",
    Value       = "5",
    Placeholder = "Enter percentage...",
    Callback    = function(input)
        local num = tonumber(input)
        _G.targetPercentage = (num and num > 0) and num or 5
        notify(string.format("Threshold set: %s%%", tostring(_G.targetPercentage)), "target")
    end
})

AutoTab:Toggle({
    Title    = "Auto Purchase (threshold %)",
    Icon     = "repeat",
    Default  = false,
    Callback = function(state)
        _G.autoBuyRunning = state
        if not state then
            notify("Auto Purchase stopped.", "stop-circle")
            return
        end

        task.spawn(function()
            notify("Auto Purchase started. Threshold: " .. (_G.targetPercentage or 5) .. "%", "play")
            local lastScan = 0
            local cachedInstances = {}
            while _G.autoBuyRunning do
                if os.clock() - lastScan > 0.25 then
                    local _, inst = VehicleScanner.scan()
                    cachedInstances = inst
                    lastScan = os.clock()
                end

                local candidates = {}
                for label, veh in pairs(cachedInstances) do
                    local sc = veh:GetAttribute("SpawnChance") or math.huge
                    if sc <= (_G.targetPercentage or 5) then
                        table.insert(candidates, { label = label, veh = veh })
                    end
                end

                if #candidates == 0 then task.wait(0.3); continue end

                local targetLabel, targetVeh = nil, nil
                for _, c in ipairs(candidates) do
                    local ok, alive = pcall(function() return c.veh:IsDescendantOf(VehFolder) end)
                    if ok and alive then
                        targetLabel = c.label
                        targetVeh   = c.veh
                        break
                    end
                end

                if not targetVeh then task.wait(0.3); continue end
                notify("Target: " .. targetLabel, "crosshair")

                pcall(function()
                    local root = getRoot()
                    if root and targetVeh:FindFirstChild("Body") and targetVeh.Body:FindFirstChild("Plate") then
                        root.CFrame = targetVeh.Body.Plate.CFrame
                    end
                end)
                task.wait(0.2)

                pcall(function()
                    if targetVeh:FindFirstChild("ClickDetector") then
                        fireclickdetector(targetVeh.ClickDetector)
                    end
                end)
                task.wait(0.25)

                local confirmBtn = waitForConfirmButton(2.5)
                if not confirmBtn then
                    warn("[AutoBuy] UI timeout — retrying.")
                    task.wait(0.5)
                    continue
                end

                pressEnter(confirmBtn)

                local vehName = targetVeh.Name
                local bought, elapsed = false, 0
                repeat
                    task.wait(0.1)
                    elapsed = elapsed + 0.1
                    if GarageFolder:FindFirstChild(vehName) or findPlayerVehicle() then
                        bought = true
                    end
                until bought or elapsed > 4 or not _G.autoBuyRunning

                if bought then
                    notify("Purchased: " .. targetLabel, "shopping-cart")
                    leaveGarageIfInside()
                    break
                else
                    warn("[AutoBuy] Unconfirmed — retrying.")
                    task.wait(1)
                end
            end
            _G.autoBuyRunning = false
            notify("Auto Purchase exited.", "stop-circle")
        end)
    end
})

AutoTab:Divider()

local manualRepair = RepairManager.new()

AutoTab:Button({
    Title    = "Repair Vehicle",
    Icon     = "settings",
    Callback = function()
        task.spawn(function()
            if not teleportTo(REPAIR_BASE_POS) then
                notify("No character.", "alert-triangle")
                return
            end
            local vehicle = findPlayerVehicle()
            if not vehicle then warn("[Repair] No vehicle."); return end
            local building = Workspace.Map.FirstCity.Buildings:FindFirstChild("PitStop(Large)")
            if not building then
                notify("PitStop not found.", "alert-triangle")
                return
            end
            local ok, err = pcall(function()
                manualRepair:runFullRepair(vehicle, building)
            end)
            if not ok then warn("[ManualRepair] " .. tostring(err)) end
            manualRepair:reinstallAndVerify()
            notify(ok and "Repair done." or "Repair finished with errors.",
                   ok and "check" or "alert-triangle")
        end)
    end
})

AutoTab:Button({
    Title    = "Apply Paint",
    Icon     = "paintbrush",
    Callback = function()
        task.spawn(function()
            if not teleportTo(PAINT_POS) then
                notify("No character.", "alert-triangle")
                return
            end
            local vehicle = findPlayerVehicle()
            if vehicle then storeVehicle(vehicle.Name) end

            local playerVeh = findPlayerVehicle()
            if playerVeh then
                spawnVehicle(playerVeh.Name, getRoot().CFrame * CFrame.new(0, 0, 15))
            end
            task.wait(2)

            local building = Workspace.Map.FirstCity.Buildings:FindFirstChild("PitStop(Large)")
            if not building then
                notify("PitStop not found.", "alert-triangle")
                return
            end
            local paintPrompt = findNearestPrompt(building.Model)
            if paintPrompt then
                fireproximityprompt(paintPrompt)
            else
                warn("[Paint] No paint prompt.")
            end
            task.wait(0.5)
            local pg     = Player:FindFirstChild("PlayerGui")
            local hud    = pg and pg:FindFirstChild("HUD")
            local frames = hud and hud:FindFirstChild("Frames")
            local paint  = frames and frames:FindFirstChild("Paint")
            local conf   = paint and paint:FindFirstChild("Confirm")
            if conf then pressEnter(conf) end
        end)
    end
})

AutoTab:Button({
    Title    = "Sell Vehicle",
    Icon     = "dollar-sign",
    Callback = function()
        if not teleportTo(SELL_POS) then
            notify("No character.", "alert-triangle")
            return
        end
        local veh = findPlayerVehicle()
        if not veh then warn("[Sell] No vehicle."); return end

        storeVehicle(veh.Name)
        task.wait(0.5)
        spawnVehicle(veh.Name, getRoot().CFrame * CFrame.new(0, 0, 15))
        task.wait(1)
        pcall(function()
            fireproximityprompt(workspace.Utils.SellCar.Prompt.ProximityPrompt)
        end)
        task.wait(0.4)
        local c = findConfirmButton()
        if c then pressEnter(c) end
        task.wait(0.5)
        Gui.SelectedCoreObject = nil
    end
})

-- Vehicle tab
local VehTab = Window:Tab({ Title = "Vehicle", Icon = "box" })

VehTab:Button({
    Title    = "Deploy Vehicle",
    Icon     = "refresh-cw",
    Callback = function()
        task.spawn(function()
            local veh = findPlayerVehicle()
            if not veh then warn("[Vehicle] No vehicle to deploy."); return end
            spawnVehicle(veh.Name, getRoot().CFrame * CFrame.new(0, 0, 15))
        end)
    end
})

VehTab:Button({
    Title    = "Goto Vehicle",
    Icon     = "map-pin",
    Callback = function()
        local v = findPlayerVehicle()
        if not v then notify("No active vehicle.", "alert-triangle"); return end
        local root = getRoot()
        if root and v:FindFirstChild("Body") and v.Body:FindFirstChild("Plate") then
            root.CFrame = v.Body.Plate.CFrame
            notify("Teleported to: " .. v.Name, "map-pin")
        end
    end
})

VehTab:Button({
    Title    = "Install Components",
    Icon     = "arrow-down-to-line",
    Callback = function()
        task.spawn(function()
            if not manualRepair:reinstallAndVerify() then
                notify("Some parts didn't reinstall — retried.", "alert-triangle")
            else
                notify("All parts reinstalled.", "check")
            end
        end)
    end
})

notify("Garage Manager loaded.", "wrench")
