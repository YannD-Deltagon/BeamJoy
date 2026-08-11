--- Reputation/XP - client side.
--- Companion of BeamJoyServer/services/reputation.lua.
---
--- Consumes the "reputation" cache slice (array of {name, reputation} records - see
--- docs/ACTIVITIES.md's note on why participants/records never travel as name-keyed maps),
--- ports classic's level curve to derive a level from the raw reputation number, and exposes
--- M.getSelf() for future UI (player list reputation/level display, etc).
---
--- Also the reward-trigger side of two reward sources the server can't detect on its own:
--- - km driven: local distance tracking (~250ms, teleport/reset-guarded), one "kmDrive" ping
---   per 1000m actually driven.
--- - drift score: BeamNG's gameplay_drift onDriftCompletedScored hook (own vehicle only),
---   reported as "driftScore" - the server re-validates the threshold and rate-caps it.

local M = {
    dependencies = { "beamjoy_communications", "beamjoy_communications_ui",
        "beamjoy_players", "beamjoy_context" },

    ---@type table<string, {playerName: string, reputation: number, level: integer}> playerName -> entry
    players = {},

    kmDrive = {
        ---@type vec3?
        lastPos = nil,
        distance = 0,
    },
}

-- above this, a position delta in a single ~250ms tick is a teleport/reset/vehicle-switch,
-- not driving (100m/250ms ~= 1440km/h) - don't count it, just re-baseline
local MAX_TICK_DISTANCE = 100
local KM_DRIVE_METERS = 1000

-- ported verbatim from classic's BJI_Managers_Reputation level curve
---@param level integer
---@return number
local function getReputationLevelAmount(level)
    return (20 * (level ^ 2)) - (40 * level) + 20
end

---@param reputation number
---@return integer
local function getReputationLevel(reputation)
    local level = 1
    while getReputationLevelAmount(level + 1) < reputation do
        level = level + 1
    end
    return level
end

---@return {playerName: string, reputation: number, level: integer}?
local function getSelf()
    local self = beamjoy_players.getSelf()
    return self and M.players[self.playerName] or nil
end

---@param caches table
local function retrieveCache(caches)
    if not caches.reputation then return end

    local selfName = beamjoy_players.getSelf() and beamjoy_players.getSelf().playerName
    local previousSelfLevel = selfName and M.players[selfName] and M.players[selfName].level

    local updated = {}
    for _, entry in ipairs(caches.reputation) do
        updated[entry.name] = {
            playerName = entry.name,
            reputation = entry.reputation,
            level = getReputationLevel(entry.reputation),
        }
    end
    M.players = updated

    local selfEntry = selfName and updated[selfName]
    if selfEntry and previousSelfLevel and selfEntry.level > previousSelfLevel then
        beamjoy_communications_ui.uiBroadcast(
            "beamjoy.reputation.levelUp", { level = selfEntry.level }, "lime", 5)
    end
end

---@param ctxt TickContext
local function onSlowUpdate(ctxt)
    if not ctxt.mpVeh or not ctxt.mpVeh.isLocal or not ctxt.mpVeh.veh then
        M.kmDrive.lastPos = nil
        return
    end

    local pos = ctxt.mpVeh.veh:getPosition()
    if M.kmDrive.lastPos then
        local delta = math.horizontalDistance(M.kmDrive.lastPos, pos)
        if delta <= MAX_TICK_DISTANCE then
            M.kmDrive.distance = M.kmDrive.distance + delta
            if M.kmDrive.distance >= KM_DRIVE_METERS then
                M.kmDrive.distance = M.kmDrive.distance - KM_DRIVE_METERS
                beamjoy_communications.send("kmDrive")
            end
        end
        -- else: teleport/reset/vehicle-switch, don't count that jump
    end
    M.kmDrive.lastPos = pos
end

--- BeamNG game hook (gameplay_drift/scoring.lua), fired on this client's own drift chain only
---@param data { addedScore: number, combo: number, tier: table?, careerRewards: table? }
local function onDriftCompletedScored(data)
    local ctxt = beamjoy_context.get()
    if not ctxt.mpVeh or not ctxt.mpVeh.isLocal then return end
    local score = tonumber(data and data.addedScore)
    if not score or score <= 0 then return end
    beamjoy_communications.send("driftScore", score)
end

local function onInit()
    beamjoy_communications.addHandler("sendCache", retrieveCache)
end

M.onInit = onInit
M.onSlowUpdate = onSlowUpdate
M.onDriftCompletedScored = onDriftCompletedScored

M.getSelf = getSelf
M.getReputationLevel = getReputationLevel
M.getReputationLevelAmount = getReputationLevelAmount
M.retrieveCache = retrieveCache

return M
