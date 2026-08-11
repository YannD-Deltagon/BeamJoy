--- Race (multiplayer) - client side.
--- Companion of BeamJoyServer/services/activities/race.lua; this file is the whole client side
--- of the game mode and never touches the framework.
---
--- v1 simplifications (documented, not bugs - see the server module header for the full list):
--- - Checkpoint detection is a plain SPHERE-RADIUS check against the vehicle's own reference
---   position, not classic's OBB-corner / gate segment-crossing geometry (see
---   RaceWaypointManager.lua on the main branch for the full version). Good enough for a
---   circular gate feel; a fast car can in theory clip a very thin gate from the side without
---   triggering - acceptable for v1.
--- - No mid-race respawn strategies: recover/reset inputs are simply blocked while racing.
--- - "stepIndex" sent to the server is a CUMULATIVE absolute waypoint count across all laps
---   (1..wpPerLap*laps), matching the server's lap/step derivation.
---
--- While "grid": teleports to this player's slot in state.startPositions (index = this
--- player's position in the frozen, name-sorted participants array) when the race authored
--- them; otherwise the vehicle is left wherever it already is (tonight-testable fallback).
--- While "running": watches the local vehicle's position every slow update (~250ms) against the
--- next waypoint; reports progress via activity events and draws the current/next waypoint with
--- the game's race marker when available.

local M = {
    KEY = "race",
    LABEL = "beamjoy.activity.race.title",

    -- local progress mirror (server remains authoritative for standings/finish ordering)
    currentStep = 0, -- absolute waypoints crossed so far this race (0 = not started)
    finished = false,
    dnf = false,

    gridPlaced = false, -- grid teleport already attempted this "grid" phase
    raceInited = false, -- local race state already (re)initialized this "running" phase

    -- lazy scenario/race_marker probe: nil until first attempt, false after a failed
    -- require/init, the module table on success
    raceMarker = nil,
}

local RESTRICTIONS_GRID = {
    "recover_vehicle", "recover_vehicle_alt", "reset_physics", "reset_all_physics",
    "loadHome", "saveHome", "dropPlayerAtCamera", "dropPlayerAtCameraNoReset",
    "reload_vehicle", "reload_all_vehicles", "vehicle_selector", "parts_selector",
}
local RESTRICTIONS_RUNNING = RESTRICTIONS_GRID

---@param entry table?
---@return string[]
function M.getRestrictions(entry)
    if entry and entry.phase == "grid" then return RESTRICTIONS_GRID end
    if entry and entry.phase == "running" then return RESTRICTIONS_RUNNING end
    return {}
end

---@return string?
local function getSelfName()
    local self = beamjoy_players.getSelf()
    return self and self.playerName or nil
end

--- participants travel as an array of {name, ...} records (see the server dispatcher); this is
--- the RAW array (all custom fields included), not the trimmed one the Angular window gets
---@param entry table
---@return table? participant, integer? index
local function findSelf(entry)
    local name = getSelfName()
    if not name then return nil end
    for i, p in ipairs(entry.participants or {}) do
        if p.name == name then return p, i end
    end
end

--- lazily requires the game's race marker module; pcall-guarded since it's reused defensively
--- (not a documented public API, see docs/ACTIVITIES.md task notes)
---@return table?
local function getRaceMarker()
    if M.raceMarker == nil then
        local ok, mod = pcall(require, "scenario/race_marker")
        M.raceMarker = (ok and type(mod) == "table") and mod or false
        if M.raceMarker then pcall(M.raceMarker.init) end
    end
    return M.raceMarker or nil
end

local function clearMarkers()
    local rm = getRaceMarker()
    if rm then pcall(rm.setupMarkers, {}) end
end

---@param state table entry.state
---@param absolute integer 1-based cumulative waypoint index
---@return table? step, boolean isFinal
local function stepAt(state, absolute)
    local wpPerLap = state.wpPerLap or 0
    if wpPerLap == 0 then return nil, false end
    local totalWps = wpPerLap * (state.laps or 1)
    if absolute < 1 or absolute > totalWps then return nil, false end
    local physicalIdx = ((absolute - 1) % wpPerLap) + 1
    return (state.steps or {})[physicalIdx], absolute == totalWps
