local RunService = game:GetService("RunService")
local Lighting   = game:GetService("Lighting")
local Players    = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local lp = Players.LocalPlayer

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local CONFIG_FOLDER = "TickOptimizer"
local CONFIG_FILE   = CONFIG_FOLDER .. "/config.json"
local FILE_API_OK   = writefile and readfile and isfile and isfolder and makefolder

-- default state; also used as the canonical "reset" baseline
local DEFAULT_STATE = {
	graphics       = false,
	particles      = false,
	decals         = false,
	shadows        = false,
	billboards     = false,
	billboardRange = 80,
	partCull       = false,
	partCullRange  = 100,
	playerCull     = false,
	playerCullRange= 60,
	cullRate       = 5,
	-- additional game-level settings
	renderDistance = false,
	textureQuality = false,
}

local state = {}
for k, v in pairs(DEFAULT_STATE) do state[k] = v end

-- tracks which preset is active; nil = custom
local activePreset = nil

local PRESETS = {
	Performance = {
		graphics = true, particles = true, decals = true, shadows = true,
		billboards = true, billboardRange = 40,
		partCull = true, partCullRange = 60,
		playerCull = true, playerCullRange = 40,
		renderDistance = true, textureQuality = true,
	},
	Balanced = {
		graphics = true, particles = true, decals = false, shadows = true,
		billboards = true, billboardRange = 80,
		partCull = false, partCullRange = 100,
		playerCull = true, playerCullRange = 60,
		renderDistance = false, textureQuality = true,
	},
	Clarity = {
		-- disables only heavy lighting/post-FX; keeps visuals mostly intact
		graphics = true, particles = false, decals = false, shadows = true,
		billboards = false, billboardRange = 80,
		partCull = false, partCullRange = 100,
		playerCull = false, playerCullRange = 60,
		renderDistance = false, textureQuality = false,
	},
}

-- compare current state to each preset to detect if user has diverged
local function detectPreset()
	for name, cfg in pairs(PRESETS) do
		local match = true
		for k, v in pairs(cfg) do
			if state[k] ~= v then match = false; break end
		end
		if match then return name end
	end

	-- check if all values match DEFAULT_STATE (i.e. reset)
	local isDefault = true
	for k, v in pairs(DEFAULT_STATE) do
		if state[k] ~= v then isDefault = false; break end
	end
	if isDefault then return "Default" end

	return "Custom"
end

local function saveConfig()
	if not FILE_API_OK then return end
	pcall(function()
		if not isfolder(CONFIG_FOLDER) then makefolder(CONFIG_FOLDER) end
		writefile(CONFIG_FILE, HttpService:JSONEncode(state))
	end)
end

local function loadConfig()
	if not FILE_API_OK then return end
	pcall(function()
		if isfile(CONFIG_FILE) then
			local saved = HttpService:JSONDecode(readfile(CONFIG_FILE))
			for k, v in pairs(saved) do
				if state[k] ~= nil then state[k] = v end
			end
		end
	end)
end

loadConfig()

-- ── connections & caches ──────────────────────────────────────────────────────

local heartbeatConn, billboardAddedConn, billboardRemovingConn
local billboardCache = {}

local partCullConn, partAddedConn, partRemovingConn
local partCullCache = {}

local playerCullConn

-- ── cache helpers ─────────────────────────────────────────────────────────────

local function billboardCacheAdd(obj)
	if obj:IsA("BillboardGui") then
		local p = obj.Parent
		if p and p:IsA("BasePart") then billboardCache[obj] = p end
	end
end

local function rebuildBillboardCache()
	billboardCache = {}
	for _, obj in ipairs(workspace:GetDescendants()) do billboardCacheAdd(obj) end
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
	for _, obj in ipairs(workspace:GetDescendants()) do partCacheAdd(obj) end
end

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

-- ── apply functions ───────────────────────────────────────────────────────────

local originalLightingProps = nil -- captured once before first graphics apply

local function captureOriginalLighting()
	if originalLightingProps then return end
	originalLightingProps = {
		GlobalShadows    = Lighting.GlobalShadows,
		FogEnd           = Lighting.FogEnd,
		Brightness       = Lighting.Brightness,
		Ambient          = Lighting.Ambient,
		OutdoorAmbient   = Lighting.OutdoorAmbient,
	}
	-- capture per-effect enabled states
	originalLightingProps.effects = {}
	for _, e in ipairs(Lighting:GetChildren()) do
		if e:IsA("BlurEffect") or e:IsA("ColorCorrectionEffect")
		or e:IsA("DepthOfFieldEffect") or e:IsA("SunRaysEffect")
		or e:IsA("BloomEffect") then
			originalLightingProps.effects[e] = e.Enabled
		end
	end
