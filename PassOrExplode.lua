local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")
local VIM        = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

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

local cfg = {
    AutoPassBomb = false,
    BombTeleport = false,
    Noclip       = false,
    SpeedEnabled = false,
    NoFall       = false,
    AutoPunch    = false,
}

local SPEED_BOMB      = 22
local SPEED_IDLE      = 20
local SPEED_DEFAULT   = 16
local MAX_TARGET_DIST = 200
local MAX_Y_DIFF      = 15
local PUNCH_Y_DIFF    = 8
local PUNCH_DIST_MAX  = 60   -- raised from 15 so chase actually kicks in
local STOP_DIST       = 4
local PUNCH_RANGE     = 6
local PUNCH_RATE      = 0.45
-- Arena Y reference from previous session: ~24
-- Players with Y > ARENA_Y + SPECTATOR_Y_MARGIN are treated as spectators
local ARENA_Y_REF     = 24
local SPECTATOR_MARGIN = 12  -- tune this after seeing debug output

local punchTimer    = 0
local teleportTimer = 0
local noclipTimer   = 0
local noFallBV      = nil
local ghostActive   = false

local remoteAction   = nil
local remoteEndgame  = nil
task.spawn(function()
    local events = RS:WaitForChild("Remotes", 10)
        and RS.Remotes:WaitForChild("Events", 10)
    if not events then return end
    remoteAction  = events:WaitForChild("ActionEvent",        10)
    remoteEndgame = events:WaitForChild("EndgameAttackEvent", 10)
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
    return ok and val == true
end

-- ─── Player filter: returns reason string if skip, nil if ok ─────────────────
local function shouldSkip(p, myHRP)
    local c = p.Character
    if not c then return "no_character" end
    local oh = getHRP(c)
    if not oh then return "no_hrp" end
    local ph = getHum(c)
    if not ph then return "no_humanoid" end

    -- Health check
    if ph.Health <= 0 then return "health_zero" end

    -- Humanoid state check (catches dead/ragdoll cheaters better than health alone)
    local state = ph:GetState()
    if state == Enum.HumanoidStateType.Dead then return "state_dead" end

    -- Y absolute: if way above arena Y ref, likely spectator platform
    local yAbs = oh.Position.Y
    if yAbs > (ARENA_Y_REF + SPECTATOR_MARGIN) then
        return ("y_too_high(%.1f)"):format(yAbs)
    end

    -- Y diff relative to us
    local myY = myHRP.Position.Y
    local yDiff = math.abs(myY - yAbs)
    if yDiff > MAX_Y_DIFF then
        return ("y_diff_too_big(%.1f)"):format(yDiff)
    end

    -- Distance
    local dist = (myHRP.Position - oh.Position).Magnitude
    if dist > MAX_TARGET_DIST then return ("too_far(%.1f)"):format(dist) end

    return nil  -- passed all filters
end

-- nearestPlayer: returns (player, dist) or (nil, math.huge)
-- debugMode = true → also returns full scan table
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

            -- Additional punch-specific Y diff filter
            local oh = p.Character and getHRP(p.Character)
            if not skipReason and yDiffLimit and oh then
                local yDiff = math.abs(h.Position.Y - oh.Position.Y)
                if yDiff > yDiffLimit then
                    skipReason = ("punch_ydiff(%.1f>%d)"):format(yDiff, yDiffLimit)
                end
            end

            local dist = math.huge
            if oh then dist = (h.Position - oh.Position).Magnitude end

            if debugMode then
                local ph = p.Character and getHum(p.Character)
                local yAbs = oh and oh.Position.Y or -999
                table.insert(scanLog, {
                    name   = p.Name,
                    dist   = dist,
                    health = ph and ph.Health or -1,
                    state  = ph and tostring(ph:GetState()) or "?",
                    yAbs   = yAbs,
                    yDiff  = oh and math.abs(h.Position.Y - yAbs) or -1,
                    skip   = skipReason or "OK_candidate",
                })
            end

            if not skipReason then
                if dist < bestDist then
                    bestDist = dist; best = p
                end
            end
        end
    end

    if debugMode then return best, bestDist, scanLog end
    return best, bestDist
end

local LEG_NAMES = {"LeftFoot","RightFoot","LeftLowerLeg","RightLowerLeg","LeftUpperLeg","RightUpperLeg","Left Leg","Right Leg"}
local function isLeg(n) for _,v in ipairs(LEG_NAMES) do if n==v then return true end end return false end

local function applyNoclip(c, on)
    for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") and not isLeg(p.Name) then
            if on and p.CanCollide then p.CanCollide = false end
            if not on and not p.CanCollide then p.CanCollide = true end
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
    if cfg.SpeedEnabled then
        targetSpd = chasing and SPEED_BOMB or SPEED_IDLE
    end
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

    -- Auto Punch (no knockback — client-side only, removed)
    if cfg.AutoPunch then
        local myY = r.Position.Y

        -- Safety: if we got knocked far from arena Y, stop movement and wait
        local yFromArena = math.abs(myY - ARENA_Y_REF)
        if yFromArena > 20 then
            -- We're probably mid-air from knockback, don't chase
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
            -- No valid target: stop any pending movement to avoid frozen state
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
TabBomb:CreateToggle({ Name = "Bomb Teleport",  CurrentValue = false, Flag = "BombTeleport",
    Callback = function(v) cfg.BombTeleport = v end })
TabBomb:CreateToggle({ Name = "Ghost Mode",     CurrentValue = false, Flag = "Noclip",
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
TabDebug:CreateSection("Player Scanner")

-- Dumps a full scan to console + shows summary in notify
TabDebug:CreateButton({ Name = "Dump Player Scan (F9 console)", Callback = function()
    local c = getChar(); local r = getHRP(c)
    if not r then
        Rayfield:Notify({ Title="Debug", Content="No character", Duration=4 })
        return
    end

    local _, _, scanLog = nearestPlayer(PUNCH_Y_DIFF, true)

    print("===== POE DEBUG SCAN =====")
    print(("Self: Y=%.2f  ArenaYRef=%d  SpectatorMargin=%d"):format(
        r.Position.Y, ARENA_Y_REF, SPECTATOR_MARGIN))
    print(("-"):rep(40))

    local okCount, skipCount = 0, 0
    for _, entry in ipairs(scanLog) do
        local passed = entry.skip == "OK_candidate"
        if passed then okCount = okCount + 1 else skipCount = skipCount + 1 end
        print(("[%s] %s | dist=%.1f | hp=%.0f | state=%s | Y=%.2f | Ydiff=%.2f | reason=%s"):format(
            passed and "OK  " or "SKIP",
            entry.name,
            entry.dist,
            entry.health,
            entry.state,
            entry.yAbs,
            entry.yDiff,
            entry.skip
        ))
    end
    print(("Total: %d players | %d OK | %d skipped"):format(#scanLog, okCount, skipCount))
    print("==========================")

    Rayfield:Notify({
        Title   = ("Scan: %d players"):format(#scanLog),
        Content = ("OK=%d  Skipped=%d\nSelf Y=%.1f\nSee F9 console for full log"):format(
            okCount, skipCount, r.Position.Y),
        Duration = 8
    })
end })

-- Quick self-info: print current Y and nearest target info
TabDebug:CreateButton({ Name = "Quick: Self Y + Nearest Target", Callback = function()
    local c = getChar(); local r = getHRP(c)
    if not r then return end

    local myY = r.Position.Y
    local target, dist, scanLog = nearestPlayer(PUNCH_Y_DIFF, true)

    local lines = {}
    table.insert(lines, ("Self Y = %.2f"):format(myY))

    if target then
        local oh = getHRP(target.Character)
        table.insert(lines, ("Target: %s"):format(target.Name))
        table.insert(lines, ("Dist=%.1f Y=%.2f"):format(dist, oh and oh.Position.Y or -1))
    else
        table.insert(lines, "No valid target found")
    end

    -- Show skipped count and top skip reason
    local skipReasons = {}
    for _, e in ipairs(scanLog) do
        if e.skip ~= "OK_candidate" then
            skipReasons[#skipReasons+1] = e.name .. "→" .. e.skip
        end
    end
    if #skipReasons > 0 then
        table.insert(lines, "Skipped: " .. table.concat(skipReasons, " | "))
    end

    local msg = table.concat(lines, "\n")
    print("[POE Quick Scan] " .. msg)
    Rayfield:Notify({ Title="Quick Scan", Content=msg, Duration=10 })
end })

-- Continuous scan: prints to console every 2s while enabled
local continuousActive = false
TabDebug:CreateToggle({ Name = "Continuous Scan (console, 2s)", CurrentValue = false,
    Flag = "ContinuousScan",
    Callback = function(v)
        continuousActive = v
        if v then
            task.spawn(function()
                while continuousActive do
                    local c2 = getChar(); local r2 = getHRP(c2)
                    if r2 then
                        local target, dist, scanLog = nearestPlayer(PUNCH_Y_DIFF, true)
                        local okList, skipList = {}, {}
                        for _, e in ipairs(scanLog) do
                            if e.skip == "OK_candidate" then
                                table.insert(okList, ("%s(%.1f)"):format(e.name, e.dist))
                            else
                                table.insert(skipList, ("%s[%s]"):format(e.name, e.skip))
                            end
                        end
                        print(("[SCAN] SelfY=%.1f | OK: %s | Skip: %s"):format(
                            r2.Position.Y,
                            #okList > 0 and table.concat(okList,",") or "none",
                            #skipList > 0 and table.concat(skipList,",") or "none"
                        ))
                    end
                    task.wait(2)
                end
            end)
        end
    end
})

TabDebug:CreateSection("Thresholds (live-tune)")
TabDebug:CreateSlider({ Name = "Punch Y Diff", Range = {3,25}, Increment = 1, CurrentValue = 8,
    Flag = "PunchYDiff",
    Callback = function(v) PUNCH_Y_DIFF = v end })
TabDebug:CreateSlider({ Name = "Max Target Dist", Range = {20,300}, Increment = 5, CurrentValue = 200,
    Flag = "MaxTargetDist",
    Callback = function(v) MAX_TARGET_DIST = v end })
TabDebug:CreateSlider({ Name = "Punch Dist Max", Range = {10,100}, Increment = 5, CurrentValue = 60,
    Flag = "PunchDistMax",
    Callback = function(v) PUNCH_DIST_MAX = v end })
