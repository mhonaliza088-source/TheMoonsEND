--[[
	MOON COLLISION v2 - LEAD-UP + 15 DAY DOOMSDAY (Delta compatible, client-side)

	Stages (one every StageLength seconds, default 180 = 3 min):
	  1      Normal day
	  2-5    5 months / 5 weeks / 1 month / 1 week BEFORE the collision (storms build up)
	  6-20   Day 1 ... Day 15
	New in v2: storms + lightning, hurricanes, wind that pushes you, low gravity,
	and nearby objects that start floating and lift off.

	GUI:  <  previous stage   II  pause   >  next stage   X  stop & restore
	Tap the title to show / hide details. Re-executing restarts cleanly.
]]

local CONFIG = {
	StageLength = 180,     -- seconds per stage (3 minutes)
	TransitionTime = 12,   -- seconds to blend into the next stage
	StartStage = 1,        -- 1 = normal day, 6 = Day 1, 14 = Core Impact
	ShowPanel = true,
	Flood = true,          -- visual flood water (not solid)
	Meteors = true,
	Fires = true,
	Quakes = true,         -- camera shake
	Storms = true,         -- rain + lightning
	Hurricane = true,      -- giant rotating storm
	Wind = true,           -- wind pushes your character
	LowGravity = true,     -- gravity drops as the Moon gets closer
	Floating = true,       -- nearby small objects float away
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

local char = lp.Character or lp.CharacterAdded:Wait()
char:WaitForChild("HumanoidRootPart", 10)

--------------------------------------------------------------------
-- ORIGINAL LIGHTING
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

local function newFx(class, props)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = Lighting
	return track(o)
end
local cc = newFx("ColorCorrection", {Name = "DoomCC"})
local bloom = newFx("BloomEffect", {Name = "DoomBloom", Intensity = 0, Size = 28, Threshold = 0.8})
local blur = newFx("BlurEffect", {Name = "DoomBlur", Size = 0})
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
-- TWEENED WORLD VALUES
--------------------------------------------------------------------
local NUM_KEYS = {"moonDeg", "egg", "chunkSpread", "chunkT", "ringT", "quake", "meteor", "ash", "ember", "molten", "acid", "water",
	"rain", "lightning", "wind", "hurr", "float", "gravity"}
local N = {}
for _, k in ipairs(NUM_KEYS) do N[k] = Instance.new("NumberValue") end
local moonColV = Instance.new("Color3Value")
local waterColV = Instance.new("Color3Value")
local hurrColV = Instance.new("Color3Value")

--------------------------------------------------------------------
-- STAGE DATA (each stage lists only what CHANGES from the previous one)
--------------------------------------------------------------------
local function C(r, g, b) return Color3.fromRGB(r, g, b) end
local G = function(f) return ORIGGRAV * f end

local base = {
	brightness = ORIG.Brightness, ambient = ORIG.Ambient, outdoor = ORIG.OutdoorAmbient, clock = ORIG.ClockTime,
	fogColor = ORIG.FogColor, fogStart = ORIG.FogStart, fogEnd = ORIG.FogEnd, exposure = ORIG.ExposureCompensation,
	atmDensity = OA.Density, atmOffset = OA.Offset, atmColor = OA.Color, atmDecay = OA.Decay, atmGlare = OA.Glare, atmHaze = OA.Haze,
	ccBright = 0, ccContrast = 0, ccSat = 0, ccTint = Color3.new(1, 1, 1), bloom = 0, blur = 0, rays = 0,
	moonDeg = 1.2, moonCol = C(205, 205, 212), egg = 0, chunkSpread = 0, chunkT = 1, ringT = 1,
	quake = 0, meteor = 0, ash = 0, ember = 0, molten = 0, acid = 0,
	water = -400, waterCol = C(35, 90, 140), fires = 0, pulse = 0,
	rain = 0, lightning = 0, wind = 0, hurr = 0, float = 0, gravity = ORIGGRAV,
	boltCol = C(210, 225, 255), hurrCol = C(70, 72, 82),
}

local STAGES = {}
local function S(label, name, ev, ef, tip, d, impact)
	STAGES[#STAGES + 1] = {label = label, name = name, ev = ev, ef = ef, tip = tip, d = d or {}, impact = impact}
end

S("NORMAL DAY", "Business as Usual", "Everything is normal.",
	"The Moon hangs quietly in the sky. Nothing seems wrong... yet.",
	"Enjoy it. The next stages are your time to prepare.", {})

S("5 MONTHS BEFORE", "First Anomalies",
	"Astronomers notice the Moon's orbit is no longer stable. Its distance begins to shrink by a few kilometers a day.",
	"Spring tides run higher than any recorded. Coastal storm systems intensify and unseasonal thunderstorms become common. Most people shrug it off.",
	"Stock food, water and tools. Plan where you will shelter.",
	{moonDeg = 1.7, rain = 40, lightning = 0.03, wind = 6, hurr = 0.1, ccSat = -0.05, atmDensity = 0.3, atmHaze = 0.8})

S("5 WEEKS BEFORE", "The Storm Season That Wouldn't End",
	"The Moon is visibly larger. Its pull now drags on the atmosphere as well as the oceans.",
	"Storm systems merge and sit over land for days. Hurricanes form out of season and the first coastal evacuations begin. Faint tremors rattle the fault lines.",
	"Move supplies inland and start digging your shelter.",
	{moonDeg = 2.2, rain = 90, lightning = 0.08, wind = 12, hurr = 0.3, quake = 0.05, ccSat = -0.1,
	 ccTint = C(225, 230, 240), atmDensity = 0.35, atmColor = C(160, 170, 185), atmHaze = 1.2, gravity = G(0.99)})

S("1 MONTH BEFORE", "Superstorms",
	"The Moon spans several times its old width and the tides have doubled.",
	"Category 5 hurricanes batter every coastline and non-stop lightning storms knock out power grids. Earthquakes hit the major faults every day.",
	"Finish your shelter. Get to high ground before the sea rises.",
	{moonDeg = 2.7, rain = 150, lightning = 0.2, wind = 22, hurr = 0.55, quake = 0.12, exposure = -0.15,
	 ccSat = -0.18, ccTint = C(205, 212, 225), atmColor = C(120, 130, 150), atmDecay = C(80, 90, 110), gravity = G(0.97)})

S("1 WEEK BEFORE", "Tides Out of Control",
	"The Moon fills a huge part of the sky and Earth's crust begins to flex under its pull.",
	"Tides surge far inland, hurricane-force winds never stop and the sky flickers with constant lightning. Loose objects start to feel oddly light in the strange gravity.",
	"Last chance. Shelter now, on high ground. Day 1 is next.",
	{moonDeg = 3.4, rain = 200, lightning = 0.35, wind = 35, hurr = 0.8, quake = 0.2, clock = 20,
	 brightness = 1.2, ambient = C(60, 65, 85), outdoor = C(85, 90, 115), gravity = G(0.93), atmDensity = 0.38,
	 atmColor = C(110, 120, 145), fogStart = 100, fogEnd = 3500, ccSat = -0.25, ccTint = C(195, 205, 225)})

S("DAY 1 / 15", "The Tidal Shock",
	"The Moon's orbit destabilizes, setting it on a collision course.",
	"Ocean tides go haywire, surging hundreds of feet high within minutes and wiping out coastal cities worldwide. Tectonic plates buckle, triggering massive earthquakes along major fault lines.",
	"Get to high ground NOW. Stay away from the coast.",
	{moonDeg = 5, quake = 0.4, water = 26, rain = 220, lightning = 0.5, wind = 40, hurr = 0.9, gravity = G(0.9)})

S("DAY 2 / 15", "The Looming Giant",
	"The Moon closes the distance, dominating the night sky as a massive disk.",
	"High tides become permanent coastal floods, rendering low-lying regions completely uninhabitable. Low-Earth-orbit satellites experience erratic drag from the shifting gravitational gradient.",
	"Floods are permanent. Stay high and inland.",
	{moonDeg = 32, quake = 0.25, water = 14, clock = 22, brightness = 1, ambient = C(45, 50, 75), outdoor = C(70, 75, 105),
	 ccSat = -0.2, ccTint = C(200, 210, 235), atmColor = C(100, 110, 140), atmDecay = C(60, 65, 90), atmHaze = 1, exposure = 0.1,
	 rain = 160, lightning = 0.3, wind = 28, hurr = 0.7, gravity = G(0.84), float = 0.1})

S("DAY 3 / 15", "Global Tectonic Awakening",
	"Gravitational stress deforms Earth's crust on a planetary scale.",
	"Continuous magnitude 8+ earthquakes strike every continent. Dormant volcanoes erupt simultaneously, choking the stratosphere with ash and sulfur dioxide, collapsing global infrastructure completely.",
	"Avoid tall structures and fault lines. Protect your air supply from ash.",
	{moonDeg = 52, quake = 0.8, ash = 70, ember = 10, ccSat = -0.35, ccTint = C(215, 190, 170),
	 atmDensity = 0.38, atmColor = C(120, 100, 90), atmDecay = C(80, 50, 30), atmHaze = 3,
	 ambient = C(60, 48, 42), outdoor = C(80, 62, 52), fogColor = C(85, 75, 70), fogStart = 200, fogEnd = 3500,
	 rain = 0, lightning = 0.6, boltCol = C(255, 190, 120), wind = 40, hurr = 0.8, hurrCol = C(90, 75, 65),
	 gravity = G(0.75), float = 0.25})

S("DAY 4 / 15", "Crossing the Roche Limit",
	"The Moon reaches the Roche limit (~9,500 km up), where Earth's tidal forces overcome the Moon's internal gravity.",
	"The Moon distorts into an egg-like shape and violently begins to tear apart, its crust fracturing under the strain.",
	"Dig in. Deep shelter is your only hope from here.",
	{moonDeg = 78, egg = 1, chunkT = 0, chunkSpread = 0.8, moonCol = C(215, 180, 160), quake = 1, ember = 22, atmDensity = 0.35,
	 lightning = 0.4, wind = 30, hurr = 0.5, gravity = G(0.6), float = 0.5})

S("DAY 5 / 15", "The Birth of Earth's Ring System",
	"The shattered lunar material spreads out into orbit.",
	"A brilliant, glittering ring of rock, dust, and boulders forms around the Earth, while the main core mass continues its unstoppable descent.",
	"Debris is coming. Reinforce your roof.",
	{moonDeg = 82, egg = 0.5, chunkSpread = 1.7, ringT = 0.3, moonCol = C(235, 150, 100), quake = 0.7, ash = 60, atmDensity = 0.3,
	 lightning = 0.3, wind = 25, hurr = 0.3, gravity = G(0.45), float = 0.7})

S("DAY 6 / 15", "Atmospheric Friction & Debris Rain",
	"Fragments from the outer ring enter the upper atmosphere.",
	"The sky glows an apocalyptic orange-red as millions of meteorites rain down constantly. Friction superheats the upper atmosphere, raising global ambient temperatures rapidly.",
	"Stay under cover. Do not go outside.",
	{moonDeg = 92, chunkT = 1, chunkSpread = 2.3, ringT = 0.15, moonCol = C(255, 120, 50), quake = 0.6, meteor = 3, ember = 60,
	 ambient = C(110, 50, 25), outdoor = C(140, 60, 30), atmDensity = 0.5, atmColor = C(255, 120, 50), atmDecay = C(255, 70, 20), atmHaze = 3,
	 fogColor = C(120, 50, 20), fogStart = 100, fogEnd = 2200, ccSat = 0.1, ccTint = C(255, 175, 130), bloom = 0.6,
	 lightning = 0.2, boltCol = C(255, 160, 90), wind = 35, hurr = 0.4, hurrCol = C(120, 50, 25), gravity = G(0.3), float = 0.9})

S("DAY 7 / 15", "Global Firestorms",
	"Continuous atmospheric impacts ignite widespread fires.",
	"Forests, grasslands, and cities catch fire from the relentless searing debris. Thick, toxic plumes of black smoke merge into a planetary canopy, blotting out the sun.",
	"Seal your shelter against smoke. Stay away from anything flammable.",
	{moonDeg = 100, quake = 0.5, meteor = 4, fires = 70, ash = 120,
	 atmDensity = 0.8, atmColor = C(70, 40, 28), atmDecay = C(50, 25, 15), atmHaze = 5,
	 ambient = C(80, 35, 20), outdoor = C(90, 40, 25), fogColor = C(40, 25, 20), fogEnd = 1300, ccBright = -0.05, ccTint = C(255, 160, 120),
	 lightning = 0.5, wind = 55, hurr = 1, hurrCol = C(255, 110, 30), gravity = G(0.22), float = 1})

S("DAY 8 / 15", "Boiling Oceans and Pressure Spikes",
	"Heat from continuous impacts and greenhouse gases boils shallow seas.",
	"Atmospheric pressure spikes wildly as steam mixes with carbon monoxide and ash. Oxygen levels crash due to the death of global plant life, making unassisted breathing impossible.",
	"You need your own air. Impact is minutes away.",
	{moonDeg = 112, quake = 0.6, water = 6, waterCol = C(200, 200, 210), blur = 5, ember = 40,
	 atmDensity = 0.9, atmColor = C(170, 150, 140), atmDecay = C(130, 100, 80), atmHaze = 6,
	 fogColor = C(150, 130, 120), fogEnd = 800, ccSat = -0.5, ccTint = C(235, 215, 200),
	 lightning = 0.6, wind = 45, hurr = 0.8, hurrCol = C(190, 185, 185), gravity = G(0.15), float = 1})

S("DAY 9 / 15", "The Core Impact",
	"The main core mass of the Moon slams directly into the Earth's crust.",
	"The sheer kinetic energy melts the impact zone instantly. A massive hemisphere of the planet turns into a roiling, superheated sea of liquid magma.",
	"BRACE FOR IMPACT.",
	{moonDeg = 0, quake = 1.2, water = 0, waterCol = C(255, 110, 40), blur = 2, ember = 150, ash = 150, meteor = 2,
	 brightness = 3, ambient = C(200, 80, 30), outdoor = C(255, 90, 30),
	 atmDensity = 1, atmColor = C(255, 90, 20), atmDecay = C(255, 60, 10), atmHaze = 6,
	 fogColor = C(255, 110, 40), fogStart = 0, fogEnd = 300, ccTint = C(255, 140, 90), bloom = 1.5,
	 lightning = 0.8, boltCol = C(255, 200, 140), wind = 100, hurr = 0.6, hurrCol = C(255, 100, 30), gravity = G(1), float = 0}, true)

S("DAY 10 / 15", "Planetary Shockwaves & Vaporized Oceans",
	"Mega-shockwaves circle the globe multiple times.",
	"The shockwaves flatten every mountain range on Earth. The remaining oceans are entirely vaporized, turning the atmosphere into a pressurized, steam-choked pressure cooker.",
	"Hold on. Each shockwave hits harder than the last.",
	{quake = 0.5, water = -400, blur = 0, ember = 100, ash = 60, meteor = 0, pulse = 28, fires = 0,
	 brightness = 2, ambient = C(180, 120, 90), outdoor = C(230, 150, 110),
	 atmColor = C(230, 200, 180), atmDecay = C(220, 170, 140), fogColor = C(230, 200, 180), fogEnd = 220,
	 ccBright = 0.1, ccTint = C(255, 235, 215), bloom = 1, wind = 70, hurr = 0.5, hurrCol = C(200, 170, 150)})

S("DAY 11 / 15", "The Ejecta Fallout (Molten Rain)",
	"Tons of pulverized rock and magma blasted into space by the Day 9 impact rain back down.",
	"The entire planet's surface is subjected to a global thermal radiation wave. The sky glows white-hot as falling molten droplets flash-heat the atmosphere, sterilizing every inch of the surface.",
	"Deep underground is the only safe place.",
	{quake = 0.6, molten = 220, pulse = 0, ember = 0, ash = 0,
	 brightness = 4, ambient = C(255, 220, 190), outdoor = C(255, 230, 200),
	 atmColor = C(255, 240, 220), atmDecay = C(255, 230, 200), fogColor = C(255, 235, 210), fogEnd = 150,
	 ccBright = 0.15, ccTint = C(255, 245, 230), bloom = 2.5, wind = 30, hurr = 0.2, hurrCol = C(255, 225, 190), lightning = 0.2})

S("DAY 12 / 15", "The Global Darkening",
	"The dust, ash, and vaporized rock form a thick, permanent global shroud.",
	"Complete, pitch-black darkness envelops the planet. Sunlight cannot penetrate the thick stratospheric haze, plunging the surface into an extreme, toxic twilight.",
	"No sunlight. Light and heat are everything.",
	{quake = 0.2, molten = 0, ash = 40, brightness = 0, exposure = -0.4,
	 ambient = C(6, 4, 4), outdoor = C(6, 4, 4), atmColor = C(0, 0, 0), atmDecay = C(0, 0, 0),
	 fogColor = C(0, 0, 0), fogStart = 0, fogEnd = 70, ccBright = -0.1, ccTint = C(180, 150, 140), bloom = 0,
	 lightning = 1.4, boltCol = C(190, 200, 255), wind = 40, hurr = 0.7, hurrCol = C(30, 25, 25)})

S("DAY 13 / 15", "The Magma Ocean Cools",
	"The surface magma ocean begins to radiate its heat into space.",
	"The roiling seas of lava slowly begin to crust over, cooling into a smooth, featureless shell of black basalt rock across the ruined landscape.",
	"The ground is still hot. Wait it out.",
	{quake = 0.1, ash = 0, ember = 25, brightness = 0.6, exposure = 0,
	 ambient = C(40, 12, 6), outdoor = C(60, 18, 8), atmColor = C(50, 15, 8), atmDecay = C(80, 20, 10), atmDensity = 0.9,
	 fogColor = C(30, 8, 4), fogEnd = 180, ccBright = 0, ccSat = -0.2, ccTint = C(255, 150, 110),
	 rain = 200, lightning = 1.0, boltCol = C(220, 225, 255), wind = 50, hurr = 1, hurrCol = C(110, 105, 110)})

S("DAY 14 / 15", "Acidic Downpours",
	"The massive amounts of atmospheric steam begin to condense.",
	"Torrential, highly acidic rains begin to pour down from the skies, washing toxic chemicals and sulfur compounds across the barren basalt plains to form new, boiling primordial seas.",
	"Acid rain. Stay sheltered.",
	{quake = 0.15, ember = 0, acid = 260, rain = 0, water = 6, waterCol = C(180, 200, 60), brightness = 0.8, bloom = 0.3,
	 ambient = C(45, 55, 25), outdoor = C(65, 80, 30), atmColor = C(120, 140, 60), atmDecay = C(100, 120, 40), atmHaze = 4, atmDensity = 0.85,
	 fogColor = C(80, 95, 40), fogEnd = 260, ccSat = -0.15, ccTint = C(215, 235, 150),
	 lightning = 0.7, wind = 45, hurr = 0.7, hurrCol = C(70, 90, 40)})

S("DAY 15 / 15", "A Silent, Ringed World",
	"The skies clear slightly, revealing the aftermath.",
	"Earth is completely unrecognizable - a sterile, silent, ocean-covered world stripped of all life, orbited by a brilliant, permanent ring system composed of the leftover debris of its former moon.",
	"It is over. Look up.",
	{quake = 0, acid = 0, water = 40, waterCol = C(25, 70, 100), ringT = 0, brightness = 1.2, bloom = 0.2,
	 ambient = C(60, 65, 85), outdoor = C(85, 95, 120), atmColor = C(150, 165, 190), atmDecay = C(90, 100, 130), atmHaze = 1, atmDensity = 0.25,
	 fogColor = C(60, 70, 90), fogStart = 400, fogEnd = 3000, ccSat = -0.35, ccTint = C(200, 215, 235),
	 lightning = 0, wind = 3, hurr = 0.1, boltCol = C(210, 225, 255)})

local NSTAGES = #STAGES
local IMPACT = 1
for i, s in ipairs(STAGES) do if s.impact then IMPACT = i end end

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
-- MOON, CHUNKS, RING
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

local craterDefs = {{20, 30, .14}, {35, 200, .10}, {50, 110, .18}, {15, 260, .07}, {45, 320, .12}, {58, 60, .09}, {28, 150, .08}, {40, 10, .06}, {10, 90, .10}}
local craters = {}
for _, c in ipairs(craterDefs) do
	local p = sphere(mkPart(Vector3.new(1, 1, 1), CFrame.new(), Enum.Material.Neon, C(125, 125, 135)))
	p.Transparency = 1
	p.Parent = fx
	craters[#craters + 1] = {part = p, phi = math.rad(c[1]), alpha = math.rad(c[2]), frac = c[3]}
end

local chunks = {}
for _ = 1, 18 do
	local v = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)
	if v.Magnitude < 0.05 then v = Vector3.new(1, 0, 0) end
	local p = mkPart(Vector3.new(1, 1, 1), CFrame.new(), Enum.Material.Neon, C(150, 130, 120))
	p.Transparency = 1
	p.Parent = fx
	chunks[#chunks + 1] = {part = p, off = v.Unit * (0.5 + math.random() * 0.5), frac = math.random(8, 28) / 100,
		rot = CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)}
end

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
connect(N.chunkT.Changed, function(v)
	for _, c in ipairs(chunks) do c.part.Transparency = v end
end)

--------------------------------------------------------------------
-- HURRICANE (giant rotating spiral of cloud bands)
--------------------------------------------------------------------
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
-- WATER + WEATHER PARTICLES
--------------------------------------------------------------------
local water = mkPart(Vector3.new(2048, 2, 2048), CFrame.new(0, baseY - 400, 0), Enum.Material.SmoothPlastic, C(35, 90, 140))
water.Reflectance = 0.1
water.Transparency = 1
water.Parent = fx

local weather = mkPart(Vector3.new(150, 1, 150), CFrame.new())
weather.Transparency = 1
weather.Parent = fx

local SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local function emitter(props)
	local e = Instance.new("ParticleEmitter")
	e.Rate = 0
	e.EmissionDirection = Enum.NormalId.Bottom
	for k, v in pairs(props) do e[k] = v end
	e.Parent = weather
	return e
end
local ashE = emitter({Texture = SMOKE, Color = ColorSequence.new(C(110, 100, 95)), Size = NumberSequence.new(1.2),
	Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.15, 0.45), NumberSequenceKeypoint.new(1, 1)}),
	Lifetime = NumberRange.new(6, 9), Speed = NumberRange.new(5, 11), SpreadAngle = Vector2.new(25, 25),
	RotSpeed = NumberRange.new(-40, 40), Acceleration = Vector3.new(6, -2, 3)})
