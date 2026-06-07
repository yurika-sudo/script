local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local ourScreenGui = nil
local windowFrame  = nil
local lockedPos    = nil

local _pgConn
_pgConn = LocalPlayer.PlayerGui.ChildAdded:Connect(function(child)
    if child:IsA("ScreenGui") then
        task.wait(0.15)  -- wait for frame to populate
        pcall(function()
            child.DisplayOrder = 999  -- always on top game banner
            child.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        end)
        -- Cari top-level Frame (main window)
        for _, ch in ipairs(child:GetChildren()) do
            if ch:IsA("Frame") then
                ourScreenGui = child
                windowFrame  = ch
                pcall(function()
                    -- Minimal y=110: under Roblox bar + game banner
                    windowFrame.Position = UDim2.new(0, 16, 0, 110)
                end)
                break
            end
        end
        if _pgConn then _pgConn:Disconnect() end
    end
end)

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

local FLY_HEIGHT       = 14
-- Punch range: ideal 4-8 studs, not spam mode (was 0-6)
local PUNCH_MIN_DIST   = 4
local PUNCH_IDEAL_DIST = 5.5
local PUNCH_MAX_DIST   = 8
local PUNCH_RATE       = 0.70  -- more deliberate, not spam
local moveTimer      = 0
local bombHoldTimer  = 0
local bombChaseDelay = 0
local punchTimer     = 0
local flyBP          = nil
local noFallBV       = nil
local ghostActive    = false
local uiClampTimer   = 0

-- Stuck detection during bomb chasing
local stuckCheckPos  = nil
local stuckCheckTime = 0

-- Remotes
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

-- Nearest player without filter (for bomb chase)
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

-- Nearest VALID player: filter spectators
-- How to: The spectator is usually in a different Y position (elevated/in another area)
-- + check health > 0 (active in-game character)
local function nearestValidPlayer()
    local c = getChar(); local h = getHRP(c)
    if not h then return nil, math.huge end
    local best, bestDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local oh  = getHRP(p.Character)
            local hum = getHum(p.Character)
            if oh and hum and hum.Health > 0 then
                -- Spectator filter: Y height must be within ±15 studs
                -- Spectators are in different areas (up/down from the arena)
                if math.abs(oh.Position.Y - h.Position.Y) <= 15 then
                    local d = (h.Position - oh.Position).Magnitude
                    if d < bestDist then bestDist = d; best = p end
                end
            end
        end
    end
    return best, bestDist
end

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

local function clampWindowToScreen()
    if not windowFrame then return end
    pcall(function()
        local vp     = workspace.CurrentCamera.ViewportSize
        local absPos = windowFrame.AbsolutePosition
        local absSz  = windowFrame.AbsoluteSize
        local nx = math.clamp(absPos.X, 0,  vp.X - absSz.X)
        local ny = math.clamp(absPos.Y, 110, vp.Y - absSz.Y)
        if math.abs(absPos.X - nx) > 1 or math.abs(absPos.Y - ny) > 1 then
            windowFrame.Position = UDim2.new(0, nx, 0, ny)
        end
    end)
end

local function resetWindowPosition()
    if not windowFrame then return end
    pcall(function()
        windowFrame.Position = UDim2.new(0, 16, 0, 110)
        lockedPos = windowFrame.Position
    end)
end

