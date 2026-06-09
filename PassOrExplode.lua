local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")
local VIM        = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

-- ─── Overlay log (mobile-friendly, replaces F9 console) ──────────────────────
local overlayGui = Instance.new("ScreenGui")
overlayGui.Name = "POEDebugOverlay"
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

local LOG_MAX = 40
local logLines = {}
local logOrder = 0

local function overlayLog(text)
    logOrder = logOrder + 1
    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(1, 0, 0, 14)
    lbl.BackgroundTransparency = 1
    lbl.TextColor3 = Color3.fromRGB(220, 220, 220)
    lbl.TextSize = 11
    lbl.Font = Enum.Font.Code
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextWrapped = false
    lbl.Text = text
    lbl.LayoutOrder = logOrder
    lbl.Parent = overlayScroll
    table.insert(logLines, lbl)
    if #logLines > LOG_MAX then
        logLines[1]:Destroy()
        table.remove(logLines, 1)
    end
    -- Auto-scroll to bottom
    task.defer(function()
        overlayScroll.CanvasPosition = Vector2.new(0, math.max(0, overlayScroll.AbsoluteCanvasSize.Y - overlayScroll.AbsoluteSize.Y))
    end)
end

local function overlayLogColor(text, color)
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
    if #logLines > LOG_MAX then logLines[1]:Destroy(); table.remove(logLines, 1) end
    task.defer(function()
        overlayScroll.CanvasPosition = Vector2.new(0, math.max(0, overlayScroll.AbsoluteCanvasSize.Y - overlayScroll.AbsoluteSize.Y))
    end)
end

