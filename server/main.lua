-- molo_soundemitters — server: storage, sync, vanilla emitter allocation, exports
local RES = GetCurrentResourceName()
local SAVE_FILE  = 'data/emitters.json'
local NAMES_FILE = 'data/interior_names.json'
local CHECK_FILE = 'data/sound_check.json'

local emitters = {}       -- id -> element (editable + packs)
local interiorNames = {}  -- "unsigned hash" -> name given in-game (custom MLOs)
local soundCheck = { bad = {}, hidden = {}, checked = 0, at = nil }  -- keys are "soundset|name" in lower case

-- ─── Utils ───────────────────────────────────────────────────────────
local function canEdit(src)
    if not Config.UseAce then return true end
    return IsPlayerAceAllowed(src, Config.Ace)
end

local function num(v, def, min, max)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return def end
    if min and v < min then v = min end
    if max and v > max then v = max end
    return v
end

local function str(v, maxLen, def)
    if type(v) ~= 'string' then return def end
    v = v:gsub('[%c]', '')
    if #v == 0 then return def end
    return v:sub(1, maxLen or 64)
end

local function genId()
    local id
    repeat id = ('se_%s%03d'):format(os.time() % 1000000, math.random(0, 999)) until not emitters[id]
    return id
end

local function list()
    local out = {}
    for _, e in pairs(emitters) do out[#out + 1] = ApplyNativeFlag(e) end
    return out
end

local function groupElements(group)
    local out = {}
    for _, e in pairs(emitters) do if e.group == group then out[#out + 1] = e end end
    return out
end

-- Groups already exported natively are kept in sync automatically (applied at next restart)
local function syncNative(group)
    if group and AudioState.groups[group] then
        ExportNativeAudio(group, groupElements(group))
        TriggerClientEvent('molo_se:audioState', -1, { status = AudioStatus(), interiors = AudioState.interiors })
    end
end

local function persist()
    local out = {}
    for _, e in pairs(emitters) do if not e.pack then out[#out + 1] = e end end
    table.sort(out, function(a, b) return a.id < b.id end)
    SaveResourceFile(RES, SAVE_FILE, json.encode(out, { indent = true }), -1)
end

local function notify(src, msg, kind)
    TriggerClientEvent('molo_se:notify', src, msg, kind or 'info')
end

-- ─── Vanilla emitter allocation (radio pool + relocated ambient emitters) ──
local function usedEmitters(exceptId)
    local used = {}
    for id, e in pairs(emitters) do
        if id ~= exceptId then
            if e.type == 'radio' and e.radio and e.radio.emitter then used[e.radio.emitter:lower()] = e end
            if e.type == 'ambient' and e.ambient and e.ambient.emitter then used[e.ambient.emitter:lower()] = e end
            if e.type == 'static' and e.static and e.static.name then used[e.static.name:lower()] = e end
        end
    end
    return used
end

local function allocRadioEmitter(wanted, exceptId)
    local used = usedEmitters(exceptId)
    if wanted and not used[wanted:lower()] then return wanted end
    for _, name in ipairs(RadioEmitterPool) do
        if not used[name:lower()] then return name end
    end
end

-- ─── Validation ─────────────────────────────────────────────────────
local TYPES = { sound = true, ambient = true, radio = true, static = true, prop = true }

local function sanitize(d, existing)
    if type(d) ~= 'table' or not TYPES[d.type] then return nil, 'invalid type' end
    local e = {
        id      = existing and existing.id or genId(),
        type    = d.type,
        label   = str(d.label, 48, nil),
        group   = str(d.group, 48, Config.DefaultGroup),
        x = num(d.x, nil), y = num(d.y, nil), z = num(d.z, nil),
        range   = num(d.range, Config.DefaultRange, 1.0, 300.0),
        enabled = d.enabled ~= false,
        interiorOnly = d.interiorOnly == true,
        interiorHash = math.floor(num(d.interiorHash, 0)),
        roomHash     = math.floor(num(d.roomHash, 0)),
        roomName     = str(d.roomName, 64, nil),
        volume       = num(d.volume, nil, -30.0, 24.0), -- dB, native export only (nil = default)
    }
    if not (e.x and e.y and e.z) then return nil, 'invalid coordinates' end
    if math.abs(e.x) > 20000 or math.abs(e.y) > 20000 or math.abs(e.z) > 5000 then return nil, 'outside the map' end

    if type(d.hours) == 'table' then
        local from, to = num(d.hours.from, nil, 0, 23), num(d.hours.to, nil, 0, 24)
        if from and to and not (from == 0 and to == 24) then e.hours = { from = math.floor(from), to = math.floor(to) } end
    end

    -- Object: on its own (prop type) or as the visible source of a sound / radio / ambient emitter
    if type(d.prop) == 'table' and str(d.prop.model, 64, nil) then
        e.prop = {
            model   = str(d.prop.model, 64, nil),
            heading = num(d.prop.heading, 0.0, -360.0, 720.0) % 360.0,
            px = num(d.prop.px, e.x), py = num(d.prop.py, e.y), pz = num(d.prop.pz, e.z),
        }
    end

    if e.type == 'sound' then
        local s = type(d.sound) == 'table' and d.sound or {}
        e.sound = {
            name     = str(s.name, 128, nil),
            set      = str(s.set, 128, nil),
            bank     = str(s.bank, 128, nil),
            bankType = (s.bankType == 'ambient') and 'ambient' or 'script',
            ['repeat'] = s['repeat'] ~= false,
            delayMin = num(s.delayMin, 0, 0, 600),
            delayMax = num(s.delayMax, 0, 0, 600),
        }
        if e.sound.delayMax < e.sound.delayMin then e.sound.delayMax = e.sound.delayMin end
        if not e.sound.name then return nil, 'missing sound name' end
    elseif e.type == 'ambient' then
        local a = type(d.ambient) == 'table' and d.ambient or {}
        local name = str(a.emitter, 64, nil)
        if not name then return nil, 'missing emitter name' end
        local taken = usedEmitters(e.id)[name:lower()]
        if taken then return nil, ('%s is already used by "%s"'):format(name, taken.label or taken.id) end
        e.ambient = { emitter = name, alarm = str(a.alarm, 64, nil) }
    elseif e.type == 'radio' then
        local r = type(d.radio) == 'table' and d.radio or {}
        local station = str(r.station, 64, nil)
        if not station then return nil, 'missing radio station' end
        local emitter = allocRadioEmitter(str(r.emitter, 64, existing and existing.radio and existing.radio.emitter), e.id)
        if not emitter then return nil, 'no free radio emitter left in the pool' end
        e.radio = { station = station, emitter = emitter }
    elseif e.type == 'static' then
        local s = type(d.static) == 'table' and d.static or {}
        local name = str(s.name, 64, nil)
        if not name then return nil, 'missing emitter name' end
        e.static = {
            name = name, enabled = s.enabled == true, default = s.default ~= false,
            station = str(s.station, 64, nil),
            vx = num(s.vx, nil), vy = num(s.vy, nil), vz = num(s.vz, nil),
        }
    elseif e.type == 'prop' then
        if not e.prop then return nil, 'missing object model' end
    end
    return e
end

-- ─── Loading ────────────────────────────────────────────────────────
local function loadFile(path, packName)
    local raw = LoadResourceFile(RES, path)
    if not raw or raw == '' then return 0 end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then
        print(('^1[molo_soundemitters] invalid JSON: %s^7'):format(path))
        return 0
    end
    local n = 0
    for _, d in ipairs(data) do
        local e, err = sanitize(d, d.id and { id = tostring(d.id), radio = d.radio } or nil)
        if e then
            if packName then e.pack = packName end
            emitters[e.id] = e
            n = n + 1
        else
            print(('^3[molo_soundemitters] skipped entry in %s: %s^7'):format(path, err))
        end
    end
    return n
end

CreateThread(function()
    local raw = LoadResourceFile(RES, NAMES_FILE)
    if raw and raw ~= '' then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == 'table' then interiorNames = data end
    end
    raw = LoadResourceFile(RES, CHECK_FILE)
    if raw and raw ~= '' then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == 'table' then
            soundCheck.bad, soundCheck.hidden = data.bad or {}, data.hidden or {}
            soundCheck.checked, soundCheck.at = data.checked or 0, data.at
        end
    end
    local n = loadFile(SAVE_FILE)
    for _, p in ipairs(Config.Packs) do
        local c = loadFile(p, p:match('([^/]+)%.json$') or p)
        print(('[molo_soundemitters] pack %s: %d elements'):format(p, c))
    end
    print(('[molo_soundemitters] %d elements loaded'):format(n))
    TriggerClientEvent('molo_se:sync', -1, list(), interiorNames)
end)

-- ─── Network ────────────────────────────────────────────────────────
RegisterNetEvent('molo_se:requestAll', function()
    TriggerClientEvent('molo_se:sync', source, list(), interiorNames)
    TriggerClientEvent('molo_se:soundCheck', source, soundCheck)
end)

-- ─── Sound check (which catalog sounds actually play) ───────────────
local function saveCheck()
    SaveResourceFile(RES, CHECK_FILE, json.encode(soundCheck, { indent = true }), -1)
    TriggerClientEvent('molo_se:soundCheck', -1, soundCheck)
end

local function keyList(t, max)
    local out = {}
    if type(t) ~= 'table' then return out end
    for _, k in ipairs(t) do
        if type(k) == 'string' and #k < 260 then out[#out + 1] = k:lower() end
        if #out >= max then break end
    end
    return out
end

-- A finished scan replaces the "bad" list. Partial scans (a single category) are merged.
RegisterNetEvent('molo_se:scanResult', function(bad, good, total, full)
    local src = source
    if not canEdit(src) then return end
    bad, good = keyList(bad, 20000), keyList(good, 20000)
    if full then
        soundCheck.bad = bad
        soundCheck.checked = math.floor(num(total, #bad + #good))
    else
        local set = {}
        for _, k in ipairs(soundCheck.bad) do set[k] = true end
        for _, k in ipairs(good) do set[k] = nil end
        for _, k in ipairs(bad) do set[k] = true end
        soundCheck.bad = {}
        for k in pairs(set) do soundCheck.bad[#soundCheck.bad + 1] = k end
        soundCheck.checked = math.max(soundCheck.checked or 0, math.floor(num(total, 0)))
    end
    soundCheck.at = os.date('%Y-%m-%d %H:%M')
    saveCheck()
    notify(src, ('Sound check done: %d sounds removed (not playable)'):format(#bad), 'success')
end)

-- Manually hide / unhide a sound you can't hear or don't want in the list
RegisterNetEvent('molo_se:hideSound', function(key, state)
    local src = source
    if not canEdit(src) or type(key) ~= 'string' or #key > 260 then return end
    key = key:lower()
    local out = {}
    for _, k in ipairs(soundCheck.hidden) do if k ~= key then out[#out + 1] = k end end
    if state then out[#out + 1] = key end
    soundCheck.hidden = out
    saveCheck()
end)

RegisterNetEvent('molo_se:resetCheck', function()
    local src = source
    if not canEdit(src) then return end
    soundCheck = { bad = {}, hidden = {}, checked = 0, at = nil }
    saveCheck()
    notify(src, 'Sound check reset', 'success')
end)

RegisterNetEvent('molo_se:save', function(d)
    local src = source
    if not canEdit(src) then return notify(src, 'No permission', 'error') end
    local existing = type(d) == 'table' and d.id and emitters[tostring(d.id)] or nil
    if existing and existing.pack then return notify(src, 'Pack element: read-only', 'error') end
    local e, err = sanitize(d, existing)
    if not e then return notify(src, 'Rejected: ' .. err, 'error') end
    local oldGroup = existing and existing.group
    emitters[e.id] = e
    persist()
    TriggerClientEvent('molo_se:upsert', -1, ApplyNativeFlag(e))
    syncNative(e.group)
    if oldGroup and oldGroup ~= e.group then syncNative(oldGroup) end
    notify(src, (existing and 'Updated: ' or 'Placed: ') .. (e.label or e.id), 'success')
end)

RegisterNetEvent('molo_se:delete', function(id)
    local src = source
    if not canEdit(src) then return notify(src, 'No permission', 'error') end
    id = tostring(id)
    local e = emitters[id]
    if not e then return end
    if e.pack then return notify(src, 'Pack element: read-only', 'error') end
    emitters[id] = nil
    persist()
    TriggerClientEvent('molo_se:remove', -1, id)
    syncNative(e.group)
    notify(src, 'Deleted: ' .. (e.label or id), 'success')
end)

RegisterNetEvent('molo_se:nameInterior', function(hash, name)
    local src = source
    if not canEdit(src) then return end
    hash = math.floor(num(hash, 0))
    if hash == 0 then return end
    local key = tostring(hash & 0xFFFFFFFF)
    interiorNames[key] = str(name, 48, nil)
    SaveResourceFile(RES, NAMES_FILE, json.encode(interiorNames, { indent = true }), -1)
    TriggerClientEvent('molo_se:interiorNames', -1, interiorNames)
    notify(src, interiorNames[key] and ('Interior named: ' .. interiorNames[key]) or 'Name removed', 'success')
end)

-- ─── Export: JSON pack + native audio (audio/<group>_game.dat151.rel, registered in fxmanifest) ──
RegisterNetEvent('molo_se:export', function(group, target)
    local src = source
    if not canEdit(src) then return notify(src, 'No permission', 'error') end
    group = str(group, 48, Config.DefaultGroup)
    if target ~= nil then
        local ok, err = SetGroupTarget(group, str(target, 64, nil))
        if not ok then return notify(src, 'Export failed: ' .. err, 'error') end
    end
    local items = {}
    for _, e in pairs(emitters) do
        if e.group == group then
            local c = json.decode(json.encode(e)); c.pack = nil; c.native = nil
            items[#items + 1] = c
        end
    end
    table.sort(items, function(a, b) return a.id < b.id end)

    local safe = group:gsub('[^%w_%-]', '_')
    local packJson = json.encode(items, { indent = true })
    if #items > 0 then SaveResourceFile(RES, ('exports/%s.json'):format(safe), packJson, -1) end

    local count, msg = ExportNativeAudio(group, groupElements(group))
    if count < 0 then
        notify(src, 'Native audio export failed: ' .. msg, 'error')
    elseif count == 0 and #items == 0 then
        return notify(src, 'Nothing in group ' .. group, 'error')
    end
    TriggerClientEvent('molo_se:audioState', -1, { status = AudioStatus(), interiors = AudioState.interiors })
    TriggerClientEvent('molo_se:exported', src, { group = group, count = #items, json = packJson, native = msg, nativeCount = count, file = safe })
end)

-- ─── MLO audio profiles (rooms + doors), used by the native export ──
-- Resources the export can target (for the dropdown)
RegisterNetEvent('molo_se:getResources', function()
    local out = {}
    for i = 0, GetNumResources() - 1 do
        local r = GetResourceByFindIndex(i)
        if r and r ~= RES and GetResourceState(r) ~= 'missing' and LoadResourceFile(r, 'fxmanifest.lua') then out[#out + 1] = r end
    end
    table.sort(out)
    TriggerClientEvent('molo_se:resources', source, out)
end)

RegisterNetEvent('molo_se:getAudioState', function()
    TriggerClientEvent('molo_se:audioState', source, { status = AudioStatus(), interiors = AudioState.interiors })
end)

RegisterNetEvent('molo_se:saveInteriorAudio', function(p)
    local src = source
    if not canEdit(src) or type(p) ~= 'table' then return end
    local key = tostring(math.floor(num(p.hash, 0)) & 0xFFFFFFFF)
    if key == '0' then return end
    local prof = { group = str(p.group, 48, Config.DefaultGroup), enabled = p.enabled ~= false, roomList = {}, rooms = {}, doors = {} }
    for i, r in ipairs(type(p.roomList) == 'table' and p.roomList or {}) do
        if i > 64 then break end
        local name = str(r, 64, nil)
        if name then prof.roomList[#prof.roomList + 1] = name:lower() end
    end
    for name, r in pairs(type(p.rooms) == 'table' and p.rooms or {}) do
        name = str(name, 64, nil)
        if name and type(r) == 'table' then
            prof.rooms[name:lower()] = {
                tone = str(r.tone, 128, nil),
                reverbSmall = num(r.reverbSmall, 0.35, 0, 1), reverbMedium = num(r.reverbMedium, 0, 0, 1), reverbLarge = num(r.reverbLarge, 0, 0, 1),
                exteriorAudibility = num(r.exteriorAudibility, 0, 0, 1), portalOcclusion = num(r.portalOcclusion, 0.7, 0, 1),
            }
        end
    end
    local n = 0
    for mh, d in pairs(type(p.doors) == 'table' and p.doors or {}) do
        local h = math.floor(num(mh, 0)) & 0xFFFFFFFF
        if h ~= 0 and type(d) == 'table' and n < 200 then
            local kind = str(d.kind, 16, nil)
            prof.doors[tostring(h)] = { model = str(d.model, 64, nil), preset = str(d.preset, 96, nil), kind = kind, how = str(d.how, 16, nil) }
            n = n + 1
        end
    end
    -- Audio occlusion data (rooms / portals / portal entities read from the game by the client)
    if type(p.occl) == 'table' then
        local o = p.occl
        local occl = { enabled = o.enabled ~= false, proxy = math.floor(num(o.proxy, 0)) & 0xFFFFFFFF, rooms = {}, portals = {} }
        for i, r in ipairs(type(o.rooms) == 'table' and o.rooms or {}) do
            if i > 64 or type(r) ~= 'table' then break end
            occl.rooms[#occl.rooms + 1] = { name = str(r.name, 64, 'room' .. i), key = math.floor(num(r.key, 0)) & 0xFFFFFFFF }
        end
        local nRooms, valid = #occl.rooms, true
        for i, pt in ipairs(type(o.portals) == 'table' and o.portals or {}) do
            if i > 256 or type(pt) ~= 'table' then break end
            local from, to = math.floor(num(pt.from, -1)), math.floor(num(pt.to, -1))
            if from >= 0 and to >= 0 and from < nRooms and to < nRooms then
                local ents = {}
                for j, e in ipairs(type(pt.entities) == 'table' and pt.entities or {}) do
                    if j > 16 or type(e) ~= 'table' then break end
                    ents[#ents + 1] = { model = math.floor(num(e.model, 0)) & 0xFFFFFFFF, name = str(e.name, 64, nil),
                        maxOcclusion = num(e.maxOcclusion, 1.0, 0, 1), isDoor = e.isDoor == true, isGlass = e.isGlass == true, linkType = 1 }
                end
                occl.portals[#occl.portals + 1] = { from = from, to = to, mirror = pt.mirror == true, entities = ents }
            else
                valid = false -- a bad portal would shift every portal index: drop the occlusion data
            end
        end
        if valid and occl.proxy ~= 0 and nRooms > 0 then prof.occl = occl end
    end

    local oldGroup = AudioState.interiors[key] and AudioState.interiors[key].group
    AudioState.interiors[key] = prof
    SaveResourceFile(RES, 'data/audio_export.json', json.encode(AudioState, { indent = true }), -1)
    syncNative(prof.group)
    if oldGroup and oldGroup ~= prof.group then syncNative(oldGroup) end
    TriggerClientEvent('molo_se:audioState', -1, { status = AudioStatus(), interiors = AudioState.interiors })
    notify(src, 'MLO audio saved (' .. #prof.roomList .. ' rooms, ' .. n .. ' doors)', 'success')
end)

-- ─── Server exports ─────────────────────────────────────────────────
-- Turn an element on / off for everyone (not saved), e.g. when a club opens
exports('SetEmitterEnabled', function(id, state)
    local e = emitters[tostring(id)]
    if not e then return false end
    e.enabled = state and true or false
    TriggerClientEvent('molo_se:upsert', -1, e)
    return true
end)

exports('GetEmitters', function(group)
    local out = {}
    for _, e in pairs(emitters) do
        if not group or e.group == group then out[#out + 1] = e end
    end
    return out
end)
