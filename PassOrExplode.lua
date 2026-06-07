local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Library = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/miroeramaa/TurtleLib/main/TurtleUiLib.lua"
))()
local Window = Library:Window("POE Assist")

local cfg = {
    AutoPassBomb = false,
    Noclip       = false,
    SpeedEnabled = false,
    Speed        = 20,
    NoFall       = false,
    Fly          = false,
    PVPMode      = false,
    AutoPunch    = false,
    LockUI       = false,
}

local FLY_HEIGHT   = 14
local PUNCH_RANGE  = 6
local PUNCH_RATE   = 0.45

local moveTimer      = 0
local bombHoldTimer  = 0
local bombChaseDelay = 0
local punchTimer     = 0
local flyBP          = nil
local noFallBV       = nil
local ghostActive    = false

-- UI state
local uiClampTimer  = 0
local ourScreenGui  = nil
local windowFrame   = nil
local lockedPos     = nil

-- Remotes: background fetch so UI renders instantly
local RS            = game:GetService("ReplicatedStorage")
local remoteAction  = nil
local remoteEndgame = nil
task.spawn(function()
    remoteAction  = RS:WaitForChild("ActionEvent", 15)
    remoteEndgame = RS:WaitForChild("EndgameAttackEvent", 15)
end)

local function getChar() return LocalPlayer.Character end
local function getHum(c) return c and c:FindFirstChildOfClass("Humanoid") end
local function getHRP(c) return c and c:FindFirstChild("HumanoidRootPart") end

local function hasBomb(c)
    if not c then return false end
    for _, v in ipairs(c:GetChildren()) do
        if v:IsA("Tool") then return true end
    end
    local bv = c:FindFirstChild("BombActive")
    if bv and bv:IsA("BoolValue") and bv.Value then return true end
    local ok, val = pcall(function() return c:GetAttribute("BombActive") end)
    if ok and val == true then return true end
    return false
end

local function nearestPlayer()
    local c = getChar(); local h = getHRP(c)
    if not h then return nil, math.huge end
    local best, bestDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local oh = getHRP(p.Character)
            if oh then
                local d = (h.Position - oh.Position).Magnitude
                if d < bestDist then bestDist = d; best = p end
            end
        end
    end
    return best, bestDist
end

-- Noclip: upper body only so step-up/stairs still work
local LEG_NAMES = {
    "LeftFoot","RightFoot","LeftLowerLeg","RightLowerLeg",
    "LeftUpperLeg","RightUpperLeg","Left Leg","Right Leg"
}
local function isLeg(name)
    for _, n in ipairs(LEG_NAMES) do if name == n then return true end end
    return false
end
local function setNoclip(c, on)
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and not isLeg(p.Name) then
            p.CanCollide = not on
        end
    end
    ghostActive = on
end

-- No Fall: BodyVelocity conditional
local function setupNoFall(enable)
    if noFallBV then pcall(function() noFallBV:Destroy() end); noFallBV = nil end
    if enable then
        local r = getHRP(getChar())
        if r then
            local bv    = Instance.new("BodyVelocity")
            bv.Name     = "NoFallBV"
            bv.Velocity = Vector3.new(0, 0, 0)
            bv.MaxForce = Vector3.new(0, 0, 0)
            bv.Parent   = r
            noFallBV = bv
        end
    end
end

-- Fly: BodyPosition with damping
local function setupFly(enable)
    if flyBP then pcall(function() flyBP:Destroy() end); flyBP = nil end
    if enable then
        local r = getHRP(getChar())
        if r then
            local bp    = Instance.new("BodyPosition")
            bp.Name     = "FlyBP"
            bp.MaxForce = Vector3.new(0, 1e5, 0)
            bp.P        = 8000
            bp.D        = 600
            bp.Position = r.Position
            bp.Parent   = r
            flyBP = bp
        end
    end
end

local function updateFly()
    local c = getChar(); local r = getHRP(c)
    if not r or not flyBP then return end
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {c}
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ray     = workspace:Raycast(r.Position, Vector3.new(0,-150,0), params)
    local groundY = ray and ray.Position.Y or (r.Position.Y - FLY_HEIGHT)
    flyBP.Position = Vector3.new(r.Position.X, groundY + FLY_HEIGHT, r.Position.Z)
end

