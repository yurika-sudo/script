local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local ourScreenGui = nil
local windowFrame  = nil
local lockedPos    = nil

local _pgConn
_pgConn = LocalPlayer.PlayerGui.ChildAdded:Connect(function(child)
    if child:IsA("ScreenGui") then
        task.wait(0.15)
        pcall(function()
            child.DisplayOrder = 999
            child.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        end)
        for _, ch in ipairs(child:GetChildren()) do
            if ch:IsA("Frame") then
                ourScreenGui = child
                windowFrame  = ch
                pcall(function()
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

-- Fly
local FLY_HEIGHT = 14

-- Punch (PVP mode)
local PUNCH_MIN_DIST   = 4
local PUNCH_IDEAL_DIST = 5.5
local PUNCH_MAX_DIST   = 8
local PUNCH_RATE       = 0.70

-- Auto pass bomb tuning
local BOMB_TRANSFER_DIST    = 3.5   -- stop chasing when this close; let game handle proximity pass
local BOMB_SPEED_CAP        = 28    -- hard cap on chase speed regardless of walkspeed setting
local STUCK_INTERVAL        = 0.5   -- seconds between stuck-check samples
local STUCK_MIN_MOVEMENT    = 1.5   -- studs; below this threshold = consider stuck
local STUCK_NOCLIP_COOLDOWN = 1.5   -- min seconds between consecutive stuck-triggered noclips

-- Runtime state
local punchTimer          = 0
local flyBP               = nil
local noFallBV            = nil
local ghostActive         = false
local uiClampTimer        = 0

-- Bomb state
local bombHoldTimer       = 0
local bombChaseDelay      = 0
local bombChaseSet        = false   -- true once delay is determined for this hold
local stuckCheckPos       = nil
local stuckCheckTime      = 0
local stuckNoclipCooldown = 0
local bombMoveVelocity    = nil     -- BodyVelocity instance (camera-lock-resistant movement)

-- Game timer cache (scanned once per round, reset on respawn)
local timerObj      = nil
local timerSearched = false

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

-- Scan workspace/RS for a numeric round timer object (once per round)
local function findGameTimer()
    if not timerSearched then
        timerSearched = true
        local candidates = {
            "Timer","GameTimer","BombTimer","TimeLeft",
            "Countdown","RoundTimer","CountdownTimer","RoundTime"
        }
        for _, name in ipairs(candidates) do
            for _, loc in ipairs({workspace, RS}) do
                local obj = loc:FindFirstChild(name, true)
                if obj and (obj:IsA("NumberValue") or obj:IsA("IntValue")) then
                    timerObj = obj
                    break
                end
            end
            if timerObj then break end
        end
    end
    return timerObj and math.floor(timerObj.Value) or nil
end

-- Urgency-aware delay: shorter if the round is almost over
local function getChaseDelay()
    local t = findGameTimer()
    if t then
        if t <= 4  then return 0   end  -- emergency: chase immediately
        if t <= 7  then return 0.8 end  -- urgent
        if t <= 10 then return 1.5 end  -- moderate
    end
    return math.random(2, 4)            -- default: look natural
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

-- Filter spectators: must be within ±15 studs Y and health > 0
local function nearestValidPlayer()
    local c = getChar(); local h = getHRP(c)
    if not h then return nil, math.huge end
    local best, bestDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local oh  = getHRP(p.Character)
            local hum = getHum(p.Character)
            if oh and hum and hum.Health > 0 then
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

-- BodyVelocity-based movement for bomb chasing.
-- Bypasses Humanoid:MoveTo() which can be blocked by the game's POV lock control scheme.
-- XZ-only force: does not fight gravity or vertical movement.
local function bombMoveTo(r, h, targetPos)
    local dirXZ = Vector3.new(targetPos.X - r.Position.X, 0, targetPos.Z - r.Position.Z)
    local dist  = dirXZ.Magnitude

    -- Inside transfer zone: stop and let the game handle the pass via proximity
    if dist <= BOMB_TRANSFER_DIST then
        if bombMoveVelocity then
            bombMoveVelocity.Velocity = Vector3.zero
        end
        return
    end

    if not bombMoveVelocity then
        local bv    = Instance.new("BodyVelocity")
        bv.Name     = "BombMoveVelocity"
        bv.MaxForce = Vector3.new(1e5, 0, 1e5)
        bv.Velocity = Vector3.zero
        bv.Parent   = r
        bombMoveVelocity = bv
    end

    local speed = math.min(h.WalkSpeed, BOMB_SPEED_CAP)
    bombMoveVelocity.Velocity = dirXZ.Unit * speed
end

local function cleanupBombMove()
    if bombMoveVelocity then
        pcall(function() bombMoveVelocity.Velocity = Vector3.zero end)
        pcall(function() bombMoveVelocity:Destroy() end)
        bombMoveVelocity = nil
    end
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

    -- Auto pass bomb
    if cfg.AutoPassBomb then
        local holding = hasBomb(c)
        if holding then
            bombHoldTimer = bombHoldTimer + dt

            -- Determine delay once per hold (accounts for current round timer)
            if not bombChaseSet then
                bombChaseDelay = getChaseDelay()
                bombChaseSet   = true
            end

            -- Suppress fly while holding bomb
            if flyBP then flyBP.MaxForce = Vector3.new(0, 0, 0) end

            if bombHoldTimer >= bombChaseDelay then
                local target, _ = nearestPlayer()
                if target and target.Character and r then
                    local oh = getHRP(target.Character)
                    if oh then
                        -- Smooth velocity movement; fixes both camera-lock block and jitter
                        bombMoveTo(r, h, oh.Position)

                        -- Stuck detection with noclip cooldown to prevent rapid ON/OFF jitter
                        stuckCheckTime      = stuckCheckTime + dt
                        stuckNoclipCooldown = math.max(0, stuckNoclipCooldown - dt)

                        if stuckCheckTime >= STUCK_INTERVAL then
                            stuckCheckTime = 0
                            if stuckCheckPos then
                                local moved = (r.Position - stuckCheckPos).Magnitude
                                if moved < STUCK_MIN_MOVEMENT and stuckNoclipCooldown <= 0 then
                                    h.Jump = true
                                    if not cfg.Noclip then
                                        stuckNoclipCooldown = STUCK_NOCLIP_COOLDOWN
                                        setNoclip(c, true)
                                        task.delay(0.4, function()
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
                -- Bomb passed or round ended: full state reset
                bombHoldTimer       = 0
                bombChaseDelay      = 0
                bombChaseSet        = false
                stuckCheckPos       = nil
                stuckCheckTime      = 0
                stuckNoclipCooldown = 0
                cleanupBombMove()
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

    -- Fly (suppressed while holding bomb)
    if cfg.Fly and not (cfg.AutoPassBomb and hasBomb(c)) then updateFly() end

    -- Auto Punch (requires PVP Mode)
    if cfg.AutoPunch and cfg.PVPMode and r then
        local target, dist = nearestValidPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh and math.abs(r.Position.Y - oh.Position.Y) <= 12 then
                local toTarget      = oh.Position - r.Position
                local toTargetUnit  = toTarget.Unit
                local facingScore   = r.CFrame.LookVector:Dot(toTargetUnit)
                local targetFleeing = oh.AssemblyLinearVelocity:Dot(toTargetUnit) > 8

                if dist > PUNCH_MAX_DIST then
                    h:MoveTo(oh.Position)
                elseif dist < PUNCH_MIN_DIST then
                    h:MoveTo(r.Position - toTargetUnit * (PUNCH_IDEAL_DIST - dist + 0.5))
                elseif facingScore < 0.5 then
                    local facePos = oh.Position + oh.CFrame.LookVector * PUNCH_IDEAL_DIST
                    h:MoveTo(Vector3.new(facePos.X, r.Position.Y, facePos.Z))
                end

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
    bombHoldTimer = 0; bombChaseDelay = 0; bombChaseSet = false
    stuckCheckPos = nil; stuckCheckTime = 0; stuckNoclipCooldown = 0
    cleanupBombMove()
    timerSearched = false  -- re-scan timer reference each round
    task.wait(1)
    if cfg.Fly    then setupFly(true)    end
    if cfg.NoFall then setupNoFall(true) end
end)

Window:Label("Bomb Game")

Window:Toggle("Auto Pass Bomb", false, function(state)
    cfg.AutoPassBomb = state
    bombHoldTimer = 0; bombChaseDelay = 0; bombChaseSet = false
    stuckCheckPos = nil; stuckCheckTime = 0; stuckNoclipCooldown = 0
    cleanupBombMove()
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
