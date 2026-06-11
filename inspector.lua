-- POE Game Inspector
-- Dumps game structure + hooks all remotes to log real traffic
-- Play normally for 1-2 rounds, then read the log

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

-- ── UI ────────────────────────────────────────────────────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name = "Inspector"; gui.ResetOnSpawn = false
gui.Parent = LocalPlayer.PlayerGui

local frame = Instance.new("ScrollingFrame")
frame.Size = UDim2.new(0.98, 0, 0.55, 0)
frame.Position = UDim2.new(0.01, 0, 0.43, 0)
frame.BackgroundColor3 = Color3.fromRGB(8, 8, 8)
frame.BackgroundTransparency = 0.1
frame.BorderSizePixel = 0
frame.CanvasSize = UDim2.new(0, 0, 0, 0)
frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
frame.ScrollBarThickness = 5
frame.Parent = gui
Instance.new("UIListLayout", frame).SortOrder = Enum.SortOrder.LayoutOrder

local n = 0
local function log(txt, col)
    n = n + 1
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1,-4,0,16); l.BackgroundTransparency = 1
    l.TextColor3 = col or Color3.fromRGB(200,200,200)
    l.TextSize = 10; l.Font = Enum.Font.Code
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = "  "..txt; l.LayoutOrder = n; l.Parent = frame
    frame.CanvasPosition = Vector3.new(0, frame.AbsoluteCanvasSize.Y, 0)
    print("[INS]", txt)
end
local Y  = Color3.fromRGB(255,230,50)
local G  = Color3.fromRGB(80,255,120)
local B  = Color3.fromRGB(100,180,255)
local W  = Color3.fromRGB(220,220,220)
local R  = Color3.fromRGB(255,100,100)
local M  = Color3.fromRGB(200,100,255)

local function sec() return string.format("[%.1fs]", tick() % 1000) end

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0.98,0,0,20)
closeBtn.Position = UDim2.new(0.01,0,0.975,0)
closeBtn.BackgroundColor3 = Color3.fromRGB(100,20,20)
closeBtn.TextColor3 = Color3.new(1,1,1); closeBtn.Text = "Close"
closeBtn.TextSize = 11; closeBtn.Font = Enum.Font.GothamBold
closeBtn.Parent = gui
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

-- ── 1. Full RS structure dump ─────────────────────────────────────────────────
local function dumpTree(obj, depth, maxDepth)
    if depth > maxDepth then return end
    local pad = string.rep("  ", depth)
    local info = obj.ClassName
    -- show value for leaf nodes
    if obj:IsA("ValueBase") then info = info.."="..tostring((obj::any).Value) end
    log(pad..obj.Name.." ["..info.."]", depth==0 and Y or (depth==1 and B or W))
    for _, child in ipairs(obj:GetChildren()) do
        dumpTree(child, depth+1, maxDepth)
    end
end

log("════ DATA MODEL DUMP ════", Y)
log("── ReplicatedStorage ──", B)
dumpTree(RS, 0, 3)

log("── LocalPlayer ──", B)
dumpTree(LocalPlayer, 0, 2)

local ws = workspace
log("── Workspace (top-level) ──", B)
for _, v in ipairs(ws:GetChildren()) do
    log("  "..v.Name.." ["..v.ClassName.."]", W)
end

-- ── 2. Hook all remotes → log params ─────────────────────────────────────────
log("════ REMOTE TRAFFIC HOOK ════", Y)
log("Play normally. All FireServer calls will be logged here.", G)
log("Look for: bomb spawn, pass, die, win, fight start/end", G)