end

--- draws the current active waypoint + the next one (best-effort; on failure the race stays
--- fully playable - sphere detection above doesn't depend on the visuals)
---@param entry table
local function updateMarkers(entry)
    local rm = getRaceMarker()
    if not rm then return end
    local state = entry.state or {}

    local wps, modes = {}, {}
    local function push(absolute, name, fallbackMode)
        local wp, isFinal = stepAt(state, absolute)
        if not wp then return end
        local parsed = math.tryParsePosRot({ pos = wp.pos })
        table.insert(wps, {
            name = name,
            pos = parsed.pos,
            radius = tonumber(wp.radius) or 6,
            fadeNear = false,
            fadeFar = false,
        })
        modes[name] = isFinal and "final" or fallbackMode
    end
    push(M.currentStep + 1, "bjRaceCurrent", "default")
    push(M.currentStep + 2, "bjRaceNext", "next")

    local ok = pcall(rm.setupMarkers, wps, "sideColumnMarker")
    if ok then pcall(rm.setModes, modes) end
end

function M.onJoin()
    M.currentStep, M.finished, M.dnf = 0, false, false
    M.gridPlaced, M.raceInited = false, false
end

---@param reason string?
function M.onLeave(reason)
    M.currentStep, M.finished, M.dnf = 0, false, false
    M.gridPlaced, M.raceInited = false, false
    clearMarkers()
    beamjoy_communications_ui.send("BJHUDText", { message = "" })
end

--- teleports to the grid slot matching this player's index in the (frozen, name-sorted)
--- participants array when the race authored startPositions; otherwise keeps the player's
--- current position (tonight-testable fallback without per-map data)
---@param entry table
---@return boolean placed true when the teleport actually ran (or no grid slot applies)
local function placeAtGrid(entry)
    local _, idx = findSelf(entry)
    local startPositions = entry.state and entry.state.startPositions
    local ctxt = beamjoy_context.get()
    local placed = true
    if idx and type(startPositions) == "table" and startPositions[idx] then
        if ctxt.mpVeh and ctxt.mpVeh.isLocal and ctxt.mpVeh.veh then
            local parsed = math.tryParsePosRot(startPositions[idx])
            local dir, up
            if type(parsed.rot) == "userdata" or (type(parsed.rot) == "table" and parsed.rot.x) then
                local ok, d, u = pcall(math.rotationQuatToDirAndUp, parsed.rot)
                if ok then dir, up = d, u end
            end
            beamjoy_vehicles.setVehiclePositionRotation(ctxt.mpVeh.veh, parsed.pos, dir, up, { safe = false })
        else
            placed = false -- vehicle not available this instant, retry on slow update
        end
    end
    beamjoy_communications_ui.send("BJHUDText", {
        message = beamjoy_lang.translate("beamjoy.activity.race.getReady", "GET READY"),
        color = "white",
        duration = 2000,
    })
    return placed
end

---@param entry table
function M.onStateUpdate(entry)
    if entry.phase == "grid" then
        if not M.gridPlaced then
            M.gridPlaced = placeAtGrid(entry)
        end
    elseif entry.phase == "running" then
        if not M.raceInited then
            M.raceInited = true
            M.currentStep = 0
            updateMarkers(entry)
            beamjoy_communications_ui.send("BJHUDText", {
                message = beamjoy_lang.translate("beamjoy.activity.race.go", "GO!"),
                color = "green",
                duration = 1500,
            })
        end
    elseif entry.phase == "ended" then
        clearMarkers()
    end
end

---@param ctxt TickContext
---@param entry table
function M.onSlowUpdate(ctxt, entry)
    -- grid retry: the one-shot onStateUpdate attempt can miss when the local vehicle was
    -- not available at that exact instant (context is memoized on ~100ms buckets)
    if entry.phase == "grid" and not M.gridPlaced then
        M.gridPlaced = placeAtGrid(entry)
        return
    end
    if entry.phase ~= "running" or M.finished or M.dnf then return end

    local self = findSelf(entry)
    if self and self.dnf then
        M.dnf = true
        clearMarkers()
        return
    elseif self and self.finished then
        M.finished = true
        clearMarkers()
        return
    end

    if not ctxt.mpVeh or not ctxt.mpVeh.isLocal or not ctxt.mpVeh.veh then return end
    local state = entry.state or {}
    local nextAbsolute = M.currentStep + 1
    local wp, isFinal = stepAt(state, nextAbsolute)
    if not wp then return end

    local pos = beamjoy_vehicles.getVehiclePositionRotation(ctxt.mpVeh.veh)
    local wpPos = math.tryParsePosRot({ pos = wp.pos }).pos
    local radius = tonumber(wp.radius) or 6
    -- v1 simplification: sphere-radius check (see module header)
    if pos:distance(wpPos) > radius then return end

    M.currentStep = nextAbsolute
    if isFinal then
        local elapsedMs = math.round((GetCurrentTime() - (state.runStartTime or GetCurrentTime())) * 1000)
        beamjoy_activity_framework.sendEvent("finish", elapsedMs)
        beamjoy_communications_ui.send("BJHUDText", {
            message = beamjoy_lang.translate("beamjoy.activity.race.finished", "FINISHED"),
            color = "green",
            duration = 4000,
        })
        clearMarkers()
    else
        beamjoy_activity_framework.sendEvent("checkpoint", M.currentStep)
        local wpPerLap = state.wpPerLap or 1
        local lap = math.ceil(M.currentStep / wpPerLap)
        local step = M.currentStep - (lap - 1) * wpPerLap
        local laps = state.laps or 1
        beamjoy_communications_ui.send("BJHUDText", {
            message = laps > 1 and
                string.var(beamjoy_lang.translate("beamjoy.activity.race.checkpointLap",
                    "Checkpoint {step}/{total} - Lap {lap}/{laps}"),
                    { step = step, total = wpPerLap, lap = lap, laps = laps }) or
                string.var(beamjoy_lang.translate("beamjoy.activity.race.checkpoint",
                    "Checkpoint {step}/{total}"), { step = step, total = wpPerLap }),
            color = "white",
            duration = 1500,
        })
        updateMarkers(entry)
    end
end

---@param entry table
---@return {label: string, value: string}[]
function M.getUIDetails(entry)
    local details = {}
    local state = entry.state or {}

    if state.raceName then
        local value = state.raceName
        if (state.laps or 1) > 1 then
            value = string.var(beamjoy_lang.translate("beamjoy.activity.race.nameWithLaps",
                "{name} ({laps} laps)"), { name = state.raceName, laps = state.laps })
        end
        table.insert(details, {
            label = beamjoy_lang.translate("beamjoy.activity.race.nameLabel", "Race"),
            value = value,
        })
    end

    if entry.phase == "grid" then
        local remaining = math.max(0, (state.raceStartTime or 0) - GetCurrentTime())
        table.insert(details, {
            label = beamjoy_lang.translate("beamjoy.activity.race.startsInLabel", "Starts in"),
            value = string.format("%ds", remaining),
        })
    elseif entry.phase == "running" or entry.phase == "ended" then
        local self = findSelf(entry)
        if self then
            table.insert(details, {
                label = beamjoy_lang.translate("beamjoy.activity.race.positionLabel", "Position"),
                value = self.position and tostring(self.position) or "-",
            })
            if (state.laps or 1) > 1 then
                table.insert(details, {
                    label = beamjoy_lang.translate("beamjoy.activity.race.lapLabel", "Lap"),
                    value = string.format("%d/%d", math.max(self.lap or 0, 1), state.laps or 1),
                })
            end
            table.insert(details, {
                label = beamjoy_lang.translate("beamjoy.activity.race.checkpointLabel", "Checkpoint"),
                value = string.format("%d/%d", self.step or 0, state.wpPerLap or 0),
            })
            if self.finished then
                table.insert(details, {
                    label = beamjoy_lang.translate("beamjoy.activity.race.timeLabel", "Time"),
                    value = string.format("%.1fs", (self.finishTimeMs or 0) / 1000),
                })
            elseif self.dnf then
                table.insert(details, {
                    label = beamjoy_lang.translate("beamjoy.activity.race.statusLabel", "Status"),
                    value = beamjoy_lang.translate("beamjoy.activity.race.dnf", "DNF"),
                })
            end
        end
    end
    return details
end

return M
