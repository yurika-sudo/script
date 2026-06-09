local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")
local VIM        = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

-- ─── Overlay log (mobile, toggle-able) ───────────────────────────────────────
local overlayGui = Instance.new("ScreenGui")
overlayGui.Name = "POEOverlay"
overlayGui.ResetOnSpawn = false
overlayGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
overlayGui.Parent = LocalPlayer.PlayerGui

local overlayFrame = Instance.new("Frame")
overlayFrame.Size = UDim2.new(0, 340, 0, 180)
overlayFrame.Position = UDim2.new(0, 6, 0.35, 0)
overlayFrame.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
overlayFrame.BackgroundTransparency = 0.3
overlayFrame.BorderSizePixel = 0
overlayFrame.Visible = false
overlayFrame.Parent = overlayGui

local overlayScroll = Instance.new("ScrollingFrame")
overlayScroll.Size = UDim2.new(1, -4, 1, -4)
overlayScroll.Position = UDim2.new(0, 2, 0, 2)
overlayScroll.BackgroundTransparency = 1
overlayScroll.BorderSizePixel = 0
overlayScroll.ScrollBarThickness = 4
overlayScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
overlayScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
overlayScroll.Parent = overlayFrame

local overlayLayout = Instance.new("UIListLayout")
overlayLayout.SortOrder = Enum.SortOrder.LayoutOrder
overlayLayout.Padding = UDim.new(0, 1)
overlayLayout.Parent = overlayScroll

local LOG_MAX  = 40
local logLines = {}
local logOrder = 0

local function overlayLog(text, color)
    logOrder = logOrder + 1
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 14)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = color or Color3.fromRGB(220, 220, 220)
    lbl.TextSize = 11
    lbl.Font = Enum.Font.Code
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextWrapped = false
    lbl.Text = text
    lbl.LayoutOrder = logOrder
    lbl.Parent = overlayScroll
    table.insert(logLines, lbl)
    if #logLines > LOG_MAX then
        logLines[1]:Destroy(); table.remove(logLines, 1)
    end
    task.defer(function()
        overlayScroll.CanvasPosition = Vector2.new(
            0, math.max(0, overlayScroll.AbsoluteCanvasSize.Y - overlayScroll.AbsoluteSize.Y))
    end)
end

-- ─── Rayfield ─────────────────────────────────────────────────────────────────
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Window = Rayfield:CreateWindow({
    Name             = "POE Assist",
    LoadingTitle     = "POE Assist",
    LoadingSubtitle  = "",
    ConfigurationSaving = { Enabled = false },
    Discord          = { Enabled = false },
    KeySystem        = false,
})

local TabBomb  = Window:CreateTab("Bomb",  4483362458)
local TabPVP   = Window:CreateTab("PVP",   4483362458)
local TabDebug = Window:CreateTab("Debug", 4483362458)

-- ─── Config ───────────────────────────────────────────────────────────────────
local cfg = {
    AutoPassBomb = false,
    BombTeleport = false,
    Noclip       = false,
    SpeedEnabled = false,
    NoFall       = false,
    AutoPunch    = false,
    AFK          = false,   -- AFK mode: auto handle bomb + idle naturally
}

local SPEED_BOMB      = 22
local SPEED_IDLE      = 20
local SPEED_DEFAULT   = 16
local MAX_TARGET_DIST = 200
local MAX_Y_DIFF      = 20
local PUNCH_Y_DIFF    = 15
local STOP_DIST       = 4
local PUNCH_RANGE     = 6
local PUNCH_RATE      = 0.45
local SPECTATOR_MARGIN = 12

-- AFK mode constants
local AFK_TELEPORT_THRESH = 3   -- teleport bomb if countdown <= this value
local AFK_IDLE_SPEED      = 16  -- walk speed when AFK and not holding bomb

-- ─── Bomb timer reader ────────────────────────────────────────────────────────
-- Reads countdown from: Workspace.[carrier].BombActive.Handle.BillboardGui.Countdown
-- Returns number (seconds remaining) or nil if bomb not found / not active
local function getBombTimer()
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then
            local bombTool = p.Character:FindFirstChild("BombActive")
            if bombTool then
                local handle = bombTool:FindFirstChild("Handle")
                if handle then
                    local bb = handle:FindFirstChildOfClass("BillboardGui")
                        or handle:FindFirstChild("BillboardGui")
                    if bb then
                        local lbl = bb:FindFirstChild("Countdown")
                        if lbl and lbl:IsA("TextLabel") then
                            local n = tonumber(lbl.Text)
                            if n then return n, p end
                        end
                    end
                end
            end
        end
    end
    return nil, nil