-- Punch: remotes + VirtualInputManager tap (mobile)
local VIM = game:GetService("VirtualInputManager")
local function firePunch(targetChar, targetHRP)
    if remoteAction then
        pcall(function() remoteAction:FireServer("Punch") end)
        pcall(function() remoteAction:FireServer("punch", targetChar) end)
        pcall(function() remoteAction:FireServer("Attack") end)
    end
    if remoteEndgame then
        pcall(function() remoteEndgame:FireServer(targetChar) end)
        pcall(function() remoteEndgame:FireServer() end)
    end
    pcall(function()
        local sp, vis = workspace.CurrentCamera:WorldToScreenPoint(targetHRP.Position)
        if vis then
            VIM:SendMouseButtonEvent(sp.X, sp.Y, 0, true,  game, 0)
            task.delay(0.06, function()
                VIM:SendMouseButtonEvent(sp.X, sp.Y, 0, false, game, 0)
            end)
        end
    end)
    pcall(function()
        for _, v in ipairs(LocalPlayer.PlayerGui:GetDescendants()) do
            if (v:IsA("ImageButton") or v:IsA("TextButton")) and v.Visible then
                local n = v.Name:lower()
                if n:find("punch") or n:find("attack") or n:find("fight") then
                    v.MouseButton1Click:Fire()
                end
            end
        end
    end)
end

-- ============================================================
-- UI position helpers
-- ============================================================
local function clampWindowToScreen()
    if not windowFrame then return end
    pcall(function()
        local vp     = workspace.CurrentCamera.ViewportSize
        local absPos = windowFrame.AbsolutePosition
        local absSz  = windowFrame.AbsoluteSize
        -- Keep at least 40px from top so title bar stays visible
        local nx = math.clamp(absPos.X, 0,  vp.X - absSz.X)
        local ny = math.clamp(absPos.Y, 40, vp.Y - absSz.Y)
        if math.abs(absPos.X - nx) > 1 or math.abs(absPos.Y - ny) > 1 then
            windowFrame.Position = UDim2.new(0, nx, 0, ny)
        end
    end)
end

local function resetWindowPosition()
    if not windowFrame then return end
    pcall(function()
        windowFrame.Position = UDim2.new(0, 16, 0, 80)
        lockedPos = windowFrame.Position
    end)
end

-- Find TurtleLib's ScreenGui after it renders
task.spawn(function()
    task.wait(0.4)
    local pg = LocalPlayer.PlayerGui
    for _, gui in ipairs(pg:GetChildren()) do
        if gui:IsA("ScreenGui") then
            for _, desc in ipairs(gui:GetDescendants()) do
                if (desc:IsA("TextLabel") or desc:IsA("TextButton"))
                    and tostring(desc.Text):find("POE") then
                    ourScreenGui = gui
                    break
                end
            end
            if ourScreenGui then break end
        end
    end

    -- Fallback: just grab every ScreenGui and boost order
    -- (safe because DisplayOrder only affects stacking vs other ScreenGuis)
    if not ourScreenGui then
        for _, gui in ipairs(pg:GetChildren()) do
            if gui:IsA("ScreenGui") then
                pcall(function()
                    -- only boost if it has at least one Frame child (looks like a lib window)
                    for _, ch in ipairs(gui:GetChildren()) do
                        if ch:IsA("Frame") then ourScreenGui = gui; break end
                    end
                end)
                if ourScreenGui then break end
            end
        end
    end

    if ourScreenGui then
        -- Stay above game banners / overlays
        pcall(function() ourScreenGui.DisplayOrder = 999 end)
        pcall(function() ourScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling end)

        -- Find the top-level draggable Frame
        for _, ch in ipairs(ourScreenGui:GetChildren()) do
            if ch:IsA("Frame") then
                windowFrame = ch
                break
            end
        end

        -- Snap to a safe starting position
        if windowFrame then
            pcall(function()
                windowFrame.Position = UDim2.new(0, 16, 0, 80)
            end)
        end
    end
end)

