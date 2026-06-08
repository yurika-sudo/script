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

-- ── Debug overlay ────────────────────────────────────────────────────────────
-- Defined before Heartbeat so labels are never nil when the loop runs.
-- Layout:
--   [debugLabel]  top-left  — live game stats (dist/bomb/players), always visible
--   [scanPanel]   full-screen scrollable list — only visible after a scan
-- ─────────────────────────────────────────────────────────────────────────────
local debugGui = Instance.new("ScreenGui")
debugGui.Name         = "POEDebug"
debugGui.ResetOnSpawn = false
debugGui.Parent       = LocalPlayer.PlayerGui

-- Live stats label (always on)
local debugLabel = Instance.new("TextLabel")
debugLabel.Size                   = UDim2.new(0, 190, 0, 70)
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

-- Scan panel — scrollable overlay shown after Scan button pressed
local scanFrame = Instance.new("Frame")
scanFrame.Size              = UDim2.new(1, -16, 0.55, 0)
scanFrame.Position          = UDim2.new(0, 8, 0, 8)
scanFrame.BackgroundColor3  = Color3.fromRGB(10, 10, 10)
scanFrame.BackgroundTransparency = 0.15
scanFrame.BorderSizePixel   = 0
scanFrame.Visible           = false
scanFrame.Parent            = debugGui

