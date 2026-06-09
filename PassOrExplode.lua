local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local RS          = game:GetService("ReplicatedStorage")
local VIM         = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

local Library = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/miroeramaa/TurtleLib/main/TurtleUiLib.lua"
))()
local Window = Library:Window("POE Assist")

-- ── Config flags ──────────────────────────────────────────────────────────────
local cfg = {
    AutoPassBomb = false,
    BombTeleport = false,
    Noclip       = false,
    SpeedEnabled = false,
    NoFall       = false,
    FreeFly      = false,
    AutoPunch    = false,
}

-- ── Tunable constants ─────────────────────────────────────────────────────────
local SPEED_BOMB    = 22   -- walkspeed while chasing to pass bomb
local SPEED_IDLE    = 20   -- walkspeed when speed boost on but not chasing
local SPEED_DEFAULT = 16   -- game default

local MAX_TARGET_DIST = 200  -- ignore players further than this (studs)
local MAX_Y_DIFF      = 15   -- max vertical diff to consider same arena

local STOP_DIST   = 4    -- stop chasing when this close (studs)
local NEAR_DIST   = 10   -- "CLOSE" zone label threshold
local PUNCH_RANGE = 6    -- fire punch when within this range
local PUNCH_RATE  = 0.45 -- seconds between punch attempts
local FLY_SPEED   = 40

-- ── State ─────────────────────────────────────────────────────────────────────
local punchTimer    = 0
local teleportTimer = 0
local noclipTimer   = 0
local noFallBV      = nil
local freeFlyBV     = nil
local ghostActive   = false
local toggleAutoPunch = nil  -- UI ref for CharacterAdded sync

-- ── Confirmed remotes (path verified via scan) ────────────────────────────────
local remoteAction  = nil
local remoteEndgame = nil
task.spawn(function()
    local events = RS:WaitForChild("Remotes", 10)
        and RS.Remotes:WaitForChild("Events", 10)
    if not events then return end
    remoteAction  = events:WaitForChild("ActionEvent",      10)
    remoteEndgame = events:WaitForChild("EndgameAttackEvent", 10)
end)

-- ── Helpers ───────────────────────────────────────────────────────────────────
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
    return ok and val == true
end

-- Returns nearest alive player.
-- requireSameHeight=true: skip players whose Y differs by more than MAX_Y_DIFF
-- (prevents targeting lobby spectators when NoFall keeps us elevated)
local function nearestPlayer(requireSameHeight)
    local c = getChar(); local h = getHRP(c)
    if not h then return nil, math.huge end
    local best, bestDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local oh = getHRP(p.Character)
            local ph = getHum(p.Character)
            if oh and ph and ph.Health > 0 then
                local d     = (h.Position - oh.Position).Magnitude
                local yDiff = math.abs(h.Position.Y - oh.Position.Y)
                local heightOk = (not requireSameHeight) or (yDiff <= MAX_Y_DIFF)
                if d < bestDist and d <= MAX_TARGET_DIST and heightOk then
                    bestDist = d
                    best     = p
                end
            end
        end
    end
    return best, bestDist
end

local LEG_NAMES = {
    "LeftFoot","RightFoot","LeftLowerLeg","RightLowerLeg",
    "LeftUpperLeg","RightUpperLeg","Left Leg","Right Leg",
}
local function isLeg(name)
    for _, n in ipairs(LEG_NAMES) do if name == n then return true end end
    return false
end

local function applyNoclip(c, on)
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and not isLeg(p.Name) then
            if on  and p.CanCollide       then p.CanCollide = false end
            if not on and not p.CanCollide then p.CanCollide = true  end
        end
    end
    ghostActive = on
end

local function setupNoFall(enable)
    if noFallBV then pcall(function() noFallBV:Destroy() end); noFallBV = nil end
    if not enable then return end
    local r = getHRP(getChar())
    if not r then return end
    local bv    = Instance.new("BodyVelocity")
    bv.Name     = "NoFallBV"
    bv.Velocity = Vector3.new(0, 0, 0)
    bv.MaxForce = Vector3.new(0, 0, 0)
    bv.Parent   = r
    noFallBV    = bv
end

