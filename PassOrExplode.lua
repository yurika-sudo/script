local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Library = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/miroeramaa/TurtleLib/main/TurtleUiLib.lua"
))()
local Window = Library:Window("POE Assist")

local cfg = {
    AutoPassBomb  = false,
    BombTeleport  = false,  -- instant CFrame to target when holding bomb
    Noclip        = false,
    SpeedEnabled  = false,
    Speed         = 20,
    NoFall        = false,
    FreeFly       = false,
    AutoPunch     = false,
}

local STOP_DIST  = 4    -- studs: stop chasing when this close
local NEAR_DIST  = 10   -- studs: switch from MoveTo to direct velocity
local PUNCH_RANGE = 6
local PUNCH_RATE  = 0.45
local FLY_SPEED   = 40

local moveTimer  = 0
local punchTimer = 0
local noFallBV   = nil
local freeFlyBV  = nil
local ghostActive = false

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

-- Noclip: upper body only, re-applied every frame so teleports don't break it
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
            if on  and p.CanCollide then p.CanCollide = false end
            if not on and not p.CanCollide then p.CanCollide = true end
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
            noFallBV    = bv
        end
    end
end

-- Free Fly: BodyVelocity, joystick = horizontal, camera pitch = vertical
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

    -- Speed
    local spd = (cfg.SpeedEnabled and not cfg.FreeFly) and cfg.Speed or 16
    if h.WalkSpeed ~= spd then h.WalkSpeed = spd end

    -- Ghost: re-apply every frame so teleports don't reset it
    if cfg.Noclip then
        applyNoclip(c, true)
    elseif ghostActive then
        applyNoclip(c, false)
    end

    -- Bomb Teleport: instant CFrame to target the moment we hold bomb
    if cfg.BombTeleport and hasBomb(c) then
        local target, _ = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh then
                -- Teleport next to target (offset slightly so not inside them)
                local dir = (r.Position - oh.Position)
                local offset = dir.Magnitude > 0 and dir.Unit * 3 or Vector3.new(3,0,0)
                r.CFrame = CFrame.new(oh.Position + offset)
            end
        end
    end

    -- Auto Pass Bomb: walk + last-mile direct velocity
    if cfg.AutoPassBomb and not cfg.BombTeleport and hasBomb(c) then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh and dist > STOP_DIST then
                if dist > NEAR_DIST then
                    -- Normal MoveTo when far
                    moveTimer = moveTimer + dt
                    if moveTimer >= 0.15 then
                        moveTimer = 0
                        h:MoveTo(oh.Position)
                    end
                else
                    -- Direct velocity push for last ~10 studs (no stutter)
                    local dir = (oh.Position - r.Position)
                    dir = Vector3.new(dir.X, 0, dir.Z).Unit
                    r.AssemblyLinearVelocity = Vector3.new(
                        dir.X * spd,
                        r.AssemblyLinearVelocity.Y,
                        dir.Z * spd
                    )
                end
            end
        end
    end

    -- No Fall
    if cfg.NoFall and noFallBV and r and not cfg.FreeFly then
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            noFallBV.MaxForce = Vector3.new(0, 1e6, 0)
            noFallBV.Velocity  = Vector3.new(0, 0, 0)
        else
            noFallBV.MaxForce = Vector3.new(0, 0, 0)
        end
    end

    -- Free Fly: joystick horizontal + camera pitch vertical
    if cfg.FreeFly and freeFlyBV and r then
        local cam     = workspace.CurrentCamera
        local moveDir = h.MoveDirection  -- world-space, camera-relative from joystick
        local pitchY  = cam.CFrame.LookVector.Y  -- -1 (down) to 1 (up)

        if moveDir.Magnitude > 0 then
            freeFlyBV.Velocity = Vector3.new(
                moveDir.X * FLY_SPEED,
                pitchY   * FLY_SPEED,  -- tilt camera = fly up/down
                moveDir.Z * FLY_SPEED
            )
        else
            freeFlyBV.Velocity = Vector3.new(0, 0, 0)  -- hover when idle
        end
    end

    -- Auto Punch (no PVP Mode gate)
    if cfg.AutoPunch and r then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh then
                if r.Position.Y - oh.Position.Y > 12 then return end
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
    task.wait(1)
    if cfg.FreeFly then setupFreeFly(true) end
    if cfg.NoFall  then setupNoFall(true) end
end)

-- UI: no labels, compact
Window:Toggle("Auto Pass Bomb", false, function(state)
    cfg.AutoPassBomb = state; moveTimer = 0
end)

Window:Toggle("Bomb Teleport", false, function(state)
    cfg.BombTeleport = state
end)

Window:Toggle("Ghost Mode", false, function(state)
    cfg.Noclip = state
    if not state and ghostActive then
        local c = getChar()
        if c then applyNoclip(c, false) end
    end
end)

Window:Toggle("Speed Boost", false, function(state)
    cfg.SpeedEnabled = state
end)

Window:Button("Speed  16", function() cfg.Speed = 16 end)
Window:Button("Speed  20", function() cfg.Speed = 20 end)
Window:Button("Speed  22", function() cfg.Speed = 22 end)

Window:Toggle("No Fall", false, function(state)
    cfg.NoFall = state
    setupNoFall(state)
end)

Window:Toggle("Free Fly", false, function(state)
    cfg.FreeFly = state
    setupFreeFly(state)
    -- Re-enable NoFall after fly is off
    if not state and cfg.NoFall then setupNoFall(true) end
end)

Window:Toggle("Auto Punch", false, function(state)
    cfg.AutoPunch = state; punchTimer = 0
end)