-- Close button inside scan panel
local closeBtn = Instance.new("TextButton")
closeBtn.Size            = UDim2.new(0, 60, 0, 24)
closeBtn.Position        = UDim2.new(1, -64, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
closeBtn.TextColor3      = Color3.fromRGB(255, 255, 255)
closeBtn.TextSize        = 13
closeBtn.Font            = Enum.Font.GothamBold
closeBtn.Text            = "CLOSE"
closeBtn.BorderSizePixel = 0
closeBtn.Parent          = scanFrame
closeBtn.MouseButton1Click:Connect(function()
    scanFrame.Visible = false
end)

-- Page label inside scan panel
local pageLabel = Instance.new("TextLabel")
pageLabel.Size              = UDim2.new(1, -70, 0, 24)
pageLabel.Position          = UDim2.new(0, 4, 0, 4)
pageLabel.BackgroundTransparency = 1
pageLabel.TextColor3        = Color3.fromRGB(255, 220, 80)
pageLabel.TextSize          = 12
pageLabel.Font              = Enum.Font.GothamBold
pageLabel.TextXAlignment    = Enum.TextXAlignment.Left
pageLabel.Text              = "Scan Results"
pageLabel.Parent            = scanFrame

-- Scrollable content inside scan panel
local scrollFrame = Instance.new("ScrollingFrame")
scrollFrame.Size              = UDim2.new(1, 0, 1, -32)
scrollFrame.Position          = UDim2.new(0, 0, 0, 30)
scrollFrame.BackgroundTransparency = 1
scrollFrame.BorderSizePixel   = 0
scrollFrame.ScrollBarThickness = 6
scrollFrame.CanvasSize        = UDim2.new(0, 0, 0, 0)
scrollFrame.Parent            = scanFrame

local listLayout = Instance.new("UIListLayout")
listLayout.SortOrder  = Enum.SortOrder.LayoutOrder
listLayout.Padding    = UDim.new(0, 2)
listLayout.Parent     = scrollFrame

-- Helper: add a line to the scan panel
local function addScanLine(text, color)
    local lbl = Instance.new("TextLabel")
    lbl.Size                   = UDim2.new(1, -8, 0, 16)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3             = color or Color3.fromRGB(200, 200, 200)
    lbl.TextSize               = 11
    lbl.Font                   = Enum.Font.Code
    lbl.TextXAlignment         = Enum.TextXAlignment.Left
    lbl.TextWrapped            = true
    lbl.Text                   = text
    lbl.Parent                 = scrollFrame
    -- Expand canvas height to fit new line
    scrollFrame.CanvasSize = UDim2.new(0, 0, 0,
        listLayout.AbsoluteContentSize.Y + 8)
    return lbl
end

local function clearScanPanel()
    for _, v in ipairs(scrollFrame:GetChildren()) do
        if v:IsA("TextLabel") then v:Destroy() end
    end
    scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
end

-- ── Main Heartbeat ────────────────────────────────────────────────────────────
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
    -- requireSameHeight=true: skip lobby/spectator players with large Y diff
    -- Post-teleport safety: if we land outside arena (Y drops > 12 studs from
    -- where we were), snap back to pre-teleport position immediately
    if cfg.BombTeleport and holding then
        teleportTimer = teleportTimer + dt
        if teleportTimer >= 0.25 then
            teleportTimer = 0
            local target, _ = nearestPlayer(true)  -- height-filtered
            if target and target.Character then
                local oh = getHRP(target.Character)
                if oh then
                    local preY    = r.Position.Y
                    local facing  = oh.CFrame.LookVector
                    local newPos  = oh.Position + Vector3.new(facing.X, 0, facing.Z) * 3
                    local preCF   = r.CFrame  -- save before teleport

                    r.CFrame = CFrame.new(newPos, oh.Position)

                    -- Safety: if we ended up more than 12 studs below where we
                    -- started (fell off arena edge), snap back instantly
                    task.defer(function()
                        local postR = getHRP(getChar())
                        if postR and (preY - postR.Position.Y) > 12 then
                            postR.CFrame = preCF
                        end
                    end)
                end
            end
        end
    else
        teleportTimer = 0
    end

    -- Auto Pass Bomb: overshoot MoveTo so Humanoid never reaches the goal
    -- and never enters the internal deceleration zone near the destination.
    -- We target a point slightly PAST the player (dir * overshoot) so the
    -- pathfinder stays in full-sprint state every frame.
    if cfg.AutoPassBomb and not cfg.BombTeleport and holding then
        local target, dist = nearestPlayer()
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh and dist > STOP_DIST then
                local dir = (oh.Position - r.Position)
                local dirXZ = Vector3.new(dir.X, 0, dir.Z)
                -- Overshoot by 8 studs past target so we never "arrive"
                local overshoot = oh.Position + dirXZ.Unit * 8
                h:MoveTo(overshoot)
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
            freeFlyBV.MaxForce = Vector3.new(0, 0, 0)
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

    -- Live stats label (always visible, small footprint)
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
    local myR = getHRP(getChar())
    local myY = myR and string.format("%.1f", myR.Position.Y) or "--"
    debugLabel.Size = UDim2.new(0, 200, 0, 90)
    debugLabel.Text = string.format(
        "dist: %s (%s)\nbomb: %s\nplayers: %d\nY: %s",
        distStr, zoneStr, holding and "YES" or "no", count, myY
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

-- ── UI ────────────────────────────────────────────────────────────────────────
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

-- ── Scan button ───────────────────────────────────────────────────────────────
-- Scans RS + workspace and displays results in an on-screen scrollable panel.
-- Run while holding the bomb to identify timer values.
-- Also scans RemoteEvents/RemoteFunctions to help identify punch remotes.
-- Results stay on screen until you tap CLOSE.
Window:Button("Scan Values (on-screen)", function()
    clearScanPanel()
    scanFrame.Visible = true
    pageLabel.Text = "Scanning..."

    local timerHits   = {}  -- NumberValue/IntValue candidates
    local remoteHits  = {}  -- RemoteEvent / RemoteFunction
    local otherHits   = {}  -- StringValue / BoolValue / misc

    local function scanContainer(container, prefix)
        for _, v in ipairs(container:GetDescendants()) do
            local cn = v.ClassName
            if cn == "NumberValue" or cn == "IntValue" then
                local ok, val = pcall(function() return v.Value end)
                if ok then
                    table.insert(timerHits, string.format(
                        "[%s] %s = %s", cn, v:GetFullName(), tostring(val)))
                end
            elseif cn == "StringValue" then
                local ok, val = pcall(function() return v.Value end)
                if ok then
                    table.insert(otherHits, string.format(
                        "[StringValue] %s = \"%s\"", v:GetFullName(), tostring(val)))
                end
            elseif cn == "BoolValue" then
                local ok, val = pcall(function() return v.Value end)
                if ok then
                    table.insert(otherHits, string.format(
                        "[BoolValue] %s = %s", v:GetFullName(), tostring(val)))
                end
            elseif cn == "RemoteEvent" or cn == "RemoteFunction" then
                table.insert(remoteHits, string.format(
                    "[%s] %s", cn, v:GetFullName()))
            end
        end
    end

    scanContainer(RS, "RS")
    scanContainer(workspace, "WS")

    -- Section: timer candidates
    addScanLine("=== TIMER CANDIDATES (Number/Int) ===",
        Color3.fromRGB(255, 220, 60))
    if #timerHits == 0 then
        addScanLine("  (none found)", Color3.fromRGB(160, 160, 160))
    else
        for _, line in ipairs(timerHits) do
            addScanLine("  " .. line, Color3.fromRGB(100, 255, 100))
        end
    end

    -- Section: remotes (punch / endgame detection)
    addScanLine("=== REMOTES (Event/Function) ===",
        Color3.fromRGB(255, 220, 60))
    if #remoteHits == 0 then
        addScanLine("  (none found)", Color3.fromRGB(160, 160, 160))
    else
        for _, line in ipairs(remoteHits) do
            addScanLine("  " .. line, Color3.fromRGB(120, 200, 255))
        end
    end

    -- Section: other values (strings/bools — game state flags)
    addScanLine("=== OTHER VALUES (String/Bool) ===",
        Color3.fromRGB(255, 220, 60))
    if #otherHits == 0 then
        addScanLine("  (none found)", Color3.fromRGB(160, 160, 160))
    else
        for _, line in ipairs(otherHits) do
            addScanLine("  " .. line, Color3.fromRGB(200, 180, 255))
        end
    end

    local total = #timerHits + #remoteHits + #otherHits
    pageLabel.Text = string.format(
        "Scan done: %d timer | %d remotes | %d other",
        #timerHits, #remoteHits, #otherHits)
end)
