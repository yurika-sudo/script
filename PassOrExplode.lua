local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Library = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/miroeramaa/TurtleLib/main/TurtleUiLib.lua"
))()
local Window = Library:Window("POE Assist")

local cfg = {
    AutoPassBomb = false,
    BombTeleport = false,
    Noclip       = false,
    SpeedEnabled = false,
    NoFall       = false,
    FreeFly      = false,
    AutoPunch    = false,
}

-- Speed auto-management (no manual buttons needed):
-- SpeedEnabled ON  + holding bomb → 22 (full chase speed)
-- SpeedEnabled ON  + idle         → 20 (subtle)
-- SpeedEnabled OFF                → 16 (game default)
local SPEED_BOMB    = 22
local SPEED_IDLE    = 20
local SPEED_DEFAULT = 16

-- Only target players within this distance (filters lobby spectators)
local MAX_TARGET_DIST = 200

-- Max Y difference to consider a player in the same arena (filters lobby/spectators when NoFall is on)
local MAX_Y_DIFF = 15

local STOP_DIST   = 4
local NEAR_DIST   = 10
local PUNCH_RANGE = 6
local PUNCH_RATE  = 0.45
local FLY_SPEED   = 40

local moveTimer      = 0
local punchTimer     = 0
local teleportTimer  = 0
local noclipTimer    = 0
local noFallBV       = nil
local freeFlyBV      = nil
local ghostActive    = false

-- UI toggle references — needed so CharacterAdded can sync toggle state
local toggleAutoPunch = nil

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

-- Filter: only in-round players (alive, within MAX_TARGET_DIST, not spectating)
-- requireSameHeight: if true, also filters players outside MAX_Y_DIFF vertically
-- Used by AutoPunch to avoid targeting lobby/spectator players when NoFall lifts us off arena
local function nearestPlayer(requireSameHeight)
    local c = getChar(); local h = getHRP(c)
    if not h then return nil, math.huge end
    local best, bestDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local oh = getHRP(p.Character)
            local ph = getHum(p.Character)
            if oh and ph and ph.Health > 0 then
                local d = (h.Position - oh.Position).Magnitude
                local yDiff = math.abs(h.Position.Y - oh.Position.Y)
                local heightOk = (not requireSameHeight) or (yDiff <= MAX_Y_DIFF)
                if d < bestDist and d <= MAX_TARGET_DIST and heightOk then
                    bestDist = d
                    best = p
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
    if enable then
        local r = getHRP(getChar())
        if r then
            local bv    = Instance.new("BodyVelocity")
            bv.Name     = "NoFallBV"
            bv.Velocity = Vector3.new(0, 0, 0)
            bv.MaxForce = Vector3.new(0, 0, 0)
            bv.Parent   = r
            noFallBV    = bv
        end
    end
end

local function setupFreeFly(enable)
    if freeFlyBV then pcall(function() freeFlyBV:Destroy() end); freeFlyBV = nil end
    if enable then
        local r = getHRP(getChar())
        if r then
            local bv    = Instance.new("BodyVelocity")
            bv.Name     = "FreeFlyBV"
            bv.MaxForce = Vector3.new(1e6, 1e6, 1e6)
            bv.Velocity = Vector3.new(0, 0, 0)
            bv.Parent   = r
            freeFlyBV   = bv
        end
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
end

-- Debug overlay: live distance + nearby player count
-- Defined before Heartbeat so debugLabel is never nil when the loop runs
local debugGui   = Instance.new("ScreenGui")
debugGui.Name    = "POEDebug"
debugGui.ResetOnSpawn = false
debugGui.Parent  = LocalPlayer.PlayerGui

local debugLabel = Instance.new("TextLabel")
debugLabel.Size                   = UDim2.new(0, 180, 0, 70)
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