end

local function applyGraphics(enabled)
	if enabled then
		captureOriginalLighting()
		settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
		Lighting.GlobalShadows  = false
		Lighting.FogEnd         = 100000
		Lighting.Brightness     = 2
		Lighting.Ambient        = Color3.fromRGB(178, 178, 178)
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
		if originalLightingProps then
			Lighting.GlobalShadows  = originalLightingProps.GlobalShadows
			Lighting.FogEnd         = originalLightingProps.FogEnd
			Lighting.Brightness     = originalLightingProps.Brightness
			Lighting.Ambient        = originalLightingProps.Ambient
			Lighting.OutdoorAmbient = originalLightingProps.OutdoorAmbient
			for e, wasEnabled in pairs(originalLightingProps.effects) do
				if e.Parent then e.Enabled = wasEnabled end
			end
		else
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

local function applyRenderDistance(enabled)
	-- StreamingMinRadius/TargetRadius only writable when StreamingEnabled is true.
	-- Non-streaming games throw on write; bail early to avoid callback errors.
	if not workspace.StreamingEnabled then return end
	pcall(function()
		if enabled then
			workspace.StreamingMinRadius    = 64
			workspace.StreamingTargetRadius = 128
		else
			workspace.StreamingMinRadius    = 128
			workspace.StreamingTargetRadius = 512
		end
	end)
end

local function applyTextureQuality(enabled)
	-- Roblox exposes texture budget via settings().Rendering; Level01 = lowest
	if enabled then
		settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
	else
		-- only restore to Automatic if graphics override is also off
		if not state.graphics then
			settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic
		end
	end
end

local function applyShadows(enabled)
	for _, obj in ipairs(workspace:GetDescendants()) do
		if obj:IsA("BasePart") then obj.CastShadow = not enabled end
	end
end

local function applyBillboards(enabled)
	if heartbeatConn      then heartbeatConn:Disconnect();      heartbeatConn      = nil end
	if billboardAddedConn then billboardAddedConn:Disconnect(); billboardAddedConn = nil end
	if billboardRemovingConn then billboardRemovingConn:Disconnect(); billboardRemovingConn = nil end

	if not enabled then
		for gui in pairs(billboardCache) do
			if gui.Parent then gui.Enabled = true end
		end
		billboardCache = {}
		return
	end

	rebuildBillboardCache()
	billboardAddedConn   = workspace.DescendantAdded:Connect(billboardCacheAdd)
	billboardRemovingConn = workspace.DescendantRemoving:Connect(function(obj)
		billboardCache[obj] = nil
	end)

	local acc = 0
	heartbeatConn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < (1 / state.cullRate) then return end
		acc = 0
		local char = lp.Character; if not char then return end
		local hrp  = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
		local hrpPos = hrp.Position
		local range  = state.billboardRange
		for gui, part in pairs(billboardCache) do
			if gui.Parent and part.Parent then
				gui.Enabled = (part.Position - hrpPos).Magnitude < range
			else
				billboardCache[gui] = nil
			end
		end
	end)
end

local function applyPartCull(enabled)
	if partCullConn     then partCullConn:Disconnect();    partCullConn     = nil end
	if partAddedConn    then partAddedConn:Disconnect();   partAddedConn    = nil end
	if partRemovingConn then partRemovingConn:Disconnect(); partRemovingConn = nil end

	if not enabled then
		for obj in pairs(partCullCache) do
			if obj.Parent then obj.LocalTransparencyModifier = 0 end
		end
		partCullCache = {}
		return
	end

	rebuildPartCullCache()
	partAddedConn    = workspace.DescendantAdded:Connect(partCacheAdd)
	partRemovingConn = workspace.DescendantRemoving:Connect(function(obj)
		partCullCache[obj] = nil
	end)

	local acc = 0
	partCullConn = RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < (1 / state.cullRate) then return end
		acc = 0
		local char = lp.Character; if not char then return end
		local hrp  = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
		local hrpPos = hrp.Position
		local range  = state.partCullRange
		for obj in pairs(partCullCache) do
			if obj.Parent then
				obj.LocalTransparencyModifier = (obj.Position - hrpPos).Magnitude > range and 1 or 0
			else
				partCullCache[obj] = nil
			end
		end
	end)
