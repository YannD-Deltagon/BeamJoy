--- Destruction Derby - client side.
--- Companion of BeamJoyServer/services/activities/derby.lua; this file is the whole client
--- side of the game mode and never touches the framework.
---
--- While "running": watches the local vehicle every slow update (~250ms) for a sustained stop
--- (mirrors classic BeamJoy's "stuck/wrecked" detection - a genuinely driveable vehicle doesn't
--- sit still in a derby). After GRACE_MS below STATIONARY_KMH the client reports its own
--- destruction: if lives remain the vehicle is repaired/repositioned in place (a life is spent),
--- otherwise it explodes for good - matching classic BeamJoy's trust model.

local M = {
    KEY = "derby",
    LABEL = "beamjoy.activity.derby.title", -- translated by the activity window

    STATIONARY_KMH = 3,      -- ~ the game's own "vehicle basically stopped" threshold
    GRACE_MS = 5000,         -- classic BeamJoy's DestroyedTimeout default
    RESPAWN_GRACE_MS = 3000, -- breathing room after a respawn before the stationary timer re-arms

    -- below STATIONARY_KMH since (ms timestamp), nil when moving
    stationarySince = nil,
    lastWarned = nil,
    -- ms timestamp until which the stationary check is suspended (right after a respawn)
    respawnUntil = nil,
    -- true once permanently out (no lives left) - stops all further ticking
    eliminated = false,
}

--- recovery/reset/vehicle-tools are only locked down once the fight is actually on; players
--- still need them in lobby/countdown to spawn, paint and ready up
local RESTRICTIONS = {
    "recover_vehicle", "recover_vehicle_alt", "reset_physics", "reset_all_physics",
    "loadHome", "saveHome", "dropPlayerAtCamera", "dropPlayerAtCameraNoReset",
    "reload_vehicle", "reload_all_vehicles", "vehicle_selector", "parts_selector",
}

---@param entry table
---@return string[]
function M.getRestrictions(entry)
    if entry and entry.phase == "running" then
        return RESTRICTIONS
    end
    return {}
end

function M.onJoin()
    M.stationarySince, M.lastWarned, M.respawnUntil, M.eliminated = nil, nil, nil, false
end

---@param reason string?
function M.onLeave(reason)
    M.stationarySince, M.lastWarned, M.respawnUntil, M.eliminated = nil, nil, nil, false
    beamjoy_communications_ui.send("BJHUDText", { message = "" })
end

--- participants travel as an array of {name, ...} records (see the server dispatcher)
---@param entry table
---@return table? own participant record
local function getSelfParticipant(entry)
    local self = beamjoy_players.getSelf()
    if not self or not entry then return nil end
    for _, p in ipairs(entry.participants or {}) do
        if p.name == self.playerName then return p end
    end
    return nil
end

---@param n number?
---@return string
local function fmtLives(n)
    return tostring(math.max(0, math.floor(n or 0)))
end

--- final elimination visual: mirrors speed.lua's explode()
local function blowUp()
    local ctxt = beamjoy_context.get()
    if ctxt.mpVeh and ctxt.mpVeh.isLocal and ctxt.mpVeh.veh then
        local veh = ctxt.mpVeh.veh
        veh:applyClusterVelocityScaleAdd(veh:getRefNodeId(), 1, 0, 0, 3)
        core_jobsystem.create(function(job)
            job.sleep(.2)
            veh:queueLuaCommand("beamstate.breakAllBreakgroups()")
        end)
        veh:queueLuaCommand("fire.explodeVehicle()")
    end
end

--- respawn: repair + reposition the vehicle where it stands. Uses the arena start slot the
--- server assigned (entry.state.arena, when the map has one) or just repairs in place (FALLBACK)
---@param entry table
---@param selfP table
local function respawn(entry, selfP)
    local ctxt = beamjoy_context.get()
    -- re-arm the grace window even when the vehicle is momentarily unavailable, so a
    -- missing-vehicle instant does not skip straight to another life-loss check
    M.respawnUntil = ctxt.now + M.RESPAWN_GRACE_MS
    if not (ctxt.mpVeh and ctxt.mpVeh.isLocal and ctxt.mpVeh.veh) then return end
    local veh = ctxt.mpVeh.veh
    local pos, dir, up = beamjoy_vehicles.getVehiclePositionRotation(veh)

    local arena = entry.state and entry.state.arena
    local slot = arena and type(arena.startPositions) == "table" and selfP.startPosition
        and arena.startPositions[selfP.startPosition] or nil
    if slot and slot.pos then
        pos = vec3(slot.pos.x, slot.pos.y, slot.pos.z)
        if slot.rot then
            dir = vec3(slot.rot.x, slot.rot.y, slot.rot.z)
        end
    end
    beamjoy_vehicles.setVehiclePositionRotation(veh, pos, dir, up)
    M.respawnUntil = ctxt.now + M.RESPAWN_GRACE_MS