RunService.Heartbeat:Connect(function(dt)
    local c = getChar(); local h = getHum(c)
    if not h or h.Health <= 0 then return end
    local r = getHRP(c)

    local holding = hasBomb(c)

    -- Auto speed: bomb = 22, idle = 20, off = 16
    local targetSpd = SPEED_DEFAULT
    if cfg.SpeedEnabled then
        targetSpd = (holding and (cfg.AutoPassBomb or cfg.BombTeleport))
            and SPEED_BOMB or SPEED_IDLE
    end
    if h.WalkSpeed ~= targetSpd then h.WalkSpeed = targetSpd end

    -- Ghost: re-apply every 0.3s so teleports/rewards don't reset it
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

    -- Bomb Teleport: appear in front of target, face them
    -- 0.25s cooldown to avoid physics spam
    if cfg.BombTeleport and holding then
        teleportTimer = teleportTimer + dt
        if teleportTimer >= 0.25 then
            teleportTimer = 0
            local target, _ = nearestPlayer()
            if target and target.Character then
                local oh = getHRP(target.Character)
                if oh then
                    -- Stand in front of where target is facing, look at them
                    local facing = oh.CFrame.LookVector
                    local newPos = oh.Position + Vector3.new(facing.X, 0, facing.Z) * 3
                    r.CFrame = CFrame.new(newPos, oh.Position)
                end
            end
        end
    else
        teleportTimer = 0
    end

    -- Auto Pass Bomb: directly face + walk toward target every frame
    -- Bypasses MoveTo acceleration curve so movement is instant full-speed,
    -- matching manual joystick feel without the internal deceleration window
    if cfg.AutoPassBomb and not cfg.BombTeleport and holding then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh and dist > STOP_DIST then
                -- Face target (Y-locked so we don't tilt up/down on height diff)
                local lookAt = Vector3.new(oh.Position.X, r.Position.Y, oh.Position.Z)
                r.CFrame = CFrame.new(r.Position, lookAt)
                -- Drive movement via MoveDirection — full speed, no ramp-up
                h:Move(Vector3.new(
                    oh.Position.X - r.Position.X,
                    0,
                    oh.Position.Z - r.Position.Z
                ).Unit, false)
            else
                h:Move(Vector3.new(0, 0, 0), false)
            end
        end
    end

    -- No Fall (skip if FreeFly handles Y)
    if cfg.NoFall and noFallBV and r and not cfg.FreeFly then
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            noFallBV.MaxForce = Vector3.new(0, 1e6, 0)
            noFallBV.Velocity  = Vector3.new(0, 0, 0)
        else
            noFallBV.MaxForce = Vector3.new(0, 0, 0)
        end
    end

    -- Free Fly: suppress while chasing bomb (need to descend to target)
    local bombChasing = holding and (cfg.AutoPassBomb or cfg.BombTeleport)
    if cfg.FreeFly and freeFlyBV and r then
        if bombChasing then
            freeFlyBV.MaxForce = Vector3.new(0, 0, 0)  -- suspend
        else
            freeFlyBV.MaxForce = Vector3.new(1e6, 1e6, 1e6)
            local cam     = workspace.CurrentCamera
            local moveDir = h.MoveDirection
            local pitchY  = cam.CFrame.LookVector.Y
            if moveDir.Magnitude > 0 then
                freeFlyBV.Velocity = Vector3.new(
                    moveDir.X * FLY_SPEED,
                    pitchY   * FLY_SPEED,
                    moveDir.Z * FLY_SPEED
                )
            else
                freeFlyBV.Velocity = Vector3.new(0, 0, 0)
            end
        end
    end

    -- Auto Punch: requireSameHeight=true to avoid targeting lobby/spectator players
    -- especially when NoFall keeps us elevated above the arena floor
    if cfg.AutoPunch and r then
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

    -- Debug label update (single loop, no duplicate Heartbeat)
    local nearest2, dist2 = nearestPlayer()
    local distStr = dist2 == math.huge and "--" or string.format("%.1f", dist2)
    local zoneStr = dist2 <= STOP_DIST and "STOP"
                 or dist2 <= NEAR_DIST  and "CLOSE"
                 or "FAR"
    local count = 0
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character and getHRP(p.Character) then
            count = count + 1
        end
    end
    debugLabel.Text = string.format(
        "dist: %s (%s)\nbomb: %s\nplayers: %d",
        distStr, zoneStr, holding and "YES" or "no", count
    )
end)

-- CharacterAdded: reset physics objects + auto-disable AutoPunch
-- AutoPunch uses VIM mouse events — if it fires during lobby teleport it
-- lands on the virtual joystick area and locks input until toggled off
LocalPlayer.CharacterAdded:Connect(function()
    noFallBV = nil; freeFlyBV = nil; ghostActive = false
    noclipTimer = 0; teleportTimer = 0; punchTimer = 0

    -- Disable AutoPunch on respawn/teleport to lobby so VIM clicks
    -- don't overlap the joystick and break movement controls
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

-- UI
Window:Toggle("Auto Pass Bomb",  false, function(state) cfg.AutoPassBomb = state; moveTimer = 0 end)
Window:Toggle("Bomb Teleport",   false, function(state) cfg.BombTeleport = state end)
Window:Toggle("Ghost Mode",      false, function(state)
    cfg.Noclip = state
    if not state and ghostActive then
        local c = getChar(); if c then applyNoclip(c, false) end
    end
end)
Window:Toggle("Speed Boost",     false, function(state) cfg.SpeedEnabled = state end)
Window:Toggle("No Fall",         false, function(state) cfg.NoFall = state; setupNoFall(state) end)
Window:Toggle("Free Fly",        false, function(state)
    cfg.FreeFly = state
    setupFreeFly(state)
    if not state and cfg.NoFall then setupNoFall(true) end
end)
-- Store reference so CharacterAdded can sync the toggle UI state
toggleAutoPunch = Window:Toggle("Auto Punch", false, function(state)
    cfg.AutoPunch = state
    punchTimer = 0
end)