end

local function applyPlayerCull(enabled)
	if playerCullConn then playerCullConn:Disconnect(); playerCullConn = nil end

	if not enabled then
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= lp and player.Character then
				for _, obj in ipairs(player.Character:GetDescendants()) do
					if obj:IsA("BasePart") then obj.LocalTransparencyModifier = 0 end
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
		local char = lp.Character; if not char then return end
		local hrp  = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
		local hrpPos = hrp.Position
		local range  = state.playerCullRange
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= lp and player.Character then
				local otherHRP = player.Character:FindFirstChild("HumanoidRootPart")
				if otherHRP then
					local hide = (otherHRP.Position - hrpPos).Magnitude > range
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

-- applies all active toggles to newly spawned objects so state stays consistent
workspace.DescendantAdded:Connect(function(obj)
	if state.particles then
		if obj:IsA("ParticleEmitter") or obj:IsA("Smoke")
		or obj:IsA("Fire") or obj:IsA("Sparkles") or obj:IsA("Trail") then
			obj.Enabled = false
		end
	end
	if state.shadows then
		if obj:IsA("BasePart") then obj.CastShadow = false end
	end
	if state.decals then
		if obj:IsA("Decal") or obj:IsA("Texture") then obj.Transparency = 1 end
	end
end)

Lighting.ChildAdded:Connect(function(e)
	if state.graphics then
		task.wait(0.5)
		if e:IsA("BlurEffect") or e:IsA("SunRaysEffect") or e:IsA("BloomEffect")
		or e:IsA("ColorCorrectionEffect") or e:IsA("DepthOfFieldEffect") then
			e.Enabled = false
		end
	end
end)

-- ── UI ────────────────────────────────────────────────────────────────────────

local Window = Rayfield:CreateWindow({
	Name               = "Tick Optimizer",
	LoadingTitle       = "Tick Optimizer",
	LoadingSubtitle    = "by yurika-sudo",
	ConfigurationSaving = { Enabled = false },
	Discord            = { Enabled = false },
	KeySystem          = false,
})

local PresetTab = Window:CreateTab("Preset", "layers")
local MainTab   = Window:CreateTab("Main",   "zap")
local DebugTab  = Window:CreateTab("Debug",  "bug")

-- label updated whenever preset changes or user manually tweaks anything
local presetStatusLabel = PresetTab:CreateParagraph({
	Title   = "Active Profile",
	Content = "Loading...",
})

local function refreshPresetStatus()
	local detected = detectPreset()
	activePreset = detected ~= "Custom" and detected or nil
	local msg
	if detected == "Custom" then
		msg = "Custom — you've adjusted settings manually. Applying a preset will override these values."
	elseif detected == "Default" then
		msg = "Default — all optimizations are off."
	else
		msg = detected .. " preset active."
	end
	presetStatusLabel:Set({ Title = "Active Profile", Content = msg })
end

