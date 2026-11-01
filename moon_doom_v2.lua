--[[
	MOON COLLISION v5 - LEAD-UP + 15 DAY DOOMSDAY  (Delta compatible, client-side)

	One stage every StageLength seconds (default 30):
	  1 normal day | 2-5 = 5 months / 5 weeks / 1 month / 1 week before | 6-20 = Day 1 ... Day 15

	v3: you take damage (shelter matters!), the Moon really breaks apart, moving hurricanes,
	    visible rain, real water + tsunamis, sounds, cracks in the ground, stars, and more.

	GUI:  <  previous   II  pause   >  next   X  stop & restore.  Tap the title for details.
	Re-executing restarts cleanly.
]]

local CONFIG = {
	StageLength = 30,      -- seconds per stage
	TransitionTime = 6,    -- seconds to blend between stages
	StartStage = 1,        -- 1 = normal, 6 = Day 1, 13 = Day 8, 14 = Core Impact
	ShowPanel = true,

	Damage = true,         -- you can get hurt / killed
	DamageScale = 1,       -- 0.5 = half damage, 2 = double damage
	OxygenSeconds = 150,   -- oxygen reserve for the thin-air days (Day 8 on)

	Sounds = true,
	SoundVolume = 1,

	Flood = true,          -- rising water
	TerrainWater = true,   -- real swimmable water (falls back to a visual plane on maps with terrain)
	Tsunamis = true,
	Meteors = true,
	Fires = true,
	Quakes = true,         -- camera shake
	Storms = true,         -- rain + lightning
	Hurricane = true,
	Wind = true,           -- wind pushes your character
	LowGravity = true,
	Floating = true,       -- nearby objects float away
	Rattle = true,         -- loose objects shake with quakes
	RattleAnchored = true, -- also rattle small anchored props
	Collapse = true,        -- strong quakes can collapse nearby buildings
	Mining = true,          -- craft a pickaxe and mine blocks
	Fissures = true,       -- cracks open in the ground during strong quakes
}

--------------------------------------------------------------------
-- SERVICES / STATE
--------------------------------------------------------------------
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local SoundService = game:GetService("SoundService")

local lp = Players.LocalPlayer
local ENV = (getgenv and getgenv()) or _G
if ENV.__MOON_DOOM then pcall(ENV.__MOON_DOOM) end

local running = true
local objs, conns, tweens = {}, {}, {}
local stage, elapsed, paused = CONFIG.StartStage, 0, false
local token, expanded = 0, true
local fireTarget, pulseEvery = 0, 0
local burst = 0
local ORIGGRAV = Workspace.Gravity
local ORIGREVERB = SoundService.AmbientReverb
local Terrain = Workspace:FindFirstChildOfClass("Terrain")

-- shared hazard state
local covered, deep = false, false
local sealed, layersN, enclosure = false, 0, 0
local hazardDps, hazardWhy = 0, ""
local oxy = CONFIG.OxygenSeconds
local AIRMAX = 25
local air = AIRMAX
local dmgFlash = 0
local stumbling, deathShown = false, false
local lastHurtSnd = 0
local toast -- defined with the GUI

local function track(o) objs[#objs + 1] = o return o end
local function connect(sig, fn) local c = sig:Connect(fn) conns[#conns + 1] = c return c end

local function tw(inst, props, t, style, dir)
	if not t or t <= 0 then
		for k, v in pairs(props) do inst[k] = v end
		return
	end
	local tween = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Sine, dir or Enum.EasingDirection.InOut), props)
	tweens[tween] = true
	tween.Completed:Connect(function() tweens[tween] = nil end)
	tween:Play()
	return tween
end

local function getRoot()
	local c = lp.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
local function getHum()
	local c = lp.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end
local function C(r, g, b) return Color3.fromRGB(r, g, b) end
local function G(f) return ORIGGRAV * f end

local char = lp.Character or lp.CharacterAdded:Wait()
char:WaitForChild("HumanoidRootPart", 10)

--------------------------------------------------------------------
-- ORIGINAL LIGHTING / SKY / TERRAIN
--------------------------------------------------------------------
local ORIG = {}
for _, p in ipairs({"Brightness", "Ambient", "OutdoorAmbient", "ClockTime", "FogColor", "FogStart", "FogEnd", "ExposureCompensation"}) do
	ORIG[p] = Lighting[p]
end

local atm = Lighting:FindFirstChildOfClass("Atmosphere")
local atmCreated = false
if not atm then
	atm = Instance.new("Atmosphere")
	atm.Density = 0
	atm.Parent = Lighting
	atmCreated = true
	track(atm)
end
local OA = {Density = atm.Density, Offset = atm.Offset, Color = atm.Color, Decay = atm.Decay, Glare = atm.Glare, Haze = atm.Haze}

local sky = Lighting:FindFirstChildOfClass("Sky")
local OSKY = sky and {StarCount = sky.StarCount, CelestialBodiesShown = sky.CelestialBodiesShown}

local OW = Terrain and {WaterColor = Terrain.WaterColor, WaterTransparency = Terrain.WaterTransparency, WaterReflectance = Terrain.WaterReflectance,
	WaterWaveSize = Terrain.WaterWaveSize, WaterWaveSpeed = Terrain.WaterWaveSpeed}

local function newFx(class, props)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = Lighting
	return track(o)
end
local cc = newFx("ColorCorrectionEffect", {Name = "DoomCC"})
local bloom = newFx("BloomEffect", {Name = "DoomBloom", Intensity = 0, Size = 28, Threshold = 0.8})
local blur = newFx("BlurEffect", {Name = "DoomBlur", Size = 0})
local uwBlur = newFx("BlurEffect", {Name = "DoomUnderwaterBlur", Size = 0})
local rays = newFx("SunRaysEffect", {Name = "DoomRays", Intensity = 0, Spread = 0.8})

--------------------------------------------------------------------
-- FX CONTAINER + HELPERS
--------------------------------------------------------------------
local fx = Instance.new("Folder")
fx.Name = "DoomFX"
fx.Parent = Workspace
track(fx)

local function mkPart(size, cf, mat, col)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = mat or Enum.Material.SmoothPlastic
	p.Color = col or Color3.new(1, 1, 1)
	p.Size = size
	p.CFrame = cf
	return p
end

local function rayP()
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = {lp.Character, fx}
	return rp
end

local startPos = Vector3.zero
local baseY = 0
do
	local root = getRoot()
	if root then
		startPos = root.Position
		local hit = Workspace:Raycast(root.Position, Vector3.new(0, -500, 0), rayP())
		baseY = hit and hit.Position.Y or (root.Position.Y - 3)
	end
end

--------------------------------------------------------------------
-- SOUNDS (Roblox built-in sounds, pitched / looped for rumble, wind, rain, thunder)
-- Swap any id for your own rbxassetid://... if you want different sounds.
--------------------------------------------------------------------
local SND = {
	boom = "rbxasset://sounds/impact_explosion_03.mp3",
	hiss = "rbxasset://sounds/impact_water.mp3",
	pop = "rbxasset://sounds/snap.mp3",
	oof = "rbxasset://sounds/uuhhh.mp3",
	drone = "rbxasset://sounds/bass.mp3",
}
local sfx = Instance.new("Folder")
sfx.Name = "DoomSFX"
sfx.Parent = SoundService
track(sfx)

local hushV = Instance.new("NumberValue") -- 1 = total silence (last stage)

local function mkSound(id, vol, speed, loop)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = vol
	s.PlaybackSpeed = speed or 1
	s.Looped = loop or false
	s.Parent = sfx
	return s
end

local rumbleS = mkSound(SND.boom, 0, 0.22, true)
local rainS = mkSound(SND.hiss, 0, 1.0, true)
local windS = mkSound(SND.hiss, 0, 0.38, true)
local roarS = mkSound(SND.hiss, 0, 0.18, true)
local droneS = mkSound(SND.drone, 0, 0.22, true)
if CONFIG.Sounds then
	for _, s in ipairs({rumbleS, rainS, windS, roarS, droneS}) do pcall(function() s:Play() end) end
end

local function oneShot(id, vol, speed, delay)
	if not CONFIG.Sounds then return end
	task.delay(delay or 0, function()
		if not running then return end
		local s = mkSound(id, math.clamp(vol * CONFIG.SoundVolume * (1 - hushV.Value), 0, 10), speed)
		pcall(function() s:Play() end)
		task.delay(14, function() pcall(function() s:Destroy() end) end)
	end)
end

--------------------------------------------------------------------
-- TWEENED WORLD VALUES
--------------------------------------------------------------------
local NUM_KEYS = {"moonDeg", "egg", "core", "chunkT", "ringT", "quake", "meteor", "ash", "ember", "molten", "acid", "water",
	"rain", "lightning", "wind", "hurr", "float", "gravity", "hush"}
local N = {}
for _, k in ipairs(NUM_KEYS) do N[k] = Instance.new("NumberValue") end
local moonColV = Instance.new("Color3Value")
local waterColV = Instance.new("Color3Value")
local hurrColV = Instance.new("Color3Value")

--------------------------------------------------------------------
-- STAGE DATA (each stage lists only what CHANGES from the previous one)
-- tsu = tsunamis {t = seconds into the stage, h = wave height in studs}
-- heat/toxic = damage per second outdoors, acidDmg = acid / molten rain damage per second (exposed to sky)
--------------------------------------------------------------------
local base = {
	brightness = ORIG.Brightness, ambient = ORIG.Ambient, outdoor = ORIG.OutdoorAmbient, clock = ORIG.ClockTime,
	fogColor = ORIG.FogColor, fogStart = ORIG.FogStart, fogEnd = ORIG.FogEnd, exposure = ORIG.ExposureCompensation,
	atmDensity = OA.Density, atmOffset = OA.Offset, atmColor = OA.Color, atmDecay = OA.Decay, atmGlare = OA.Glare, atmHaze = OA.Haze,
	ccBright = 0, ccContrast = 0, ccSat = 0, ccTint = Color3.new(1, 1, 1), bloom = 0, blur = 0, rays = 0,
	moonDeg = 1.2, moonCol = C(205, 205, 212), egg = 0, core = 0, chunkT = 1, ringT = 1,
	quake = 0, meteor = 0, ash = 0, ember = 0, molten = 0, acid = 0,
	water = -400, waterCol = C(35, 90, 140), fires = 0, pulse = 0,
	rain = 0, lightning = 0, wind = 0, hurr = 0, float = 0, gravity = ORIGGRAV, hush = 0,
	boltCol = C(210, 225, 255), hurrCol = C(70, 72, 82),
	heat = 0, toxic = 0, acidDmg = 0, thin = false, crackHot = false,
}

