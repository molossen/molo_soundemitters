-- molo_soundemitters — client: streaming of sounds, ambient emitters, radios, vanilla emitters and objects
Emitters = {}            -- id -> element (server data)
InteriorNames = {}       -- "unsigned hash" -> name
local active = {}        -- id -> runtime audio state
local props = {}         -- id -> object entity (false = model failed)
local localOverride = {} -- id -> bool (client export)
local banks = {}         -- name -> refcount
local interiorCache = {} -- id -> interiorId at the element position

-- ─── Loading helpers ────────────────────────────────────────────────
local function loadBank(name, kind)
    if not name then return true end
    if banks[name] then banks[name] = banks[name] + 1 return true end
    local deadline, ok = GetGameTimer() + 3000, false
    while GetGameTimer() < deadline do
        if kind == 'ambient' then ok = RequestAmbientAudioBank(name, false) else ok = RequestScriptAudioBank(name, false) end
        if ok then break end
        Wait(50)
    end
    if not ok then
        print(('^3[molo_soundemitters] audio bank not found: %s^7'):format(name))
        return false
    end
    banks[name] = 1
    return true
end

local function releaseBank(name, kind)
    if not name or not banks[name] then return end
    banks[name] = banks[name] - 1
    if banks[name] <= 0 then
        banks[name] = nil
        if kind ~= 'ambient' then ReleaseNamedScriptAudioBank(name) end -- ambient banks have no named release
    end
end

