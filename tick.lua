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
	partCull = false,
	partCullRange = 100,
	playerCull = false,
	playerCullRange = 60,
}

local heartbeatConn = nil
local partCullConn = nil
local playerCullConn = nil

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

local function applyPartCull(enabled)
	if partCullConn then
		partCullConn:Disconnect()
		partCullConn = nil
	end
	if not enabled then
		for _, obj in ipairs(workspace:GetDescendants()) do
			if obj:IsA("BasePart") and not obj:IsDescendantOf(lp.Character or game) then
				obj.LocalTransparencyModifier = 0
			end
		end
		return
	end
	partCullConn = RunService.Heartbeat:Connect(function()
		local char = lp.Character
		if not char then return end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		for _, obj in ipairs(workspace:GetDescendants()) do
			if obj:IsA("BasePart") and not obj:IsDescendantOf(char) then
				local dist = (obj.Position - hrp.Position).Magnitude
				obj.LocalTransparencyModifier = dist > state.partCullRange and 1 or 0
			end
		end
	end)
end

local function applyPlayerCull(enabled)
	if playerCullConn then
		playerCullConn:Disconnect()
		playerCullConn = nil
	end
	if not enabled then
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= lp and player.Character then
				for _, obj in ipairs(player.Character:GetDescendants()) do
					if obj:IsA("BasePart") then
						obj.LocalTransparencyModifier = 0
					end
				end
			end
		end
		return
	end
	playerCullConn = RunService.Heartbeat:Connect(function()
		local char = lp.Character
		if not char then return end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= lp and player.Character then
				local otherHRP = player.Character:FindFirstChild("HumanoidRootPart")
				if otherHRP then
					local dist = (otherHRP.Position - hrp.Position).Magnitude
					local hide = dist > state.playerCullRange
					for _, obj in ipairs(player.Character:GetDescendants()) do
						if obj:IsA("BasePart") then
							obj.LocalTransparencyModifier = hide and 1 or 0
						end
					end
				end
			end
		end
	end)
end

local function setPreset(mode)
	if mode == "Performance" then
		state.graphics = true
		state.particles = true
		state.decals = true
		state.shadows = true
		state.billboards = true
		state.billboardRange = 40
		state.partCull = true
		state.partCullRange = 60
		state.playerCull = true
		state.playerCullRange = 40
	elseif mode == "Balanced" then
		state.graphics = true
		state.particles = true
		state.decals = false
		state.shadows = true
		state.billboards = true
		state.billboardRange = 80
		state.partCull = false
		state.partCullRange = 100
		state.playerCull = true
		state.playerCullRange = 60
	elseif mode == "Quality" then
		state.graphics = true
		state.particles = false
		state.decals = false
		state.shadows = true
		state.billboards = false
		state.billboardRange = 80
		state.partCull = false
		state.partCullRange = 100
		state.playerCull = false
		state.playerCullRange = 60
	end
	applyGraphics(state.graphics)
	applyParticles(state.particles)
	applyDecals(state.decals)
	applyShadows(state.shadows)
	applyBillboards(state.billboards)
	applyPartCull(state.partCull)
	applyPlayerCull(state.playerCull)
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

local PresetTab = Window:CreateTab("Preset", "layers")
local MainTab = Window:CreateTab("Main", "zap")
local DebugTab = Window:CreateTab("Debug", "bug")

PresetTab:CreateSection("Recommended — Start here")

PresetTab:CreateParagraph({
	Title = "First time?",
	Content = "Pick a preset below. If you're not sure, go with Balanced first. You can switch anytime.",
})

PresetTab:CreateButton({
	Name = "Performance  —  Max FPS",
	Description = "Disables everything including other players beyond range. Best for heavy games like keyboard/tile simulators where FPS tanks hard.",
	Callback = function()
		setPreset("Performance")
		Rayfield:Notify({ Title = "Performance", Content = "Max FPS mode active", Duration = 3 })
	end,
})

PresetTab:CreateButton({
	Name = "Balanced  —  FPS + visuals ok",
	Description = "FPS boost without completely trashing visuals. Players nearby still visible. Recommended for most games.",
	Callback = function()
		setPreset("Balanced")
		Rayfield:Notify({ Title = "Balanced", Content = "Balanced mode active", Duration = 3 })
	end,
})

PresetTab:CreateButton({
	Name = "Quality  —  Mild optimize",
	Description = "Only disables heavy lighting effects. For games that already run fine but need a bit more stability.",
	Callback = function()
		setPreset("Quality")
		Rayfield:Notify({ Title = "Quality", Content = "Quality mode active", Duration = 3 })
	end,
})

PresetTab:CreateButton({
	Name = "Reset  —  Back to default",
	Description = "Turns off all optimizations and restores the game to its original state.",
	Callback = function()
		state.graphics = false
		state.particles = false
		state.decals = false
		state.shadows = false
		state.billboards = false
		state.partCull = false
		state.playerCull = false
		applyGraphics(false)
		applyParticles(false)
		applyDecals(false)
		applyShadows(false)
		applyBillboards(false)
		applyPartCull(false)
		applyPlayerCull(false)
		Rayfield:Notify({ Title = "Reset", Content = "All optimizations off", Duration = 3 })
	end,
})