local STAGES = {}
local function S(label, name, ev, ef, tip, d, flag)
	STAGES[#STAGES + 1] = {label = label, name = name, ev = ev, ef = ef, tip = tip, d = d or {}, impact = flag == "impact", breakup = flag == "breakup"}
end

S("NORMAL DAY", "Business as Usual", "Everything is normal.",
	"The Moon hangs quietly in the sky. Nothing seems wrong... yet.",
	"Enjoy it. The next stages are your time to prepare.", {})

S("5 MONTHS BEFORE", "First Anomalies",
	"Astronomers notice the Moon's orbit is no longer stable. Its distance begins to shrink by a few kilometers a day.",
	"Spring tides run higher than any recorded. Coastal storm systems intensify and unseasonal thunderstorms become common. Most people shrug it off.",
	"Stock up and plan a shelter. A roof protects you from rain, a deep underground bunker from almost everything.",
	{moonDeg = 1.7, rain = 60, lightning = 0.04, wind = 8, hurr = 0.1, ccSat = -0.05, atmDensity = 0.3, atmHaze = 0.8})

S("5 WEEKS BEFORE", "The Storm Season That Wouldn't End",
	"The Moon is visibly larger. Its pull now drags on the atmosphere as well as the oceans.",
	"Storm systems merge and sit over land for days. Hurricanes form out of season and the first coastal evacuations begin.",
	"Don't stand in the open during thunderstorms. Lightning can strike you.",
	{moonDeg = 2.2, rain = 110, lightning = 0.1, wind = 14, hurr = 0.3, ccSat = -0.1,
	 ccTint = C(225, 230, 240), atmDensity = 0.35, atmColor = C(160, 170, 185), atmHaze = 1.2, gravity = G(0.99)})

S("1 MONTH BEFORE", "Superstorms",
	"The Moon spans several times its old width and the tides have doubled.",
	"Category 5 hurricanes batter every coastline and non-stop lightning storms knock out power grids.",
	"Watch the hurricane marker on your HUD. Take cover before the eyewall arrives.",
	{moonDeg = 2.7, rain = 170, lightning = 0.22, wind = 24, hurr = 0.55, exposure = -0.15,
	 ccSat = -0.18, ccTint = C(205, 212, 225), atmColor = C(120, 130, 150), atmDecay = C(80, 90, 110), gravity = G(0.97)})

S("1 WEEK BEFORE", "Tides Out of Control",
	"The Moon fills a huge part of the sky and Earth's crust begins to flex under its pull.",
	"Tides surge far inland, hurricane-force winds never stop and the sky flickers with constant lightning. Loose objects start to feel oddly light.",
	"Get to high ground. A small tsunami hits soon.",
	{moonDeg = 3.4, rain = 230, lightning = 0.38, wind = 38, hurr = 0.8, clock = 20, brightness = 1.2,
	 ambient = C(60, 65, 85), outdoor = C(85, 90, 115), gravity = G(0.93), atmDensity = 0.38,
	 atmColor = C(110, 120, 145), fogStart = 100, fogEnd = 3500, ccSat = -0.25, ccTint = C(195, 205, 225),
	 tsu = {{t = 6, h = 8}}})

S("DAY 1 / 15", "The Tidal Shock",
	"The Moon's orbit destabilizes, setting it on a collision course.",
	"Ocean tides go haywire, surging hundreds of feet high within minutes and wiping out coastal cities worldwide.",
	"TSUNAMIS. Climb above the wave height or you will be swept away.",
	{moonDeg = 5, water = 10, rain = 260, lightning = 0.55, wind = 44, hurr = 0.9, gravity = G(0.9),
	 tsu = {{t = 1, h = 12}, {t = 10, h = 18}}})

S("DAY 2 / 15", "The Looming Giant",
	"The Moon closes the distance, dominating the night sky as a massive disk.",
	"High tides become permanent coastal floods, rendering low-lying regions completely uninhabitable. Low-Earth-orbit satellites experience erratic drag from the shifting gravitational gradient.",
	"Floods are permanent. Stay high. The first faint tremors begin.",
	{moonDeg = 32, quake = 0.1, water = 8, clock = 22, brightness = 1, ambient = C(45, 50, 75), outdoor = C(70, 75, 105),
	 ccSat = -0.2, ccTint = C(200, 210, 235), atmColor = C(100, 110, 140), atmDecay = C(60, 65, 90), atmHaze = 1, exposure = 0.1,
	 rain = 190, lightning = 0.32, wind = 30, hurr = 0.7, gravity = G(0.84), tsu = {{t = 2, h = 14}}})

S("DAY 3 / 15", "Global Tectonic Awakening",
	"Gravitational stress deforms Earth's crust on a planetary scale.",
	"Continuous magnitude 8+ earthquakes strike every continent. Dormant volcanoes erupt simultaneously, choking the stratosphere with ash and sulfur dioxide, collapsing global infrastructure completely.",
	"Quakes knock you down. Ash is toxic outdoors - a roof halves it.",
	{moonDeg = 52, quake = 1.0, ash = 70, ember = 10, ccSat = -0.35, ccTint = C(215, 190, 170),
	 atmDensity = 0.38, atmColor = C(120, 100, 90), atmDecay = C(80, 50, 30), atmHaze = 3,
	 ambient = C(60, 48, 42), outdoor = C(80, 62, 52), fogColor = C(85, 75, 70), fogStart = 200, fogEnd = 3500,
	 rain = 0, lightning = 0.6, boltCol = C(255, 190, 120), wind = 42, hurr = 0.8, hurrCol = C(90, 75, 65),
	 gravity = G(0.75), float = 0.25, toxic = 0.6, tsu = {{t = 5, h = 20}}})

S("DAY 4 / 15", "Crossing the Roche Limit",
	"The Moon reaches the Roche limit (~9,500 km up), where Earth's tidal forces overcome the Moon's internal gravity.",
	"The Moon distorts into an egg-like shape and violently begins to tear apart, its crust fracturing under the strain.",
	"Watch the sky. The Moon is about to rupture.",
	{moonDeg = 78, egg = 1, core = 0, moonCol = C(215, 180, 160), quake = 1, ember = 22, atmDensity = 0.35,
	 lightning = 0.4, wind = 32, hurr = 0.5, gravity = G(0.6), float = 0.5, toxic = 0.6, tsu = {{t = 14, h = 16}}}, "breakup")

S("DAY 5 / 15", "The Birth of Earth's Ring System",
	"The shattered lunar material spreads out into orbit.",
	"A brilliant, glittering ring of rock, dust, and boulders forms around the Earth, while the main core mass continues its unstoppable descent.",
	"Debris is coming. Get under a solid roof.",
	{moonDeg = 60, egg = 0.15, core = 1, chunkT = 0, ringT = 0.3, moonCol = C(235, 140, 80), quake = 0.7, ash = 60, atmDensity = 0.3,
	 lightning = 0.3, wind = 28, hurr = 0.3, gravity = G(0.45), float = 0.7, toxic = 0.4})

S("DAY 6 / 15", "Atmospheric Friction & Debris Rain",
	"Fragments from the outer ring enter the upper atmosphere.",
	"The sky glows an apocalyptic orange-red as millions of meteorites rain down constantly. Friction superheats the upper atmosphere, raising global ambient temperatures rapidly.",
	"Meteors explode on impact. Stay under cover and away from craters.",
	{moonDeg = 70, chunkT = 1, ringT = 0.15, moonCol = C(255, 120, 50), quake = 0.6, meteor = 3, ember = 60,
	 ambient = C(110, 50, 25), outdoor = C(140, 60, 30), atmDensity = 0.5, atmColor = C(255, 120, 50), atmDecay = C(255, 70, 20), atmHaze = 3,
	 fogColor = C(120, 50, 20), fogStart = 100, fogEnd = 2200, ccSat = 0.1, ccTint = C(255, 175, 130), bloom = 0.6,
	 lightning = 0.2, boltCol = C(255, 160, 90), wind = 36, hurr = 0.4, hurrCol = C(120, 50, 25), gravity = G(0.3), float = 0.9,
	 heat = 0.5, toxic = 0.3})

S("DAY 7 / 15", "Global Firestorms",
	"Continuous atmospheric impacts ignite widespread fires.",
	"Forests, grasslands, and cities catch fire from the relentless searing debris. Thick, toxic plumes of black smoke merge into a planetary canopy, blotting out the sun.",
	"Heat and smoke hurt outdoors. Stay away from fires.",
	{moonDeg = 82, quake = 0.5, meteor = 4, fires = 70, ash = 120,
	 atmDensity = 0.8, atmColor = C(70, 40, 28), atmDecay = C(50, 25, 15), atmHaze = 5,
	 ambient = C(80, 35, 20), outdoor = C(90, 40, 25), fogColor = C(40, 25, 20), fogEnd = 1300, ccBright = -0.05, ccTint = C(255, 160, 120),
	 lightning = 0.5, wind = 56, hurr = 1, hurrCol = C(255, 110, 30), gravity = G(0.22), float = 1,
	 heat = 2, toxic = 1.5})

S("DAY 8 / 15", "Boiling Oceans and Pressure Spikes",
	"Heat from continuous impacts and greenhouse gases boils shallow seas.",
	"Atmospheric pressure spikes wildly as steam mixes with carbon monoxide and ash. Oxygen levels crash due to the death of global plant life, making unassisted breathing impossible.",
	"Your oxygen reserve is draining. Impact is next.",
	{moonDeg = 96, quake = 0.6, water = 6, waterCol = C(200, 200, 210), blur = 5, ember = 40,
	 atmDensity = 0.9, atmColor = C(170, 150, 140), atmDecay = C(130, 100, 80), atmHaze = 6,
	 fogColor = C(150, 130, 120), fogEnd = 800, ccSat = -0.5, ccTint = C(235, 215, 200),
	 lightning = 0.6, wind = 46, hurr = 0.8, hurrCol = C(190, 185, 185), gravity = G(0.15), float = 1,
	 heat = 3, toxic = 1, thin = true})

S("DAY 9 / 15", "The Core Impact",
	"The main core mass of the Moon slams directly into the Earth's crust.",
	"The sheer kinetic energy melts the impact zone instantly. A massive hemisphere of the planet turns into a roiling, superheated sea of liquid magma.",
	"BRACE. Deep underground survives the shockwave best.",
	{moonDeg = 0, quake = 1.2, water = 0, waterCol = C(255, 110, 40), blur = 2, ember = 150, ash = 150, meteor = 2,
	 brightness = 3, ambient = C(200, 80, 30), outdoor = C(255, 90, 30),
	 atmDensity = 1, atmColor = C(255, 90, 20), atmDecay = C(255, 60, 10), atmHaze = 6,
	 fogColor = C(255, 110, 40), fogStart = 0, fogEnd = 300, ccTint = C(255, 140, 90), bloom = 1.5,
	 lightning = 0.8, boltCol = C(255, 200, 140), wind = 100, hurr = 0.6, hurrCol = C(255, 100, 30), gravity = G(1), float = 0,
	 heat = 6, toxic = 2, crackHot = true, tsu = {{t = 12, h = 45}}}, "impact")

S("DAY 10 / 15", "Planetary Shockwaves & Vaporized Oceans",
	"Mega-shockwaves circle the globe multiple times.",
	"The shockwaves flatten every mountain range on Earth. The remaining oceans are entirely vaporized, turning the atmosphere into a pressurized, steam-choked pressure cooker.",
	"Shockwaves hit every few seconds. Hold on.",
	{quake = 0.5, water = -400, blur = 0, ember = 100, ash = 60, meteor = 0, pulse = 9, fires = 0,
	 brightness = 2, ambient = C(180, 120, 90), outdoor = C(230, 150, 110),
	 atmColor = C(230, 200, 180), atmDecay = C(220, 170, 140), fogColor = C(230, 200, 180), fogEnd = 220,
	 ccBright = 0.1, ccTint = C(255, 235, 215), bloom = 1, wind = 70, hurr = 0.5, hurrCol = C(200, 170, 150),
	 heat = 8, toxic = 1.5, tsu = {{t = 2, h = 30}}})

S("DAY 11 / 15", "The Ejecta Fallout (Molten Rain)",
	"Tons of pulverized rock and magma blasted into space by the Day 9 impact rain back down.",
	"The entire planet's surface is subjected to a global thermal radiation wave. The sky glows white-hot as falling molten droplets flash-heat the atmosphere, sterilizing every inch of the surface.",
	"Only deep underground is survivable.",
	{quake = 0.6, molten = 220, pulse = 0, ember = 0, ash = 0,
	 brightness = 4, ambient = C(255, 220, 190), outdoor = C(255, 230, 200),
	 atmColor = C(255, 240, 220), atmDecay = C(255, 230, 200), fogColor = C(255, 235, 210), fogEnd = 150,
	 ccBright = 0.15, ccTint = C(255, 245, 230), bloom = 2.5, wind = 30, hurr = 0.2, hurrCol = C(255, 225, 190), lightning = 0.2,
	 heat = 20, toxic = 0, acidDmg = 18})

S("DAY 12 / 15", "The Global Darkening",
	"The dust, ash, and vaporized rock form a thick, permanent global shroud.",
	"Complete, pitch-black darkness envelops the planet. Sunlight cannot penetrate the thick stratospheric haze, plunging the surface into an extreme, toxic twilight.",
	"Total darkness. Lightning is the only light.",
	{quake = 0.2, molten = 0, ash = 40, brightness = 0, exposure = -0.4,
	 ambient = C(6, 4, 4), outdoor = C(6, 4, 4), atmColor = C(0, 0, 0), atmDecay = C(0, 0, 0),
	 fogColor = C(0, 0, 0), fogStart = 0, fogEnd = 70, ccBright = -0.1, ccTint = C(180, 150, 140), bloom = 0,
	 lightning = 1.4, boltCol = C(190, 200, 255), wind = 40, hurr = 0.7, hurrCol = C(30, 25, 25),
	 heat = 4, toxic = 2, acidDmg = 0})

S("DAY 13 / 15", "The Magma Ocean Cools",
	"The surface magma ocean begins to radiate its heat into space.",
	"The roiling seas of lava slowly begin to crust over, cooling into a smooth, featureless shell of black basalt rock across the ruined landscape.",
	"Steam storms rage. The ground is still hot.",
	{quake = 0.1, ash = 0, ember = 25, brightness = 0.6, exposure = 0,
	 ambient = C(40, 12, 6), outdoor = C(60, 18, 8), atmColor = C(50, 15, 8), atmDecay = C(80, 20, 10), atmDensity = 0.9,
	 fogColor = C(30, 8, 4), fogEnd = 180, ccBright = 0, ccSat = -0.2, ccTint = C(255, 150, 110),
	 rain = 220, lightning = 1.0, boltCol = C(220, 225, 255), wind = 52, hurr = 1, hurrCol = C(110, 105, 110),
	 heat = 6, toxic = 1})

S("DAY 14 / 15", "Acidic Downpours",
	"The massive amounts of atmospheric steam begin to condense.",
	"Torrential, highly acidic rains begin to pour down from the skies, washing toxic chemicals and sulfur compounds across the barren basalt plains to form new, boiling primordial seas.",
	"Acid rain burns. A roof blocks it completely.",
	{quake = 0.15, ember = 0, acid = 260, rain = 0, water = 8, waterCol = C(180, 200, 60), brightness = 0.8, bloom = 0.3,
	 ambient = C(45, 55, 25), outdoor = C(65, 80, 30), atmColor = C(120, 140, 60), atmDecay = C(100, 120, 40), atmHaze = 4, atmDensity = 0.85,
	 fogColor = C(80, 95, 40), fogEnd = 260, ccSat = -0.15, ccTint = C(215, 235, 150),
	 lightning = 0.7, wind = 46, hurr = 0.7, hurrCol = C(70, 90, 40),
	 heat = 0, toxic = 1.5, acidDmg = 6})

S("DAY 15 / 15", "A Silent, Ringed World",
	"The skies clear slightly, revealing the aftermath.",
	"Earth is completely unrecognizable - a sterile, silent, ocean-covered world stripped of all life, orbited by a brilliant, permanent ring system composed of the leftover debris of its former moon.",
	"It is over. Look up.",
	{quake = 0, acid = 0, water = 14, waterCol = C(25, 70, 100), ringT = 0, brightness = 1.2, bloom = 0.2,
	 ambient = C(60, 65, 85), outdoor = C(85, 95, 120), atmColor = C(150, 165, 190), atmDecay = C(90, 100, 130), atmHaze = 1, atmDensity = 0.25,
	 fogColor = C(60, 70, 90), fogStart = 400, fogEnd = 3000, ccSat = -0.35, ccTint = C(200, 215, 235),
	 lightning = 0, wind = 3, hurr = 0.1, boltCol = C(210, 225, 255), hush = 1,
	 heat = 0, toxic = 0, acidDmg = 0, thin = false})

local NSTAGES = #STAGES
local IMPACT, BREAKUP = 1, 1
for i, s in ipairs(STAGES) do
	if s.impact then IMPACT = i end
	if s.breakup then BREAKUP = i end
end

local R = {}
do
	local cur = {}
	for k, v in pairs(base) do cur[k] = v end
	for i = 1, NSTAGES do
		for k, v in pairs(STAGES[i].d) do cur[k] = v end
		local snap = {}
		for k, v in pairs(cur) do snap[k] = v end
		R[i] = snap
	end
end

--------------------------------------------------------------------
-- MOON, CRACKS, DEBRIS, GLOW
--------------------------------------------------------------------
local moonDir = Vector3.new(0.45, 0.38, -0.81).Unit
local DIST = 900

local function sphere(part)
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.Sphere
	m.Parent = part
	return part
end

local moon = sphere(mkPart(Vector3.new(10, 10, 10), CFrame.new(), Enum.Material.Neon, C(205, 205, 212)))
moon.Transparency = 1
moon.Parent = fx
local moonGlow = sphere(mkPart(Vector3.new(10, 10, 10), CFrame.new(), Enum.Material.Neon, C(205, 205, 212)))
moonGlow.Transparency = 1
moonGlow.Parent = fx

local craterDefs = {{20, 30, .14}, {35, 200, .10}, {50, 110, .18}, {15, 260, .07}, {45, 320, .12}, {58, 60, .09}, {28, 150, .08}, {40, 10, .06}, {10, 90, .10},
	{55, 250, .07}, {32, 330, .05}, {48, 170, .06}}
local craters = {}
for _, c in ipairs(craterDefs) do
	local p = sphere(mkPart(Vector3.new(1, 1, 1), CFrame.new(), Enum.Material.Neon, C(125, 125, 135)))
	p.Transparency = 1
	p.Parent = fx
	craters[#craters + 1] = {part = p, phi = math.rad(c[1]), alpha = math.rad(c[2]), frac = c[3]}
end

local cracks = {}
for _ = 1, 14 do
	local phi, alpha = math.rad(math.random(8, 62)), math.rad(math.random(0, 359))
	local pts = {}
	for k = 1, 4 do
		pts[k] = {phi = phi, alpha = alpha}
		phi = math.clamp(phi + math.rad(math.random(-9, 9)), math.rad(3), math.rad(70))
		alpha = alpha + math.rad(math.random(-14, 14))
	end
	for k = 1, 3 do
		local p = mkPart(Vector3.new(1, 1, 1), CFrame.new(), Enum.Material.Neon, C(255, 110, 30))
		p.Transparency = 1
		p.Parent = fx
		cracks[#cracks + 1] = {part = p, a = pts[k], b = pts[k + 1]}
	end
end

local debris = {}
local function clearDebris()
	for _, d in ipairs(debris) do pcall(function() d.part:Destroy() end) end
	debris = {}
end

local function spawnDebris()
	clearDebris()
	local r0 = DIST * math.sin(math.rad(78) / 2)
	for i = 1, 70 do
		local dv = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
		if dv.Magnitude < 0.05 then dv = Vector3.new(1, 0, 0) end
		dv = dv.Unit
		local sz = (i <= 8) and math.random(60, 140) or math.random(8, 55)
		local p = mkPart(Vector3.new(sz, sz * (0.6 + math.random() * 0.5), sz * (0.7 + math.random() * 0.5)), CFrame.new(),
			Enum.Material.Neon, C(255, 150, 60))
		if i <= 14 then
			local a0 = Instance.new("Attachment", p)
			a0.Position = Vector3.new(0, sz * 0.5, 0)
			local a1 = Instance.new("Attachment", p)
			a1.Position = Vector3.new(0, -sz * 0.5, 0)
			local tr = Instance.new("Trail")
			tr.Attachment0, tr.Attachment1 = a0, a1
			tr.Lifetime = 1.6
			tr.Color = ColorSequence.new(C(255, 190, 90), C(90, 30, 10))
			tr.Transparency = NumberSequence.new(0.2, 1)
			tr.LightEmission = 1
			tr.Parent = p
		end
		p.Parent = fx
		debris[#debris + 1] = {part = p, off = dv * r0 * (0.2 + math.random() * 0.7), vel = dv * (60 + math.random() * 260),
			rot = CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6),
			ang = Vector3.new((math.random() - 0.5) * 2, (math.random() - 0.5) * 2, (math.random() - 0.5) * 2), age = 0}
	end
end

local function updateDebris(dt, center, right, upv, u)
	if #debris == 0 then return end
	local ct = N.chunkT.Value
	for _, d in ipairs(debris) do
		d.age += dt
		d.off += d.vel * dt
		d.vel = d.vel * (1 - math.min(0.4 * dt, 1))
		if DIST + d.off.Z < 150 or ct >= 0.99 then
			d.part.Transparency = 1
		else
			d.rot = CFrame.Angles(d.ang.X * dt, d.ang.Y * dt, d.ang.Z * dt) * d.rot
			d.part.Transparency = ct
			d.part.Color = C(255, 150, 60):Lerp(C(110, 100, 95), math.clamp(d.age / 8, 0, 1))
			d.part.CFrame = CFrame.new(center + right * d.off.X + upv * d.off.Y + u * d.off.Z) * d.rot
		end
	end
end

local function shockDisc(center, cp)
	local p = mkPart(Vector3.new(6, 60, 60), CFrame.lookAt(center, cp) * CFrame.Angles(0, -math.pi / 2, 0), Enum.Material.Neon, C(255, 225, 170))
	p.Shape = Enum.PartType.Cylinder
	p.Transparency = 0.1
	p.Parent = fx
	tw(p, {Size = Vector3.new(6, 2048, 2048), Transparency = 1}, 2.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	task.delay(3, function() pcall(function() p:Destroy() end) end)
end

local function surfPt(center, u, right, upv, r, phi, alpha)
	local n = -u * math.cos(phi) + (right * math.cos(alpha) + upv * math.sin(alpha)) * math.sin(phi)
	return center + n * r, n
end

local function updateMoon(cp, dt)
	local u = moonDir
	local right = u:Cross(Vector3.yAxis).Unit
	local upv = right:Cross(u)
	local center = cp + u * DIST
	local deg = N.moonDeg.Value
	if deg < 0.05 then
		moon.Transparency = 1
		moonGlow.Transparency = 1
		for _, c in ipairs(craters) do c.part.Transparency = 1 end
		for _, c in ipairs(cracks) do c.part.Transparency = 1 end
	else
		local s = 2 * DIST * math.sin(math.rad(math.min(deg, 176)) / 2)
		local egg = N.egg.Value
		local sx = math.min(2048, s * (1 + 0.35 * egg))
		local sy = math.min(2048, s * (1 - 0.12 * egg))
		moon.Transparency = 0
		moon.Color = moonColV.Value
		moon.Size = Vector3.new(sx, sy, sy)
		moon.CFrame = CFrame.fromMatrix(center, right, upv)
		moonGlow.Transparency = 0.86
		moonGlow.Color = moonColV.Value
		moonGlow.Size = Vector3.new(math.min(2048, sx * 1.18), math.min(2048, sy * 1.18), math.min(2048, sy * 1.18))
		moonGlow.CFrame = moon.CFrame

		local crackVis = math.clamp(math.max((egg - 0.25) / 0.5, N.core.Value), 0, 1)
		local r = s / 2
		for _, c in ipairs(craters) do
			local pt, n = surfPt(center, u, right, upv, r * 0.995, c.phi, c.alpha)
			c.part.Transparency = crackVis
			c.part.Size = Vector3.new(s * c.frac, s * c.frac, math.max(0.05, s * c.frac * 0.06))
			c.part.CFrame = CFrame.lookAt(pt, pt + n)
		end
		if crackVis > 0.02 then
			local w = math.max(0.6, s * 0.012)
			for _, c in ipairs(cracks) do
				local pa = surfPt(center, u, right, upv, r * 1.004, c.a.phi, c.a.alpha)
				local pb = surfPt(center, u, right, upv, r * 1.004, c.b.phi, c.b.alpha)
				local len = math.max(0.5, (pb - pa).Magnitude)
				c.part.Transparency = 1 - crackVis * 0.9
				c.part.Size = Vector3.new(w, w, len)
				c.part.CFrame = CFrame.lookAt(pa, pb) * CFrame.new(0, 0, -len / 2)
			end
		else
			for _, c in ipairs(cracks) do c.part.Transparency = 1 end
		end
	end
	updateDebris(dt, center, right, upv, u)
end

--------------------------------------------------------------------
-- RING + HURRICANE MODEL
--------------------------------------------------------------------
local ringModel = Instance.new("Model")
ringModel.Name = "Ring"
ringModel.Parent = fx
local ringOrigin = mkPart(Vector3.new(1, 1, 1), CFrame.new(0, 0, 0))
ringOrigin.Transparency = 1
ringOrigin.Parent = ringModel
ringModel.PrimaryPart = ringOrigin
local ringParts = {}
local function addRing(p, b)
	p.Transparency = 1
	p.Parent = ringModel
	ringParts[#ringParts + 1] = {part = p, base = b}
end
for bi, band in ipairs({{700, 140, 0.6}, {850, 160, 0.4}, {1000, 120, 0.65}}) do
	local r, w, b = band[1], band[2], band[3]
	local segs = 56
	local len = 2 * math.pi * r / segs * 1.02
	for i = 1, segs do
		local a = (i / segs) * math.pi * 2
		local y = ((i % 2 == 0) and 0.08 or -0.08) + bi * 0.2
		addRing(mkPart(Vector3.new(w, 0.5, len), CFrame.new(math.cos(a) * r, y, math.sin(a) * r) * CFrame.Angles(0, -a, 0), Enum.Material.Neon, C(190, 170, 150)), b)
	end
end
for _ = 1, 140 do
	local a, r, s = math.random() * math.pi * 2, math.random(650, 1050), math.random(6, 34)
	addRing(mkPart(Vector3.new(s, s * (0.5 + math.random() * 0.6), s * (0.6 + math.random() * 0.6)),
		CFrame.new(math.cos(a) * r, math.random(-8, 8), math.sin(a) * r) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6),
		Enum.Material.Neon, C(math.random(150, 230), math.random(130, 200), math.random(110, 180))), 0)
end
connect(N.ringT.Changed, function(v)
	for _, rp in ipairs(ringParts) do rp.part.Transparency = rp.base + (1 - rp.base) * v end
end)

local hurrModel = Instance.new("Model")
hurrModel.Name = "Hurricane"
hurrModel.Parent = fx
local hOrigin = mkPart(Vector3.new(1, 1, 1), CFrame.new())
hOrigin.Transparency = 1
hOrigin.Parent = hurrModel
hurrModel.PrimaryPart = hOrigin
local hParts = {}
for layer = 1, 14 do
	local y = layer * 55
	local r = 140 + layer * 65
	local segs = 8
	for s = 1, segs do
		local a = (s / segs) * math.pi * 2 + layer * 0.4 + math.random() * 0.2
		local arc = 2 * math.pi * r / segs * (0.55 + math.random() * 0.35)
		local p = mkPart(Vector3.new(60 + math.random() * 50, 34 + math.random() * 20, arc),
			CFrame.new(math.cos(a) * r, y, math.sin(a) * r) * CFrame.Angles(0, -a, 0), Enum.Material.SmoothPlastic, C(70, 72, 82))
		p.Transparency = 1
		p.Parent = hurrModel
		hParts[#hParts + 1] = {part = p, shade = 0.55 + 0.45 * (layer / 14), base = 0.4 + math.random() * 0.2}
	end
end
local function hurrAlpha(v)
	local k = CONFIG.Hurricane and math.clamp(v * 1.2, 0, 1) or 0
	for _, h in ipairs(hParts) do h.part.Transparency = 1 - (1 - h.base) * k end
end
local function hurrColor(c)
	for _, h in ipairs(hParts) do h.part.Color = c:Lerp(Color3.new(0, 0, 0), 1 - h.shade) end
end
connect(N.hurr.Changed, hurrAlpha)
connect(hurrColV.Changed, hurrColor)

--------------------------------------------------------------------
-- WATER (fallback plane + real terrain water) + SURGE
--------------------------------------------------------------------
local water = mkPart(Vector3.new(2048, 2, 2048), CFrame.new(0, baseY - 400, 0), Enum.Material.SmoothPlastic, C(35, 90, 140))
water.Reflectance = 0.1
water.Transparency = 1
water.Parent = fx
local water2 = mkPart(Vector3.new(2048, 1, 2048), CFrame.new(0, baseY - 400, 0), Enum.Material.SmoothPlastic, C(60, 120, 170))
water2.Transparency = 1
water2.Parent = fx

local surge = 0 -- extra water height left behind by tsunamis (decays)
local GRID = 4
local gridBase = math.floor(baseY / GRID) * GRID
local WHALF = 512
local wcx = math.floor(startPos.X / GRID) * GRID
local wcz = math.floor(startPos.Z / GRID) * GRID
local slabs = 0
local terrainOK = nil -- nil = not decided yet, true = real water works, false = use the plane

local function terrainBlocked()
	if not Terrain then return true end
	local ok, mats, occ = pcall(function()
		local reg = Region3.new(Vector3.new(wcx - 128, gridBase + GRID, wcz - 128), Vector3.new(wcx + 128, gridBase + GRID + 48, wcz + 128)):ExpandToGrid(GRID)
		return Terrain:ReadVoxels(reg, GRID)
	end)
	if not ok or not occ then return true end
	for x = 1, #occ do
		for y = 1, #occ[x] do
			for z = 1, #occ[x][y] do
				if occ[x][y][z] > 0 then return true end
			end
		end
	end
	return false
end

local function slabFill(k, mat)
	return pcall(function()
		Terrain:FillBlock(CFrame.new(wcx, gridBase + GRID + k * GRID + GRID / 2, wcz), Vector3.new(WHALF * 2, GRID, WHALF * 2), mat)
	end)
end

local function waterStep()
	if not CONFIG.Flood or not CONFIG.TerrainWater or terrainOK == false then return end
	local level = N.water.Value + surge
	local want = level > 2 and math.floor(level / GRID) or 0
	if terrainOK == nil then
		if want <= 0 then return end
		if terrainBlocked() then terrainOK = false return end
	end
	if want > slabs then
		local ok = slabFill(slabs, Enum.Material.Water)
		if ok then slabs += 1 terrainOK = true else terrainOK = false end
	elseif want < slabs then
		slabFill(slabs - 1, Enum.Material.Air)
		slabs -= 1
	end
end

local function surfaceY()
	if terrainOK then
		return slabs > 0 and (gridBase + GRID + slabs * GRID) or nil
	end
	local lv = N.water.Value + surge
	if CONFIG.Flood and lv > -300 then return baseY + lv end
	return nil
end

--------------------------------------------------------------------
-- WEATHER: particles, rain streaks, wind dust
--------------------------------------------------------------------
local weather = mkPart(Vector3.new(150, 1, 150), CFrame.new())
weather.Transparency = 1
weather.Parent = fx

local SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local function emitter(parent, props)
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	for k, v in pairs(props) do e[k] = v end
	e.Parent = parent
	return e
end
local ashE = emitter(weather, {EmissionDirection = Enum.NormalId.Bottom, Texture = SMOKE, Color = ColorSequence.new(C(110, 100, 95)), Size = NumberSequence.new(1.2),
	Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.15, 0.45), NumberSequenceKeypoint.new(1, 1)}),
	Lifetime = NumberRange.new(6, 9), Speed = NumberRange.new(5, 11), SpreadAngle = Vector2.new(25, 25),
	RotSpeed = NumberRange.new(-40, 40), Acceleration = Vector3.new(6, -2, 3)})
local emberE = emitter(weather, {EmissionDirection = Enum.NormalId.Bottom, Texture = SPARK, Color = ColorSequence.new(C(255, 140, 40), C(255, 60, 0)), Size = NumberSequence.new(0.5),
	LightEmission = 1, Lifetime = NumberRange.new(5, 8), Speed = NumberRange.new(10, 18), SpreadAngle = Vector2.new(30, 30),
	Acceleration = Vector3.new(4, -3, 2)})
local moltenE = emitter(weather, {EmissionDirection = Enum.NormalId.Bottom, Texture = SPARK, Color = ColorSequence.new(C(255, 190, 80), C(255, 70, 10)), Size = NumberSequence.new(1.4),
	LightEmission = 1, Lifetime = NumberRange.new(1.0, 1.3), Speed = NumberRange.new(65, 90), SpreadAngle = Vector2.new(4, 4),
	Acceleration = Vector3.new(0, -90, 0)})

local dustPart = mkPart(Vector3.new(220, 10, 220), CFrame.new())
dustPart.Transparency = 1
dustPart.Parent = fx
local dustE = emitter(dustPart, {Texture = SMOKE, Color = ColorSequence.new(C(150, 135, 115)), Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 5)}),
	Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.2, 0.7), NumberSequenceKeypoint.new(1, 1)}),
	Lifetime = NumberRange.new(3, 4), Speed = NumberRange.new(0, 0), Drag = 0.8, SpreadAngle = Vector2.new(0, 0), RotSpeed = NumberRange.new(-30, 30)})