local emberE = emitter({Texture = SPARK, Color = ColorSequence.new(C(255, 140, 40), C(255, 60, 0)), Size = NumberSequence.new(0.5),
	LightEmission = 1, Lifetime = NumberRange.new(5, 8), Speed = NumberRange.new(10, 18), SpreadAngle = Vector2.new(30, 30),
	Acceleration = Vector3.new(4, -3, 2)})
local moltenE = emitter({Texture = SPARK, Color = ColorSequence.new(C(255, 190, 80), C(255, 70, 10)), Size = NumberSequence.new(1.1),
	LightEmission = 1, Lifetime = NumberRange.new(1.0, 1.3), Speed = NumberRange.new(65, 90), SpreadAngle = Vector2.new(4, 4),
	Acceleration = Vector3.new(0, -90, 0)})
local acidE = emitter({Texture = SPARK, Color = ColorSequence.new(C(200, 235, 70)), Size = NumberSequence.new(0.55),
	Transparency = NumberSequence.new(0.3), LightEmission = 0.5, Lifetime = NumberRange.new(0.9, 1.2), Speed = NumberRange.new(85, 110),
	SpreadAngle = Vector2.new(2, 2), Acceleration = Vector3.new(0, -120, 0)})
local rainE = emitter({Texture = SPARK, Color = ColorSequence.new(C(170, 190, 225)), Size = NumberSequence.new(0.35),
	Transparency = NumberSequence.new(0.4), LightEmission = 0.2, Lifetime = NumberRange.new(0.7, 0.9), Speed = NumberRange.new(90, 120),
	SpreadAngle = Vector2.new(3, 3), Acceleration = Vector3.new(0, -130, 0)})

