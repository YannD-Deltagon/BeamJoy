--- Votes - generic vote engine (server side).
---
--- One active vote at a time, server-wide. Two vote types ship with this module:
--- - KICK: payload = {targetName}. On success, kicks the target through the existing
---   services_players.kick() path (ctxt.origin = "vote" bypasses the normal group-hierarchy
---   permission gate, matching classic BeamJoy's vote-triggered kick).
--- - ACTIVITY_START: payload = {key, settings}. On success, starts the activity through
---   services_activities.requestStart() (the same function object the "activityStart" rx
---   handler uses), with the vote CREATOR as the permission subject - see the comment above
---   that export in services/activities.lua.
---
--- Threshold = majority (51%) of connected non-staff players (KICK excludes the target from
--- that pool, matching classic). Timeout is checked every slow tick (no utils_async task
--- needed, same pattern as services/activities.lua's own onSlowTick).
---
--- Ported from classic BeamJoy's VotesManager/VoteRx (Kick + Scenario), collapsed into one
--- generic engine since the V4 activity framework already owns per-mode rules.

local M = {
    dependencies = { "services_players", "services_permissions", "services_activities",
        "communications_rx", "communications_tx" },

    TYPES = {
        KICK = "kick",
        ACTIVITY_START = "activityStart",
    },

    DEFAULTS = {
        kickTimeout = 30,     -- seconds
        activityTimeout = 30, -- seconds
        thresholdRatio = .51,
    },

    ---@type BJSVote?
    active = nil,
}

---@class BJSVote
---@field type string M.TYPES value
---@field creatorName string
---@field creatorID integer
---@field payload table type-specific: KICK = {targetName}; ACTIVITY_START = {key, settings, label}
---@field voters tablelib<string, true> set of playerNames backing the vote (creator included)
---@field startedAt integer
---@field endsAt integer

--- guards against BJ_PERMISSIONS.VoteKick/VoteActivity not being merged into the permission
--- catalog yet: services_permissions.hasAllPermissions(id) with an empty/nil permission list
--- vacuously returns true (table.every on an empty table), which would otherwise grant vote
--- powers to everyone until the central integration lands
---@param senderID integer
---@param permKey string?
---@return boolean
local function hasPermission(senderID, permKey)
    return type(permKey) == "string" and #permKey > 0 and
        services_permissions.hasAllPermissions(senderID, permKey)
end

---@param ctxt BJSContext
---@return BJSPlayer?
local function getSender(ctxt)
    local playerName = MP.GetPlayerName(ctxt.senderID)
    return services_players.players[playerName]
end

--- connected, non-staff players eligible to vote (and be counted for the threshold)
---@param excludeName string? typically the KICK target
---@return integer
local function countEligible(excludeName)
    local n = 0
    services_players.players:forEach(function(_, playerName)
        if playerName ~= excludeName and not services_permissions.isStaff(playerName) then
            n = n + 1
        end
    end)
    return n
end

---@param vote BJSVote
---@return integer
local function getThreshold(vote)
    local exclude = vote.type == M.TYPES.KICK and vote.payload.targetName or nil
    return math.max(1, math.ceil(countEligible(exclude) * M.DEFAULTS.thresholdRatio))
end

--- always returns a wrapper table (never nil) so a cleared vote still overwrites stale
--- client-side state; only the "active" field is nil-able (mirrors services/activities.lua's
--- getPublicState pack() pattern)
---@return table
local function getPublicState()
    local vote = M.active
    return {
        active = vote and {
            type = vote.type,
            creatorName = vote.creatorName,
            payload = vote.payload,
            voters = vote.voters:keys(), -- array of playerNames (never a name-keyed map: see
            -- services/activities.lua's comment on numeric-name JSON key mangling)
            threshold = getThreshold(vote),
            startedAt = vote.startedAt,
            endsAt = vote.endsAt,
        } or nil,
    }
end

local function broadcastState()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache", {
        voteState = getPublicState(),
    })
end

---@param caches table
local function onBJRequestCache(caches)
    caches.voteState = getPublicState()
end

---@param vote BJSVote
local function finalize(vote)
    local threshold = getThreshold(vote)
    local success = vote.voters:length() >= threshold

    if success then
        if vote.type == M.TYPES.KICK then
            local ctxt = InitContext(nil)
            ctxt.origin = "vote" -- bypasses services_players.kick()'s group-hierarchy gate
            services_players.kick(ctxt, vote.payload.targetName, nil)
        elseif vote.type == M.TYPES.ACTIVITY_START then
            local ctxt = InitContext(vote.creatorID)
            ctxt.origin = "vote"
            services_activities.requestStart(ctxt, vote.payload.key, vote.payload.settings)
        end
    end

    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "voteResult", {
        type = vote.type,
        success = success,
        payload = vote.payload,
    })
    M.active = nil
    broadcastState()
end

