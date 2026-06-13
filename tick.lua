local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local lp = Players.LocalPlayer

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

-- ============================================================
-- Config persistence (save/load state.* to a file)
-- ============================================================
local CONFIG_FOLDER = "TickOptimizer"
local CONFIG_FILE = CONFIG_FOLDER .. "/config.json"
local FILE_API_OK = writefile and readfile and isfile and isfolder and makefolder

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
	-- How many times per second the distance-based culling loops
	-- (billboards / partCull / playerCull) re-check distances.
	-- Lower = cheaper, higher = more responsive.
	cullRate = 5,
}

local function saveConfig()
	if not FILE_API_OK then return end
	pcall(function()
		if not isfolder(CONFIG_FOLDER) then
			makefolder(CONFIG_FOLDER)
		end
		writefile(CONFIG_FILE, HttpService:JSONEncode(state))
	end)
end

local function loadConfig()
	if not FILE_API_OK then return end
	pcall(function()
		if isfile(CONFIG_FILE) then
			local saved = HttpService:JSONDecode(readfile(CONFIG_FILE))
			for k, v in pairs(saved) do
				if state[k] ~= nil then
					state[k] = v
				end
			end
		end
	end)
end

-- Load saved values BEFORE UI is built so toggles/sliders show
-- the correct CurrentValue on startup.
loadConfig()

-- ============================================================
-- Connections & caches
-- ============================================================
local heartbeatConn = nil          -- billboard cull heartbeat
local billboardAddedConn = nil
local billboardRemovingConn = nil
local billboardCache = {}          -- [BillboardGui] = parentBasePart

local partCullConn = nil           -- part cull heartbeat
local partAddedConn = nil
local partRemovingConn = nil
local partCullCache = {}           -- [BasePart] = true

local playerCullConn = nil         -- player cull heartbeat

-- ============================================================
-- Cache helpers (built once, maintained incrementally)
-- ============================================================
local function billboardCacheAdd(obj)
	if obj:IsA("BillboardGui") then
		local p = obj.Parent
		if p and p:IsA("BasePart") then
			billboardCache[obj] = p
		end
	end
end

local function rebuildBillboardCache()
	billboardCache = {}
	for _, obj in ipairs(workspace:GetDescendants()) do
		billboardCacheAdd(obj)
	end
end

local function isLocalCharacterPart(obj)
	local char = lp.Character
	return char ~= nil and obj:IsDescendantOf(char)
end

local function partCacheAdd(obj)
	if obj:IsA("BasePart") and not isLocalCharacterPart(obj) then
		partCullCache[obj] = true
	end
end

local function rebuildPartCullCache()
	partCullCache = {}
	for _, obj in ipairs(workspace:GetDescendants()) do
		partCacheAdd(obj)
	end
end

-- When the local player respawns, their new character's parts may briefly
-- get added to the part-cull cache before lp.Character updates. Strip them
-- out so the player doesn't get culled/transparent right after respawn.
lp.CharacterAdded:Connect(function(char)
	if not state.partCull then return end
	task.wait(0.1)
	for _, obj in ipairs(char:GetDescendants()) do
		if obj:IsA("BasePart") and partCullCache[obj] then
			partCullCache[obj] = nil
			obj.LocalTransparencyModifier = 0
		end
	end
end)

-- ============================================================
-- Apply functions
-- ============================================================
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

-- Billboard distance cull: cache BillboardGui+part pairs once, maintain via
-- DescendantAdded/Removing, and only re-check distances at state.cullRate
-- times per second instead of every single frame.
local function applyBillboards(enabled)
	if heartbeatConn then heartbeatConn:Disconnect(); heartbeatConn = nil end
	if billboardAddedConn then billboardAddedConn:Disconnect(); billboardAddedConn = nil end
	if billboardRemovingConn then billboardRemovingConn:Disconnect(); billboardRemovingConn = nil end

	if not enabled then
		for gui in pairs(billboardCache) do
			if gui.Parent then
				gui.Enabled = true
			end
		end
		billboardCache = {}
		return
	end

	rebuildBillboardCache()

	billboardAddedConn = workspace.DescendantAdded:Connect(billboardCacheAdd)
	billboardRemovingConn = workspace.DescendantRemoving:Connect(function(obj)
		billboardCache[obj] = nil
	end)

	local acc = 0
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < (1 / state.cullRate) then return end
		acc = 0

		local char = lp.Character
		if not char then return end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local hrpPos = hrp.Position
		local range = state.billboardRange

		for gui, part in pairs(billboardCache) do
			if gui.Parent and part.Parent then
				gui.Enabled = (part.Position - hrpPos).Magnitude < range
			else
				billboardCache[gui] = nil
			end
		end
	end)
end

