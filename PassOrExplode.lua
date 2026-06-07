local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Library = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/miroeramaa/TurtleLib/main/TurtleUiLib.lua"
))()
local Window = Library:Window("Debug Flags")

-- Config
local SPEED_BOOST   = 22
local SPEED_DEFAULT = 16
local FLY_HEIGHT    = 14
local PUNCH_RANGE   = 6
local PUNCH_RATE    = 0.45

local cfg = {
    AutoPassBomb = false,
    SpeedBoost   = false,
    NoFall       = false,
    Fly          = false,
    PVPMode      = false,
    AutoPunch    = false,
}

local moveTimer   = 0
local punchTimer  = 0
local flyBP       = nil   -- BodyPosition for fly
local noFallForce = nil   -- BodyForce for true no-fall
local ghostActive = false -- noclip state tracking

-- Hardcoded remotes (scanned: 26 total)
local RS            = game:GetService("ReplicatedStorage")
local remoteAction  = RS:WaitForChild("ActionEvent", 10)
local remoteEndgame = RS:WaitForChild("EndgameAttackEvent", 10)

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
    local c = getChar()
    local h = getHRP(c)
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

-- [BUG 3 FIX] True No Fall via BodyForce that cancels gravity exactly
-- mass × gravity = upward force needed to float perfectly
local function setupNoFall(enable)
    local r = getHRP(getChar())
    if noFallForce then
        pcall(function() noFallForce:Destroy() end)
        noFallForce = nil
    end
    if enable and r then
        local bf   = Instance.new("BodyForce")
        bf.Name    = "NoFallForce"
        local mass = r.AssemblyMass
        if mass <= 0 then mass = 20 end  -- fallback if AssemblyMass unavailable
        -- +30 margin so gravity never wins; won't cause lift since it's not a net upward force
        bf.Force   = Vector3.new(0, mass * workspace.Gravity + 30, 0)
        bf.Parent  = r
        noFallForce = bf
    end
end

-- Fly: BodyPosition with damping (D value prevents oscillation)
local function setupFly(enable)
    if flyBP then
        pcall(function() flyBP:Destroy() end)
        flyBP = nil
    end
    if enable then
        local r = getHRP(getChar())
        if r then
            local bp    = Instance.new("BodyPosition")
            bp.Name     = "FlyBP"
            bp.MaxForce = Vector3.new(0, 1e5, 0)  -- Y only, humanoid handles XZ
            bp.P        = 8000
            bp.D        = 600  -- damping = no oscillation
            bp.Position = r.Position
            bp.Parent   = r
            flyBP = bp
        end
    end
end

local function updateFly()
    local c = getChar()
    local r = getHRP(c)
    if not r or not flyBP then return end
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {c}
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ray     = workspace:Raycast(r.Position, Vector3.new(0, -150, 0), params)
    local groundY = ray and ray.Position.Y or (r.Position.Y - FLY_HEIGHT)
    flyBP.Position = Vector3.new(r.Position.X, groundY + FLY_HEIGHT, r.Position.Z)
end

-- [BUG 1 FIX] Noclip: set all parts CanCollide = false when holding bomb
-- Restored when bomb is passed / auto pass disabled
local function setNoclip(c, enable)
    for _, part in ipairs(c:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = not enable
        end
    end
    ghostActive = enable
end

local function firePunch(targetChar, targetHRP)
    if remoteAction then
        pcall(function() remoteAction:FireServer("Punch") end)
        pcall(function() remoteAction:FireServer("Attack") end)
        pcall(function() remoteAction:FireServer("punch", targetChar) end)
        pcall(function() remoteAction:FireServer("attack", targetChar) end)
    end
    if remoteEndgame then
        pcall(function() remoteEndgame:FireServer(targetChar) end)
        pcall(function() remoteEndgame:FireServer(targetHRP.Position) end)
        pcall(function() remoteEndgame:FireServer() end)
    end
end

-- Main loop
RunService.Heartbeat:Connect(function(dt)
    local c = getChar()
    local h = getHum(c)
    if not h or h.Health <= 0 then return end
    local r = getHRP(c)

    -- Persistent speed
    local spd = cfg.SpeedBoost and SPEED_BOOST or SPEED_DEFAULT
    if h.WalkSpeed ~= spd then h.WalkSpeed = spd end

    -- Auto Pass Bomb
    if cfg.AutoPassBomb then
        local holding = hasBomb(c)

        -- [BUG 1] Noclip on/off based on whether holding bomb
        if holding and not ghostActive then
            setNoclip(c, true)
        elseif not holding and ghostActive then
            setNoclip(c, false)
        end

        -- [BUG 2] Suppress fly while holding bomb so character can descend to target
        if holding and flyBP then
            flyBP.MaxForce = Vector3.new(0, 0, 0)  -- pause fly force
        elseif not holding and cfg.Fly and flyBP then
            flyBP.MaxForce = Vector3.new(0, 1e5, 0) -- resume fly force
        end

        if holding then
            moveTimer = moveTimer + dt
            if moveTimer >= 0.15 then
                moveTimer = 0
                local target = nearestPlayer()
                if target and target.Character then
                    local oh = getHRP(target.Character)
                    if oh then h:MoveTo(oh.Position) end
                end
            end
        end
    elseif ghostActive then
        -- Auto pass disabled mid-flight: restore collision
        setNoclip(c, false)
    end

    -- [BUG 3] True No Fall: BodyForce handles it passively, no per-frame velocity hack needed
    -- setupNoFall handles the physics object; nothing to do here

    -- Fly (only when not suppressed by bomb)
    if cfg.Fly and not (cfg.AutoPassBomb and hasBomb(c)) then
        updateFly()
    end

    -- Auto Punch (PVP only)
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
end)

LocalPlayer.CharacterAdded:Connect(function()
    flyBP       = nil
    noFallForce = nil
    ghostActive = false
    task.wait(1)
    if cfg.Fly    then setupFly(true) end
    if cfg.NoFall then setupNoFall(true) end
end)

-- UI
Window:Label("--- Bomb Game ---")

Window:Toggle("Auto Pass Bomb", false, function(state)
    cfg.AutoPassBomb = state
    moveTimer = 0
    if not state and ghostActive then
        local c = getChar()
        if c then setNoclip(c, false) end
    end
end)

Window:Toggle("Walk Speed Boost", false, function(state)
    cfg.SpeedBoost = state
end)

Window:Label("--- PVP ---")

Window:Toggle("PVP Mode (enable in arena)", false, function(state)
    cfg.PVPMode = state
    punchTimer  = 0
end)

Window:Toggle("No Fall", false, function(state)
    cfg.NoFall = state
    setupNoFall(state)
end)

Window:Toggle("Fly Mode", false, function(state)
    cfg.Fly = state
    setupFly(state)
    -- Fly supersedes NoFall (redundant together)
    if state and noFallForce then
        setupNoFall(false)
        cfg.NoFall = false
    end
end)

Window:Toggle("Auto Punch", false, function(state)
    cfg.AutoPunch = state
    punchTimer    = 0
end)
