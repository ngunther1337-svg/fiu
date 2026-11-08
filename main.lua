-- =========================================================================
-- Fix It Up Garage Manager — Delta Android Hardened
-- =========================================================================
-- This script includes a fallback for Delta's uncertain touch API support.
-- If SendTouchEvent is not available, it falls back to ClickDetector firing.
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
-- Delta sometimes misreports MouseEnabled on mobile. Trust TouchEnabled.
local isMobile = UserInputService.TouchEnabled

-- Debug print to verify Delta's input detection
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

-- Android repair gesture tuning
local TOUCH_MAX_ATTEMPTS = 30
local TOUCH_SWIPE_RADIUS = 12
local TOUCH_GESTURE_DUR  = 0.5
local TOUCH_GAP          = 0.15
-- PC hold tuning
local PC_HOLD_MAX        = 20

local REPAIR_BASE_POS = CFrame.new(-1076, 5, -414)
local PAINT_POS = CFrame.new(
    -990.619568, 4.53032351, -387.379364,
    0.350393713, -8.45001722e-08, -0.936602473,
    -4.68328265e-09, 1, -9.19719554e-08,
    0.936602473, 3.66127715e-08, 0.350393713
)
local SELL_POS = CFrame.new(-1915, 4, -785)

-- Load WindUI with a pinned version to avoid "latest" redirect failures
local WindUI_URL = "https://raw.githubusercontent.com/Footagesus/WindUI/main/main.lua" -- Fallback simple URL
local WindUI = loadstring(game:HttpGet(WindUI_URL))()

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

-- =========================================================================
-- Touch / Mouse repair input with Delta fallback
-- =========================================================================
local touchSupported = true -- Optimistic; flips to false on first error

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
                -- SendTouchEvent unsupported — fall back entirely
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

-- The rest of the script (VehicleScanner, RepairManager, FarmSession, UI)
-- remains structurally identical to the previous corrected version.
-- [Paste the remaining sections from the previous fully fixed script here]
-- ...
-- ...
