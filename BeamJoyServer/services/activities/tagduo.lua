--- Tag Duo (hybrid): players pair up, one is "it" and must touch the other (proximity
--- checked client-side, ~3m between vehicles) to swap roles. Ported from classic BeamJoy's
--- TagDuoManager onto the V4 activity framework - this file is the whole server side of the
--- game mode and never touches the dispatcher.
---
--- TYPE = "hybrid": an always-on joinable lobby, coexisting with freeroam, created lazily on
--- first join. Any number of participants may be inside this ONE handle at once; pairing is a
--- pure per-participant state machine driven by join/leave, no lobby/countdown phases needed
--- ("first two unpaired participants become a pair"). A participant with no partner yet simply
--- has pairId == nil and waits in the pool until someone else joins or a pair breaks up.
---
--- Gameplay outcome (the tag itself) is client-reported, matching classic BeamJoy's and V4
--- Speed's trust model: the server owns pairing, role bookkeeping and the anti-instant-retag
--- cooldown ("immunity").

local M = {
    KEY = "tagduo",
    TYPE = "hybrid",
    MIN_PLAYERS = 2, -- informational only: hybrid pairs form/break as players trickle in/out

    DEFAULTS = {
        immunity = 5, -- seconds of grace after a pairing/tag before another tag can register
    },
}

--- names of participants without a pair yet, in join order (Table:forEach order matches
--- insertion for our purposes since names are only ever added/removed, never reordered)
---@param handle BJSActivityHandle
---@return string[]
local function getWaiting(handle)
    local waiting = {}
    handle.participants:forEach(function(p, name)
        if not p.pairId then table.insert(waiting, name) end
    end)
    return waiting
end

--- pairs up the first two waiting participants, if any; the starting tagger is picked at
--- random and both partners get a short immunity so a fresh pair spawning close together
--- can't be tagged before either player has had a chance to move
---@param handle BJSActivityHandle
local function tryPair(handle)
    local waiting = getWaiting(handle)
    if #waiting < 2 then return end
    local nameA, nameB = waiting[1], waiting[2]
    local pa, pb = handle.participants[nameA], handle.participants[nameB]

    handle.state.nextPairId = (handle.state.nextPairId or 0) + 1
    local now = GetCurrentTime()
    local immuneUntil = now + M.DEFAULTS.immunity
    local taggerIsA = math.random(2) == 1

    pa.pairId, pb.pairId = handle.state.nextPairId, handle.state.nextPairId
    pa.partner, pb.partner = nameB, nameA
    pa.tagger, pb.tagger = taggerIsA, not taggerIsA
    pa.immuneUntil, pb.immuneUntil = immuneUntil, immuneUntil
end

---@param handle BJSActivityHandle
---@param settings table?
function M.onStart(handle, settings)
    handle.state = { nextPairId = 0 }
    handle.setPhase("active")
end

--- always joinable: new participant enters the waiting pool and is immediately paired if
--- someone else is waiting too
---@param handle BJSActivityHandle
---@param player BJSPlayer
function M.onPlayerJoin(handle, player)
    handle.participants[player.playerName] = {
        pairId = nil,
        partner = nil,
        tagger = false,
        score = 0,
        immuneUntil = nil,
    }
    tryPair(handle)
end

--- client-reported tag: only the current tagger of a pair can trigger it, and only once the
--- pair's immunity has expired (also filters out duplicate reports for the same tag: once
--- processed, p.tagger flips to false so a resend fails the tagger check below)
---@param handle BJSActivityHandle
---@param player BJSPlayer
---@param eventName string
function M.onClientEvent(handle, player, eventName)
    if eventName ~= "tagged" then return end
    local p = handle.participants[player.playerName]
    if not p or not p.pairId or not p.tagger then return end
    local partner = handle.participants[p.partner]
    if not partner then return end

    local now = GetCurrentTime()
    if p.immuneUntil and now < p.immuneUntil then return end -- pair on cooldown

    -- swap roles: the toucher becomes the runner, the touched becomes the new tagger
    p.tagger = false
    partner.tagger = true
    p.score = (p.score or 0) + 1
    local immuneUntil = now + M.DEFAULTS.immunity
    p.immuneUntil, partner.immuneUntil = immuneUntil, immuneUntil
    handle.sendState()
end

--- a leaving/disconnecting participant frees their partner, who re-enters the waiting pool
--- and may immediately re-pair with someone else already waiting
---@param handle BJSActivityHandle
---@param player BJSPlayer
---@param disconnected boolean
---@param entry table? the (already removed) participant record
function M.onPlayerLeave(handle, player, disconnected, entry)
    if not entry or not entry.partner then return end
    local partner = handle.participants[entry.partner]
    if partner then
        partner.pairId, partner.partner, partner.tagger, partner.immuneUntil = nil, nil, false, nil
        tryPair(handle)
    end
end

return M
