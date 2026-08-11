--- Votes - generic vote engine (client side).
---
--- Mirrors the server dispatcher (BeamJoyServer/services/votes.lua): receives the voteState
--- cache slice, composes the descriptor consumed by the Angular vote window (ui/modModules/
--- beamjoy/windows/vote), and bridges start/cast/cancel actions from that UI back to the
--- server. Also surfaces vote outcomes/denials as HUD toasts (same uiBroadcast pattern as
--- beamjoy/activity/framework.lua's "activityDenied" handler).

local M = {
    dependencies = { "beamjoy_communications", "beamjoy_communications_ui", "beamjoy_lang",
        "beamjoy_players", "beamjoy_permissions", "beamjoy_activity_framework" },

    ---@type table? last received public state ({active?})
    state = nil,
}

---@return string? playerName of the local player
local function getSelfName()
    local self = beamjoy_players.getSelf()
    return self and self.playerName or nil
end

--- same defensive guard as the server module: BJ_PERMISSIONS.VoteKick/VoteActivity being nil
--- (catalog not merged yet) would otherwise make hasAllPermissions() vacuously return true
--- for an empty permission list, showing the start-vote buttons to everyone
---@param permKey string?
---@return boolean
local function hasPermission(permKey)
    return type(permKey) == "string" and beamjoy_permissions.hasAllPermissions(nil, permKey)
end

--- exclusive activities the local player could start a vote for; the client activity
--- framework's registry is read-only here (never mutated) - see docs/ACTIVITIES.md
---@return {value: string, label: string}[]
local function getActivityOptions()
    local options = {}
    if beamjoy_activity_framework and beamjoy_activity_framework.registry then
        table.forEach(beamjoy_activity_framework.registry, function(mod, key)
            table.insert(options, { value = key, label = mod.LABEL or key })
        end)
    end
    table.sort(options, function(a, b) return a.label < b.label end)
    return options
end

--- compose and push the descriptor consumed by the Angular vote window
local function pushUIState()
    local selfName = getSelfName()
    local vote = M.state and M.state.active or nil

    local players = {}
    beamjoy_players.players:forEach(function(_, playerName)
        if playerName ~= selfName then
            table.insert(players, { value = playerName, label = playerName })
        end
    end)
    table.sort(players, function(a, b) return a.label < b.label end)

    local voteData = nil
    if vote then
        -- server activity modules carry no LABEL: resolve it from the client registry
        local payload = vote.payload
        if vote.type == "activityStart" and payload and payload.key then
            local clientMod = beamjoy_activity_framework.registry[payload.key]
            payload = table.assign(table.clone(payload), {
                label = clientMod and clientMod.LABEL or payload.key,
            })
        end
        voteData = {
            type = vote.type,
            creatorName = vote.creatorName,
            payload = payload,
            voters = vote.voters or {},
            votersCount = #(vote.voters or {}),
            threshold = vote.threshold,
            endsAt = vote.endsAt,
            self = {
                isCreator = vote.creatorName == selfName,
                hasVoted = table.includes(vote.voters or {}, selfName),
            },
        }
    end

    beamjoy_communications_ui.send("BJVoteState", {
        vote = voteData,
        players = players,
        activities = getActivityOptions(),
        canStartKick = hasPermission(BJ_PERMISSIONS.VoteKick) and not beamjoy_permissions.isStaff(),
        canStartActivity = hasPermission(BJ_PERMISSIONS.VoteActivity),
        canCancel = vote ~= nil and
            (vote.creatorName == selfName or beamjoy_permissions.isStaff()),
    })
end

---@param caches table
local function retrieveCache(caches)
    if caches.voteState then
        M.state = caches.voteState
    end
    -- also refresh on plain player join/leave/update pushes (caches.players, no voteState
    -- involved) so the kick-target picker doesn't go stale between vote-related broadcasts
    if caches.voteState or caches.players then
        pushUIState()
    end
end

---@param data {type: string, success: boolean, payload: table}
local function onVoteResult(data)
    local key = string.format("beamjoy.votes.result.%s.%s", tostring(data.type),
        data.success and "success" or "failure")
    local params = {}
    if data.type == "kick" then
        params.target = data.payload and data.payload.targetName or ""
    elseif data.type == "activityStart" then
        local label = data.payload and (data.payload.label or data.payload.key) or ""
        params.activity = beamjoy_lang.translate(label, label)
    end
    beamjoy_communications_ui.uiBroadcast(key, params, data.success and "lightgreen" or "orange", 5)
end

---@param reasonKey string
local function onVoteDenied(reasonKey)
    beamjoy_communications_ui.uiBroadcast(reasonKey, nil, "orange", 5)
end

--- UI actions bridge (start/cast/cancel from the Angular window)
---@param action string
---@param payload any
local function onUIAction(action, payload)
    if action == "startKick" then
        if type(payload) == "string" and #payload > 0 then
            beamjoy_communications.send("voteStart", "kick", { targetName = payload })
        end
    elseif action == "startActivity" then
        if type(payload) == "string" and #payload > 0 then
            beamjoy_communications.send("voteStart", "activityStart", { key = payload })
        end
    elseif action == "cast" then
        beamjoy_communications.send("voteCast")
    elseif action == "cancel" then
        beamjoy_communications.send("voteCancel")
    end
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", retrieveCache)
    beamjoy_communications.addHandler("voteResult", onVoteResult)
    beamjoy_communications.addHandler("voteDenied", onVoteDenied)
    beamjoy_communications_ui.addHandler("BJVoteAction", onUIAction)
end

M.onInit = onInit

M.retrieveCache = retrieveCache

return M