end

-- Arena Y: auto-detected each round, fallback 24
local arenaY       = 24
local arenaYLocked = false  -- true once detected this round

local punchTimer    = 0
local teleportTimer = 0
local noclipTimer   = 0
local noFallBV      = nil
local ghostActive   = false

-- ─── Remotes ──────────────────────────────────────────────────────────────────
local remoteAction  = nil
local remoteEndgame = nil
task.spawn(function()
    local events = RS:WaitForChild("Remotes", 10)
        and RS.Remotes:WaitForChild("Events", 10)
    if not events then return end
    remoteAction  = events:WaitForChild("ActionEvent",        10)
    remoteEndgame = events:WaitForChild("EndgameAttackEvent", 10)
end)

-- ─── Helpers ──────────────────────────────────────────────────────────────────
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

-- Auto-detect arena Y: called when character is standing still at round start.
-- Uses median of recent Y samples to avoid catching jump/fall frames.
local ySamples    = {}
local ySampleTimer = 0
local function updateArenaY(dt, myY)
    if arenaYLocked then return end
    ySampleTimer = ySampleTimer + dt
    if ySampleTimer >= 0.5 then
        ySampleTimer = 0
        table.insert(ySamples, myY)
        if #ySamples > 6 then table.remove(ySamples, 1) end
        if #ySamples >= 4 then
            -- Check variance: if Y is stable (player standing), lock it
            local sum = 0
            for _, v in ipairs(ySamples) do sum = sum + v end
            local mean = sum / #ySamples
            local maxDev = 0
            for _, v in ipairs(ySamples) do
                local d = math.abs(v - mean)
                if d > maxDev then maxDev = d end
            end
            if maxDev < 1.5 then
                arenaY = math.floor(mean + 0.5)
                arenaYLocked = true
                overlayLog(("ArenaY locked: %d"):format(arenaY), Color3.fromRGB(100,200,255))
            end
        end
    end
end

-- Reset arena detection each round (called on CharacterAdded + round transitions)
local function resetArenaY()
    arenaYLocked = false
    ySamples = {}
    ySampleTimer = 0
end

-- ─── Player filter ────────────────────────────────────────────────────────────
local function shouldSkip(p, myHRP)
    local c = p.Character; if not c then return "no_character" end
    local oh = getHRP(c);  if not oh then return "no_hrp" end
    local ph = getHum(c);  if not ph then return "no_humanoid" end
    if ph.Health <= 0 then return "health_zero" end
    if ph:GetState() == Enum.HumanoidStateType.Dead then return "state_dead" end
    local yAbs = oh.Position.Y
    -- Spectator check: above arena + margin
    if yAbs > (arenaY + SPECTATOR_MARGIN) then
        return ("y_high(%.1f)"):format(yAbs)
    end
    -- Below arena: fell off or underground
    if yAbs < (arenaY - SPECTATOR_MARGIN) then
        return ("y_low(%.1f)"):format(yAbs)
    end
    local dist = (myHRP.Position - oh.Position).Magnitude
    if dist > MAX_TARGET_DIST then return ("far(%.0f)"):format(dist) end
    return nil
end

local function nearestPlayer(punchYLimit, debugMode)
    local c = getChar(); local h = getHRP(c)
    if not h then
        if debugMode then return nil, math.huge, {} end
        return nil, math.huge
    end
    local best, bestDist = nil, math.huge
    local scanLog = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then
            local skipReason = shouldSkip(p, h)
            local oh = p.Character and getHRP(p.Character)
            -- Additional per-call Y diff filter (for punch specifically)
            if not skipReason and punchYLimit and oh then
                local yd = math.abs(h.Position.Y - oh.Position.Y)
                if yd > punchYLimit then
                    skipReason = ("yd(%.1f)"):format(yd)
                end
            end
            local dist = oh and (h.Position - oh.Position).Magnitude or math.huge
            if debugMode then
                local ph2 = p.Character and getHum(p.Character)
                table.insert(scanLog, {
                    name   = p.Name,
                    dist   = dist,
                    health = ph2 and ph2.Health or -1,
                    yAbs   = oh and oh.Position.Y or -999,
                    skip   = skipReason or "OK",
                })
            end
            if not skipReason and dist < bestDist then
                bestDist = dist; best = p
            end
        end
    end
    if debugMode then return best, bestDist, scanLog end
    return best, bestDist
