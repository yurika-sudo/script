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
local FLY_HEIGHT    = 14   -- studs above ground
local PUNCH_RANGE   = 6    -- studs
local PUNCH_RATE    = 0.45 -- seconds between punches

local cfg = {
    AutoPassBomb = false,
    SpeedBoost   = false,
    FloatMidAir  = false,
    Fly          = false,
    PVPMode      = false,  -- manual gate: enable when entering PVP arena
    AutoPunch    = false,
}

local moveTimer  = 0
local punchTimer = 0
local punchRemote = nil
local flyBP = nil  -- BodyPosition instance for fly

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
                if d < bestDist then
                    bestDist = d
                    best = p
                end
            end
        end
    end
    return best, bestDist
end

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

-- Create/destroy BodyPosition for fly
local function setupFly(enable)
    local c = getChar()
    local r = getHRP(c)

    -- Clean up existing
    if flyBP then
        pcall(function() flyBP:Destroy() end)
        flyBP = nil
    end

    if enable and r then
        -- BodyPosition only controls Y (MaxForce X/Z = 0 so humanoid movement works normally)
        -- D = damping value — this is what prevents oscillation
        local bp = Instance.new("BodyPosition")
        bp.Name       = "FlyBP"
        bp.MaxForce   = Vector3.new(0, 1e5, 0)
        bp.P          = 8000   -- stiffness
        bp.D          = 600    -- damping: higher = less bouncy
        bp.Position   = r.Position
        bp.Parent     = r
        flyBP = bp
    end
end

-- Update fly target height each frame
local function updateFly()
    local c = getChar()
    local r = getHRP(c)
    if not r or not flyBP then return end

    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {c}
    params.FilterType = Enum.RaycastFilterType.Exclude

    local ray = workspace:Raycast(r.Position, Vector3.new(0, -150, 0), params)
    local groundY = ray and ray.Position.Y or (r.Position.Y - FLY_HEIGHT)
    flyBP.Position = Vector3.new(r.Position.X, groundY + FLY_HEIGHT, r.Position.Z)
end

RunService.Heartbeat:Connect(function(dt)
    local c = getChar()
    local h = getHum(c)
    if not h or h.Health <= 0 then return end
    local r = getHRP(c)

    -- Persistent speed
    local targetSpd = cfg.SpeedBoost and SPEED_BOOST or SPEED_DEFAULT
    if h.WalkSpeed ~= targetSpd then h.WalkSpeed = targetSpd end

    -- Auto Pass Bomb
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

    -- Float: cancel downward velocity
    if cfg.FloatMidAir and not cfg.Fly and r then
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            r.AssemblyLinearVelocity = Vector3.new(vel.X, 0, vel.Z)
        end
    end

    -- Fly: update BodyPosition target height each frame
    if cfg.Fly then
        updateFly()
    end

    -- Auto Punch: ONLY active when PVP Mode is on
    if cfg.AutoPunch and cfg.PVPMode then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh then
                -- Don't follow if target fell off platform (Y drop > 12 studs below us)
                local heightDiff = r.Position.Y - oh.Position.Y
                if heightDiff > 12 then return end

                h:MoveTo(oh.Position)

                punchTimer = punchTimer + dt
                if dist <= PUNCH_RANGE and punchTimer >= PUNCH_RATE then
                    punchTimer = 0
                    local remote = findPunchRemote()
                    if remote then
                        pcall(function() remote:FireServer(oh.Position) end)
                        pcall(function() remote:FireServer(target.Character) end)
                        pcall(function() remote:FireServer() end)
                    end
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
    punchRemote = nil
    flyBP = nil
    -- Re-setup fly if it was on
    task.wait(1)
    if cfg.Fly then
        setupFly(true)
    end
end)

-- UI -------------------------------------------------------

Window:Label("--- Bomb Game ---")

Window:Toggle("Auto Pass Bomb", false, function(state)
    cfg.AutoPassBomb = state
    moveTimer = 0
end)