local function setupFreeFly(enable)
    if freeFlyBV then pcall(function() freeFlyBV:Destroy() end); freeFlyBV = nil end
    if not enable then return end
    local r = getHRP(getChar())
    if not r then return end
    local bv    = Instance.new("BodyVelocity")
    bv.Name     = "FreeFlyBV"
    bv.MaxForce = Vector3.new(1e6, 1e6, 1e6)
    bv.Velocity = Vector3.new(0, 0, 0)
    bv.Parent   = r
    freeFlyBV   = bv
end

-- Fires punch via confirmed remotes + VIM screen tap at target position
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
end

-- ── Minimal debug label ───────────────────────────────────────────────────────
-- Shows: dist to nearest / bomb status / player count / own Y
-- Small footprint, no scan panel, no exports
local debugGui = Instance.new("ScreenGui")
debugGui.Name         = "POEDebug"
debugGui.ResetOnSpawn = false
debugGui.Parent       = LocalPlayer.PlayerGui

local debugLabel = Instance.new("TextLabel")
debugLabel.Size                   = UDim2.new(0, 200, 0, 72)
debugLabel.Position               = UDim2.new(0, 8, 0.45, 0)
debugLabel.BackgroundColor3       = Color3.fromRGB(0, 0, 0)
debugLabel.BackgroundTransparency = 0.45
debugLabel.TextColor3             = Color3.fromRGB(100, 255, 100)
debugLabel.TextSize               = 13
debugLabel.Font                   = Enum.Font.Code
debugLabel.TextXAlignment         = Enum.TextXAlignment.Left
debugLabel.TextYAlignment         = Enum.TextYAlignment.Top
debugLabel.Text                   = "initializing..."
debugLabel.BorderSizePixel        = 0
debugLabel.Parent                 = debugGui