-- ============================================================
-- Main loop
-- ============================================================
RunService.Heartbeat:Connect(function(dt)
    local c = getChar(); local h = getHum(c)
    if not h or h.Health <= 0 then return end
    local r = getHRP(c)

    -- Persistent speed
    local spd = cfg.SpeedEnabled and cfg.Speed or 16
    if h.WalkSpeed ~= spd then h.WalkSpeed = spd end

    -- Noclip
    if cfg.Noclip and not ghostActive then
        setNoclip(c, true)
    elseif not cfg.Noclip and ghostActive then
        setNoclip(c, false)
    end

    -- Auto Pass Bomb — anti-sus delay adjusted for 10–14s game timer
    -- Waits 2–4s first (looks natural), still leaves ~6–12s to pass it
    if cfg.AutoPassBomb then
        local holding = hasBomb(c)
        if holding then
            bombHoldTimer = bombHoldTimer + dt

            if bombChaseDelay == 0 then
                -- FIX: was math.random(7,10) — too long for a 10-14s timer
                bombChaseDelay = math.random(2, 4)
            end

            if flyBP then flyBP.MaxForce = Vector3.new(0, 0, 0) end

            local target, dist = nearestPlayer()
            local closeEnough  = dist <= spd * 1.5
            if bombHoldTimer >= bombChaseDelay or closeEnough then
                moveTimer = moveTimer + dt
                if moveTimer >= 0.15 and target and target.Character then
                    moveTimer = 0
                    local oh = getHRP(target.Character)
                    if oh then h:MoveTo(oh.Position) end
                end
            end
        else
            if bombHoldTimer > 0 then
                bombHoldTimer  = 0
                bombChaseDelay = 0
                if cfg.Fly and flyBP then
                    flyBP.MaxForce = Vector3.new(0, 1e5, 0)
                end
            end
        end
    end

    -- No Fall
    if cfg.NoFall and noFallBV and r and not cfg.Fly then
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            noFallBV.MaxForce = Vector3.new(0, 1e6, 0)
            noFallBV.Velocity  = Vector3.new(0, 0, 0)
        else
            noFallBV.MaxForce = Vector3.new(0, 0, 0)
        end
    end

    -- Fly
    if cfg.Fly and not (cfg.AutoPassBomb and hasBomb(c)) then updateFly() end

    -- Auto Punch
    if cfg.AutoPunch and cfg.PVPMode and r then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh then
                if r.Position.Y - oh.Position.Y > 12 then return end
                h:MoveTo(oh.Position)
                punchTimer = punchTimer + dt
                if dist <= PUNCH_RANGE and punchTimer >= PUNCH_RATE then
                    punchTimer = 0
                    firePunch(target.Character, oh)
                end
            end
        end
    end

    -- UI: clamp every 0.6s so window stays on screen
    uiClampTimer = uiClampTimer + dt
    if uiClampTimer >= 0.6 then
        uiClampTimer = 0
        if cfg.LockUI and lockedPos and windowFrame then
            -- Hard-lock: snap back to saved position every tick
            pcall(function() windowFrame.Position = lockedPos end)
        else
            clampWindowToScreen()
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    flyBP = nil; noFallBV = nil; ghostActive = false
    bombHoldTimer = 0; bombChaseDelay = 0
    task.wait(1)
    if cfg.Fly    then setupFly(true) end
    if cfg.NoFall then setupNoFall(true) end
end)

-- ============================================================
-- UI
-- ============================================================

Window:Label("Bomb Game")

Window:Toggle("Auto Pass Bomb", false, function(state)
    cfg.AutoPassBomb = state
    bombHoldTimer = 0; bombChaseDelay = 0; moveTimer = 0
end)

Window:Toggle("Ghost Mode", false, function(state)
    cfg.Noclip = state
    if not state and ghostActive then
        local c = getChar()
        if c then setNoclip(c, false) end
    end
end)

Window:Toggle("Speed Boost", false, function(state)
    cfg.SpeedEnabled = state
end)

Window:Button("Speed  16  (default)", function() cfg.Speed = 16 end)
Window:Button("Speed  20  (subtle)",  function() cfg.Speed = 20 end)
Window:Button("Speed  22  (safe max)",function() cfg.Speed = 22 end)

Window:Label("PVP")

Window:Toggle("PVP Mode", false, function(state)
    cfg.PVPMode = state
    punchTimer  = 0
end)

Window:Toggle("No Fall", false, function(state)
    cfg.NoFall = state
    setupNoFall(state)
end)

Window:Toggle("Fly", false, function(state)
    cfg.Fly = state
    setupFly(state)
    if state then
        if noFallBV then noFallBV.MaxForce = Vector3.new(0,0,0) end
    else
        if cfg.NoFall then setupNoFall(true) end
    end
end)

Window:Toggle("Auto Punch", false, function(state)
    cfg.AutoPunch = state
    punchTimer    = 0
end)

Window:Label("UI")

Window:Button("Reset UI Position", function()
    resetWindowPosition()
end)

Window:Toggle("Lock UI Position", false, function(state)
    cfg.LockUI = state
    if state and windowFrame then
        -- Clamp dulu sebelum lock biar posisinya aman
        clampWindowToScreen()
        pcall(function() lockedPos = windowFrame.Position end)
    end
end)