-- Apply preset directly without going through Rayfield.Flags:Set — avoids
-- callback errors from Rayfield flag timing issues on some executors.
-- State is updated first so any running heartbeat loops pick up new values
-- immediately; then apply* fns are called to push changes to the game.
local function setPreset(mode)
	local cfg = PRESETS[mode]
	if not cfg then return end

	-- update state table first (ranges before booleans — heartbeats read ranges)
	state.billboardRange  = cfg.billboardRange
	state.partCullRange   = cfg.partCullRange
	state.playerCullRange = cfg.playerCullRange

	state.graphics       = cfg.graphics
	state.particles      = cfg.particles
	state.decals         = cfg.decals
	state.shadows        = cfg.shadows
	state.billboards     = cfg.billboards
	state.partCull       = cfg.partCull
	state.playerCull     = cfg.playerCull
	state.renderDistance = cfg.renderDistance
	state.textureQuality = cfg.textureQuality

	-- call apply functions directly
	applyGraphics(cfg.graphics)
	applyTextureQuality(cfg.textureQuality)
	applyRenderDistance(cfg.renderDistance)
	applyParticles(cfg.particles)
	applyDecals(cfg.decals)
	applyShadows(cfg.shadows)
	applyBillboards(cfg.billboards)
	applyPartCull(cfg.partCull)
	applyPlayerCull(cfg.playerCull)

	-- sync Rayfield UI to reflect new values (best-effort; pcall so failures
	-- don't abort the preset — actual state is already applied above)
	pcall(function()
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
		Rayfield.Flags["renderDistance"]:Set(cfg.renderDistance)
		Rayfield.Flags["textureQuality"]:Set(cfg.textureQuality)
	end)

	saveConfig()
	refreshPresetStatus()
end

-- ── Preset tab ────────────────────────────────────────────────────────────────

PresetTab:CreateSection("Profiles")

PresetTab:CreateButton({
	Name        = "Performance",
	Description = "Maximum FPS — all optimizations on, aggressive culling. Good for heavy tile/simulator games.",
	Callback = function()
		setPreset("Performance")
		Rayfield:Notify({ Title = "Performance", Content = "Profile applied", Duration = 3 })
	end,
})

PresetTab:CreateButton({
	Name        = "Balanced",
	Description = "FPS boost without gutting visuals. Nearby players still visible, decals kept, streaming untouched.",
	Callback = function()
		setPreset("Balanced")
		Rayfield:Notify({ Title = "Balanced", Content = "Profile applied", Duration = 3 })
	end,
})

PresetTab:CreateButton({
	Name        = "Clarity",
	Description = "Removes only expensive post-processing and shadows. Visuals stay mostly intact — for games that already run fine.",
	Callback = function()
		setPreset("Clarity")
		Rayfield:Notify({ Title = "Clarity", Content = "Profile applied", Duration = 3 })
	end,
})

PresetTab:CreateSection("Reset")

PresetTab:CreateButton({
	Name        = "Reset to Default",
	Description = "Disables all optimizations and restores game to its original state.",
	Callback = function()
		for k, v in pairs(DEFAULT_STATE) do state[k] = v end

		applyGraphics(false)
		applyTextureQuality(false)
		applyRenderDistance(false)
		applyParticles(false)
		applyDecals(false)
		applyShadows(false)
		applyBillboards(false)
		applyPartCull(false)
		applyPlayerCull(false)

		pcall(function()
			Rayfield.Flags["billboardRange"]:Set(DEFAULT_STATE.billboardRange)
			Rayfield.Flags["partCullRange"]:Set(DEFAULT_STATE.partCullRange)
			Rayfield.Flags["playerCullRange"]:Set(DEFAULT_STATE.playerCullRange)
			Rayfield.Flags["graphics"]:Set(false)
			Rayfield.Flags["particles"]:Set(false)
			Rayfield.Flags["decals"]:Set(false)
			Rayfield.Flags["shadows"]:Set(false)
			Rayfield.Flags["billboards"]:Set(false)
			Rayfield.Flags["partCull"]:Set(false)
			Rayfield.Flags["playerCull"]:Set(false)
			Rayfield.Flags["renderDistance"]:Set(false)
			Rayfield.Flags["textureQuality"]:Set(false)
		end)

		saveConfig()
		refreshPresetStatus()
		Rayfield:Notify({ Title = "Reset", Content = "All optimizations off", Duration = 3 })
	end,
})

-- ── Main tab ──────────────────────────────────────────────────────────────────

-- shared callback wrapper: applies, saves, then updates preset status label
local function onChange(applyFn, stateKey)
	return function(val)
		state[stateKey] = val
		applyFn(val)
		saveConfig()
		refreshPresetStatus()
	end
end

MainTab:CreateSection("Rendering")

MainTab:CreateToggle({
	Name         = "Graphics Override",
	Description  = "Forces minimum quality level and disables post-processing effects (blur, bloom, sun rays, depth of field).",
	CurrentValue = state.graphics,
	Flag         = "graphics",
	Callback     = onChange(applyGraphics, "graphics"),
})

MainTab:CreateToggle({
	Name         = "Texture Quality",
	Description  = "Locks texture resolution to the minimum. Stacks with Graphics Override for extra GPU headroom.",
	CurrentValue = state.textureQuality,
	Flag         = "textureQuality",
	Callback     = onChange(applyTextureQuality, "textureQuality"),
})

MainTab:CreateToggle({
	Name         = "Render Distance",
	Description  = "Reduces client-side streaming radius. Useful for open-world games with large maps; may cause pop-in near edges.",
	CurrentValue = state.renderDistance,
	Flag         = "renderDistance",
	Callback     = onChange(applyRenderDistance, "renderDistance"),
})

MainTab:CreateToggle({
	Name         = "Shadow Removal",
	Description  = "Disables shadow casting on all BaseParts. Significant FPS gain on shadow-heavy maps.",
	CurrentValue = state.shadows,
	Flag         = "shadows",
	Callback     = onChange(applyShadows, "shadows"),
})

MainTab:CreateSection("Scene Cleanup")

MainTab:CreateToggle({
	Name         = "Particle Suppression",
	Description  = "Disables particle emitters, smoke, fire, sparkles, and trails. Gameplay unaffected.",
	CurrentValue = state.particles,
	Flag         = "particles",
	Callback     = onChange(applyParticles, "particles"),
})

MainTab:CreateToggle({
	Name         = "Decal & Texture Strip",
	Description  = "Makes all decals and surface textures fully transparent. Map looks bare but draw calls drop sharply.",
	CurrentValue = state.decals,
	Flag         = "decals",
	Callback     = onChange(applyDecals, "decals"),
})

MainTab:CreateSection("Distance Culling")

MainTab:CreateToggle({
	Name         = "Billboard Culling",
	Description  = "Hides floating UI labels (player names, damage numbers, 3D text) beyond the configured range.",
	CurrentValue = state.billboards,
	Flag         = "billboards",
	Callback     = onChange(applyBillboards, "billboards"),
})

MainTab:CreateSlider({
	Name         = "Billboard Range",
	Description  = "Distance at which billboards become visible. Lower = more hidden = cheaper.",
	Range        = {20, 200},
	Increment    = 10,
	Suffix       = " studs",
	CurrentValue = state.billboardRange,
	Flag         = "billboardRange",
	Callback = function(val)
		state.billboardRange = val
		saveConfig()
		refreshPresetStatus()
	end,
})

MainTab:CreateToggle({
	Name         = "Player Culling",
	Description  = "Hides other players' characters beyond range. High impact on crowded servers.",
	CurrentValue = state.playerCull,
	Flag         = "playerCull",
	Callback     = onChange(applyPlayerCull, "playerCull"),
})

MainTab:CreateSlider({
	Name         = "Player Cull Range",
	Description  = "Distance before other players get hidden. 40–60 studs suits most servers.",
	Range        = {20, 200},
	Increment    = 10,
	Suffix       = " studs",
	CurrentValue = state.playerCullRange,
	Flag         = "playerCullRange",
	Callback = function(val)
		state.playerCullRange = val
		saveConfig()
		refreshPresetStatus()
	end,
})

MainTab:CreateToggle({
	Name         = "Part Culling",
	Description  = "Hides non-character BaseParts beyond range. Best for tile/keyboard simulators with hundreds of map objects.",
	CurrentValue = state.partCull,
	Flag         = "partCull",
	Callback     = onChange(applyPartCull, "partCull"),
})

MainTab:CreateSlider({
	Name         = "Part Cull Range",
	Description  = "Distance before world parts get hidden. Start at 80–100; too low may hide gameplay-critical objects.",
	Range        = {20, 300},
	Increment    = 10,
	Suffix       = " studs",
	CurrentValue = state.partCullRange,
	Flag         = "partCullRange",
	Callback = function(val)
		state.partCullRange = val
		saveConfig()
		refreshPresetStatus()
	end,
})

MainTab:CreateSlider({
	Name         = "Cull Update Rate",
	Description  = "How often distance checks run per second (billboard/part/player). Lower = less CPU; higher = snappier transitions.",
	Range        = {2, 10},
	Increment    = 1,
	Suffix       = " Hz",
	CurrentValue = state.cullRate,
	Flag         = "cullRate",
	Callback = function(val)
		state.cullRate = val
		saveConfig()
		refreshPresetStatus()
	end,
})

-- ── Debug tab ─────────────────────────────────────────────────────────────────

local debugLabel = DebugTab:CreateParagraph({
	Title   = "Output",
	Content = "Run a tool below.",
})

DebugTab:CreateButton({
	Name        = "Scan Workspace",
	Description = "Counts heavy objects in the current scene. Useful for picking an appropriate profile.",
	Callback = function()
		local counts = {
			ParticleEmitter = 0, Smoke = 0, Fire = 0, Sparkles = 0,
			Trail = 0, Decal = 0, Texture = 0, BillboardGui = 0,
			BasePart = 0, BlurEffect = 0, SunRaysEffect = 0, BloomEffect = 0,
			ColorCorrectionEffect = 0, DepthOfFieldEffect = 0,
		}
		for _, obj in ipairs(workspace:GetDescendants()) do
			local cn = obj.ClassName
			if counts[cn] ~= nil then counts[cn] += 1 end
		end
		for _, e in ipairs(Lighting:GetChildren()) do
			local cn = e.ClassName
			if counts[cn] ~= nil then counts[cn] += 1 end
		end
		local lines = {}
		for k, v in pairs(counts) do
			table.insert(lines, k .. ": " .. v)
		end
		table.sort(lines)
		debugLabel:Set({ Title = "Scan Results", Content = table.concat(lines, "\n") })
	end,
})

DebugTab:CreateButton({
	Name        = "FPS Benchmark",
	Description = "Samples FPS over 60 frames (~1s). Run before and after applying a profile to compare.",
	Callback = function()
		debugLabel:Set({ Title = "FPS Benchmark", Content = "Sampling..." })
		local samples, conn = {}, nil
		conn = RunService.Heartbeat:Connect(function(dt)
			table.insert(samples, 1 / dt)
			if #samples >= 60 then
				conn:Disconnect()
				local sum = 0
				for _, v in ipairs(samples) do sum += v end
				debugLabel:Set({
					Title   = "FPS Benchmark",
					Content = "Avg over 60 frames: " .. math.floor(sum / #samples) .. " fps",
				})
			end
		end)
	end,
})

DebugTab:CreateButton({
	Name        = "Game Info",
	Description = "Shows current game-level settings that affect rendering.",
	Callback = function()
		local streamingEnabled = pcall(function() return workspace.StreamingEnabled end)
		                         and tostring(workspace.StreamingEnabled) or "n/a"
		local qualityLevel = tostring(settings().Rendering.QualityLevel)
		local info = "Quality level: " .. qualityLevel
			.. "\nStreaming enabled: " .. streamingEnabled
			.. "\nGlobal shadows: " .. tostring(Lighting.GlobalShadows)
			.. "\nFog end: " .. tostring(Lighting.FogEnd)
			.. "\nActive profile: " .. detectPreset()
		debugLabel:Set({ Title = "Game Info", Content = info })
	end,
})

DebugTab:CreateButton({
	Name        = "Save Settings",
	Description = "Manually flush config to disk. Settings also auto-save on every change.",
	Callback = function()
		if not FILE_API_OK then
			debugLabel:Set({
				Title   = "Save Settings",
				Content = "File API unavailable on this executor — settings won't persist between sessions.",
			})
			return
		end
		saveConfig()
		debugLabel:Set({ Title = "Save Settings", Content = "Saved → " .. CONFIG_FILE })
	end,
})

DebugTab:CreateButton({
	Name        = "Config Path",
	Description = "Shows where the config file lives and whether it exists.",
	Callback = function()
		if not FILE_API_OK then
			debugLabel:Set({ Title = "Config Path", Content = "File API unavailable." })
			return
		end
		debugLabel:Set({
			Title   = "Config Path",
			Content = CONFIG_FILE .. "\nExists: " .. tostring(isfile(CONFIG_FILE)),
		})
	end,
})

DebugTab:CreateButton({
	Name        = "Ping Check",
	Description = "Measures round-trip latency to the server over 10 samples (~2s).",
	Callback = function()
		debugLabel:Set({ Title = "Ping Check", Content = "Sampling..." })
		local stats = game:GetService("Stats")
		local samples, conn = {}, nil
		local elapsed = 0
		conn = RunService.Heartbeat:Connect(function(dt)
			elapsed += dt
			-- Stats.Network.ServerStatsItem["Data Ping"] gives the current ping in ms
			local ok, ping = pcall(function()
				return stats.Network.ServerStatsItem["Data Ping"]:GetValue()
			end)
			if ok then table.insert(samples, ping) end
			if elapsed >= 2 or #samples >= 10 then
				conn:Disconnect()
				if #samples == 0 then
					debugLabel:Set({ Title = "Ping Check", Content = "Ping data unavailable on this server." })
					return
				end
				local sum, mn, mx = 0, math.huge, 0
				for _, v in ipairs(samples) do
					sum += v
					if v < mn then mn = v end
					if v > mx then mx = v end
				end
				local avg = math.floor(sum / #samples)
				debugLabel:Set({
					Title   = "Ping Check",
					Content = "Avg: " .. avg .. " ms  |  Min: " .. math.floor(mn) .. "  Max: " .. math.floor(mx) .. "\n(" .. #samples .. " samples)",
				})
			end
		end)
	end,
})


-- initial status update after UI is fully built
refreshPresetStatus()
