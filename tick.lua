local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local lp = Players.LocalPlayer

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local state = {
	graphics = false,
	particles = false,
	decals = false,
	shadows = false,
	billboards = false,
	billboardRange = 80,
}

local heartbeatConn = nil

local function applyGraphics(enabled)
	if enabled then
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
	else
		settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic
		Lighting.GlobalShadows = true
		for _, e in ipairs(Lighting:GetChildren()) do
			if e:IsA("BlurEffect") or e:IsA("ColorCorrectionEffect")
			or e:IsA("DepthOfFieldEffect") or e:IsA("SunRaysEffect")
			or e:IsA("BloomEffect") then
				e.Enabled = true
			end
		end
	end
end

local function applyParticles(enabled)
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("ParticleEmitter") or obj:IsA("Smoke")
		or obj:IsA("Fire") or obj:IsA("Sparkles") or obj:IsA("Trail") then
			obj.Enabled = not enabled
		end
	end
end

local function applyDecals(enabled)
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("Decal") or obj:IsA("Texture") then
			obj.Transparency = enabled and 1 or 0
		end
	end
end

local function applyShadows(enabled)
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("BasePart") then
			obj.CastShadow = not enabled
		end
	end
end

local function applyBillboards(enabled)
	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end
	if not enabled then
		for _, obj in ipairs(workspace:GetDescendants()) do
			if obj:IsA("BillboardGui") then
				obj.Enabled = true
			end
		end
		return
	end
	heartbeatConn = RunService.Heartbeat:Connect(function()
		local char = lp.Character
		if not char then return end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		for _, obj in ipairs(workspace:GetDescendants()) do
			if obj:IsA("BillboardGui") then
				local p = obj.Parent
				if p and p:IsA("BasePart") then
					obj.Enabled = (p.Position - hrp.Position).Magnitude < state.billboardRange
				end
			end
		end
	end)
end

workspace.DescendantAdded:Connect(function(obj)
	if state.particles then
		if obj:IsA("ParticleEmitter") or obj:IsA("Smoke")
		or obj:IsA("Fire") or obj:IsA("Sparkles") or obj:IsA("Trail") then
			obj.Enabled = false
		end
	end
	if state.shadows then
		if obj:IsA("BasePart") then
			obj.CastShadow = false
		end
	end
end)

Lighting.ChildAdded:Connect(function(e)
	if state.graphics then
		task.wait(0.5)
		if e:IsA("BlurEffect") or e:IsA("SunRaysEffect") or e:IsA("BloomEffect") then
			e.Enabled = false
		end
	end
end)

local Window = Rayfield:CreateWindow({
	Name = "Tick Optimizer",
	LoadingTitle = "Tick Optimizer",
	LoadingSubtitle = "low-end mode",
	ConfigurationSaving = { Enabled = false },
	Discord = { Enabled = false },
	KeySystem = false,
})

local MainTab = Window:CreateTab("Main", "zap")
local DebugTab = Window:CreateTab("Debug", "bug")

MainTab:CreateToggle({
	Name = "Graphics Nuke",
	CurrentValue = false,
	Flag = "graphics",
	Callback = function(val)
		state.graphics = val
		applyGraphics(val)
	end,
})

MainTab:CreateToggle({
	Name = "Remove Particles & Trails",
	CurrentValue = false,
	Flag = "particles",
	Callback = function(val)
		state.particles = val
		applyParticles(val)
	end,
})

MainTab:CreateToggle({
	Name = "Hide Decals & Textures",
	CurrentValue = false,
	Flag = "decals",
	Callback = function(val)
		state.decals = val
		applyDecals(val)
	end,
})

MainTab:CreateToggle({
	Name = "Disable Shadows",
	CurrentValue = false,
	Flag = "shadows",
	Callback = function(val)
		state.shadows = val
		applyShadows(val)
	end,
})

MainTab:CreateToggle({
	Name = "Billboard Distance Cull",
	CurrentValue = false,
	Flag = "billboards",
	Callback = function(val)
		state.billboards = val
		applyBillboards(val)
	end,
})

MainTab:CreateSlider({
	Name = "Billboard Cull Range",
	Range = {20, 200},
	Increment = 10,
	Suffix = " studs",
	CurrentValue = 80,
	Flag = "billboardRange",
	Callback = function(val)
		state.billboardRange = val
	end,
})

local debugLabel = DebugTab:CreateParagraph({
	Title = "Scan Results",
	Content = "Press Scan to start.",
})

DebugTab:CreateButton({
	Name = "Scan Workspace",
	Callback = function()
		local counts = {
			ParticleEmitter = 0,
			Smoke = 0,
			Fire = 0,
			Sparkles = 0,
			Trail = 0,
			Decal = 0,
			Texture = 0,
			BillboardGui = 0,
			BasePart = 0,
			BlurEffect = 0,
			SunRaysEffect = 0,
			BloomEffect = 0,
		}
		for _, obj in ipairs(workspace:GetDescendants()) do
			local cn = obj.ClassName
			if counts[cn] ~= nil then
				counts[cn] = counts[cn] + 1
			end
		end
		for _, e in ipairs(Lighting:GetChildren()) do
			local cn = e.ClassName
			if counts[cn] ~= nil then
				counts[cn] = counts[cn] + 1
			end
		end
		local result = ""
		for k, v in pairs(counts) do
			result = result .. k .. ": " .. v .. "\n"
		end
		debugLabel:Set({
			Title = "Scan Results",
			Content = result,
		})
	end,
})

DebugTab:CreateButton({
	Name = "FPS Check",
	Callback = function()
		local samples = {}
		local conn
		conn = RunService.Heartbeat:Connect(function(dt)
			table.insert(samples, 1 / dt)
			if #samples >= 60 then
				conn:Disconnect()
				local sum = 0
				for _, v in ipairs(samples) do sum = sum + v end
				local avg = math.floor(sum / #samples)
				debugLabel:Set({
					Title = "FPS Result",
					Content = "Average FPS (60 frames): " .. avg .. " fps",
				})
			end
		end)
		debugLabel:Set({
			Title = "FPS Result",
			Content = "Sampling... (wait ~1s)",
		})
	end,
})