end

-- ─── Noclip / NoFall ──────────────────────────────────────────────────────────
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
    bv.Name = "NoFallBV"
    bv.Velocity = Vector3.new(0,0,0)
    bv.MaxForce = Vector3.new(0,0,0)
    bv.Parent = r
    noFallBV = bv
end

-- ─── firePunch ────────────────────────────────────────────────────────────────
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
            VIM:SendMouseButtonEvent(sp.X, sp.Y, 0, true, game, 0)
            task.delay(0.06, function()
                VIM:SendMouseButtonEvent(sp.X, sp.Y, 0, false, game, 0)
            end)
        end
    end)
end

-- ─── Main loop ────────────────────────────────────────────────────────────────
RunService.Heartbeat:Connect(function(dt)
    local c = getChar(); local h = getHum(c)
    if not h or h.Health <= 0 then return end
    local r = getHRP(c); if not r then return end

    -- Arena Y auto-detection (only when not yet locked this round)
    updateArenaY(dt, r.Position.Y)

    local holding = hasBomb(c)
    local chasing = holding and (cfg.AutoPassBomb or cfg.BombTeleport)

    -- Speed
    local targetSpd = SPEED_DEFAULT
    if cfg.SpeedEnabled then targetSpd = chasing and SPEED_BOMB or SPEED_IDLE end
    if h.WalkSpeed ~= targetSpd then h.WalkSpeed = targetSpd end

    -- Noclip
    if cfg.Noclip then
        noclipTimer = noclipTimer + dt
        if noclipTimer >= 0.3 then noclipTimer = 0; applyNoclip(c, true) end
    elseif ghostActive then
        applyNoclip(c, false); noclipTimer = 0
    end

    -- Bomb Teleport (manual, skip if AFK handles it)
    if cfg.BombTeleport and not cfg.AFK and holding then
        teleportTimer = teleportTimer + dt
        if teleportTimer >= 0.25 then
            teleportTimer = 0
            local target = nearestPlayer(MAX_Y_DIFF)
            if target and target.Character then
                local oh = getHRP(target.Character)
                if oh then
                    local preCF = r.CFrame
                    local preY  = r.Position.Y
                    local dir   = oh.CFrame.LookVector
                    r.CFrame    = CFrame.new(oh.Position + Vector3.new(dir.X,0,dir.Z)*3, oh.Position)
                    task.defer(function()
                        local pr = getHRP(getChar())
                        if pr and (preY - pr.Position.Y) > 12 then pr.CFrame = preCF end
                    end)
                end
            end
        end
    else
        teleportTimer = 0
    end

    -- Bomb timer (read every frame, cheap)
    local bombTimer, bombCarrier = getBombTimer()

    -- AFK Mode: handles bomb automatically when holding, idles naturally when not
    -- Logic:
    --   holding + timer <= AFK_TELEPORT_THRESH → teleport (guaranteed pass, beats obstacles)
    --   holding + timer >  AFK_TELEPORT_THRESH → run toward nearest player (overshoot)
    --   not holding → stop movement, stand still (look natural)
    if cfg.AFK then
        if holding then
            local target, dist = nearestPlayer(nil)
            if target and target.Character then
                local oh = getHRP(target.Character)
                if oh then
                    local shouldTeleport = bombTimer and bombTimer <= AFK_TELEPORT_THRESH
                    if shouldTeleport or (cfg.BombTeleport) then
                        -- Emergency teleport: snap in front of target
                        local preCF = r.CFrame
                        local preY  = r.Position.Y
                        local dir   = oh.CFrame.LookVector
                        r.CFrame    = CFrame.new(
                            oh.Position + Vector3.new(dir.X,0,dir.Z)*3,
                            oh.Position)
                        task.defer(function()
                            local pr = getHRP(getChar())
                            if pr and (preY - pr.Position.Y) > 12 then
                                pr.CFrame = preCF
                            end
                        end)
                    elseif dist > STOP_DIST then
                        -- Run toward target, overshoot so no decel zone
                        if noFallBV then noFallBV.MaxForce = Vector3.new(0,0,0) end
                        local d = Vector3.new(
                            oh.Position.X-r.Position.X, 0,
                            oh.Position.Z-r.Position.Z)
                        h:MoveTo(oh.Position + d.Unit * 8)
                    end
                end
            end
        else
            -- Not holding: stop moving, look natural
            h:Move(Vector3.new(0,0,0), false)
        end
    end

    -- Auto Pass Bomb (manual mode, independent of AFK)
    if cfg.AutoPassBomb and not cfg.BombTeleport and not cfg.AFK and holding then
        if noFallBV then noFallBV.MaxForce = Vector3.new(0,0,0) end
        local target, dist = nearestPlayer(nil)
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh and dist > STOP_DIST then
                local d = Vector3.new(oh.Position.X-r.Position.X, 0, oh.Position.Z-r.Position.Z)
                h:MoveTo(oh.Position + d.Unit * 8)
            end
        end
    end

    -- Bomb Teleport manual (skip if AFK handles it)
    -- (moved inside AFK block above for AFK mode, kept here for manual use)

    -- No Fall
    if cfg.NoFall and noFallBV and r then
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            noFallBV.MaxForce = Vector3.new(0, 1e6, 0)
            noFallBV.Velocity = Vector3.new(0, 0, 0)
        else
            noFallBV.MaxForce = Vector3.new(0, 0, 0)
        end
    end

    -- Auto Punch
    if cfg.AutoPunch then
        local myY = r.Position.Y
        -- Safety: if we're far from arena Y (mid-air from knockback), wait
        if math.abs(myY - arenaY) > 20 then
            return
        end
        local target, dist = nearestPlayer(PUNCH_Y_DIFF)
        if target and target.Character then
            local oh = getHRP(target.Character)
            if oh then
                if dist > PUNCH_RANGE then
                    h:MoveTo(oh.Position)
                else
                    punchTimer = punchTimer + dt
                    if punchTimer >= PUNCH_RATE then
                        punchTimer = 0
                        firePunch(target.Character, oh)
                    end
                end
            end
        else
            h:MoveTo(r.Position)
            punchTimer = 0
        end
    else
        punchTimer = 0
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    noFallBV = nil; ghostActive = false
    noclipTimer = 0; teleportTimer = 0; punchTimer = 0
    resetArenaY()
    task.wait(1)
    if cfg.NoFall then setupNoFall(true) end
end)