RunService.Heartbeat:Connect(function(dt)
    local c = getChar(); local h = getHum(c)
    if not h or h.Health <= 0 then return end
    local r = getHRP(c)

    -- Speed
    local spd = cfg.SpeedEnabled and cfg.Speed or 16
    if h.WalkSpeed ~= spd then h.WalkSpeed = spd end

    -- Noclip
    if cfg.Noclip and not ghostActive then
        setNoclip(c, true)
    elseif not cfg.Noclip and ghostActive then
        setNoclip(c, false)
    end

    if cfg.AutoPassBomb then
        local holding = hasBomb(c)
        if holding then
            bombHoldTimer = bombHoldTimer + dt

            -- Set the delay once you receive the bomb
            -- 2-4s: Looks natural, with 6-12s left to catch up (10-14s timer)
            if bombChaseDelay == 0 then
                bombChaseDelay = math.random(2, 4)
            end

            if flyBP then flyBP.MaxForce = Vector3.new(0, 0, 0) end

            -- BUG FIX: Remove the "closeEnough" bypass — that's what makes characters
            -- instantly chase because players are always within 24 studs of each other.
            -- Now it's purely a matter of waiting for the delay, period.
            if bombHoldTimer >= bombChaseDelay then
                local target, _ = nearestPlayer()
                moveTimer = moveTimer + dt
                if moveTimer >= 0.15 and target and target.Character then
                    moveTimer = 0
                    local oh = getHRP(target.Character)
                    if oh and r then
                        h:MoveTo(oh.Position)

                        -- Stuck detection: sample position every 0.5s
                        -- If it doesn't advance ≥1.5 studs → jump + brief noclip
                        stuckCheckTime = stuckCheckTime + 0.15
                        if stuckCheckTime >= 0.5 then
                            stuckCheckTime = 0
                            if stuckCheckPos then
                                local moved = (r.Position - stuckCheckPos).Magnitude
                                if moved < 1.5 then
                                    -- Hit an obstacle: jump first
                                    h.Jump = true
                                    -- If still stuck after jumping → brief noclip
                                    if not cfg.Noclip then
                                        setNoclip(c, true)
                                        task.delay(0.35, function()
                                            if not cfg.Noclip then
                                                local chr = getChar()
                                                if chr then setNoclip(chr, false) end
                                            end
                                        end)
                                    end
                                end
                            end
                            stuckCheckPos = r.Position
                        end
                    end
                end
            end
        else
            if bombHoldTimer > 0 then
                bombHoldTimer  = 0
                bombChaseDelay = 0
                stuckCheckPos  = nil
                stuckCheckTime = 0
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

    if cfg.AutoPunch and cfg.PVPMode and r then
        local target, dist = nearestValidPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            -- Double-check height (in case the audience goes up/down)
            if oh and math.abs(r.Position.Y - oh.Position.Y) <= 12 then
                local toTarget     = oh.Position - r.Position
                local toTargetUnit = toTarget.Unit

                -- How "face-to-face" are we to the target?
                -- 1.0 = directly facing, -1.0 = facing away
                local facingScore = r.CFrame.LookVector:Dot(toTargetUnit)

                -- Is the target running away fast?  Don't waste punch
                local targetFleeing = oh.AssemblyLinearVelocity:Dot(toTargetUnit) > 8

                -- Positioning logic
                if dist > PUNCH_MAX_DIST then
                    -- Too far → chase
                    h:MoveTo(oh.Position)
                elseif dist < PUNCH_MIN_DIST then
                    -- Too close → move back to ideal range
                    h:MoveTo(r.Position - toTargetUnit * (PUNCH_IDEAL_DIST - dist + 0.5))
                elseif facingScore < 0.5 then
                    -- Already in range but still tilted/facing away →
                    -- Move to a position directly in front of the target (face-to-face)
                    local facePos = oh.Position + oh.CFrame.LookVector * PUNCH_IDEAL_DIST
                    h:MoveTo(Vector3.new(facePos.X, r.Position.Y, facePos.Z))
                end

                -- Punch when: facing the target, ideal range, target is no longer blurry
                -- Rate 0.7s → feels natural, not newbie spam
                punchTimer = punchTimer + dt
                if dist >= PUNCH_MIN_DIST and dist <= PUNCH_MAX_DIST
                   and facingScore > 0.5
                   and not targetFleeing
                   and punchTimer >= PUNCH_RATE then
                    punchTimer = 0
                    firePunch(target.Character, oh)
                end
            end
        end
    end

    -- UI clamp every 0.6s
    uiClampTimer = uiClampTimer + dt
    if uiClampTimer >= 0.6 then
        uiClampTimer = 0
        if cfg.LockUI and lockedPos and windowFrame then
            pcall(function() windowFrame.Position = lockedPos end)
        else
            clampWindowToScreen()
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    flyBP = nil; noFallBV = nil; ghostActive = false
    bombHoldTimer = 0; bombChaseDelay = 0
    stuckCheckPos = nil; stuckCheckTime = 0
    task.wait(1)
    if cfg.Fly    then setupFly(true) end
    if cfg.NoFall then setupNoFall(true) end
end)

Window:Label("Bomb Game")

Window:Toggle("Auto Pass Bomb", false, function(state)
    cfg.AutoPassBomb = state
    bombHoldTimer = 0; bombChaseDelay = 0; moveTimer = 0
    stuckCheckPos = nil; stuckCheckTime = 0
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
        clampWindowToScreen()
        pcall(function() lockedPos = windowFrame.Position end)
    end
end)