--------------------------------------------------------------------
-- WIND
--------------------------------------------------------------------
local wd, windMag, hcenter = Vector3.new(1, 0, 0), 0, Vector3.zero
local hdir = Vector3.new(0.8, 0, -0.6).Unit

local function updateWind(t)
	local hv = math.min(N.hurr.Value, 1)
	local root = getRoot()
	local rp = root and root.Position or startPos
	local dist = 300 + 1200 * (1 - hv)
	hcenter = Vector3.new(startPos.X + hdir.X * dist, baseY, startPos.Z + hdir.Z * dist)
	local rel = Vector3.new(rp.X - hcenter.X, 0, rp.Z - hcenter.Z)
	local baseAng = 0.7 + math.noise(t * 0.05, 2.2, 0) * 2
	local dir = Vector3.new(math.cos(baseAng), 0, math.sin(baseAng))
	if rel.Magnitude > 1 and hv > 0.02 then
		local tang = Vector3.new(-rel.Z, 0, rel.X).Unit
		local inward = (-rel).Unit
		dir = dir * (1 - hv) + (tang + inward * 0.35).Unit * hv
	end
	if dir.Magnitude > 0.01 then dir = dir.Unit end
	wd = dir
	windMag = N.wind.Value * (0.8 + 0.6 * math.noise(t * 0.8, 4.4, 0))