-- ─── UI: Bomb ─────────────────────────────────────────────────────────────────
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
TabBomb:CreateSlider({ Name = "Bomb Speed", Range = {16,40}, Increment = 1, CurrentValue = 22,
    Flag = "BombSpeed", Callback = function(v) SPEED_BOMB = v end })
TabBomb:CreateSlider({ Name = "Idle Speed", Range = {16,30}, Increment = 1, CurrentValue = 20,
    Flag = "IdleSpeed", Callback = function(v) SPEED_IDLE = v end })
TabBomb:CreateSection("AFK Mode")
TabBomb:CreateToggle({ Name = "AFK Mode", CurrentValue = false, Flag = "AFK",
    Callback = function(v) cfg.AFK = v end })
TabBomb:CreateSlider({ Name = "Teleport at Timer <=", Range = {1,6}, Increment = 1, CurrentValue = 3,
    Flag = "AFKTeleportThresh", Callback = function(v) AFK_TELEPORT_THRESH = v end })

-- ─── UI: PVP ──────────────────────────────────────────────────────────────────
TabPVP:CreateToggle({ Name = "No Fall", CurrentValue = false, Flag = "NoFall",
    Callback = function(v) cfg.NoFall = v; setupNoFall(v) end })
TabPVP:CreateToggle({ Name = "Auto Punch", CurrentValue = false, Flag = "AutoPunch",
    Callback = function(v) cfg.AutoPunch = v; punchTimer = 0 end })
TabPVP:CreateSlider({ Name = "Spectator Y Margin", Range = {5,40}, Increment = 1, CurrentValue = 12,
    Flag = "SpectatorMargin", Callback = function(v) SPECTATOR_MARGIN = v end })

