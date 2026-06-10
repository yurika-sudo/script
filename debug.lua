-- POE Bug Bounty PoC Tool
-- Run on second account in quiet server
-- Verifies ACTUAL impact, not just "accepted"

local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

-- ── Output UI ─────────────────────────────────────────────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name = "POEDebug"; gui.ResetOnSpawn = false
gui.Parent = LocalPlayer.PlayerGui

local frame = Instance.new("ScrollingFrame")
frame.Size = UDim2.new(0.95, 0, 0.5, 0)
frame.Position = UDim2.new(0.025, 0, 0.48, 0)
frame.BackgroundColor3 = Color3.fromRGB(10, 10, 10)
frame.BackgroundTransparency = 0.2
frame.BorderSizePixel = 0
frame.CanvasSize = UDim2.new(0, 0, 0, 0)
frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
frame.ScrollBarThickness = 4
frame.Parent = gui

Instance.new("UIListLayout", frame).SortOrder = Enum.SortOrder.LayoutOrder

local lineN = 0
local function log(text, col)
    lineN = lineN + 1
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1,-8,0,18); l.BackgroundTransparency = 1
    l.TextColor3 = col or Color3.fromRGB(100,255,100)
    l.TextSize = 11; l.Font = Enum.Font.Code
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = "  "..text; l.LayoutOrder = lineN; l.Parent = frame
    frame.CanvasPosition = Vector3.new(0, frame.AbsoluteCanvasSize.Y, 0)
    print("[POE]", text)
end
local W = Color3.fromRGB(255,255,255)
local Y = Color3.fromRGB(255,230,50)
local G = Color3.fromRGB(80,255,120)
local R = Color3.fromRGB(255,80,80)
local B = Color3.fromRGB(120,180,255)
local function logH(t) log("────── "..t.." ──────", Y) end
local function logOk(t) log("✓ "..t, G) end
local function logFail(t) log("✗ "..t, R) end
local function logInfo(t) log("  "..t, B) end

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0.95,0,0,22)
closeBtn.Position = UDim2.new(0.025,0,0.97,0)
closeBtn.BackgroundColor3 = Color3.fromRGB(120,30,30)
closeBtn.TextColor3 = Color3.new(1,1,1)
closeBtn.Text = "Close"; closeBtn.TextSize = 12
closeBtn.Font = Enum.Font.GothamBold; closeBtn.Parent = gui
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function getEvents()
    local r = RS:FindFirstChild("Remotes")
    return r and r:FindFirstChild("Events")
end

local function getCoins()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if ls then
        for _, v in ipairs(ls:GetChildren()) do
            local n = tonumber(v.Value)
            if n then return n, v.Name end
        end
    end
    -- fallback: scan GUI
    for _, v in ipairs(LocalPlayer.PlayerGui:GetDescendants()) do
        if v:IsA("TextLabel") then
            local n = tonumber(v.Text)
            if n and n > 50 then return n, v:GetFullName() end
        end
    end
    return nil, nil
end

local function getAbilityState()
    -- Check character for ability buff markers
    local c = LocalPlayer.Character; if not c then return {} end
    local state = {}
    for _, v in ipairs(c:GetDescendants()) do
        if v:IsA("StringValue") or v:IsA("BoolValue") or v:IsA("NumberValue") then
            if v.Name:lower():find("ability") or v.Name:lower():find("buff")
            or v.Name:lower():find("speed") or v.Name:lower():find("active") then
                state[v.Name] = tostring(v.Value)
            end
        end
    end
    -- Also check WalkSpeed (Faster ability would increase this)
    local h = c:FindFirstChildOfClass("Humanoid")
    if h then state["WalkSpeed"] = tostring(h.WalkSpeed) end
    return state
end

local function diffState(before, after)
    local changes = {}
    for k, v in pairs(after) do
        if before[k] ~= v then
            table.insert(changes, k..": "..tostring(before[k]).." → "..v)
        end
    end
    return changes
end

-- ── PoC 1: Currency manipulation ─────────────────────────────────────────────
task.spawn(function()
    task.wait(1)
    logH("PoC 1: Currency Manipulation")

    local coinsBefore, coinSrc = getCoins()
    logInfo("Coins before: "..(coinsBefore and tostring(coinsBefore) or "?").." (src: "..(coinSrc or "?")..")")

    local events = getEvents()
    if not events then logFail("Events folder not found"); return end

    -- Candidates sorted by likelihood
    local targets = {
        {events:FindFirstChild("ActionEvent"),   "ActionEvent",   {"AddCoins",100}},
        {events:FindFirstChild("ActionEvent"),   "ActionEvent",   {"GiveCoins",100}},
        {events:FindFirstChild("ActionEvent"),   "ActionEvent",   {"addcoins",100}},
        {events:FindFirstChild("ShopEvent"),     "ShopEvent",     {"Give","Coins",100}},
        {events:FindFirstChild("ShopEvent"),     "ShopEvent",     {"free","coin"}},
        {events:FindFirstChild("ClaimRewardEvent"), "ClaimRewardEvent", {}},
        {events:FindFirstChild("DailyRewardEvent"), "DailyRewardEvent",{}},
        {events:FindFirstChild("FreeRewardEvent"),  "FreeRewardEvent", {}},
    }

    for _, t in ipairs(targets) do
        local remote, name, args = t[1], t[2], t[3]
        if not remote then continue end
        local ok = pcall(function() remote:FireServer(table.unpack(args)) end)
        task.wait(0.5)
        local coinsAfter = getCoins()
        local delta = coinsAfter and coinsBefore and (coinsAfter - coinsBefore) or 0
        if delta > 0 then
            logOk(name.."("..table.concat(args,",")..") → COINS CHANGED by +"..delta.." !! VULN CONFIRMED")
            coinsBefore = coinsAfter
        else
            log(name.."("..table.concat(args,",")..") → no effect", Color3.fromRGB(150,150,150))
        end
        task.wait(0.3)
    end

    local coinsAfterAll = getCoins()
    local totalDelta = coinsAfterAll and coinsBefore and (coinsAfterAll - coinsBefore) or 0
    if totalDelta > 0 then
        logOk("Total coins gained: +"..totalDelta)
    else
        logFail("No currency manipulation found")
    end
end)

