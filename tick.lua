local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local lp = Players.LocalPlayer

settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
Lighting.GlobalShadows = false
Lighting.FogEnd = 100000
Lighting.Brightness = 2
Lighting.Ambient = Color3.fromRGB(178, 178, 178)
Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)

for _, e in ipairs(Lighting:GetChildren()) do
	if e:IsA("BlurEffect") or e:IsA("ColorCorrectionEffect")
	or e:IsA("DepthOfFieldEffect") or e:IsA("SunRaysEffect")
	or e:IsA("BloomEffect") then
		e.Enabled = false
	end
end

for _, obj in ipairs(workspace:GetDescendants()) do
	if obj:IsA("ParticleEmitter") or obj:IsA("Smoke")
	or obj:IsA("Fire") or obj:IsA("Sparkles") or obj:IsA("Trail") then
		obj.Enabled = false
	end
	if obj:IsA("BasePart") then
		obj.CastShadow = false
	end
	if obj:IsA("Decal") or obj:IsA("Texture") then
		obj.Transparency = 1
	end
end

Lighting.ChildAdded:Connect(function(e)
	task.wait(0.5)
	if e:IsA("BlurEffect") or e:IsA("SunRaysEffect") or e:IsA("BloomEffect") then
		e.Enabled = false
	end
end)

workspace.DescendantAdded:Connect(function(obj)
	if obj:IsA("ParticleEmitter") or obj:IsA("Smoke")
	or obj:IsA("Fire") or obj:IsA("Sparkles") or obj:IsA("Trail") then
		obj.Enabled = false
	end
	if obj:IsA("BasePart") then
		obj.CastShadow = false
	end
end)

RunService.Heartbeat:Connect(function()
	local char = lp.Character
	if not char then return end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("BillboardGui") then
			local p = obj.Parent
			if p and p:IsA("BasePart") then
				obj.Enabled = (p.Position - hrp.Position).Magnitude < 80
			end
		end
	end
end)