local function serialize(v)
    if type(v) == "table" then
        local parts = {}
        for k, val in pairs(v) do
            table.insert(parts, tostring(k).."="..serialize(val))
        end
        return "{"..table.concat(parts,",").."}"
    elseif typeof(v) == "Instance" then
        return "["..v.ClassName..":"..v.Name.."]"
    elseif typeof(v) == "Vector3" then
        return string.format("V3(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
    elseif typeof(v) == "CFrame" then
        return string.format("CF(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
    else
        return tostring(v)
    end
end

local hooked = {}
local function hookRemote(remote)
    if hooked[remote] then return end
    hooked[remote] = true
    -- Hook FireServer
    local mt = getrawmetatable and getrawmetatable(remote)
    if mt then
        local old = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            local method = tostring(...):match("^(%w+)") -- get method name
            if self == remote and method == "FireServer" then
                local args = {...}
                table.remove(args, 1) -- remove method name
                local parts = {}
                for _, a in ipairs(args) do table.insert(parts, serialize(a)) end
                log(sec().." → "..remote.Name.."("..table.concat(parts,", ")..")", M)
            end
            return old(self, ...)
        end)
        setreadonly(mt, true)
    end

    -- Also hook OnClientEvent to see what SERVER sends US
    remote.OnClientEvent:Connect(function(...)
        local parts = {}
        for _, a in ipairs({...}) do table.insert(parts, serialize(a)) end
        log(sec().." ← "..remote.Name.."("..table.concat(parts,", ")..")", G)
    end)
end

-- Hook all current + future remotes
local function hookAll(folder)
    if not folder then return end
    for _, v in ipairs(folder:GetDescendants()) do
        if v:IsA("RemoteEvent") then hookRemote(v) end
    end
    folder.DescendantAdded:Connect(function(v)
        if v:IsA("RemoteEvent") then hookRemote(v) end
    end)
end

local events = RS:FindFirstChild("Remotes") and RS.Remotes:FindFirstChild("Events")
hookAll(events)
hookAll(RS)

-- ── 3. Live game state tracker ────────────────────────────────────────────────
log("════ LIVE GAME STATE ════", Y)

local RunService = game:GetService("RunService")
local lastState = ""
local stateTimer = 0

RunService.Heartbeat:Connect(function(dt)
    stateTimer = stateTimer + dt
    if stateTimer < 2 then return end
    stateTimer = 0

    local c = LocalPlayer.Character
    if not c then return end
    local hrp = c:FindFirstChild("HumanoidRootPart")
    local hum = c:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return end

    -- Read bomb timer from any BillboardGui/SurfaceGui in workspace
    local timerVal = "?"
    for _, obj in ipairs(workspace:GetDescendants()) do
        if (obj:IsA("BillboardGui") or obj:IsA("SurfaceGui")) then
            for _, lbl in ipairs(obj:GetDescendants()) do
                if lbl:IsA("TextLabel") then
                    local n2 = tonumber(lbl.Text)
                    if n2 and n2 >= 0 and n2 <= 30 then
                        timerVal = tostring(n2)
                    end
                end
            end
        end
    end

    -- Read carrier (who has bomb) from any attribute/value
    local carrier = "none"
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then
            -- check for Tool in character (bomb)
            for _, v in ipairs(p.Character:GetChildren()) do
                if v:IsA("Tool") then
                    carrier = p.Name.."(tool:"..v.Name..")"
                end
            end
            -- check BombActive attribute
            local ok, ba = pcall(function() return p.Character:GetAttribute("BombActive") end)
            if ok and ba then carrier = p.Name.."(BombActive)" end
        end
    end

    -- Check our status
    local hasBomb = false
    for _, v in ipairs(c:GetChildren()) do
        if v:IsA("Tool") then hasBomb = true end
    end

    local state = string.format(
        "Y:%.0f hp:%.0f spd:%.0f bomb:%s carrier:%s timer:%s",
        hrp.Position.Y, hum.Health, hum.WalkSpeed,
        hasBomb and "YES" or "no", carrier, timerVal
    )

    if state ~= lastState then
        log(sec().." STATE: "..state, B)
        lastState = state
    end
end)

-- ── 4. Inspect AbilityCatalog fully ──────────────────────────────────────────
task.spawn(function()
    task.wait(1)
    log("════ ABILITY CATALOG ════", Y)
    local catalog = RS:FindFirstChild("Shared") and RS.Shared:FindFirstChild("AbilityCatalog")
    if not catalog then log("AbilityCatalog not found", R); return end
    local ok, data = pcall(require, catalog)
    if not ok then log("require failed: "..tostring(data), R); return end

    local function dumpVal(v, depth)
        if depth > 2 then return "..." end
        if type(v) == "table" then
            local p = {}
            for k2, v2 in pairs(v) do
                table.insert(p, tostring(k2).."="..dumpVal(v2, depth+1))
            end
            return "{"..table.concat(p,", ").."}"
        end
        return tostring(v)
    end

    local src = type(data)=="table" and (type(data.Abilities)=="table" and data.Abilities or data) or {}
    for id, props in pairs(src) do
        if type(props) == "table" then
            log("  ["..id.."] "..dumpVal(props, 0), W)
        else
            log("  "..tostring(id).." = "..tostring(props), W)
        end
    end
end)

log("Inspector ready. Play 1-2 full rounds to capture traffic.", G)
log("← = server→client  |  → = client→server", G)