function LoadModelSafe(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelInCdimage(hash) then return nil end
    RequestModel(hash)
    local deadline = GetGameTimer() + 3000
    while not HasModelLoaded(hash) and GetGameTimer() < deadline do Wait(10) end
    return HasModelLoaded(hash) and hash or nil
end

-- ─── Audio primitives ───────────────────────────────────────────────
function PlaySound3D(name, set, x, y, z, range, soundId)
    local id = soundId or GetSoundId()
    PlaySoundFromCoord(id, name, x, y, z, (set and set ~= '') and set or 0, false, math.floor(range or 0), false)
    return id
end

-- Moves a vanilla static emitter onto an entity (a placed object, or an invisible anchor created here).
-- Returns the anchor entity when this function created it (so the caller can delete it later).
function AttachEmitter(emitter, x, y, z, entity)
    local owned = nil
    if not entity or not DoesEntityExist(entity) then
        local hash = LoadModelSafe(Config.SupportModel)
        if not hash then return nil end
        entity = CreateObjectNoOffset(hash, x, y, z, false, false, false)
        SetModelAsNoLongerNeeded(hash)
        SetEntityCollision(entity, false, false)
        FreezeEntityPosition(entity, true)
        SetEntityVisible(entity, false, false)
        owned = entity
    end
    LinkStaticEmitterToEntity(emitter, entity)
    SetStaticEmitterEnabled(emitter, true)
    return owned
end

function DetachEmitter(emitter, ownedEntity)
    SetStaticEmitterEnabled(emitter, false)
    if ownedEntity and DoesEntityExist(ownedEntity) then DeleteEntity(ownedEntity) end
end

function StartAlarmSafe(alarm)
    local deadline = GetGameTimer() + 3000
    while not PrepareAlarm(alarm) and GetGameTimer() < deadline do Wait(50) end
    StartAlarm(alarm, true)
end

-- ─── Objects ────────────────────────────────────────────────────────
function SpawnPropFor(e)
    local p = e.prop
    local hash = LoadModelSafe(p.model)
    if not hash then return nil end
    local obj = CreateObjectNoOffset(hash, p.px, p.py, p.pz, false, false, false)
    SetModelAsNoLongerNeeded(hash)
    SetEntityHeading(obj, p.heading or 0.0)
    FreezeEntityPosition(obj, true)
    SetEntityInvincible(obj, true)
    return obj
end

local function deleteProp(id)
    local obj = props[id]
    if obj and DoesEntityExist(obj) then DeleteEntity(obj) end
    props[id] = nil
end

-- ─── Start / stop audio ─────────────────────────────────────────────
local function start(e)
    local st = { type = e.type, ref = e }
    if e.type == 'sound' then
        local s = e.sound
        if s.bank and loadBank(s.bank, s.bankType) then st.bank, st.bankType = s.bank, s.bankType end
        st.soundId = PlaySound3D(s.name, s.set, e.x, e.y, e.z, e.range)
    elseif e.type == 'ambient' then
        st.owned = AttachEmitter(e.ambient.emitter, e.x, e.y, e.z, props[e.id])
        if e.ambient.alarm then CreateThread(function() StartAlarmSafe(e.ambient.alarm) end) end
    elseif e.type == 'radio' then
        st.owned = AttachEmitter(e.radio.emitter, e.x, e.y, e.z, props[e.id])
        SetEmitterRadioStation(e.radio.emitter, e.radio.station)
    elseif e.type == 'static' then
        SetStaticEmitterEnabled(e.static.name, e.static.enabled)
        if e.static.enabled and e.static.station then SetEmitterRadioStation(e.static.name, e.static.station) end
    end
    active[e.id] = st
end

local function stop(id)
    local st = active[id]
    if not st then return end
    if st.type == 'sound' then
        if st.soundId then StopSound(st.soundId) ReleaseSoundId(st.soundId) end
        releaseBank(st.bank, st.bankType)
    elseif st.type == 'ambient' then
        if st.ref.ambient.alarm then StopAlarm(st.ref.ambient.alarm, true) end
        DetachEmitter(st.ref.ambient.emitter, st.owned)
    elseif st.type == 'radio' then
        DetachEmitter(st.ref.radio.emitter, st.owned)
    elseif st.type == 'static' then
        SetStaticEmitterEnabled(st.ref.static.name, st.ref.static.default ~= false)
    end
    active[id] = nil
end

local function clear(id)
    stop(id)
    deleteProp(id)
    interiorCache[id] = nil
end

local function clearAll()
    for id in pairs(active) do stop(id) end
    for id in pairs(props) do deleteProp(id) end
    interiorCache = {}
end

-- ─── Conditions ─────────────────────────────────────────────────────
local function inHours(h)
    if not h then return true end
    local now = GetClockHours()
    if h.from <= h.to then return now >= h.from and now < h.to end
    return now >= h.from or now < h.to -- window across midnight (e.g. 22 -> 6)
end

local function interiorOk(e, pedInterior)
    if not e.interiorOnly then return true end
    local int = interiorCache[e.id]
    if not int or int == 0 then
        int = GetInteriorAtCoords(e.x, e.y, e.z)
        interiorCache[e.id] = int
    end
    return int ~= 0 and int == pedInterior
end

-- ─── Streaming loop ─────────────────────────────────────────────────
CreateThread(function()
    TriggerServerEvent('molo_se:requestAll')
    TriggerServerEvent('molo_se:getAudioState')
    while true do
        local ped = PlayerPedId()
        local p = GetEntityCoords(ped)
        local pedInterior = GetInteriorFromEntity(ped)
        local candidates = {}
        -- groups exported with their own player into a running MLO resource: don't play them twice
        local external = {}
        for g, st in pairs(AudioStateCache and AudioStateCache.status or {}) do
            if st.external and st.target and GetResourceState(st.target) == 'started' then external[g] = true end
        end

        for id, e in pairs(Emitters) do
            local enabled = e.enabled
            if localOverride[id] ~= nil then enabled = localOverride[id] end

            -- Objects
            if e.prop then
                local showProp = not external[e.group] and (e.type ~= 'prop' or enabled) and #(p - vector3(e.prop.px, e.prop.py, e.prop.pz)) < Config.PropDistance
                if showProp and props[id] == nil then
                    props[id] = SpawnPropFor(e) or false
                elseif not showProp and props[id] ~= nil then
                    if active[id] then stop(id) end -- an emitter linked to the object must be stopped first
                    deleteProp(id)
                end
            end

            -- Audio (elements inside a loaded native .dat151.rel are played by the game itself)
            if enabled and e.type ~= 'prop' and not e.native and not external[e.group] then
                local d = #(p - vector3(e.x, e.y, e.z))
                local limit = e.range + (active[id] and Config.StreamMargin or 0.0)
                if d <= limit and inHours(e.hours) and interiorOk(e, pedInterior) then
                    candidates[#candidates + 1] = { id = id, d = d }
                end
            end
        end

        table.sort(candidates, function(a, b) return a.d < b.d end)
        local keep = {}
        for i = 1, math.min(#candidates, Config.MaxActive) do keep[candidates[i].id] = true end
        for id in pairs(active) do if not keep[id] then stop(id) end end

        local now = GetGameTimer()
        for id in pairs(keep) do
            local st = active[id]
            if not st then
                start(Emitters[id])
            elseif st.type == 'sound' and st.soundId and HasSoundFinished(st.soundId) then
                local s = st.ref.sound
                if s['repeat'] then
                    if not st.nextAt then
                        local dmin, dmax = s.delayMin or 0, s.delayMax or 0
                        st.nextAt = now + math.floor((dmin + math.random() * (dmax - dmin)) * 1000)
                    elseif now >= st.nextAt then
                        st.nextAt = nil
                        PlaySound3D(s.name, s.set, st.ref.x, st.ref.y, st.ref.z, st.ref.range, st.soundId)
                    end
                end
            end
        end

        Wait(Config.TickMs)
    end
end)

-- ─── Server sync ────────────────────────────────────────────────────
RegisterNetEvent('molo_se:sync', function(list, names)
    clearAll()
    Emitters = {}
    for _, e in ipairs(list) do Emitters[e.id] = e end
    InteriorNames = names or {}
    if EditorRefresh then EditorRefresh() end
end)

RegisterNetEvent('molo_se:upsert', function(e)
    clear(e.id)
    Emitters[e.id] = e
    if EditorRefresh then EditorRefresh() end
end)

RegisterNetEvent('molo_se:remove', function(id)
    clear(id)
    Emitters[id] = nil
    if EditorRefresh then EditorRefresh() end
end)

RegisterNetEvent('molo_se:interiorNames', function(names)
    InteriorNames = names or {}
    if EditorRefresh then EditorRefresh() end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then clearAll() end
end)

-- ─── Client exports ─────────────────────────────────────────────────
exports('SetLocalEmitterEnabled', function(id, state) localOverride[id] = state end) -- nil = back to server state
exports('IsEmitterActive', function(id) return active[id] ~= nil end)
exports('GetEmitters', function() return Emitters end)
exports('GetPropEntity', function(id) return props[id] end)
