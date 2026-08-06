--- Speed game - client side.
--- Companion of BeamJoyServer/services/activities/speed.lua; this file is the whole client
--- side of the game mode and never touches the framework.
---
--- While "running": watches the local vehicle's speed every slow update (~250ms); below the
--- server-driven minimum speed a 3s grace timer runs (HUD warning), then the client reports
--- its own elimination and blows the engine - matching classic BeamJoy's trust model.

local M = {
    KEY = "speed",
    LABEL = "beamjoy.activity.speed.title", -- translated by the activity window

    GRACE_MS = 3000,

    -- below minimum speed since (ms timestamp), nil when above
    failSince = nil,
    lastWarned = nil,
    eliminated = false,
}

--- recovery/reset inputs are blocked while playing (matching classic Speed rules)
local RESTRICTIONS = {
    "recover_vehicle", "recover_vehicle_alt", "reset_physics", "reset_all_physics",
    "loadHome", "saveHome", "dropPlayerAtCamera", "dropPlayerAtCameraNoReset",
    "reload_vehicle", "reload_all_vehicles", "vehicle_selector", "parts_selector",
}

---@param state table
---@return string[]
function M.getRestrictions(state)
    return RESTRICTIONS
end

function M.onJoin()
    M.failSince, M.lastWarned, M.eliminated = nil, nil, false
end

---@param reason string?
function M.onLeave(reason)
    M.failSince, M.lastWarned, M.eliminated = nil, nil, false
    beamjoy_communications_ui.send("BJHUDText", { message = "" })
end

---@param kmh number
---@return string
local function fmtSpeed(kmh)
    return string.format("%d km/h", math.round(kmh))
end

--- self-elimination: report + blow the engine locally
local function eliminate()
    M.eliminated = true
    M.failSince = nil
    beamjoy_activity_framework.sendEvent("eliminated")
    local ctxt = beamjoy_context.get()
    if ctxt.mpVeh and ctxt.mpVeh.isLocal and ctxt.mpVeh.veh then
        -- mirrors vehicles.lua explode(): impulse first, breakgroups after a short beat
        ctxt.mpVeh.veh:applyClusterVelocityScaleAdd(ctxt.mpVeh.veh:getRefNodeId(), 1, 0, 0, 3)
        local veh = ctxt.mpVeh.veh
        core_jobsystem.create(function(job)
            job.sleep(.2)
            veh:queueLuaCommand("beamstate.breakAllBreakgroups()")
        end)
        veh:queueLuaCommand("fire.explodeVehicle()")
    end
    beamjoy_communications_ui.send("BJHUDText", {
        message = beamjoy_lang.translate("beamjoy.activity.speed.eliminated", "ELIMINATED"),
        color = "red",
        duration = 5000,
    })
end

---@param ctxt TickContext
---@param entry table activity public entry (phase/state/participants)
function M.onSlowUpdate(ctxt, entry)
    if entry.phase ~= "running" or M.eliminated then return end
    local state = entry.state or {}
    local minSpeed = tonumber(state.minSpeed) or 0

    -- only the local player's own focused vehicle counts: while spectating someone else
    -- (mpVeh not local) or on foot, the participant is simply below minimum speed
    local speedKmh = 0
    if ctxt.mpVeh and ctxt.mpVeh.isLocal and ctxt.mpVeh.veh then
        local vel = ctxt.mpVeh.veh:getVelocity()
        speedKmh = math.sqrt(vel.x * vel.x + vel.y * vel.y + vel.z * vel.z) * 3.6
    end

    if speedKmh >= minSpeed then
        if M.failSince then
            M.failSince = nil
            beamjoy_communications_ui.send("BJHUDText", {
                message = string.var(
                    beamjoy_lang.translate("beamjoy.activity.speed.minSpeed", "Min: {speed}"),
                    { speed = fmtSpeed(minSpeed) }),
                color = "white",
                duration = 1500,
            })
        end
    else
        if not M.failSince then
            M.failSince = ctxt.now
        end
        local elapsed = ctxt.now - M.failSince
        if elapsed >= M.GRACE_MS then
            eliminate()
        else
            local remaining = math.ceil((M.GRACE_MS - elapsed) / 1000)
            if remaining ~= M.lastWarned then
                M.lastWarned = remaining
                beamjoy_communications_ui.send("BJHUDText", {
                    message = string.var(
                        beamjoy_lang.translate("beamjoy.activity.speed.speedUp",
                            "SPEED UP! {seconds}s (min {speed})"),
                        { seconds = remaining, speed = fmtSpeed(minSpeed) }),
                    color = "red",
                })
            end
        end
    end
end

---@param entry table
---@return {label: string, value: string}[]
function M.getUIDetails(entry)
    local state = entry.state or {}
    local details = {}
    if entry.phase == "running" or entry.phase == "ended" then
        table.insert(details, {
            label = beamjoy_lang.translate("beamjoy.activity.speed.minSpeedLabel", "Minimum speed"),
            value = fmtSpeed(state.minSpeed or 0),
        })
    end
    if entry.phase == "ended" and state.winner then
        table.insert(details, {
            label = beamjoy_lang.translate("beamjoy.activity.speed.winnerLabel", "Winner"),
            value = state.winner,
        })
    end
    return details
end

return M