end

--- self-elimination report: lives left -> respawn (repair, life spent), none left -> final
---@param entry table
---@param selfP table own participant record BEFORE the server applies this event
local function reportDestroyed(entry, selfP)
    M.stationarySince, M.lastWarned = nil, nil
    beamjoy_activity_framework.sendEvent("destroyed")
    if (selfP.lives or 0) > 0 then
        respawn(entry, selfP)
        beamjoy_communications_ui.send("BJHUDText", {
            message = string.var(
                beamjoy_lang.translate("beamjoy.activity.derby.lifeLost", "Life lost! {lives} left"),
                { lives = fmtLives((selfP.lives or 1) - 1) }),
            color = "orange",
            duration = 3000,
        })
    else
        M.eliminated = true
        blowUp()
        beamjoy_communications_ui.send("BJHUDText", {
            message = beamjoy_lang.translate("beamjoy.activity.derby.eliminated", "ELIMINATED"),
            color = "red",
            duration = 5000,
        })
    end
end

---@param ctxt TickContext
---@param entry table activity public entry (phase/state/participants)
function M.onSlowUpdate(ctxt, entry)
    if entry.phase ~= "running" or M.eliminated then return end
    local selfP = getSelfParticipant(entry)
    if not selfP or selfP.eliminationTime then return end

    if M.respawnUntil then
        if ctxt.now < M.respawnUntil then return end
        M.respawnUntil = nil
    end

    -- only the local player's own focused vehicle counts: while spectating someone else
    -- (mpVeh not local) or on foot, the participant is simply stationary
    local speedKmh = 0
    if ctxt.mpVeh and ctxt.mpVeh.isLocal and ctxt.mpVeh.veh then
        local vel = ctxt.mpVeh.veh:getVelocity()
        speedKmh = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z) * 3.6
    end

    if speedKmh >= M.STATIONARY_KMH then
        if M.stationarySince then
            M.stationarySince, M.lastWarned = nil, nil
            beamjoy_communications_ui.send("BJHUDText", { message = "" })
        end
        return
    end

    if not M.stationarySince then
        M.stationarySince = ctxt.now
    end
    local elapsed = ctxt.now - M.stationarySince
    if elapsed >= M.GRACE_MS then
        reportDestroyed(entry, selfP)
    else
        local remaining = math.ceil((M.GRACE_MS - elapsed) / 1000)
        if remaining ~= M.lastWarned then
            M.lastWarned = remaining
            beamjoy_communications_ui.send("BJHUDText", {
                message = string.var(
                    beamjoy_lang.translate("beamjoy.activity.derby.stuck",
                        "STUCK! Eliminated in {seconds}s"),
                    { seconds = remaining }),
                color = "red",
            })
        end
    end
end

---@param entry table
---@return {label: string, value: string}[]
function M.getUIDetails(entry)
    local details = {}
    if entry.phase == "running" or entry.phase == "ended" then
        local alive = 0
        for _, p in ipairs(entry.participants or {}) do
            if not p.eliminationTime then alive = alive + 1 end
        end
        table.insert(details, {
            label = beamjoy_lang.translate("beamjoy.activity.derby.aliveLabel", "Alive"),
            value = tostring(alive),
        })
        local selfP = getSelfParticipant(entry)
        if selfP then
            table.insert(details, {
                label = beamjoy_lang.translate("beamjoy.activity.derby.livesLabel", "Lives left"),
                value = fmtLives(selfP.lives),
            })
        end
    end
    if entry.phase == "ended" and entry.state and entry.state.winner then
        table.insert(details, {
            label = beamjoy_lang.translate("beamjoy.activity.derby.winnerLabel", "Winner"),
            value = entry.state.winner,
        })
    end
    return details
end

return M
