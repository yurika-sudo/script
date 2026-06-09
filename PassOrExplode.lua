local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS         = game:GetService("ReplicatedStorage")
local VIM        = game:GetService("VirtualInputManager")
local LocalPlayer = Players.LocalPlayer

-- Rayfield: tabs, clean layout
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
local Window = Rayfield:CreateWindow({
    Name             = "POE Assist",
    LoadingTitle     = "POE Assist",
    LoadingSubtitle  = "",
    ConfigurationSaving = { Enabled = false },
    Discord          = { Enabled = false },
    KeySystem        = false,
})

local TabBomb     = Window:CreateTab("Bomb",     4483362458)
local TabPVP      = Window:CreateTab("PVP",      4483362458)
local TabAbility  = Window:CreateTab("Abilities",4483362458)

-- Config
local cfg = {
    AutoPassBomb = false,
    BombTeleport = false,
    Noclip       = false,
    SpeedEnabled = false,
    NoFall       = false,
    FreeFly      = false,
    AutoPunch    = false,
}

local SPEED_BOMB    = 22
local SPEED_IDLE    = 20
local SPEED_DEFAULT = 16
local MAX_TARGET_DIST = 200
local MAX_Y_DIFF      = 15
local PUNCH_Y_DIFF    = 8
local PUNCH_DIST_MAX  = 15
local LOBBY_Y_THRESH  = 10
local STOP_DIST       = 4
local PUNCH_RANGE     = 6
local PUNCH_RATE      = 0.45
local FLY_SPEED       = 40

local punchTimer    = 0
local teleportTimer = 0
local noclipTimer   = 0
local noFallBV      = nil
local punchNoFallBV = nil
local freeFlyBV     = nil
local ghostActive   = false

-- Remotes at correct path
local remoteAction   = nil
local remoteEndgame  = nil
local remoteAbility  = nil
task.spawn(function()
    local events = RS:WaitForChild("Remotes", 10)
        and RS.Remotes:WaitForChild("Events", 10)
    if not events then return end
    remoteAction  = events:WaitForChild("ActionEvent",       10)
    remoteEndgame = events:WaitForChild("EndgameAttackEvent", 10)
    remoteAbility = events:FindFirstChild("AbilityUseEvent")
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
                local ok    = (not yDiffLimit) or (yDiff <= yDiffLimit)
                if d < bestDist and d <= MAX_TARGET_DIST and ok then
                    bestDist = d; best = p
                end
            end
        end
    end
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

local function setupFreeFly(enable)
    if freeFlyBV then pcall(function() freeFlyBV:Destroy() end); freeFlyBV = nil end
    if not enable then return end
    local r = getHRP(getChar()); if not r then return end
    local bv = Instance.new("BodyVelocity")
    bv.Name = "FreeFlyBV"; bv.MaxForce = Vector3.new(1e6,1e6,1e6)
    bv.Velocity = Vector3.new(0,0,0); bv.Parent = r; freeFlyBV = bv
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

local function fireAbility(id)
    if remoteAbility then
        pcall(function() remoteAbility:FireServer(id) end)
    else
        -- Fallback: find it on the fly
        local events = RS:FindFirstChild("Remotes") and RS.Remotes:FindFirstChild("Events")
        if events then
            local e = events:FindFirstChild("AbilityUseEvent")
            if e then pcall(function() e:FireServer(id) end) end
        end
    end
end

-- Main loop
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

    -- Ghost re-apply every 0.3s
    if cfg.Noclip then
        noclipTimer = noclipTimer + dt
        if noclipTimer >= 0.3 then noclipTimer = 0; applyNoclip(c, true) end
    elseif ghostActive then
        applyNoclip(c, false); noclipTimer = 0
    end

    -- Bomb Teleport: face target, safety rollback if fell off
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

    -- Auto Pass Bomb
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

    -- No Fall
    if cfg.NoFall and noFallBV and r and not cfg.FreeFly and not chasing then
        local vel = r.AssemblyLinearVelocity
        if vel.Y < 0 then
            noFallBV.MaxForce = Vector3.new(0, 1e6, 0)
            noFallBV.Velocity = Vector3.new(0, 0, 0)
        else
            noFallBV.MaxForce = Vector3.new(0, 0, 0)
        end
    end

    -- Free Fly
    if cfg.FreeFly and freeFlyBV then
        if chasing then
            freeFlyBV.MaxForce = Vector3.new(0,0,0)
        else
            freeFlyBV.MaxForce = Vector3.new(1e6,1e6,1e6)
            local moveDir = h.MoveDirection
            local pitchY  = workspace.CurrentCamera.CFrame.LookVector.Y
            freeFlyBV.Velocity = moveDir.Magnitude > 0
                and Vector3.new(moveDir.X*FLY_SPEED, pitchY*FLY_SPEED, moveDir.Z*FLY_SPEED)
                or  Vector3.new(0,0,0)
        end
    end

    -- Auto Punch: chase target → stop at PUNCH_RANGE → punch + knockback
    if cfg.AutoPunch then
        local target, dist = nearestPlayer(PUNCH_Y_DIFF)
        if target and target.Character and dist <= PUNCH_DIST_MAX then
            local oh = getHRP(target.Character)
            if oh then
                if dist > PUNCH_RANGE then
                    -- Chase: walk toward target, stop when in punch range
                    h:MoveTo(oh.Position)
                else
                    -- In range: fire punch every PUNCH_RATE seconds
                    punchTimer = punchTimer + dt
                    if punchTimer >= PUNCH_RATE then
                        punchTimer = 0
                        firePunch(target.Character, oh)
                        -- Knockback: launch target away from us (replicated via physics)
                        pcall(function()
                            local dir = (oh.Position - r.Position)
                            local flat = Vector3.new(dir.X, 0, dir.Z)
                            if flat.Magnitude > 0 then
                                oh.AssemblyLinearVelocity = Vector3.new(
                                    flat.Unit.X * 90,
                                    35,
                                    flat.Unit.Z * 90
                                )
                            end
                        end)
                    end
                end
            end
        end
    else
        if punchNoFallBV then pcall(function() punchNoFallBV:Destroy() end); punchNoFallBV = nil end
    end
end)

