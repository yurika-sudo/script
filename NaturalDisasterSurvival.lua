-- DropKick Clean | Natural Disaster Survival
-- Pure cosmetic self-animation script
-- No auto-execution, no loops, full restore on disable

local Players       = game:GetService("Players")
local TweenService  = game:GetService("TweenService")
local RunService    = game:GetService("RunService")
local LocalPlayer   = Players.LocalPlayer

-- ─── Helpers ──────────────────────────────────────────────────────────────────
local function getChar()  return LocalPlayer.Character end
local function getHum(c)  return c and c:FindFirstChildOfClass("Humanoid") end
local function getHRP(c)  return c and c:FindFirstChild("HumanoidRootPart") end
local function getAnim(c) return c and c:FindFirstChildOfClass("Animator") end

-- Store original motor6d CFrames for full restore
local originalCFrames = {}
local function saveOriginalPose(c)
    originalCFrames = {}
    for _, m in ipairs(c:GetDescendants()) do
        if m:IsA("Motor6D") then
            originalCFrames[m] = m.C0
        end
    end
end

local function restoreOriginalPose(c)
    for _, m in ipairs(c:GetDescendants()) do
        if m:IsA("Motor6D") and originalCFrames[m] then
            m.C0 = originalCFrames[m]
        end
    end
end

-- Stop all playing animations cleanly
local function stopAllAnims(c)
    local anim = getAnim(c)
    if not anim then return end
    for _, track in ipairs(anim:GetPlayingAnimationTracks()) do
        track:Stop(0.1)
    end
end

-- ─── Motor6D pose setter (no AnimationTrack needed) ───────────────────────────
-- We drive Motor6D.C0 directly so no server AnimationID required
-- All poses are relative to the saved original C0

local function getMotors(c)
    local m = {}
    for _, v in ipairs(c:GetDescendants()) do
        if v:IsA("Motor6D") then m[v.Name] = v end
    end
    return m
end

local function tweenMotor(motor, targetC0, duration)
    if not motor then return end
    local ti = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(motor, ti, { C0 = targetC0 }):Play()
end

-- ─── Animation sequences ──────────────────────────────────────────────────────
-- Each sequence is a coroutine-style function that:
--   1. Saves original pose
--   2. Drives motors through poses
--   3. Restores original pose when done
-- No loops, fire-and-forget per click

local animPlaying = false

local function playAnim(fn, c)
    if animPlaying then return end
    local h = getHum(c)
    if not h then return end
    animPlaying = true
    saveOriginalPose(c)
    stopAllAnims(c)
    task.spawn(function()
        local ok, err = pcall(fn, c, getMotors(c))
        if not ok then warn("[DropKick] anim error:", err) end
        -- Restore after anim finishes
        task.wait(0.15)
        restoreOriginalPose(c)
        animPlaying = false
    end)
end

-- Shared: tween multiple motors simultaneously
local function pose(motors, targets, duration)
    for name, cf in pairs(targets) do
        tweenMotor(motors[name], cf, duration)
    end
    task.wait(duration)
end