-- ── Main loop ─────────────────────────────────────────────────────────────────
RunService.Heartbeat:Connect(function(dt)
    local c = getChar(); local h = getHum(c)
    if not h or h.Health <= 0 then return end
    local r = getHRP(c)
    if not r then return end

    local holding = hasBomb(c)

    -- Speed management
    local targetSpd = SPEED_DEFAULT
    if cfg.SpeedEnabled then
        targetSpd = (holding and (cfg.AutoPassBomb or cfg.BombTeleport))
            and SPEED_BOMB or SPEED_IDLE
    end
    if h.WalkSpeed ~= targetSpd then h.WalkSpeed = targetSpd end

    -- Ghost: re-apply every 0.3s so round transitions don't reset it
    if cfg.Noclip then
        noclipTimer = noclipTimer + dt
        if noclipTimer >= 0.3 then
            noclipTimer = 0
            applyNoclip(c, true)
        end
    elseif ghostActive then
        applyNoclip(c, false)
        noclipTimer = 0
    end

    -- Bomb Teleport: snap in front of nearest same-height player
    -- 0.25s cooldown; post-teleport Y-drop safety snaps back if we fell off arena
    if cfg.BombTeleport and holding then
        teleportTimer = teleportTimer + dt
        if teleportTimer >= 0.25 then
            teleportTimer = 0
            local target, _ = nearestPlayer(true)
            if target and target.Character then
                local oh = getHRP(target.Character)
                if oh then
                    local preY  = r.Position.Y
                    local preCF = r.CFrame
                    local dir   = oh.CFrame.LookVector
                    r.CFrame    = CFrame.new(
                        oh.Position + Vector3.new(dir.X, 0, dir.Z) * 3,
                        oh.Position)
                    task.defer(function()
                        local pr = getHRP(getChar())
                        if pr and (preY - pr.Position.Y) > 12 then
                            pr.CFrame = preCF
                        end
                    end)
                end
            end
        end
    else
        teleportTimer = 0
    end

    -- Auto Pass Bomb: overshoot MoveTo so Humanoid never enters deceleration zone
    if cfg.AutoPassBomb and not cfg.BombTeleport and holding then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh and dist > STOP_DIST then
                local dirXZ = Vector3.new(
                    oh.Position.X - r.Position.X, 0,
                    oh.Position.Z - r.Position.Z)
                h:MoveTo(oh.Position + dirXZ.Unit * 8)
            end
        end
    end

    -- No Fall: cancel downward velocity (skip if FreeFly is active)
    if cfg.NoFall and noFallBV and not cfg.FreeFly then
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            noFallBV.MaxForce = Vector3.new(0, 1e6, 0)
            noFallBV.Velocity = Vector3.new(0, 0, 0)
        else
            noFallBV.MaxForce = Vector3.new(0, 0, 0)
        end
    end

    -- Free Fly: suspend while actively chasing to pass bomb
    local bombChasing = holding and (cfg.AutoPassBomb or cfg.BombTeleport)
    if cfg.FreeFly and freeFlyBV then
        if bombChasing then
            freeFlyBV.MaxForce = Vector3.new(0, 0, 0)
        else
            freeFlyBV.MaxForce = Vector3.new(1e6, 1e6, 1e6)
            local cam     = workspace.CurrentCamera
            local moveDir = h.MoveDirection
            local pitchY  = cam.CFrame.LookVector.Y
            freeFlyBV.Velocity = moveDir.Magnitude > 0
                and Vector3.new(moveDir.X * FLY_SPEED, pitchY * FLY_SPEED, moveDir.Z * FLY_SPEED)
                or  Vector3.new(0, 0, 0)
        end
    end

    -- Auto Punch: height-filtered to avoid targeting lobby/spectator players
    if cfg.AutoPunch then
        local target, dist = nearestPlayer(true)
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh then
                if dist > STOP_DIST then h:MoveTo(oh.Position) end
                punchTimer = punchTimer + dt
                if dist <= PUNCH_RANGE and punchTimer >= PUNCH_RATE then
                    punchTimer = 0
                    firePunch(target.Character, oh)
                end
            end
        end
    end

    -- Debug label update
    local _, dist2 = nearestPlayer()
    local distStr  = dist2 == math.huge and "--" or string.format("%.1f", dist2)
    local zoneStr  = dist2 <= STOP_DIST and "STOP"
                  or dist2 <= NEAR_DIST  and "CLOSE"
                  or "FAR"
    local count = 0
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character and getHRP(p.Character) then
            count = count + 1
        end
    end
    debugLabel.Text = string.format(
        "dist: %s (%s)\nbomb: %s\nplayers: %d\nY: %.1f",
        distStr, zoneStr,
        holding and "YES" or "no",
        count, r.Position.Y)
end)

-- ── CharacterAdded ────────────────────────────────────────────────────────────
-- Reset physics state + auto-disable AutoPunch so VIM clicks don't land on
-- the virtual joystick after lobby teleport
LocalPlayer.CharacterAdded:Connect(function()
    noFallBV = nil; freeFlyBV = nil; ghostActive = false
    noclipTimer = 0; teleportTimer = 0; punchTimer = 0

    if cfg.AutoPunch then
        cfg.AutoPunch = false
        if toggleAutoPunch then
            pcall(function() toggleAutoPunch:Set(false) end)
        end
    end

    task.wait(1)
    if cfg.FreeFly then setupFreeFly(true) end
    if cfg.NoFall  then setupNoFall(true)  end
end)

-- ── UI ────────────────────────────────────────────────────────────────────────
Window:Toggle("Auto Pass Bomb", false, function(s) cfg.AutoPassBomb = s end)
Window:Toggle("Bomb Teleport",  false, function(s) cfg.BombTeleport = s end)
Window:Toggle("Ghost Mode",     false, function(s)
    cfg.Noclip = s
    if not s and ghostActive then
        local c = getChar(); if c then applyNoclip(c, false) end
    end
end)
Window:Toggle("Speed Boost",    false, function(s) cfg.SpeedEnabled = s end)
Window:Toggle("No Fall",        false, function(s) cfg.NoFall = s; setupNoFall(s) end)
Window:Toggle("Free Fly",       false, function(s)
    cfg.FreeFly = s
    setupFreeFly(s)
    if not s and cfg.NoFall then setupNoFall(true) end
end)
toggleAutoPunch = Window:Toggle("Auto Punch", false, function(s)
    cfg.AutoPunch = s
    punchTimer    = 0
end)
