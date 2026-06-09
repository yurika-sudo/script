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
    FreeFly      = false,
    AutoPunch    = false,
}

-- ── Tunable constants ─────────────────────────────────────────────────────────
local SPEED_BOMB    = 22
local SPEED_IDLE    = 20
local SPEED_DEFAULT = 16

local MAX_TARGET_DIST  = 200
local MAX_Y_DIFF       = 15   -- general arena filter
local PUNCH_Y_DIFF     = 8    -- tighter Y filter for Auto Punch
local PUNCH_DIST_MAX   = 15   -- Auto Punch only targets within this range (filters spectators)
local LOBBY_Y_THRESH   = 10   -- Y below this = lobby, auto-off punch

local STOP_DIST   = 4
local NEAR_DIST   = 10
local PUNCH_RANGE = 6
local PUNCH_RATE  = 0.45
local FLY_SPEED   = 40

-- ── State ─────────────────────────────────────────────────────────────────────
local punchTimer    = 0
local teleportTimer = 0
local noclipTimer   = 0
local noFallBV      = nil
local punchNoFallBV = nil  -- dedicated BV for Auto Punch, independent of cfg.NoFall
local freeFlyBV     = nil
local ghostActive   = false
local toggleAutoPunch = nil

-- ── Confirmed remotes ─────────────────────────────────────────────────────────
local remoteAction  = nil
local remoteEndgame = nil
task.spawn(function()
    local events = RS:WaitForChild("Remotes", 10)
        and RS.Remotes:WaitForChild("Events", 10)
    if not events then return end
    remoteAction  = events:WaitForChild("ActionEvent",       10)
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

-- yDiffLimit: max Y diff allowed (pass nil to skip height filter)
local function nearestPlayer(yDiffLimit)
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
                local heightOk = (not yDiffLimit) or (yDiff <= yDiffLimit)
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

-- ── Ability scanner ───────────────────────────────────────────────────────────
-- Searches RS descendants for anything with "Speed", "Ability", or "Boost"
-- in the name. Outputs to a small timed overlay for bug-bounty audit.
-- Filters out lighting/animation noise (LightRange, Weight, etc).
local ABILITY_KEYWORDS = {"speed", "ability", "boost", "faster", "carrier", "status"}
local ABILITY_NOISE    = {"light", "weight", "damp", "bright", "angle", "range", "anim"}

local function wordMatch(s, list)
    local low = s:lower()
    for _, w in ipairs(list) do
        if low:find(w, 1, true) then return true end
    end
    return false
end

local abilityGui = Instance.new("ScreenGui")
abilityGui.Name         = "POEAbility"
abilityGui.ResetOnSpawn = false
abilityGui.Parent       = LocalPlayer.PlayerGui

local abilityLabel = Instance.new("TextLabel")
abilityLabel.Size                   = UDim2.new(0.6, 0, 0.35, 0)
abilityLabel.Position               = UDim2.new(0.38, 0, 0.08, 0)
abilityLabel.BackgroundColor3       = Color3.fromRGB(10, 10, 30)
abilityLabel.BackgroundTransparency = 0.1
abilityLabel.TextColor3             = Color3.fromRGB(255, 220, 80)
abilityLabel.TextSize               = 11
abilityLabel.Font                   = Enum.Font.Code
abilityLabel.TextXAlignment         = Enum.TextXAlignment.Left
abilityLabel.TextYAlignment         = Enum.TextYAlignment.Top
abilityLabel.TextWrapped            = true
abilityLabel.Text                   = ""
abilityLabel.BorderSizePixel        = 0
abilityLabel.Visible                = false
abilityLabel.Parent                 = abilityGui

-- ── Debug label ───────────────────────────────────────────────────────────────
local debugGui = Instance.new("ScreenGui")
debugGui.Name         = "POEDebug"
debugGui.ResetOnSpawn = false
debugGui.Parent       = LocalPlayer.PlayerGui

local debugLabel = Instance.new("TextLabel")
debugLabel.Size                   = UDim2.new(0, 200, 0, 86)
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
    local myY     = r.Position.Y

    -- Auto-disable AutoPunch when we return to lobby (Y drops below threshold)
    -- This is the fallback for round-end since we have no server timer
    if cfg.AutoPunch and myY < LOBBY_Y_THRESH then
        cfg.AutoPunch = false
        if toggleAutoPunch then
            pcall(function() toggleAutoPunch:Set(false) end)
        end
    end

    -- Speed management
    -- No Fall is suppressed while Auto Pass Bomb is active so physics
    -- doesn't fight the Humanoid chasing movement on sloped terrain
    local chasing = holding and (cfg.AutoPassBomb or cfg.BombTeleport)
    local targetSpd = SPEED_DEFAULT
    if cfg.SpeedEnabled then
        targetSpd = chasing and SPEED_BOMB or SPEED_IDLE
    end
    if h.WalkSpeed ~= targetSpd then h.WalkSpeed = targetSpd end

    -- Ghost: re-apply every 0.3s
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

    -- Bomb Teleport
    if cfg.BombTeleport and holding then
        teleportTimer = teleportTimer + dt
        if teleportTimer >= 0.25 then
            teleportTimer = 0
            local target, _ = nearestPlayer(MAX_Y_DIFF)
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

    -- Auto Pass Bomb: overshoot MoveTo, suppress No Fall while chasing
    if cfg.AutoPassBomb and not cfg.BombTeleport and holding then
        -- Temporarily suspend No Fall so it doesn't fight movement on slopes
        if noFallBV then noFallBV.MaxForce = Vector3.new(0, 0, 0) end
        local target, dist = nearestPlayer(nil)
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

    -- Free Fly: suspend while chasing
    if cfg.FreeFly and freeFlyBV then
        if chasing then
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

    -- Auto Punch:
    -- - Own dedicated BodyVelocity (punchNoFallBV) — no dependency on cfg.NoFall toggle
    -- - PUNCH_Y_DIFF=8: tighter vertical filter (avoids lobby/spectator)
    -- - PUNCH_DIST_MAX=15: only targets players within 15 studs, never reaches spectators
    -- - No MoveTo: character stays still, punches when target enters range
    if cfg.AutoPunch then
        -- Setup dedicated no-fall BV if not already created
        if not punchNoFallBV then
            local bv    = Instance.new("BodyVelocity")
            bv.Name     = "PunchNoFallBV"
            bv.Velocity = Vector3.new(0, 0, 0)
            bv.MaxForce = Vector3.new(0, 0, 0)
            bv.Parent   = r
            punchNoFallBV = bv
        end
        -- Apply no-fall via dedicated BV
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            punchNoFallBV.MaxForce = Vector3.new(0, 1e6, 0)
            punchNoFallBV.Velocity = Vector3.new(0, 0, 0)
        else
            punchNoFallBV.MaxForce = Vector3.new(0, 0, 0)
        end
        local target, dist = nearestPlayer(PUNCH_Y_DIFF)
        if target and target.Character and dist <= PUNCH_DIST_MAX then
            local oh = getHRP(target.Character)
            if oh then
                punchTimer = punchTimer + dt
                if dist <= PUNCH_RANGE and punchTimer >= PUNCH_RATE then
                    punchTimer = 0
                    firePunch(target.Character, oh)
                end
            end
        end
    else
        -- Clean up dedicated BV when Auto Punch is off
        if punchNoFallBV then
            pcall(function() punchNoFallBV:Destroy() end)
            punchNoFallBV = nil
        end
    end

    -- Debug label
    local _, dist2 = nearestPlayer(nil)
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
        count, myY)
