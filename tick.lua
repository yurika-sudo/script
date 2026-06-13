--Tested for executors: Delta
--Safe to run on any game

local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local lp = Players.LocalPlayer

local function SetGraphicsNuke()
    --Set quality level to lowest
    settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    
    --Lighting becomes flat/no shadow
    Lighting.GlobalShadows = false
    Lighting.FogEnd = 100000
    Lighting.Brightness = 2
    Lighting.Ambient = Color3.fromRGB(178, 178, 178)
    Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
    
    --Turn off all lighting effects
    for _, effect in ipairs(Lighting:GetChildren()) do
        if effect:IsA("BlurEffect") 
        or effect:IsA("ColorCorrectionEffect")
        or effect:IsA("DepthOfFieldEffect")
        or effect:IsA("SunRaysEffect")
        or effect:IsA("BloomEffect")
        then
            effect.Enabled = false
        end
    end
    
    print("[Optimizer] Graphics nuked ✓")
end

local function RemoveDecorations()
    --Remove all ParticleEmitters, Smoke, Fire, Sparkles
    local removed = 0
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("ParticleEmitter") 
        or obj:IsA("Smoke") 
        or obj:IsA("Fire")
        or obj:IsA("Sparkles")
        or obj:IsA("Trail")
        then
            obj.Enabled = false -- disable dulu, bukan destroy
            removed = removed + 1
        end
        
        --Turn off shadow per part
        if obj:IsA("BasePart") then
            obj.CastShadow = false
        end
        
        --Turn off heavy textures (optional, uncomment if you want to go extreme)
        -- if obj:IsA("Texture") or obj:IsA("Decal") then
        --     obj:Destroy()
        -- end
    end
    print("[Optimizer] Removed/disabled " .. removed .. " decorative effects ✓")
end

local function SetRenderDistance()
    --Workspace StreamingEnabled check
    if workspace.StreamingEnabled then
        workspace.StreamingMinRadius = 64
        workspace.StreamingTargetRadius = 128
        print("[Optimizer] Streaming radius reduced ✓")
    else
        print("[Optimizer] StreamingEnabled not active on this game")
    end
end

local function ThrottleNPCAnimations()
    --Reduce NPC animation update rate outside the range
    RunService.Heartbeat:Connect(function()
        for _, model in ipairs(workspace:GetDescendants()) do
            if model:IsA("Humanoid") and model.Parent ~= lp.Character then
                local hrp = model.Parent:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local dist = (hrp.Position - lp.Character.HumanoidRootPart.Position).Magnitude
                    local animator = model:FindFirstChildOfClass("Animator")
                    if animator then
                        --NPC far away = turn off animation
                        animator.Parent.Parent:FindFirstChildOfClass("AnimationController")
                        --Trick: set speed 0 if > 100 studs
                        if dist > 100 then
                            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                                track:AdjustSpeed(0)
                            end
                        else
                            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                                track:AdjustSpeed(1)
                            end
                        end
                    end
                end
            end
        end
    end)
    print("[Optimizer] NPC animation throttling active ✓")
end

SetGraphicsNuke()
RemoveDecorations()
SetRenderDistance()
-- ThrottleNPCAnimations() --uncomment this if the game is NPC-heavy, a bit heavy in Heartbeat

--Auto-reapply every time Lighting/effect is reset by the game
Lighting.ChildAdded:Connect(function(child)
    task.wait(0.5)
    if child:IsA("BlurEffect") or child:IsA("SunRaysEffect") or child:IsA("BloomEffect") then
        child.Enabled = false
    end
end)

print("[Optimizer] All optimizations applied!")