---@param ctxt BJSContext
---@param voteType string
---@param payload table?
local function onVoteStart(ctxt, voteType, payload)
    local sender = getSender(ctxt)
    if not sender then return end
    if M.active then
        return communications_tx.sendToPlayer(ctxt.senderID, "voteDenied", "beamjoy.votes.denied.alreadyRunning")
    end
    payload = type(payload) == "table" and payload or {}

    local vote
    if voteType == M.TYPES.KICK then
        if not hasPermission(ctxt.senderID, BJ_PERMISSIONS.VoteKick) or
            services_permissions.isStaff(sender.playerName) then
            return communications_tx.sendToPlayer(ctxt.senderID, "voteDenied",
                "beamjoy.votes.denied.insufficientPermissions")
        end
        local targetName = payload.targetName
        local target = targetName and services_players.players[targetName]
        if not target or targetName == sender.playerName then
            return communications_tx.sendToPlayer(ctxt.senderID, "voteDenied", "beamjoy.votes.denied.invalidTarget")
        end
        if countEligible(targetName) < 2 then -- creator + at least one other eligible voter
            return communications_tx.sendToPlayer(ctxt.senderID, "voteDenied", "beamjoy.votes.denied.notEnoughPlayers")
        end
        vote = {
            type = voteType,
            payload = { targetName = targetName },
            endsAt = GetCurrentTime() + M.DEFAULTS.kickTimeout,
        }
    elseif voteType == M.TYPES.ACTIVITY_START then
        -- staff excluded like for KICK: staff are not in countEligible()'s pool, and they
        -- can start activities directly through their StartActivity permission anyway
        if not hasPermission(ctxt.senderID, BJ_PERMISSIONS.VoteActivity) or
            services_permissions.isStaff(sender.playerName) then
            return communications_tx.sendToPlayer(ctxt.senderID, "voteDenied",
                "beamjoy.votes.denied.insufficientPermissions")
        end
        local key = payload.key
        local module = key and services_activities.registry[key]
        if not module or module.TYPE ~= services_activities.TYPES.EXCLUSIVE then
            return communications_tx.sendToPlayer(ctxt.senderID, "voteDenied", "beamjoy.votes.denied.invalidActivity")
        end
        if services_activities.exclusive then
            return communications_tx.sendToPlayer(ctxt.senderID, "voteDenied", "beamjoy.votes.denied.activityBusy")
        end
        if countEligible(nil) < 2 then
            return communications_tx.sendToPlayer(ctxt.senderID, "voteDenied", "beamjoy.votes.denied.notEnoughPlayers")
        end
        vote = {
            type = voteType,
            payload = { key = key, settings = payload.settings, label = module.LABEL or key },
            endsAt = GetCurrentTime() + M.DEFAULTS.activityTimeout,
        }
    else
        return communications_tx.sendToPlayer(ctxt.senderID, "voteDenied", "beamjoy.votes.denied.invalidType")
    end

    vote.creatorName = sender.playerName
    vote.creatorID = ctxt.senderID
    vote.voters = Table({ [sender.playerName] = true })
    vote.startedAt = GetCurrentTime()
    M.active = vote
    broadcastState()
end

--- toggles the sender's vote on the active vote; dropping the last voter (usually the
--- creator withdrawing) cancels it outright, matching classic Kick/Map vote behavior
---@param ctxt BJSContext
local function onVoteCast(ctxt)
    local sender = getSender(ctxt)
    if not M.active or not sender then return end
    local permKey = M.active.type == M.TYPES.KICK and BJ_PERMISSIONS.VoteKick or BJ_PERMISSIONS.VoteActivity
    if not hasPermission(ctxt.senderID, permKey) or services_permissions.isStaff(sender.playerName) then return end
    if M.active.type == M.TYPES.KICK and sender.playerName == M.active.payload.targetName then return end

    if M.active.voters[sender.playerName] then
        M.active.voters[sender.playerName] = nil
    else
        M.active.voters[sender.playerName] = true
    end

    if M.active.voters:length() == 0 then
        M.active = nil
    end
    broadcastState()
end

---@param ctxt BJSContext
local function onVoteCancel(ctxt)
    local sender = getSender(ctxt)
    if not M.active or not sender then return end
    if sender.playerName ~= M.active.creatorName and not services_permissions.isStaff(sender.playerName) then
        return
    end
    M.active = nil
    broadcastState()
end

local function onSlowTick()
    if M.active and GetCurrentTime() >= M.active.endsAt then
        finalize(M.active)
    end
end

---@param playerID integer
local function onPlayerDisconnect(playerID)
    if not M.active then return end
    local playerName = MP.GetPlayerName(playerID)

    if playerName == M.active.creatorName then
        M.active = nil
        return broadcastState()
    end
    if M.active.type == M.TYPES.KICK and playerName == M.active.payload.targetName then
        M.active = nil -- target already gone, nothing left to vote on
        return broadcastState()
    end
    if M.active.voters[playerName] then
        M.active.voters[playerName] = nil
        if M.active.voters:length() == 0 then
            M.active = nil
        end
        broadcastState()
    end
end

local function onInit()
    communications_rx.addHandler("voteStart", onVoteStart)
    communications_rx.addHandler("voteCast", onVoteCast)
    communications_rx.addHandler("voteCancel", onVoteCancel)
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onSlowUpdate = onSlowTick
M.onPlayerDisconnect = onPlayerDisconnect

M.getPublicState = getPublicState

return M