-- rain = lots of long thin streaks that fall around the camera and slant with the wind
local RAIN_MAX = 420
local rainParts, rainPos = {}, {}
for i = 1, RAIN_MAX do
	local p = sphere(mkPart(Vector3.new(0.16, 0.16, 3.4), CFrame.new(0, -1000, 0), Enum.Material.Neon, C(190, 210, 240)))
	p.Transparency = 1
	p.Parent = fx
	rainParts[i] = p
	rainPos[i] = {x = 0, y = 0, z = 0}
end
local rainShown = 0
local rainColLast = nil
local coveredF = 0

--------------------------------------------------------------------
-- WIND + MOVING HURRICANE
--------------------------------------------------------------------
local hdir = Vector3.new(0.8, 0, -0.6).Unit
local H = {pos = Vector3.new(startPos.X + hdir.X * 1800, baseY, startPos.Z + hdir.Z * 1800), dir = -hdir, passed = false}
local wd, windMag, rainMul, eyeCalm, Hdist = Vector3.new(1, 0, 0), 0, 1, false, 99999

local function stepHurricane(dt, t)
	local hv = N.hurr.Value
	if hv < 0.02 then return end
	local speed = 12 + 30 * hv
	if not H.passed then
		local target = Vector3.new(startPos.X + math.cos(t * 0.05) * 220, 0, startPos.Z + math.sin(t * 0.07) * 220)
		local to = target - Vector3.new(H.pos.X, 0, H.pos.Z)
		if to.Magnitude < 90 then H.passed = true else H.dir = to.Unit end
	end
	H.pos = H.pos + H.dir * speed * dt
	local away = Vector3.new(H.pos.X - startPos.X, 0, H.pos.Z - startPos.Z).Magnitude
	if away > 2600 then
		local a = math.random() * math.pi * 2
		H.pos = Vector3.new(startPos.X + math.cos(a) * 2200, baseY, startPos.Z + math.sin(a) * 2200)
		H.dir = Vector3.new(-math.cos(a), 0, -math.sin(a))
		H.passed = false
	end
end

local function updateWind(t)
	local hv = math.min(N.hurr.Value, 1)
	local root = getRoot()
	local rp = root and root.Position or startPos
	local rel = Vector3.new(rp.X - H.pos.X, 0, rp.Z - H.pos.Z)
	local d = rel.Magnitude
	Hdist = d
	local hf = 0
	eyeCalm = false
	if hv > 0.02 then
		if d < 140 then hf = 0.1 eyeCalm = true
		elseif d < 300 then hf = 0.1 + 0.9 * (d - 140) / 160
		else hf = math.max(0, 1 - (d - 300) / 1400) end
		hf = hf * math.min(hv * 1.2, 1)
	end
	local baseAng = 0.7 + math.noise(t * 0.05, 2.2, 0) * 2
	local dir = Vector3.new(math.cos(baseAng), 0, math.sin(baseAng))
	if rel.Magnitude > 1 and hf > 0.05 then
		local tang = Vector3.new(-rel.Z, 0, rel.X).Unit
		local inward = (-rel).Unit
		local k = math.min(hf * 1.5, 1)
		dir = dir * (1 - k) + (tang + inward * 0.8).Unit * k
	end
	if dir.Magnitude > 0.01 then dir = dir.Unit end
	wd = dir
	windMag = N.wind.Value * (0.5 + 1.1 * hf) * (0.8 + 0.6 * math.noise(t * 0.8, 4.4, 0))
	rainMul = eyeCalm and 0.1 or (1 + 1.5 * hf)
end

-- error reporting: each distinct error is printed once and shown on screen
local seenErr = {}
local errSink
local function report(where, e)
	local msg = where .. ": " .. tostring(e)
	if seenErr[msg] then return end
	seenErr[msg] = true
	warn("[MoonDoom] " .. msg)
	if errSink then errSink(msg) end
end

-- Part 2 lives in its own function (Luau allows max 200 local variables per function)
local function __part2()

local onWave, structDamage, onStage, survivalCleanup, majorShock, restoreMined
local tsuShake = 0
local buildFolder = Instance.new("Folder")
buildFolder.Name = "DoomBuild"
buildFolder.Parent = Workspace
track(buildFolder)
local mineFolder = Instance.new("Folder")
mineFolder.Name = "DoomMined"
mineFolder.Parent = Workspace
track(mineFolder)

--------------------------------------------------------------------
-- DAMAGE
--------------------------------------------------------------------
local function hurt(amount, why, loud)
	if not CONFIG.Damage or amount <= 0 then return end
	local hum = getHum()
	if not hum or hum.Health <= 0 then return end
	amount = amount * CONFIG.DamageScale
	hum:TakeDamage(amount)
	dmgFlash = math.min(1, dmgFlash + amount / 25)
	if loud and os.clock() - lastHurtSnd > 1.2 then
		lastHurtSnd = os.clock()
		oneShot(SND.oof, 0.8, 1, 0)
	end
	if hum.Health <= 0 and not deathShown then
		deathShown = true
		pcall(function() lp.Character:BreakJoints() end)
		if toast then toast("YOU DIED - " .. tostring(why), C(255, 70, 60), 5) end
	end
end

local function blast(dmg, impulse, why)
	local root = getRoot()
	if not root then return end
	local expo = deep and 0.2 or (sealed and 0.4 or (covered and 0.6 or 1))
	hurt(dmg * expo, why, true)
	local dv = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
	if dv.Magnitude < 0.1 then dv = Vector3.xAxis end
	dv = dv.Unit
	root:ApplyImpulse((dv * 0.8 + Vector3.new(0, 0.7, 0)) * root.AssemblyMass * impulse)
end

