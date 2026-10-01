-- molo_soundemitters — client: menu + in-game editor (aim, place, move, edit)
local open, panelOpen = false, false
local template = nil               -- element placed with E
local range = Config.DefaultRange
local heightOff, heading = 0.0, 0.0
local group = Config.DefaultGroup
local movingId, hoverId = nil, nil
local deleteArmed = { id = nil, t = 0 }
local aim = nil                    -- { sound = vec3, prop = vec3, hit = vec3 }
local ghostObj, ghostModel = nil, nil
local preview = nil
local roomCache = {}               -- interiorId -> { room names }

local COLORS = {
    sound   = { 90, 170, 255 },
    ambient = { 70, 210, 195 },
    radio   = { 255, 165, 60 },
    static  = { 120, 215, 130 },
    prop    = { 190, 140, 255 },
    off     = { 140, 140, 140 },
}
local K = Config.Keys

-- ─── Helpers ────────────────────────────────────────────────────────
local function nui(action, data) SendNUIMessage({ action = action, data = data }) end
local function notify(msg, kind) nui('notify', { msg = msg, kind = kind or 'info' }) end
RegisterNetEvent('molo_se:notify', notify)

local function u32(h) return math.floor(tonumber(h) or 0) & 0xFFFFFFFF end

local function rotToDir(rot)
    local rz, rx = math.rad(rot.z), math.rad(rot.x)
    local n = math.abs(math.cos(rx))
    return vector3(-math.sin(rz) * n, math.cos(rz) * n, math.sin(rx))
end

local function raycast()
    local cam = GetGameplayCamCoord()
    local dir = rotToDir(GetGameplayCamRot(2))
    local dest = cam + dir * Config.RayDistance
    local h = StartExpensiveSynchronousShapeTestLosProbe(cam.x, cam.y, cam.z, dest.x, dest.y, dest.z, 1 | 16, PlayerPedId(), 7)
    local _, hit, endC, normal, ent = GetShapeTestResult(h)
    if hit == 1 then return endC, normal, cam, dir, ent end
    local p = cam + dir * 8.0
    return p, vector3(0.0, 0.0, 1.0), cam, dir, 0
end

local function distToRay(p, origin, dir)
    local v = p - origin
    local t = v.x * dir.x + v.y * dir.y + v.z * dir.z
    if t < 0 then return 9999.0 end
    return #(v - dir * t)
end

local function text3D(x, y, z, txt, scale)
    local on, sx, sy = World3dToScreen2d(x, y, z)
    if not on then return end
    SetTextScale(0.0, scale or 0.3)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 215)
    SetTextOutline()
    SetTextCentre(true)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(txt)
    EndTextCommandDisplayText(sx, sy)
end

local function sphere(p, r, c, a)
    DrawMarker(28, p.x, p.y, p.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r, r, r, c[1], c[2], c[3], a, false, false, 2, false, nil, nil, false)
end

local function hasProp(t) return t and t.prop and t.prop.model and t.prop.model ~= '' end

local function describe(t)
    if not t then return nil end
    local base
    if t.type == 'sound' then base = (t.sound.set and t.sound.set ~= '' and (t.sound.set .. ' › ') or '') .. t.sound.name
    elseif t.type == 'ambient' then base = 'Ambient › ' .. t.ambient.emitter
    elseif t.type == 'radio' then base = 'Radio › ' .. t.radio.station
    elseif t.type == 'static' then base = 'Vanilla › ' .. t.static.name .. (t.static.enabled and ' (ON)' or ' (OFF)')
    elseif t.type == 'prop' then return 'Object › ' .. t.prop.model end
    if hasProp(t) then base = base .. '  +  ' .. t.prop.model end
    return base
end