-- ─── Rayfield ─────────────────────────────────────────────────────────────────
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Window = Rayfield:CreateWindow({
    Name             = "POE Assist [DEBUG]",
    LoadingTitle     = "POE Assist",
    LoadingSubtitle  = "debug build",
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
}

local SPEED_BOMB       = 22
local SPEED_IDLE       = 20
local SPEED_DEFAULT    = 16
local MAX_TARGET_DIST  = 200
local MAX_Y_DIFF       = 15
local PUNCH_Y_DIFF     = 8
local PUNCH_DIST_MAX   = 60
local STOP_DIST        = 4
local PUNCH_RANGE      = 6
local PUNCH_RATE       = 0.45
local ARENA_Y_REF      = 24
local SPECTATOR_MARGIN = 12

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

-- ─── Player filter ────────────────────────────────────────────────────────────
local function shouldSkip(p, myHRP)
    local c = p.Character
    if not c then return "no_character" end
    local oh = getHRP(c); if not oh then return "no_hrp" end
    local ph = getHum(c); if not ph then return "no_humanoid" end
    if ph.Health <= 0 then return "health_zero" end
    local state = ph:GetState()
    if state == Enum.HumanoidStateType.Dead then return "state_dead" end
    local yAbs = oh.Position.Y
    if yAbs > (ARENA_Y_REF + SPECTATOR_MARGIN) then
        return ("y_too_high(%.1f)"):format(yAbs)
    end
    local yDiff = math.abs(myHRP.Position.Y - yAbs)
    if yDiff > MAX_Y_DIFF then
        return ("y_diff(%.1f)"):format(yDiff)
    end
    local dist = (myHRP.Position - oh.Position).Magnitude
    if dist > MAX_TARGET_DIST then return ("too_far(%.0f)"):format(dist) end
    return nil
end

local function nearestPlayer(yDiffLimit, debugMode)
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
            if not skipReason and yDiffLimit and oh then
                local yd = math.abs(h.Position.Y - oh.Position.Y)
                if yd > yDiffLimit then
                    skipReason = ("punch_yd(%.1f)"):format(yd)
                end
            end
            local dist = oh and (h.Position - oh.Position).Magnitude or math.huge
            if debugMode then
                local ph2 = p.Character and getHum(p.Character)
                local yAbs = oh and oh.Position.Y or -999
                table.insert(scanLog, {
                    name   = p.Name,
                    dist   = dist,
                    health = ph2 and ph2.Health or -1,
                    state  = ph2 and tostring(ph2:GetState()) or "?",
                    yAbs   = yAbs,
                    yDiff  = oh and math.abs(h.Position.Y - yAbs) or -1,
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
local LEG_NAMES = {"LeftFoot","RightFoot","LeftLowerLeg","RightLowerLeg","LeftUpperLeg","RightUpperLeg","Left Leg","Right Leg"}
local function isLeg(n) for _,v in ipairs(LEG_NAMES) do if n==v then return true end end return false end

local function applyNoclip(c, on)
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and not isLeg(p.Name) then
            if on then p.CanCollide = false
            else p.CanCollide = true end
        end
    end
    ghostActive = on
end

local function setupNoFall(enable)
    if noFallBV then pcall(function() noFallBV:Destroy() end); noFallBV = nil end
    if not enable then return end
    local r = getHRP(getChar()); if not r then return end
    local bv = Instance.new("BodyVelocity")
    bv.Name = "NoFallBV"; bv.Velocity = Vector3.new(0,0,0)
    bv.MaxForce = Vector3.new(0,0,0); bv.Parent = r; noFallBV = bv
end

-- ─── Remotes: scan helper ─────────────────────────────────────────────────────
local COIN_KEYWORDS = {"coin","currency","score","reward","money","cash","gold","point","earn","collect"}
local function matchesCoinKeyword(name)
    local lower = name:lower()
    for _, kw in ipairs(COIN_KEYWORDS) do
        if lower:find(kw, 1, true) then return true end
    end
    return false
end

local function scanRemotesDeep(root, results, depth)
    depth = depth or 0
    if depth > 5 then return end
    for _, child in ipairs(root:GetChildren()) do
        if child:IsA("RemoteEvent") or child:IsA("RemoteFunction") then
            table.insert(results, {
                name  = child.Name,
                class = child.ClassName,
                path  = child:GetFullName(),
                coin  = matchesCoinKeyword(child.Name),
                ref   = child,
            })
        end
        if #child:GetChildren() > 0 then
            scanRemotesDeep(child, results, depth + 1)
        end
    end
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

    local holding = hasBomb(c)
    local chasing = holding and (cfg.AutoPassBomb or cfg.BombTeleport)

    local targetSpd = SPEED_DEFAULT
    if cfg.SpeedEnabled then targetSpd = chasing and SPEED_BOMB or SPEED_IDLE end
    if h.WalkSpeed ~= targetSpd then h.WalkSpeed = targetSpd end

    if cfg.Noclip then
        noclipTimer = noclipTimer + dt
        if noclipTimer >= 0.3 then noclipTimer = 0; applyNoclip(c, true) end
    elseif ghostActive then
        applyNoclip(c, false); noclipTimer = 0
    end

    if cfg.BombTeleport and holding then
        teleportTimer = teleportTimer + dt
        if teleportTimer >= 0.25 then
            teleportTimer = 0
            local target = nearestPlayer(MAX_Y_DIFF)
            if target and target.Character then
                local oh = getHRP(target.Character)
                if oh then
                    local preY = r.Position.Y; local preCF = r.CFrame
                    local dir  = oh.CFrame.LookVector
                    r.CFrame   = CFrame.new(oh.Position + Vector3.new(dir.X,0,dir.Z)*3, oh.Position)
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

    if cfg.AutoPassBomb and not cfg.BombTeleport and holding then
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

    if cfg.NoFall and noFallBV and r then
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            noFallBV.MaxForce = Vector3.new(0, 1e6, 0)
            noFallBV.Velocity = Vector3.new(0, 0, 0)
        else
            noFallBV.MaxForce = Vector3.new(0, 0, 0)
        end
    end

    if cfg.AutoPunch then
        local myY = r.Position.Y
        if math.abs(myY - ARENA_Y_REF) > 20 then return end
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
    task.wait(1)
    if cfg.NoFall then setupNoFall(true) end
end)

-- ─── UI: Bomb tab ─────────────────────────────────────────────────────────────
TabBomb:CreateToggle({ Name = "Auto Pass Bomb", CurrentValue = false, Flag = "AutoPassBomb",
    Callback = function(v) cfg.AutoPassBomb = v end })
TabBomb:CreateToggle({ Name = "Bomb Teleport", CurrentValue = false, Flag = "BombTeleport",
    Callback = function(v) cfg.BombTeleport = v end })
TabBomb:CreateToggle({ Name = "Ghost Mode", CurrentValue = false, Flag = "Noclip",
    Callback = function(v)
        cfg.Noclip = v
        if not v and ghostActive then local c=getChar(); if c then applyNoclip(c,false) end end
    end })
TabBomb:CreateToggle({ Name = "Speed Boost", CurrentValue = false, Flag = "SpeedBoost",
    Callback = function(v) cfg.SpeedEnabled = v end })
TabBomb:CreateSlider({ Name = "Bomb Speed", Range = {16,40}, Increment = 1, CurrentValue = 22, Flag = "BombSpeed",
    Callback = function(v) SPEED_BOMB = v end })
TabBomb:CreateSlider({ Name = "Idle Speed", Range = {16,30}, Increment = 1, CurrentValue = 20, Flag = "IdleSpeed",
    Callback = function(v) SPEED_IDLE = v end })

-- ─── UI: PVP tab ──────────────────────────────────────────────────────────────
TabPVP:CreateToggle({ Name = "No Fall", CurrentValue = false, Flag = "NoFall",
    Callback = function(v) cfg.NoFall = v; setupNoFall(v) end })
TabPVP:CreateToggle({ Name = "Auto Punch", CurrentValue = false, Flag = "AutoPunch",
    Callback = function(v) cfg.AutoPunch = v; punchTimer = 0 end })
TabPVP:CreateSlider({ Name = "Spectator Y Margin", Range = {5,40}, Increment = 1, CurrentValue = 12,
    Flag = "SpectatorMargin",
    Callback = function(v) SPECTATOR_MARGIN = v end })
TabPVP:CreateSlider({ Name = "Arena Y Reference", Range = {0,60}, Increment = 1, CurrentValue = 24,
    Flag = "ArenaYRef",
    Callback = function(v) ARENA_Y_REF = v end })

-- ─── UI: Debug tab ────────────────────────────────────────────────────────────
TabDebug:CreateSection("Overlay")

TabDebug:CreateToggle({ Name = "Show Log Overlay", CurrentValue = false, Flag = "ShowOverlay",
    Callback = function(v)
        overlayFrame.Visible = v
    end })

TabDebug:CreateButton({ Name = "Clear Overlay", Callback = function()
    for _, lbl in ipairs(logLines) do lbl:Destroy() end
    logLines = {}
end })

TabDebug:CreateSection("Player Scanner")

TabDebug:CreateButton({ Name = "Full Player Scan", Callback = function()
    local c = getChar(); local r = getHRP(c)
    if not r then
        Rayfield:Notify({ Title="Debug", Content="No character", Duration=4 })
        return
    end
    local _, _, scanLog = nearestPlayer(PUNCH_Y_DIFF, true)
    local okCount, skipCount = 0, 0
    overlayLog(("=SCAN SelfY=%.1f ArenaRef=%d"):format(r.Position.Y, ARENA_Y_REF))
    for _, e in ipairs(scanLog) do
        local passed = e.skip == "OK"
        if passed then okCount = okCount + 1 else skipCount = skipCount + 1 end
        local line = ("[%s] %s d=%.0f hp=%.0f Y=%.1f %s"):format(
            passed and "OK" or "SK",
            e.name:sub(1,12),
            e.dist, e.health, e.yAbs, passed and "" or ("("..e.skip..")")
        )
        overlayLogColor(line, passed and Color3.fromRGB(100,255,100) or Color3.fromRGB(255,120,80))
    end
    overlayLog(("OK=%d Skip=%d"):format(okCount, skipCount))
    overlayFrame.Visible = true
    Rayfield:Notify({
        Title   = ("Scan: %d players"):format(#scanLog),
        Content = ("OK=%d  Skip=%d\nSelfY=%.1f\nSee overlay (left side)"):format(okCount, skipCount, r.Position.Y),
        Duration = 6
    })
end })

TabDebug:CreateButton({ Name = "Quick: Self + Target", Callback = function()
    local c = getChar(); local r = getHRP(c)
    if not r then return end
    local target, dist, scanLog = nearestPlayer(PUNCH_Y_DIFF, true)
    local lines = {}
    table.insert(lines, ("SelfY=%.2f"):format(r.Position.Y))
    if target then
        local oh = getHRP(target.Character)
        table.insert(lines, ("Target:%s"):format(target.Name))
        table.insert(lines, ("Dist=%.1f Y=%.2f"):format(dist, oh and oh.Position.Y or -1))
    else
        table.insert(lines, "No target")
    end
    local skipParts = {}
    for _, e in ipairs(scanLog) do
        if e.skip ~= "OK" then
            table.insert(skipParts, e.name:sub(1,8)..">"..e.skip)
        end
    end
    if #skipParts > 0 then
        table.insert(lines, "Skip:")
        for _, s in ipairs(skipParts) do table.insert(lines, "  "..s) end
    end
    overlayFrame.Visible = true
    for _, l in ipairs(lines) do overlayLog(l) end
    Rayfield:Notify({ Title="Quick Scan", Content=table.concat(lines,"\n"), Duration=8 })
end })

local continuousActive = false
TabDebug:CreateToggle({ Name = "Continuous Scan (2s)", CurrentValue = false, Flag = "ContinuousScan",
    Callback = function(v)
        continuousActive = v
        overlayFrame.Visible = v
        if v then
            task.spawn(function()
                while continuousActive do
                    local c2 = getChar(); local r2 = getHRP(c2)
                    if r2 then
                        local target, dist, scanLog = nearestPlayer(PUNCH_Y_DIFF, true)
                        local okList, skipList = {}, {}
                        for _, e in ipairs(scanLog) do
                            if e.skip == "OK" then
                                table.insert(okList, e.name:sub(1,8).."("..math.floor(e.dist)..")")
                            else
                                table.insert(skipList, e.name:sub(1,8).."["..e.skip.."]")
                            end
                        end
                        local selfY = r2.Position.Y
                        overlayLog(("Y=%.1f OK:%s"):format(selfY, #okList>0 and table.concat(okList,",") or "none"))
                        if #skipList > 0 then
                            overlayLogColor("Skip:"..table.concat(skipList,","), Color3.fromRGB(255,160,60))
                        end
                    end
                    task.wait(2)
                end
            end)
        end
    end
})

TabDebug:CreateSection("Coin / Remote Scanner")

TabDebug:CreateButton({ Name = "Scan Coin Remotes", Callback = function()
    local results = {}
    scanRemotesDeep(RS, results)
    -- Also scan workspace for any events there
    scanRemotesDeep(workspace, results)

    local coinHits = {}
    local allCount = 0
    for _, r in ipairs(results) do
        allCount = allCount + 1
        if r.coin then table.insert(coinHits, r) end
    end

    overlayFrame.Visible = true
    overlayLog(("=REMOTE SCAN total=%d coin=%d"):format(allCount, #coinHits))

    if #coinHits == 0 then
        overlayLog("No coin-keyword remotes found")
        overlayLog("Showing ALL remotes:")
        for _, r2 in ipairs(results) do
            overlayLog(("  [%s] %s"):format(r2.class:sub(1,2), r2.path))
        end
    else
        for _, r2 in ipairs(coinHits) do
            overlayLogColor(("[COIN] %s"):format(r2.path), Color3.fromRGB(255,215,0))
        end
        overlayLog("--- All remotes ---")
        for _, r2 in ipairs(results) do
            overlayLog(("  [%s] %s"):format(r2.class:sub(1,2), r2.path))
        end
    end

    local summary = ("%d remotes found\n%d match coin keywords\nCheck overlay"):format(allCount, #coinHits)
    Rayfield:Notify({ Title="Remote Scan", Content=summary, Duration=8 })
end })

-- Fire a coin remote by name with a test value
-- Usage: type remote name in slider (workaround: buttons for common patterns)
TabDebug:CreateButton({ Name = "Try Fire: AddCoins +999", Callback = function()
    local results = {}
    scanRemotesDeep(RS, results)
    scanRemotesDeep(workspace, results)

    local fired = 0
    for _, r2 in ipairs(results) do
        if r2.coin and r2.class == "RemoteEvent" then
            -- Try several payload patterns
            pcall(function() r2.ref:FireServer(999) end)
            pcall(function() r2.ref:FireServer("add", 999) end)
            pcall(function() r2.ref:FireServer({amount=999}) end)
            fired = fired + 1
            overlayLogColor(("FIRED: %s"):format(r2.name), Color3.fromRGB(255,215,0))
        end
    end
    overlayFrame.Visible = true
    Rayfield:Notify({
        Title   = "Fire Attempt",
        Content = ("Fired %d coin remote(s)\nCheck if balance changed"):format(fired),
        Duration = 6
    })
end })

TabDebug:CreateButton({ Name = "Try Fire: ActionEvent Coins", Callback = function()
    -- Try common action strings that might add coins
    local actions = {"AddCoins","addCoins","earn","collect","reward","GiveCoins","giveCoins","coin"}
    if remoteAction then
        for _, a in ipairs(actions) do
            pcall(function() remoteAction:FireServer(a) end)
            pcall(function() remoteAction:FireServer(a, 999) end)
        end
        overlayFrame.Visible = true
        overlayLog("Fired ActionEvent with coin strings")
        overlayLog("Check balance change")
        Rayfield:Notify({ Title="ActionEvent Fire", Content="Tried coin strings\nCheck if balance changed", Duration=6 })
    else
        Rayfield:Notify({ Title="ActionEvent", Content="remoteAction not loaded yet", Duration=4 })
    end
end })

TabDebug:CreateSection("Thresholds (live-tune)")
TabDebug:CreateSlider({ Name = "Punch Y Diff", Range = {3,25}, Increment = 1, CurrentValue = 8,
    Flag = "PunchYDiff", Callback = function(v) PUNCH_Y_DIFF = v end })
TabDebug:CreateSlider({ Name = "Max Target Dist", Range = {20,300}, Increment = 5, CurrentValue = 200,
    Flag = "MaxTargetDist", Callback = function(v) MAX_TARGET_DIST = v end })
TabDebug:CreateSlider({ Name = "Punch Dist Max", Range = {10,100}, Increment = 5, CurrentValue = 60,
    Flag = "PunchDistMax", Callback = function(v) PUNCH_DIST_MAX = v end })