end)

-- ── CharacterAdded ────────────────────────────────────────────────────────────
LocalPlayer.CharacterAdded:Connect(function()
    noFallBV = nil; punchNoFallBV = nil; freeFlyBV = nil; ghostActive = false
    noclipTimer = 0; teleportTimer = 0; punchTimer = 0

    if cfg.AutoPunch then
        cfg.AutoPunch = false
        if toggleAutoPunch then
            pcall(function() toggleAutoPunch:Set(false) end)
        end
    end

    task.wait(1)
    if cfg.FreeFly then setupFreeFly(true) end
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
Window:Button("Speed 22 (safe)", function()
    SPEED_BOMB = 22
    local h = getHum(getChar())
    if h then h.WalkSpeed = cfg.SpeedEnabled and SPEED_BOMB or SPEED_DEFAULT end
end)
Window:Button("Speed 24 (boost)", function()
    SPEED_BOMB = 24
    local h = getHum(getChar())
    if h then h.WalkSpeed = cfg.SpeedEnabled and SPEED_BOMB or SPEED_DEFAULT end
end)
Window:Button("Speed 26 (match P2W)", function()
    SPEED_BOMB = 26
    local h = getHum(getChar())
    if h then h.WalkSpeed = cfg.SpeedEnabled and SPEED_BOMB or SPEED_DEFAULT end
end)
Window:Toggle("Free Fly", false, function(s)
    cfg.FreeFly = s
    setupFreeFly(s)
end)
toggleAutoPunch = Window:Toggle("Auto Punch", false, function(s)
    cfg.AutoPunch = s
    punchTimer    = 0
end)
-- Ability scanner + AbilityCatalog dump (bug bounty audit)
Window:Button("Scan Abilities", function()
    local lines = {}

    -- 1. Filter RS descendants by keyword
    local hits = {}
    for _, v in ipairs(RS:GetDescendants()) do
        local name = v.Name
        if wordMatch(name, ABILITY_KEYWORDS) and not wordMatch(name, ABILITY_NOISE) then
            local ok, val = pcall(function() return v.Value end)
            local valStr = ok and (" = " .. tostring(val)) or ""
            table.insert(hits, string.format("[%s] %s%s", v.ClassName, v:GetFullName(), valStr))
        end
    end
    table.insert(lines, "[RS scan] " .. #hits .. " hits:")
    for i = 1, math.min(#hits, 8) do table.insert(lines, hits[i]) end
    if #hits > 8 then table.insert(lines, "...+" .. (#hits-8) .. " more") end

    -- 2. Require AbilityCatalog and dump names + speed values
    table.insert(lines, ""); table.insert(lines, "[AbilityCatalog]")
    local catalogModule = RS:FindFirstChild("Shared")
        and RS.Shared:FindFirstChild("AbilityCatalog")
    if catalogModule then
        local ok, catalog = pcall(require, catalogModule)
        if ok and type(catalog) == "table" then
            local count = 0
            for id, data in pairs(catalog) do
                count = count + 1
                if count <= 12 then
                    local extra = ""
                    if type(data) == "table" then
                        local spd = data.Speed or data.speed or data.WalkSpeed
                        local dur = data.Duration or data.duration
                        local nm  = data.Name or data.name or tostring(id)
                        if spd then extra = extra .. " spd=" .. tostring(spd) end
                        if dur then extra = extra .. " dur=" .. tostring(dur) end
                        table.insert(lines, string.format("  [%s] %s%s", tostring(id), nm, extra))
                    else
                        table.insert(lines, string.format("  [%s]=%s", tostring(id), tostring(data)))
                    end
                end
            end
            if count > 12 then table.insert(lines, "  ...+" .. (count-12) .. " more") end
            table.insert(lines, "Total: " .. count .. " abilities")
        else
            table.insert(lines, "require failed: " .. tostring(catalog))
        end
    else
        table.insert(lines, "Not found in RS.Shared")
    end

    -- 3. AbilityUseEvent bypass test — fire P2W ability without owning it
    table.insert(lines, ""); table.insert(lines, "[AbilityUseEvent bypass test]")
    local abilityUse = RS:FindFirstChild("Remotes")
        and RS.Remotes:FindFirstChild("Events")
        and RS.Remotes.Events:FindFirstChild("AbilityUseEvent")
    if abilityUse then
        local fired, err = pcall(function() abilityUse:FireServer("Faster") end)
        table.insert(lines, fired
            and "FireServer(Faster) accepted -- POTENTIAL BYPASS"
            or  "Rejected: " .. tostring(err))
    else
        table.insert(lines, "AbilityUseEvent not found")
    end

    abilityLabel.Text = table.concat(lines, "\n")
    abilityLabel.Visible = true
    task.delay(25, function() abilityLabel.Visible = false end)
end)
