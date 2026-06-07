local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Library = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/miroeramaa/TurtleLib/main/TurtleUiLib.lua"
))()
local Window = Library:Window("Debug Flags")

-- Config
local SPEED_DEFAULT = 16
local SPEED_BOOST   = 20
local JUMP_BOOST    = 75

local cfg = {
    AutoPassBomb = false,
    JumpBoost    = false,
    SpeedBoost   = false,
    FloatMidAir  = false,
}

local moveTimer = 0

local function getChar() return LocalPlayer.Character end
local function getHum(c) return c and c:FindFirstChildOfClass("Humanoid") end
local function getHRP(c) return c and c:FindFirstChild("HumanoidRootPart") end

local function targetSpeed()
    return cfg.SpeedBoost and SPEED_BOOST or SPEED_DEFAULT
end

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
    if not h then return nil end
    local best, bestDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character then
            local oh = getHRP(p.Character)
            if oh then
                local d = (h.Position - oh.Position).Magnitude
                if d < bestDist then
                    bestDist = d
                    best = p
                end
            end
        end
    end
    return best
end

RunService.Heartbeat:Connect(function(dt)
    local c = getChar()
    local h = getHum(c)
    if not h or h.Health <= 0 then return end

    local spd = targetSpeed()
    if h.WalkSpeed ~= spd then h.WalkSpeed = spd end

    if cfg.JumpBoost then
        if h.JumpPower ~= JUMP_BOOST then h.JumpPower = JUMP_BOOST end
    end

    if cfg.FloatMidAir then
        local r = getHRP(c)
        if r then
            local vel = r.AssemblyLinearVelocity
            if vel.Y < 0 then
                r.AssemblyLinearVelocity = Vector3.new(vel.X, 0, vel.Z)
            end
        end
    end

    if cfg.AutoPassBomb and hasBomb(c) then
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
end)

LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(0.5)
    local h = char:FindFirstChildOfClass("Humanoid")
    if h then h.JumpPower = 50 end
end)

Window:Toggle("auto_pass_bomb", false, function(state)
    cfg.AutoPassBomb = state
    moveTimer = 0
end)

Window:Toggle("jump_boost", false, function(state)
    cfg.JumpBoost = state
    if not state then
        local h = getHum(getChar())
        if h then h.JumpPower = 50 end
    end
end)

Window:Toggle("walk_speed_override", false, function(state)
    cfg.SpeedBoost = state
end)

Window:Toggle("float_midair", false, function(state)
    cfg.FloatMidAir = state
end)