Window:Toggle("Walk Speed Boost", false, function(state)
    cfg.SpeedBoost = state
end)

Window:Label("--- PVP ---")

-- PVP Mode gate: user enables this when entering the PVP arena
-- Prevents Auto Punch from running in lobby or bomb game
Window:Toggle("PVP Mode (enable in arena)", false, function(state)
    cfg.PVPMode = state
    punchTimer = 0
    if state then
        task.spawn(findPunchRemote)
    end
end)

Window:Toggle("No Fall (Float)", false, function(state)
    cfg.FloatMidAir = state
end)

Window:Toggle("Fly Mode", false, function(state)
    cfg.Fly = state
    setupFly(state)
    -- Float redundant when flying
    if state then cfg.FloatMidAir = false end
end)

Window:Toggle("Auto Punch", false, function(state)
    cfg.AutoPunch = state
    punchTimer = 0
end)

-- Debug: scan all RemoteEvents and show names on screen
Window:Button("Scan Remotes (debug)", function()
    local SG = game:GetService("StarterGui")
    local results = {}

    for _, v in ipairs(game:GetService("ReplicatedStorage"):GetDescendants()) do
        if v:IsA("RemoteEvent") or v:IsA("RemoteFunction") then
            table.insert(results, v.Name)
        end
    end

    if #results == 0 then
        table.insert(results, "(none found)")
    end

    -- Show first 5 via notifications (each notification = 1 batch)
    local batch = table.concat(results, "  |  ")

    -- Method 1: Roblox notification popup
    pcall(function()
        SG:SetCore("SendNotification", {
            Title    = "Remotes (" .. #results .. ")",
            Text     = batch:sub(1, 200),
            Duration = 15,
        })
    end)

    -- Method 2: Floating ScreenGui label (visible even if notif fails)
    pcall(function()
        local existing = LocalPlayer.PlayerGui:FindFirstChild("RemoteScanResult")
        if existing then existing:Destroy() end

        local gui   = Instance.new("ScreenGui")
        gui.Name    = "RemoteScanResult"
        gui.ResetOnSpawn = false
        gui.Parent  = LocalPlayer.PlayerGui

        local frame = Instance.new("ScrollingFrame")
        frame.Size              = UDim2.new(0.9, 0, 0.4, 0)
        frame.Position          = UDim2.new(0.05, 0, 0.55, 0)
        frame.BackgroundColor3  = Color3.fromRGB(20, 20, 20)
        frame.BackgroundTransparency = 0.1
        frame.BorderSizePixel   = 0
        frame.CanvasSize        = UDim2.new(0, 0, 0, #results * 28)
        frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
        frame.Parent            = gui

        local layout = Instance.new("UIListLayout")
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Parent    = frame

        for i, name in ipairs(results) do
            local lbl = Instance.new("TextLabel")
            lbl.Size             = UDim2.new(1, 0, 0, 26)
            lbl.BackgroundColor3 = i % 2 == 0 and Color3.fromRGB(30,30,30) or Color3.fromRGB(40,40,40)
            lbl.TextColor3       = Color3.fromRGB(200, 255, 180)
            lbl.TextSize         = 14
            lbl.Font             = Enum.Font.Code
            lbl.Text             = "  " .. i .. ".  " .. name
            lbl.TextXAlignment   = Enum.TextXAlignment.Left
            lbl.BorderSizePixel  = 0
            lbl.LayoutOrder      = i
            lbl.Parent           = frame
        end

        -- Close button
        local close = Instance.new("TextButton")
        close.Size            = UDim2.new(0.9, 0, 0, 32)
        close.Position        = UDim2.new(0.05, 0, 0.96, 0)
        close.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
        close.TextColor3      = Color3.new(1,1,1)
        close.TextSize        = 14
        close.Font            = Enum.Font.GothamBold
        close.Text            = "Close"
        close.Parent          = gui
        close.MouseButton1Click:Connect(function() gui:Destroy() end)
    end)
end)