-- Part distance cull: cache non-character BaseParts once, maintain via
-- DescendantAdded/Removing, and only re-check distances at state.cullRate
-- times per second instead of scanning the whole workspace every frame.
local function applyPartCull(enabled)
	if partCullConn then partCullConn:Disconnect(); partCullConn = nil end
	if partAddedConn then partAddedConn:Disconnect(); partAddedConn = nil end
	if partRemovingConn then partRemovingConn:Disconnect(); partRemovingConn = nil end

	if not enabled then
		for obj in pairs(partCullCache) do
			if obj.Parent then
				obj.LocalTransparencyModifier = 0
			end
		end
		partCullCache = {}
		return
	end

	rebuildPartCullCache()

	partAddedConn = workspace.DescendantAdded:Connect(partCacheAdd)
	partRemovingConn = workspace.DescendantRemoving:Connect(function(obj)
		partCullCache[obj] = nil
	end)

	local acc = 0
	partCullConn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < (1 / state.cullRate) then return end
		acc = 0

		local char = lp.Character
		if not char then return end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local hrpPos = hrp.Position
		local range = state.partCullRange

		for obj in pairs(partCullCache) do
			if obj.Parent then
				local dist = (obj.Position - hrpPos).Magnitude
				obj.LocalTransparencyModifier = dist > range and 1 or 0
			else
				partCullCache[obj] = nil
			end
		end
	end)
end

-- Player distance cull: logic unchanged, just throttled to state.cullRate
-- times per second instead of every frame.
local function applyPlayerCull(enabled)
	if playerCullConn then playerCullConn:Disconnect(); playerCullConn = nil end

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

	local acc = 0
	playerCullConn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < (1 / state.cullRate) then return end
		acc = 0

		local char = lp.Character
		if not char then return end
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		local hrpPos = hrp.Position
		local range = state.playerCullRange

		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= lp and player.Character then
				local otherHRP = player.Character:FindFirstChild("HumanoidRootPart")
				if otherHRP then
					local dist = (otherHRP.Position - hrpPos).Magnitude
					local hide = dist > range
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

-- ============================================================
-- Presets (drive everything through Rayfield.Flags so the UI
-- and the saved config stay in sync with the actual state)
-- ============================================================
local function setPreset(mode)
	local cfg
	if mode == "Performance" then
		cfg = {
			graphics = true, particles = true, decals = true, shadows = true,
			billboards = true, billboardRange = 40,
			partCull = true, partCullRange = 60,
			playerCull = true, playerCullRange = 40,
		}
	elseif mode == "Balanced" then
		cfg = {
			graphics = true, particles = true, decals = false, shadows = true,
			billboards = true, billboardRange = 80,
			partCull = false, partCullRange = 100,
			playerCull = true, playerCullRange = 60,
		}
	elseif mode == "Quality" then
		cfg = {
			graphics = true, particles = false, decals = false, shadows = true,
			billboards = false, billboardRange = 80,
			partCull = false, partCullRange = 100,
			playerCull = false, playerCullRange = 60,
		}
	else
		return
	end

	-- Ranges first so the toggle callbacks below read the right values.
	Rayfield.Flags["billboardRange"]:Set(cfg.billboardRange)
	Rayfield.Flags["partCullRange"]:Set(cfg.partCullRange)
	Rayfield.Flags["playerCullRange"]:Set(cfg.playerCullRange)

	Rayfield.Flags["graphics"]:Set(cfg.graphics)
	Rayfield.Flags["particles"]:Set(cfg.particles)
	Rayfield.Flags["decals"]:Set(cfg.decals)
	Rayfield.Flags["shadows"]:Set(cfg.shadows)
	Rayfield.Flags["billboards"]:Set(cfg.billboards)
	Rayfield.Flags["partCull"]:Set(cfg.partCull)
	Rayfield.Flags["playerCull"]:Set(cfg.playerCull)

	saveConfig()
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
		Rayfield.Flags["billboardRange"]:Set(80)
		Rayfield.Flags["partCullRange"]:Set(100)
		Rayfield.Flags["playerCullRange"]:Set(60)
		Rayfield.Flags["graphics"]:Set(false)
		Rayfield.Flags["particles"]:Set(false)
		Rayfield.Flags["decals"]:Set(false)
		Rayfield.Flags["shadows"]:Set(false)
		Rayfield.Flags["billboards"]:Set(false)
		Rayfield.Flags["partCull"]:Set(false)
		Rayfield.Flags["playerCull"]:Set(false)
		saveConfig()
		Rayfield:Notify({ Title = "Reset", Content = "All optimizations off", Duration = 3 })
	end,
})

MainTab:CreateSection("Basic")

MainTab:CreateToggle({
	Name = "Graphics Nuke",
	Description = "Forces graphics to the lowest level and disables all lighting effects (blur, bloom, sun rays). Safe on any game.",
	CurrentValue = state.graphics,
	Flag = "graphics",
	Callback = function(val)
		state.graphics = val
		applyGraphics(val)
		saveConfig()
	end,
})

MainTab:CreateToggle({
	Name = "Remove Particles & Trails",
	Description = "Disables particle effects, smoke, fire, sparkles, and character trails. Visual effects disappear but gameplay is unaffected.",
	CurrentValue = state.particles,
	Flag = "particles",
	Callback = function(val)
		state.particles = val
		applyParticles(val)
		saveConfig()
	end,
})