-- ── ONE PUNCH ─────────────────────────────────────────────────────────────────
-- Stage 1: wind-up (pull right arm back)
-- Stage 2: extend punch forward fast
-- Stage 3: hold briefly
-- Stage 4: recover
local function anim_OnePunch(c, m)
    local orig = {}
    for k, v in pairs(originalCFrames) do orig[v.Name] = k.C0 end

    -- Wind-up: right arm back, body lean forward
    pose(m, {
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(0, math.rad(90), math.rad(-140)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(math.rad(20), 0, math.rad(20)),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(math.rad(-10), 0, 0),
    }, 0.18)

    -- Punch extend: fast
    pose(m, {
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(math.rad(-10), 0, math.rad(-90)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(math.rad(-10), 0, math.rad(-20)),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(math.rad(10), 0, 0),
    }, 0.08)

    task.wait(0.12)

    -- Recover
    pose(m, {
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(0, math.rad(90), math.rad(-5)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(0, 0, 0),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(0, 0, 0),
    }, 0.2)

    task.wait(0.2)
end

-- ── ONE SLAP ──────────────────────────────────────────────────────────────────
-- Stage 1: raise hand high
-- Stage 2: swing down fast (open palm)
-- Stage 3: recover
local function anim_OneSlap(c, m)
    -- Raise left arm high, lean slightly
    pose(m, {
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(math.rad(-160), 0, math.rad(-30)),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(math.rad(-8), math.rad(-15), 0),
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(0, math.rad(90), math.rad(5)),
    }, 0.22)

    -- Slap down: fast swing
    pose(m, {
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(math.rad(20), 0, math.rad(30)),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(math.rad(12), math.rad(15), 0),
    }, 0.07)

    task.wait(0.1)

    -- Recover
    pose(m, {
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(0, 0, 0),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(0, 0, 0),
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(0, math.rad(90), 0),
    }, 0.2)

    task.wait(0.2)
end

-- ── SPIN KICK ─────────────────────────────────────────────────────────────────
-- Stage 1: crouch/load
-- Stage 2: body spins, leg extends outward
-- Stage 3: full spin (rotate HRP briefly)
-- Stage 4: land recover
local function anim_SpinKick(c, m)
    local hrp = getHRP(c)

    -- Load crouch
    pose(m, {
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(math.rad(-30), math.rad(-90), 0),
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(math.rad(-30), math.rad(90), 0),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(0, 0, math.rad(-60)),
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(0, 0, math.rad(60)),
    }, 0.18)

    -- Spin: extend right leg outward
    pose(m, {
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(0, math.rad(90), math.rad(-90)),
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(math.rad(10), math.rad(-90), 0),
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(math.rad(-90), 0, 0),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(math.rad(-90), 0, 0),
    }, 0.12)

    -- Rotate HRP for spin visual
    if hrp then
        local startCF = hrp.CFrame
        for i = 1, 6 do
            hrp.CFrame = startCF * CFrame.Angles(0, math.rad(i * 60), 0)
            task.wait(0.03)
        end
    end

    -- Recover
    pose(m, {
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(0, math.rad(90), 0),
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(0, math.rad(-90), 0),
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(0, math.rad(90), math.rad(-5)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(0, math.rad(-90), math.rad(5)),
    }, 0.22)

    task.wait(0.22)
end

-- ── DROP KICK ─────────────────────────────────────────────────────────────────
-- Stage 1: jump (set velocity up)
-- Stage 2: both legs forward horizontal (mid-air)
-- Stage 3: ragdoll spin (badan horizontal)
-- Stage 4: land recover
local function anim_DropKick(c, m)
    local hrp = getHRP(c)
    local h   = getHum(c)

    -- Jump impulse
    if hrp then
        hrp.AssemblyLinearVelocity = Vector3.new(
            hrp.AssemblyLinearVelocity.X,
            50,
            hrp.AssemblyLinearVelocity.Z
        )
    end

    task.wait(0.15)

    -- Both legs forward, arms back (flying pose)
    pose(m, {
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(math.rad(-80), math.rad(90), 0),
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(math.rad(-80), math.rad(-90), 0),
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(math.rad(140), 0, math.rad(20)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(math.rad(140), 0, math.rad(-20)),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(math.rad(-15), 0, 0),
    }, 0.15)

    -- Horizontal spin (ragdoll visual)
    if hrp then
        local startCF = hrp.CFrame
        for i = 1, 4 do
            hrp.CFrame = startCF * CFrame.Angles(math.rad(i * 30), 0, 0)
            task.wait(0.05)
        end
    end

    task.wait(0.2)

    -- Land recover: crouch on landing
    pose(m, {
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(math.rad(-40), math.rad(90), 0),
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(math.rad(-40), math.rad(-90), 0),
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(0, 0, math.rad(40)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(0, 0, math.rad(-40)),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(math.rad(10), 0, 0),
    }, 0.18)

    task.wait(0.18)
end

-- ── TSB PUNCH ─────────────────────────────────────────────────────────────────
-- The Blue (TSB) inspired: aggressive charge then double-arm forward thrust
local function anim_TSBPunch(c, m)
    -- Charge: both arms pull back, body leans back
    pose(m, {
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(math.rad(160), 0, math.rad(20)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(math.rad(160), 0, math.rad(-20)),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(math.rad(-20), 0, 0),
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(math.rad(20), math.rad(90), 0),
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(math.rad(20), math.rad(-90), 0),
    }, 0.2)

    -- Thrust forward: both arms shoot out
    pose(m, {
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(math.rad(-20), 0, math.rad(-80)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(math.rad(-20), 0, math.rad(80)),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(math.rad(15), 0, 0),
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(math.rad(-15), math.rad(90), 0),
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(math.rad(-15), math.rad(-90), 0),
    }, 0.07)

    task.wait(0.15)

    -- Recover
    pose(m, {
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(0, math.rad(90), math.rad(-5)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(0, math.rad(-90), math.rad(5)),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(0, 0, 0),
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(0, math.rad(90), 0),
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(0, math.rad(-90), 0),
    }, 0.22)

    task.wait(0.22)
end

-- ── UPPER CUT ─────────────────────────────────────────────────────────────────
-- Stage 1: crouch low
-- Stage 2: explode upward, arm drives up
-- Stage 3: float at top briefly
-- Stage 4: recover
local function anim_UpperCut(c, m)
    local hrp = getHRP(c)

    -- Crouch/load
    pose(m, {
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(math.rad(-50), math.rad(90), 0),
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(math.rad(-50), math.rad(-90), 0),
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(math.rad(60), 0, math.rad(10)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(math.rad(30), 0, math.rad(-10)),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(math.rad(15), 0, 0),
    }, 0.15)

    -- Launch upward
    if hrp then
        hrp.AssemblyLinearVelocity = Vector3.new(
            hrp.AssemblyLinearVelocity.X,
            65,
            hrp.AssemblyLinearVelocity.Z
        )
    end

    -- Rising arm drive
    pose(m, {
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(math.rad(-150), 0, math.rad(-10)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(math.rad(60), 0, math.rad(-30)),
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(math.rad(20), math.rad(90), 0),
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(math.rad(-20), math.rad(-90), 0),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(math.rad(-20), 0, 0),
    }, 0.1)

    task.wait(0.35)

    -- Recover
    pose(m, {
        ["Right Shoulder"] = CFrame.new(1.5, 0.5, 0)
            * CFrame.Angles(0, math.rad(90), math.rad(-5)),
        ["Left Shoulder"]  = CFrame.new(-1.5, 0.5, 0)
            * CFrame.Angles(0, math.rad(-90), math.rad(5)),
        ["Right Hip"]      = CFrame.new(0.5, -1, 0)
            * CFrame.Angles(0, math.rad(90), 0),
        ["Left Hip"]       = CFrame.new(-0.5, -1, 0)
            * CFrame.Angles(0, math.rad(-90), 0),
        ["Neck"]           = CFrame.new(0, 1, 0)
            * CFrame.Angles(0, 0, 0),
    }, 0.25)

    task.wait(0.25)
end

-- ─── UI ───────────────────────────────────────────────────────────────────────
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "DropKickUI"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = LocalPlayer.PlayerGui

-- Main container (draggable)
local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.new(0, 320, 0, 240)
main.Position = UDim2.new(0.5, -160, 0.5, -120)
main.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
main.BorderSizePixel = 0
main.Active = true
main.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = main

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(60, 60, 80)
stroke.Thickness = 1.5
stroke.Parent = main

-- Title bar
local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1, 0, 0, 36)
titleBar.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
titleBar.BorderSizePixel = 0
titleBar.Parent = main

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 10)
titleCorner.Parent = titleBar

-- Bottom cover to square off title bar bottom corners
local titleFix = Instance.new("Frame")
titleFix.Size = UDim2.new(1, 0, 0, 10)
titleFix.Position = UDim2.new(0, 0, 1, -10)
titleFix.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
titleFix.BorderSizePixel = 0
titleFix.Parent = titleBar

local titleLabel = Instance.new("TextLabel")
titleLabel.Size = UDim2.new(1, -40, 1, 0)
titleLabel.Position = UDim2.new(0, 12, 0, 0)
titleLabel.BackgroundTransparency = 1
titleLabel.Text = "✦ Drop Kick"
titleLabel.TextColor3 = Color3.fromRGB(220, 220, 255)
titleLabel.TextSize = 15
titleLabel.Font = Enum.Font.GothamBold
titleLabel.TextXAlignment = Enum.TextXAlignment.Left
titleLabel.Parent = titleBar

-- Close/minimize button
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 28, 0, 28)
closeBtn.Position = UDim2.new(1, -32, 0, 4)
closeBtn.BackgroundColor3 = Color3.fromRGB(180, 60, 60)
closeBtn.Text = "✕"
closeBtn.TextColor3 = Color3.fromRGB(255,255,255)
closeBtn.TextSize = 13
closeBtn.Font = Enum.Font.GothamBold
closeBtn.BorderSizePixel = 0
closeBtn.Parent = titleBar
Instance.new("UICorner", closeBtn).CornerRadius = UDim.new(0, 6)

-- Dragging logic
local dragging, dragStart, startPos = false, nil, nil
titleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch
    or input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging  = true
        dragStart = input.Position
        startPos  = main.Position
    end
end)
titleBar.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.Touch
    or input.UserInputType == Enum.UserInputType.MouseMovement) then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)
titleBar.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch
    or input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    end
end)

-- Button factory
local function makeButton(parent, text, x, y, w, h, accent)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, w, 0, h)
    btn.Position = UDim2.new(0, x, 0, y)
    btn.BackgroundColor3 = accent or Color3.fromRGB(38, 38, 52)
    btn.Text = text
    btn.TextColor3 = Color3.fromRGB(210, 210, 240)
    btn.TextSize = 13
    btn.Font = Enum.Font.GothamSemibold
    btn.BorderSizePixel = 0
    btn.AutoButtonColor = false
    btn.Parent = parent
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 7)

    -- Hover effect
    btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.12), {
            BackgroundColor3 = Color3.fromRGB(60, 60, 90)
        }):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.12), {
            BackgroundColor3 = accent or Color3.fromRGB(38, 38, 52)
        }):Play()
    end)
    -- Touch feedback
    btn.TouchTap:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.06), {
            BackgroundColor3 = Color3.fromRGB(80, 80, 120)
        }):Play()
        task.delay(0.12, function()
            TweenService:Create(btn, TweenInfo.new(0.12), {
                BackgroundColor3 = accent or Color3.fromRGB(38, 38, 52)
            }):Play()
        end)
    end)
    return btn
