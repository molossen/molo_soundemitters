-- molo_soundemitters — MLO audio occlusion (.ymt, PSO naOcclusionInteriorMetadata)
--
-- Path generation translated from Hedgehog-Technologies/ht_mlotool (client/classes/mlo.lua, node.lua, path.lua),
-- itself based on pedr0fontoura's gtav-audio-occlusion (MIT License, Copyright (c) 2021 snakewiz).
-- PSO layout reproduced from CodeWalker's XmlPso/PsoBuilder output (checked byte for byte).

Occlusion = {}

local U32 = 0xFFFFFFFF
local function u32(v) return math.floor(v) & U32 end
local function i32(v) v = u32(v) if v >= 0x80000000 then return v - 0x100000000 end return v end

-- ─── MLO model ──────────────────────────────────────────────────────
-- info = { proxy = u32, rooms = { {index, name, key = u32}... (index 0 = limbo) },
--          portals = { {from, to, mirror = bool, enabled = {true,true}, entities = {...}}... } }
local function buildMlo(info)
    local mlo = { proxy = u32(info.proxy), rooms = {}, portals = {} }
    for i, r in ipairs(info.rooms) do
        mlo.rooms[i] = { index = i - 1, name = r.name, key = u32(r.key), portalCount = 0 }
    end
    for i, p in ipairs(info.portals) do
        mlo.portals[i] = {
            index = i - 1, fromRoomIndex = p.from, toRoomIndex = p.to, isMirror = p.mirror == true,
            isEnabled = { p.enabled == nil or p.enabled[1] ~= false, p.enabled == nil or p.enabled[2] ~= false },
            globalPortalIndices = { -1, -1 }, entities = p.entities or {},
        }
    end
    -- Global portal indices (order = PortalInfoList order)
    local g = 0
    for _, room in ipairs(mlo.rooms) do
        for _, portal in ipairs(mlo.portals) do
            if not portal.isMirror then
                local dir = portal.fromRoomIndex == room.index and 1 or portal.toRoomIndex == room.index and 2 or nil
                if dir then portal.globalPortalIndices[dir] = g; g = g + 1 end
            end
        end
    end
    return mlo
end

