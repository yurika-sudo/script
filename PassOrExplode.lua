local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local RS          = game:GetService("ReplicatedStorage")
local VIM         = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

-- ── Rayfield UI ───────────────────────────────────────────────────────────────
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Window = Rayfield:CreateWindow({
    Name            = "POE Assist",
    LoadingTitle    = "POE Assist",
    LoadingSubtitle = "",
    ConfigurationSaving = { Enabled = false },
    Discord         = { Enabled = false },
    KeySystem       = false,
})
local TabBomb = Window:CreateTab("Bomb", 4483362458)
local TabPVP  = Window:CreateTab("PVP",  4483362458)

-- ── Config ────────────────────────────────────────────────────────────────────
local cfg = {
    AutoPassBomb = false,
    BombTeleport = false,
    Noclip       = false,
    SpeedEnabled = false,
    NoFall       = false,
    AutoPunch    = false,
}

-- ── Constants ─────────────────────────────────────────────────────────────────
local SPEED_BOMB      = 22
local SPEED_IDLE      = 20
local SPEED_DEFAULT   = 16
local MAX_TARGET_DIST = 200
local SPECTATOR_MARGIN = 12
local STOP_DIST       = 4
local PUNCH_RANGE     = 6
local PUNCH_RATE      = 0.45
local PUNCH_Y_DIFF    = 15

-- Arena Y: auto-detected from stable Y samples, fallback 24
local arenaY       = 24
local arenaYLocked = false
local ySamples     = {}
local ySampleTimer = 0

-- ── State ─────────────────────────────────────────────────────────────────────
local punchTimer    = 0
local teleportTimer = 0
local noclipTimer   = 0
local noFallBV      = nil
local ghostActive   = false

