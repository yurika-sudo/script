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
}

local FLY_HEIGHT  = 14
local PUNCH_RANGE = 6
local PUNCH_RATE  = 0.45

local moveTimer      = 0
local bombHoldTimer  = 0
local bombChaseDelay = 0
local punchTimer     = 0
local flyBP          = nil
local noFallBV       = nil
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
-- vel.Y < 0 (falling)  → MaxForce active, velocity locked to 0
-- vel.Y >= 0 (jumping) → MaxForce = 0, normal physics
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

-- Fly: BodyPosition with damping (no oscillation)
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

-- Punch: remotes + VirtualInputManager tap + GUI button scan
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

            if bombChaseDelay == 0 then
                bombChaseDelay = math.random(7, 10)
            end

            if flyBP then flyBP.MaxForce = Vector3.new(0, 0, 0) end

            -- FIX: removed "closeEnough" bypass (was dist <= spd*1.5 ≈ 24 studs,
            -- almost always true in a small arena → delay never actually waited)
            if bombHoldTimer >= bombChaseDelay then
                local target, _ = nearestPlayer()
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
                moveTimer      = 0  -- FIX: was not reset, causing early first-tick fire next hold
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

    -- Fly (suppressed while holding bomb so character can descend to reach target)
    if cfg.Fly and not (cfg.AutoPassBomb and hasBomb(c)) then updateFly() end

    -- Auto Punch (PVP only)
    if cfg.AutoPunch and cfg.PVPMode and r then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            -- FIX: original only filtered "we are 12+ above target"; math.abs covers
            -- both directions so spectators above us are also excluded
            if oh and math.abs(r.Position.Y - oh.Position.Y) <= 12 then
                h:MoveTo(oh.Position)
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
    flyBP = nil; noFallBV = nil; ghostActive = false
    bombHoldTimer = 0; bombChaseDelay = 0; moveTimer = 0
    task.wait(1)
    if cfg.Fly    then setupFly(true)    end
    if cfg.NoFall then setupNoFall(true) end
end)

-- UI
Window:Label("💣  Bomb Game")

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

Window:Label("⚡  Speed")

Window:Toggle("Speed Boost", false, function(state)
    cfg.SpeedEnabled = state
end)

Window:Button("16  —  Default", function() cfg.Speed = 16 end)
Window:Button("20  —  Subtle",  function() cfg.Speed = 20 end)
Window:Button("22  —  Safe Max",function() cfg.Speed = 22 end)

Window:Label("⚔️  PVP")

Window:Toggle("PVP Mode", false, function(state)
    cfg.PVPMode = state
    punchTimer  = 0
end)

Window:Toggle("Auto Punch", false, function(state)
    cfg.AutoPunch = state
    punchTimer    = 0
end)

Window:Label("🛡️  Utility")

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