-- ─── UI: Debug ────────────────────────────────────────────────────────────────
TabDebug:CreateSection("Overlay")
TabDebug:CreateToggle({ Name = "Show Log Overlay", CurrentValue = false, Flag = "ShowOverlay",
    Callback = function(v) overlayFrame.Visible = v end })
TabDebug:CreateButton({ Name = "Clear Overlay", Callback = function()
    for _, lbl in ipairs(logLines) do lbl:Destroy() end
    logLines = {}
end })

TabDebug:CreateSection("Player Scan")
TabDebug:CreateButton({ Name = "Full Scan", Callback = function()
    local c = getChar(); local r = getHRP(c)
    if not r then
        Rayfield:Notify({ Title="Debug", Content="No character", Duration=4 })
        return
    end
    local _, _, scanLog = nearestPlayer(PUNCH_Y_DIFF, true)
    local okCount, skipCount = 0, 0
    overlayLog(("=SCAN ArenaY=%d SelfY=%.1f"):format(arenaY, r.Position.Y), Color3.fromRGB(180,180,255))
    for _, e in ipairs(scanLog) do
        local passed = e.skip == "OK"
        if passed then okCount = okCount + 1 else skipCount = skipCount + 1 end
        overlayLog(
            ("[%s] %s d=%.0f hp=%.0f Y=%.1f %s"):format(
                passed and "OK" or "SK",
                e.name:sub(1,12),
                e.dist, e.health, e.yAbs,
                passed and "" or ("("..e.skip..")")
            ),
            passed and Color3.fromRGB(100,255,100) or Color3.fromRGB(255,120,80)
        )
    end
    overlayLog(("OK=%d Skip=%d"):format(okCount, skipCount))
    overlayFrame.Visible = true
    Rayfield:Notify({
        Title   = ("Scan: %d players"):format(#scanLog),
        Content = ("OK=%d  Skip=%d\nArenaY=%d  SelfY=%.1f"):format(
            okCount, skipCount, arenaY, r.Position.Y),
        Duration = 6
    })
end })

TabDebug:CreateButton({ Name = "Quick: Self + Target", Callback = function()
    local c = getChar(); local r = getHRP(c)
    if not r then return end
    local target, dist, scanLog = nearestPlayer(PUNCH_Y_DIFF, true)
    overlayFrame.Visible = true
    overlayLog(("SelfY=%.2f ArenaY=%d locked=%s"):format(
        r.Position.Y, arenaY, tostring(arenaYLocked)),
        Color3.fromRGB(180,180,255))
    if target then
        local oh = getHRP(target.Character)
        overlayLog(("Target:%s d=%.1f Y=%.2f"):format(
            target.Name, dist, oh and oh.Position.Y or -1))
    else
        overlayLog("No target")
    end
    for _, e in ipairs(scanLog) do
        if e.skip ~= "OK" then
            overlayLog(("  skip:%s > %s"):format(e.name:sub(1,10), e.skip),
                Color3.fromRGB(255,160,60))
        end
    end
end })

local continuousActive = false
TabDebug:CreateToggle({ Name = "Continuous Scan (2s)", CurrentValue = false, Flag = "ContScan",
    Callback = function(v)
        continuousActive = v
        overlayFrame.Visible = v
        if v then
            task.spawn(function()
                while continuousActive do
                    local c2 = getChar(); local r2 = getHRP(c2)
                    if r2 then
                        local _, _, scanLog = nearestPlayer(PUNCH_Y_DIFF, true)
                        local ok2, sk2 = {}, {}
                        for _, e in ipairs(scanLog) do
                            if e.skip == "OK" then
                                table.insert(ok2, e.name:sub(1,7).."("..math.floor(e.dist)..")")
                            else
                                table.insert(sk2, e.name:sub(1,7).."["..e.skip.."]")
                            end
                        end
                        local bTimer, bCarrier = getBombTimer()
                        local timerStr = bTimer and ("T="..tostring(bTimer)) or "T=?"
                        local carrierStr = bCarrier and bCarrier.Name:sub(1,8) or "none"
                        overlayLog(("Y=%.1f aY=%d %s carrier=%s | OK:%s"):format(
                            r2.Position.Y, arenaY, timerStr, carrierStr,
                            #ok2 > 0 and table.concat(ok2,",") or "none"))
                        if #sk2 > 0 then
                            overlayLog("sk:"..table.concat(sk2,","),
                                Color3.fromRGB(255,160,60))
                        end
                    end
                    task.wait(2)
                end
            end)
        end
    end
})

TabDebug:CreateSection("Bomb Timer Scanner")

-- Shorten a full path to last N components so it fits on one overlay line
local function shortPath(fullPath, n)
    n = n or 4
    local parts = {}
    for seg in fullPath:gmatch("[^%.]+") do table.insert(parts, seg) end
    local start = math.max(1, #parts - n + 1)
    local out = {}
    for i = start, #parts do table.insert(out, parts[i]) end
    return table.concat(out, ".")
end

-- Live scan: only logs when value changes, shows last 4 path segments
local timerScanActive = false
TabDebug:CreateToggle({ Name = "Scan Bomb Timer (live)", CurrentValue = false, Flag = "TimerScan",
    Callback = function(v)
        timerScanActive = v
        overlayFrame.Visible = v
        if v then
            task.spawn(function()
                local lastSnapshot = {}  -- path -> val
                while timerScanActive do
                    local roots = { LocalPlayer.PlayerGui }
                    pcall(function() table.insert(roots, game:GetService("CoreGui")) end)
                    local snapshot = {}
                    for _, root in ipairs(roots) do
                        for _, lbl in ipairs(root:GetDescendants()) do
                            if lbl:IsA("TextLabel") or lbl:IsA("TextButton") then
                                local txt = lbl.Text:match("^%s*(%d+)%s*$")
                                local num = txt and tonumber(txt)
                                if num and num >= 1 and num <= 15 and lbl.Visible then
                                    snapshot[lbl:GetFullName()] = num
                                end
                            end
                        end
                    end
                    -- Log only changed entries
                    for path, val in pairs(snapshot) do
                        if lastSnapshot[path] ~= val then
                            overlayLog(
                                ("[T] %d | %s"):format(val, shortPath(path, 4)),
                                Color3.fromRGB(255,215,0)
                            )
                        end
                    end
                    -- Log entries that disappeared
                    for path, _ in pairs(lastSnapshot) do
                        if not snapshot[path] then
                            overlayLog(
                                ("[T] gone | %s"):format(shortPath(path, 4)),
                                Color3.fromRGB(160,160,160)
                            )
                        end
                    end
                    lastSnapshot = snapshot
                    task.wait(0.3)
                end
            end)
        end
    end
})

-- Dump: visible numeric labels only, shortened path, during active round
-- Run this WHILE bomb countdown is on screen
TabDebug:CreateButton({ Name = "Dump Numeric Labels (visible)", Callback = function()
    local roots = { LocalPlayer.PlayerGui }
    pcall(function() table.insert(roots, game:GetService("CoreGui")) end)
    local results = {}
    for _, root in ipairs(roots) do
        for _, lbl in ipairs(root:GetDescendants()) do
            if (lbl:IsA("TextLabel") or lbl:IsA("TextButton")) and lbl.Visible then
                local txt = lbl.Text:match("^%s*(%d+%.?%d*)%s*$")
                if txt then
                    table.insert(results, { short = shortPath(lbl:GetFullName(), 5), val = txt })
                end
            end
        end
    end
    overlayFrame.Visible = true
    overlayLog(("=VIS LABELS %d"):format(#results), Color3.fromRGB(180,180,255))
    for _, r2 in ipairs(results) do
        overlayLog(("v=%s %s"):format(r2.val, r2.short), Color3.fromRGB(220,220,100))
    end
    Rayfield:Notify({ Title=("Labels:%d"):format(#results), Content="Check overlay", Duration=4 })
end })

-- Workspace bomb object scanner: look for Parts/Models with bomb-related names
-- or with IntValue/NumberValue children that could be a timer
TabDebug:CreateButton({ Name = "Scan Workspace Bomb Objects", Callback = function()
    local BOMB_KEYWORDS = {"bomb","timer","countdown","fuse","explosive","tnt"}
    local function matchesBomb(name)
        local l = name:lower()
        for _, kw in ipairs(BOMB_KEYWORDS) do
            if l:find(kw, 1, true) then return true end
        end
        return false
    end
    local found = {}
    for _, obj in ipairs(workspace:GetDescendants()) do
        if matchesBomb(obj.Name) then
            -- Collect any numeric children (timer values)
            local vals = {}
            for _, child in ipairs(obj:GetChildren()) do
                if child:IsA("IntValue") or child:IsA("NumberValue") or child:IsA("StringValue") then
                    table.insert(vals, child.Name.."="..tostring(child.Value))
                end
            end
            table.insert(found, {
                name  = obj.Name,
                class = obj.ClassName,
                path  = shortPath(obj:GetFullName(), 4),
                vals  = table.concat(vals, ","),
            })
        end
    end
    overlayFrame.Visible = true
    overlayLog(("=WS BOMB SCAN found=%d"):format(#found), Color3.fromRGB(180,180,255))
    if #found == 0 then
        overlayLog("Nothing found. Try during active round.", Color3.fromRGB(160,160,160))
    else
        for _, f in ipairs(found) do
            overlayLog(
                ("[%s] %s | %s"):format(f.class:sub(1,6), f.path,
                    f.vals ~= "" and f.vals or "no values"),
                Color3.fromRGB(100,255,200)
            )
        end
    end
    Rayfield:Notify({ Title="WS Bomb Scan", Content=(#found.." objects found\nCheck overlay"), Duration=5 })
end })

TabDebug:CreateSection("Movement Logger")

-- Log nearest target's movement direction every 0.5s
-- Goal: understand movement patterns for "follow step" implementation
local moveLogActive  = false
local prevTargetPos  = nil
local moveLogTimer   = 0
TabDebug:CreateToggle({ Name = "Log Target Movement", CurrentValue = false, Flag = "MoveLog",
    Callback = function(v)
        moveLogActive = v
        overlayFrame.Visible = v
        if not v then prevTargetPos = nil; moveLogTimer = 0 end
        if v then
            task.spawn(function()
                while moveLogActive do
                    local c2 = getChar(); local r2 = getHRP(c2)
                    if r2 then
                        local target = nearestPlayer(PUNCH_Y_DIFF)
                        if target and target.Character then
                            local oh = getHRP(target.Character)
                            if oh then
                                local curPos = oh.Position
                                if prevTargetPos then
                                    local delta = curPos - prevTargetPos
                                    local flatDelta = Vector3.new(delta.X, 0, delta.Z)
                                    local speed = flatDelta.Magnitude / 0.5  -- studs/sec
                                    local dirStr = "idle"
                                    if speed > 0.5 then
                                        -- Encode direction as rough compass
                                        local angle = math.deg(math.atan2(flatDelta.X, flatDelta.Z))
                                        if angle < 0 then angle = angle + 360 end
                                        local dirs = {"N","NE","E","SE","S","SW","W","NW"}
                                        local idx = math.floor((angle + 22.5) / 45) % 8 + 1
                                        dirStr = dirs[idx]
                                    end
                                    overlayLog(
                                        ("%s spd=%.1f dir=%s dY=%.1f"):format(
                                            target.Name:sub(1,10),
                                            speed, dirStr, delta.Y
                                        ),
                                        speed > 1 and Color3.fromRGB(100,255,150) or Color3.fromRGB(160,160,160)
                                    )
                                end
                                prevTargetPos = curPos
                            end
                        else
                            prevTargetPos = nil
                        end
                    end
                    task.wait(0.5)
                end
            end)
        end
    end
})

TabDebug:CreateSection("Live Tune")
TabDebug:CreateButton({ Name = "Reset Arena Y Detection", Callback = function()
    resetArenaY()
    overlayLog("ArenaY reset, re-detecting...", Color3.fromRGB(255,215,0))
    overlayFrame.Visible = true
    Rayfield:Notify({ Title="Arena Y", Content="Reset. Stand still on arena to re-detect.", Duration=5 })
end })
TabDebug:CreateSlider({ Name = "Punch Y Diff", Range = {5,30}, Increment = 1, CurrentValue = 15,
    Flag = "PunchYDiff", Callback = function(v) PUNCH_Y_DIFF = v end })
TabDebug:CreateSlider({ Name = "Max Target Dist", Range = {20,300}, Increment = 5, CurrentValue = 200,
    Flag = "MaxTargetDist", Callback = function(v) MAX_TARGET_DIST = v end })