-- ── PoC 2: Ability bypass with actual state verification ──────────────────────
task.spawn(function()
    task.wait(6)
    logH("PoC 2: Ability Bypass Verification")

    local stateBefore = getAbilityState()
    logInfo("WalkSpeed before: "..(stateBefore["WalkSpeed"] or "?"))

    local events = getEvents()
    local abilityEvent = events and events:FindFirstChild("AbilityUseEvent")
    if not abilityEvent then logFail("AbilityUseEvent not found"); return end

    -- Get actual ability IDs from catalog
    local catalog = RS:FindFirstChild("Shared") and RS.Shared:FindFirstChild("AbilityCatalog")
    local abilityIds = {"Runner","Radar","Trap","Silent","Faster","Invisible","Shield"}
    if catalog then
        local ok, data = pcall(require, catalog)
        if ok and type(data)=="table" then
            local src = type(data.Abilities)=="table" and data.Abilities or data
            abilityIds = {}
            for k,v in pairs(src) do
                if type(v)=="table" then table.insert(abilityIds, tostring(k)) end
            end
            logInfo("Catalog IDs: "..table.concat(abilityIds,", "))
        end
    end

    for _, id in ipairs(abilityIds) do
        local before = getAbilityState()
        pcall(function() abilityEvent:FireServer(id) end)
        task.wait(0.8)  -- wait for server response
        local after = getAbilityState()
        local changes = diffState(before, after)
        if #changes > 0 then
            logOk("AbilityUseEvent("..id..") → STATE CHANGED: "..table.concat(changes,", ").." !! VULN")
        else
            log("AbilityUseEvent("..id..") → no state change", Color3.fromRGB(150,150,150))
        end
        task.wait(0.2)
    end
end)

-- ── PoC 3: CratesEvent (free loot box) ───────────────────────────────────────
task.spawn(function()
    task.wait(14)
    logH("PoC 3: CratesEvent (free open)")

    local coinsBefore = getCoins()
    local stateBefore = getAbilityState()
    local events = getEvents()
    local crates = events and events:FindFirstChild("CratesEvent")
    if not crates then logFail("CratesEvent not found"); return end

    local attempts = {
        {"open"}, {"Open"}, {"free"}, {"open","RareCrate"},
        {"open","CommonCrate"}, {crateId="RareCrate",action="open"},
    }
    for _, args in ipairs(attempts) do
        pcall(function() crates:FireServer(table.unpack(args)) end)
        task.wait(0.8)
        local coinsAfter = getCoins()
        local stateAfter = getAbilityState()
        local coinDelta = coinsAfter and coinsBefore and (coinsAfter - coinsBefore) or 0
        local stateChanges = diffState(stateBefore, stateAfter)
        if coinDelta ~= 0 or #stateChanges > 0 then
            logOk("CratesEvent("..tostring(args[1])..") → EFFECT DETECTED! coins:"..coinDelta.." state:"..table.concat(stateChanges,","))
        end
    end
    logInfo("CratesEvent probe done")
end)

-- ── PoC 4: Training/Quest manipulation ───────────────────────────────────────
task.spawn(function()
    task.wait(20)
    logH("PoC 4: TrainingEvent / QuestEvent")
    local events = getEvents()

    for _, name in ipairs({"TrainingEvent","QuestEvent"}) do
        local remote = events and events:FindFirstChild(name)
        if not remote then log(name..": not found", Color3.fromRGB(150,150,150)); continue end

        local coinsBefore = getCoins()
        -- Try to claim/complete without doing the actual task
        local args = {{"claim"},{"complete"},{"finish"},{"Complete"},{"Claim"},{action="complete"}}
        for _, a in ipairs(args) do
            pcall(function() remote:FireServer(table.unpack(a)) end)
            task.wait(0.5)
        end
        local coinsAfter = getCoins()
        local delta = coinsAfter and coinsBefore and (coinsAfter - coinsBefore) or 0
        if delta > 0 then
            logOk(name.." → coins changed +"..delta.." !! POTENTIAL VULN")
        else
            log(name..": no measurable effect", Color3.fromRGB(150,150,150))
        end
    end
end)

log("POE Bug Bounty PoC loaded. Testing in sequence...", B)
log("Results show ACTUAL state changes, not just 'accepted'.", B)