end

--------------------------------------------------------------------
-- METEORS, LIGHTNING, FIRES, FLOATERS
--------------------------------------------------------------------
local meteors = {}

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
	meteors[#meteors + 1] = {part = p, vel = vel, gy = gy}
end

local function impact(pos)
	if math.random() < 0.6 then
		local e = Instance.new("Explosion")
		e.BlastPressure = 0
		e.BlastRadius = math.random(8, 16)
		e.DestroyJointRadiusPercent = 0
		e.ExplosionType = Enum.ExplosionType.NoCraters
		e.Position = pos
		e.Parent = Workspace
	end
	local root = getRoot()
	if root then
		local d = (root.Position - pos).Magnitude
		if d < 80 then burst += 0.35 * (1 - d / 80) end
	end
end

local flash -- defined with the GUI
local activeBolts = 0

local function spawnBolt()
	local root = getRoot()
	if not root or activeBolts >= 4 then return end
	local ang, dist = math.random() * math.pi * 2, math.random(120, 700)
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
end

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
	if not CONFIG.Fires or fireTarget <= 0 then
		clearFire(6)
		return
	end
	if #fireList >= fireTarget then return end
	local root = getRoot()
	if not root then return end
	overlap.FilterDescendantsInstances = {lp.Character, fx}
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

-- Floating objects: local visual copies of small nearby parts rise and drift away
local floaters, picked = {}, {}
local KEEP = {SpecialMesh = true, BlockMesh = true, SurfaceAppearance = true, Decal = true, Texture = true}

local function releaseFloater(f)
	pcall(function() f.orig.LocalTransparencyModifier = 0 end)
	picked[f.orig] = nil
	pcall(function() f.clone:Destroy() end)
end

local function dropFloater(f)
	-- object flew away: keep the original hidden, just remove the copy
	picked[f.orig] = nil
	pcall(function() f.clone:Destroy() end)
end

local function pickFloaters(count)
	local root = getRoot()
	if not root then return end
	overlap.FilterDescendantsInstances = {lp.Character, fx}
	local parts = Workspace:GetPartBoundsInRadius(root.Position, 140, overlap)
	if #parts == 0 then return end
	local floor = Workspace:Raycast(root.Position, Vector3.new(0, -8, 0), rayP())
	local floorPart = floor and floor.Instance
	for _ = 1, count do
		local p = parts[math.random(#parts)]
		if p and not picked[p] and p ~= floorPart and not p:IsA("Terrain") then
			local mag = p.Size.Magnitude
			local model = p:FindFirstAncestorOfClass("Model")
			if mag >= 3 and mag <= 32 and p.Transparency < 0.9 and not (model and model:FindFirstChildOfClass("Humanoid")) then
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
						vel = Vector3.zero, launched = false, phase = math.random() * 6.28,
						ang = Vector3.new((math.random() - 0.5) * 2, (math.random() - 0.5) * 2, (math.random() - 0.5) * 2)}
				end
			end
		end
	end
end

local function floaterStep(dt, t)
	local fv = CONFIG.Floating and N.float.Value or 0
	local root = getRoot()
	local rp = root and root.Position or startPos
	local moonFlat = Vector3.new(moonDir.X, 0, moonDir.Z).Unit
	for i = #floaters, 1, -1 do
		local f = floaters[i]
		if not f.clone.Parent then
			table.remove(floaters, i)
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
				if fv < 0.3 and f.pos.Y <= f.home then
					table.remove(floaters, i)
					releaseFloater(f)
				elseif f.pos.Y > baseY + 1200 or (f.pos - rp).Magnitude > 1500 then
					table.remove(floaters, i)
					dropFloater(f)
				end
			else
				local target = f.home + fv * fv * 45 + math.sin(t * 1.7 + f.phase) * 0.5 * fv
				local y = f.pos.Y + (target - f.pos.Y) * math.min(1, dt * 1.5)
				f.pos = Vector3.new(f.pos.X, y, f.pos.Z)
				local k = dt * 0.3 * fv
				f.rot = CFrame.Angles(f.ang.X * k, f.ang.Y * k, f.ang.Z * k) * f.rot
				f.clone.CFrame = CFrame.new(f.pos) * f.rot
				if fv < 0.02 and math.abs(f.pos.Y - f.home) < 0.3 then
					table.remove(floaters, i)
					releaseFloater(f)
				end
			end
		end
	end
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
-- APPLY A STAGE
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
	task.wait(7)
	if not running or tok ~= token then return end
	N.moonDeg.Value = 0
	flash(0, 9)
	burst += 3.5
	applyState(R[IMPACT], 2.5)
end

local function applyStage(i, instant)
	token += 1
	local tok = token
	stage = i
	if not instant then showBanner(i) end
	expanded = true
	refreshPanel()
	task.delay(25, function()
		if running and tok == token then expanded = false refreshPanel() end
	end)
	if i == IMPACT and not instant then
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
	clearFire(#fireList)
	for i = #floaters, 1, -1 do releaseFloater(floaters[i]) end
	for p in pairs(picked) do pcall(function() p.LocalTransparencyModifier = 0 end) end
	for _, o in ipairs(objs) do pcall(function() o:Destroy() end) end
	for k, v in pairs(ORIG) do pcall(function() Lighting[k] = v end) end
	if not atmCreated then
		for k, v in pairs(OA) do pcall(function() atm[k] = v end) end
	end
	pcall(function() Workspace.Gravity = ORIGGRAV end)
	ENV.__MOON_DOOM = nil
end
ENV.__MOON_DOOM = Stop
btn("X", Stop)

--------------------------------------------------------------------
-- PER-FRAME VISUALS
--------------------------------------------------------------------
local function updateMoon(cp)
	local deg = N.moonDeg.Value
	if deg < 0.05 then
		moon.Transparency = 1
		for _, c in ipairs(craters) do c.part.Transparency = 1 end
		return
	end
	local u = moonDir
	local right = u:Cross(Vector3.yAxis).Unit
	local upv = right:Cross(u)
	local s = 2 * DIST * math.sin(math.rad(math.min(deg, 176)) / 2)
	local center = cp + u * DIST
	local egg = N.egg.Value

	moon.Transparency = 0
	moon.Color = moonColV.Value
	moon.Size = Vector3.new(math.min(2048, s * (1 + 0.35 * egg)), math.min(2048, s * (1 - 0.12 * egg)), math.min(2048, s * (1 - 0.12 * egg)))
	moon.CFrame = CFrame.fromMatrix(center, right, upv)

	local cT = math.clamp(egg * 1.5, 0, 1)
	for _, c in ipairs(craters) do
		local n = -u * math.cos(c.phi) + (right * math.cos(c.alpha) + upv * math.sin(c.alpha)) * math.sin(c.phi)
		local pt = center + n * (s / 2 * 0.995)
		c.part.Transparency = cT
		c.part.Size = Vector3.new(s * c.frac, s * c.frac, math.max(0.05, s * c.frac * 0.06))
		c.part.CFrame = CFrame.lookAt(pt, pt + n)
	end

	if N.chunkT.Value < 0.99 then
		local sp = N.chunkSpread.Value
		for _, c in ipairs(chunks) do
			local off = (right * c.off.X + upv * c.off.Y + u * c.off.Z) * (s / 2) * (1 + sp)
			local proj = off:Dot(u)
			if proj < -(DIST - 200) then off += u * (-(DIST - 200) - proj) end
			local sz = math.max(1, math.min(900, s * c.frac))
			c.part.Size = Vector3.new(sz, sz * 0.8, sz * 0.9)
			c.part.CFrame = CFrame.new(center + off) * c.rot
		end
	end
end

RunService:BindToRenderStep("MoonDoomFX", Enum.RenderPriority.Camera.Value + 1, function(dt)
	local cam = Workspace.CurrentCamera
	if not cam or not running then return end
	local t = os.clock()

	updateWind(t)
	if CONFIG.LowGravity then Workspace.Gravity = N.gravity.Value end

	-- earthquake / shockwave / wind-gust shake
	local q = CONFIG.Quakes and (N.quake.Value + burst) or 0
	q += windMag * 0.004
	burst = burst * math.exp(-dt * 1.1)
	if q > 0.02 then
		cam.CFrame = cam.CFrame
			* CFrame.new(math.noise(t * 23, 1.3, 0) * 2 * q * 0.5, math.noise(t * 27, 7.7, 0) * 2 * q * 0.5, 0)
			* CFrame.Angles(math.noise(t * 19, 5.1, 0) * 2 * q * 0.012, math.noise(t * 21, 9.7, 0) * 2 * q * 0.012, math.noise(t * 17, 3.3, 0) * 2 * q * 0.02)
	end

	local cp = cam.CFrame.Position
	updateMoon(cp)

	if N.ringT.Value < 0.99 then
		ringModel:PivotTo(CFrame.new(cp + Vector3.new(0, -350, 0)) * CFrame.Angles(math.rad(32), 0, math.rad(10)) * CFrame.Angles(0, t * 0.015, 0))
	end

	if CONFIG.Hurricane and N.hurr.Value > 0.02 then
		hurrModel:PivotTo(CFrame.new(hcenter) * CFrame.Angles(0, t * (0.15 + 0.25 * N.hurr.Value), 0))
	end

	-- flood water
	local level = N.water.Value
	if CONFIG.Flood and level > -300 then
		water.Transparency = 0.35
		water.Color = waterColV.Value
		local surface = baseY + level
		water.CFrame = CFrame.new(cp.X, surface - 1, cp.Z)
		if cp.Y < surface then
			underOverlay.BackgroundColor3 = waterColV.Value
			underOverlay.BackgroundTransparency = 0.45
		else
			underOverlay.BackgroundTransparency = 1
		end
	else
		water.Transparency = 1
		underOverlay.BackgroundTransparency = 1
	end

	-- weather
	weather.CFrame = CFrame.new(cp + Vector3.new(0, 55, 0))
	ashE.Rate = N.ash.Value
	emberE.Rate = N.ember.Value
	moltenE.Rate = N.molten.Value
	acidE.Rate = N.acid.Value
	rainE.Rate = CONFIG.Storms and N.rain.Value or 0
	rainE.Acceleration = Vector3.new(wd.X * windMag * 1.2, -130, wd.Z * windMag * 1.2)
	ashE.Acceleration = Vector3.new(wd.X * windMag * 0.4, -2, wd.Z * windMag * 0.4)
end)

--------------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------------
local function fmt(sec)
	sec = math.max(0, math.floor(sec))
	return ("%d:%02d"):format(sec // 60, sec % 60)
end

local meteorAcc, boltAcc, fireAcc, floatAcc, uiAcc, aftershock, pulseTimer = 0, 0, 0, 0, 0, 8, 20

connect(RunService.Heartbeat, function(dt)
	if not running then return end
	local t = os.clock()

	if not paused and stage < NSTAGES then
		elapsed += dt
		if elapsed >= CONFIG.StageLength then
			elapsed = 0
			applyStage(stage + 1, false)
		end
	end

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
			impact(pos)
			m.part:Destroy()
			table.remove(meteors, i)
		end
	end

	-- lightning
	if CONFIG.Storms then
		boltAcc += N.lightning.Value * dt
		while boltAcc >= 1 do boltAcc -= 1 spawnBolt() end
	end

	-- wind pushes you
	if CONFIG.Wind and windMag > 1 then
		local root = getRoot()
		if root then root:ApplyImpulse(wd * windMag * 0.55 * root.AssemblyMass * dt) end
	end

	-- fires
	fireAcc += dt
	if fireAcc > 0.7 then fireAcc = 0 fireStep() end

	-- floating objects
	floatAcc += dt
	if floatAcc > 1.2 then
		floatAcc = 0
		local fv = CONFIG.Floating and N.float.Value or 0
		if fv > 0.05 and #floaters < math.floor(70 * math.min(fv, 1)) then pickFloaters(4) end
	end
	floaterStep(dt, t)

	-- aftershocks
	if N.quake.Value > 0.1 then
		aftershock -= dt
		if aftershock <= 0 then
			burst += 0.4 + math.random() * 0.6 * N.quake.Value
			aftershock = math.random(6, 16) / (1 + N.quake.Value)
		end
	end

	-- planetary shockwaves
	if pulseEvery > 0 then
		pulseTimer -= dt
		if pulseTimer <= 0 then
			pulseTimer = pulseEvery
			burst += 2.2
			flash(0.55, 2.5)
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
	end
end)

--------------------------------------------------------------------
-- GO
--------------------------------------------------------------------
applyStage(stage, true)
showBanner(stage)
print("[MoonDoom v2] started at stage " .. stage .. " of " .. NSTAGES .. " - new stage every " .. CONFIG.StageLength .. "s")