local function stumble()
	local hum = getHum()
	if not hum or hum.Health <= 0 or stumbling then return end
	stumbling = true
	hum.PlatformStand = true
	local root = getRoot()
	if root then
		root:ApplyImpulse(Vector3.new((math.random() - 0.5) * 2, 0.5, (math.random() - 0.5) * 2) * root.AssemblyMass * 25)
	end
	hurt(3 + math.random() * 3, "earthquake fall", true)
	task.delay(1.2, function()
		stumbling = false
		pcall(function()
			hum.PlatformStand = false
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end)
end

--------------------------------------------------------------------
-- METEORS, SCORCH MARKS, LIGHTNING, FISSURES
--------------------------------------------------------------------
local meteors, scorches, fissures = {}, {}, {}

local function spawnMeteor()
	local root = getRoot()
	if not root or #meteors >= 45 then return end
	local ang, dist = math.random() * math.pi * 2, math.random(25, 260)
	local tx = root.Position.X + math.cos(ang) * dist
	local tz = root.Position.Z + math.sin(ang) * dist
	local hit = Workspace:Raycast(Vector3.new(tx, root.Position.Y + 700, tz), Vector3.new(0, -1600, 0), rayP())
	local gy = hit and hit.Position.Y or baseY
	local drift = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * 160
	local vel = Vector3.new(drift.X, -270, drift.Z)
	local fall = 520 / 270
	local start = Vector3.new(tx - drift.X * fall, gy + 520, tz - drift.Z * fall)
	local sz = math.random(3, 9)
	local p = mkPart(Vector3.new(sz, sz, sz), CFrame.new(start) * CFrame.Angles(math.random() * 6, math.random() * 6, 0),
		Enum.Material.Neon, C(255, math.random(90, 160), 30))
	local a0 = Instance.new("Attachment", p)
	a0.Position = Vector3.new(0, sz * 0.5, 0)
	local a1 = Instance.new("Attachment", p)
	a1.Position = Vector3.new(0, -sz * 0.5, 0)
	local tr = Instance.new("Trail")
	tr.Attachment0, tr.Attachment1 = a0, a1
	tr.Lifetime = 0.9
	tr.Color = ColorSequence.new(C(255, 170, 60), C(120, 20, 0))
	tr.Transparency = NumberSequence.new(0.1, 1)
	tr.LightEmission = 1
	tr.Parent = p
	p.Parent = fx
	meteors[#meteors + 1] = {part = p, vel = vel, gy = gy, size = sz}
end

local function impact(pos, size)
	if math.random() < 0.6 then
		local e = Instance.new("Explosion")
		e.BlastPressure = 0
		e.BlastRadius = math.random(8, 16)
		e.DestroyJointRadiusPercent = 0
		e.ExplosionType = Enum.ExplosionType.NoCraters
		e.Position = pos
		e.Parent = Workspace
	end
	if structDamage then structDamage(pos, 14, 45) end
	if #scorches < 40 then
		local d = math.clamp(size * 2.2, 6, 18)
		local sc = mkPart(Vector3.new(0.1, d, d), CFrame.new(pos.X, pos.Y + 0.1, pos.Z) * CFrame.Angles(0, 0, math.pi / 2), Enum.Material.SmoothPlastic, C(14, 12, 12))
		sc.Shape = Enum.PartType.Cylinder
		sc.Transparency = 0.1
		sc.Parent = fx
		scorches[#scorches + 1] = sc
	end
	local root = getRoot()
	if root then
		local d = (root.Position - pos).Magnitude
		if d < 80 then burst += 0.35 * (1 - d / 80) end
		if d < 16 then blast(15 + 35 * (1 - d / 16), 35, "meteor impact") end
		oneShot(SND.boom, math.clamp(1.3 - d / 250, 0.08, 1.3), 0.85 + math.random() * 0.4, d / 320)
	end
end

local flash -- defined with the GUI
local activeBolts = 0

local function spawnBolt(targeted)
	local root = getRoot()
	if not root or activeBolts >= 4 then return end
	local ang = math.random() * math.pi * 2
	local dist = targeted and math.random(5, 14) or math.random(120, 700)
	local gx = root.Position.X + math.cos(ang) * dist
	local gz = root.Position.Z + math.sin(ang) * dist
	local hit = Workspace:Raycast(Vector3.new(gx, root.Position.Y + 500, gz), Vector3.new(0, -1500, 0), rayP())
	local gy = hit and hit.Position.Y or baseY
	local top = gy + 550 + math.random(0, 150)
	local n = 9
	local pts = {}
	for i = 0, n do
		local t = i / n
		local jx = (i == 0 or i == n) and 0 or (math.random() - 0.5) * 45
		local jz = (i == 0 or i == n) and 0 or (math.random() - 0.5) * 45
		pts[#pts + 1] = Vector3.new(gx + jx, top + (gy - top) * t, gz + jz)
	end
	local col = R[stage].boltCol
	local thick = 1.4 + dist * 0.012
	local made = {}
	for i = 1, n do
		local a, b = pts[i], pts[i + 1]
		local len = (b - a).Magnitude
		local p = mkPart(Vector3.new(thick, thick, len), CFrame.lookAt(a, b) * CFrame.new(0, 0, -len / 2), Enum.Material.Neon, col)
		p.Parent = fx
		made[#made + 1] = p
		tw(p, {Transparency = 1}, 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end
	activeBolts += 1
	task.delay(0.5, function()
		activeBolts -= 1
		for _, p in ipairs(made) do pcall(function() p:Destroy() end) end
	end)
	if flash then flash(math.clamp(0.72 + dist / 800, 0.72, 0.95), 0.4) end
	if dist < 250 then burst += 0.3 end
	-- thunder arrives later the farther the strike is
	oneShot(SND.boom, math.clamp(1.7 - dist / 450, 0.25, 1.7), 0.5 + math.random() * 0.2, dist / 180)
	if dist < 22 then blast(45, 45, "lightning strike") end
end

local function spawnFissure()
	local root = getRoot()
	if not root or #fissures >= 24 then return end
	local ang, dist = math.random() * math.pi * 2, math.random(15, 160)
	local x = root.Position.X + math.cos(ang) * dist
	local z = root.Position.Z + math.sin(ang) * dist
	local hit = Workspace:Raycast(Vector3.new(x, root.Position.Y + 200, z), Vector3.new(0, -500, 0), rayP())
	if not hit then return end
	local hot = R[stage].crackHot
	local p = mkPart(Vector3.new(math.random(15, 50) / 10, 0.15, math.random(40, 140)),
		CFrame.new(hit.Position + Vector3.new(0, 0.12, 0)) * CFrame.Angles(0, math.random() * 6.28, 0),
		hot and Enum.Material.Neon or Enum.Material.SmoothPlastic, hot and C(255, 90, 15) or C(18, 16, 16))
	p.Transparency = 1
	p.Parent = fx
	tw(p, {Transparency = 0.05}, 0.6)
	fissures[#fissures + 1] = p
end

--------------------------------------------------------------------
-- FIRES
--------------------------------------------------------------------
local fireList = {}
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.MaxParts = 200

local function clearFire(n)
	for _ = 1, math.min(n, #fireList) do
		local pair = table.remove(fireList)
		pcall(function() pair[1]:Destroy() pair[2]:Destroy() end)
	end
end

local function fireStep()
	for i = #fireList, 1, -1 do
		if not fireList[i][1].Parent then table.remove(fireList, i) end
	end
	if #fireList > 0 and math.random() < 0.5 then
		oneShot(SND.pop, 0.2 + math.random() * 0.15, 0.6 + math.random() * 0.5, 0)
	end
	if not CONFIG.Fires or fireTarget <= 0 then
		clearFire(6)
		return
	end
	if #fireList >= fireTarget then return end
	local root = getRoot()
	if not root then return end
	overlap.FilterDescendantsInstances = {lp.Character, fx, buildFolder, mineFolder}
	local parts = Workspace:GetPartBoundsInRadius(root.Position, 170, overlap)
	if #parts == 0 then return end
	for _ = 1, 3 do
		local p = parts[math.random(#parts)]
		if p and not p:IsA("Terrain") and p.Size.Magnitude > 2 and not p:FindFirstChildOfClass("Fire") then
			local f = Instance.new("Fire")
			f.Size = math.clamp(p.Size.Magnitude * 0.4, 6, 16)
			f.Heat = 12
			f.Color = C(255, 140, 30)
			f.SecondaryColor = C(180, 40, 0)
			f.Parent = p
			local s = Instance.new("Smoke")
			s.Size = 14
			s.Opacity = 0.5
			s.RiseVelocity = 8
			s.Color = C(30, 25, 25)
			s.Parent = p
			fireList[#fireList + 1] = {f, s}
		end
	end
end

--------------------------------------------------------------------
-- FLOATING + RATTLING OBJECTS (local visual copies)
--------------------------------------------------------------------
local floaters, picked = {}, {}
local KEEP = {SpecialMesh = true, BlockMesh = true, SurfaceAppearance = true, Decal = true, Texture = true}

local function releaseFloater(f)
	pcall(function() f.orig.LocalTransparencyModifier = 0 end)
	picked[f.orig] = nil
	pcall(function() f.clone:Destroy() end)
end

local function dropFloater(f)
	picked[f.orig] = nil
	pcall(function() f.clone:Destroy() end)
end

local function pickFloaters(count, rattleOnly)
	local root = getRoot()
	if not root then return end
	overlap.FilterDescendantsInstances = {lp.Character, fx, buildFolder, mineFolder}
	local parts = Workspace:GetPartBoundsInRadius(root.Position, 140, overlap)
	if #parts == 0 then return end
	local floor = Workspace:Raycast(root.Position, Vector3.new(0, -8, 0), rayP())
	local floorPart = floor and floor.Instance
	for _ = 1, count do
		local p = parts[math.random(#parts)]
		if p and not picked[p] and p ~= floorPart and not p:IsA("Terrain") then
			local mag = p.Size.Magnitude
			local sizeOk
			if rattleOnly then
				sizeOk = (not p.Anchored and mag >= 1.5 and mag <= 40)
					or (CONFIG.RattleAnchored and p.Anchored and mag >= 1.5 and mag <= 12)
			else
				sizeOk = mag >= 3 and mag <= 32
			end
			local model = p:FindFirstAncestorOfClass("Model")
			if sizeOk and p.Transparency < 0.9 and not (model and model:FindFirstChildOfClass("Humanoid")) then
				local ok, cl = pcall(function() return p:Clone() end)
				if ok and cl then
					for _, ch in ipairs(cl:GetChildren()) do
						if not KEEP[ch.ClassName] then ch:Destroy() end
					end
					cl.Anchored = true
					cl.CanCollide = false
					cl.CanQuery = false
					cl.CanTouch = false
					cl.Parent = fx
					p.LocalTransparencyModifier = 1
					picked[p] = true
					local cf = p.CFrame
					floaters[#floaters + 1] = {clone = cl, orig = p, pos = cf.Position, home = cf.Position.Y, rot = cf - cf.Position,
						vel = Vector3.zero, launched = false, phase = math.random() * 6.28, size = mag,
						ang = Vector3.new((math.random() - 0.5) * 2, (math.random() - 0.5) * 2, (math.random() - 0.5) * 2)}
				end
			end
		end
	end
end

local function rattleOffset(f, amp, t)
	if amp < 0.015 then return Vector3.zero, CFrame.new() end
	local k = math.clamp(8 / math.max(f.size, 1), 0.5, 2)
	local ph = f.phase * 7
	local fr = 30 + amp * 25
	local s = math.min(amp * 1.2 * k, 1.6)
	local off = Vector3.new(
		math.noise(t * fr + ph, 1.1, 0) * 2 * s,
		math.abs(math.noise(t * fr + ph, 2.2, 0)) * 2 * s,
		math.noise(t * fr + ph, 3.3, 0) * 2 * s)
	if amp > 0.4 then
		off += Vector3.new(0, math.max(0, math.noise(t * 9 + ph, 4.4, 0)) * 2 * amp * k, 0)
	end
	local tilt = math.min(amp * 0.09 * k, 0.18)
	local rot = CFrame.Angles(
		math.noise(t * fr + ph, 5.5, 0) * 2 * tilt,
		math.noise(t * fr + ph, 6.6, 0) * 2 * tilt,
		math.noise(t * fr + ph, 7.7, 0) * 2 * tilt)
	return off, rot
end

local function floaterStep(dt, t)
	local fv = CONFIG.Floating and N.float.Value or 0
	local amp = CONFIG.Rattle and (N.quake.Value + burst * 0.6) or 0
	local root = getRoot()
	local rp = root and root.Position or startPos
	local moonFlat = Vector3.new(moonDir.X, 0, moonDir.Z).Unit
	for i = #floaters, 1, -1 do
		local f = floaters[i]
		if not f.clone.Parent then
			table.remove(floaters, i)
		elseif not f.launched and not f.orig.Parent then
			table.remove(floaters, i)
			dropFloater(f)
		else
			if fv >= 0.7 then f.launched = true end
			if f.launched then
				if fv >= 0.3 then
					f.vel += (Vector3.new(0, 12 + fv * 14, 0) + wd * windMag * 0.5 + moonFlat * 6) * dt
				else
					f.vel += (Vector3.new(0, -ORIGGRAV, 0) + wd * windMag * 0.2) * dt
				end
				f.pos += f.vel * dt
				local sp = 0.6 + f.vel.Magnitude * 0.01
				f.rot = CFrame.Angles(f.ang.X * dt * sp, f.ang.Y * dt * sp, f.ang.Z * dt * sp) * f.rot
				f.clone.CFrame = CFrame.new(f.pos) * f.rot
				-- flying debris hurts
				if f.vel.Magnitude > 25 and (f.pos - rp).Magnitude < f.size * 0.5 + 4 and os.clock() - (f.hitT or 0) > 1.5 then
					f.hitT = os.clock()
					hurt(6 + f.size * 0.2, "flying debris", true)
				end
				if fv < 0.3 and f.pos.Y <= f.home then
					table.remove(floaters, i)
					releaseFloater(f)
				elseif f.pos.Y > baseY + 1200 or (f.pos - rp).Magnitude > 1500 then
					table.remove(floaters, i)
					dropFloater(f)
				end
			else
				local oc = f.orig.CFrame
				f.home = oc.Y
				local target = oc.Y + fv * fv * 45 + math.sin(t * 1.7 + f.phase) * 0.5 * fv
				local y = f.pos.Y + (target - f.pos.Y) * math.min(1, dt * 1.5)
				f.pos = Vector3.new(oc.X, y, oc.Z)
				if fv > 0.02 then
					local k = dt * 0.3 * fv
					f.rot = CFrame.Angles(f.ang.X * k, f.ang.Y * k, f.ang.Z * k) * f.rot
				else
					f.rot = oc - oc.Position
				end
				local off, jr = rattleOffset(f, amp, t)
				f.clone.CFrame = CFrame.new(f.pos + off) * jr * f.rot
				if fv < 0.02 and amp < 0.012 and math.abs(f.pos.Y - oc.Y) < 0.3 then
					table.remove(floaters, i)
					releaseFloater(f)
				end
			end
		end
	end
end

--------------------------------------------------------------------
-- TSUNAMIS
--------------------------------------------------------------------
local tsunamis = {}
local tsuNear, tsuSurface = 99999, nil

local function spawnTsunami(h)
	if not CONFIG.Tsunamis or not running then return end
	local ang = math.random() * math.pi * 2
	local dir = Vector3.new(-math.cos(ang), 0, -math.sin(ang))
	local start = Vector3.new(startPos.X + math.cos(ang) * 1800, baseY, startPos.Z + math.sin(ang) * 1800)
	local width = 2200
	local col = waterColV.Value
	local wall = mkPart(Vector3.new(width, h, 60), CFrame.new(), Enum.Material.SmoothPlastic, col)
	wall.Transparency = 0.22
	wall.Reflectance = 0.15
	local back = mkPart(Vector3.new(width, h * 0.45, 900), CFrame.new(), Enum.Material.SmoothPlastic, col)
	back.Transparency = 0.4
	local foam = mkPart(Vector3.new(width, 6, 90), CFrame.new(), Enum.Material.Neon, C(235, 245, 255))
	foam.Transparency = 0.1
	emitter(foam, {Texture = SMOKE, Color = ColorSequence.new(C(240, 248, 255)), Size = NumberSequence.new(14),
		Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1)}),
		Lifetime = NumberRange.new(2, 3), Speed = NumberRange.new(20, 40), SpreadAngle = Vector2.new(40, 40), Rate = 350})
	wall.Parent, back.Parent, foam.Parent = fx, fx, fx
	tsunamis[#tsunamis + 1] = {wall = wall, back = back, foam = foam, dir = dir, right = dir:Cross(Vector3.yAxis),
		start = start, d = 0, speed = 85, h = h, width = width, hit = false}
	if toast then toast("TSUNAMI APPROACHING - get " .. h .. "+ studs above the ground (ramps + pallets)", C(120, 200, 255), 5) end
	oneShot(SND.boom, 1, 0.2, 0)
end

local function tsunamiStep(dt)
	tsuNear, tsuSurface = 99999, nil
	local tsuShakeT = 0
	local root = getRoot()
	local rp = root and root.Position or startPos
	for i = #tsunamis, 1, -1 do
		local w = tsunamis[i]
		w.d += w.speed * dt
		local front = w.start + w.dir * w.d
		local function place(part, center)
			part.CFrame = CFrame.lookAt(center, center + w.dir)
		end
		place(w.wall, front + Vector3.new(0, w.h / 2 - 2, 0))
		place(w.foam, front + Vector3.new(0, w.h - 1, 0) - w.dir * 10)
		place(w.back, front - w.dir * 480 + Vector3.new(0, w.h * 0.225 - 2, 0))
        if onWave then onWave(w, front) end
		local rel = Vector3.new(rp.X - front.X, 0, rp.Z - front.Z)
		local along = rel:Dot(w.dir)
		local lateral = math.abs(rel:Dot(w.right))
		tsuNear = math.min(tsuNear, math.abs(along))
		if math.abs(along) < 300 then
			tsuShakeT = math.max(tsuShakeT, (1 - math.abs(along) / 300) * (((rp.Y - 3 - baseY) > w.h + 2) and 0.15 or 0.7))
		end
		local heightRel = rp.Y - 3 - baseY
		if lateral < w.width / 2 then
			if not w.hit and along > -30 and along < 30 and heightRel < w.h * 0.85 then
				w.hit = true
				surge = math.max(surge, w.h * 0.3)
				burst += 2
				if flash then flash(0.35, 1.5) end
				oneShot(SND.boom, 2, 0.3, 0)
				blast(math.min(30, 5 + w.h * 0.3), 45, "tsunami")
				if root then root:ApplyImpulse(w.dir * root.AssemblyMass * 50) end
			end
			if along > -930 and along < 30 and heightRel < w.h * 0.45 - 1 then
				tsuSurface = baseY + w.h * 0.45
				if root then
					local v = root.AssemblyLinearVelocity
					local tv = w.dir * w.speed * 0.85
					local k = math.min(1, dt * 2.5)
					root.AssemblyLinearVelocity = Vector3.new(v.X + (tv.X - v.X) * k, v.Y, v.Z + (tv.Z - v.Z) * k)
				end
				hurt(3 * dt, "tsunami debris")
			end
		end
		if w.d > 3900 then
			for _, p in ipairs({w.wall, w.back, w.foam}) do pcall(function() p:Destroy() end) end
			table.remove(tsunamis, i)
		end
	end
	tsuShake = tsuShake + (tsuShakeT - tsuShake) * math.min(1, dt * 4)
end

--------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "MoonDoomUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 999
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
local okParent = pcall(function() gui.Parent = (gethui and gethui()) or game:GetService("CoreGui") end)
if not okParent or not gui.Parent then gui.Parent = lp:WaitForChild("PlayerGui") end
track(gui)

local function mk(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end

local underOverlay = mk("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = C(30, 80, 130), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 1}, gui)
local dmgFrame = mk("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = C(200, 20, 20), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2}, gui)
local flashFrame = mk("Frame", {Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 2}, gui)

flash = function(startAlpha, dur)
	flashFrame.BackgroundTransparency = startAlpha
	tw(flashFrame, {BackgroundTransparency = 1}, dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

local function stageColor(i)
	return Color3.fromHSV(0.33 * (1 - (i - 1) / (NSTAGES - 1)), 0.75, 1)
end

local banner = mk("TextLabel", {Size = UDim2.new(1, 0, 0, 70), Position = UDim2.new(0, 0, 0.28, 0), BackgroundTransparency = 1,
	Text = "", Font = Enum.Font.GothamBlack, TextSize = 44, TextColor3 = Color3.new(1, 1, 1), TextTransparency = 1,
	TextStrokeTransparency = 1, ZIndex = 4}, gui)
local bannerToken = 0
local function showBanner(i)
	bannerToken += 1
	local t = bannerToken
	banner.Text = STAGES[i].label
	banner.TextColor3 = stageColor(i)
	banner.TextTransparency = 0
	banner.TextStrokeTransparency = 0.4
	task.delay(2.2, function()
		if running and t == bannerToken then tw(banner, {TextTransparency = 1, TextStrokeTransparency = 1}, 2.5) end
	end)
end

local toastL = mk("TextLabel", {Size = UDim2.new(1, 0, 0, 40), Position = UDim2.new(0, 0, 0.16, 0), BackgroundTransparency = 1,
	Text = "", Font = Enum.Font.GothamBold, TextSize = 20, TextColor3 = Color3.new(1, 1, 1), TextTransparency = 1,
	TextStrokeTransparency = 1, TextWrapped = true, ZIndex = 4}, gui)
local toastToken = 0
toast = function(text, col, dur)
	toastToken += 1
	local t = toastToken
	toastL.Text = text
	toastL.TextColor3 = col or Color3.new(1, 1, 1)
	toastL.TextTransparency = 0
	toastL.TextStrokeTransparency = 0.3
	task.delay(dur or 4, function()
		if running and t == toastToken then tw(toastL, {TextTransparency = 1, TextStrokeTransparency = 1}, 1.5) end
	end)
end

local PANEL_W = 340
local panel = mk("Frame", {AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.new(0, PANEL_W, 0, 76),
	BackgroundColor3 = C(12, 12, 18), BackgroundTransparency = 0.2, BorderSizePixel = 0, ZIndex = 5, Visible = CONFIG.ShowPanel}, gui)
mk("UICorner", {CornerRadius = UDim.new(0, 8)}, panel)
mk("UIStroke", {Color = C(80, 80, 100), Transparency = 0.5}, panel)

local title = mk("TextButton", {Position = UDim2.new(0, 10, 0, 5), Size = UDim2.new(1, -125, 0, 20), BackgroundTransparency = 1, AutoButtonColor = false,
	Font = Enum.Font.GothamBlack, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, Text = "", ZIndex = 6}, panel)
local nameL = mk("TextLabel", {Position = UDim2.new(0, 10, 0, 25), Size = UDim2.new(1, -20, 0, 16), BackgroundTransparency = 1,
	Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C(235, 235, 240), TextXAlignment = Enum.TextXAlignment.Left, Text = "", ZIndex = 6}, panel)
local barBg = mk("Frame", {Position = UDim2.new(0, 10, 0, 45), Size = UDim2.new(1, -20, 0, 6), BackgroundColor3 = C(45, 45, 55), BorderSizePixel = 0, ZIndex = 6}, panel)
mk("UICorner", {CornerRadius = UDim.new(1, 0)}, barBg)
local barFill = mk("Frame", {Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C(255, 80, 60), BorderSizePixel = 0, ZIndex = 7}, barBg)
mk("UICorner", {CornerRadius = UDim.new(1, 0)}, barFill)
local timerL = mk("TextLabel", {Position = UDim2.new(0, 10, 0, 54), Size = UDim2.new(1, -20, 0, 14), BackgroundTransparency = 1,
	Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C(170, 170, 185), TextXAlignment = Enum.TextXAlignment.Left, Text = "", ZIndex = 6}, panel)
local details = mk("TextLabel", {Position = UDim2.new(0, 10, 0, 74), Size = UDim2.new(1, -20, 0, 100), BackgroundTransparency = 1,
	Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = C(215, 215, 225), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top, Text = "", ZIndex = 6}, panel)

-- survival HUD (left side, above the thumbstick area)
local hud = mk("TextLabel", {Position = UDim2.new(0, 8, 0.32, 0), Size = UDim2.new(0, 235, 0, 96), BackgroundColor3 = C(10, 10, 14), BackgroundTransparency = 0.45,
	Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C(235, 235, 240), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
	TextYAlignment = Enum.TextYAlignment.Top, Text = "", BorderSizePixel = 0, ZIndex = 6}, gui)
mk("UICorner", {CornerRadius = UDim.new(0, 6)}, hud)
mk("UIPadding", {PaddingLeft = UDim.new(0, 8), PaddingTop = UDim.new(0, 6), PaddingRight = UDim.new(0, 6)}, hud)
local errL = mk("TextLabel", {AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -8), Size = UDim2.new(0, 420, 0, 60),
	BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C(255, 120, 110), TextWrapped = true,
	TextStrokeTransparency = 0.5, Text = "", ZIndex = 9}, gui)
errSink = function(msg) errL.Text = "SCRIPT ERROR (screenshot this): " .. msg end

local function refreshPanel()
	local d = STAGES[stage]
	title.Text = d.label .. "  " .. (expanded and "-" or "+")
	title.TextColor3 = stageColor(stage)
	nameL.Text = d.name
	details.Text = "EVENT: " .. d.ev .. "\nEFFECTS: " .. d.ef .. "\nPREP: " .. d.tip
	local h = TextService:GetTextSize(details.Text, 12, Enum.Font.Gotham, Vector2.new(PANEL_W - 20, 10000)).Y
	details.Size = UDim2.new(1, -20, 0, h)
	details.Visible = expanded
	panel.Size = UDim2.new(0, PANEL_W, 0, expanded and (74 + h + 10) or 76)
end
connect(title.Activated, function() expanded = not expanded refreshPanel() end)

local btnRow = mk("Frame", {Position = UDim2.new(1, -112, 0, 4), Size = UDim2.new(0, 104, 0, 22), BackgroundTransparency = 1, ZIndex = 6}, panel)
mk("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), HorizontalAlignment = Enum.HorizontalAlignment.Right}, btnRow)
local function btn(txt, cb)
	local b = mk("TextButton", {Size = UDim2.new(0, 24, 1, 0), BackgroundColor3 = C(40, 40, 52), BorderSizePixel = 0, Text = txt,
		Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = Color3.new(1, 1, 1), ZIndex = 7}, btnRow)
	mk("UICorner", {CornerRadius = UDim.new(0, 5)}, b)
	connect(b.Activated, cb)
	return b
end

--------------------------------------------------------------------
-- SURVIVAL: trees -> wood -> pallets -> shelter  (+ extra world details)
--------------------------------------------------------------------
local wood, pallets = 0, 0
local stone, slabs, buildMat, hasPick = 0, 0, "Wood", false
local SCOL = C(130, 130, 136)
local trees, pieces, pieceKeys = {}, {}, {}
local treeFolder = Instance.new("Folder")
treeFolder.Name = "DoomTrees"
treeFolder.Parent = fx
local PCOL = C(150, 105, 60)
local lastBurnMsg = 0

local function setTree(rec, rot)
	for _, p in ipairs(rec.parts) do p.part.CFrame = rec.baseCF * rot * p.rel end
end

local function chopTree(rec)
	if rec.felled then return end
	rec.felled = true
	for i, r in ipairs(trees) do
		if r == rec then table.remove(trees, i) break end
	end
	local gain = math.random(3, 4)
	wood += gain
	toast("+" .. gain .. " wood  (total " .. wood .. ")", C(215, 170, 110), 1.8)
	oneShot(SND.pop, 0.8, 0.45, 0)
	pcall(function() rec.prompt:Destroy() end)
	for _, p in ipairs(rec.parts) do p.part.CanCollide = false end
	local axis = Vector3.yAxis:Cross(Vector3.new(math.cos(rec.phase), 0, math.sin(rec.phase)))
	task.spawn(function()
		local t0 = os.clock()
		while running and os.clock() - t0 < 1.3 do
			local k = math.min(1, (os.clock() - t0) / 1.2)
			setTree(rec, CFrame.fromAxisAngle(axis, k * k * (math.pi / 2)))
			task.wait()
		end
		pcall(function() rec.model:Destroy() end)
	end)
end

local function makeTree(x, z)
	local hit = Workspace:Raycast(Vector3.new(x, baseY + 300, z), Vector3.new(0, -800, 0), rayP())
	if not hit then return false end
	local inst = hit.Instance
	if not (inst:IsA("Terrain") or (inst.Size.X >= 60 and inst.Size.Z >= 60)) then return false end
	local surf = surfaceY()
	if surf and hit.Position.Y < surf then return false end
	local gy = hit.Position.Y
	local h = math.random(18, 30)
	local model = Instance.new("Model")
	model.Name = "DoomTree"
	local baseCF = CFrame.new(x, gy, z)
	local parts = {}
	local function add(part, rel)
		part.Parent = model
		parts[#parts + 1] = {part = part, rel = rel}
		part.CFrame = baseCF * rel
	end
	local trunk = mkPart(Vector3.new(h, 2.4, 2.4), CFrame.new(), Enum.Material.Wood, C(105, 72, 42))
	trunk.Shape = Enum.PartType.Cylinder
	trunk.CanCollide = true
	add(trunk, CFrame.new(0, h / 2, 0) * CFrame.Angles(0, 0, math.pi / 2))
	for k = 1, 3 do
		local d = math.random(12, 17) * (1.1 - k * 0.15)
		local leaf = sphere(mkPart(Vector3.new(d, d * 0.8, d), CFrame.new(), Enum.Material.Grass,
			C(math.random(40, 60), math.random(100, 125), math.random(40, 55))))
		add(leaf, CFrame.new(math.random(-2, 2), h - 2 + k * 3.2, math.random(-2, 2)))
	end
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = "Chop tree"
	pp.ObjectText = "Tree"
	pp.HoldDuration = 1.2
	pp.MaxActivationDistance = 12
	pp.RequiresLineOfSight = false
	pp.Parent = trunk
	model.Parent = treeFolder
	local rec = {model = model, parts = parts, baseCF = baseCF, phase = math.random() * 6.28, prompt = pp}
	pp.Triggered:Connect(function() chopTree(rec) end)
	trees[#trees + 1] = rec
	return true
end

local function spawnTrees(n)
	local root = getRoot()
	for _ = 1, n do
		local around = (math.random() < 0.5 or not root) and startPos or root.Position
		local ang, dist = math.random() * math.pi * 2, math.random(25, 340)
		makeTree(around.X + math.cos(ang) * dist, around.Z + math.sin(ang) * dist)
	end
end

local function chopNearest()
	local root = getRoot()
	if not root then return end
	local best, bd = nil, 15
	for _, rec in ipairs(trees) do
		local d = (rec.baseCF.Position - root.Position).Magnitude
		if d < bd then best, bd = rec, d end
	end
	if best then chopTree(best) else toast("No tree within reach - walk up to one", C(255, 200, 120), 2) end
end

local function burnTrees()
	for _, rec in ipairs(trees) do
		pcall(function()
			local f = Instance.new("Fire")
			f.Size = 14
			f.Heat = 15
			f.Parent = rec.parts[1].part
			rec.prompt:Destroy()
		end)
		task.delay(4 + math.random() * 5, function() pcall(function() rec.model:Destroy() end) end)
	end
	trees = {}
end

-- crafting + building -------------------------------------------------
local function craftPallet()
	if wood < 2 then
		toast("A pallet needs 2 wood - chop trees first", C(255, 200, 120), 2.5)
		return
	end
	wood -= 2
	pallets += 1
	oneShot(SND.pop, 0.7, 0.8, 0)
	toast("Crafted a wooden pallet  (pallets: " .. pallets .. ")", C(215, 170, 110), 1.8)
end

local PIECES = {"Wall", "Floor", "Roof", "Ramp"}
local pieceIdx, bLevel, buildOn = 1, 0, false
local GR = 8

local function placement()
	local root = getRoot()
	if not root then return nil end
	local p = root.Position
	local lk = root.CFrame.LookVector
	local look = Vector3.new(lk.X, 0, lk.Z)
	if look.Magnitude < 0.05 then look = Vector3.new(0, 0, -1) end
	look = look.Unit
	local cx = math.floor(p.X / GR) * GR + GR / 2
	local cz = math.floor(p.Z / GR) * GR + GR / 2
	local alongX = math.abs(look.X) >= math.abs(look.Z)
	local sx = alongX and (look.X > 0 and 1 or -1) or 0
	local sz = (not alongX) and (look.Z > 0 and 1 or -1) or 0
	local y0 = baseY + bLevel * GR
	local kind = PIECES[pieceIdx]
	local res = {kind = kind, ok = true}
	if kind == "Wall" then
		if alongX then
			res.cf = CFrame.new(cx + sx * GR / 2, y0 + GR / 2, cz)
			res.size = Vector3.new(0.8, GR, GR + 0.8)
		else
			res.cf = CFrame.new(cx, y0 + GR / 2, cz + sz * GR / 2)
			res.size = Vector3.new(GR + 0.8, GR, 0.8)
		end
		res.key = ("Wall|%d|%d|%d|%d|%d"):format(cx, cz, bLevel, sx, sz)
	elseif kind == "Floor" then
		res.cf = CFrame.new(cx, y0 + 0.25, cz)
		res.size = Vector3.new(GR, 0.5, GR)
		res.key = ("Floor|%d|%d|%d"):format(cx, cz, bLevel)
	elseif kind == "Roof" then
		local b = ("Roof|%d|%d|%d"):format(cx, cz, bLevel)
		local s = 0
		while s < 4 and pieceKeys[b .. "|" .. s] do s += 1 end
		res.cf = CFrame.new(cx, y0 + GR + 0.25 + s * 1.0, cz)
		res.size = Vector3.new(GR + 0.4, 0.5, GR + 0.4)
		res.key = b .. "|" .. s
		if s >= 4 then res.ok = false res.why = "Roof is already 4 layers thick" end
	else
		local d = alongX and Vector3.new(sx, 0, 0) or Vector3.new(0, 0, sz)
		local center = Vector3.new(cx, y0 + GR / 2, cz) + d * (GR / 2 + 6)
		res.cf = CFrame.lookAt(center, center + d * 12 + Vector3.new(0, GR, 0))
		res.size = Vector3.new(GR, 0.5, math.sqrt(144 + GR * GR))
		res.key = ("Ramp|%d|%d|%d|%d|%d"):format(cx, cz, bLevel, sx, sz)
	end
	if res.ok and pieceKeys[res.key] then res.ok = false res.why = "Something is already built there" end
	return res
end

local function hurtPiece(i, dmg)
	local r = pieces[i]
	if not r then return end
	r.hp -= dmg
	if r.hp <= 0 then
		table.remove(pieces, i)
		pieceKeys[r.key] = nil
		pcall(function() r.part:Destroy() end)
		if os.clock() - lastBurnMsg > 6 then
			lastBurnMsg = os.clock()
			toast("A shelter piece was destroyed - repair it with pallets!", C(255, 150, 110), 3)
		end
	else
		r.part.Color = ((r.mat == "Stone") and SCOL or PCOL):Lerp(C(25, 20, 18), 1 - r.hp / (r.maxhp or 100))
	end
end

local function placePiece()
	local pl = placement()
	if not pl then return end
	if not pl.ok then toast(pl.why, C(255, 150, 120), 1.8) return end
	if buildMat == "Stone" then
		if slabs < 1 then toast("No stone slabs - craft one first (3 stone)", C(255, 200, 120), 2) return end
		slabs -= 1
	else
		if pallets < 1 then toast("No pallets - craft one first (2 wood)", C(255, 200, 120), 2) return end
		pallets -= 1
	end
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = true
	p.CanQuery = true
	p.CanTouch = false
	p.Material = (buildMat == "Stone") and Enum.Material.Cobblestone or Enum.Material.WoodPlanks
	p.Color = (buildMat == "Stone") and SCOL or PCOL
	p.Size = pl.size
	p.CFrame = pl.cf
	p.Parent = buildFolder
	local maxhp = (buildMat == "Stone") and 320 or 100
	local rec = {part = p, hp = maxhp, maxhp = maxhp, mat = buildMat, kind = pl.kind, key = pl.key}
	pieces[#pieces + 1] = rec
	pieceKeys[pl.key] = rec
	oneShot(SND.pop, 0.9, 0.55, 0)
end

local function removeNearest()
	local root = getRoot()
	if not root then return end
	local best, bd = nil, 16
	for i, r in ipairs(pieces) do
		local d = (r.part.Position - root.Position).Magnitude
		if d < bd then best, bd = i, d end
	end
	if not best then toast("No built piece within reach", C(255, 200, 120), 1.8) return end
	local r = table.remove(pieces, best)
	pieceKeys[r.key] = nil
	pcall(function() r.part:Destroy() end)
	if r.mat == "Stone" then slabs += 1 else pallets += 1 end
end

structDamage = function(pos, radius, dmg)
	for i = #pieces, 1, -1 do
		local r = pieces[i]
		if not pos or (r.part.Position - pos).Magnitude <= radius then hurtPiece(i, dmg) end
	end
end

onWave = function(w, front)
	for i = #pieces, 1, -1 do
		local r = pieces[i]
		w.hitPieces = w.hitPieces or {}
		if not w.hitPieces[r] then
			local rel = r.part.Position - front
			local flat = Vector3.new(rel.X, 0, rel.Z)
			if flat:Dot(w.dir) > -30 and flat:Dot(w.dir) < 30 and math.abs(flat:Dot(w.right)) < w.width / 2
				and r.part.Position.Y < baseY + w.h * 0.7 then
				w.hitPieces[r] = true
				hurtPiece(i, 45)
			end
		end
	end
end

-- fire, acid and impacts slowly destroy exposed wood (top roof layers first)
local WEAR = {[12] = 0.35, [13] = 0.5, [14] = 0.8, [15] = 0.8, [16] = 3.0, [17] = 0.6, [18] = 0.8, [19] = 1.5}
local function wearTick()
	local rate = WEAR[stage] or 0
	if rate <= 0 or #pieces == 0 then return end
	local rpar = rayP()
	for i = #pieces, 1, -1 do
		local r = pieces[i]
		if r then
			local top = r.part.Position + Vector3.new(0, r.part.Size.Y / 2 + 0.2, 0)
			local exposed = not Workspace:Raycast(top, Vector3.new(0, 200, 0), rpar)
			local k = (exposed and 1 or 0.12) * (r.kind == "Wall" and 0.5 or 1) * ((r.mat == "Stone") and 0.15 or 1) * (0.7 + math.random() * 0.6)
			hurtPiece(i, rate * k)
		end
	end
end

-- UI: wood / pallets / build menu (right side) ---------------------------
local craftFrame = mk("ScrollingFrame", {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0.18, 0), Size = UDim2.new(0, 160, 0.62, 0),
	CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4,
	BackgroundColor3 = C(10, 10, 14), BackgroundTransparency = 0.4, BorderSizePixel = 0, ZIndex = 6}, gui)
mk("UICorner", {CornerRadius = UDim.new(0, 6)}, craftFrame)
mk("UIPadding", {PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6)}, craftFrame)
mk("UIListLayout", {Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder}, craftFrame)
local invL = mk("TextLabel", {Size = UDim2.new(1, -8, 0, 62), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12,
	TextColor3 = C(235, 200, 150), TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "", ZIndex = 7, LayoutOrder = 1}, craftFrame)
local function sbtn(text, order, cb)
	local b = mk("TextButton", {Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = C(58, 44, 30), BorderSizePixel = 0, Text = text,
		Font = Enum.Font.GothamMedium, TextSize = 11, TextColor3 = Color3.new(1, 1, 1), ZIndex = 7, LayoutOrder = order}, craftFrame)
	mk("UICorner", {CornerRadius = UDim.new(0, 5)}, b)
	connect(b.Activated, cb)
	return b
end
sbtn("CHOP NEAREST TREE", 2, chopNearest)
sbtn("CRAFT PALLET (2 wood)", 3, craftPallet)
local modeBtn, pieceBtn
modeBtn = sbtn("BUILD MODE: OFF", 4, function()
	buildOn = not buildOn
	modeBtn.Text = "BUILD MODE: " .. (buildOn and "ON" or "OFF")
end)
pieceBtn = sbtn("PIECE: Wall", 5, function()
	pieceIdx = pieceIdx % #PIECES + 1
	pieceBtn.Text = "PIECE: " .. PIECES[pieceIdx]
end)
local lvlRow = mk("Frame", {Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, ZIndex = 7, LayoutOrder = 6}, craftFrame)
mk("UIListLayout", {FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4)}, lvlRow)
local function lbtn(text, cb)
	local b = mk("TextButton", {Size = UDim2.new(0.5, -2, 1, 0), BackgroundColor3 = C(58, 44, 30), BorderSizePixel = 0, Text = text,
		Font = Enum.Font.GothamMedium, TextSize = 11, TextColor3 = Color3.new(1, 1, 1), ZIndex = 7}, lvlRow)
	mk("UICorner", {CornerRadius = UDim.new(0, 5)}, b)
	connect(b.Activated, cb)
end
lbtn("LEVEL -", function() bLevel = math.max(0, bLevel - 1) end)
lbtn("LEVEL +", function() bLevel = math.min(8, bLevel + 1) end)
sbtn("PLACE PIECE (1 pallet)", 7, placePiece)
sbtn("REMOVE NEAREST (+1 pallet)", 8, removeNearest)

local ghost = mkPart(Vector3.new(8, 8, 1), CFrame.new(0, -500, 0), Enum.Material.Neon, C(80, 255, 120))
ghost.Transparency = 1
ghost.Parent = fx

-- emergency broadcasts ----------------------------------------------------
local ALERT = {
	"Normal conditions. Moon visible, clear skies.",
	"Astronomers report the Moon's orbit is drifting. Officials call it a measurement error.",
	"Hurricane watch for every coast. Tides are two meters above normal.",
	"Superstorms active. Evacuate the coasts. Collect wood, water and supplies.",
	"Tsunami warning. Seek high ground and build elevated shelters.",
	"TSUNAMI WARNING: waves incoming. Get above the wave height!",
	"Coastlines are gone. Floods are permanent. Stay on high ground.",
	"Magnitude 8 quakes everywhere and volcanoes erupting. Cover your airways.",
	"The Moon is breaking apart. Take shelter under thick roofs.",
	"A ring is forming. Debris will fall. Layer your roof.",
	"Meteors across the sky. Do not go outside.",
	"Firestorms burning. Wooden shelters are catching fire - repair them.",
	"Oxygen levels collapsing. Use your reserve sparingly.",
	"IMPACT IMMINENT. Seal your shelter. Roof layers matter.",
	"Shockwaves circling the globe.",
	"Molten rain. Only thick, sealed shelters survive.",
	"Total darkness. Stay sealed in.",
	"Surface cooling. Steam storms rage.",
	"Acid rain. Keep your roof intact.",
	"Skies clearing. If you hear this, you survived.",
}
local alertL = mk("TextLabel", {AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -76), Size = UDim2.new(0, 440, 0, 36),
	BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C(255, 205, 110), TextWrapped = true,
	TextStrokeTransparency = 0.4, TextTransparency = 1, Text = "", ZIndex = 8}, gui)
local alertTok = 0
local function showAlert(text)
	if not text then return end
	alertTok += 1
	local tk = alertTok
	alertL.Text = "EMERGENCY BROADCAST: " .. text
	alertL.TextTransparency = 0
	alertL.TextStrokeTransparency = 0.4
	task.delay(9, function()
		if running and tk == alertTok then tw(alertL, {TextTransparency = 1, TextStrokeTransparency = 1}, 1.5) end
	end)
end

onStage = function(i, instant)
	showAlert(ALERT[i])
	if i >= IMPACT then
		if i == IMPACT and not instant then task.delay(11, burnTrees) else burnTrees() end
	end
end

-- extra details: birds fleeing, failing power grid, rain splashes, quake dust --------
local birds = {}
local function spawnFlock()
	local root = getRoot()
	if not root then return end
	local a = math.random() * math.pi * 2
	local dir = Vector3.new(math.cos(a), 0, math.sin(a))
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local center = Vector3.new(root.Position.X, baseY + math.random(70, 130), root.Position.Z) - dir * 450 + side * math.random(-150, 150)
	for _ = 1, 10 do
		local wl = mkPart(Vector3.new(2.6, 0.12, 0.9), CFrame.new(), Enum.Material.SmoothPlastic, C(20, 20, 24))
		local wr = mkPart(Vector3.new(2.6, 0.12, 0.9), CFrame.new(), Enum.Material.SmoothPlastic, C(20, 20, 24))
		wl.Parent, wr.Parent = fx, fx
		birds[#birds + 1] = {l = wl, r = wr, dir = dir, speed = 22 + math.random() * 10, ph = math.random() * 6, t = 0,
			pos = center + Vector3.new(math.random(-30, 30), math.random(-10, 10), math.random(-30, 30))}
	end
end

local lightRecs, lightCount = {}, 0
local function scanLights()
	local root = getRoot()
	if not root then return end
	overlap.FilterDescendantsInstances = {lp.Character, fx, buildFolder, mineFolder}
	local parts = Workspace:GetPartBoundsInRadius(root.Position, 220, overlap)
	for _, part in ipairs(parts) do
		for _, ch in ipairs(part:GetChildren()) do
			if lightCount < 80 and ch:IsA("Light") and not lightRecs[ch] then
				lightRecs[ch] = {on = ch.Enabled}
				lightCount += 1
			end
		end
	end
end

local splashPart = mkPart(Vector3.new(70, 0.2, 70), CFrame.new())
splashPart.Transparency = 1
splashPart.Parent = fx
local splashE = emitter(splashPart, {Texture = SPARK, Color = ColorSequence.new(C(220, 235, 255)),
	Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1.5)}),
	Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1)}),
	Lifetime = NumberRange.new(0.25, 0.4), Speed = NumberRange.new(2, 5), SpreadAngle = Vector2.new(70, 70), LightEmission = 0.3})
local puffPart = mkPart(Vector3.new(30, 0.2, 30), CFrame.new())
puffPart.Transparency = 1
puffPart.Parent = fx
local puffE = emitter(puffPart, {Texture = SMOKE, Color = ColorSequence.new(C(135, 115, 95)),
	Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 9)}),
	Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1)}),
	Lifetime = NumberRange.new(1.5, 2.5), Speed = NumberRange.new(8, 14), SpreadAngle = Vector2.new(80, 80)})

local treeAcc, swayAcc, wearAcc, birdAcc, lightAcc, scanAcc, hudAcc = 0, 0, 0, 0, 0, 0, 0
local lastBurst, finalT, surviveShown = 0, 0, false

local function survivalStep(dt)
	local t = os.clock()
	local root = getRoot()
	local rp = root and root.Position or startPos

	-- trees keep sprouting until the core impact, then they burn
	treeAcc += dt
	if treeAcc > 2.2 then
		treeAcc = 0
		if stage < IMPACT and #trees < 60 then spawnTrees(2) end
	end

	-- trees bend and sway in the wind
	swayAcc += dt
	if swayAcc > 0.066 then
		swayAcc = 0
		local lean = math.clamp(windMag / 220, 0, 0.35)
		local sway = math.clamp(windMag / 400, 0.005, 0.06)
		local axis = Vector3.yAxis:Cross(wd)
		for _, rec in ipairs(trees) do
			if not rec.felled then
				local dx, dz = rec.baseCF.Position.X - rp.X, rec.baseCF.Position.Z - rp.Z
				if dx * dx + dz * dz < 90000 then
					setTree(rec, CFrame.fromAxisAngle(axis, lean + math.sin(t * 1.4 + rec.phase) * sway))
				end
			end
		end
	end

	-- fire / acid / impacts wear down exposed wood
	wearAcc += dt
	if wearAcc > 1 then wearAcc = 0 wearTick() end

	-- placement preview
	if buildOn then
		local pl = placement()
		if pl then
			ghost.Size = pl.size
			ghost.CFrame = pl.cf
			ghost.Color = (pl.ok and ((buildMat == "Stone" and slabs or pallets) > 0)) and C(80, 255, 120) or C(255, 80, 80)
			ghost.Transparency = 0.55
		end
	else
		ghost.Transparency = 1
	end

	-- birds flee before the disaster
	birdAcc += dt
	if birdAcc > 7 then
		birdAcc = 0
		if stage >= 2 and stage <= 9 and #birds < 20 then spawnFlock() end
	end
	for i = #birds, 1, -1 do
		local b = birds[i]
		b.t += dt
		b.pos += b.dir * b.speed * dt
		local flap = math.sin(b.t * 10 + b.ph) * 0.7
		local base = CFrame.lookAt(b.pos, b.pos + b.dir)
		b.l.CFrame = base * CFrame.new(-1.3, 0, 0) * CFrame.Angles(0, 0, flap)
		b.r.CFrame = base * CFrame.new(1.3, 0, 0) * CFrame.Angles(0, 0, -flap)
		if (b.pos - rp).Magnitude > 900 then
			pcall(function() b.l:Destroy() b.r:Destroy() end)
			table.remove(birds, i)
		end
	end

	-- the power grid fails: nearby lights flicker and die from Day 3 on
	scanAcc += dt
	if scanAcc > 5 then scanAcc = 0 scanLights() end
	lightAcc += dt
	if lightAcc > 0.15 then
		lightAcc = 0
		local b = math.clamp((stage - 8) / 3, 0, 1)
		for l, rec in pairs(lightRecs) do
			if l.Parent then
				l.Enabled = rec.on and (b <= 0 or math.random() > b * 0.92)
			else
				lightRecs[l] = nil
				lightCount -= 1
			end
		end
	end

	-- rain splashes at your feet, dust puffs when the ground shakes
	splashPart.CFrame = CFrame.new(rp.X, rp.Y - 3, rp.Z)
	puffPart.CFrame = CFrame.new(rp.X, rp.Y - 3, rp.Z)
	splashE.Rate = 0
	if burst - lastBurst > 0.35 and N.quake.Value > 0.25 then puffE:Emit(math.floor(15 + burst * 10)) end
	lastBurst = burst

	-- inventory text
	hudAcc += dt
	if hudAcc > 0.25 then
		hudAcc = 0
		invL.Text = ("WOOD %d   STONE %d\nPALLETS %d   SLABS %d\n%s %s   LVL %d (%d studs)%s"):format(wood, stone, pallets, slabs, string.upper(buildMat), PIECES[pieceIdx], bLevel, bLevel * GR, hasPick and "\nPICKAXE READY" or "")
	end

	-- the end
	if stage == NSTAGES then
		finalT += dt
		local hum = getHum()
		if finalT > 12 and not surviveShown and hum and hum.Health > 0 then
			surviveShown = true
			toast("YOU SURVIVED THE END OF THE WORLD", C(120, 255, 150), 8)
		end
	else
		finalT = 0
	end
end

connect(RunService.Heartbeat, function(dt)
	local ok, e = pcall(survivalStep, dt)
	if not ok then report("survival", e) end
end)

survivalCleanup = function()
	for l, rec in pairs(lightRecs) do pcall(function() l.Enabled = rec.on end) end
	if restoreMined then pcall(restoreMined) end
end

if stage < IMPACT then spawnTrees(14) end
task.delay(2, function()
	if running then toast("SURVIVE: chop trees, craft pallets + a pickaxe, mine stone, build walls + 3 roof layers. Height beats tsunamis.", C(230, 200, 150), 9) end
end)

--------------------------------------------------------------------
-- MINING, EARTHQUAKE CRACKS + LAVA, COLLAPSING BUILDINGS, 3D RAIN
--------------------------------------------------------------------
local function __part3()

local CELL = 4
local minedOrig, minedTerrain = {}, {}
local lastMine = 0
local debrisCount = 0
local collapsedModels = {}
local DEB_CAP = 260
local lavaWarned = false

local ROCKY = {}
for _, n in ipairs({"Rock", "Slate", "Basalt", "Limestone", "Granite", "Sandstone", "Concrete", "Brick", "Cobblestone", "Marble", "Pavement", "Asphalt", "CrackedLava", "Salt", "Pebble"}) do
	local ok, m = pcall(function() return Enum.Material[n] end)
	if ok and m then ROCKY[m] = true end
end

local function yieldFor(mat)
	if mat == Enum.Material.Wood or mat == Enum.Material.WoodPlanks then return "wood", math.random(1, 2) end
	if ROCKY[mat] then return "stone", 2 end
	return "stone", 1
end

-- "breaking" a block hides the real part on your screen only (restored when you stop the script)
local function hideOrig(inst)
	if inst.Parent == mineFolder then
		pcall(function() inst:Destroy() end)
		return
	end
	if not minedOrig[inst] then minedOrig[inst] = {cc = inst.CanCollide, cq = inst.CanQuery} end
	inst.LocalTransparencyModifier = 1
	inst.CanCollide = false
	inst.CanQuery = false
end

local function cellOf(inst, pt)
	local mx = inst.Size / 2
	local l = inst.CFrame:PointToObjectSpace(pt)
	local function ax(v, m)
		local mn = -m
		local i = math.floor((v - mn) / CELL)
		return math.max(mn + i * CELL, mn), math.min(mn + (i + 1) * CELL, m)
	end
	local x0, x1 = ax(l.X, mx.X)
	local y0, y1 = ax(l.Y, mx.Y)
	local z0, z1 = ax(l.Z, mx.Z)
	return x0, x1, y0, y1, z0, z1, mx
end

local function makePiece(src, mn, mx)
	local sz = mx - mn
	if sz.X < 0.05 or sz.Y < 0.05 or sz.Z < 0.05 then return nil end
	local ok, cl = pcall(function() return src:Clone() end)
	if not ok or not cl then return false end
	for _, ch in ipairs(cl:GetChildren()) do
		if not KEEP[ch.ClassName] then ch:Destroy() end
	end
	cl.Anchored = true
	cl.CanCollide = true
	cl.CanQuery = true
	cl.CanTouch = false
	cl.LocalTransparencyModifier = 0
	cl.Size = sz
	cl.CFrame = src.CFrame * CFrame.new((mn + mx) / 2)
	cl.Parent = mineFolder
	return cl
end

-- cut ONE 4x4x4 block out of a plain block part (the rest of the part stays)
local function carve(inst, res)
	local x0, x1, y0, y1, z0, z1, mx = cellOf(inst, res.Position - res.Normal * 0.3)
	if x1 - x0 < 0.01 or y1 - y0 < 0.01 or z1 - z0 < 0.01 then return false end
	local boxes = {}
	local function add(a, b, c, d, e, f) boxes[#boxes + 1] = {Vector3.new(a, b, c), Vector3.new(d, e, f)} end
	if x0 > -mx.X then add(-mx.X, -mx.Y, -mx.Z, x0, mx.Y, mx.Z) end
	if x1 < mx.X then add(x1, -mx.Y, -mx.Z, mx.X, mx.Y, mx.Z) end
	if y0 > -mx.Y then add(x0, -mx.Y, -mx.Z, x1, y0, mx.Z) end
	if y1 < mx.Y then add(x0, y1, -mx.Z, x1, mx.Y, mx.Z) end
	if z0 > -mx.Z then add(x0, y0, -mx.Z, x1, y1, z0) end
	if z1 < mx.Z then add(x0, y0, z1, x1, y1, mx.Z) end
	local made = {}
	for _, b in ipairs(boxes) do
		local cl = makePiece(inst, b[1], b[2])
		if cl == false then
			for _, m in ipairs(made) do pcall(function() m:Destroy() end) end
			return false
		end
		if cl then made[#made + 1] = cl end
	end
	hideOrig(inst)
	return true
end

local function mineTerrain(res)
	if not Terrain then return false end
	local p = res.Position - res.Normal * 2
	local c = Vector3.new(math.floor(p.X / CELL) * CELL + CELL / 2, math.floor(p.Y / CELL) * CELL + CELL / 2, math.floor(p.Z / CELL) * CELL + CELL / 2)
	local ok = pcall(function() Terrain:FillBlock(CFrame.new(c), Vector3.new(CELL, CELL, CELL), Enum.Material.Air) end)
	if ok and #minedTerrain < 600 then minedTerrain[#minedTerrain + 1] = {c = c, mat = res.Material} end
	return ok
end

local function mineRay()
	local cam = Workspace.CurrentCamera
	local root = getRoot()
	if not cam or not root then return nil end
	local vs = cam.ViewportSize
	local ray = cam:ViewportPointToRay(vs.X / 2, vs.Y / 2)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = {lp.Character, fx}
	rp.IgnoreWater = true
	local res = Workspace:Raycast(ray.Origin, ray.Direction * 80, rp)
	if res and (res.Position - root.Position).Magnitude <= 14 then return res end
	return nil
end

local function mineFx(pos)
	local p = mkPart(Vector3.new(1, 1, 1), CFrame.new(pos))
	p.Transparency = 1
	p.Parent = fx
	local e = emitter(p, {Texture = SMOKE, Color = ColorSequence.new(C(150, 140, 130)),
		Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1.6)}),
		Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1)}),
		Lifetime = NumberRange.new(0.5, 1), Speed = NumberRange.new(6, 12), SpreadAngle = Vector2.new(80, 80)})
	e:Emit(14)
	task.delay(1.5, function() pcall(function() p:Destroy() end) end)
