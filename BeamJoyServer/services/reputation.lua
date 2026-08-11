--- Reputation/XP service - cross-cutting (NOT an activity, always loaded).
---
--- Owns per-player reputation: persisted at player.data.reputation. Migrated players carry
--- their classic value at player.data.classic.reputation (written by
--- tools/migrate_classic_data.py) - read once, lazily, as the starting point the first time
--- a player's reputation is touched; every reward after that maintains player.data.reputation
--- going forward, classic's field is never written back to.
---
--- Reward sources wired here:
--- - "kmDrive" client event (1 fired per ~1000m actually driven, client-side distance
---   tracking with a teleport/reset guard) -> KmDrive reward.
--- - "driftScore" client event (gameplay_drift's onDriftCompletedScored hook, client-side) ->
---   DriftGood/DriftBig reward, thresholded and rate-capped here (the client report is
---   trusted for the score value like classic was, but capped per-minute against spam/replay).
--- - Activity participation/wins: services/activities.lua (owned by another module, cannot be
---   edited here) has no "activity ended" hook yet, so this module polls
---   services_activities.getPublicState() every onSlowUpdate (~1s) and edge-detects phase
---   transitions into "ended" per activity key. See docs note in the integration report: a
---   dedicated M.onActivityEnded(handle) dispatcher hook would remove the need for this poll.
---
--- Broadcast: reputation changes piggyback services_players.savePlayer() (already broadcasts
--- a full "updatePlayer" event to everyone, players.lua is NOT edited here) for live deltas,
--- plus this module's own "reputation" cache slice (via the onBJRequestCache hook every
--- server module can implement, see services/cache.lua) so newly (re)connecting clients get
--- every currently-connected player's reputation regardless of players.lua's staff-gated
--- per-player cache fields.

local M = {
    dependencies = { "services_players", "services_activities",
        "communications_rx", "communications_tx" },

    -- own defaults: services_config has no Reputation/Freeroam.Drift* block on V4 yet (the
    -- classic config port is a separate backlog item) - configurable in-code for now.
    REWARDS = {
        KmDrive = 3,
        DriftGood = 30,
        DriftBig = 100,
        ActivityParticipation = 20,
        ActivityWin = 100,
    },

    -- classic Freeroam.DriftGood/DriftBig thresholds (score, not reward amount)
    DRIFT_GOOD_THRESHOLD = 2000,
    DRIFT_BIG_THRESHOLD = 10000,

    -- anti-spam cap on the client-trusted drift score report
    DRIFT_RATE_WINDOW = 60, -- seconds
    DRIFT_RATE_MAX = 10,    -- max rewarded drift reports per player per window

    ---@type table<string, tablelib<integer, number>> playerName -> reward timestamps (drift only)
    driftRateLog = {},

    ---@type table<string, string> activity key -> last observed phase (edge-detects "ended")
    lastActivityPhase = {},
}

---@param player BJSPlayer
---@return number
local function getOrInitReputation(player)
    player.data = player.data or {}
    if type(player.data.reputation) ~= "number" then
        player.data.reputation = (player.data.classic and tonumber(player.data.classic.reputation)) or 0
    end
    return player.data.reputation
end

--- builds the public reputation slice: an ARRAY of records (never a name-keyed map - see
--- docs/ACTIVITIES.md's participants note on numeric-looking display names)
---@return {name: string, reputation: number}[]
local function buildCachePayload()
    local list = {}
    services_players.players:forEach(function(player, playerName)
        table.insert(list, { name = playerName, reputation = getOrInitReputation(player) })
    end)
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function broadcastCache()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache", {
        reputation = buildCachePayload(),
    })
end

--- reward API for other server modules (and this module's own event handlers)
---@param playerName string
---@param key string M.REWARDS key ("KmDrive", "DriftGood", "DriftBig", "ActivityParticipation", "ActivityWin"...)
---@param amount number? overrides the configured amount for `key` when given
---@return number? newReputation nil if the player isn't currently connected
local function reward(playerName, key, amount)
    local player = services_players.players[playerName]
    if not player then return end

    local delta = tonumber(amount) or M.REWARDS[key]
    if type(delta) ~= "number" or delta == 0 then
        return getOrInitReputation(player)
    end

    getOrInitReputation(player)
    player.data.reputation = player.data.reputation + delta
    -- piggyback the existing save/broadcast flow (players.lua is not edited here)
    services_players.savePlayer(player)
    broadcastCache()
    return player.data.reputation
end

---@param caches table
---@param targetID integer
local function onBJRequestCache(caches, targetID)
    caches.reputation = buildCachePayload()
end

---@param ctxt BJSContext
local function onKmDrive(ctxt)
    if not ctxt.sender then return end
    reward(ctxt.sender.playerName, "KmDrive")
end

---@param ctxt BJSContext
---@param score number
local function onDriftScore(ctxt, score)
    if not ctxt.sender then return end
    score = tonumber(score)
    if not score or score < M.DRIFT_GOOD_THRESHOLD then return end

    local playerName = ctxt.sender.playerName
    local now = GetCurrentTime()
    local log = table.filter(M.driftRateLog[playerName] or {},
        function(t) return now - t < M.DRIFT_RATE_WINDOW end)
    if log:length() >= M.DRIFT_RATE_MAX then
        M.driftRateLog[playerName] = log
        return -- rate-capped this window, drop silently
    end
    log:insert(now)
    M.driftRateLog[playerName] = log

    reward(playerName, score >= M.DRIFT_BIG_THRESHOLD and "DriftBig" or "DriftGood")
end

--- edge-detects a single activity entry's transition into "ended" and rewards once
---@param entry table? {key, phase, participants, state} (see services/activities.lua getPublicState)
--- the edge-detector state must be cleared once a handle disappears, otherwise the stale
--- "ended" value suppresses reward detection for every later run of the same activity key
local function clearGoneActivities(state)
    for key in pairs(M.lastActivityPhase) do
        local stillThere = (state.exclusive and state.exclusive.key == key)
            or (state.hybrids and state.hybrids[key] ~= nil)
        if not stillThere then
            M.lastActivityPhase[key] = nil
        end
    end
end

local function checkActivityEnded(entry)
    if not entry or not entry.key then return end
    local previousPhase = M.lastActivityPhase[entry.key]
    M.lastActivityPhase[entry.key] = entry.phase
    if entry.phase ~= "ended" or previousPhase == "ended" then return end

    for _, p in ipairs(entry.participants or {}) do
        reward(p.name, "ActivityParticipation")
    end
    local winnerName = entry.state and entry.state.winner
    if winnerName then
        reward(winnerName, "ActivityWin")
    end
end

local function onSlowUpdate()
    local ok, state = pcall(services_activities.getPublicState)
    if ok and state then clearGoneActivities(state) end
    if not ok or not state then return end
    checkActivityEnded(state.exclusive)
    table.forEach(state.hybrids or {}, checkActivityEnded)
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    M.driftRateLog[MP.GetPlayerName(playerID)] = nil
end

local function onInit()
    communications_rx.addHandler("kmDrive", onKmDrive)
    communications_rx.addHandler("driftScore", onDriftScore)
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onSlowUpdate = onSlowUpdate
M.onPlayerDisconnect = onPlayerDisconnect

M.reward = reward
M.getReputation = function(playerName)
    local player = services_players.players[playerName]
    return player and getOrInitReputation(player) or nil
end

return M