local function emitterList()
    local out = {}
    for _, e in pairs(Emitters) do out[#out + 1] = e end
    return out
end

-- ─── Current interior ───────────────────────────────────────────────
local function roomNames(int)
    if roomCache[int] then return roomCache[int] end
    local names = {}
    for i = 0, GetInteriorRoomCount(int) - 1 do names[#names + 1] = GetInteriorRoomName(int, i) or ('room ' .. i) end
    roomCache[int] = names
    return names
end

local function interiorSnapshot()
    local ped = PlayerPedId()
    local int = GetInteriorFromEntity(ped)
    local p = GetEntityCoords(ped)
    local info = { inside = int ~= 0, id = int, player = { x = p.x, y = p.y, z = p.z } }
    if int ~= 0 then
        local _, nameHash = GetInteriorLocationAndNamehash(int)
        local ix, iy, iz = GetInteriorPosition(int)
        local roomKey = GetRoomKeyFromEntity(ped)
        info.hash = u32(nameHash)
        info.pos = { x = ix, y = iy, z = iz }
        info.roomHash = u32(roomKey)
        info.roomIndex = GetInteriorRoomIndexByHash(int, roomKey)
        info.rooms = roomNames(int)
        info.portals = GetInteriorPortalCount(int)
    end
    if aim then
        local aimInt = GetInteriorAtCoords(aim.sound.x, aim.sound.y, aim.sound.z)
        info.aimInside = aimInt ~= 0
        info.aimSame = aimInt ~= 0 and aimInt == int
    end
    return info
end

-- ─── Ghost object ───────────────────────────────────────────────────
local function clearGhost()
    if ghostObj and DoesEntityExist(ghostObj) then DeleteEntity(ghostObj) end
    ghostObj, ghostModel = nil, nil
end

local function updateGhost(model, pos)
    if not model then return clearGhost() end
    if model ~= ghostModel then
        clearGhost()
        ghostModel = model
        local hash = LoadModelSafe(model)
        if not hash then notify('Model not found: ' .. model, 'error') return end
        ghostObj = CreateObjectNoOffset(hash, pos.x, pos.y, pos.z, false, false, false)
        SetModelAsNoLongerNeeded(hash)
        SetEntityCollision(ghostObj, false, false)
        FreezeEntityPosition(ghostObj, true)
        SetEntityAlpha(ghostObj, 170, false)
    end
    if ghostObj then
        SetEntityCoordsNoOffset(ghostObj, pos.x, pos.y, pos.z, false, false, false)
        SetEntityHeading(ghostObj, heading)
    end
end

-- ─── Preview ────────────────────────────────────────────────────────
local function stopPreview()
    if not preview then return end
    if preview.kind == 'sound' then
        StopSound(preview.id) ReleaseSoundId(preview.id)
        if preview.bank then ReleaseNamedScriptAudioBank(preview.bank) end
    elseif preview.kind == 'emitter' then
        if preview.alarm then StopAlarm(preview.alarm, true) end
        DetachEmitter(preview.name, preview.owned)
    elseif preview.kind == 'static' then
        SetStaticEmitterEnabled(preview.name, preview.default)
    end
    preview = nil
end

local function startPreview(t, p)
    stopPreview()
    if not t then return notify('Nothing to preview: pick something in the menu (TAB)', 'error') end
    p = p or GetEntityCoords(PlayerPedId())
    if t.type == 'sound' then
        local bank
        if t.sound.bank then
            if t.sound.bankType == 'ambient' then RequestAmbientAudioBank(t.sound.bank, false)
            else RequestScriptAudioBank(t.sound.bank, false) bank = t.sound.bank end
        end
        local id = PlaySound3D(t.sound.name, t.sound.set, p.x, p.y, p.z, range)
        preview = { kind = 'sound', id = id, bank = bank, untilT = GetGameTimer() + 12000 }
        -- A sound already "finished" a couple of frames after starting never actually played
        CreateThread(function()
            Wait(0) Wait(0)
            if preview and preview.id == id and HasSoundFinished(id) then
                notify("This sound didn't play (it probably needs an audio bank). You can hide it from the list.", 'warn')
                nui('soundFailed', { name = t.sound.name, set = t.sound.set })
            end
        end)
    elseif t.type == 'ambient' then
        local owned = AttachEmitter(t.ambient.emitter, p.x, p.y, p.z, nil)
        if t.ambient.alarm then CreateThread(function() StartAlarmSafe(t.ambient.alarm) end) end
        preview = { kind = 'emitter', name = t.ambient.emitter, alarm = t.ambient.alarm, owned = owned, untilT = GetGameTimer() + 20000 }
    elseif t.type == 'radio' then
        local owned = AttachEmitter(RadioPreviewEmitter, p.x, p.y, p.z, nil)
        SetEmitterRadioStation(RadioPreviewEmitter, t.radio.station)
        preview = { kind = 'emitter', name = RadioPreviewEmitter, owned = owned, untilT = GetGameTimer() + 20000 }
    elseif t.type == 'static' then
        SetStaticEmitterEnabled(t.static.name, true)
        if t.static.station then SetEmitterRadioStation(t.static.name, t.static.station) end
        preview = { kind = 'static', name = t.static.name, default = t.static.default ~= false, untilT = GetGameTimer() + 15000 }
    else
        notify('An object on its own has no sound', 'info')
    end
end

-- ─── Actions ────────────────────────────────────────────────────────
local function applyPlacement(d)
    local int = GetInteriorAtCoords(aim.sound.x, aim.sound.y, aim.sound.z)
    -- a point aimed on a wall/floor is often just outside the interior bounds: use the player's interior then
    local pedInt = GetInteriorFromEntity(PlayerPedId())
    if pedInt ~= 0 and (int == 0 or #(GetEntityCoords(PlayerPedId()) - vector3(aim.sound.x, aim.sound.y, aim.sound.z)) < 60.0) then int = pedInt end
    d.x, d.y, d.z, d.range = aim.sound.x, aim.sound.y, aim.sound.z, range
    d.interiorHash, d.roomHash, d.roomName = 0, 0, nil
    if int ~= 0 then
        local _, nameHash = GetInteriorLocationAndNamehash(int)
        d.interiorHash = nameHash
        local ped = PlayerPedId()
        if GetInteriorFromEntity(ped) == int then
            local key = GetRoomKeyFromEntity(ped)
            d.roomHash = key
            local idx = GetInteriorRoomIndexByHash(int, key)
            if idx and idx >= 0 then d.roomName = GetInteriorRoomName(int, idx) end
        end
    end
    if hasProp(d) then
        d.prop.px, d.prop.py, d.prop.pz, d.prop.heading = aim.prop.x, aim.prop.y, aim.prop.z, heading
    end
    return d
end

local function placeOrConfirm()
    if not aim then return end
    if movingId then
        local e = Emitters[movingId]
        if e then TriggerServerEvent('molo_se:save', applyPlacement(json.decode(json.encode(e)))) end
        movingId = nil
        return
    end
    if not template then return notify('Pick something to place in the menu first (TAB)', 'error') end
    local d = json.decode(json.encode(template))
    d.id, d.group, d.enabled = nil, group, true
    TriggerServerEvent('molo_se:save', applyPlacement(d))
end

local function openPanel(tab, editId)
    panelOpen = true
    SetNuiFocus(true, true)
    nui('names', InteriorNames)
    nui('soundCheck', SoundCheck)
    if AudioStateCache then nui('audioState', AudioStateCache) end
    nui('panel', { tab = tab, editId = editId, emitters = emitterList(), group = group, range = range, interior = interiorSnapshot() })
end

local function closePanel()
    panelOpen = false
    SetNuiFocus(false, false)
    nui('panelClose')
end

EditorRefresh = function()
    if not open then return end
    nui('names', InteriorNames)
    if panelOpen then nui('emitters', { emitters = emitterList(), interior = interiorSnapshot() }) end
    if movingId and not Emitters[movingId] then movingId = nil end
end

local function closeEditor()
    stopPreview()
    clearGhost()
    if panelOpen then closePanel() end
    open, movingId, hoverId, aim = false, nil, nil, nil
    nui('close')
end

local function startMove(e)
    movingId, range, heightOff = e.id, e.range, 0.0
    heading = e.prop and e.prop.heading or heading
end

-- ─── Editor loop ────────────────────────────────────────────────────
local DISABLED = { 24, 25, 37, 38, 44, 45, 47, 73, 74, 14, 15, 16, 17, 140, 141, 142, 257, 263, 264, 99, 100, 115, 116, 261, 262, 174, 175, 177 }

local function editorLoop()
    local lastHud, lastInt = 0, 0
    while open do
        local now = GetGameTimer()
        if preview and now > preview.untilT then stopPreview() end
        local current = movingId and Emitters[movingId] or template

        -- Aim
        local origin, dir
        if not panelOpen then
            local hit, normal, ent
            hit, normal, origin, dir, ent = raycast()
            local lift = vector3(0.0, 0.0, heightOff)
            if hasProp(current) then
                aim = { prop = hit + lift, sound = hit + lift + vector3(0.0, 0.0, Config.PropSoundOffset) }
            else
                aim = { prop = hit + lift, sound = hit + normal * Config.SurfaceOffset + lift }
            end
            aim.hit = hit
            aim.entity = (ent and ent ~= 0 and DoesEntityExist(ent) and GetEntityType(ent) == 3) and ent or nil
            updateGhost(hasProp(current) and current.prop.model or nil, aim.prop)
            if ghostObj then SetEntityVisible(ghostObj, true, false) end
        elseif ghostObj then
            SetEntityVisible(ghostObj, false, false)
        end

        -- Existing elements
        local ped = GetEntityCoords(PlayerPedId())
        local bestId, bestD = nil, 0.8
        for id, e in pairs(Emitters) do
            local p = vector3(e.x, e.y, e.z)
            local dist = #(ped - p)
            if dist < Config.EditorDrawDistance and id ~= movingId then
                local c = e.enabled and COLORS[e.type] or COLORS.off
                sphere(p, 0.22, c, 200)
                if e.type == 'static' and e.static.vx then
                    DrawLine(p.x, p.y, p.z, e.static.vx, e.static.vy, e.static.vz, c[1], c[2], c[3], 160)
                end
                if dist < 25.0 then text3D(p.x, p.y, p.z + 0.35, (e.label or e.id) .. (e.pack and '  [pack]' or ''), 0.28) end
                if origin then
                    local rd = distToRay(p, origin, dir)
                    if rd < bestD then bestD, bestId = rd, id end
                end
            end
        end
        if not panelOpen then hoverId = bestId end

        if hoverId and Emitters[hoverId] and not movingId then
            local e = Emitters[hoverId]
            local p = vector3(e.x, e.y, e.z)
            if e.type ~= 'prop' then sphere(p, e.range, COLORS[e.type], 22) end
            sphere(p, 0.35, { 255, 255, 255 }, 120)
        end

        -- Ghost
        if aim and not panelOpen then
            local c = current and COLORS[current.type] or { 255, 255, 255 }
            sphere(aim.sound, 0.2, { 255, 255, 255 }, 230)
            if not current or current.type ~= 'prop' then sphere(aim.sound, range, c, 28) end
            if heightOff ~= 0.0 then DrawLine(aim.hit.x, aim.hit.y, aim.hit.z, aim.prop.x, aim.prop.y, aim.prop.z, 255, 255, 255, 180) end
            if current and current.type == 'static' and current.static.vx then
                DrawLine(aim.sound.x, aim.sound.y, aim.sound.z, current.static.vx, current.static.vy, current.static.vz, c[1], c[2], c[3], 200)
            end
        end

        -- Controls
        if not panelOpen then
            for _, ctl in ipairs(DISABLED) do DisableControlAction(0, ctl, true) end
            HideHudComponentThisFrame(19)
            HideHudComponentThisFrame(20)
            ShowHudComponentThisFrame(14)

            local shift = IsControlPressed(0, K.shift)
            if IsDisabledControlJustPressed(0, K.up) then
                if shift then heightOff = heightOff + 0.1 else range = math.min(300.0, range + (range < 10 and 0.5 or 1.0)) end
            elseif IsDisabledControlJustPressed(0, K.down) then
                if shift then heightOff = heightOff - 0.1 else range = math.max(1.0, range - (range <= 10 and 0.5 or 1.0)) end
            end
            local dt = GetFrameTime()
            if IsDisabledControlPressed(0, K.rotL) then heading = (heading + Config.RotateSpeed * dt) % 360.0 end
            if IsDisabledControlPressed(0, K.rotR) then heading = (heading - Config.RotateSpeed * dt) % 360.0 end

            if IsDisabledControlJustPressed(0, K.place) then
                placeOrConfirm()
            elseif IsDisabledControlJustPressed(0, K.grab) then
                local e = hoverId and Emitters[hoverId]
                if e and e.pack then notify('Pack element: read-only', 'error') elseif e then startMove(e) end
            elseif IsDisabledControlJustPressed(0, K.delete) then
                local e = hoverId and Emitters[hoverId]
                if e then
                    if e.pack then notify('Pack element: read-only', 'error')
                    elseif deleteArmed.id == e.id and now - deleteArmed.t < 2000 then
                        TriggerServerEvent('molo_se:delete', e.id)
                        deleteArmed.id = nil
                    else
                        deleteArmed = { id = e.id, t = now }
                        notify('Press X again to delete "' .. (e.label or e.id) .. '"', 'warn')
                    end
                end
            elseif IsDisabledControlJustPressed(0, K.edit) then
                if hoverId then openPanel('edit', hoverId) end
            elseif IsDisabledControlJustPressed(0, K.listen) then
                if preview then stopPreview() else startPreview(current, aim and aim.sound) end
            elseif IsDisabledControlJustPressed(0, K.menu) then
                openPanel(nil)
            elseif IsDisabledControlJustPressed(0, K.close) then
                if movingId then movingId = nil else closeEditor() end
            end
        end

        if now - lastInt > 400 then nui('interior', interiorSnapshot()) lastInt = now end
        if now - lastHud > 100 and not panelOpen then
            local hover = hoverId and Emitters[hoverId]
            nui('hud', {
                template = describe(template), type = template and template.type,
                range = range, height = heightOff, heading = heading, showHeading = hasProp(current),
                group = group,
                moving = movingId and Emitters[movingId] and (Emitters[movingId].label or movingId) or nil,
                hover = hover and { label = hover.label or hover.id, what = describe(hover), pack = hover.pack } or nil,
            })
            lastHud = now
        end
        Wait(0)
    end
end

local function toggleEditor()
    if open then return closeEditor() end
    open = true
    nui('open', { group = group, range = range })
    CreateThread(editorLoop)
    openPanel('interior')
end

RegisterCommand(Config.Command, function() toggleEditor() end, false)
RegisterKeyMapping(Config.Command, 'Molo Sound Emitters: menu', 'keyboard', Config.OpenKey)

-- ─── NUI callbacks ──────────────────────────────────────────────────
RegisterNUICallback('close', function(_, cb) closePanel() cb(1) end)
RegisterNUICallback('exitEditor', function(_, cb) closeEditor() cb(1) end)

RegisterNUICallback('setTemplate', function(d, cb)
    template = d
    if d.range then range = tonumber(d.range) or range end
    movingId = nil
    closePanel()
    notify((describe(template) or '?') .. ' — aim and press E', 'success')
    cb(1)
end)

RegisterNUICallback('preview', function(d, cb)
    local p = (not d.atPlayer and aim) and aim.sound or GetEntityCoords(PlayerPedId())
    startPreview(d, p)
    cb(1)
end)
RegisterNUICallback('stopPreview', function(_, cb) stopPreview() cb(1) end)

RegisterNUICallback('saveEmitter', function(d, cb) TriggerServerEvent('molo_se:save', d) cb(1) end)
RegisterNUICallback('deleteEmitter', function(d, cb) TriggerServerEvent('molo_se:delete', d.id) cb(1) end)
RegisterNUICallback('export', function(d, cb) TriggerServerEvent('molo_se:export', d.group, d.target) cb(1) end)
RegisterNUICallback('setGroup', function(d, cb) if d.group and d.group ~= '' then group = d.group end cb(1) end)
RegisterNUICallback('nameInterior', function(d, cb) TriggerServerEvent('molo_se:nameInterior', d.hash, d.name) cb(1) end)

RegisterNUICallback('moveEmitter', function(d, cb)
    local e = Emitters[d.id]
    if e and not e.pack then startMove(e) closePanel() end
    cb(1)
end)

RegisterNUICallback('teleport', function(d, cb)
    local e = Emitters[d.id]
    if e then SetEntityCoords(PlayerPedId(), e.x, e.y, e.z + 0.5, false, false, false, false) end
    cb(1)
end)

RegisterNetEvent('molo_se:exported', function(r) nui('exported', r) end)

-- ─── MLO audio (rooms + doors), logic adapted from Hedgehog-Technologies/ht_mlotool ──
local DOOR_RE = { 'door', 'gate', 'shutter', 'barrier', 'turnstile' }

local function isDoorName(name)
    name = (name or ''):lower()
    for _, w in ipairs(DOOR_RE) do if name:find(w, 1, true) then return true end end
    return false
end

local function mloInfo()
    local ped = PlayerPedId()
    local int = GetInteriorFromEntity(ped)
    if int == 0 then return { inside = false } end
    local loc, nameHash = GetInteriorLocationAndNamehash(int)
    local info = { inside = true, hash = u32(nameHash), rooms = {}, doors = {} }
    for i = 0, GetInteriorRoomCount(int) - 1 do info.rooms[#info.rooms + 1] = GetInteriorRoomName(int, i) end

    -- Audio occlusion data, computed exactly like ht_mlotool (proxy hash, room keys, portals)
    local function trunc(v) v = v * 100 return v > 0 and math.floor(v) or math.ceil(v) end
    local proxy = nameHash ~ trunc(loc.x) ~ trunc(loc.y) ~ trunc(loc.z)
    local occl = { proxy = u32(proxy), rooms = {}, portals = {} }
    for i, name in ipairs(info.rooms) do
        local nh = name == 'limbo' and GetHashKey('outside') or GetHashKey(name)
        occl.rooms[i] = { name = name, key = u32(name == 'limbo' and nh or (proxy ~ nh)) }
    end

    local seen = {}
    local function addDoor(hash, obj, source)
        hash = u32(hash)
        if hash == 0 or seen[hash] then return end
        local ok = obj and obj ~= 0 and DoesEntityExist(obj)
        local name = ok and GetEntityArchetypeName(obj) or nil
        local mn, mx = GetModelDimensions(hash)
        local d = { hash = hash, model = (name and name ~= '') and name or ('hash_%08X'):format(hash), source = source,
            size = { x = mx.x - mn.x, y = mx.y - mn.y, z = mx.z - mn.z } }
        if ok then
            local c = GetEntityCoords(obj)
            d.pos = { x = c.x, y = c.y, z = c.z }
            d.registered = DoorSystemFindExistingDoor(c.x, c.y, c.z, hash) and true or false
        end
        if source == 'shape' and not d.registered then return end -- door-shaped props only count when the game treats them as doors
        seen[hash] = true
        info.doors[#info.doors + 1] = d
    end
    -- Portals and the entities attached to them (doors, glass…)
    for p = 0, GetInteriorPortalCount(int) - 1 do
        local portal = {
            from = GetInteriorPortalRoomFrom(int, p), to = GetInteriorPortalRoomTo(int, p),
            mirror = (GetInteriorPortalFlag(int, p) & 4) == 4, entities = {},
        }
        for e = 0, GetInteriorPortalEntityCount(int, p) - 1 do
            local arch = GetInteriorPortalEntityArchetype(int, p, e)
            local rx, ry, rz = GetInteriorPortalEntityPosition(int, p, e)
            local pos = loc + vector3(rx, ry, rz)
            local obj = GetClosestObjectOfType(pos.x, pos.y, pos.z, 3.0, arch, false, false, false)
            addDoor(arch, obj, 'portal')
            local name = obj ~= 0 and DoesEntityExist(obj) and GetEntityArchetypeName(obj) or ''
            portal.entities[#portal.entities + 1] = {
                model = u32(arch), name = name ~= '' and name or ('hash_%08X'):format(u32(arch)),
                isDoor = isDoorName(name), isGlass = name:lower():find('glass', 1, true) ~= nil, maxOcclusion = 1.0,
            }
        end
        occl.portals[#occl.portals + 1] = portal
    end
    info.occl = occl
    -- Door props inside this interior: by name, or registered in the game's door system
    for _, obj in ipairs(GetGamePool('CObject')) do
        if GetInteriorFromEntity(obj) == int then
            local name = GetEntityArchetypeName(obj)
            if isDoorName(name) then addDoor(GetEntityModel(obj), obj, 'nearby') else addDoor(GetEntityModel(obj), obj, 'shape') end
        end
    end
    return info
end

RegisterNUICallback('getMlo', function(_, cb) cb(mloInfo()) end)

-- Door type probe: opens the door through the game's door system for a moment and measures how it moves.
-- swing = turns around its vertical axis, garage = tilts up, barrier = long arm that tilts,
-- sliding = moves sideways, vertical = moves up (roller / lift door)
local function angleDiff(a, b) local d = (a - b + 180.0) % 360.0 - 180.0 return math.abs(d) end

local function probeDoor(model, pos)
    local obj = GetClosestObjectOfType(pos.x, pos.y, pos.z, 2.0, model, false, false, false)
    if obj == 0 or not DoesEntityExist(obj) then return { error = 'not streamed in' } end
    local c0, r0 = GetEntityCoords(obj), GetEntityRotation(obj, 2)
    local right, fwd, up = GetEntityMatrix(obj)

    local found, hash = DoorSystemFindExistingDoor(c0.x, c0.y, c0.z, model)
    local temp = not found
    local prevState, prevRatio = 0, 0.0
    if temp then
        hash = GetHashKey(('molo_probe_%d_%d'):format(model, GetGameTimer()))
        AddDoorToSystem(hash, model, c0.x, c0.y, c0.z, false, false, true)
    else
        prevState, prevRatio = DoorSystemGetDoorState(hash), DoorSystemGetOpenRatio(hash)
    end
    DoorSystemSetDoorState(hash, 0, false, true)
    DoorSystemSetHoldOpen(hash, true)
    DoorSystemSetOpenRatio(hash, 1.0, false, true)

    local yaw, pitch, roll, side, vert = 0.0, 0.0, 0.0, 0.0, 0.0
    local deadline = GetGameTimer() + 1800
    while GetGameTimer() < deadline do
        Wait(50)
        if not DoesEntityExist(obj) then break end
        local c, r = GetEntityCoords(obj), GetEntityRotation(obj, 2)
        local dv = c - c0
        yaw = math.max(yaw, angleDiff(r.z, r0.z))
        pitch = math.max(pitch, angleDiff(r.x, r0.x))
        roll = math.max(roll, angleDiff(r.y, r0.y))
        side = math.max(side, math.abs(dv.x * right.x + dv.y * right.y + dv.z * right.z), math.abs(dv.x * fwd.x + dv.y * fwd.y + dv.z * fwd.z))
        vert = math.max(vert, math.abs(dv.x * up.x + dv.y * up.y + dv.z * up.z))
    end

    -- put everything back
    DoorSystemSetOpenRatio(hash, temp and 0.0 or prevRatio, false, true)
    DoorSystemSetHoldOpen(hash, false)
    if temp then
        Wait(800)
        RemoveDoorFromSystem(hash)
    else
        DoorSystemSetDoorState(hash, prevState, false, true)
    end

    local mn, mx = GetModelDimensions(model)
    local long = math.max(mx.x - mn.x, mx.y - mn.y)
    local kind
    if yaw > 20.0 then kind = 'swing'
    elseif pitch > 20.0 or roll > 20.0 then kind = (long > 3.0 and (mx.z - mn.z) < 1.2) and 'barrier' or 'garage'
    elseif vert > 0.4 then kind = 'vertical'
    elseif side > 0.3 then kind = 'sliding' end
    return { kind = kind, yaw = yaw, pitch = math.max(pitch, roll), side = side, vert = vert }
end

RegisterNUICallback('probeDoor', function(d, cb)
    if not d.pos then return cb({ error = 'no position' }) end
    local ok, res = pcall(probeDoor, d.hash, vector3(d.pos.x, d.pos.y, d.pos.z))
    cb(ok and res or { error = tostring(res) })
end)

RegisterNUICallback('aimedObject', function(_, cb)
    local ent = aim and aim.entity
    if not ent then return cb({}) end
    local name = GetEntityArchetypeName(ent)
    cb({ hash = u32(GetEntityModel(ent)), model = (name and name ~= '') and name or nil })
end)

RegisterNUICallback('getResources', function(_, cb) TriggerServerEvent('molo_se:getResources') cb(1) end)
RegisterNetEvent('molo_se:resources', function(list) nui('resources', list) end)
RegisterNUICallback('saveInteriorAudio', function(d, cb) TriggerServerEvent('molo_se:saveInteriorAudio', d) cb(1) end)
RegisterNUICallback('getAudioState', function(_, cb) TriggerServerEvent('molo_se:getAudioState') cb(1) end)
RegisterNetEvent('molo_se:audioState', function(st) AudioStateCache = st if open then nui('audioState', st) end end)

-- ─── Sound check: plays every catalog sound for a split second and keeps the ones that really play ──
SoundCheck = { bad = {}, hidden = {}, checked = 0 }
local scanning = false

RegisterNetEvent('molo_se:soundCheck', function(c)
    SoundCheck = c or SoundCheck
    if open then nui('soundCheck', SoundCheck) end
end)

RegisterNUICallback('scanSounds', function(d, cb)
    cb(1)
    if scanning or type(d.items) ~= 'table' then return end
    scanning = true
    stopPreview()
    CreateThread(function()
        local items, bad, good, batch = d.items, {}, {}, 12
        for i = 1, #items, batch do
            if not scanning then break end
            local p = GetEntityCoords(PlayerPedId())
            local ids = {}
            for j = i, math.min(i + batch - 1, #items) do
                local it = items[j]
                ids[#ids + 1] = { id = PlaySound3D(it.n, it.r, p.x, p.y, p.z + 0.5, 15.0), k = it.k }
            end
            -- Unplayable sounds (missing bank, bad ref) are already finished after a couple of frames
            Wait(0) Wait(0) Wait(0)
            for _, snd in ipairs(ids) do
                if HasSoundFinished(snd.id) then bad[#bad + 1] = snd.k else good[#good + 1] = snd.k end
                StopSound(snd.id)
                ReleaseSoundId(snd.id)
            end
            nui('scanProgress', { done = math.min(i + batch - 1, #items), total = #items, bad = #bad })
            Wait(60)
        end
        local completed = scanning
        scanning = false
        nui('scanProgress', { done = #items, total = #items, bad = #bad, finished = true, aborted = not completed })
        if completed then TriggerServerEvent('molo_se:scanResult', bad, good, #items, d.full == true) end
    end)
end)

RegisterNUICallback('stopScan', function(_, cb) scanning = false cb(1) end)
RegisterNUICallback('hideSound', function(d, cb) TriggerServerEvent('molo_se:hideSound', d.key, d.state) cb(1) end)
RegisterNUICallback('resetCheck', function(_, cb) TriggerServerEvent('molo_se:resetCheck') cb(1) end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and open then stopPreview() clearGhost() SetNuiFocus(false, false) end
end)