end

local function mineBlock()
	if not CONFIG.Mining then return end
	if not hasPick then toast("Craft a pickaxe first (4 wood)", C(255, 200, 120), 2) return end
	if os.clock() - lastMine < 0.35 then return end
	lastMine = os.clock()
	local res = mineRay()
	if not res then toast("Nothing in reach - aim the dot at a block (14 studs max)", C(255, 200, 120), 1.5) return end
	local inst = res.Instance
	local mat = res.Material
	local model = inst:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then return end
	if inst:IsA("Terrain") then
		if not mineTerrain(res) then return end
	elseif inst.Parent == buildFolder then
		for i, r in ipairs(pieces) do
			if r.part == inst then
				table.remove(pieces, i)
				pieceKeys[r.key] = nil
				pcall(function() inst:Destroy() end)
				if r.mat == "Stone" then slabs += 1 else pallets += 1 end
				toast("Deconstructed - piece refunded", C(215, 170, 110), 1.5)
				oneShot(SND.pop, 0.8, 0.5, 0)
				break
			end
		end
		return
	else
		local plain = inst:IsA("Part") and inst.Shape == Enum.PartType.Block and not inst:FindFirstChildOfClass("SpecialMesh")
		if not (plain and carve(inst, res)) then hideOrig(inst) end
	end
	local kind, n = yieldFor(mat)
	if kind == "wood" then wood += n else stone += n end
	toast("+" .. n .. " " .. kind, kind == "wood" and C(215, 170, 110) or C(190, 190, 200), 1.2)
	oneShot(SND.pop, 0.9, 0.5, 0)
	mineFx(res.Position)