MainTab:CreateSection("Basic")

MainTab:CreateToggle({
	Name = "Graphics Nuke",
	Description = "Forces graphics to the lowest level and disables all lighting effects (blur, bloom, sun rays). Safe on any game.",
	CurrentValue = false,
	Flag = "graphics",
	Callback = function(val)
		state.graphics = val
		applyGraphics(val)
	end,
})

MainTab:CreateToggle({
	Name = "Remove Particles & Trails",
	Description = "Disables particle effects, smoke, fire, sparkles, and character trails. Visual effects disappear but gameplay is unaffected.",
	CurrentValue = false,
	Flag = "particles",
	Callback = function(val)
		state.particles = val
		applyParticles(val)
	end,
})

MainTab:CreateToggle({
	Name = "Hide Decals & Textures",
	Description = "Hides images and textures applied to objects. Map will look plain but gives a significant FPS boost in tile/keyboard games.",
	CurrentValue = false,
	Flag = "decals",
	Callback = function(val)
		state.decals = val
		applyDecals(val)
	end,
})

MainTab:CreateToggle({
	Name = "Disable Shadows",
	Description = "Removes shadows from all objects. One of the most impactful toggles for FPS on low-end devices.",
	CurrentValue = false,
	Flag = "shadows",
	Callback = function(val)
		state.shadows = val
		applyShadows(val)
	end,
})

MainTab:CreateSection("Advanced")

MainTab:CreateToggle({
	Name = "Billboard Distance Cull",
	Description = "Hides floating text and 3D labels (player names, leaderboards) that are far from your character. Adjust the range with the slider below.",
	CurrentValue = false,
	Flag = "billboards",
	Callback = function(val)
		state.billboards = val
		applyBillboards(val)
	end,
})

MainTab:CreateSlider({
	Name = "Billboard Cull Range",
	Description = "Max distance a billboard is still visible. Lower = more hidden = more FPS impact.",
	Range = {20, 200},
	Increment = 10,
	Suffix = " studs",
	CurrentValue = 80,
	Flag = "billboardRange",
	Callback = function(val)
		state.billboardRange = val
	end,
})

MainTab:CreateToggle({
	Name = "Player Distance Cull",
	Description = "Hides other players' characters beyond a set range. Very effective on crowded servers since each player has trails, particles, and mesh parts.",
	CurrentValue = false,
	Flag = "playerCull",
	Callback = function(val)
		state.playerCull = val
		applyPlayerCull(val)
	end,
})

MainTab:CreateSlider({
	Name = "Player Cull Range",
	Description = "Distance before other players get hidden. Recommended 40-60 for busy servers.",
	Range = {20, 200},
	Increment = 10,
	Suffix = " studs",
	CurrentValue = 60,
	Flag = "playerCullRange",
	Callback = function(val)
		state.playerCullRange = val
	end,
})

MainTab:CreateSection("Keyboard / Tile Game Only")

MainTab:CreateToggle({
	Name = "Part Distance Cull",
	Description = "Hides tiles and objects far from your character. Very effective in keyboard simulators since hundreds of tiles keep rendering even off-screen.",
	CurrentValue = false,
	Flag = "partCull",
	Callback = function(val)
		state.partCull = val
		applyPartCull(val)
	end,
})

MainTab:CreateSlider({
	Name = "Part Cull Range",
	Description = "Distance before tiles get hidden. Too low may hide important objects. Recommended to start at 80-100.",
	Range = {20, 300},
	Increment = 10,
	Suffix = " studs",
	CurrentValue = 100,
	Flag = "partCullRange",
	Callback = function(val)
		state.partCullRange = val
	end,
})

local debugLabel = DebugTab:CreateParagraph({
	Title = "Results",
	Content = "Press a button below.",
})

DebugTab:CreateButton({
	Name = "Scan Workspace",
	Description = "Counts all heavy objects in the current game. Useful for knowing how demanding a game is before picking a preset.",
	Callback = function()
		local counts = {
			ParticleEmitter = 0, Smoke = 0, Fire = 0, Sparkles = 0,
			Trail = 0, Decal = 0, Texture = 0, BillboardGui = 0,
			BasePart = 0, BlurEffect = 0, SunRaysEffect = 0, BloomEffect = 0,
		}
		for _, obj in ipairs(workspace:GetDescendants()) do
			local cn = obj.ClassName
			if counts[cn] ~= nil then counts[cn] = counts[cn] + 1 end
		end
		for _, e in ipairs(Lighting:GetChildren()) do
			local cn = e.ClassName
			if counts[cn] ~= nil then counts[cn] = counts[cn] + 1 end
		end
		local result = ""
		for k, v in pairs(counts) do
			result = result .. k .. ": " .. v .. "\n"
		end
		debugLabel:Set({ Title = "Scan Results", Content = result })
	end,
})

DebugTab:CreateButton({
	Name = "FPS Check",
	Description = "Measures average FPS over 60 frames (~1 second). Run before and after applying a preset to see the difference.",
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
		debugLabel:Set({ Title = "FPS Result", Content = "Sampling... (wait ~1s)" })
	end,
})
