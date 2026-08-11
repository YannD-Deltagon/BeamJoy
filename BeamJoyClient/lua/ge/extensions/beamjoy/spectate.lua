--- Spectator camera for exclusive activities.
---
--- When an exclusive activity (beamjoy_activity_framework.state.exclusive) is running and the
--- local player is NOT one of its participants, this module lets them park their camera on a
--- participant's vehicle instead of sitting in freeroam: cycle manually (next/prev) or let it
--- auto-follow the current leader (position 1). Spectating is camera-only - it never touches
--- inputs or ownership, it just calls the same "focus another player's vehicle" primitive the
--- friends-list UI already uses (beamjoy_players.lua onPlayerAction "focus"): resolve the
--- participant's current vehicle through the player cache, then
--- beamjoy_vehicles.focusVehicle(vid), which is be:enterVehicle(0, veh) + a freecam bailout.
--- Entering a REMOTE (not mpVeh.isLocal) vehicle this way never grants input control in BeamMP
--- (see BeamMP's MPVehicleGE.onVehicleSwitched: it only ever adjusts the camera for a
--- non-local vehicle, ownership/inputs stay networked to the actual driver) - confirmed against
--- the BeamMP 4.22.1 client source and already relied upon by the existing "focus" action.
---
--- No dedicated window: exposed as plain functions for the F4 menu (menu.lua, shared file, not
--- owned here - see docs/ACTIVITIES.md-style integration notes returned alongside this file).

local M = {
    dependencies = { "camera", "beamjoy_vehicles", "beamjoy_players", "beamjoy_activity_framework" },

    MIN_DWELL_MS = 5000, -- auto-follow won't re-target more often than this

    ---@type string? playerName of the participant currently focused, nil when not spectating
    target = nil,
    ---@type boolean
    autoFollow = false,
    ---@type integer milliseconds timestamp of the last programmatic focus switch
    lastSwitch = 0,
    ---@type integer|false|nil vid of the local player's own vehicle to restore on stop
    --- (false = "had no own vehicle to restore to", nil = "not currently spectating")
    ownVid = nil,
}

--- the running exclusive activity entry, or nil if there is none or the local player is
--- already one of its participants (nothing to spectate then - they have their own HUD)
---@return table?
local function getEntry()
    local fw = beamjoy_activity_framework
    local entry = fw.state and fw.state.exclusive or nil
    if not entry or fw.currentKey == entry.key then return nil end
    return entry
end

---@param entry table
---@return tablelib<integer, string> playerNames, in the server's broadcast order
local function participantNames(entry)
    return Table(entry.participants or {}):map(function(p) return p.name end)
end

--- resolve a participant's currently-driven vehicle through the player cache (mirrors
--- beamjoy_players.lua's onPlayerAction "focus" resolution for a target player)
---@param playerName string
---@return BJVehicle?
local function findParticipantVehicle(playerName)
    local player = beamjoy_players.players[playerName]
    if not player or not player.currentVehicle then return nil end
    return beamjoy_vehicles.vehicles:find(function(v)
        return v.remoteVID == player.currentVehicle
    end)
end

---@param playerName string
---@param silent boolean? skip the HUD toast (used by auto-follow to avoid spam)
---@return boolean success
local function focusParticipant(playerName, silent)
    local mpVeh = findParticipantVehicle(playerName)
    if not mpVeh or not mpVeh.veh or not mpVeh.veh.playerUsable then
        return false -- no drivable vehicle for them right now (on foot, not spawned...)
    end
    if M.ownVid == nil then
        -- remember our own vehicle once, the first time we look away from it, so "stop" can
        -- give it back; false means "we had none" (freeroam foot / no vehicle)
        local own = beamjoy_vehicles.getCurrentOwn()
        M.ownVid = own and own.vid or false
    end
    beamjoy_vehicles.focusVehicle(mpVeh.vid)
    M.target = playerName
    M.lastSwitch = GetCurrentTimeMillis()
    if not silent then
        beamjoy_communications_ui.uiBroadcast("beamjoy.spectate.now", { name = playerName }, "white", 2)
    end
    return true