end

-- Status label
local statusLabel = Instance.new("TextLabel")
statusLabel.Size = UDim2.new(1, -16, 0, 18)
statusLabel.Position = UDim2.new(0, 8, 0, 216)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "Ready"
statusLabel.TextColor3 = Color3.fromRGB(120, 200, 120)
statusLabel.TextSize = 11
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextXAlignment = Enum.TextXAlignment.Center
statusLabel.Parent = main

local function setStatus(text, color)
    statusLabel.Text = text
    statusLabel.TextColor3 = color or Color3.fromRGB(120, 200, 120)
end

-- Layout: left col (x=8), right col (x=168), row height=46, start y=44
local BW, BH = 144, 40
local LX, RX = 8, 168
local rows = {44, 94, 144}

local btnOnePunch  = makeButton(main, "One Punch",  LX, rows[1], BW, BH)
local btnOneSlap   = makeButton(main, "One Slap",   LX, rows[2], BW, BH)
local btnSpinKick  = makeButton(main, "Spin Kick",  LX, rows[3], BW, BH)
local btnDropKick  = makeButton(main, "Drop Kick",  RX, rows[1], BW, BH)
local btnTSBPunch  = makeButton(main, "TSB Punch",  RX, rows[2], BW, BH)
local btnUpperCut  = makeButton(main, "Upper Cut",  RX, rows[3], BW, BH)