-- ── Remotes ───────────────────────────────────────────────────────────────────
local remoteAction  = nil
local remoteEndgame = nil
task.spawn(function()
    local events = RS:WaitForChild("Remotes", 10)
        and RS.Remotes:WaitForChild("Events", 10)
    if not events then return end
    remoteAction  = events:WaitForChild("ActionEvent",        10)
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

-- Arena Y auto-detection via stable Y samples
local function updateArenaY(dt, myY)
    if arenaYLocked then return end
    ySampleTimer = ySampleTimer + dt
    if ySampleTimer < 0.5 then return end
    ySampleTimer = 0
    table.insert(ySamples, myY)
    if #ySamples > 6 then table.remove(ySamples, 1) end
    if #ySamples < 4 then return end
    local sum = 0
    for _, v in ipairs(ySamples) do sum = sum + v end
    local mean = sum / #ySamples
    local maxDev = 0
    for _, v in ipairs(ySamples) do
        maxDev = math.max(maxDev, math.abs(v - mean))
    end
    if maxDev < 1.5 then
        arenaY = math.floor(mean + 0.5)
        arenaYLocked = true
    end
end

-- Returns skip reason string or nil if player is valid target
local function shouldSkip(p, myHRP)
    local c = p.Character; if not c then return "no_char" end
    local oh = getHRP(c);  if not oh then return "no_hrp" end
    local ph = getHum(c);  if not ph then return "no_hum" end
    if ph.Health <= 0 then return "dead" end
    if ph:GetState() == Enum.HumanoidStateType.Dead then return "dead_state" end
    local yAbs = oh.Position.Y
    if yAbs > arenaY + SPECTATOR_MARGIN then return "y_high" end
    if yAbs < arenaY - SPECTATOR_MARGIN then return "y_low" end
    if (myHRP.Position - oh.Position).Magnitude > MAX_TARGET_DIST then return "far" end
    return nil
end

-- punchYLimit: extra Y diff cap for punch (nil = no extra cap)
local function nearestPlayer(punchYLimit)
    local c = getChar(); local h = getHRP(c)
    if not h then return nil, math.huge end
    local best, bestDist = nil, math.huge
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local skip = shouldSkip(p, h)
            local oh   = p.Character and getHRP(p.Character)
            if not skip and punchYLimit and oh then
                if math.abs(h.Position.Y - oh.Position.Y) > punchYLimit then
                    skip = "punch_y"
                end
            end
            if not skip and oh then
                local d = (h.Position - oh.Position).Magnitude
                if d < bestDist then bestDist = d; best = p end
            end
        end
    end
    return best, bestDist
end

-- Bomb timer from BillboardGui on carrier
local function getBombTimer()
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then
            local tool = p.Character:FindFirstChild("BombActive")
            if tool then
                local handle = tool:FindFirstChild("Handle")
                local bb = handle and (handle:FindFirstChildOfClass("BillboardGui")
                    or handle:FindFirstChild("BillboardGui"))
                local lbl = bb and bb:FindFirstChild("Countdown")
                if lbl and lbl:IsA("TextLabel") then
                    local n = tonumber(lbl.Text)
                    if n then return n, p end
                end
            end
        end
    end
    return nil, nil
end

local LEG_NAMES = {"LeftFoot","RightFoot","LeftLowerLeg","RightLowerLeg",
                   "LeftUpperLeg","RightUpperLeg","Left Leg","Right Leg"}
local function isLeg(n)
    for _, v in ipairs(LEG_NAMES) do if n == v then return true end end
    return false
end

local function applyNoclip(c, on)
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and not isLeg(p.Name) then
            p.CanCollide = not on
        end
    end
    ghostActive = on
end

local function setupNoFall(enable)
    if noFallBV then pcall(function() noFallBV:Destroy() end); noFallBV = nil end
    if not enable then return end
    local r = getHRP(getChar()); if not r then return end
    local bv = Instance.new("BodyVelocity")
    bv.Name     = "NoFallBV"
    bv.Velocity = Vector3.new(0, 0, 0)
    bv.MaxForce = Vector3.new(0, 0, 0)
    bv.Parent   = r
    noFallBV    = bv
end

local function firePunch(targetChar, targetHRP)
    if remoteAction then
        pcall(function() remoteAction:FireServer("Punch") end)
        pcall(function() remoteAction:FireServer("punch", targetChar) end)
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

-- ── Debug label ───────────────────────────────────────────────────────────────
local debugGui = Instance.new("ScreenGui")
debugGui.Name = "POEDebug"; debugGui.ResetOnSpawn = false
debugGui.Parent = LocalPlayer.PlayerGui

local debugLabel = Instance.new("TextLabel")
debugLabel.Size                   = UDim2.new(0, 200, 0, 86)
debugLabel.Position               = UDim2.new(0, 8, 0.45, 0)
debugLabel.BackgroundColor3       = Color3.fromRGB(0, 0, 0)
debugLabel.BackgroundTransparency = 0.45
debugLabel.TextColor3             = Color3.fromRGB(100, 255, 100)
debugLabel.TextSize               = 13
debugLabel.Font                   = Enum.Font.Code
debugLabel.TextXAlignment         = Enum.TextXAlignment.Left
debugLabel.TextYAlignment            = Enum.TextYAlignment.Top
debugLabel.Text                   = "initializing..."
debugLabel.BorderSizePixel        = 0
debugLabel.Parent                 = debugGui

-- ── Main loop ─────────────────────────────────────────────────────────────────
RunService.Heartbeat:Connect(function(dt)
    local c = getChar(); local h = getHum(c)
    if not h or h.Health <= 0 then return end
    local r = getHRP(c); if not r then return end
    local myY = r.Position.Y

    updateArenaY(dt, myY)

    local holding = hasBomb(c)
    local chasing  = holding and (cfg.AutoPassBomb or cfg.BombTeleport)

    -- Speed
    local targetSpd = SPEED_DEFAULT
    if cfg.SpeedEnabled then
        targetSpd = chasing and SPEED_BOMB or SPEED_IDLE
    end
    if h.WalkSpeed ~= targetSpd then h.WalkSpeed = targetSpd end

    -- Noclip
    if cfg.Noclip then
        noclipTimer = noclipTimer + dt
        if noclipTimer >= 0.3 then noclipTimer = 0; applyNoclip(c, true) end
    elseif ghostActive then
        applyNoclip(c, false); noclipTimer = 0
    end

    -- Bomb Teleport
    if cfg.BombTeleport and holding then
        teleportTimer = teleportTimer + dt
        if teleportTimer >= 0.25 then
            teleportTimer = 0
            local target = nearestPlayer(nil)
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

    -- Auto Pass Bomb
    -- Reads bomb timer every frame. If timer <= 3 and BombTeleport is ON,
    -- teleport immediately instead of running (beats obstacles on tight maps).
    -- Otherwise: overshoot MoveTo toward target so Humanoid never decelerates.
    -- MoveTo is called every frame so direction is always fresh — no "slow start".
    if cfg.AutoPassBomb and not cfg.BombTeleport and holding then
        if noFallBV then noFallBV.MaxForce = Vector3.new(0, 0, 0) end
        local target, dist = nearestPlayer(nil)
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh then
                if dist > STOP_DIST then
                    -- Overshoot: goal is 8 studs past target so we never "arrive"
                    -- and never enter the internal decel window
                    local dirXZ = Vector3.new(
                        oh.Position.X - r.Position.X, 0,
                        oh.Position.Z - r.Position.Z)
                    if dirXZ.Magnitude > 0 then
                        h:MoveTo(oh.Position + dirXZ.Unit * 8)
                    end
                end
            end
        end
    end

    -- No Fall
    if cfg.NoFall and noFallBV then
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            noFallBV.MaxForce = Vector3.new(0, 1e6, 0)
            noFallBV.Velocity = Vector3.new(0, 0, 0)
        else
            noFallBV.MaxForce = Vector3.new(0, 0, 0)
        end
    end

    -- Auto Punch: stay still, punch when target enters range
    -- punchNoFall handled via cfg.NoFall — enable No Fall in PVP tab
    if cfg.AutoPunch then
        if math.abs(myY - arenaY) > 20 then return end
        local target, dist = nearestPlayer(PUNCH_Y_DIFF)
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh then
                if dist <= PUNCH_RANGE then
                    punchTimer = punchTimer + dt
                    if punchTimer >= PUNCH_RATE then
                        punchTimer = 0
                        firePunch(target.Character, oh)
                    end
                else
                    punchTimer = 0
                end
            end
        else
            punchTimer = 0
        end
    else
        punchTimer = 0
    end

    -- Debug label
    local bombTimer = getBombTimer()
    local _, dist2  = nearestPlayer(nil)
    local distStr   = dist2 == math.huge and "--" or string.format("%.1f", dist2)
    local zoneStr   = dist2 <= STOP_DIST and "STOP"
                   or dist2 <= 10        and "CLOSE"
                   or "FAR"
    local count = 0
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Character and getHRP(p.Character) then
            count = count + 1
        end
    end
    debugLabel.Text = string.format(
        "dist:%s(%s) bomb:%s\nT:%s Y:%.1f aY:%d\nplayers:%d",
        distStr, zoneStr,
        holding and "YES" or "no",
        bombTimer and tostring(bombTimer) or "?",
        myY, arenaY, count)
end)

-- ── CharacterAdded ────────────────────────────────────────────────────────────
LocalPlayer.CharacterAdded:Connect(function()
    noFallBV = nil; ghostActive = false
    noclipTimer = 0; teleportTimer = 0; punchTimer = 0
    arenaYLocked = false; ySamples = {}; ySampleTimer = 0
    task.wait(1)
    if cfg.NoFall then setupNoFall(true) end
end)

-- ── UI: Bomb tab ──────────────────────────────────────────────────────────────
TabBomb:CreateToggle({ Name = "Auto Pass Bomb", CurrentValue = false, Flag = "AutoPassBomb",
    Callback = function(v) cfg.AutoPassBomb = v end })
TabBomb:CreateToggle({ Name = "Bomb Teleport", CurrentValue = false, Flag = "BombTeleport",
    Callback = function(v) cfg.BombTeleport = v end })
TabBomb:CreateToggle({ Name = "Ghost Mode", CurrentValue = false, Flag = "Noclip",
    Callback = function(v)
        cfg.Noclip = v
        if not v and ghostActive then
            local c = getChar(); if c then applyNoclip(c, false) end
        end
    end })
TabBomb:CreateToggle({ Name = "Speed Boost", CurrentValue = false, Flag = "SpeedBoost",
    Callback = function(v) cfg.SpeedEnabled = v end })
TabBomb:CreateSlider({ Name = "Bomb Speed", Range = {16, 40}, Increment = 1, CurrentValue = 22,
    Flag = "BombSpeed", Callback = function(v) SPEED_BOMB = v end })
TabBomb:CreateSlider({ Name = "Idle Speed", Range = {16, 30}, Increment = 1, CurrentValue = 20,
    Flag = "IdleSpeed", Callback = function(v) SPEED_IDLE = v end })

-- ── UI: PVP tab ───────────────────────────────────────────────────────────────
TabPVP:CreateToggle({ Name = "No Fall", CurrentValue = false, Flag = "NoFall",
    Callback = function(v) cfg.NoFall = v; setupNoFall(v) end })
TabPVP:CreateToggle({ Name = "Auto Punch", CurrentValue = false, Flag = "AutoPunch",
    Callback = function(v) cfg.AutoPunch = v; punchTimer = 0 end })
TabPVP:CreateSlider({ Name = "Punch Y Diff", Range = {5, 30}, Increment = 1, CurrentValue = 15,
    Flag = "PunchYDiff", Callback = function(v) PUNCH_Y_DIFF = v end })
TabPVP:CreateSlider({ Name = "Spectator Margin", Range = {5, 40}, Increment = 1, CurrentValue = 12,
    Flag = "SpecMargin", Callback = function(v) SPECTATOR_MARGIN = v end })