MainTab:CreateToggle({
	Name = "Hide Decals & Textures",
	Description = "Hides images and textures applied to objects. Map will look plain but gives a significant FPS boost in tile/keyboard games.",
	CurrentValue = state.decals,
	Flag = "decals",
	Callback = function(val)
		state.decals = val
		applyDecals(val)
		saveConfig()
	end,
})

MainTab:CreateToggle({
	Name = "Disable Shadows",
	Description = "Removes shadows from all objects. One of the most impactful toggles for FPS on low-end devices.",
	CurrentValue = state.shadows,
	Flag = "shadows",
	Callback = function(val)
		state.shadows = val
		applyShadows(val)
		saveConfig()
	end,
})

MainTab:CreateSection("Advanced")

MainTab:CreateToggle({
	Name = "Billboard Distance Cull",
	Description = "Hides floating text and 3D labels (player names, leaderboards) that are far from your character. Adjust the range with the slider below.",
	CurrentValue = state.billboards,
	Flag = "billboards",
	Callback = function(val)
		state.billboards = val
		applyBillboards(val)
		saveConfig()
	end,
})

MainTab:CreateSlider({
	Name = "Billboard Cull Range",
	Description = "Max distance a billboard is still visible. Lower = more hidden = more FPS impact.",
	Range = {20, 200},
	Increment = 10,
	Suffix = " studs",
	CurrentValue = state.billboardRange,
	Flag = "billboardRange",
	Callback = function(val)
		state.billboardRange = val
		saveConfig()
	end,
})

MainTab:CreateToggle({
	Name = "Player Distance Cull",
	Description = "Hides other players' characters beyond a set range. Very effective on crowded servers since each player has trails, particles, and mesh parts.",
	CurrentValue = state.playerCull,
	Flag = "playerCull",
	Callback = function(val)
		state.playerCull = val
		applyPlayerCull(val)
		saveConfig()
	end,
})

MainTab:CreateSlider({
	Name = "Player Cull Range",
	Description = "Distance before other players get hidden. Recommended 40-60 for busy servers.",
	Range = {20, 200},
	Increment = 10,
	Suffix = " studs",
	CurrentValue = state.playerCullRange,
	Flag = "playerCullRange",
	Callback = function(val)
		state.playerCullRange = val
		saveConfig()
	end,
})

MainTab:CreateSlider({
	Name = "Cull Update Rate",
	Description = "How many times per second billboard/part/player distance checks run. Lower = less CPU overhead, higher = more responsive culling. 5 is a good default.",
	Range = {2, 10},
	Increment = 1,
	Suffix = " Hz",
	CurrentValue = state.cullRate,
	Flag = "cullRate",
	Callback = function(val)
		state.cullRate = val
		saveConfig()
	end,
})

MainTab:CreateSection("Keyboard / Tile Game Only")

MainTab:CreateToggle({
	Name = "Part Distance Cull",
	Description = "Hides tiles and objects far from your character. Very effective in keyboard simulators since hundreds of tiles keep rendering even off-screen.",
	CurrentValue = state.partCull,
	Flag = "partCull",
	Callback = function(val)
		state.partCull = val
		applyPartCull(val)
		saveConfig()
	end,
})

MainTab:CreateSlider({
	Name = "Part Cull Range",
	Description = "Distance before tiles get hidden. Too low may hide important objects. Recommended to start at 80-100.",
	Range = {20, 300},
	Increment = 10,
	Suffix = " studs",
	CurrentValue = state.partCullRange,
	Flag = "partCullRange",
	Callback = function(val)
		state.partCullRange = val
		saveConfig()
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

DebugTab:CreateButton({
	Name = "Save Settings Now",
	Description = "Manually saves the current configuration. Settings also auto-save whenever you change a toggle, slider, or preset.",
	Callback = function()
		if not FILE_API_OK then
			debugLabel:Set({ Title = "Save Settings", Content = "File API (writefile/readfile/isfile/isfolder/makefolder) not available on this executor. Settings won't persist between sessions." })
			return
		end
		saveConfig()
		debugLabel:Set({ Title = "Save Settings", Content = "Saved to: " .. CONFIG_FILE })
	end,
})

DebugTab:CreateButton({
	Name = "Show Config Path",
	Description = "Shows where the saved configuration file lives and whether it currently exists.",
	Callback = function()
		if not FILE_API_OK then
			debugLabel:Set({ Title = "Config Path", Content = "File API not available on this executor — config won't be saved." })
			return
		end
		local exists = isfile(CONFIG_FILE)
		debugLabel:Set({
			Title = "Config Path",
			Content = "Relative path: " .. CONFIG_FILE
				.. "\nExists: " .. tostring(exists)
				.. "\nThis is inside your executor's workspace/files folder (e.g. .../<executor>/workspace/" .. CONFIG_FILE .. ")",
		})
	end,
})
