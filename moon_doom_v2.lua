import sys

def tabify(s):
    out = []
    for line in s.split("\n"):
        n = len(line) - len(line.lstrip(" "))
        out.append("\t" * (n // 4) + " " * (n % 4) + line.lstrip(" "))
    return "\n".join(out)

SRC = "/mnt/user-data/outputs/moon_doom_v5.lua"
DST = "/mnt/user-data/outputs/moon_doom_v6.lua"
src = open(SRC, encoding="utf-8").read()

def rep(old, new, count=1, raw=False):
    global src
    if not raw:
        old = tabify(old); new = tabify(new)
    c = src.count(old)
    if c != count:
        print("MISMATCH (%d found, wanted %d) for: %r" % (c, count, old[:110])); sys.exit(1)
    src = src.replace(old, new)

# ------------------------------------------------------------------ labels
rep("MOON COLLISION v5", "MOON COLLISION v6", raw=True)
rep('print("[MoonDoom v5] started', 'print("[MoonDoom v6] started', raw=True)

# ------------------------------------------------------------------ remove the annoying quake tumble
rep("if q > 0.6 and hum.FloorMaterial ~= Enum.Material.Air and math.random() < (q - 0.6) * 0.07 then stumble() end", "-- (quake tumble removed)", raw=True)

# ------------------------------------------------------------------ remove the whole old survival layer (pallets / ramps / old menu / old mining)
start_marker = "--------------------------------------------------------------------\n-- SURVIVAL: trees -> wood -> pallets -> shelter  (+ extra world details)\n"
end_marker = "--------------------------------------------------------------------\n-- APPLY A STAGE (+ the two big scripted sequences)\n"
assert src.count(start_marker) == 1, "start marker"
assert src.count(end_marker) == 1, "end marker"
a = src.index(start_marker)
b = src.index(end_marker)
assert a < b
src = src[:a] + "@@NEWLAYER@@\n" + src[b:]

# ------------------------------------------------------------------ forward declarations / folders (part 2 start)
rep("local onWave, structDamage, onStage, survivalCleanup, majorShock, restoreMined\nlocal tsuShake = 0\n",
    "local onWave, structDamage, onStage, survivalCleanup, majorShock, restoreMined\nlocal tsuShake = 0\nlocal SV = {}\n", raw=True)
rep("track(mineFolder)", '''track(mineFolder)
local function mkFolder(name)
    local f = Instance.new("Folder")
    f.Name = name
    f.Parent = Workspace
    track(f)
    return f
end
local treesFolder = mkFolder("DoomTrees")
local coreFolder = mkFolder("DoomCore")
local animalFolder = mkFolder("DoomAnimals")
local dropFolder = mkFolder("DoomDrops")''')
rep("overlap.FilterDescendantsInstances = {lp.Character, fx, buildFolder, mineFolder}",
    "overlap.FilterDescendantsInstances = {lp.Character, fx, buildFolder, mineFolder, treesFolder, coreFolder, animalFolder, dropFolder}", count=2, raw=True)

# ------------------------------------------------------------------ core impact hook
rep("if structDamage then structDamage(nil, nil, 45) end", "if structDamage then structDamage(nil, nil, 45) end\n    if SV.onImpact then SV.onImpact() end", raw=True)

# ------------------------------------------------------------------ the new layer
PART3 = r'''
--------------------------------------------------------------------
-- PART 3: items, Minecraft-style hotbar + inventory + crafting, blocks,
--         voxel trees, animals + meat, furnace
--------------------------------------------------------------------
local function __part3()

local UIS = game:GetService("UserInputService")
local CELL = 4
local PANEL, SLOTBG, DARKTXT = C(198, 198, 198), C(139, 139, 139), C(45, 45, 45)

local ITEMS = {
    log = {name = "Log", abbr = "LOG", col = C(110, 75, 45), block = true},
    planks = {name = "Planks", abbr = "PLK", col = C(172, 128, 76), block = true},
    stone = {name = "Stone", abbr = "STN", col = C(125, 125, 132), block = true},
    furnace = {name = "Furnace", abbr = "FUR", col = C(88, 88, 94), block = true},
    stick = {name = "Stick", abbr = "STK", col = C(140, 105, 62)},
    pickaxe = {name = "Pickaxe", abbr = "PIC", col = C(150, 156, 168), tool = true},
    raw_meat = {name = "Raw Meat", abbr = "RAW", col = C(205, 95, 95), food = 4},
    cooked_meat = {name = "Steak", abbr = "CKD", col = C(135, 72, 42), food = 30},
}
local BLOCK = {
    log = {mat = Enum.Material.Wood, col = C(110, 75, 45), hp = 140},
    planks = {mat = Enum.Material.WoodPlanks, col = C(172, 128, 76), hp = 100},
    stone = {mat = Enum.Material.Cobblestone, col = C(125, 125, 132), hp = 400},
    furnace = {mat = Enum.Material.Cobblestone, col = C(88, 88, 94), hp = 300},
    leaf = {mat = Enum.Material.Grass, col = C(70, 140, 60), hp = 20},
    core = {mat = Enum.Material.Slate, col = C(40, 36, 42), hp = 1000},
}
-- seconds to break each kind of block (logs take 3 seconds like you asked)
local BTIME = {leaf = 0.35, log = 3.0, planks = 1.5, stone = 1.4, furnace = 1.6, core = 2.5, terrain = 1.4, ground = 1.4}
local NEEDPICK = {stone = true, furnace = true, core = true, terrain = true, ground = true}
local RECIPES = {
    {cost = {{"log", 1}}, out = {"planks", 4}},
    {cost = {{"planks", 2}}, out = {"stick", 4}},
    {cost = {{"planks", 3}, {"stick", 2}}, out = {"pickaxe", 1}},
    {cost = {{"stone", 5}}, out = {"furnace", 1}},
}

local inv = {}
for i = 1, 36 do inv[i] = false end
local sel, invOpen, moveFrom = 1, false, nil
local refreshUI, openFurnace, toggleInv

local blockInfo = setmetatable({}, {__mode = "k"})
local furnaceOf = setmetatable({}, {__mode = "k"})
local animalOf = setmetatable({}, {__mode = "k"})
local blocks, trees, animals, drops = {}, {}, {}, {}
local minedOrig, minedTerrain = {}, {}
local lastBurnMsg = 0
local holding = false
local lastHit, lastNeedMsg = 0, 0
local brk = {key = nil, t = 0}

local ROCKY = {}
for _, n in ipairs({"Rock", "Slate", "Basalt", "Limestone", "Granite", "Sandstone", "Concrete", "Brick", "Cobblestone", "Marble", "Pavement", "Asphalt", "CrackedLava", "Salt", "Pebble"}) do
    local ok, m = pcall(function() return Enum.Material[n] end)
    if ok and m then ROCKY[m] = true end
end

---------------- inventory logic ----------------
local function countItem(id)
    local n = 0
    for i = 1, 36 do
        local s = inv[i]
        if s and s.id == id then n += s.n end
    end
    return n
end

local function takeItem(id, n)
    if countItem(id) < n then return false end
    for i = 1, 36 do
        local s = inv[i]
        if s and s.id == id then
            local t = math.min(n, s.n)
            s.n -= t
            n -= t
            if s.n <= 0 then inv[i] = false end
            if n <= 0 then break end
        end
    end
    return true
end

local function addItem(id, n)
    local maxn = ITEMS[id].tool and 1 or 64
    for i = 1, 36 do
        local s = inv[i]
        if s and s.id == id and s.n < maxn then
            local add = math.min(n, maxn - s.n)
            s.n += add
            n -= add
            if n <= 0 then return 0 end
        end
    end
    for i = 1, 36 do
        if not inv[i] then
            local add = math.min(n, maxn)
            inv[i] = {id = id, n = add}
            n -= add
            if n <= 0 then return 0 end
        end
    end
    return n
end

local function hasPickSelected()
    local s = inv[sel]
    return s and s.id == "pickaxe"
end

---------------- dropped items ----------------
local function dropItem(id, n, pos)
    local d = ITEMS[id]
    if not d or n <= 0 then return end
    local p = mkPart(Vector3.new(1.4, 1.4, 1.4), CFrame.new(pos), Enum.Material.SmoothPlastic, d.col)
    p.Parent = dropFolder
    local ang, r = math.random() * math.pi * 2, math.random() * 3
    local lx, lz = pos.X + math.cos(ang) * r, pos.Z + math.sin(ang) * r
    local hit = Workspace:Raycast(Vector3.new(lx, pos.Y + 3, lz), Vector3.new(0, -80, 0), rayP())
    local ly = hit and (hit.Position.Y + 1) or pos.Y
    drops[#drops + 1] = {part = p, id = id, n = n, born = os.clock(), from = pos, to = Vector3.new(lx, ly, lz), spin = math.random() * 6}
end

local function dropsStep(t, rp)
    for i = #drops, 1, -1 do
        local d = drops[i]
        local age = os.clock() - d.born
        local remove = false
        if not d.part.Parent or age > 300 then
            remove = true
        else
            local pos
            if age < 0.5 then
                local k = age / 0.5
                pos = d.from:Lerp(d.to, k) + Vector3.new(0, math.sin(k * math.pi) * 3, 0)
            else
                pos = d.to + Vector3.new(0, 0.4 + math.sin(t * 3 + d.spin) * 0.3, 0)
                if (pos - rp).Magnitude < 6 then
                    local before = d.n
                    local left = addItem(d.id, d.n)
                    if left < before then
                        toast("+" .. (before - left) .. " " .. ITEMS[d.id].name, C(235, 235, 235), 1.2)
                        oneShot(SND.pop, 0.5, 1.6, 0)
                        refreshUI()
                    end
                    d.n = left
                    if left <= 0 then remove = true end
                end
            end
            d.part.CFrame = CFrame.new(pos) * CFrame.Angles(0, t * 2 + d.spin, 0)
        end
        if remove then
            pcall(function() d.part:Destroy() end)
            table.remove(drops, i)
        end
    end
end

---------------- carving blocks out of the world ----------------
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

-- cut a box (given in the part's local space) out of a block part
local function subtractLocal(src, a, b, mx)
    local boxes = {}
    local function add(x0, y0, z0, x1, y1, z1) boxes[#boxes + 1] = {Vector3.new(x0, y0, z0), Vector3.new(x1, y1, z1)} end
    if a.X > -mx.X then add(-mx.X, -mx.Y, -mx.Z, a.X, mx.Y, mx.Z) end
    if b.X < mx.X then add(b.X, -mx.Y, -mx.Z, mx.X, mx.Y, mx.Z) end
    if a.Y > -mx.Y then add(a.X, -mx.Y, -mx.Z, b.X, a.Y, mx.Z) end
    if b.Y < mx.Y then add(a.X, b.Y, -mx.Z, b.X, mx.Y, mx.Z) end
    if a.Z > -mx.Z then add(a.X, a.Y, -mx.Z, b.X, b.Y, a.Z) end
    if b.Z < mx.Z then add(a.X, a.Y, b.Z, b.X, b.Y, mx.Z) end
    local made = {}
    for _, bx in ipairs(boxes) do
        local cl = makePiece(src, bx[1], bx[2])
        if cl == false then
            for _, m in ipairs(made) do pcall(function() m:Destroy() end) end
            return false
        end
        if cl then made[#made + 1] = cl end
    end
    hideOrig(src)
    return true
end

-- cut a world-space box out of a block part (the part must be axis aligned)
local function subtractBox(src, wmin, wmax)
    local invcf = src.CFrame:Inverse()
    local lmn = Vector3.new(1e9, 1e9, 1e9)
    local lmx = Vector3.new(-1e9, -1e9, -1e9)
    for _, x in ipairs({wmin.X, wmax.X}) do
        for _, y in ipairs({wmin.Y, wmax.Y}) do
            for _, z in ipairs({wmin.Z, wmax.Z}) do
                local l = invcf * Vector3.new(x, y, z)
                lmn = lmn:Min(l)
                lmx = lmx:Max(l)
            end
        end
    end
    local mx = src.Size / 2
    local a = lmn:Max(-mx)
    local b = lmx:Min(mx)
    if b.X - a.X < 0.05 or b.Y - a.Y < 0.05 or b.Z - a.Z < 0.05 then return false end
    return subtractLocal(src, a, b, mx)
end

local function carve(inst, res)
    local x0, x1, y0, y1, z0, z1, mx = cellOf(inst, res.Position - res.Normal * 0.3)
    if x1 - x0 < 0.01 or y1 - y0 < 0.01 or z1 - z0 < 0.01 then return false end
    return subtractLocal(inst, Vector3.new(x0, y0, z0), Vector3.new(x1, y1, z1), mx)
end

local function mineTerrain(res)
    if not Terrain then return false end
    local p = res.Position - res.Normal * 2
    local c = Vector3.new(math.floor(p.X / CELL) * CELL + CELL / 2, math.floor(p.Y / CELL) * CELL + CELL / 2, math.floor(p.Z / CELL) * CELL + CELL / 2)
    local ok = pcall(function() Terrain:FillBlock(CFrame.new(c), Vector3.new(CELL, CELL, CELL), Enum.Material.Air) end)
    if ok and #minedTerrain < 600 then minedTerrain[#minedTerrain + 1] = {c = c, mat = res.Material} end
    return ok
end

---------------- block parts, trees ----------------
local function newBlock(pos, kind, parent)
    local d = BLOCK[kind]
    local p = Instance.new("Part")
    p.Anchored = true
    p.CanCollide = true
    p.CanQuery = true
    p.CanTouch = false
    p.Size = Vector3.new(CELL, CELL, CELL)
    p.Material = d.mat
    if kind == "leaf" then
        p.Color = C(math.random(55, 80), math.random(125, 160), math.random(50, 70))
    else
        p.Color = d.col
    end
    p.CFrame = CFrame.new(pos)
    p.Parent = parent
    return p
end

local function makeTree(x, z)
    local cx = math.floor(x / CELL) * CELL + CELL / 2
    local cz = math.floor(z / CELL) * CELL + CELL / 2
    local hit = Workspace:Raycast(Vector3.new(cx, baseY + 300, cz), Vector3.new(0, -800, 0), rayP())
    if not hit then return false end
    local inst = hit.Instance
    if not (inst:IsA("Terrain") or (inst.Size.X >= 60 and inst.Size.Z >= 60)) then return false end
    local surf = surfaceY()
    if surf and hit.Position.Y < surf then return false end
    local gy = hit.Position.Y
    local H = math.random(4, 6)
    local rec = {parts = {}}
    local function add(dx, k, dz, kind)
        local pos = Vector3.new(cx + dx * CELL, gy + CELL / 2 + k * CELL, cz + dz * CELL)
        local p = newBlock(pos, kind, treesFolder)
        blockInfo[p] = {part = p, kind = kind, tree = rec}
        rec.parts[#rec.parts + 1] = p
    end
    for k = 0, H - 1 do add(0, k, 0, "log") end
    for k = H - 2, H - 1 do
        add(1, k, 0, "leaf")
        add(-1, k, 0, "leaf")
        add(0, k, 1, "leaf")
        add(0, k, -1, "leaf")
    end
    add(0, H, 0, "leaf")
    add(1, H, 0, "leaf")
    add(-1, H, 0, "leaf")
    add(0, H, 1, "leaf")
    add(0, H, -1, "leaf")
    trees[#trees + 1] = rec
    return true
end

local function randomAround()
    local root = getRoot()
    local around = (math.random() < 0.5 or not root) and startPos or root.Position
    local ang, dist = math.random() * math.pi * 2, math.random(25, 330)
    return around.X + math.cos(ang) * dist, around.Z + math.sin(ang) * dist
end

local function burnTrees()
    for _, rec in ipairs(trees) do
        for k, p in ipairs(rec.parts) do
            if p.Parent then
                if k % 3 == 0 then
                    pcall(function()
                        local f = Instance.new("Fire")
                        f.Size = 10
                        f.Heat = 12
                        f.Parent = p
                    end)
                end
                task.delay(3 + math.random() * 6, function() pcall(function() p:Destroy() end) end)
            end
        end
    end
    trees = {}
end

---------------- placed blocks: damage / wear ----------------
local function removeBlockRec(rec)
    for i, r in ipairs(blocks) do
        if r == rec then table.remove(blocks, i) break end
    end
    furnaceOf[rec.part] = nil
end

local function hurtBlock(rec, dmg)
    rec.hp -= dmg
    if rec.hp <= 0 then
        removeBlockRec(rec)
        blockInfo[rec.part] = nil
        pcall(function() rec.part:Destroy() end)
        if os.clock() - lastBurnMsg > 6 then
            lastBurnMsg = os.clock()
            toast("A shelter block was destroyed - repair it!", C(255, 150, 110), 3)
        end
    else
        rec.part.Color = BLOCK[rec.kind].col:Lerp(C(25, 20, 18), 1 - rec.hp / rec.maxhp)
    end
end

structDamage = function(pos, radius, dmg)
    for i = #blocks, 1, -1 do
        local r = blocks[i]
        if r and r.part.Parent and (not pos or (r.part.Position - pos).Magnitude <= radius) then hurtBlock(r, dmg) end
    end
end

onWave = function(w, front)
    w.hitBlocks = w.hitBlocks or {}
    for i = #blocks, 1, -1 do
        local r = blocks[i]
        if r and not w.hitBlocks[r] and r.part.Parent then
            local rel = r.part.Position - front
            local flat = Vector3.new(rel.X, 0, rel.Z)
            local al = flat:Dot(w.dir)
            if al > -30 and al < 30 and math.abs(flat:Dot(w.right)) < w.width / 2 and r.part.Position.Y < baseY + w.h * 0.7 then
                w.hitBlocks[r] = true
                hurtBlock(r, 45)
            end
        end
    end
end

local WEAR = {[12] = 0.35, [13] = 0.5, [14] = 0.8, [15] = 0.8, [16] = 3.0, [17] = 0.6, [18] = 0.8, [19] = 1.5}
local WEARMUL = {log = 0.8, planks = 1, stone = 0.15, furnace = 0.2}
local function wearTick()
    local rate = WEAR[stage] or 0
    if rate <= 0 or #blocks == 0 then return end
    local rpar = rayP()
    for i = #blocks, 1, -1 do
        local r = blocks[i]
        if r and r.part.Parent then
            local top = r.part.Position + Vector3.new(0, CELL / 2 + 0.2, 0)
            local exposed = not Workspace:Raycast(top, Vector3.new(0, 200, 0), rpar)
            hurtBlock(r, rate * (exposed and 1 or 0.12) * (WEARMUL[r.kind] or 1) * (0.7 + math.random() * 0.6))
        end
    end
end

---------------- animals ----------------
local ANIMALS = {
    chicken = {hp = 2, meat = 1, speed = 5},
    pig = {hp = 3, meat = 2, speed = 4},
    cow = {hp = 5, meat = 3, speed = 3.5},
}

local function buildAnimal(kind, pos)
    local d = ANIMALS[kind]
    local a = {kind = kind, hp = d.hp, parts = {}, pos = pos, gy = pos.Y, heading = math.random() * 6.28, speed = d.speed,
        t = 0, moving = false, fleeUntil = 0, flashUntil = 0, gT = 0}
    local function add(size, rel, col)
        local p = mkPart(size, CFrame.new(), Enum.Material.SmoothPlastic, col)
        p.CanQuery = true
        p.Parent = animalFolder
        animalOf[p] = a
        a.parts[#a.parts + 1] = {part = p, rel = rel, col = col}
    end
    if kind == "chicken" then
        add(Vector3.new(1.6, 1.6, 2.2), CFrame.new(0, 1.6, 0), C(245, 245, 240))
        add(Vector3.new(1, 1.1, 1), CFrame.new(0, 2.7, -1.3), C(245, 245, 240))
        add(Vector3.new(0.4, 0.4, 0.8), CFrame.new(0, 2.6, -2.0), C(240, 170, 40))
        add(Vector3.new(0.3, 0.5, 0.5), CFrame.new(0, 3.4, -1.3), C(210, 40, 40))
        add(Vector3.new(0.3, 1, 0.3), CFrame.new(-0.4, 0.5, 0.2), C(240, 170, 40))
        add(Vector3.new(0.3, 1, 0.3), CFrame.new(0.4, 0.5, 0.2), C(240, 170, 40))
    elseif kind == "pig" then
        add(Vector3.new(2.6, 2.4, 4), CFrame.new(0, 2.3, 0), C(240, 170, 170))
        add(Vector3.new(2, 1.8, 1.8), CFrame.new(0, 2.8, -2.7), C(240, 170, 170))
        add(Vector3.new(1, 0.8, 0.5), CFrame.new(0, 2.5, -3.7), C(220, 130, 130))
        for _, lx in ipairs({-0.9, 0.9}) do
            for _, lz in ipairs({-1.4, 1.4}) do
                add(Vector3.new(0.8, 1.2, 0.8), CFrame.new(lx, 0.6, lz), C(225, 150, 150))
            end
        end
    else
        add(Vector3.new(3, 3, 5.4), CFrame.new(0, 3.6, 0), C(245, 245, 245))
        add(Vector3.new(3.05, 1.6, 2), CFrame.new(0, 4, 0.8), C(40, 35, 35))
        add(Vector3.new(2.2, 2.2, 2), CFrame.new(0, 4.3, -3.6), C(245, 245, 245))
        add(Vector3.new(1.2, 0.8, 0.6), CFrame.new(0, 3.9, -4.7), C(215, 160, 150))
        for _, lx in ipairs({-1, 1}) do
            for _, lz in ipairs({-1.9, 1.9}) do
                add(Vector3.new(1, 2.2, 1), CFrame.new(lx, 1.1, lz), C(235, 235, 235))
            end
        end
    end
    animals[#animals + 1] = a
    return a
end

local function removeAnimal(a, idx)
    for _, pr in ipairs(a.parts) do
        animalOf[pr.part] = nil
        pcall(function() pr.part:Destroy() end)
    end
    table.remove(animals, idx)
end

local function spawnAnimal()
    local root = getRoot()
    if not root or #animals >= 10 then return end
    local ang, dist = math.random() * math.pi * 2, math.random(40, 150)
    local x, z = root.Position.X + math.cos(ang) * dist, root.Position.Z + math.sin(ang) * dist
    local hit = Workspace:Raycast(Vector3.new(x, root.Position.Y + 60, z), Vector3.new(0, -300, 0), rayP())
    if not hit then return end
    local inst = hit.Instance
    if not (inst:IsA("Terrain") or (inst.Size.X >= 40 and inst.Size.Z >= 40)) then return end
    local surf = surfaceY()
    if surf and hit.Position.Y < surf then return end
    local r = math.random()
    buildAnimal((r < 0.4) and "chicken" or ((r < 0.75) and "pig" or "cow"), hit.Position)
end

local function killAnimal(a)
    local d = ANIMALS[a.kind]
    dropItem("raw_meat", d.meat, Vector3.new(a.pos.X, a.gy + 2, a.pos.Z))
    for i, x in ipairs(animals) do
        if x == a then removeAnimal(a, i) break end
    end
end

local function hitAnimal(a)
    a.hp -= 1
    local root = getRoot()
    if root then
        local away = Vector3.new(a.pos.X - root.Position.X, 0, a.pos.Z - root.Position.Z)
        if away.Magnitude < 0.1 then away = Vector3.xAxis end
        away = away.Unit
        a.heading = math.atan2(away.X, away.Z)
        a.pos = a.pos + away * 2.5
    end
    a.fleeUntil = os.clock() + 3.5
    a.flashUntil = os.clock() + 0.18
    oneShot(SND.oof, 0.5, 1.4, 0)
    if a.hp <= 0 then killAnimal(a) end
end

local function animalStep(dt, rp)
    local now = os.clock()
    for i = #animals, 1, -1 do
        local a = animals[i]
        if (a.pos - rp).Magnitude > 450 or stage >= 11 then
            removeAnimal(a, i)
        else
            a.t -= dt
            if a.t <= 0 then
                a.t = 2 + math.random() * 4
                a.moving = math.random() < 0.65
                a.heading += (math.random() - 0.5) * 2.5
            end
            local fleeing = now < a.fleeUntil
            if fleeing or a.moving then
                local sp = fleeing and a.speed * 2.3 or a.speed
                a.pos = a.pos + Vector3.new(math.sin(a.heading), 0, math.cos(a.heading)) * sp * dt
            end
            a.gT -= dt
            if a.gT <= 0 then
                a.gT = 0.3
                local rp2 = RaycastParams.new()
                rp2.FilterType = Enum.RaycastFilterType.Exclude
                rp2.FilterDescendantsInstances = {lp.Character, fx, animalFolder, dropFolder}
                local hit = Workspace:Raycast(Vector3.new(a.pos.X, a.gy + 25, a.pos.Z), Vector3.new(0, -80, 0), rp2)
                local surf = surfaceY()
                if hit and not (surf and hit.Position.Y < surf - 0.5) then
                    a.gy = hit.Position.Y
                else
                    a.heading += math.pi
                    a.pos = a.pos + Vector3.new(math.sin(a.heading), 0, math.cos(a.heading)) * 2
                end
            end
            local p3 = Vector3.new(a.pos.X, a.gy, a.pos.Z)
            local fwd = Vector3.new(math.sin(a.heading), 0, math.cos(a.heading))
            local base = CFrame.lookAt(p3, p3 + fwd)
            local flash = now < a.flashUntil
            for _, pr in ipairs(a.parts) do
                pr.part.CFrame = base * pr.rel
                pr.part.Color = flash and C(230, 60, 60) or pr.col
            end
        end
    end
end

---------------- furnace logic ----------------
local function furnaceStep(dt)
    for part, f in pairs(furnaceOf) do
        if part.Parent then
            local cooking = f.input > 0 and f.burn > 0
            if cooking then
                f.prog += dt
                f.burn -= dt
                if f.prog >= 5 then
                    f.prog = 0
                    f.input -= 1
                    f.output += 1
                end
            end
            if f.light then f.light.Enabled = cooking end
        end
    end
end

---------------- Minecraft style GUI ----------------
local SLOT = 34
local function slotButton(parent, x, y)
    local b = mk("TextButton", {Position = UDim2.new(0, x, 0, y), Size = UDim2.new(0, SLOT, 0, SLOT), BackgroundColor3 = SLOTBG,
        BorderSizePixel = 0, Text = "", AutoButtonColor = false, ZIndex = 13}, parent)
    local stroke = mk("UIStroke", {Color = C(25, 25, 28), Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, b)
    local icon = mk("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0), Size = UDim2.new(0, SLOT - 12, 0, SLOT - 12),
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 14}, b)
    local label = mk("TextLabel", {Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", Font = Enum.Font.Arcade, TextSize = 10,
        TextColor3 = Color3.new(1, 1, 1), TextStrokeTransparency = 0.3, ZIndex = 15}, icon)
    local cnt = mk("TextLabel", {AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -1, 1, 0), Size = UDim2.new(0, 26, 0, 14), BackgroundTransparency = 1,
        Text = "", Font = Enum.Font.Arcade, TextSize = 13, TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Right,
        TextStrokeTransparency = 0.2, ZIndex = 16}, b)
    return {btn = b, stroke = stroke, icon = icon, label = label, cnt = cnt}
end

local hotbar = mk("Frame", {AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.new(0, 9 * SLOT + 8 * 3 + 10, 0, SLOT + 10),
    BackgroundColor3 = C(35, 35, 40), BackgroundTransparency = 0.2, BorderSizePixel = 0, ZIndex = 12}, gui)
mk("UIStroke", {Color = C(15, 15, 18), Thickness = 3}, hotbar)
local hotUI, gridUI = {}, {}
for i = 1, 9 do hotUI[i] = slotButton(hotbar, 5 + (i - 1) * (SLOT + 3), 5) end

local selLabel = mk("TextLabel", {AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -56), Size = UDim2.new(0, 220, 0, 18), BackgroundTransparency = 1,
    Text = "", Font = Enum.Font.Arcade, TextSize = 16, TextColor3 = Color3.new(1, 1, 1), TextStrokeTransparency = 0.2, TextTransparency = 1, ZIndex = 12}, gui)
local selTok = 0
local function showSelName()
    selTok += 1
    local tk = selTok
    local s = inv[sel]
    selLabel.Text = s and ITEMS[s.id].name or ""
    selLabel.TextTransparency = 0
    selLabel.TextStrokeTransparency = 0.2
    task.delay(1.6, function()
        if running and tk == selTok then tw(selLabel, {TextTransparency = 1, TextStrokeTransparency = 1}, 0.6) end
    end)
end

local invPanel = mk("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.44, 0), Size = UDim2.new(0, 9 * SLOT + 8 * 3 + 20, 0, 284),
    BackgroundColor3 = PANEL, BorderSizePixel = 0, Visible = false, ZIndex = 12}, gui)
mk("UIStroke", {Color = C(20, 20, 20), Thickness = 3}, invPanel)
local function panelLabel(parent, text, x, y, w)
    return mk("TextLabel", {Position = UDim2.new(0, x, 0, y), Size = UDim2.new(0, w or 200, 0, 16), BackgroundTransparency = 1, Text = text,
        Font = Enum.Font.Arcade, TextSize = 14, TextColor3 = DARKTXT, TextXAlignment = Enum.TextXAlignment.Left, ZIndex = 13}, parent)
end
panelLabel(invPanel, "Inventory", 10, 4)
panelLabel(invPanel, "Crafting", 10, 24)
local recipeList = mk("ScrollingFrame", {Position = UDim2.new(0, 10, 0, 42), Size = UDim2.new(1, -20, 0, 100), BackgroundColor3 = SLOTBG, BorderSizePixel = 0,
    CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 4, ZIndex = 13}, invPanel)
mk("UIListLayout", {Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder}, recipeList)
mk("UIPadding", {PaddingLeft = UDim.new(0, 3), PaddingTop = UDim.new(0, 3), PaddingRight = UDim.new(0, 3)}, recipeList)
panelLabel(invPanel, "Backpack", 10, 148)
for i = 10, 36 do
    local r, c = (i - 10) // 9, (i - 10) % 9
    gridUI[i] = slotButton(invPanel, 10 + c * (SLOT + 3), 166 + r * (SLOT + 3))
end

local function recipeText(r)
    local parts = {}
    for _, c in ipairs(r.cost) do parts[#parts + 1] = c[2] .. " " .. ITEMS[c[1]].name end
    return table.concat(parts, " + ") .. "  >  " .. r.out[2] .. " " .. ITEMS[r.out[1]].name
end
local recipeBtns = {}
local function canCraft(r)
    for _, c in ipairs(r.cost) do
        if countItem(c[1]) < c[2] then return false end
    end
    return true
end
local function craft(r)
    if not canCraft(r) then toast("Missing ingredients for " .. ITEMS[r.out[1]].name, C(255, 200, 120), 1.6) return end
    for _, c in ipairs(r.cost) do takeItem(c[1], c[2]) end
    local left = addItem(r.out[1], r.out[2])
    if left > 0 then
        local root = getRoot()
        if root then dropItem(r.out[1], left, root.Position + Vector3.new(0, 2, 0)) end
    end
    oneShot(SND.pop, 0.7, 0.9, 0)
    refreshUI()
end
for idx, r in ipairs(RECIPES) do
    local b = mk("TextButton", {Size = UDim2.new(1, -6, 0, 22), BackgroundColor3 = C(170, 170, 170), BorderSizePixel = 0, Text = recipeText(r),
        Font = Enum.Font.Arcade, TextSize = 13, TextColor3 = DARKTXT, AutoButtonColor = true, ZIndex = 14, LayoutOrder = idx}, recipeList)
    mk("UIStroke", {Color = C(60, 60, 60), Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, b)
    connect(b.Activated, function() craft(r) end)
    recipeBtns[idx] = {btn = b, r = r}
end
local closeInv = mk("TextButton", {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 4), Size = UDim2.new(0, 22, 0, 18), BackgroundColor3 = C(170, 60, 60),
    BorderSizePixel = 0, Text = "X", Font = Enum.Font.Arcade, TextSize = 14, TextColor3 = Color3.new(1, 1, 1), ZIndex = 14}, invPanel)

local function slotUI(i) return (i <= 9) and hotUI[i] or gridUI[i] end
local function paintSlot(u, s)
    if s then
        local d = ITEMS[s.id]
        u.icon.Visible = true
        u.icon.BackgroundColor3 = d.col
        u.label.Text = d.abbr
        u.cnt.Text = s.n > 1 and tostring(s.n) or ""
    else
        u.icon.Visible = false
        u.cnt.Text = ""
    end
end

refreshUI = function()
    for i = 1, 9 do
        paintSlot(hotUI[i], inv[i])
        local isSel = (i == sel)
        hotUI[i].stroke.Color = (moveFrom == i) and C(255, 220, 60) or (isSel and Color3.new(1, 1, 1) or C(25, 25, 28))
        hotUI[i].stroke.Thickness = isSel and 3 or 2
    end
    if invOpen then
        for i = 10, 36 do
            paintSlot(gridUI[i], inv[i])
            gridUI[i].stroke.Color = (moveFrom == i) and C(255, 220, 60) or C(25, 25, 28)
        end
        for _, rb in ipairs(recipeBtns) do
            rb.btn.BackgroundColor3 = canCraft(rb.r) and C(150, 200, 150) or C(170, 170, 170)
        end
    end
end

local function onSlot(i)
    if invOpen then
        if moveFrom == nil then
            if inv[i] then moveFrom = i end
        else
            if moveFrom ~= i then
                local a, b = inv[moveFrom], inv[i]
                if a and b and a.id == b.id and not ITEMS[a.id].tool then
                    local mv = math.min(a.n, 64 - b.n)
                    b.n += mv
                    a.n -= mv
                    if a.n <= 0 then inv[moveFrom] = false end
                else
                    inv[moveFrom], inv[i] = b, a
                end
            end
            moveFrom = nil
        end
    elseif i <= 9 then
        sel = i
        showSelName()
    end
    refreshUI()
end
for i = 1, 9 do connect(hotUI[i].btn.Activated, function() onSlot(i) end) end
for i = 10, 36 do connect(gridUI[i].btn.Activated, function() onSlot(i) end) end

-- furnace window
local furOpen, curFurnace = false, nil
local furPanel = mk("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.42, 0), Size = UDim2.new(0, 300, 0, 200),
    BackgroundColor3 = PANEL, BorderSizePixel = 0, Visible = false, ZIndex = 12}, gui)
mk("UIStroke", {Color = C(20, 20, 20), Thickness = 3}, furPanel)
panelLabel(furPanel, "Furnace", 10, 4)
local function bigSlot(x, y, caption)
    local f = mk("Frame", {Position = UDim2.new(0, x, 0, y), Size = UDim2.new(0, 46, 0, 46), BackgroundColor3 = SLOTBG, BorderSizePixel = 0, ZIndex = 13}, furPanel)
    mk("UIStroke", {Color = C(25, 25, 28), Thickness = 2}, f)
    local icon = mk("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0), Size = UDim2.new(0, 30, 0, 30),
        BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, Visible = false, ZIndex = 14}, f)
    local cnt = mk("TextLabel", {AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -2, 1, 0), Size = UDim2.new(0, 40, 0, 14), BackgroundTransparency = 1,
        Text = "", Font = Enum.Font.Arcade, TextSize = 13, TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Right,
        TextStrokeTransparency = 0.2, ZIndex = 16}, f)
    mk("TextLabel", {Position = UDim2.new(0, x - 6, 0, y + 48), Size = UDim2.new(0, 58, 0, 14), BackgroundTransparency = 1, Text = caption, Font = Enum.Font.Arcade,
        TextSize = 11, TextColor3 = DARKTXT, ZIndex = 13}, furPanel)
    return {icon = icon, cnt = cnt}
end
local furIn = bigSlot(40, 30, "INPUT")
local furFuel = bigSlot(40, 100, "FUEL")
local furOut = bigSlot(214, 64, "OUTPUT")
local furBarBg = mk("Frame", {Position = UDim2.new(0, 100, 0, 78), Size = UDim2.new(0, 100, 0, 14), BackgroundColor3 = C(100, 100, 100), BorderSizePixel = 0, ZIndex = 13}, furPanel)
local furBar = mk("Frame", {Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C(255, 190, 60), BorderSizePixel = 0, ZIndex = 14}, furBarBg)
local function furButton(text, x, cb)
    local b = mk("TextButton", {Position = UDim2.new(0, x, 0, 164), Size = UDim2.new(0, 66, 0, 26), BackgroundColor3 = C(170, 170, 170), BorderSizePixel = 0,
        Text = text, Font = Enum.Font.Arcade, TextSize = 12, TextColor3 = DARKTXT, ZIndex = 14}, furPanel)
    mk("UIStroke", {Color = C(60, 60, 60), Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, b)
    connect(b.Activated, cb)
    return b
end
local function refreshFurnace()
    local f = curFurnace
    if not f then return end
    furIn.icon.Visible = f.input > 0
    furIn.icon.BackgroundColor3 = ITEMS.raw_meat.col
    furIn.cnt.Text = f.input > 0 and tostring(f.input) or ""
    furFuel.icon.Visible = f.burn > 0
    furFuel.icon.BackgroundColor3 = C(255, 140, 40)
    furFuel.cnt.Text = f.burn > 0 and (math.floor(f.burn) .. "s") or ""
    furOut.icon.Visible = f.output > 0
    furOut.icon.BackgroundColor3 = ITEMS.cooked_meat.col
    furOut.cnt.Text = f.output > 0 and tostring(f.output) or ""
    furBar.Size = UDim2.new(math.clamp(f.prog / 5, 0, 1), 0, 1, 0)
end
furButton("+ MEAT", 10, function()
    local f = curFurnace
    if not f then return end
    local n = countItem("raw_meat")
    if n <= 0 then toast("You have no raw meat", C(255, 200, 120), 1.5) return end
    takeItem("raw_meat", n)
    f.input += n
    refreshUI()
end)
furButton("+ FUEL", 80, function()
    local f = curFurnace
    if not f then return end
    for _, fu in ipairs({{"stick", 5}, {"planks", 10}, {"log", 15}}) do
        local n = math.min(countItem(fu[1]), 8)
        if n > 0 then
            takeItem(fu[1], n)
            f.burn += fu[2] * n
            refreshUI()
            return
        end
    end
    toast("You need sticks, planks or logs for fuel", C(255, 200, 120), 1.8)
end)
furButton("TAKE", 150, function()
    local f = curFurnace
    if not f or f.output <= 0 then return end
    local before = f.output
    local left = addItem("cooked_meat", f.output)
    f.output = left
    if left < before then toast("+" .. (before - left) .. " Steak", C(235, 235, 235), 1.2) end
    refreshUI()
end)
furButton("CLOSE", 220, function() furOpen = false furPanel.Visible = false end)

openFurnace = function(part)
    local f = furnaceOf[part]
    if not f then return end
    curFurnace = f
    furOpen = true
    furPanel.Visible = true
    invOpen = false
    invPanel.Visible = false
    refreshFurnace()
end

toggleInv = function()
    invOpen = not invOpen
    invPanel.Visible = invOpen
    moveFrom = nil
    if invOpen then furOpen = false furPanel.Visible = false end
    refreshUI()
end
connect(closeInv.Activated, toggleInv)

-- crosshair, break progress, target outline
local cross = mk("Frame", {AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, 0), Size = UDim2.new(0, 6, 0, 6),
    BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0, ZIndex = 9}, gui)
mk("UICorner", {CornerRadius = UDim.new(1, 0)}, cross)
mk("UIStroke", {Color = Color3.new(0, 0, 0), Thickness = 1}, cross)
local progBg = mk("Frame", {AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.5, 20), Size = UDim2.new(0, 70, 0, 7), BackgroundColor3 = C(20, 20, 20),
    BorderSizePixel = 0, Visible = false, ZIndex = 9}, gui)
local progFill = mk("Frame", {Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = C(120, 230, 120), BorderSizePixel = 0, ZIndex = 10}, progBg)
local ghost = mkPart(Vector3.new(4, 4, 4), CFrame.new(0, -500, 0), Enum.Material.Neon, Color3.new(1, 1, 1))
ghost.Transparency = 1
ghost.Parent = fx

---------------- aiming, breaking, placing, using ----------------
local function aim(maxDist)
    local cam = Workspace.CurrentCamera
    local root = getRoot()
    if not cam or not root then return nil end
    local vs = cam.ViewportSize
    local ray = cam:ViewportPointToRay(vs.X / 2, vs.Y / 2)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = {lp.Character, fx}
    rp.IgnoreWater = true
    local res = Workspace:Raycast(ray.Origin, ray.Direction * 100, rp)
    if res and (res.Position - root.Position).Magnitude <= (maxDist or 14) then return res end
    return nil
end

local function classify(res)
    local inst = res.Instance
    local a = animalOf[inst]
    if a then return "animal", a end
    local bi = blockInfo[inst]
    if bi then return bi.kind, bi end
    if inst:IsA("Terrain") then return "terrain", nil end
    return "ground", nil
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

local function stoneYield(mat)
    return ROCKY[mat] and 2 or 1
end

local function finishBreak(res, cls, info)
    local inst = res.Instance
    local pos = res.Position
    if cls == "log" or cls == "leaf" or cls == "planks" or cls == "stone" or cls == "furnace" or cls == "core" then
        local pp = inst.Position
        if info and info.hp then removeBlockRec(info) end
        blockInfo[inst] = nil
        pcall(function() inst:Destroy() end)
        if cls == "log" then dropItem("log", 1, pp)
        elseif cls == "leaf" then
            if math.random() < 0.25 then dropItem("stick", 1, pp) end
        elseif cls == "planks" then dropItem("planks", 1, pp)
        elseif cls == "stone" then dropItem("stone", 1, pp)
        elseif cls == "furnace" then dropItem("furnace", 1, pp)
        else
            dropItem("stone", 90, pp)
            toast("+90 stone from the Moon core!", C(190, 190, 205), 2.5)
        end
    elseif cls == "terrain" then
        if not mineTerrain(res) then return end
        dropItem("stone", stoneYield(res.Material), pos + Vector3.new(0, 1, 0))
    else
        local plain = inst:IsA("Part") and inst.Shape == Enum.PartType.Block and not inst:FindFirstChildOfClass("SpecialMesh")
        if not (plain and carve(inst, res)) then hideOrig(inst) end
        dropItem("stone", stoneYield(res.Material), pos + Vector3.new(0, 1, 0))
    end
    oneShot(SND.pop, 0.9, 0.5, 0)
    mineFx(pos)
end

local function keyFor(res, cls)
    local inst = res.Instance
    if cls == "ground" and inst:IsA("Part") and inst.Shape == Enum.PartType.Block and not inst:FindFirstChildOfClass("SpecialMesh") then
        local x0, x1, y0, y1, z0, z1 = cellOf(inst, res.Position - res.Normal * 0.3)
        return tostring(inst) .. ("|%.1f|%.1f|%.1f"):format(x0, y0, z0)
    elseif cls == "terrain" then
        local p = res.Position - res.Normal * 2
        return ("T|%d|%d|%d"):format(math.floor(p.X / CELL), math.floor(p.Y / CELL), math.floor(p.Z / CELL))
    end
    return tostring(inst)
end

local function updateGhost(res, cls, progress)
    local inst = res.Instance
    ghost.Color = Color3.new(1, 1, 1):Lerp(C(40, 30, 30), progress)
    ghost.Transparency = 0.8 - 0.55 * progress
    if cls == "terrain" then
        local p = res.Position - res.Normal * 2
        ghost.Size = Vector3.new(CELL + 0.1, CELL + 0.1, CELL + 0.1)
        ghost.CFrame = CFrame.new(math.floor(p.X / CELL) * CELL + CELL / 2, math.floor(p.Y / CELL) * CELL + CELL / 2, math.floor(p.Z / CELL) * CELL + CELL / 2)
    elseif cls == "ground" and inst:IsA("Part") and inst.Shape == Enum.PartType.Block and not inst:FindFirstChildOfClass("SpecialMesh") then
        local x0, x1, y0, y1, z0, z1 = cellOf(inst, res.Position - res.Normal * 0.3)
        ghost.Size = Vector3.new(math.max(0.06, x1 - x0 + 0.06), math.max(0.06, y1 - y0 + 0.06), math.max(0.06, z1 - z0 + 0.06))
        ghost.CFrame = inst.CFrame * CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
    elseif inst.Size.Magnitude < 40 then
        ghost.Size = inst.Size + Vector3.new(0.08, 0.08, 0.08)
        ghost.CFrame = inst.CFrame
    else
        ghost.Size = Vector3.new(CELL, CELL, CELL)
        ghost.CFrame = CFrame.new(res.Position - res.Normal * 1)
    end
end

local function breakStep(dt)
    local res = aim(14)
    if not res then
        brk.key = nil
        brk.t = 0
        progBg.Visible = false
        ghost.Transparency = 1
        return
    end
    local cls, info = classify(res)
    if cls == "animal" then
        ghost.Transparency = 1
        progBg.Visible = false
        if holding and os.clock() - lastHit > 0.45 then
            lastHit = os.clock()
            local root = getRoot()
            if root and (info.pos - root.Position).Magnitude <= 9 then hitAnimal(info) end
        end
        return
    end
    local key = keyFor(res, cls)
    if key ~= brk.key then
        brk.key = key
        brk.t = 0
    end
    if not holding then
        brk.t = 0
        progBg.Visible = false
        updateGhost(res, cls, 0)
        return
    end
    if NEEDPICK[cls] and not hasPickSelected() then
        brk.t = 0
        progBg.Visible = false
        updateGhost(res, cls, 0)
        if os.clock() - lastNeedMsg > 2 then
            lastNeedMsg = os.clock()
            toast("Select a pickaxe in your hotbar (craft one: 3 planks + 2 sticks)", C(255, 200, 120), 2)
        end
        return
    end
    brk.t += dt
    local need = BTIME[cls] or 1.5
    local p = math.clamp(brk.t / need, 0, 1)
    progBg.Visible = true
    progFill.Size = UDim2.new(p, 0, 1, 0)
    updateGhost(res, cls, p)
    if brk.t >= need then
        brk.t = 0
        brk.key = nil
        progBg.Visible = false
        finishBreak(res, cls, info)
    end
end

local occ = OverlapParams.new()
occ.FilterType = Enum.RaycastFilterType.Exclude

local function snapC(v) return math.floor(v / CELL) * CELL + CELL / 2 end

local function placeBlock()
    local s = inv[sel]
    if not s or not ITEMS[s.id].block then
        toast("Select a block (log, planks, stone or furnace) to place", C(255, 200, 120), 1.8)
        return
    end
    local res = aim(14)
    local root = getRoot()
    if not res or not root then return end
    local n = res.Normal
    local inst = res.Instance
    local c
    local bi = blockInfo[inst]
    if bi then
        local ax, ay, az = math.abs(n.X), math.abs(n.Y), math.abs(n.Z)
        local d
        if ax >= ay and ax >= az then d = Vector3.new(n.X > 0 and 1 or -1, 0, 0)
        elseif ay >= az then d = Vector3.new(0, n.Y > 0 and 1 or -1, 0)
        else d = Vector3.new(0, 0, n.Z > 0 and 1 or -1) end
        c = inst.Position + d * CELL
    else
        local pt = res.Position + n * (CELL / 2)
        local ax, ay, az = math.abs(n.X), math.abs(n.Y), math.abs(n.Z)
        if ax >= ay and ax >= az then c = Vector3.new(pt.X, snapC(pt.Y), snapC(pt.Z))
        elseif ay >= az then c = Vector3.new(snapC(pt.X), pt.Y, snapC(pt.Z))
        else c = Vector3.new(snapC(pt.X), snapC(pt.Y), pt.Z) end
    end
    local rp = root.Position
    if math.abs(c.X - rp.X) < 3.4 and math.abs(c.Z - rp.Z) < 3.4 and c.Y - 2 < rp.Y + 2.5 and c.Y + 2 > rp.Y - 3.2 then
        toast("You are in the way", C(255, 200, 120), 1.2)
        return
    end
    occ.FilterDescendantsInstances = {lp.Character, fx, dropFolder, animalFolder}
    for _, h in ipairs(Workspace:GetPartBoundsInBox(CFrame.new(c), Vector3.new(3, 3, 3), occ)) do
        if h.CanCollide then
            toast("Something is already there", C(255, 200, 120), 1.2)
            return
        end
    end
    local kind = s.id
    local p = newBlock(c, kind, buildFolder)
    local d = BLOCK[kind]
    local rec = {part = p, kind = kind, hp = d.hp, maxhp = d.hp}
    blockInfo[p] = rec
    blocks[#blocks + 1] = rec
    if kind == "furnace" then
        local light = Instance.new("PointLight")
        light.Color = C(255, 150, 60)
        light.Range = 14
        light.Brightness = 2
        light.Enabled = false
        light.Parent = p
        furnaceOf[p] = {input = 0, output = 0, burn = 0, prog = 0, light = light}
    end
    s.n -= 1
    if s.n <= 0 then inv[sel] = false end
    oneShot(SND.pop, 0.8, 0.6, 0)
    refreshUI()
end

local function useAction()
    local res = aim(14)
    if res then
        local cls, info = classify(res)
        if cls == "furnace" then
            openFurnace(info.part)
            return
        end
    end
    local s = inv[sel]
    if s and ITEMS[s.id].food then
        local hum = getHum()
        if hum and hum.Health > 0 and hum.Health < hum.MaxHealth then
            hum.Health = math.min(hum.MaxHealth, hum.Health + ITEMS[s.id].food)
            s.n -= 1
            if s.n <= 0 then inv[sel] = false end
            oneShot(SND.pop, 0.6, 1.2, 0)
            refreshUI()
        else
            toast("You are not hurt", C(255, 200, 120), 1.2)
        end
    else
        toast("Aim at a furnace to use it, or select food to eat", C(255, 200, 120), 1.5)
    end
end

-- action buttons (right side) + keyboard
local function actBtn(text, y, down, up, click)
    local b = mk("TextButton", {AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, y, 0), Size = UDim2.new(0, 74, 0, 42), BackgroundColor3 = C(70, 70, 76),
        BackgroundTransparency = 0.15, BorderSizePixel = 0, Text = text, Font = Enum.Font.Arcade, TextSize = 15, TextColor3 = Color3.new(1, 1, 1), ZIndex = 12}, gui)
    mk("UIStroke", {Color = C(20, 20, 24), Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, b)
    if down then connect(b.MouseButton1Down, down) end
    if up then
        connect(b.MouseButton1Up, up)
        connect(b.InputEnded, function(i)
            if i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1 then up() end
        end)
    end
    if click then connect(b.Activated, click) end
    return b
end
actBtn("INV", 0.27, nil, nil, toggleInv)
actBtn("BREAK", 0.39, function() holding = true end, function() holding = false end)
actBtn("PLACE", 0.51, nil, nil, placeBlock)
actBtn("USE", 0.63, nil, nil, useAction)

local KEYNUM = {[Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2, [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4, [Enum.KeyCode.Five] = 5,
    [Enum.KeyCode.Six] = 6, [Enum.KeyCode.Seven] = 7, [Enum.KeyCode.Eight] = 8, [Enum.KeyCode.Nine] = 9}
connect(UIS.InputBegan, function(input, gp)
    if gp then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        holding = true
    elseif input.UserInputType == Enum.UserInputType.Keyboard then
        local k = input.KeyCode
        if k == Enum.KeyCode.E then toggleInv()
        elseif k == Enum.KeyCode.Q then placeBlock()
        elseif k == Enum.KeyCode.F then useAction()
        elseif KEYNUM[k] then
            sel = KEYNUM[k]
            showSelName()
            refreshUI()
        end
    end
end)
connect(UIS.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then holding = false end
end)

---------------- main loop of this part ----------------
local treeAcc, animAcc, pruneAcc, wearAcc = 0, 0, 0, 0
local function step(dt)
    local t = os.clock()
    local root = getRoot()
    local rp = root and root.Position or startPos
    breakStep(dt)
    dropsStep(t, rp)
    furnaceStep(dt)
    animalStep(dt, rp)
    if furOpen then refreshFurnace() end

    wearAcc += dt
    if wearAcc > 1 then wearAcc = 0 wearTick() end

    treeAcc += dt
    if treeAcc > 2 then
        treeAcc = 0
        if stage < IMPACT and #trees < 22 then
            local x, z = randomAround()
            makeTree(x, z)
        end
    end
    animAcc += dt
    if animAcc > 5 then
        animAcc = 0
        if stage < 11 then spawnAnimal() end
    end
    pruneAcc += dt
    if pruneAcc > 6 then
        pruneAcc = 0
        for i = #trees, 1, -1 do
            local alive = false
            for _, p in ipairs(trees[i].parts) do
                if p.Parent then alive = true break end
            end
            if not alive then table.remove(trees, i) end
        end
    end
end
connect(RunService.Heartbeat, function(dt)
    local ok, e = pcall(step, dt)
    if not ok then report("inventory/blocks", e) end
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

-- exports for part 4
SV.hideOrig = hideOrig
SV.makePiece = makePiece
SV.subtractBox = subtractBox
SV.minedOrig = minedOrig
SV.blockInfo = blockInfo
SV.newBlock = newBlock
SV.burnTrees = burnTrees
SV.dropItem = dropItem
SV.clearAnimals = function()
    for i = #animals, 1, -1 do removeAnimal(animals[i], i) end
end

-- starting world: trees and animals
if stage < IMPACT then
    for _ = 1, 16 do
        local x, z = randomAround()
        makeTree(x, z)
    end
    for _ = 1, 6 do spawnAnimal() end
end
refreshUI()
showSelName()
task.delay(2, function()
    if running then
        toast("Hold BREAK on a tree log (3 s) - open INV (E) to craft planks, a pickaxe and a furnace. Hunt animals for meat.", C(230, 200, 150), 9)
    end
end)

end
local ok3, e3 = pcall(__part3)
if not ok3 then report("startup (inventory/blocks)", e3) end
'''

PART4 = r'''
--------------------------------------------------------------------
-- PART 4: disasters that touch the ground + extra details
--   real cracks, sinkholes, collapsing buildings, the Moon core + map split,
--   alerts, birds, power cuts, 3D rain clouds / puddles / splashes
--------------------------------------------------------------------
local function __part4()

local CELL = 4

-- emergency broadcasts ------------------------------------------------------
local ALERT = {
    "Normal conditions. Moon visible, clear skies.",
    "Astronomers report the Moon's orbit is drifting. Officials call it a measurement error.",
    "Hurricane watch for every coast. Tides are two meters above normal.",
    "Superstorms active. Evacuate the coasts. Gather wood, stone and food.",
    "Tsunami warning. Seek high ground and build elevated shelters.",
    "TSUNAMI WARNING: waves incoming. Get above the wave height!",
    "Coastlines are gone. Floods are permanent. Stay on high ground.",
    "Magnitude 8 quakes everywhere. The ground is cracking open.",
    "The Moon is breaking apart. Take shelter under thick roofs.",
    "A ring is forming. Debris will fall. Layer your roof.",
    "Meteors across the sky. Do not go outside.",
    "Firestorms burning. Wooden shelters are catching fire - use stone.",
    "Oxygen levels collapsing. Use your reserve sparingly.",
    "IMPACT IMMINENT. Seal your shelter. Roof layers matter.",
    "The Moon's core has buried itself in the earth. The planet is splitting.",
    "Molten rain. Only thick, sealed shelters survive.",
    "Total darkness. Stay sealed in.",
    "Surface cooling. Steam storms rage.",
    "Acid rain. Keep your roof intact.",
    "Skies clearing. If you hear this, you survived.",
}
local alertL = mk("TextLabel", {AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -80), Size = UDim2.new(0, 440, 0, 36),
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
        if SV.burnTrees then
            if i == IMPACT and not instant then task.delay(11, SV.burnTrees) else SV.burnTrees() end
        end
        if SV.clearAnimals then SV.clearAnimals() end
    end
end

-- birds flee before the disaster -------------------------------------------
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

-- power grid failure -------------------------------------------------------
local lightRecs, lightCount = {}, 0
local function scanLights()
    local root = getRoot()
    if not root then return end
    overlap.FilterDescendantsInstances = {lp.Character, fx, buildFolder, mineFolder, treesFolder, coreFolder, animalFolder, dropFolder}
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

-- dust when the ground shakes ---------------------------------------------
local puffPart = mkPart(Vector3.new(30, 0.2, 30), CFrame.new())
puffPart.Transparency = 1
puffPart.Parent = fx
local puffE = emitter(puffPart, {Texture = SMOKE, Color = ColorSequence.new(C(135, 115, 95)),
    Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 9)}),
    Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1)}),
    Lifetime = NumberRange.new(1.5, 2.5), Speed = NumberRange.new(8, 14), SpreadAngle = Vector2.new(80, 80)})

local function dustBurst(center, size, amount)
    local p = mkPart(size, CFrame.new(center))
    p.Transparency = 1
    p.Parent = fx
    local e = emitter(p, {Texture = SMOKE, Color = ColorSequence.new(C(140, 125, 108)),
        Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 5), NumberSequenceKeypoint.new(1, 18)}),
        Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1)}),
        Lifetime = NumberRange.new(2.5, 4.5), Speed = NumberRange.new(8, 22), SpreadAngle = Vector2.new(70, 70)})
    e:Emit(amount)
    task.delay(6, function() pcall(function() p:Destroy() end) end)
end

-- 3D rain: clouds, puddles, splash rings -------------------------------------
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

-- cutting real holes in the ground ------------------------------------------
local ovp = OverlapParams.new()
ovp.FilterType = Enum.RaycastFilterType.Exclude
ovp.MaxParts = 400

local function axisAligned(p)
    local c = p.CFrame
    local function a(v) return math.abs(v.X) > 0.999 or math.abs(v.Y) > 0.999 or math.abs(v.Z) > 0.999 end
    return a(c.RightVector) and a(c.UpVector)
end

local function carveGroundBox(wmin, wmax, skip)
    ovp.FilterDescendantsInstances = {lp.Character, fx, buildFolder, treesFolder, coreFolder, animalFolder, dropFolder}
    local center = (wmin + wmax) / 2
    local size = wmax - wmin
    local parts = Workspace:GetPartBoundsInBox(CFrame.new(center), size, ovp)
    local did = false
    for _, p in ipairs(parts) do
        if p:IsA("Terrain") then
            if pcall(function() Terrain:FillBlock(CFrame.new(center), size, Enum.Material.Air) end) then did = true end
        elseif not (skip and skip[p]) and p:IsA("Part") and p.Shape == Enum.PartType.Block and p.Anchored and p.CanCollide
            and p.Size.X >= 24 and p.Size.Z >= 24 and axisAligned(p) then
            if SV.subtractBox(p, wmin, wmax) then did = true end
        end
    end
    return did
end

-- real cracks that split open (carved into the ground, with a dark / lava floor) ----------
local cracks2 = {}
local lavaWarned = false
local function growCrack(lava)
    local root = getRoot()
    if not root then return end
    local ang, dist = math.random() * math.pi * 2, math.random(14, 120)
    local cx = math.floor(root.Position.X + math.cos(ang) * dist)
    local cz = math.floor(root.Position.Z + math.sin(ang) * dist)
    local hit = Workspace:Raycast(Vector3.new(cx, root.Position.Y + 60, cz), Vector3.new(0, -300, 0), rayP())
    if not hit then return end
    local gy = hit.Position.Y
    local depth = lava and 10 or 8
    local rec = {lava = lava, floors = {}}
    if #cracks2 >= 10 then table.remove(cracks2, 1) end
    cracks2[#cracks2 + 1] = rec
    oneShot(SND.boom, 1, 0.3, 0)
    task.spawn(function()
        local n = math.random(9, 13)
        local axisX = math.random() < 0.5
        local sx = (math.random() < 0.5) and 1 or -1
        local sz = (math.random() < 0.5) and 1 or -1
        for i = 1, n do
            if not running then return end
            local w = 3 + 3 * math.sin(math.pi * i / (n + 1)) + math.random()
            local len = math.random(6, 14)
            local x0, x1, z0, z1
            if axisX then
                x0, x1 = cx, cx + sx * len
                z0, z1 = cz - w / 2, cz + w / 2
                cx = cx + sx * len
                cz = cz + math.random(-1, 1)
            else
                z0, z1 = cz, cz + sz * len
                x0, x1 = cx - w / 2, cx + w / 2
                cz = cz + sz * len
                cx = cx + math.random(-1, 1)
            end
            if x0 > x1 then x0, x1 = x1, x0 end
            if z0 > z1 then z0, z1 = z1, z0 end
            carveGroundBox(Vector3.new(x0, gy - depth, z0), Vector3.new(x1, gy + 0.6, z1))
            local fl = mkPart(Vector3.new(x1 - x0, 0.4, z1 - z0), CFrame.new((x0 + x1) / 2, gy - depth + 0.2, (z0 + z1) / 2),
                lava and Enum.Material.Neon or Enum.Material.Basalt, lava and C(255, 85, 10) or C(28, 24, 24))
            fl.CanCollide = true
            fl.Parent = fx
            if lava and i % 3 == 1 then
                local pl = Instance.new("PointLight")
                pl.Color = C(255, 120, 40)
                pl.Range = 30
                pl.Brightness = 3
                pl.Parent = fl
            end
            rec.floors[#rec.floors + 1] = {x0 = x0, x1 = x1, z0 = z0, z1 = z1, y = gy - depth}
            dustBurst(Vector3.new((x0 + x1) / 2, gy, (z0 + z1) / 2), Vector3.new(math.max(3, x1 - x0), 1, math.max(3, z1 - z0)), 18)
            burst += 0.25
            axisX = not axisX
            task.wait(0.18)
        end
    end)
end

local function lavaTick(step)
    local root = getRoot()
    if not root then return end
    local foot = root.Position.Y - 3
    local p = root.Position
    for _, c in ipairs(cracks2) do
        if c.lava then
            for _, f in ipairs(c.floors) do
                if p.X > f.x0 - 0.8 and p.X < f.x1 + 0.8 and p.Z > f.z0 - 0.8 and p.Z < f.z1 + 0.8 and foot < f.y + 3 then
                    hurt(24 * step, "lava", true)
                    if not lavaWarned then
                        lavaWarned = true
                        toast("LAVA! Get out of the crack!", C(255, 110, 40), 2.5)
                    end
                    return
                end
            end
        end
    end
end

-- collapsing buildings + sinkholes ---------------------------------------------
local debrisCount = 0
local collapsedModels = {}
local DEB_CAP = 260

local function collapseParts(list, root)
    if debrisCount + #list > DEB_CAP then return false end
    local recs = {}
    local minV, maxV = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9)
    for _, p in ipairs(list) do
        if p.Size.Magnitude <= 150 and p.Transparency < 0.95 and not SV.minedOrig[p] then
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
                SV.hideOrig(p)
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
    dustBurst(Vector3.new(center.X, minV.Y, center.Z), Vector3.new(math.max(4, maxV.X - minV.X), 1, math.max(4, maxV.Z - minV.Z)), 120)
    oneShot(SND.boom, 2.2, 0.25, (rp - center).Magnitude / 300)
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

local function pickBuilding()
    local root = getRoot()
    if not root then return nil end
    overlap.FilterDescendantsInstances = {lp.Character, fx, buildFolder, mineFolder, treesFolder, coreFolder, animalFolder, dropFolder}
    local parts = Workspace:GetPartBoundsInRadius(root.Position, 320, overlap)
    local cand, seen = {}, {}
    for _, part in ipairs(parts) do
        if not part:IsA("Terrain") and not SV.minedOrig[part] and not picked[part] then
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
    if #cand == 0 then return nil end
    local pickc = cand[math.random(#cand)]
    local list = {}
    if pickc.model then
        collapsedModels[pickc.model] = true
        for _, d in ipairs(pickc.model:GetDescendants()) do
            if d:IsA("BasePart") and not d:IsA("Terrain") and not SV.minedOrig[d] then list[#list + 1] = d end
        end
    else
        list[1] = pickc.single
    end
    if #list == 0 or #list > 120 then return nil end
    return list
end

-- a sinkhole opens under a building: pit first, then the building drops in
local function sinkhole(list)
    local root = getRoot()
    if not root then return end
    local minV, maxV = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9)
    local skip = {}
    for _, p in ipairs(list) do
        skip[p] = true
        minV = minV:Min(p.Position - p.Size / 2)
        maxV = maxV:Max(p.Position + p.Size / 2)
    end
    local gy = minV.Y
    local cxm, czm = (minV.X + maxV.X) / 2, (minV.Z + maxV.Z) / 2
    local hx = math.min(30, (maxV.X - minV.X) / 2 + 3)
    local hz = math.min(30, (maxV.Z - minV.Z) / 2 + 3)
    carveGroundBox(Vector3.new(cxm - hx - 4, gy - 4, czm - hz - 4), Vector3.new(cxm + hx + 4, gy + 0.6, czm + hz + 4), skip)
    carveGroundBox(Vector3.new(cxm - hx, gy - 12, czm - hz), Vector3.new(cxm + hx, gy - 3.9, czm + hz), skip)
    local fl = mkPart(Vector3.new(hx * 2, 0.4, hz * 2), CFrame.new(cxm, gy - 12 + 0.2, czm), Enum.Material.Basalt, C(28, 24, 24))
    fl.CanCollide = true
    fl.Parent = fx
    collapseParts(list, root)
    toast("A SINKHOLE SWALLOWS A BUILDING!", C(255, 170, 90), 3)
end

local lastMajor = 0
majorShock = function()
    local q = N.quake.Value
    if q < 0.6 or os.clock() - lastMajor < 8 then return end
    lastMajor = os.clock()
    if CONFIG.Fissures then
        local lavaChance = R[stage].crackHot and 1 or ((q >= 0.9) and 0.35 or ((q >= 0.7) and 0.15 or 0.05))
        for _ = 1, (q >= 0.8) and 2 or 1 do
            growCrack(math.random() < lavaChance)
        end
    end
    if q >= 0.8 then
        if CONFIG.Collapse and math.random() < 0.5 then
            local list = pickBuilding()
            if list then
                local root = getRoot()
                if math.random() < 0.5 then
                    sinkhole(list)
                elseif root and collapseParts(list, root) then
                    toast("A BUILDING IS COLLAPSING!", C(255, 170, 90), 3)
                end
            end
        end
        if structDamage then structDamage(nil, nil, 8) end
    end
end

-- the Moon core crashes into the earth and splits the map ----------------------------
local chasm = nil
local movedOrig = {}

local function cutAtX(p, X0)
    local c = p.CFrame
    local mx = p.Size / 2
    local which, sign
    if math.abs(c.RightVector.X) > 0.999 then which, sign = "X", (c.RightVector.X > 0) and 1 or -1
    elseif math.abs(c.UpVector.X) > 0.999 then which, sign = "Y", (c.UpVector.X > 0) and 1 or -1
    else which, sign = "Z", ((-c.LookVector.X) > 0) and 1 or -1 end
    local lc = sign * (X0 - p.Position.X)
    local lo, hi = Vector3.new(-mx.X, -mx.Y, -mx.Z), Vector3.new(mx.X, mx.Y, mx.Z)
    local b1min, b1max, b2min, b2max
    if which == "X" then
        b1min, b1max = lo, Vector3.new(lc, mx.Y, mx.Z)
        b2min, b2max = Vector3.new(lc, -mx.Y, -mx.Z), hi
    elseif which == "Y" then
        b1min, b1max = lo, Vector3.new(mx.X, lc, mx.Z)
        b2min, b2max = Vector3.new(-mx.X, lc, -mx.Z), hi
    else
        b1min, b1max = lo, Vector3.new(mx.X, mx.Y, lc)
        b2min, b2max = Vector3.new(-mx.X, -mx.Y, lc), hi
    end
    local p1 = SV.makePiece(p, b1min, b1max)
    local p2 = SV.makePiece(p, b2min, b2max)
    if p1 == false or p2 == false then
        if p1 then p1:Destroy() end
        if p2 then p2:Destroy() end
        return nil
    end
    SV.hideOrig(p)
    return {p1, p2}
end

local function coreAndSplit()
    local root = getRoot()
    if not root then return end
    local moonFlat = Vector3.new(moonDir.X, 0, moonDir.Z).Unit
    local P = root.Position + moonFlat * 230
    P = Vector3.new(math.floor(P.X / CELL) * CELL, P.Y, math.floor(P.Z / CELL) * CELL)
    local hit = Workspace:Raycast(Vector3.new(P.X, P.Y + 200, P.Z), Vector3.new(0, -600, 0), rayP())
    local gy = hit and hit.Position.Y or baseY
    local X0 = P.X
    toast("THE MOON CORE BURIES ITSELF IN THE EARTH - THE MAP IS SPLITTING APART", C(255, 150, 70), 6)

    local canSplit = true
    local okT, blocked = pcall(terrainBlocked)
    if okT and blocked then canSplit = false end

    local moves = {}
    if canSplit then
        ovp.FilterDescendantsInstances = {lp.Character, fx, coreFolder, animalFolder, dropFolder}
        local parts = Workspace:GetPartBoundsInRadius(Vector3.new(P.X, gy, P.Z), 450, ovp)
        for _, p in ipairs(parts) do
            if #moves >= 1500 then break end
            if not p:IsA("Terrain") and p.Anchored and not SV.minedOrig[p] then
                local c = p.CFrame
                local hx = 0.5 * (math.abs(c.RightVector.X) * p.Size.X + math.abs(c.UpVector.X) * p.Size.Y + math.abs(c.LookVector.X) * p.Size.Z)
                local minx, maxx = p.Position.X - hx, p.Position.X + hx
                local done = false
                if minx < X0 and maxx > X0 and p:IsA("Part") and p.Shape == Enum.PartType.Block and axisAligned(p) then
                    local pieces = cutAtX(p, X0)
                    if pieces then
                        for _, pc in ipairs(pieces) do
                            if pc then moves[#moves + 1] = {part = pc, base = pc.CFrame, side = (pc.Position.X < X0) and -1 or 1} end
                        end
                        done = true
                    end
                end
                if not done then
                    local side = (p.Position.X < X0) and -1 or 1
                    moves[#moves + 1] = {part = p, base = p.CFrame, side = side}
                    movedOrig[#movedOrig + 1] = {part = p, base = p.CFrame}
                end
            end
        end
    end

    -- chasm floor with glowing crust
    if canSplit then
        local floorY = gy - 16
        local fl = mkPart(Vector3.new(36, 1, 1200), CFrame.new(X0, floorY, P.Z), Enum.Material.Basalt, C(30, 22, 22))
        fl.CanCollide = true
        fl.Parent = coreFolder
        for i = 1, 16 do
            local s = mkPart(Vector3.new(math.random(10, 30) / 10, 0.3, math.random(15, 45)),
                CFrame.new(X0 + math.random(-15, 15), floorY + 0.6, P.Z + math.random(-450, 450)) * CFrame.Angles(0, math.random() * 6.28, 0),
                Enum.Material.Neon, C(255, 90, 10))
            s.Parent = coreFolder
            if i % 3 == 0 then
                local pl = Instance.new("PointLight")
                pl.Color = C(255, 120, 40)
                pl.Range = 40
                pl.Brightness = 3
                pl.Parent = s
            end
        end
        chasm = {x0 = X0, y = floorY}
    end

    -- the core: a half-buried ball of minable blocks (90 stone per block)
    local cy = gy + 2
    local centerBlock
    for ix = -4, 4 do
        for iy = -4, 4 do
            for iz = -4, 4 do
                local d2 = ix * ix + iy * iy + iz * iz
                if d2 <= 17 and iy >= -2 then
                    local pos = Vector3.new(X0 + ix * CELL, cy + iy * CELL, P.Z + iz * CELL)
                    local b = SV.newBlock(pos, "core", coreFolder)
                    if math.random() < 0.2 then
                        b.Material = Enum.Material.Neon
                        b.Color = C(255, 110, 30)
                    else
                        local s = math.random(30, 60)
                        b.Color = C(s, s - 4, s + 4)
                    end
                    SV.blockInfo[b] = {part = b, kind = "core"}
                    if ix == 0 and iy == 0 and iz == 0 then centerBlock = b end
                end
            end
        end
    end
    if centerBlock then
        local pl = Instance.new("PointLight")
        pl.Color = C(255, 120, 40)
        pl.Range = 70
        pl.Brightness = 4
        pl.Parent = centerBlock
    end

    if canSplit and #moves > 0 then
        local startSide = (root.Position.X < X0) and -1 or 1
        task.spawn(function()
            local t0 = os.clock()
            local lastOff = 0
            while running and os.clock() - t0 < 9 do
                local k = (os.clock() - t0) / 9
                local off = 15 * k * k * (3 - 2 * k)
                local list, cfs = {}, {}
                for _, m in ipairs(moves) do
                    if m.part.Parent then
                        list[#list + 1] = m.part
                        cfs[#cfs + 1] = m.base + Vector3.new(m.side * off, 0, 0)
                    end
                end
                if #list > 0 then Workspace:BulkMoveTo(list, cfs, Enum.BulkMoveMode.FireNoEvents) end
                local r = getRoot()
                if r then r.CFrame = r.CFrame + Vector3.new(startSide * (off - lastOff), 0, 0) end
                lastOff = off
                burst += 0.015
                task.wait()
            end
        end)
    end
end

SV.onImpact = function()
    task.spawn(function()
        local ok, e = pcall(coreAndSplit)
        if not ok then report("core/split", e) end
    end)
end

-- main loop of this part --------------------------------------------------------
local treeStep = 0
local birdAcc, lightAcc, scanAcc, accCloud, accPud, accLava, splashAcc, hotAcc = 0, 0, 0, 0, 0, 0, 0, 0
local lastBurst, finalT, surviveShown = 0, 0, false

local function extraStep(dt)
    local t = os.clock()
    local root = getRoot()
    local rp = root and root.Position or startPos

    -- birds
    birdAcc += dt
    if birdAcc > 7 then
        birdAcc = 0
        if stage >= 2 and stage <= 9 and #birds < 20 then spawnFlock() end
    end
    for i = #birds, 1, -1 do
        local b = birds[i]
        b.t += dt
        b.pos = b.pos + b.dir * b.speed * dt
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

    -- dust puffs when the ground shakes
    puffPart.CFrame = CFrame.new(rp.X, rp.Y - 3, rp.Z)
    if burst - lastBurst > 0.35 and N.quake.Value > 0.25 then puffE:Emit(math.floor(15 + burst * 10)) end
    lastBurst = burst

    -- 3D rain clouds, puddles and splash rings
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

    -- lava + hot crust damage
    accLava += dt
    if accLava >= 0.2 then
        lavaTick(accLava)
        if chasm and root and root.Position.Y - 3 < chasm.y + 3 and math.abs(root.Position.X - chasm.x0) < 20 then
            hurt(10 * accLava, "scorching crust", true)
        end
        accLava = 0
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
    local ok, e = pcall(extraStep, dt)
    if not ok then report("extras", e) end
end)

survivalCleanup = function()
    for l, rec in pairs(lightRecs) do pcall(function() l.Enabled = rec.on end) end
    for _, m in ipairs(movedOrig) do
        pcall(function() m.part.CFrame = m.base end)
    end
    if restoreMined then pcall(restoreMined) end
end

end
local ok4, e4 = pcall(__part4)
if not ok4 then report("startup (disasters/extras)", e4) end
'''

new_layer = tabify(PART3) + "\n" + tabify(PART4) + "\n"
assert src.count("@@NEWLAYER@@\n") == 1
src = src.replace("@@NEWLAYER@@\n", new_layer)

open(DST, "w", encoding="utf-8").write(src)
print("patched OK ->", DST)
