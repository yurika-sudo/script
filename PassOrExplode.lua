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
local function nearestPlayer()
    local c = getChar(); local h = getHRP(c)
    if not h then return nil, math.huge end
    local best, bestDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local oh  = getHRP(p.Character)
            local ph  = getHum(p.Character)
            if oh and ph and ph.Health > 0 then
                local d = (h.Position - oh.Position).Magnitude
                if d < bestDist and d <= MAX_TARGET_DIST then
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

    -- Auto Pass Bomb (walk):
    -- Far  (dist > 10): MoveTo for natural navigation
    -- Close (dist 4-10): Humanoid:Move() at full WalkSpeed, no deceleration
    -- Stop (dist <= 4):  Humanoid:Move(zero) to halt
    if cfg.AutoPassBomb and not cfg.BombTeleport and holding then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh then
                if dist > NEAR_DIST then
                    moveTimer = moveTimer + dt
                    if moveTimer >= 0.15 then
                        moveTimer = 0
                        h:MoveTo(oh.Position)
                    end
                elseif dist > STOP_DIST then
                    -- Full speed last-mile, no slowdown
                    local dir = Vector3.new(
                        oh.Position.X - r.Position.X,
                        0,
                        oh.Position.Z - r.Position.Z
                    ).Unit
                    h:Move(dir, false)
                else
                    h:Move(Vector3.zero, false)
                end
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

    -- Auto Punch: enable only when needed (PVP), filters non-arena players
    if cfg.AutoPunch and r then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh and r.Position.Y - oh.Position.Y <= 12 then
                if dist > STOP_DIST then h:MoveTo(oh.Position) end
                punchTimer = punchTimer + dt
                if dist <= PUNCH_RANGE and punchTimer >= PUNCH_RATE then
                    punchTimer = 0
                    firePunch(target.Character, oh)
                end
            end
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    noFallBV = nil; freeFlyBV = nil; ghostActive = false
    noclipTimer = 0; teleportTimer = 0
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
Window:Toggle("Auto Punch",      false, function(state) cfg.AutoPunch = state; punchTimer = 0 end)