local function activePortalsForRoom(mlo, roomIndex)
    local out = {}
    for _, portal in ipairs(mlo.portals) do
        if not portal.isMirror and (portal.fromRoomIndex == roomIndex and portal.isEnabled[2])
            or (portal.toRoomIndex == roomIndex and portal.isEnabled[1]) then
            out[#out + 1] = portal
        end
    end
    return out
end

local function generateNodes(mlo)
    local nodes = {}
    for i, room in ipairs(mlo.rooms) do
        local portals = activePortalsForRoom(mlo, i - 1)
        nodes[i] = { room = room, index = room.index, name = room.name, key = room.key, activePortals = portals, activePortalCount = #portals, edges = {} }
    end
    for _, node in ipairs(nodes) do
        local edges, added = {}, {}
        for _, portal in ipairs(node.activePortals) do
            local check
            if portal.fromRoomIndex == node.index then check = portal.toRoomIndex
            elseif portal.toRoomIndex == node.index then check = portal.fromRoomIndex end
            if check then
                for _, edgeNode in ipairs(nodes) do
                    if not added[edgeNode.index] and edgeNode.index == check then
                        added[edgeNode.index] = true
                        edges[#edges + 1] = edgeNode
                        break
                    end
                end
            end
        end
        node.edges = edges
    end
    return nodes
end

local function nonLimboEdges(node)
    local out = {}
    for _, e in ipairs(node.edges) do if e.index ~= 0 then out[#out + 1] = e end end
    return out
end

local function nodePairs(nodes)
    local out = {}
    for _, a in ipairs(nodes) do
        for _, b in ipairs(nodes) do
            if a.index ~= b.index then
                out[#out + 1] = { fromNode = a, toNode = b, isLimboPair = a.index == 0 or b.index == 0 }
            end
        end
    end
    return out
end

local function newPath(origin, dest, distance)
    local p = { distance = distance, origin = origin, destination = dest, childList = {} }
    if origin.index == dest.index then
        p.uintKey, p.key = 0, 0
    else
        p.uintKey = u32(origin.key - dest.key) + distance
        p.key = i32(p.uintKey)
    end
    return p
end

local function addChild(path, origin, dest, distance, gpi)
    path.childList[#path.childList + 1] = { pathNode = newPath(origin, dest, distance), globalPortalIndex = gpi }
end

local function isRelevant(path, a, b) return path.origin.index == a.index and path.destination.index == b.index end

local function alreadyFound(list, fromKey, toKey, distance)
    local k = u32(fromKey - toKey)
    for i = 1, distance do if list[k + i] then return true end end
    return false
end

local function findPath(list, fromKey, toKey, distance) return list[u32(fromKey - toKey) + distance] end

local function portalIndexTowards(portal, roomIndex)
    if portal.toRoomIndex == roomIndex then return portal.globalPortalIndices[1]
    elseif portal.fromRoomIndex == roomIndex then return portal.globalPortalIndices[2] end
end

local function generateRoutes(list, keys, pair, distance)
    local edges = pair.isLimboPair and pair.fromNode.edges or nonLimboEdges(pair.fromNode)
    local dmo = keys[distance - 1]
    for _, k in ipairs(dmo) do
        local path = list[k]
        if distance <= 3 then
            if isRelevant(path, pair.fromNode, pair.toNode) then
                local cur = findPath(list, pair.fromNode.key, pair.toNode.key, distance)
                local new = false
                if not cur then cur = newPath(pair.fromNode, pair.toNode, distance); new = true end
                for _, portal in ipairs(pair.fromNode.activePortals) do
                    if not portal.isMirror then
                        local gpi = portalIndexTowards(portal, pair.toNode.index)
                        if gpi ~= nil then addChild(cur, pair.fromNode, pair.fromNode, distance - 1, gpi) end
                    end
                end
                if new and #cur.childList > 0 then list[cur.uintKey] = cur; table.insert(keys[distance], cur.uintKey) end
            else
                for _, edge in ipairs(edges) do
                    if isRelevant(path, edge, pair.toNode) then
                        local cur = findPath(list, pair.fromNode.key, pair.toNode.key, distance)
                        local new = false
                        if not cur then cur = newPath(pair.fromNode, pair.toNode, distance); new = true end
                        for _, portal in ipairs(pair.fromNode.activePortals) do
                            if not portal.isMirror then
                                local gpi = portalIndexTowards(portal, edge.index)
                                if gpi ~= nil and (edge.index == portal.fromRoomIndex or (portal.fromRoomIndex ~= 0 and portal.toRoomIndex ~= 0)) then
                                    addChild(cur, edge, pair.toNode, distance - 1, gpi)
                                end
                            end
                        end
                        if new and #cur.childList > 0 then list[cur.uintKey] = cur; table.insert(keys[distance], cur.uintKey) end
                    end
                end
            end
        else
            for _, edge in ipairs(edges) do
                if isRelevant(path, edge, pair.toNode) and not alreadyFound(list, pair.fromNode.key, pair.toNode.key, distance) then
                    local cur = findPath(list, pair.fromNode.key, pair.toNode.key, distance)
                    local new = false
                    if not cur then cur = newPath(pair.fromNode, pair.toNode, distance); new = true end
                    for _, portal in ipairs(pair.fromNode.activePortals) do
                        if not portal.isMirror then
                            local gpi = portalIndexTowards(portal, edge.index)
                            if gpi ~= nil and (edge.index == pair.toNode.index or (portal.fromRoomIndex ~= 0 and portal.toRoomIndex ~= 0)) then
                                addChild(cur, edge, pair.toNode, distance - 1, gpi)
                            end
                        end
                    end
                    if new and #cur.childList > 0 then list[cur.uintKey] = cur; table.insert(keys[distance], cur.uintKey) end
                end
            end
        end
    end
end

local function generatePaths(mlo)
    local nodes = generateNodes(mlo)
    local pairs_ = nodePairs(nodes)
    local list, keys = {}, {}
    for distance = 1, 5 do
        keys[distance] = {}
        if distance == 1 then
            for _, node in ipairs(nodes) do
                for _, edge in ipairs(node.edges) do
                    local path = newPath(node, edge, 1)
                    for _, portal in ipairs(node.activePortals) do
                        if not portal.isMirror then
                            local gpi = portalIndexTowards(portal, edge.index)
                            if gpi ~= nil then addChild(path, node, node, 0, gpi) end
                        end
                    end
                    if #path.childList > 0 then list[path.uintKey] = path; table.insert(keys[1], path.uintKey) end
                end
            end
        else
            for _, pair in ipairs(pairs_) do generateRoutes(list, keys, pair, distance) end
        end
        table.sort(keys[distance])
    end
    return list, keys
end

-- ─── Data (what the PSO / XML contain) ──────────────────────────────
function Occlusion.generate(info)
    local mlo = buildMlo(info)
    local portalsOut = {}
    for _, room in ipairs(mlo.rooms) do
        local roomPortalIndex = 0
        for _, portal in ipairs(mlo.portals) do
            if portal.fromRoomIndex == room.index or portal.toRoomIndex == room.index then
                if not portal.isMirror then
                    local dest = portal.fromRoomIndex == room.index and portal.toRoomIndex or portal.fromRoomIndex
                    local ents = {}
                    for _, e in ipairs(portal.entities) do
                        ents[#ents + 1] = {
                            linkType = e.linkType or 1, maxOcclusion = e.maxOcclusion or 1.0,
                            model = u32(e.model or 0), isDoor = e.isDoor == true, isGlass = e.isGlass == true,
                        }
                    end
                    portalsOut[#portalsOut + 1] = { proxy = mlo.proxy, portalIdx = roomPortalIndex, roomIdx = room.index, destProxy = mlo.proxy, destRoomIdx = dest, entities = ents }
                end
                roomPortalIndex = roomPortalIndex + 1
            end
        end
    end

    local list, keys = generatePaths(mlo)
    local nodesOut = {}
    for d = 1, 5 do
        for _, k in ipairs(keys[d]) do
            local p = list[k]
            table.sort(p.childList, function(a, b) return a.globalPortalIndex < b.globalPortalIndex end)
            local children = {}
            for _, c in ipairs(p.childList) do children[#children + 1] = { key = c.pathNode.key, portalInfoIdx = c.globalPortalIndex } end
            if #children > 0 then nodesOut[#nodesOut + 1] = { key = p.key, children = children } end
        end
    end
    return { portals = portalsOut, nodes = nodesOut }
end

-- ─── PSO binary ─────────────────────────────────────────────────────
local H_ROOT, H_PORTAL, H_ENTITY, H_NODE, H_CHILD = 0xDE5DB4C2, 0x811C03CF, 0xF6624EF9, 0x771E3577, 0x892CF74F
local SCHEMA = {
    [H_ENTITY] = '0000000500000010000000006c0eb7bf0600000000000000b4e6530e0700000400000000e367400506000008000000001c4929eb0000000c000000003f33caad0000000d00000000',
    [H_PORTAL] = '000000070000002800000000df6b30ef06000000000000003f4807570500000400000000baf48c550500000800000000036d70200600000c000000003d535eda0500001000000000000001000c000000f6624ef9bef8bc2c0d00001800000005',
    [H_CHILD]  = '000000020000000800000000a23cde7b060000000000000040a50f770500000400000000',
    [H_NODE]   = '0000000300000018000000006098a50e0600000000000000000001000c000000892cf74fd27114dc0d00000800000001',
    [H_ROOT]   = '000000040000002000000000000001000c000000811c03cfb7e5d57c0d00000000000000000001000c000000771e3577441599890d00001000000002',
}
local function unhex(h) return (h:gsub('..', function(c) return string.char(tonumber(c, 16)) end)) end
for k, v in pairs(SCHEMA) do SCHEMA[k] = unhex(v) end

local pack = string.pack

function Occlusion.toPso(data)
    -- Blocks, in CodeWalker's creation order: entities, portals, children, nodes, root
    local order = { H_ENTITY, H_PORTAL, H_CHILD, H_NODE, H_ROOT }
    local blocks = {}
    for _, h in ipairs(order) do blocks[h] = { parts = {}, size = 0 } end
    local schemaOrder, seen = {}, {}
    local function touched(h) if not seen[h] then seen[h] = true; schemaOrder[#schemaOrder + 1] = h end end
    local function add(h, bytes)
        local b = blocks[h]
        local off = b.size
        b.parts[#b.parts + 1] = bytes
        b.size = b.size + #bytes
        return off
    end
    -- block ids are assigned once we know which blocks exist; keep pointer fix-ups symbolic
    local ptrs = {}
    local function arr(h, off, count) local t = { h = h, off = off, count = count }; ptrs[#ptrs + 1] = t; return t end

    local portalItems = {}
    for _, p in ipairs(data.portals) do
        local entArr
        if #p.entities > 0 then
            local chunk = {}
            for _, e in ipairs(p.entities) do
                chunk[#chunk + 1] = pack('>I4fI4BBI2', e.linkType, e.maxOcclusion, e.model, e.isDoor and 1 or 0, e.isGlass and 1 or 0, 0)
                touched(H_ENTITY)
            end
            entArr = arr(H_ENTITY, add(H_ENTITY, table.concat(chunk)), #p.entities)
        end
        portalItems[#portalItems + 1] = { head = pack('>I4i4i4I4i4I4', p.proxy, p.portalIdx, p.roomIdx, p.destProxy, p.destRoomIdx, 0), arr = entArr }
        touched(H_PORTAL)
    end
    local portalArr
    if #portalItems > 0 then portalArr = arr(H_PORTAL, blocks[H_PORTAL].size, #portalItems) end

    local nodeItems = {}
    for _, n in ipairs(data.nodes) do
        local chArr
        if #n.children > 0 then
            local chunk = {}
            for _, c in ipairs(n.children) do
                chunk[#chunk + 1] = pack('>I4i4', u32(c.key), c.portalInfoIdx)
                touched(H_CHILD)
            end
            chArr = arr(H_CHILD, add(H_CHILD, table.concat(chunk)), #n.children)
        end
        nodeItems[#nodeItems + 1] = { head = pack('>I4I4', u32(n.key), 0), arr = chArr }
        touched(H_NODE)
    end
    local nodeArr
    if #nodeItems > 0 then nodeArr = arr(H_NODE, blocks[H_NODE].size, #nodeItems) end
    touched(H_ROOT)

    -- Which blocks exist → 1-based ids
    local ids, present = {}, {}
    for _, h in ipairs(order) do
        local needed = (h == H_ROOT) or (h == H_PORTAL and portalArr) or (h == H_NODE and nodeArr) or blocks[h].size > 0
        if needed then present[#present + 1] = h; ids[h] = #present end
    end
    local function arrBytes(a)
        if not a then return string.rep('\0', 16) end
        return pack('>I4I4I2I2I4', (ids[a.h] & 0xFFF) + ((a.off & 0xFFFFF) << 12), 0, a.count, a.count, 0)
    end
    for _, it in ipairs(portalItems) do add(H_PORTAL, it.head .. arrBytes(it.arr)) end
    for _, it in ipairs(nodeItems) do add(H_NODE, it.head .. arrBytes(it.arr)) end
    add(H_ROOT, arrBytes(portalArr) .. arrBytes(nodeArr))

    -- PSIN
    local body, offsets, off = {}, {}, 16
    for _, h in ipairs(present) do
        offsets[h] = off
        body[#body + 1] = table.concat(blocks[h].parts)
        off = off + blocks[h].size
    end
    local psinData = table.concat(body)
    local psin = pack('>c4I4I4I4', 'PSIN', 16 + #psinData, 0, 0) .. psinData

    -- PMAP
    local pm = { pack('>c4I4I4I2I2', 'PMAP', 16 + 16 * #present, ids[H_ROOT], #present, 0x7070) }
    for _, h in ipairs(present) do pm[#pm + 1] = pack('>I4I4I4I4', h, offsets[h], 0, blocks[h].size) end
    local pmap = table.concat(pm)

    -- PSCH (struct infos in first-completed order)
    local idx, blobs, pos = {}, {}, 12 + 8 * #schemaOrder
    for _, h in ipairs(schemaOrder) do
        idx[#idx + 1] = pack('>I4I4', h, pos)
        blobs[#blobs + 1] = SCHEMA[h]
        pos = pos + #SCHEMA[h]
    end
    local psch = pack('>c4I4I4', 'PSCH', pos, #schemaOrder) .. table.concat(idx) .. table.concat(blobs)

    return psin .. pmap .. psch
end

-- CodeWalker-compatible XML (.ymt.pso.xml), same content as the binary
function Occlusion.toXml(data)
    local L = { '<?xml version="1.0" encoding="UTF-8"?>', '<naOcclusionInteriorMetadata>' }
    local function add(s) L[#L + 1] = s end
    if #data.portals > 0 then
        add('  <PortalInfoList itemType="naOcclusionPortalInfoMetadata">')
        for _, p in ipairs(data.portals) do
            add('    <Item>')
            add(('      <InteriorProxyHash value="%d" />'):format(i32(p.proxy)))
            add(('      <PortalIdx value="%d" />'):format(p.portalIdx))
            add(('      <RoomIdx value="%d" />'):format(p.roomIdx))
            add(('      <DestInteriorHash value="%d" />'):format(i32(p.destProxy)))
            add(('      <DestRoomIdx value="%d" />'):format(p.destRoomIdx))
            if #p.entities > 0 then
                add('      <PortalEntityList itemType="naOcclusionPortalEntityMetadata">')
                for _, e in ipairs(p.entities) do
                    add('        <Item>')
                    add(('          <LinkType value="%d" />'):format(e.linkType))
                    add(('          <MaxOcclusion value="%s" />'):format(('%.9g'):format(string.unpack('f', string.pack('f', e.maxOcclusion)))))
                    add(('          <EntityModelHashkey value="%d" />'):format(i32(e.model)))
                    add(('          <IsDoor value="%s" />'):format(tostring(e.isDoor)))
                    add(('          <IsGlass value="%s" />'):format(tostring(e.isGlass)))
                    add('        </Item>')
                end
                add('      </PortalEntityList>')
            else
                add('      <PortalEntityList itemType="naOcclusionPortalEntityMetadata" />')
            end
            add('    </Item>')
        end
        add('  </PortalInfoList>')
    else
        add('  <PortalInfoList itemType="naOcclusionPortalInfoMetadata" />')
    end
    if #data.nodes > 0 then
        add('  <PathNodeList itemType="naOcclusionPathNodeMetadata">')
        for _, n in ipairs(data.nodes) do
            add('    <Item>')
            add(('      <Key value="%d" />'):format(i32(n.key)))
            add('      <PathNodeChildList itemType="naOcclusionPathNodeChildMetadata">')
            for _, c in ipairs(n.children) do
                add('        <Item>')
                add(('          <PathNodeKey value="%d" />'):format(i32(c.key)))
                add(('          <PortalInfoIdx value="%d" />'):format(c.portalInfoIdx))
                add('        </Item>')
            end
            add('      </PathNodeChildList>')
            add('    </Item>')
        end
        add('  </PathNodeList>')
    else
        add('  <PathNodeList itemType="naOcclusionPathNodeMetadata" />')
    end
    add('</naOcclusionInteriorMetadata>')
    return table.concat(L, '\n')
end