end

local function giveTool()
	local bp = lp:FindFirstChildOfClass("Backpack")
	if not bp then return end
	if bp:FindFirstChild("Pickaxe") or (lp.Character and lp.Character:FindFirstChild("Pickaxe")) then return end
	local tool = Instance.new("Tool")
	tool.Name = "Pickaxe"
	tool.ToolTip = "Tap / click to mine the block you aim at"
	tool.RequiresHandle = true
	tool.CanBeDropped = false
	tool.GripPos = Vector3.new(0, -1.4, 0)
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.5, 3.6, 0.5)
	handle.Material = Enum.Material.Wood
	handle.Color = C(120, 85, 50)
	handle.CanCollide = false
	handle.Parent = tool
	local head = Instance.new("Part")
	head.Size = Vector3.new(3.2, 0.7, 0.7)
	head.Material = Enum.Material.Metal
	head.Color = C(145, 150, 158)
	head.CanCollide = false
	head.Massless = true
	head.Parent = tool
	local wl = Instance.new("Weld")
	wl.Part0 = handle
	wl.Part1 = head
	wl.C0 = CFrame.new(0, 1.6, 0)
	wl.Parent = handle
	connect(tool.Activated, mineBlock)
	tool.Parent = bp
	track(tool)
end

local function craftPickaxe()
	if not CONFIG.Mining then return end
	if hasPick then toast("You already have a pickaxe", C(255, 200, 120), 1.5) return end
	if wood < 4 then toast("A pickaxe needs 4 wood", C(255, 200, 120), 2) return end
	wood -= 4
	hasPick = true
	giveTool()
	oneShot(SND.pop, 0.8, 0.7, 0)
	toast("Pickaxe crafted! Aim the dot at a block and press MINE (or use the tool)", C(215, 170, 110), 4)
end

local function craftSlab()
	if stone < 3 then toast("A stone slab needs 3 stone - mine some", C(255, 200, 120), 2) return end
	stone -= 3
	slabs += 1
	oneShot(SND.pop, 0.8, 0.6, 0)
	toast("Crafted a stone slab  (slabs: " .. slabs .. ")", C(190, 190, 200), 1.8)
end

connect(lp.CharacterAdded, function()
	task.wait(1)
	if running and hasPick then giveTool() end
end)

local matBtn
sbtn("CRAFT STONE SLAB (3 stone)", 9, craftSlab)
matBtn = sbtn("MATERIAL: WOOD", 10, function()
	buildMat = (buildMat == "Wood") and "Stone" or "Wood"
	matBtn.Text = "MATERIAL: " .. string.upper(buildMat)
end)
sbtn("CRAFT PICKAXE (4 wood)", 11, craftPickaxe)
sbtn("MINE (aim at a block)", 12, mineBlock)

local mineGhost = mkPart(Vector3.new(4, 4, 4), CFrame.new(0, -500, 0), Enum.Material.Neon, C(255, 255, 255))
mineGhost.Transparency = 1
mineGhost.Parent = fx
local cross = mk("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0), Size = UDim2.new(0, 6, 0, 6),
	BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 9}, gui)
mk("UICorner", {CornerRadius = UDim.new(1, 0)}, cross)
mk("UIStroke", {Color = Color3.new(0, 0, 0), Thickness = 1}, cross)

local function updateMineGhost()
	if not hasPick or not CONFIG.Mining then
		mineGhost.Transparency = 1
		cross.Visible = false
		return
	end
	cross.Visible = true
	local res = mineRay()
	if not res then mineGhost.Transparency = 1 return end
	local inst = res.Instance
	mineGhost.Transparency = 0.7
	if inst:IsA("Terrain") then
		local p = res.Position - res.Normal * 2
		local c = Vector3.new(math.floor(p.X / CELL) * CELL + CELL / 2, math.floor(p.Y / CELL) * CELL + CELL / 2, math.floor(p.Z / CELL) * CELL + CELL / 2)
		mineGhost.Size = Vector3.new(CELL + 0.1, CELL + 0.1, CELL + 0.1)
		mineGhost.CFrame = CFrame.new(c)
	elseif inst:IsA("Part") and inst.Shape == Enum.PartType.Block and inst.Parent ~= buildFolder and not inst:FindFirstChildOfClass("SpecialMesh") then
		local x0, x1, y0, y1, z0, z1 = cellOf(inst, res.Position - res.Normal * 0.3)
		mineGhost.Size = Vector3.new(math.max(0.06, x1 - x0 + 0.06), math.max(0.06, y1 - y0 + 0.06), math.max(0.06, z1 - z0 + 0.06))
		mineGhost.CFrame = inst.CFrame * CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
	elseif inst.Size.Magnitude < 40 then
		mineGhost.Size = inst.Size + Vector3.new(0.06, 0.06, 0.06)
		mineGhost.CFrame = inst.CFrame
	else
		mineGhost.Size = Vector3.new(CELL, CELL, CELL)
		mineGhost.CFrame = CFrame.new(res.Position - res.Normal * 1)
	end
end

