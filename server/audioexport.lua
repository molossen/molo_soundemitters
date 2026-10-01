-- molo_soundemitters — export of a group:
--   • native audio  audio/<group>_game.dat151.rel  (rooms, door sounds, optional static emitters)
--   • occlusion     stream/<interior proxy>.ymt
-- into a TARGET resource (normally the MLO's own resource), whose fxmanifest.lua is patched automatically.
-- Interior + room logic adapted from Hedgehog-Technologies/ht_mlotool.

local RES = GetCurrentResourceName()
local STATE_FILE = 'data/audio_export.json'
local BEGIN = '-- >>> molo_soundemitters (auto-generated, do not edit) >>>'
local FINISH = '-- <<< molo_soundemitters <<<'
local OLD_BEGIN = '-- >>> molo_soundemitters native audio (auto-generated, do not edit) >>>'
local OLD_FINISH = '-- <<< molo_soundemitters native audio <<<'
local VERSION = 45897013

AudioState = { groups = {}, interiors = {}, targets = {} }
local loadedNative = {}   -- id -> true for elements inside a native audio file loaded at server start

local function safeName(g) return (tostring(g):gsub('[^%w_%-]', '_'):lower()) end
local function relPath(g) return ('audio/molo_se_%s_game.dat151.rel'):format(safeName(g)) end
local function playerPath(g) return ('audio/molo_se_%s_player.lua'):format(safeName(g)) end
local function u32(h) return math.floor(tonumber(h) or 0) & 0xFFFFFFFF end

local function saveState()
    SaveResourceFile(RES, STATE_FILE, json.encode(AudioState, { indent = true }), -1)
end

-- Where a group is exported: its target resource if it exists, otherwise this resource
function GroupTarget(group)
    local t = AudioState.targets[group]
    if t and t ~= '' and t ~= RES and GetResourceState(t) ~= 'missing' and GetResourcePath(t) then return t end
    return RES
end

-- ─── File helpers (binary-safe, any resource) ───────────────────────
local function mkdirs(res, path)
    local dir = path:match('(.+)/[^/]+$')
    if dir then
        local acc = GetResourcePath(res)
        for part in dir:gmatch('[^/]+') do
            acc = acc .. '/' .. part
            pcall(os.createdir, acc)
        end
    end
end

local writeErrors = {}
local function permLine(res) return ('add_filesystem_permission %s write %s'):format(RES, res) end

local function writeFile(res, path, data)
    mkdirs(res, path)
    local full = GetResourcePath(res) .. '/' .. path
    local f, err = io.open(full, 'wb')
    if f then
        f:write(data)
        f:close()
        local chk = io.open(full, 'rb')
        if chk then
            local back = chk:read('a')
            chk:close()
            if back == data then return true end
        end
        err = 'written but read back differs'
    end
    if res == RES and SaveResourceFile(res, path, data, #data) then return true end
    print(('^1[molo_soundemitters] cannot write %s/%s: %s^7'):format(res, path, tostring(err)))
    writeErrors[#writeErrors + 1] = path
    return false, err
end

local function removeFile(res, path)
    os.remove(GetResourcePath(res) .. '/' .. path)
end

local function readFile(res, path)
    local f = io.open(GetResourcePath(res) .. '/' .. path, 'rb')
    if not f then return nil end
    local d = f:read('a')
    f:close()
    return d
end


-- ─── fxmanifest.lua managed block (one per target resource) ─────────
local function stripBlock(raw, b, f)
    local a = raw:find(b, 1, true)
    local z = a and raw:find(f, a, true)
    if a and z then raw = raw:sub(1, a - 1):gsub('%s+$', '') .. raw:sub(z + #f):gsub('^%s*', '\n') end
    return raw
end

local function writeManifest(res)
    local raw = readFile(res, 'fxmanifest.lua') or LoadResourceFile(res, 'fxmanifest.lua')
    if not raw then return false, 'fxmanifest.lua not found' end
    raw = stripBlock(stripBlock(raw, OLD_BEGIN, OLD_FINISH), BEGIN, FINISH)

    local names = {}
    for g, st in pairs(AudioState.groups) do if (st.target or RES) == res then names[#names + 1] = g end end
    table.sort(names)
    local lines, files = {}, {}
    for _, g in ipairs(names) do
        local st = AudioState.groups[g]
        if (st.count or 0) > 0 then
            local p = relPath(g)
            lines[#lines + 1] = ("data_file 'AUDIO_GAMEDATA' '%s'"):format((p:gsub('%.dat151%.rel$', '.dat')))
            files[#files + 1] = ("'%s'"):format(p)
        end
    end
    if #files > 0 then lines[#lines + 1] = 'files { ' .. table.concat(files, ', ') .. ' }' end
    if res ~= RES then
        for _, g in ipairs(names) do
            if (AudioState.groups[g].elements or 0) > 0 then lines[#lines + 1] = ("client_script '%s'"):format(playerPath(g)) end
        end
    end

    raw = raw:gsub('%s+$', '')
    local block = ''
    if #lines > 0 then block = BEGIN .. '\n' .. table.concat(lines, '\n') .. '\n' .. FINISH; raw = raw .. '\n\n' .. block .. '\n' else raw = raw .. '\n' end
    local ok, err = writeFile(res, 'fxmanifest.lua', raw)
    if not ok then return false, err, block end
    return true, nil, block
end

-- ─── Native static emitters (off by default: the player script plays sounds reliably) ──
local vanillaStation  -- emitter name -> radio station id
local function stationOf(emitter)
    if not vanillaStation then
        vanillaStation = {}
        local byLabel = {}
        local ok, radios = pcall(json.decode, LoadResourceFile(RES, 'data/radios.json') or '[]')
        for _, r in ipairs(ok and radios or {}) do byLabel[r.l] = r.n end
        local ok2, list = pcall(json.decode, LoadResourceFile(RES, 'data/static_emitters.json') or '[]')
        for _, n in ipairs(ok2 and list or {}) do
            if n.rs and n.rs ~= '' then vanillaStation[n.n:lower()] = (byLabel[n.rs] or n.rs):upper() end
        end
    end
    return emitter and vanillaStation[tostring(emitter):lower()]
end

function IsNativeEligible(e)
    if Config.NativeEmitters == false then return false end
    if e.type == 'radio' then return true end
    if e.type == 'ambient' and e.ambient and (e.ambient.station or stationOf(e.ambient.emitter)) then return true end
    if e.type == 'sound' and e.sound then
        local s = e.sound
        return (not s.set or s.set == '') and not s.bank and s['repeat'] ~= false and (s.delayMax or 0) == 0
    end
    return false
end

function ApplyNativeFlag(e)
    e.native = loadedNative[e.id] and IsNativeEligible(e) or nil
    return e
end

-- ─── Build dat151 items ─────────────────────────────────────────────
local function roomObjectName(hash, room)
    return ('%X_%s'):format(u32(hash), room):lower()
end

function EmitterListName(group)
    local n = tonumber(Config.EmitterListNumber and Config.EmitterListNumber[group]) or (10 + RelWriter.joaat(safeName(group)) % 90)
    return ('ambient_emitter_list_%02d'):format(n)
end

local noRoom = {}  -- emitters exported without interior/room (heard as outside sounds)
local function buildItems(group, elements)
    local items, emitterNames, profiles = {}, {}, {}
    noRoom = {}
    for key, p in pairs(AudioState.interiors) do
        if p.group == group then profiles[key] = p end
    end

    -- Rooms (InteriorSettings + InteriorRoom), as ht_mlotool does
    for key, p in pairs(profiles) do
        if p.enabled ~= false then
            local hash = tonumber(key)
            local refs = {}
            for _, roomName in ipairs(p.roomList or {}) do
                if roomName ~= 'limbo' then refs[#refs + 1] = roomObjectName(hash, roomName) end
            end
            items[#items + 1] = { kind = 'InteriorSettings', nameHash = hash, rooms = refs }
            for _, roomName in ipairs(p.roomList or {}) do
                if roomName ~= 'limbo' then
                    local r = (p.rooms or {})[roomName] or {}
                    items[#items + 1] = {
                        kind = 'InteriorRoom', name = roomObjectName(hash, roomName), roomName = roomName:lower(),
                        roomTone = (r.tone and r.tone ~= '') and r.tone or 'null_sound',
                        reverbSmall = tonumber(r.reverbSmall) or 0.35,
                        reverbMedium = tonumber(r.reverbMedium) or 0.0,
                        reverbLarge = tonumber(r.reverbLarge) or 0.0,
                        exteriorAudibility = tonumber(r.exteriorAudibility) or 0.0,
                        nonMarkedPortalOcclusion = tonumber(r.portalOcclusion) or 0.7,
                    }
                end
            end
        end
    end

    -- Door sounds: DASL_<model hash> → door audio preset
    local doorDone = {}
    for _, p in pairs(profiles) do
        for mh, d in pairs(p.doors or {}) do
            local h = u32(tonumber(mh))
            if h ~= 0 and d.preset and d.preset ~= '' and not doorDone[h] then
                doorDone[h] = true
                items[#items + 1] = { kind = 'DoorAudioSettingsLink', name = ('dasl_%08x'):format(h), door = d.preset }
            end
        end
    end

    -- Optional native static emitters
    local ids = {}
    table.sort(elements, function(a, b) return a.id < b.id end)
    for _, e in ipairs(elements) do
        if IsNativeEligible(e) and e.enabled ~= false then
            local name = ('molo_se_%s'):format(e.id:gsub('^se_', ''))
            local it = {
                kind = 'StaticEmitter', name = name, x = e.x, y = e.y, z = e.z, maxDistance = e.range,
                minTime = e.hours and e.hours.from * 60 or 0, maxTime = e.hours and e.hours.to * 60 or 1440,
            }
            -- Vanilla radio emitters are +12 dB with a 2.5x slower rolloff and some reverb (e.g. los_santos_ammunation_gun_range)
            local music = e.type == 'radio' or e.type == 'ambient'
            local db = tonumber(e.volume) or (music and Config.NativeMusicVolume or Config.NativeSoundVolume) or 0
            it.volume = math.floor(db * 100 + 0.5)  -- EmittedVolume is in mB (1/100 dB)
            it.rolloff = music and 250 or 100
            if music then it.smallReverb, it.mediumReverb = 50, 50 end
            if e.type == 'radio' then it.radioStation, it.childSound = e.radio.station, 'null_sound'
            elseif e.type == 'ambient' then it.radioStation, it.childSound = e.ambient.station or stationOf(e.ambient.emitter), 'null_sound'
            else it.childSound = e.sound.name end
            local key = tostring(u32(e.interiorHash))
            if e.interiorHash and e.interiorHash ~= 0 and profiles[key] and profiles[key].enabled ~= false and e.roomName and e.roomName ~= '' and e.roomName ~= 'limbo' then
                it.interior, it.room = u32(e.interiorHash), roomObjectName(e.interiorHash, e.roomName)
            else
                noRoom[#noRoom + 1] = e.label or e.id
            end
            items[#items + 1] = it
            emitterNames[#emitterNames + 1] = name
            ids[#ids + 1] = e.id
        end
    end
    if #emitterNames > 0 then
        -- GTA only loads StaticEmitterLists named ambient_emitter_list_NN (vanilla uses 01-03); any other name is ignored
        items[#items + 1] = { kind = 'StaticEmitterList', name = EmitterListName(group), emitters = emitterNames }
    end
    return items, ids
end

-- ─── Occlusion: one stream/<proxy hash>.ymt per MLO of the group ────
local function exportOcclusion(group, target)
    local written, notes = {}, {}
    for key, p in pairs(AudioState.interiors) do
        local o = p.occl
        if p.group == group and o and o.enabled ~= false and o.proxy and #(o.rooms or {}) > 0 then
            local ok, data = pcall(Occlusion.generate, o)
            if ok then
                local name = tostring(u32(o.proxy))
                local mine = {}
                for _, n in ipairs((AudioState.groups[group] or {}).ymts or {}) do mine[n] = true end
                local existing = readFile(target, 'stream/' .. name .. '.ymt')
                if existing and not mine[name] and not readFile(target, 'audio/_molo_backup/' .. name .. '.ymt') then
                    writeFile(target, 'audio/_molo_backup/' .. name .. '.ymt', existing)
                    notes[#notes + 1] = ('replaced stream/%s.ymt (original in audio/_molo_backup)'):format(name)
                end
                writeFile(target, 'stream/' .. name .. '.ymt', Occlusion.toPso(data))
                written[#written + 1] = name
                notes[#notes + 1] = ('stream/%s.ymt'):format(name)
            else
                print(('^1[molo_soundemitters] occlusion failed for interior %s: %s^7'):format(key, data))
            end
        end
    end
    return written, notes
end

-- Remove everything a previous export of this group wrote (in its previous target)
local function cleanPrevious(group)
    local st = AudioState.groups[group]
    if not st then return end
    local res = st.target or RES
    if GetResourceState(res) == 'missing' then return end
    removeFile(res, relPath(group))
    removeFile(res, relPath(group) .. '.xml')
    removeFile(res, playerPath(group))
    if res == RES then -- files of the earlier version (v1.4–1.6), exported inside this resource
        removeFile(res, ('audio/%s_game.dat151.rel'):format(safeName(group)))
        removeFile(res, ('audio/%s_game.dat151.rel.xml'):format(safeName(group)))
    end
    for _, n in ipairs(st.ymts or {}) do
        removeFile(res, 'stream/' .. n .. '.ymt')
        removeFile(res, 'audio/occlusion/' .. n .. '.ymt.pso.xml')
    end
    if res ~= RES then -- standalone player of v1.7 (no longer exported)
        removeFile(res, 'molo_se/player.lua')
        removeFile(res, 'molo_se/data.json')
        pcall(os.remove, GetResourcePath(res) .. '/molo_se')
        pcall(os.remove, GetResourcePath(res) .. '/audio/occlusion')
    end
    return res
end

-- ─── Taking over the target's own audio files ───────────────────────
local function escPat(s) return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0')) end

-- AUDIO_GAMEDATA files declared by the resource itself (outside our block)
local function ownAudioFiles(res)
    local raw = readFile(res, 'fxmanifest.lua') or LoadResourceFile(res, 'fxmanifest.lua') or ''
    raw = stripBlock(stripBlock(raw, OLD_BEGIN, OLD_FINISH), BEGIN, FINISH)
    local out = {}
    for line in raw:gmatch('[^\n]+') do
        if not line:match('^%s*%-%-') then
            local dat = line:match("data_file%s*%(?%s*['\"]AUDIO_GAMEDATA['\"]%s*,?%s*['\"]([^'\"]+)['\"]")
            if dat then out[#out + 1] = dat:gsub('%.dat$', '.dat151.rel') end
        end
    end
    return out
end

-- Comment out the data_file line and drop the file entry of an absorbed audio file
local function unlistFromManifest(res, relFile)
    local raw = readFile(res, 'fxmanifest.lua') or LoadResourceFile(res, 'fxmanifest.lua')
    if not raw then return false, 'no fxmanifest.lua' end
    if not readFile(res, 'fxmanifest.lua.molo_backup') then writeFile(res, 'fxmanifest.lua.molo_backup', raw) end
    local dat = relFile:gsub('%.dat151%.rel$', '.dat')
    local new = raw:gsub("(\n?)([ \t]*)(data_file%s*%(?%s*['\"]AUDIO_GAMEDATA['\"]%s*,?%s*['\"]" .. escPat(dat) .. "['\"]%s*%)?)",
        '%1%2-- [moved into molo_soundemitters export] %3')
    new = new:gsub("['\"]" .. escPat(relFile) .. "['\"]%s*,?", '')
    new = new:gsub(',(%s*)}', '%1}'):gsub('{(%s*),', '{%1')
    local ok, err = load(new, 'fxmanifest', 't', {})
    if not ok then return false, 'manifest would break: ' .. tostring(err) end
    local w, werr = writeFile(res, 'fxmanifest.lua', new)
    if not w then return false, werr end
    return true
end

-- Returns raw items to carry over, notes
local function absorbTargetAudio(group, target, generated)
    local st = AudioState.groups[group] or {}
    local absorbed = st.absorbed or {}
    local sources, notes = {}, {}
    for _, b in ipairs(absorbed) do sources[#sources + 1] = { path = b, backup = true } end
    for _, f in ipairs(ownAudioFiles(target)) do
        if f ~= relPath(group) then sources[#sources + 1] = { path = f, backup = false } end
    end

    local candidates = {}
    for _, src in ipairs(sources) do
        local data = readFile(target, src.path)
        local parsed = data and RelWriter.read(data)
        if parsed then
            local allKnown, overlaps = true, false
            for _, it in ipairs(parsed.items) do
                if not it.known then allKnown = false end
                if generated[it.nameHash] then overlaps = true end
            end
            if src.backup or (allKnown and overlaps) then
                for _, it in ipairs(parsed.items) do candidates[#candidates + 1] = it end
                if not src.backup then
                    local name = src.path:match('([^/]+)$')
                    local backup = 'audio/_molo_backup/' .. name
                    writeFile(target, backup, data)
                    removeFile(target, src.path)
                    local ok, err = unlistFromManifest(target, src.path)
                    if not ok then
                        writeFile(target, src.path, data) -- put it back
                        notes[#notes + 1] = ('kept %s (%s)'):format(src.path, err)
                        for _ = 1, #parsed.items do table.remove(candidates) end
                    else
                        absorbed[#absorbed + 1] = backup
                        notes[#notes + 1] = ('took over %s (original in %s)'):format(src.path, backup)
                    end
                end
            elseif overlaps then
                notes[#notes + 1] = ('WARNING %s also defines this interior/doors and could not be merged'):format(src.path)
            end
        end
    end

    -- Drop what we regenerate, plus the rooms of an InteriorSettings we replace
    local drop = {}
    for h in pairs(generated) do drop[h] = true end
    for _, it in ipairs(candidates) do
        if it.typeId == 44 and generated[it.nameHash] then
            for _, r in ipairs(RelWriter.roomsOf(it)) do drop[r] = true end
        end
    end
    local raw, seen = {}, {}
    for _, it in ipairs(candidates) do
        if not drop[it.nameHash] and not seen[it.nameHash] then
            seen[it.nameHash] = true
            raw[#raw + 1] = { kind = 'Raw', typeId = it.typeId, bytes = it.bytes, ht = it.ht, nameHash = it.nameHash }
        end
    end
    return raw, notes, absorbed
end

-- Returns count, message
function ExportNativeAudio(group, elements)
    local target = GroupTarget(group)
    writeErrors = {}
    local prevRes = cleanPrevious(group)

    local items, ids = buildItems(group, elements)
    local absorbedList, absorbNotes = (AudioState.groups[group] or {}).absorbed, {}
    if target ~= RES then
        local generated = {}
        for _, it in ipairs(items) do generated[it.nameHash or RelWriter.hash(it.name)] = true end
        local raw
        raw, absorbNotes, absorbedList = absorbTargetAudio(group, target, generated)
        for _, it in ipairs(raw) do items[#items + 1] = it end
    end
    local ymts, ymtNotes = exportOcclusion(group, target)
    local parts, bytes = {}, 0

    if #items > 0 then
        local ok, bin = pcall(RelWriter.build, items, VERSION)
        if not ok then return -1, 'build failed: ' .. tostring(bin) end
        writeFile(target, relPath(group), bin)
        bytes = #bin
        parts[#parts + 1] = relPath(group)
    end
    -- Standalone player script (sounds, radios, vanilla emitters, mute zones, objects)
    local pcount = 0
    if target ~= RES then
        local skip, list = {}, {}
        for _, id in ipairs(ids) do skip[id] = true end
        for _, e in ipairs(elements) do
            if not skip[e.id] then
                local c = json.decode(json.encode(e))
                c.pack, c.native, c.label, c.group = nil, nil, nil, nil
                list[#list + 1] = c
            end
        end
        if #list > 0 then
            local data = json.encode(list)
            local eq = '=='
            while data:find(']' .. eq .. ']', 1, true) do eq = eq .. '=' end
            local code = ('local DATA_JSON = [%s[%s]%s]\n'):format(eq, data, eq) .. (LoadResourceFile(RES, 'runtime/player_template.lua') or '')
            if writeFile(target, playerPath(group), code) then pcount = #list end
            parts[#parts + 1] = ('%s (%d elements)'):format(playerPath(group), #list)
        end
    end
    for _, n in ipairs(ymtNotes) do parts[#parts + 1] = n end
    for _, n in ipairs(absorbNotes) do parts[#parts + 1] = n end

    if #items == 0 and #ymts == 0 and pcount == 0 then
        AudioState.groups[group] = nil
        saveState()
        if prevRes then writeManifest(prevRes) end
        writeManifest(target)
        return 0, 'nothing to export'
    end
    local skipped = 0
    for _, e in ipairs(elements) do
        if e.type ~= 'prop' and e.enabled ~= false and not IsNativeEligible(e) then skipped = skipped + 1 end
    end
    if #ids > 0 then parts[#parts + 1] = ('%d native emitter(s) in %s'):format(#ids, EmitterListName(group)) end
    if #noRoom > 0 then parts[#parts + 1] = ('WARNING %d emitter(s) not linked to a room, the game treats them as outside sounds and they are muffled inside (%s): stand in the room, press G on each one then E, and export again'):format(#noRoom, table.concat(noRoom, ', ')) end
    if skipped > 0 and target == RES then parts[#parts + 1] = ('%d element(s) not exportable natively (soundset sounds, alarms, random pauses, mute zones): editor only'):format(skipped) end

    AudioState.groups[group] = {
        at = os.date('%Y-%m-%d %H:%M'), target = target, count = #items, emitters = #ids, ids = ids,
        bytes = bytes, ymts = ymts, elements = pcount, pending = true, absorbed = absorbedList,
    }
    saveState()
    if prevRes and prevRes ~= target then writeManifest(prevRes) end
    local mok, merr, block = writeManifest(target)
    if not mok or #writeErrors > 0 then
        local msg = ('FiveM blocked writing into %s (%s). Add this line to server.cfg, then restart the server and export again:\n%s'):format(
            target, table.concat(writeErrors, ', '), permLine(target))
        print('^1[molo_soundemitters] ' .. msg .. '^7')
        return -1, msg
    end
    return #items + #ymts + pcount, ('%s → %s'):format(target, table.concat(parts, ', '))
end

function SetGroupTarget(group, target)
    target = (target and target ~= '') and target or nil
    if target and (GetResourceState(target) == 'missing' or not GetResourcePath(target)) then
        return false, ('resource "%s" not found'):format(target)
    end
    AudioState.targets[group] = target
    saveState()
    return true
end

local function manifestHasBlock(res)
    local raw = (GetResourcePath(res) and readFile(res, 'fxmanifest.lua')) or LoadResourceFile(res, 'fxmanifest.lua') or ''
    return raw:find(BEGIN, 1, true) ~= nil
end

-- Make sure every exported target's fxmanifest.lua has its block (re-patches it if it was lost)
function EnsureManifests(verbose)
    local done = {}
    for g, st in pairs(AudioState.groups) do
        local res = st.target or RES
        if not done[res] and GetResourceState(res) ~= 'missing' and (st.count or 0) > 0 then
            done[res] = true
            if not manifestHasBlock(res) then
                local ok, err, block = writeManifest(res)
                if ok and manifestHasBlock(res) then
                    print(('^2[molo_soundemitters] audio lines added to %s/fxmanifest.lua (refresh + restart %s)^7'):format(res, res))
                else
                    print(('^1[molo_soundemitters] could not patch %s/fxmanifest.lua (%s). FiveM blocks writing into another resource: add this line to server.cfg and restart the server:^7\n%s'):format(res, tostring(err), permLine(res)))
                end
            elseif verbose then
                print(('[molo_soundemitters] %s/fxmanifest.lua is up to date'):format(res))
            end
        end
    end
end

RegisterCommand('molo_se_manifest', function(src)
    if src ~= 0 then return end
    EnsureManifests(true)
end, true)

function AudioStatus()
    local out = {}
    for g, st in pairs(AudioState.groups) do
        local target = st.target or RES
        out[g] = {
            at = st.at, count = st.count, emitters = st.emitters, bytes = st.bytes, pending = st.pending,
            target = target, manifest = manifestHasBlock(target), external = target ~= RES and (st.elements or 0) > 0, elements = st.elements or 0, perm = permLine(target),
            file = relPath(g), ymts = st.ymts or {},
        }
    end
    for g, t in pairs(AudioState.targets) do
        out[g] = out[g] or {}
        out[g].wantedTarget = t
    end
    return out
end

-- ─── Startup: which groups were really loaded by the game ───────────
CreateThread(function()
    local raw = LoadResourceFile(RES, STATE_FILE)
    if raw and raw ~= '' then
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == 'table' then
            AudioState.groups = data.groups or {}
            AudioState.interiors = data.interiors or {}
            AudioState.targets = data.targets or {}
        end
    end
    for _, st in pairs(AudioState.groups) do
        local res = st.target or RES
        local manifest = (GetResourcePath(res) and readFile(res, 'fxmanifest.lua')) or LoadResourceFile(res, 'fxmanifest.lua') or ''
        if manifest:find(BEGIN, 1, true) or manifest:find(OLD_BEGIN, 1, true) then
            st.pending = false
            for _, id in ipairs(st.ids or {}) do loadedNative[id] = true end
        end
    end
    EnsureManifests(false)
    saveState()
end)