-- Wire up buttons
local function wire(btn, name, fn)
    local function fire()
        local c = getChar()
        if not c then setStatus("No character", Color3.fromRGB(255,100,100)); return end
        if animPlaying then setStatus("Animation playing...", Color3.fromRGB(255,180,60)); return end
        setStatus(name.."...", Color3.fromRGB(100,180,255))
        playAnim(fn, c)
        task.spawn(function()
            while animPlaying do task.wait(0.05) end
            setStatus("Ready")
        end)
    end
    btn.MouseButton1Click:Connect(fire)
    btn.TouchTap:Connect(fire)
end

wire(btnOnePunch, "One Punch", anim_OnePunch)
wire(btnOneSlap,  "One Slap",  anim_OneSlap)
wire(btnSpinKick, "Spin Kick", anim_SpinKick)
wire(btnDropKick, "Drop Kick", anim_DropKick)
wire(btnTSBPunch, "TSB Punch", anim_TSBPunch)
wire(btnUpperCut, "Upper Cut", anim_UpperCut)

-- Close: destroy UI, restore pose
closeBtn.MouseButton1Click:Connect(function()
    local c = getChar()
    if c then
        stopAllAnims(c)
        restoreOriginalPose(c)
    end
    animPlaying = false
    screenGui:Destroy()
end)
closeBtn.TouchTap:Connect(function()
    local c = getChar()
    if c then stopAllAnims(c); restoreOriginalPose(c) end
    animPlaying = false
    screenGui:Destroy()
end)

-- CharacterAdded: reset state so it doesn't carry over
LocalPlayer.CharacterAdded:Connect(function()
    animPlaying = false
    originalCFrames = {}
    setStatus("Ready")
end)

setStatus("Ready ✓")