-- earthquake cracks (some open up to lava) ------------------------------
local cracks2 = {}
local function growCrack(lava)
	local root = getRoot()
	if not root then return end
	if #cracks2 >= 22 then
		local old = table.remove(cracks2, 1)
		for _, p in ipairs(old.parts) do pcall(function() p:Destroy() end) end
	end
	local ang, dist = math.random() * math.pi * 2, math.random(12, 150)
	local pos = Vector3.new(root.Position.X + math.cos(ang) * dist, 0, root.Position.Z + math.sin(ang) * dist)
	local heading = math.random() * math.pi * 2
	local w = math.random(20, 50) / 10
	local rec = {parts = {}, lava = lava, segs = {}}
	local rpar = rayP()
	local topY = root.Position.Y + 60
	for s = 1, math.random(4, 7) do
		local len = math.random(14, 30)
		local nxt = pos + Vector3.new(math.cos(heading) * len, 0, math.sin(heading) * len)
		local h1 = Workspace:Raycast(Vector3.new(pos.X, topY, pos.Z), Vector3.new(0, -200, 0), rpar)
		local h2 = Workspace:Raycast(Vector3.new(nxt.X, topY, nxt.Z), Vector3.new(0, -200, 0), rpar)
		if not (h1 and h2) then break end
		local a = Vector3.new(pos.X, h1.Position.Y + 0.1, pos.Z)
		local b = Vector3.new(nxt.X, h2.Position.Y + 0.1, nxt.Z)
		local seglen = (b - a).Magnitude
		if seglen < 1 then break end
		local cf = CFrame.lookAt(a, b) * CFrame.new(0, 0, -seglen / 2)
		local dark = mkPart(Vector3.new(0.2, 0.12, seglen + 1.2), cf, Enum.Material.SmoothPlastic, C(12, 10, 10))
		dark.Parent = fx
		tw(dark, {Size = Vector3.new(w * 1.5, 0.12, seglen + 1.2)}, 2.2)
		rec.parts[#rec.parts + 1] = dark
		if lava then
			local glow = mkPart(Vector3.new(0.1, 0.14, seglen + 0.8), cf * CFrame.new(0, 0.03, 0), Enum.Material.Neon, C(255, 90, 10))
			glow.Transparency = 0.1
			glow.Parent = fx
			tw(glow, {Size = Vector3.new(w, 0.14, seglen + 0.8)}, 3.2)
			rec.parts[#rec.parts + 1] = glow
			if s == 2 then
				local pl = Instance.new("PointLight")
				pl.Color = C(255, 120, 40)
				pl.Range = 30
				pl.Brightness = 3
				pl.Parent = glow
				emitter(glow, {Texture = SPARK, Color = ColorSequence.new(C(255, 160, 60), C(255, 60, 0)), Size = NumberSequence.new(0.7),
					LightEmission = 1, Lifetime = NumberRange.new(1, 2), Speed = NumberRange.new(4, 9), SpreadAngle = Vector2.new(30, 30), Rate = 8})
			end
		end
		rec.segs[#rec.segs + 1] = {a = a, b = b, w = w}
		pos = nxt
		heading = heading + math.rad(math.random(-35, 35))
	end
	if #rec.parts == 0 then return end
	cracks2[#cracks2 + 1] = rec
	oneShot(SND.boom, 1, 0.3, 0)
end

local function distSeg(p, a, b)
	local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local ap = Vector3.new(p.X - a.X, 0, p.Z - a.Z)
	local l2 = ab:Dot(ab)
	local t = l2 > 0 and math.clamp(ap:Dot(ab) / l2, 0, 1) or 0
	local c = Vector3.new(a.X + ab.X * t, 0, a.Z + ab.Z * t)
	return (Vector3.new(p.X, 0, p.Z) - c).Magnitude
end

local function lavaTick(step)
	local root = getRoot()
	if not root then return end
	local foot = root.Position.Y - 3
	for _, c in ipairs(cracks2) do
		if c.lava then
			for _, s in ipairs(c.segs) do
				local dy = foot - s.a.Y
				if dy < 4 and dy > -6 and distSeg(root.Position, s.a, s.b) < s.w * 0.75 + 1.2 then
					hurt(20 * step, "lava", true)
					if not lavaWarned then
						lavaWarned = true
						toast("LAVA! Get off the crack!", C(255, 110, 40), 2.5)
					end
					return
				end
			end
		end
	end
end

-- collapsing buildings ---------------------------------------------------
local function collapseParts(list, root)
	if debrisCount + #list > DEB_CAP then return false end
	local recs = {}
	local minV, maxV = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9)
	for _, p in ipairs(list) do
		if p.Size.Magnitude <= 150 and p.Transparency < 0.95 then
			local ok, cl = pcall(function() return p:Clone() end)
			if ok and cl then
				for _, ch in ipairs(cl:GetChildren()) do
					if not KEEP[ch.ClassName] then ch:Destroy() end
				end
				cl.Anchored = true
				cl.CanCollide = true
				cl.CanQuery = true
				cl.CanTouch = false
				cl.LocalTransparencyModifier = 0
				cl.Parent = mineFolder
				hideOrig(p)
				recs[#recs + 1] = {part = cl, cf = cl.CFrame}
				minV = minV:Min(p.Position - p.Size / 2)
				maxV = maxV:Max(p.Position + p.Size / 2)
			end
		end
	end
	if #recs == 0 then return false end
	debrisCount += #recs
	local center = (minV + maxV) / 2
	task.spawn(function()
		local t0 = os.clock()
		while running and os.clock() - t0 < 1.6 do
			local now = os.clock()
			local k = (now - t0) / 1.6
			for _, r in ipairs(recs) do
				if r.part.Parent then
					local j = Vector3.new(math.noise(now * 30, r.cf.X * 0.1, 1), math.noise(now * 31, r.cf.Y * 0.1, 2) * 0.5, math.noise(now * 29, r.cf.Z * 0.1, 3)) * (0.3 + k * 1.4)
					r.part.CFrame = r.cf * CFrame.new(j) * CFrame.Angles(j.Z * 0.01, 0, j.X * 0.01)
				end
			end
			task.wait()
		end
		for _, r in ipairs(recs) do
			if r.part.Parent then
				local out = r.cf.Position - center
				out = Vector3.new(out.X, 0, out.Z)
				local dv = out.Magnitude > 0.1 and out.Unit or Vector3.xAxis
				r.part.Anchored = false
				r.part.AssemblyLinearVelocity = dv * math.random(3, 12) + Vector3.new(0, math.random(0, 4), 0)
				r.part.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 3
			end
		end
		task.delay(40, function()
			for _, r in ipairs(recs) do
				if r.part.Parent then r.part.Anchored = true end
			end
		end)
	end)
	local rp = root.Position
	if rp.X > minV.X - 4 and rp.X < maxV.X + 4 and rp.Z > minV.Z - 4 and rp.Z < maxV.Z + 4 and rp.Y < maxV.Y + 2 then
		blast(40, 35, "collapsing building")
	end
	local dust = mkPart(Vector3.new(math.max(4, maxV.X - minV.X), 1, math.max(4, maxV.Z - minV.Z)), CFrame.new(center.X, minV.Y, center.Z))
	dust.Transparency = 1
	dust.Parent = fx
	local de = emitter(dust, {Texture = SMOKE, Color = ColorSequence.new(C(140, 125, 108)),
		Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 6), NumberSequenceKeypoint.new(1, 22)}),
		Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1)}),
		Lifetime = NumberRange.new(3, 5), Speed = NumberRange.new(10, 25), SpreadAngle = Vector2.new(70, 70)})
	de:Emit(120)
	task.delay(7, function() pcall(function() dust:Destroy() end) end)
	oneShot(SND.boom, 2.2, 0.25, (rp - center).Magnitude / 300)
	toast("A BUILDING IS COLLAPSING!", C(255, 170, 90), 3)
	return true
end

local function topBuilding(part)
	local best
	local cur = part
	while cur and cur ~= Workspace do
		if cur:IsA("Model") then
			local ok, ext = pcall(function() return cur:GetExtentsSize() end)
			if ok and ext.X <= 120 and ext.Z <= 120 and ext.Y <= 170 then best = cur else break end
		end
		cur = cur.Parent
	end
	return best
end

