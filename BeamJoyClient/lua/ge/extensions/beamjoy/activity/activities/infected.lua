--- Infected - client side.
--- Companion of BeamJoyServer/services/activities/infected.lua; this file is the whole client
--- side of the game mode and never touches the framework.
---
--- While "running" and locally infected: scans every other participant still marked as a
--- survivor for proximity every slow update (~250ms, own vehicle vs their vehicle, 3D
--- distance) and reports a touch via sendEvent("infect", targetName) - the server owns
--- validation and the win condition, matching classic BeamJoy's trust model.
---
--- v1 scope cuts (see the server module header for the full list): no survivor/infected
--- color forcing, no per-role start delay, no per-map arena - participants play from
--- wherever their vehicle already is.

local M = {
    KEY = "infected",
    LABEL = "beamjoy.activity.infected.title", -- translated by the activity window

    TOUCH_DISTANCE = 3, -- meters

    -- local-only UI bookkeeping, reset on join/leave
    announcedRole = false,
    wasInfected = false,
}

--- recovery/reset inputs are blocked while playing (matching classic Infected rules, same
--- list as the Speed game)
local RESTRICTIONS = {
    "recover_vehicle", "recover_vehicle_alt", "reset_physics", "reset_all_physics",
    "loadHome", "saveHome", "dropPlayerAtCamera", "dropPlayerAtCameraNoReset",
    "reload_vehicle", "reload_all_vehicles", "vehicle_selector", "parts_selector",
}

---@param entry table
---@return string[]
function M.getRestrictions(entry)
    return RESTRICTIONS
end

function M.onJoin()
    M.announcedRole, M.wasInfected = false, false
end

---@param reason string?
function M.onLeave(reason)
    M.announcedRole, M.wasInfected = false, false
    beamjoy_communications_ui.send("BJHUDText", { message = "" })
end

--- participants travel as an array of {name, infected, ...} records
---@param entry table
---@return table? own participant record
local function findSelf(entry)
    local selfName = MPConfig.getNickname()
    for _, p in ipairs(entry.participants or {}) do
        if p.name == selfName then return p end
    end
end

---@param entry table activity public entry (phase/state/participants)
function M.onStateUpdate(entry)
    local selfP = findSelf(entry)
    if not selfP or entry.phase ~= "running" then return end

    if not M.announcedRole then
        -- first tick of the round: color-coded role announcement
        M.announcedRole = true
        M.wasInfected = selfP.infected == true
        beamjoy_communications_ui.send("BJHUDText", {
            message = selfP.infected and
                beamjoy_lang.translate("beamjoy.activity.infected.roleInfected",
                    "YOU ARE INFECTED - HUNT THE SURVIVORS") or
                beamjoy_lang.translate("beamjoy.activity.infected.roleSurvivor",
                    "YOU ARE A SURVIVOR - AVOID THE INFECTED"),
            color = selfP.infected and "red" or "green",
            duration = 5000,
        })
    elseif selfP.infected and not M.wasInfected then
        -- got touched since the last update
        M.wasInfected = true
        beamjoy_communications_ui.send("BJHUDText", {
            message = beamjoy_lang.translate("beamjoy.activity.infected.justInfected",
                "YOU HAVE BEEN INFECTED!"),
            color = "red",
            duration = 5000,
        })
    end
end

---@param playerName string
---@return BJVehicle? the player's first non-AI drivable vehicle, if loaded locally
local function findPlayerVehicle(playerName)
    return beamjoy_vehicles.vehicles:find(function(v)
        return v.ownerName == playerName and v.isVehicle and not v.isAi
    end)
end

---@param ctxt TickContext
---@param entry table activity public entry (phase/state/participants)
function M.onSlowUpdate(ctxt, entry)
    if entry.phase ~= "running" then return end
    local selfP = findSelf(entry)
    -- only an infected participant, in their own local vehicle, can touch a survivor
    if not selfP or not selfP.infected then return end
    if not (ctxt.mpVeh and ctxt.mpVeh.isLocal and ctxt.mpVeh.veh) then return end

    local selfPos = beamjoy_vehicles.getVehiclePositionRotation(ctxt.mpVeh.veh)
    for _, p in ipairs(entry.participants) do
        if not p.infected and p.name ~= selfP.name then
            local targetVeh = findPlayerVehicle(p.name)
            if targetVeh and targetVeh.veh then
                local targetPos = beamjoy_vehicles.getVehiclePositionRotation(targetVeh.veh)
                if selfPos:distance(targetPos) <= M.TOUCH_DISTANCE then
                    beamjoy_activity_framework.sendEvent("infect", p.name)
                end
            end
        end
    end
end

---@param entry table
---@return {label: string, value: string}[]
function M.getUIDetails(entry)
    local details = {}
    if entry.phase ~= "countdown" and entry.phase ~= "running" and entry.phase ~= "ended" then
        return details
    end

    local infectedCount, survivorCount = 0, 0
    for _, p in ipairs(entry.participants or {}) do
        if p.infected then
            infectedCount = infectedCount + 1
        else
            survivorCount = survivorCount + 1
        end
    end
    table.insert(details, {
        label = beamjoy_lang.translate("beamjoy.activity.infected.infectedLabel", "Infected"),
        value = tostring(infectedCount),
    })
    table.insert(details, {
        label = beamjoy_lang.translate("beamjoy.activity.infected.survivorsLabel", "Survivors"),
        value = tostring(survivorCount),
    })

    local selfP = findSelf(entry)
    if selfP then
        table.insert(details, {
            label = beamjoy_lang.translate("beamjoy.activity.infected.statusLabel", "Your status"),
            value = selfP.infected and
                beamjoy_lang.translate("beamjoy.activity.infected.statusInfected", "Infected") or
                beamjoy_lang.translate("beamjoy.activity.infected.statusSurvivor", "Survivor"),
        })
    end

    local state = entry.state or {}
    if entry.phase == "ended" and state.winner then
        table.insert(details, {
            label = beamjoy_lang.translate("beamjoy.activity.infected.winnerLabel", "Winner"),
            value = state.winner,
        })
    end
    return details
end

return M