LocalPlayer.CharacterAdded:Connect(function()
    noFallBV = nil; punchNoFallBV = nil; freeFlyBV = nil
    ghostActive = false; noclipTimer = 0; teleportTimer = 0; punchTimer = 0
    task.wait(1)
    if cfg.FreeFly then setupFreeFly(true) end
    if cfg.NoFall  then setupNoFall(true)  end
end)

-- UI: Bomb tab
TabBomb:CreateToggle({ Name = "Auto Pass Bomb", CurrentValue = false, Flag = "AutoPassBomb",
    Callback = function(v) cfg.AutoPassBomb = v end })
TabBomb:CreateToggle({ Name = "Bomb Teleport",  CurrentValue = false, Flag = "BombTeleport",
    Callback = function(v) cfg.BombTeleport = v end })
TabBomb:CreateToggle({ Name = "Ghost Mode",     CurrentValue = false, Flag = "Noclip",
    Callback = function(v)
        cfg.Noclip = v
        if not v and ghostActive then local c=getChar(); if c then applyNoclip(c,false) end end
    end })
TabBomb:CreateToggle({ Name = "Speed Boost",    CurrentValue = false, Flag = "SpeedBoost",
    Callback = function(v) cfg.SpeedEnabled = v end })
TabBomb:CreateSlider({ Name = "Bomb Speed", Range = {16, 40}, Increment = 1,
    CurrentValue = 22, Flag = "BombSpeed",
    Callback = function(v) SPEED_BOMB = v end })
TabBomb:CreateSlider({ Name = "Idle Speed", Range = {16, 30}, Increment = 1,
    CurrentValue = 20, Flag = "IdleSpeed",
    Callback = function(v) SPEED_IDLE = v end })

-- UI: PVP tab
TabPVP:CreateToggle({ Name = "No Fall",   CurrentValue = false, Flag = "NoFall",
    Callback = function(v) cfg.NoFall = v; setupNoFall(v) end })
TabPVP:CreateToggle({ Name = "Free Fly",  CurrentValue = false, Flag = "FreeFly",
    Callback = function(v)
        cfg.FreeFly = v; setupFreeFly(v)
        if not v and cfg.NoFall then setupNoFall(true) end
    end })
TabPVP:CreateToggle({ Name = "Auto Punch", CurrentValue = false, Flag = "AutoPunch",
    Callback = function(v) cfg.AutoPunch = v; punchTimer = 0 end })

-- UI: Abilities tab
TabAbility:CreateSection("Use Ability")
TabAbility:CreateButton({ Name = "Runner (default)", Callback = function() fireAbility("Runner") end })
TabAbility:CreateButton({ Name = "Radar",            Callback = function() fireAbility("Radar")  end })
TabAbility:CreateButton({ Name = "Trap",             Callback = function() fireAbility("Trap")   end })
TabAbility:CreateButton({ Name = "Silent",           Callback = function() fireAbility("Silent") end })
TabAbility:CreateSection("Debug")
TabAbility:CreateButton({ Name = "Scan All Ability IDs", Callback = function()
    local catalog = RS:FindFirstChild("Shared") and RS.Shared:FindFirstChild("AbilityCatalog")
    if not catalog then Rayfield:Notify({ Title="Scan", Content="AbilityCatalog not found", Duration=5 }); return end
    local ok, data = pcall(require, catalog)
    if not ok then Rayfield:Notify({ Title="Scan", Content=tostring(data), Duration=5 }); return end

    local ids = {}
    if type(data) == "table" then
        -- Catalog is { Abilities = { [id] = {...}, ... }, DefaultAbility = "Runner" }
        -- Drill into data.Abilities if it exists, otherwise use data directly
        local src = (type(data.Abilities) == "table") and data.Abilities or data
        for k, v in pairs(src) do
            if type(v) == "table" then
                table.insert(ids, tostring(k))
            end
        end
    end

    Rayfield:Notify({
        Title    = "Ability IDs (" .. #ids .. ")",
        Content  = table.concat(ids, ", "),
        Duration = 20
    })
end })