end

---@param restoreOwn boolean? give the local player's own vehicle focus back
local function releaseSpectate(restoreOwn)
    -- M.target may already be nil when the spectated participant vanished (disconnect);
    -- the own-vehicle restore must not depend on it
    if restoreOwn and M.ownVid then
        beamjoy_vehicles.focusVehicle(M.ownVid)
    end
    M.target, M.autoFollow, M.ownVid = nil, false, nil
end

--- manual cycling; offset +1 = next, -1 = previous. Disables auto-follow (manual override).
--- Tries every participant once (wrapping) so one unspawned participant doesn't get stuck.
---@param offset integer
local function cycle(offset)
    local entry = getEntry()
    if not entry then
        beamjoy_communications_ui.uiBroadcast("beamjoy.spectate.unavailable", nil, "orange", 3)
        return
    end
    local names = participantNames(entry)
    local n = names:length()
    if n == 0 then
        beamjoy_communications_ui.uiBroadcast("beamjoy.spectate.noParticipants", nil, "orange", 3)
        return
    end
    M.autoFollow = false

    local startIdx = M.target and names:indexOf(M.target) or nil
    -- 0-based walk so wrap-around is a plain modulo; nil start = "just before first" (offset
    -- +1) or "just after last" (offset -1) so the first step lands on the natural end
    local base = startIdx and (startIdx - 1) or (offset > 0 and -1 or 0)
    for _ = 1, n do
        base = (base + offset) % n
        if focusParticipant(names[base + 1]) then return end
    end
    beamjoy_communications_ui.uiBroadcast("beamjoy.spectate.noneAvailable", nil, "orange", 3)
end

---@param state boolean? nil = toggle
local function setAutoFollow(state)
    local entry = getEntry()
    if not entry then
        M.autoFollow = false
        beamjoy_communications_ui.uiBroadcast("beamjoy.spectate.unavailable", nil, "orange", 3)
        return
    end
    if state == nil then state = not M.autoFollow end
    M.autoFollow = state == true
    if M.autoFollow then
        M.lastSwitch = 0 -- force an immediate (re)acquisition on the next slow tick
        beamjoy_communications_ui.uiBroadcast("beamjoy.spectate.autoFollowOn", nil, "white", 2)
    else
        beamjoy_communications_ui.uiBroadcast("beamjoy.spectate.autoFollowOff", nil, "white", 2)
    end
end

local function stop()
    if not M.target and not M.autoFollow and M.ownVid == nil then return end
    releaseSpectate(true)
    beamjoy_communications_ui.uiBroadcast("beamjoy.spectate.stopped", nil, "white", 2)
end

---@return boolean
local function isAvailable()
    return getEntry() ~= nil
end

---@param ctxt TickContext
local function onSlowUpdate(ctxt)
    local entry = getEntry()
    if not entry then
        if M.target or M.autoFollow or M.ownVid ~= nil then
            releaseSpectate(true)
        end
        return
    end

    local names = participantNames(entry)
    if M.target and not names:includes(M.target) then
        M.target = nil -- the participant we were watching left the activity
    end

    if not M.autoFollow then return end

    if not M.target then
        -- just lost our target (or never had one): (re)acquire immediately, ignore dwell
        local leader = Table(entry.participants or {}):find(function(p) return p.position == 1 end)
        focusParticipant((leader and leader.name) or names[1], true)
    elseif ctxt.now - M.lastSwitch >= M.MIN_DWELL_MS then
        local leader = Table(entry.participants or {}):find(function(p) return p.position == 1 end)
        if leader and leader.name ~= M.target then
            focusParticipant(leader.name, true)
        end
    end
end

M.next = function() cycle(1) end
M.prev = function() cycle(-1) end
M.setAutoFollow = setAutoFollow
M.toggleAutoFollow = function() setAutoFollow(nil) end
M.stop = stop
M.isAvailable = isAvailable

M.onSlowUpdate = onSlowUpdate

return M
