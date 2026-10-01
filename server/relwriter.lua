-- molo_soundemitters — binary writer for GTA V game.dat151.rel files
-- Layout mirrors CodeWalker's RelFile.Save() (dexyfex/CodeWalker, RelFile.cs) for the item types below.
-- Only plain data is written: no name table, so items are identified by their name hashes.

RelWriter = {}

local function joaat(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end
RelWriter.joaat = joaat

-- Accepts a name, a "hash_XXXXXXXX" string, a number, or nil/'' (= 0)
local function H(v)
    if v == nil or v == '' or v == 0 then return 0 end
    if type(v) == 'number' then return math.floor(v) & 0xFFFFFFFF end
    local hex = tostring(v):match('^hash_(%x+)$')
    if hex then return tonumber(hex, 16) & 0xFFFFFFFF end
    return joaat(v)
end
RelWriter.hash = H

local TYPE = {
    StaticEmitter = 6,
    StaticEmitterList = 32,
    InteriorSettings = 44,
    InteriorRoom = 46,
    DoorAudioSettingsLink = 117,
}

local pack = string.pack

local function header(typeId) return pack('<I4', typeId & 0xFF) end -- ntOffset 0, type id in the low byte

local encoders = {}

function encoders.StaticEmitter(it)
    return header(TYPE.StaticEmitter) .. pack('<I4I4I4fffffi4I2I2I2I2I4I4I4fI2I2I4I4BBBBI2I2ff',
        it.flags or 0xAA041501,
        H(it.childSound or 'null_sound'),
        H(it.radioStation),
        it.x, it.y, it.z,
        it.minDistance or 0.0,
        it.maxDistance or 20.0,
        math.floor(it.volume or 0),
        it.lpf or 23900, it.hpf or 0,
        it.rolloff or 100, 0,
        H(it.interior), H(it.room),
        0,                              -- RadioStationForScore
        it.maxLeakage or 0.8,
        it.minLeakDist or 6, it.maxLeakDist or 15,
        H(it.alarm),
        H('null_sound'),                -- OnBreakOneShot
        it.maxPathDepth or 3, it.smallReverb or 0, it.mediumReverb or 0, it.largeReverb or 0,
        it.minTime or 0, it.maxTime or 1440,
        0.94, 0.99), nil                -- BrokenHealth / UndamagedHealth (vanilla values)
end

function encoders.StaticEmitterList(it)
    local b = { header(TYPE.StaticEmitterList), pack('<I4', #it.emitters) }
    for _, h in ipairs(it.emitters) do b[#b + 1] = pack('<I4', H(h)) end
    return table.concat(b), nil
end

function encoders.InteriorSettings(it)
    local b = { header(TYPE.InteriorSettings), pack('<I4I4I4I4', it.flags or 0xAAAAA044, H(it.walla or 'hash_D4855127'), H(it.reflections), #it.rooms) }
    local ht = {}
    for i, h in ipairs(it.rooms) do
        b[#b + 1] = pack('<I4', H(h))
        ht[#ht + 1] = 16 + (i - 1) * 4
    end
    return table.concat(b), ht
end

function encoders.InteriorRoom(it)
    return header(TYPE.InteriorRoom) .. pack('<I4I4I4BBi2fffI4BBi2fffffI4I4',
        it.flags or 0xAAAAAAAA,
        H(it.roomName),
        H(it.ambientZone),
        it.interiorType or 0, 0, 0,
        it.reverbSmall or 0.35, it.reverbMedium or 0.0, it.reverbLarge or 0.0,
        H(it.roomTone or 'null_sound'),
        it.rainType or 0, 0, 0,
        it.exteriorAudibility or 0.0,
        it.occlusionDamping or 0.0,
        it.nonMarkedPortalOcclusion or 0.7,
        it.portalOcclusionDistance or 0.0,
        it.portalFadeDistance or 50.0,
        H(it.weaponMetrics),
        H(it.walla or 'hash_D4855127')), { 8 }
end

function encoders.DoorAudioSettingsLink(it)
    return header(TYPE.DoorAudioSettingsLink) .. pack('<I4', H(it.door)), { 0 }
end

-- Item copied as-is from another .dat151.rel (see RelWriter.read); its hash-table offsets must be known
function encoders.Raw(it)
    return string.char(it.typeId) .. '\0\0\0' .. it.bytes:sub(5), it.ht -- name-table offset cleared (no name table here)
end

local ALIGN4 = { [TYPE.StaticEmitterList] = true }

local function rot8(h) return ((h >> 8) | (h << 24)) & 0xFFFFFFFF end

-- items: { { kind = 'StaticEmitter', name = 'x', ... }, ... } — written in the given order
function RelWriter.build(items, version)
    local data = { pack('<I4', version or 45897013) }
    local pos = 4
    local entries, htOffsets = {}, {}

    for _, it in ipairs(items) do
        local enc = encoders[it.kind]
        if not enc then error('unknown rel item kind: ' .. tostring(it.kind)) end
        if ALIGN4[it.kind == 'Raw' and it.typeId or TYPE[it.kind]] then
            while pos % 4 ~= 0 do data[#data + 1] = '\0'; pos = pos + 1 end
        end
        local bytes, ht = enc(it)
        local nameHash = it.nameHash or H(it.name)
        entries[#entries + 1] = { hash = nameHash, offset = pos, length = #bytes }
        if ht then
            for _, o in ipairs(ht) do htOffsets[#htOffsets + 1] = pos + 12 + o end
        end
        data[#data + 1] = bytes
        pos = pos + #bytes
    end

    local block = table.concat(data)
    table.sort(entries, function(a, b) return rot8(a.hash) < rot8(b.hash) end)

    local out = {
        pack('<I4I4', 151, #block), block,
        pack('<I4I4', 4, 0),            -- name table: length 4, count 0
        pack('<I4', #entries),
    }
    for _, e in ipairs(entries) do out[#out + 1] = pack('<I4I4I4', e.hash, e.offset, e.length) end
    out[#out + 1] = pack('<I4', #htOffsets)
    for _, o in ipairs(htOffsets) do out[#out + 1] = pack('<I4', o) end
    out[#out + 1] = pack('<I4', 0)      -- pack table
    return table.concat(out)
end

-- Same content as CodeWalker XML (for checking in CodeWalker or diffing)
function RelWriter.toXml(items, version)
    local function hs(v)
        local h = H(v)
        if h == 0 then return '' end
        if type(v) == 'string' and not v:match('^hash_') then return v:lower() end
        return ('hash_%08X'):format(h)
    end
    local function f(v) return (('%.6g'):format(v)) end
    local L = { '<?xml version="1.0" encoding="UTF-8"?>', '<Dat151>', (' <Version value="%d" />'):format(version or 45897013), ' <Items>' }
    local function add(s) L[#L + 1] = s end
    for _, it in ipairs(items) do
        add(('  <Item type="%s" ntOffset="0">'):format(it.kind))
        add(('   <Name>%s</Name>'):format(it.name and hs(it.name) or ('hash_%08X'):format(it.nameHash)))
        if it.kind == 'StaticEmitter' then
            add(('   <Flags value="0x%08X" />'):format(it.flags or 0xAA041501))
            add(('   <ChildSound>%s</ChildSound>'):format(hs(it.childSound or 'null_sound')))
            add(('   <RadioStation>%s</RadioStation>'):format(hs(it.radioStation)))
            add(('   <Position x="%s" y="%s" z="%s" />'):format(f(it.x), f(it.y), f(it.z)))
            add(('   <MinDistance value="%s" />'):format(f(it.minDistance or 0)))
            add(('   <MaxDistance value="%s" />'):format(f(it.maxDistance or 20)))
            add(('   <EmittedVolume value="%d" />'):format(math.floor(it.volume or 0)))
            add(('   <LPFCutoff value="%d" />'):format(it.lpf or 23900))
            add(('   <HPFCutoff value="%d" />'):format(it.hpf or 0))
            add(('   <RolloffFactor value="%d" />'):format(it.rolloff or 100))
            add(('   <Interior>%s</Interior>'):format(hs(it.interior)))
            add(('   <Room>%s</Room>'):format(hs(it.room)))
            add('   <RadioStationForScore />')
            add(('   <MaxLeakage value="%s" />'):format(f(it.maxLeakage or 0.8)))
            add(('   <MinLeakageDistance value="%d" />'):format(it.minLeakDist or 6))
            add(('   <MaxLeakageDistance value="%d" />'):format(it.maxLeakDist or 15))
            add(('   <Alarm>%s</Alarm>'):format(hs(it.alarm)))
            add('   <OnBreakOneShot>null_sound</OnBreakOneShot>')
            add(('   <MaxPathDepth value="%d" />'):format(it.maxPathDepth or 3))
            add(('   <SmallReverbSend value="%d" />'):format(it.smallReverb or 0))
            add(('   <MediumReverbSend value="%d" />'):format(it.mediumReverb or 0))
            add(('   <LargeReverbSend value="%d" />'):format(it.largeReverb or 0))
            add(('   <MinTimeMinutes value="%d" />'):format(it.minTime or 0))
            add(('   <MaxTimeMinutes value="%d" />'):format(it.maxTime or 1440))
            add('   <BrokenHealth value="0.94" />')
            add('   <UndamagedHealth value="0.99" />')
        elseif it.kind == 'StaticEmitterList' then
            add('   <Emitters>')
            for _, e in ipairs(it.emitters) do add(('    <Item>%s</Item>'):format(hs(e))) end
            add('   </Emitters>')
        elseif it.kind == 'InteriorSettings' then
            add(('   <Flags value="0x%08X" />'):format(it.flags or 0xAAAAA044))
            add(('   <InteriorWallaSoundSet>%s</InteriorWallaSoundSet>'):format(hs(it.walla or 'hash_D4855127')))
            add(('   <InteriorReflections>%s</InteriorReflections>'):format(hs(it.reflections)))
            add('   <Rooms>')
            for _, r in ipairs(it.rooms) do add(('    <Item>%s</Item>'):format(hs(r))) end
            add('   </Rooms>')
        elseif it.kind == 'InteriorRoom' then
            add(('   <Flags value="0x%08X" />'):format(it.flags or 0xAAAAAAAA))
            add(('   <RoomName>%s</RoomName>'):format(hs(it.roomName)))
            add(('   <AmbientZone>%s</AmbientZone>'):format(hs(it.ambientZone)))
            add(('   <InteriorType value="%d" />'):format(it.interiorType or 0))
            add(('   <ReverbSmall value="%s" />'):format(f(it.reverbSmall or 0.35)))
            add(('   <ReverbMedium value="%s" />'):format(f(it.reverbMedium or 0)))
            add(('   <ReverbLarge value="%s" />'):format(f(it.reverbLarge or 0)))
            add(('   <RoomToneSound>%s</RoomToneSound>'):format(hs(it.roomTone or 'null_sound')))
            add(('   <RainType value="%d" />'):format(it.rainType or 0))
            add(('   <ExteriorAudibility value="%s" />'):format(f(it.exteriorAudibility or 0)))
            add(('   <RoomOcclusionDamping value="%s" />'):format(f(it.occlusionDamping or 0)))
            add(('   <NonMarkedPortalOcclusion value="%s" />'):format(f(it.nonMarkedPortalOcclusion or 0.7)))
            add(('   <DistanceFromPortalForOcclusion value="%s" />'):format(f(it.portalOcclusionDistance or 0)))
            add(('   <DistanceFromPortalFadeDistance value="%s" />'):format(f(it.portalFadeDistance or 50)))
            add(('   <WeaponMetrics>%s</WeaponMetrics>'):format(hs(it.weaponMetrics)))
            add(('   <InteriorWallaSoundSet>%s</InteriorWallaSoundSet>'):format(hs(it.walla or 'hash_D4855127')))
        elseif it.kind == 'DoorAudioSettingsLink' then
            add(('   <Door>%s</Door>'):format(hs(it.door)))
        end
        add('  </Item>')
    end
    add(' </Items>')
    add('</Dat151>')
    return table.concat(L, '\n')
end

-- ─── Reader ─────────────────────────────────────────────────────────
-- Hash-table offsets (relative to the data after the 4-byte item header) of the types we can carry over
local function rawHashTable(typeId, bytes)
    if typeId == 44 then -- InteriorSettings: one per room
        local count = string.unpack('<I4', bytes, 17)
        local t = {}
        for i = 0, count - 1 do t[#t + 1] = 16 + i * 4 end
        return t
    elseif typeId == 46 then return { 8 }   -- InteriorRoom
    elseif typeId == 47 then return { 4 }   -- DoorAudioSettings
    elseif typeId == 117 then return { 0 }  -- DoorAudioSettingsLink
    elseif typeId == 6 or typeId == 32 then return nil -- StaticEmitter / StaticEmitterList
    end
    return false -- unknown layout
end

-- Returns { version, items = { {nameHash, typeId, bytes, ht, known} ... } in data order } or nil, err
function RelWriter.read(data)
    if #data < 8 then return nil, 'file too small' end
    local relType, dataLen = string.unpack('<I4I4', data, 1)
    if relType ~= 151 then return nil, 'not a dat151 file' end
    local block = data:sub(9, 8 + dataLen)
    local pos = 9 + dataLen
    local _, ntCount = string.unpack('<I4I4', data, pos)
    pos = pos + 8 + 4 * ntCount
    for _ = 1, ntCount do pos = (data:find('\0', pos, true) or #data) + 1 end
    local count = string.unpack('<I4', data, pos)
    pos = pos + 4
    local items = {}
    for _ = 1, count do
        local h, off, len = string.unpack('<I4I4I4', data, pos)
        pos = pos + 12
        local bytes = block:sub(off + 1, off + len)
        local typeId = bytes:byte(1)
        local ht = rawHashTable(typeId, bytes)
        items[#items + 1] = { nameHash = h, offset = off, typeId = typeId, bytes = bytes, ht = ht or nil, known = ht ~= false }
    end
    table.sort(items, function(a, b) return a.offset < b.offset end)
    return { version = string.unpack('<I4', block, 1), items = items }
end

-- Hashes of the rooms listed by an InteriorSettings item
function RelWriter.roomsOf(item)
    local out = {}
    if item.typeId ~= 44 then return out end
    local count = string.unpack('<I4', item.bytes, 17)
    for i = 0, count - 1 do out[#out + 1] = string.unpack('<I4', item.bytes, 21 + i * 4) end
    return out
end