local function collapseBuilding()
	if not CONFIG.Collapse then return false end
	local root = getRoot()
	if not root then return false end
	overlap.FilterDescendantsInstances = {lp.Character, fx, buildFolder, mineFolder}
	local parts = Workspace:GetPartBoundsInRadius(root.Position, 320, overlap)
	local cand, seen = {}, {}
	for _, part in ipairs(parts) do
		if not part:IsA("Terrain") and not minedOrig[part] and not picked[part] then
			local m = topBuilding(part)
			if m then
				if not seen[m] and not collapsedModels[m] and not m:FindFirstChildOfClass("Humanoid") then
					seen[m] = true
					local ok, ext = pcall(function() return m:GetExtentsSize() end)
					if ok and ext.Y >= 8 then cand[#cand + 1] = {model = m} end
				end
			elseif part.Size.Y >= 12 and part.Size.X <= 45 and part.Size.Z <= 45 and not seen[part] then
				seen[part] = true
				cand[#cand + 1] = {single = part}
			end
		end
	end
	if #cand == 0 then return false end
	local pickc = cand[math.random(#cand)]
	local list = {}
	if pickc.model then
		collapsedModels[pickc.model] = true
		for _, d in ipairs(pickc.model:GetDescendants()) do
			if d:IsA("BasePart") and not d:IsA("Terrain") and not minedOrig[d] then list[#list + 1] = d end
		end
	else
		list[1] = pickc.single
	end
	if #list == 0 or #list > 120 then return false end
	return collapseParts(list, root)
end

local lastMajor = 0
majorShock = function()
	local q = N.quake.Value
	if q < 0.6 or os.clock() - lastMajor < 8 then return end
	lastMajor = os.clock()
	if CONFIG.Fissures then
		local lavaChance = R[stage].crackHot and 1 or ((q >= 0.9) and 0.35 or ((q >= 0.7) and 0.15 or 0.05))
		for _ = 1, (q >= 0.8) and math.random(2, 3) or 1 do
			growCrack(math.random() < lavaChance)
		end
	end
	if q >= 0.8 then
		if math.random() < 0.5 then collapseBuilding() end
		if structDamage then structDamage(nil, nil, 8) end
	end
end

-- 3D rain: rain clouds, puddles, splash rings (the falling drops are 3D teardrops) ---
local clouds = {}
for i = 1, 12 do
	local c = {x = (math.random() - 0.5) * 1300, z = (math.random() - 0.5) * 1300, y = 170 + math.random() * 60, parts = {}}
	for k = 1, 4 do
		local d = math.random(60, 110)
		local p = sphere(mkPart(Vector3.new(d, d * 0.45, d), CFrame.new(), Enum.Material.SmoothPlastic, C(70, 72, 80)))
		p.Transparency = 1
		p.Parent = fx
		c.parts[k] = {part = p, ox = (math.random() - 0.5) * 90, oz = (math.random() - 0.5) * 90, oy = (math.random() - 0.5) * 14}
	end
	clouds[i] = c
end

local function updateClouds(dt, rp)
	local cover = math.clamp(N.rain.Value / 150 + N.acid.Value / 200 + N.hurr.Value * 0.5 + N.ash.Value / 120, 0, 1)
	local tr = 1 - 0.8 * cover
	local col = hurrColV.Value:Lerp(C(120, 122, 130), 0.45)
	for _, c in ipairs(clouds) do
		c.x += wd.X * windMag * 0.5 * dt
		c.z += wd.Z * windMag * 0.5 * dt
		local dx, dz = c.x - rp.X, c.z - rp.Z
		if dx > 650 then c.x -= 1300 elseif dx < -650 then c.x += 1300 end
		if dz > 650 then c.z -= 1300 elseif dz < -650 then c.z += 1300 end
		for _, q in ipairs(c.parts) do
			q.part.Transparency = tr
			q.part.Color = col
			q.part.CFrame = CFrame.new(c.x + q.ox, rp.Y + c.y + q.oy, c.z + q.oz)
		end
	end
end

local puddles = {}
local function spawnPuddle(rp)
	local ang, d = math.random() * math.pi * 2, math.random(4, 55)
	local x, z = rp.X + math.cos(ang) * d, rp.Z + math.sin(ang) * d
	local hit = Workspace:Raycast(Vector3.new(x, rp.Y + 10, z), Vector3.new(0, -60, 0), rayP())
	if not hit or hit.Normal.Y < 0.92 then return end
	local r = math.random(30, 80) / 10
	local p = mkPart(Vector3.new(0.05, 0.1, 0.1), CFrame.new(hit.Position + Vector3.new(0, 0.07, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.Material.Glass, C(80, 105, 130))
	p.Shape = Enum.PartType.Cylinder
	p.Reflectance = 0.45
	p.Transparency = 0.35
	p.Parent = fx
	tw(p, {Size = Vector3.new(0.05, r * 2, r * 2)}, 5)
	puddles[#puddles + 1] = {part = p}
end

local function spawnSplash(rp)
	local ang, d = math.random() * math.pi * 2, math.random(2, 26)
	local x, z = rp.X + math.cos(ang) * d, rp.Z + math.sin(ang) * d
	local hit = Workspace:Raycast(Vector3.new(x, rp.Y + 6, z), Vector3.new(0, -40, 0), rayP())
	if not hit then return end
	local p = mkPart(Vector3.new(0.04, 0.5, 0.5), CFrame.new(hit.Position + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Enum.Material.Neon, rainColLast or C(210, 225, 245))
	p.Shape = Enum.PartType.Cylinder
	p.Transparency = 0.3
	p.Parent = fx
	tw(p, {Size = Vector3.new(0.04, 2.8, 2.8), Transparency = 1}, 0.45)
	task.delay(0.5, function() pcall(function() p:Destroy() end) end)
end

local accCloud, accPud, accLava, splashAcc = 0, 0, 0, 0
local function extraStep(dt)
	local root = getRoot()
	local rp = root and root.Position or startPos
	updateMineGhost()

	accCloud += dt
	if accCloud > 0.05 then
		updateClouds(accCloud, rp)
		accCloud = 0
	end

	accPud += dt
	if accPud > 1 then
		accPud = 0
		local raining = CONFIG.Storms and (N.rain.Value * (1 - coveredF)) > 40
		if raining then
			if #puddles < 22 then spawnPuddle(rp) spawnPuddle(rp) end
		elseif #puddles > 0 then
			local old = table.remove(puddles, 1)
			tw(old.part, {Transparency = 1}, 3)
			task.delay(3.2, function() pcall(function() old.part:Destroy() end) end)
		end
	end

	if CONFIG.Storms then
		splashAcc = math.min(splashAcc + math.clamp(N.rain.Value * rainMul * (1 - coveredF) * 0.12, 0, 22) * dt, 6)
		while splashAcc >= 1 do
			splashAcc -= 1
			spawnSplash(rp)
		end
	end

	accLava += dt
	if accLava >= 0.2 then
		lavaTick(accLava)
		accLava = 0
	end
end

connect(RunService.Heartbeat, function(dt)
	local ok, e = pcall(extraStep, dt)
	if not ok then report("extras", e) end
end)

restoreMined = function()
	for p, rec in pairs(minedOrig) do
		pcall(function()
			p.LocalTransparencyModifier = 0
			p.CanCollide = rec.cc
			p.CanQuery = rec.cq
		end)
	end
	if Terrain then
		for i = #minedTerrain, 1, -1 do
			local m = minedTerrain[i]
			if m.mat ~= Enum.Material.Water and m.mat ~= Enum.Material.Air then
				pcall(function() Terrain:FillBlock(CFrame.new(m.c), Vector3.new(CELL, CELL, CELL), m.mat) end)
			end
		end
	end
end

end
local ok3, e3 = pcall(__part3)
if not ok3 then report("startup (mining/quakes/rain)", e3) end

--------------------------------------------------------------------
-- APPLY A STAGE (+ the two big scripted sequences)
--------------------------------------------------------------------
local function applyState(s, T)
	tw(Lighting, {Brightness = s.brightness, Ambient = s.ambient, OutdoorAmbient = s.outdoor, ClockTime = s.clock,
		FogColor = s.fogColor, FogStart = s.fogStart, FogEnd = s.fogEnd, ExposureCompensation = s.exposure}, T)
	tw(atm, {Density = s.atmDensity, Offset = s.atmOffset, Color = s.atmColor, Decay = s.atmDecay, Glare = s.atmGlare, Haze = s.atmHaze}, T)
	tw(cc, {Brightness = s.ccBright, Contrast = s.ccContrast, Saturation = s.ccSat, TintColor = s.ccTint}, T)
	tw(bloom, {Intensity = s.bloom}, T)
	tw(blur, {Size = s.blur}, T)
	tw(rays, {Intensity = s.rays}, T)
	for _, k in ipairs(NUM_KEYS) do tw(N[k], {Value = s[k]}, T) end
	tw(moonColV, {Value = s.moonCol}, T)
	tw(waterColV, {Value = s.waterCol}, T)
	tw(hurrColV, {Value = s.hurrCol}, T)
	fireTarget = s.fires
	pulseEvery = s.pulse
	if sky and OSKY then
		sky.CelestialBodiesShown = (s.moonDeg < 2.5) and OSKY.CelestialBodiesShown
		local night = s.clock >= 17 or s.clock <= 5
		sky.StarCount = night and math.max(OSKY.StarCount, 4500) or OSKY.StarCount
	end
end

local function breakupSequence(tok, i)
	local s = R[i]
	applyState(s, CONFIG.TransitionTime)
	tw(N.quake, {Value = 1.5}, 7)
	oneShot(SND.boom, 1.2, 0.25, 1)
	oneShot(SND.boom, 1.5, 0.22, 5)
	task.wait(9)
	if not running or tok ~= token then return end
	-- THE MOON RUPTURES
	local cam = Workspace.CurrentCamera
	local cp = cam and cam.CFrame.Position or startPos
	tw(N.egg, {Value = 0.1}, 0.5)
	tw(N.moonDeg, {Value = 54}, 0.5)
	tw(N.core, {Value = 1}, 0.5)
	tw(moonColV, {Value = C(255, 125, 55)}, 0.5)
	N.chunkT.Value = 0
	spawnDebris()
	shockDisc(cp + moonDir * DIST, cp)
	flash(0.1, 3.5)
	burst += 3.2
	bloom.Intensity = 3
	tw(bloom, {Intensity = s.bloom}, 4)
	oneShot(SND.boom, 3, 0.28, 0)
	oneShot(SND.boom, 2, 0.5, 0.4)
	toast("THE MOON HAS BROKEN APART", C(255, 170, 90), 5)
	tw(N.quake, {Value = s.quake}, 6)
end

local function impactSequence(tok)
	applyState(R[IMPACT - 1], 3)
	task.wait(3)
	if not running or tok ~= token then return end
	tw(N.moonDeg, {Value = 176}, 7, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tw(N.quake, {Value = 1.6}, 7, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tw(N.gravity, {Value = ORIGGRAV * 0.05}, 7)
	tw(N.float, {Value = 1.2}, 7)
	tw(Lighting, {FogEnd = 2200}, 4)
	tw(atm, {Density = 0.45, Color = C(255, 140, 70)}, 4)
	tw(moonColV, {Value = C(255, 95, 35)}, 7)
	oneShot(SND.boom, 1.5, 0.2, 1)
	task.wait(7)
	if not running or tok ~= token then return end
	N.moonDeg.Value = 0
	flash(0, 9)
	burst += 3.5
	applyState(R[IMPACT], 2.5)
	oneShot(SND.boom, 4, 0.18, 0)
	oneShot(SND.boom, 3, 0.3, 0.6)
	blast(55, 110, "core impact shockwave")
    if structDamage then structDamage(nil, nil, 45) end
	toast("CORE IMPACT", C(255, 120, 50), 4)
end

local function applyStage(i, instant)
	token += 1
	local tok = token
	stage = i
	if i < BREAKUP then clearDebris() end
    if onStage then onStage(i, instant) end
	if not instant then showBanner(i) end
	expanded = true
	refreshPanel()
	task.delay(25, function()
		if running and tok == token then expanded = false refreshPanel() end
	end)
	if not instant then
		local tsu = STAGES[i].d.tsu
		if tsu then
			for _, e in ipairs(tsu) do
				task.delay(e.t, function()
					if running and tok == token then spawnTsunami(e.h) end
				end)
			end
		end
	end
	if STAGES[i].breakup and not instant then
		task.spawn(breakupSequence, tok, i)
	elseif STAGES[i].impact and not instant then
		task.spawn(impactSequence, tok)
	else
		applyState(R[i], instant and 0 or CONFIG.TransitionTime)
	end
end

local function goStage(i)
	i = math.clamp(i, 1, NSTAGES)
	elapsed = 0
	applyStage(i, false)
end

local pauseBtn
btn("<", function() goStage(stage - 1) end)
pauseBtn = btn("II", function()
	paused = not paused
	pauseBtn.Text = paused and "|>" or "II"
end)
btn(">", function() goStage(stage + 1) end)

local function Stop()
	if not running then return end
	running = false
	pcall(function() RunService:UnbindFromRenderStep("MoonDoomFX") end)
	for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
	for t in pairs(tweens) do pcall(function() t:Cancel() end) end
	if survivalCleanup then pcall(survivalCleanup) end
	clearFire(#fireList)
	for i = #floaters, 1, -1 do releaseFloater(floaters[i]) end
	for p in pairs(picked) do pcall(function() p.LocalTransparencyModifier = 0 end) end
	-- drain terrain water we added
	if terrainOK and Terrain then
		for k = slabs - 1, 0, -1 do slabFill(k, Enum.Material.Air) end
	end
	if OW and Terrain then
		for k, v in pairs(OW) do pcall(function() Terrain[k] = v end) end
	end
	if sky and OSKY then
		for k, v in pairs(OSKY) do pcall(function() sky[k] = v end) end
	end
	for _, o in ipairs(objs) do pcall(function() o:Destroy() end) end
	for k, v in pairs(ORIG) do pcall(function() Lighting[k] = v end) end
	if not atmCreated then
		for k, v in pairs(OA) do pcall(function() atm[k] = v end) end
	end
	pcall(function() Workspace.Gravity = ORIGGRAV end)
	pcall(function() SoundService.AmbientReverb = ORIGREVERB end)
	pcall(function()
		local hum = getHum()
		if hum then hum.PlatformStand = false end
	end)
	ENV.__MOON_DOOM = nil
end
ENV.__MOON_DOOM = Stop
btn("X", Stop)

connect(lp.CharacterAdded, function()
	oxy = CONFIG.OxygenSeconds
	air = AIRMAX
	deathShown = false
	stumbling = false
	dmgFlash = 0
end)

--------------------------------------------------------------------
-- RAIN + SOUND UPDATE (render step)
--------------------------------------------------------------------
local function updateRain(dt, cp)
	local inten = N.rain.Value * rainMul + N.acid.Value + N.molten.Value * 0.6
	if not CONFIG.Storms then inten = N.acid.Value + N.molten.Value * 0.6 end
	coveredF = coveredF + ((covered and 1 or 0) - coveredF) * math.min(1, dt * 3)
	inten = inten * (1 - 0.88 * coveredF)
	local active = math.clamp(math.floor(inten * 1.5), 0, RAIN_MAX)

	local rr, aa, mm = N.rain.Value, N.acid.Value, N.molten.Value
	local col
	if rr >= aa and rr >= mm then col = C(190, 210, 240)
	elseif aa >= mm then col = C(190, 235, 70)
	else col = C(255, 150, 40) end
	if col ~= rainColLast then
		rainColLast = col
		for i = 1, RAIN_MAX do rainParts[i].Color = col end
	end

	if active > rainShown then
		for i = rainShown + 1, active do
			local d = rainPos[i]
			d.x = cp.X + (math.random() - 0.5) * 110
			d.z = cp.Z + (math.random() - 0.5) * 110
			d.y = cp.Y + math.random() * 70 - 25
			rainParts[i].Transparency = 0.35
		end
	elseif active < rainShown then
		for i = active + 1, rainShown do rainParts[i].Transparency = 1 end
	end
	rainShown = active
	if active == 0 then return end

	local vx, vy, vz = wd.X * windMag * 0.9, -115, wd.Z * windMag * 0.9
	local list, cfs = {}, {}
	for i = 1, active do
		local d = rainPos[i]
		d.x += vx * dt
		d.y += vy * dt
		d.z += vz * dt
		if d.y < cp.Y - 30 or math.abs(d.x - cp.X) > 55 or math.abs(d.z - cp.Z) > 55 then
			d.x = cp.X + (math.random() - 0.5) * 110
			d.z = cp.Z + (math.random() - 0.5) * 110
			d.y = cp.Y + 40 + math.random() * 40
		end
		list[i] = rainParts[i]
		cfs[i] = CFrame.lookAt(Vector3.new(d.x, d.y, d.z), Vector3.new(d.x + vx, d.y + vy, d.z + vz))
	end
	Workspace:BulkMoveTo(list, cfs, Enum.BulkMoveMode.FireNoEvents)
end

local camUnder, lastReverbUnder = false, false

local function updateSounds(dt)
	hushV.Value = N.hush.Value
	local master = CONFIG.Sounds and CONFIG.SoundVolume * (1 - N.hush.Value) * (camUnder and 0.45 or 1) or 0
	local function setVol(s, v)
		s.Volume = s.Volume + (v * master - s.Volume) * math.min(1, dt * 4)
	end
	local q = N.quake.Value + burst
	setVol(rumbleS, math.clamp(q * 0.8, 0, 3))
	rumbleS.PlaybackSpeed = 0.2 + math.min(q, 2) * 0.05
	setVol(rainS, math.clamp((N.rain.Value * rainMul + N.acid.Value) / 260, 0, 1) * 0.8 * (1 - 0.5 * coveredF))
	setVol(windS, math.clamp(windMag / 60, 0, 1.5) * (1 - 0.45 * coveredF))
	windS.PlaybackSpeed = 0.3 + math.clamp(windMag / 300, 0, 0.4)
	setVol(roarS, tsuNear < 1800 and math.clamp((1800 - tsuNear) / 1800, 0, 1) * 2 or 0)
	setVol(droneS, math.clamp((stage - 1) / (NSTAGES - 1), 0, 1) * 0.5)
end

--------------------------------------------------------------------
-- RENDER STEP
--------------------------------------------------------------------
local function renderStep(dt)
	local cam = Workspace.CurrentCamera
	if not cam or not running then return end
	local t = os.clock()

	updateWind(t)
	if CONFIG.LowGravity then Workspace.Gravity = N.gravity.Value end

	-- earthquake / shockwave shake (tiny quakes still show)
	local q = CONFIG.Quakes and (N.quake.Value + burst + tsuShake) or 0
	q = q > 0 and q ^ 0.85 or 0
	burst = burst * math.exp(-dt * 1.1)
	if q > 0.015 then
		cam.CFrame = cam.CFrame
			* CFrame.new(math.noise(t * 23, 1.3, 0) * 2 * q * 0.5, math.noise(t * 27, 7.7, 0) * 2 * q * 0.5, 0)
			* CFrame.Angles(math.noise(t * 19, 5.1, 0) * 2 * q * 0.012, math.noise(t * 21, 9.7, 0) * 2 * q * 0.012, math.noise(t * 17, 3.3, 0) * 2 * q * 0.02)
	end

	local cp = cam.CFrame.Position
	updateMoon(cp, dt)

	if N.ringT.Value < 0.99 then
		ringModel:PivotTo(CFrame.new(cp + Vector3.new(0, -350, 0)) * CFrame.Angles(math.rad(32), 0, math.rad(10)) * CFrame.Angles(0, t * 0.015, 0))
	end
	if CONFIG.Hurricane and N.hurr.Value > 0.02 then
		hurrModel:PivotTo(CFrame.new(H.pos) * CFrame.Angles(0, -t * (0.15 + 0.25 * N.hurr.Value), 0))
	end

	-- water
	local surf = surfaceY()
	if CONFIG.Flood and surf and not terrainOK then
		local rough = 1 + windMag / 30
		water.Transparency = 0.35
		water.Color = waterColV.Value
		water.CFrame = CFrame.new(cp.X, surf - 1 + math.sin(t * 0.9) * 0.35 * rough, cp.Z)
		water2.Transparency = 0.6
		water2.Color = waterColV.Value:Lerp(Color3.new(1, 1, 1), 0.25)
		water2.CFrame = CFrame.new(cp.X, surf - 0.5 + math.sin(t * 1.3 + 1) * 0.3 * rough, cp.Z)
	else
		water.Transparency = 1
		water2.Transparency = 1
	end
	if terrainOK and Terrain then
		Terrain.WaterColor = waterColV.Value
		Terrain.WaterTransparency = 0.45
		Terrain.WaterReflectance = 0.6
		Terrain.WaterWaveSize = math.clamp(0.12 + windMag * 0.012, 0.12, 1)
		Terrain.WaterWaveSpeed = math.clamp(8 + windMag * 0.5, 8, 40)
	end
	local effSurf = math.max(surf or -1e9, tsuSurface or -1e9)
	camUnder = effSurf > -1e8 and cp.Y < effSurf
	if camUnder then
		underOverlay.BackgroundColor3 = waterColV.Value
		underOverlay.BackgroundTransparency = 0.45
		uwBlur.Size = 8
	else
		underOverlay.BackgroundTransparency = 1
		uwBlur.Size = 0
	end
	if camUnder ~= lastReverbUnder then
		lastReverbUnder = camUnder
		pcall(function() SoundService.AmbientReverb = camUnder and Enum.ReverbType.UnderWater or ORIGREVERB end)
	end

	-- weather
	weather.CFrame = CFrame.new(cp + Vector3.new(0, 55, 0))
	ashE.Rate = N.ash.Value
	emberE.Rate = N.ember.Value
	moltenE.Rate = N.molten.Value * 0.5
	ashE.Acceleration = Vector3.new(wd.X * windMag * 0.4, -2, wd.Z * windMag * 0.4)
	dustPart.CFrame = CFrame.new(cp.X, cp.Y - 2, cp.Z)
	dustE.Rate = CONFIG.Wind and math.clamp(windMag * 2.5, 0, 160) or 0
	dustE.Acceleration = wd * windMag * 0.8
	updateRain(dt, cp)

	updateSounds(dt)

	-- damage flash
	dmgFlash = math.max(0, dmgFlash - dt * 1.4)
	dmgFrame.BackgroundTransparency = 1 - math.min(dmgFlash, 1) * 0.55
end
RunService:BindToRenderStep("MoonDoomFX", Enum.RenderPriority.Camera.Value + 1, function(dt)
	local ok, e = pcall(renderStep, dt)
	if not ok then report("render", e) end
end)

--------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------
local function fmt(sec)
	sec = math.max(0, math.floor(sec))
	return ("%d:%02d"):format(sec // 60, sec % 60)
end

local meteorAcc, boltAcc, fireAcc, floatAcc, uiAcc, hazAcc, waterAcc, aftershock, pulseTimer = 0, 0, 0, 0, 0, 0, 0, 8, 6
local swimming = false

local function hazardTick(step, t)
	local root, hum = getRoot(), getHum()
	if not root or not hum or hum.Health <= 0 then return end
	local s = R[stage]

	-- shelter: count roof layers above you and how enclosed you are
	local rpar = rayP()
	local layers = 0
	local origin = root.Position + Vector3.new(0, 2.5, 0)
	for _ = 1, 5 do
		local hit = Workspace:Raycast(origin, Vector3.new(0, 80, 0), rpar)
		if not hit then break end
		layers += 1
		origin = hit.Position + Vector3.new(0, 0.55, 0)
	end
	local chest = root.Position + Vector3.new(0, 1, 0)
	local blocked = 0
	for k = 0, 7 do
		local a = k * math.pi / 4
		if Workspace:Raycast(chest, Vector3.new(math.cos(a) * 9, 0, math.sin(a) * 9), rpar) then blocked += 1 end
	end
	layersN = layers
	enclosure = blocked / 8
	covered = layers > 0
	deep = root.Position.Y < baseY - 10
	local layerExpo = ({[0] = 1, 0.5, 0.28, 0.15, 0.08})[math.min(layers, 4)]
	local expo = deep and 0.05 or layerExpo
	sealed = layers >= 1 and enclosure >= 0.75
	if sealed and not deep then expo = expo * 0.6 end

	local heat = s.heat * expo
	local toxic = s.toxic * expo
	local acid = (not covered and not deep) and s.acidDmg or 0
	local fire = 0
	for _, pair in ipairs(fireList) do
		local part = pair[1].Parent
		if part and part:IsA("BasePart") and (part.Position - root.Position).Magnitude < 7 then fire = 4 break end
	end
	local oxyDps = 0
	if s.thin then
		oxy = math.max(0, oxy - step)
		if oxy <= 0 then oxyDps = 4 end
	else
		oxy = math.min(CONFIG.OxygenSeconds, oxy + step * 3)
	end

	local dps = heat + toxic + acid + fire + oxyDps
	hazardDps = dps
	local best, bw = 0, ""
	for _, e in ipairs({{heat, "heat"}, {toxic, "toxic air"}, {acid, "acid rain"}, {fire, "fire"}, {oxyDps, "no oxygen"}}) do
		if e[1] > best then best, bw = e[1], e[2] end
	end
	hazardWhy = bw
	if dps > 0 then hurt(dps * step, bw) end
	if hum.Health > 0 and hum.Health < hum.MaxHealth then
		if sealed and layers >= 2 then hum.Health = math.min(hum.MaxHealth, hum.Health + 1.5 * step)
		elseif deep then hum.Health = math.min(hum.MaxHealth, hum.Health + 1.0 * step) end
	end

	-- drowning
	local surf = surfaceY()
	local eff = math.max(surf or -1e9, tsuSurface or -1e9)
	local headY = root.Position.Y + 2
	if eff > -1e8 and headY < eff then
		air = air - step
		if air <= 0 then hurt(8 * step, "drowning") end
	else
		air = math.min(AIRMAX, air + step * 6)
	end

	-- earthquakes knock you down
	local q = N.quake.Value + burst
	if q > 0.6 and hum.FloorMaterial ~= Enum.Material.Air and math.random() < (q - 0.6) * 0.07 then stumble() end
end

local function heartbeat(dt)
	if not running then return end
	local t = os.clock()

	if not paused and stage < NSTAGES then
		elapsed += dt
		if elapsed >= CONFIG.StageLength then
			elapsed = 0
			applyStage(stage + 1, false)
		end
	end

	stepHurricane(dt, t)
	tsunamiStep(dt)
	surge = math.max(0, surge - dt * (0.8 + surge * 0.05))

	-- meteors
	if CONFIG.Meteors then
		meteorAcc += N.meteor.Value * dt
		while meteorAcc >= 1 do meteorAcc -= 1 spawnMeteor() end
	end
	for i = #meteors, 1, -1 do
		local m = meteors[i]
		local pos = m.part.Position + m.vel * dt
		m.part.Position = pos
		if pos.Y <= m.gy + 2 then
			impact(Vector3.new(pos.X, m.gy, pos.Z), m.size)
			m.part:Destroy()
			table.remove(meteors, i)
		end
	end

	-- lightning (stronger near the hurricane wall, calm in the eye)
	if CONFIG.Storms then
		boltAcc += N.lightning.Value * (eyeCalm and 0.2 or math.min(rainMul, 2.5) * 0.7) * dt
		while boltAcc >= 1 do
			boltAcc -= 1
			local targeted = N.lightning.Value >= 0.25 and not covered and not deep and math.random() < 0.05
			spawnBolt(targeted)
		end
	end

	-- wind pulls you toward the storm (gusts surge; walls and bunkers shield you)
	if CONFIG.Wind and windMag > 1 then
		local root = getRoot()
		if root then
			local gust = 1 + 1.8 * math.max(0, math.noise(t * 0.22, 9.1, 0) * 2.2)
			local exposure = deep and 0.1 or (1 - 0.85 * enclosure)
			local accel = windMag * 1.0 * gust * exposure
			root:ApplyImpulse(wd * accel * root.AssemblyMass * dt)
			if windMag > 60 and exposure > 0.5 then
				root:ApplyImpulse(Vector3.new(0, windMag * 0.1 * root.AssemblyMass * dt, 0))
			end
		end
	end

	-- swimming for the visual plane / tsunami bodies (real terrain water handles itself)
	do
		local root, hum = getRoot(), getHum()
		local planeSurf = nil
		if not terrainOK then planeSurf = surfaceY() end
		if tsuSurface then planeSurf = math.max(planeSurf or -1e9, tsuSurface) end
		if root and hum and hum.Health > 0 and planeSurf and root.Position.Y < planeSurf - 1 then
			if not swimming then
				swimming = true
				pcall(function() hum:ChangeState(Enum.HumanoidStateType.Swimming) end)
			end
			root:ApplyImpulse(Vector3.new(0, Workspace.Gravity * root.AssemblyMass * dt * 0.92, 0))
			root.AssemblyLinearVelocity = root.AssemblyLinearVelocity * (1 - math.min(1, dt * 1.5))
		elseif swimming then
			swimming = false
			if hum then pcall(function() hum:ChangeState(Enum.HumanoidStateType.Freefall) end) end
		end
	end

	-- fires
	fireAcc += dt
	if fireAcc > 0.7 then fireAcc = 0 fireStep() end

	-- floating / rattling objects
	floatAcc += dt
	if floatAcc > 1.2 then
		floatAcc = 0
		local fv = CONFIG.Floating and N.float.Value or 0
		local qv = CONFIG.Rattle and N.quake.Value or 0
		if fv > 0.05 and #floaters < math.floor(70 * math.min(fv, 1)) then
			pickFloaters(4, false)
		elseif qv > 0.03 and #floaters < math.floor(10 + 45 * math.min(qv / 0.4, 1)) then
			pickFloaters(5, true)
		end
	end
	floaterStep(dt, t)

	-- hazards (4x per second)
	hazAcc += dt
	if hazAcc >= 0.25 then
		local step = hazAcc
		hazAcc = 0
		hazardTick(step, t)
	end

	-- real terrain water follows the water level
	waterAcc += dt
	if waterAcc > 0.2 then waterAcc = 0 waterStep() end

	-- aftershocks: rumble pulses that rattle everything, and can crack the ground
	if N.quake.Value > 0.05 then
		aftershock -= dt
		if aftershock <= 0 then
			burst += N.quake.Value * (0.6 + math.random() * 0.8)
			aftershock = math.random(6, 16) / (1 + N.quake.Value)
			if majorShock then majorShock() end
		end
	end

	-- planetary shockwaves
	if pulseEvery > 0 then
		pulseTimer -= dt
		if pulseTimer <= 0 then
			pulseTimer = pulseEvery
			burst += 2.2
			flash(0.55, 2.5)
			oneShot(SND.boom, 2, 0.35, 0)
			blast(22, 60, "shockwave")
            if structDamage then structDamage(nil, nil, 18) end
		end
	end

	-- UI
	uiAcc += dt
	if uiAcc > 0.25 then
		uiAcc = 0
		local prog = (stage - 1 + (stage < NSTAGES and elapsed / CONFIG.StageLength or 0)) / (NSTAGES - 1)
		barFill.Size = UDim2.new(math.clamp(prog, 0, 1), 0, 1, 0)
		barFill.BackgroundColor3 = stageColor(1 + prog * (NSTAGES - 1))
		if paused then
			timerL.Text = "PAUSED"
		elseif stage >= NSTAGES then
			timerL.Text = "Final stage - the world is silent."
		else
			local left = CONFIG.StageLength - elapsed
			local txt = "Next stage in " .. fmt(left)
			if stage < IMPACT then
				txt = txt .. "   |   Core impact in " .. fmt((IMPACT - stage - 1) * CONFIG.StageLength + left + 10)
			end
			timerL.Text = txt
		end

		local lines = {}
		local shelterTxt = deep and "UNDERGROUND (safest)" or (sealed and ("SEALED, " .. layersN .. " roof layer(s)") or (covered and ("COVERED, " .. layersN .. " layer(s), walls " .. math.floor(enclosure * 100) .. "%") or "OUTSIDE (exposed)"))
		lines[#lines + 1] = "SHELTER: " .. shelterTxt
		if (sealed and layersN >= 2) or deep then lines[#lines + 1] = "RESTING: you slowly heal here" end
		if N.quake.Value > 0.05 then lines[#lines + 1] = ("QUAKE: M%.1f"):format(4 + N.quake.Value * 4.4) end
		if hazardDps > 0.05 then lines[#lines + 1] = ("HAZARD: %.1f dmg/s (%s)"):format(hazardDps, hazardWhy) end
		if R[stage].thin or oxy < CONFIG.OxygenSeconds - 1 then
			lines[#lines + 1] = ("O2 RESERVE: %d%%"):format(math.floor(oxy / CONFIG.OxygenSeconds * 100))
		end
		if air < AIRMAX - 0.5 then lines[#lines + 1] = ("BREATH: %d s"):format(math.max(0, math.floor(air))) end
		if N.hurr.Value > 0.02 and CONFIG.Hurricane then
			lines[#lines + 1] = ("HURRICANE: %d studs%s"):format(math.floor(Hdist), eyeCalm and " (IN THE EYE)" or "")
		end
		if #tsunamis > 0 and tsuNear < 5000 then lines[#lines + 1] = ("TSUNAMI: %d studs away"):format(math.floor(tsuNear)) end
		hud.Text = table.concat(lines, "\n")
		hud.Size = UDim2.new(0, 235, 0, 12 + #lines * 15)
	end
end
connect(RunService.Heartbeat, function(dt)
	local ok, e = pcall(heartbeat, dt)
	if not ok then report("loop", e) end
end)

--------------------------------------------------------------------
-- GO
--------------------------------------------------------------------
applyStage(stage, true)
showBanner(stage)
print("[MoonDoom v5] started at stage " .. stage .. " of " .. NSTAGES .. " - new stage every " .. CONFIG.StageLength .. "s")
end

local __ok, __err = xpcall(__part2, function(e) return tostring(e) .. "\n" .. debug.traceback() end)
if not __ok then warn("[MoonDoom] STARTUP ERROR: " .. tostring(__err)) end
