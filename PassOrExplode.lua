local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

local Library = loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/miroeramaa/TurtleLib/main/TurtleUiLib.lua"
))()
local Window = Library:Window("Debug Flags")

-- Config
local SPEED_BOOST  = 22
local SPEED_DEFAULT = 16
local FLY_HEIGHT   = 12   -- studs above ground while flying
local PUNCH_RANGE  = 6    -- studs, trigger punch within this distance
local PUNCH_RATE   = 0.45 -- seconds between punches

local cfg = {
    AutoPassBomb = false,
    SpeedBoost   = false,
    FloatMidAir  = false,
    Fly          = false,
    AutoPunch    = false,
}

local moveTimer  = 0
local punchTimer = 0
local punchRemote = nil  -- cached after first scan

-- Helpers
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
    return best, bestDist or math.huge
end

-- Scan ReplicatedStorage once for a punch-related RemoteEvent
local function findPunchRemote()
    if punchRemote then return punchRemote end
    local rs = game:GetService("ReplicatedStorage")
    local keywords = {"punch", "attack", "hit", "fight", "damage", "combat"}
    for _, v in ipairs(rs:GetDescendants()) do
        if v:IsA("RemoteEvent") then
            local name = v.Name:lower()
            for _, kw in ipairs(keywords) do
                if name:find(kw) then
                    punchRemote = v
                    return v
                end
            end
        end
    end
    return nil
end

RunService.Heartbeat:Connect(function(dt)
    local c = getChar()
    local h = getHum(c)
    if not h or h.Health <= 0 then return end
    local r = getHRP(c)

    -- Walk Speed (persistent — re-applies every frame if game overrides it)
    local targetSpd = cfg.SpeedBoost and SPEED_BOOST or SPEED_DEFAULT
    if h.WalkSpeed ~= targetSpd then h.WalkSpeed = targetSpd end

    -- Auto Pass Bomb: walk toward nearest player naturally
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

    -- Float Mid-Air: cancel downward velocity (useful in PVP to not fall off)
    if cfg.FloatMidAir and r then
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            r.AssemblyLinearVelocity = Vector3.new(vel.X, 0, vel.Z)
        end
    end

    -- Fly: hover at fixed height above ground, normal joystick movement
    if cfg.Fly and r then
        local rayResult = workspace:Raycast(
            r.Position,
            Vector3.new(0, -100, 0),
            RaycastParams.new()  -- exclude character not needed here
        )
        local groundY = rayResult and rayResult.Position.Y or (r.Position.Y - FLY_HEIGHT)
        local targetY = groundY + FLY_HEIGHT
        local dy = targetY - r.Position.Y
        local vel = r.AssemblyLinearVelocity
        r.AssemblyLinearVelocity = Vector3.new(vel.X, dy * 10, vel.Z)
    end

    -- Auto Punch: stay on target + punch when in range
    if cfg.AutoPunch then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh then
                -- Always move toward target
                h:MoveTo(oh.Position)

                -- Punch when close enough
                punchTimer = punchTimer + dt
                if dist <= PUNCH_RANGE and punchTimer >= PUNCH_RATE then
                    punchTimer = 0
                    -- Try RemoteEvent first
                    local remote = findPunchRemote()
                    if remote then
                        pcall(function() remote:FireServer(oh.Position) end)
                        pcall(function() remote:FireServer(target.Character) end)
                        pcall(function() remote:FireServer() end)
                    end
                    -- Fallback: activate any equipped Tool
                    for _, v in ipairs(c:GetChildren()) do
                        if v:IsA("Tool") then
                            pcall(function() v:Activate() end)
                        end
                    end
                end
            end
        end
    end
end)

LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(0.5)
    punchRemote = nil  -- re-scan on respawn
end)

-- UI: Bomb Game section
Window:Label("--- Bomb Game ---")

Window:Toggle("Auto Pass Bomb", false, function(state)
    cfg.AutoPassBomb = state
    moveTimer = 0
end)

Window:Toggle("Walk Speed Boost", false, function(state)
    cfg.SpeedBoost = state
end)

-- UI: PVP section
Window:Label("--- PVP ---")

Window:Toggle("No Fall (Float)", false, function(state)
    cfg.FloatMidAir = state
end)

Window:Toggle("Fly Mode", false, function(state)
    cfg.Fly = state
    -- Disable float if fly is on (redundant)
    if state then cfg.FloatMidAir = false end
end)

Window:Toggle("Auto Punch", false, function(state)
    cfg.AutoPunch = state
    punchTimer = 0
    if state then
        -- Pre-scan for remote on enable
        task.spawn(findPunchRemote)
    end
end)
