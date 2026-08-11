--- Race (multiplayer): grid start -> lap/checkpoint race -> standings.
--- Ported from classic BeamJoy (RaceManager.lua) onto the V4 activity framework - this file is
--- the whole server side of the game mode and never touches the dispatcher.
---
--- Phases: "lobby" (join + ready up) -> "grid" (teleport to startPositions if the race authored
--- them, else keep each participant's current position; synchronized 3-2-1 countdown) ->
--- "running" (checkpoint/finish events from clients, DNF on leave) -> "ended" (standings).
---
--- Race data comes from dao_activity(map, "races") - deliberately NOT keyed by M.KEY like
--- derby's single arena: one map can host several races, picked by name/index (see
--- resolveRace/pickRace). Shape (array of records): { name, loopable, laps, startPositions[] =
--- { pos = {x,y,z}, rot? = {x,y,z,w} }, steps[][] = { pos, rot?, radius? } }. `steps` mirrors
--- classic's shape (array of "step" arrays, each holding parallel waypoints for branching
--- paths) for forward-compat with an eventual editor; v1 only reads steps[i][1] - see
--- docs/ACTIVITIES.md checklist item 4 for the "author per-map data" step, and the sample JSON
--- in this port's notes for a minimal hand-written race to test tonight.
---
--- v1 scope cuts (documented, not bugs - see TRACKING.md for the extension point):
--- - No branching paths (steps[i][1] only, no OBB gate geometry - client does a sphere check).
--- - No classic respawn strategies (ALL_RESPAWNS/LAST_CHECKPOINT/STAND): resets are simply
---   blocked while racing (client-side restriction), closest to classic's NO_RESPAWN.
--- - No forced vehicle model/config, no race records/PBs, no tournament hook.
--- - Standings order by SERVER-ARRIVAL order of "finish" events (a monotonic counter), not by
---   client-reported time, so a desynced client clock can't win/lose a race by cheating the
---   clock; the client-reported time is kept only as a cosmetic display value.
---
--- Freezing: unlike the other activities (which freeze only once results are final), this one
--- freezes the roster at the "lobby" -> "grid" transition already. Reason: grid slot assignment
--- is "my index in the (name-sorted) participants array" - if the roster weren't frozen, a
--- player leaving mid-grid would shift everyone after them down one slot on the very next
--- broadcast, colliding two participants onto the same startPosition. Freezing early trades
--- away the free `handle.countParticipants()` helper (it would count frozen DNF ghosts forever)
--- for index stability - so MIN_PLAYERS checks below count non-dnf participants by hand instead.

local M = {
    KEY = "race",
    TYPE = "exclusive",
    MIN_PLAYERS = 2,

    DATA_TYPE = "races", -- dao_activity(map, DATA_TYPE): array of race records for this map

    DEFAULTS = {
        lobbyTimeout = 60,      -- seconds before an unfilled lobby cancels
        gridCountdown = 5,      -- seconds of "grid" phase before the race actually starts
        endTimeout = 15,        -- seconds the standings stay up before auto-stop
        laps = 1,               -- default lap count when the race record doesn't force one
        maxLaps = 50,           -- sanity clamp against a bogus/abusive settings.laps value
        checkpointRadius = 6,   -- fallback radius (m) for waypoints missing one
        maxRaceDuration = 1800, -- safety net: force-DNF stragglers after this long (seconds)
    },
}

---@param races table? array of race records
---@param settings table?
---@return table? race
local function pickRace(races, settings)
    if type(races) ~= "table" then return nil end
    local sel = settings and settings.race
    if type(sel) == "string" then
        for _, r in ipairs(races) do
            if r.name == sel then return r end
        end
        return nil
    elseif type(sel) == "number" then
        return races[math.floor(sel)]
    end
    return races[1]
end

--- v1 keeps only the first waypoint of each classic "step" (no branching paths)
---@param rawSteps table?
---@return table[]
local function normalizeSteps(rawSteps)
    local steps = {}
    for _, step in ipairs(rawSteps or {}) do
        local wp = step and step[1]
        if type(wp) == "table" and type(wp.pos) == "table" then
            table.insert(steps, {
                pos = {
                    x = tonumber(wp.pos.x) or 0,
                    y = tonumber(wp.pos.y) or 0,
                    z = tonumber(wp.pos.z) or 0,
                },
                rot = wp.rot, -- optional quat {x,y,z,w}: passthrough for grid placement / future gates
                radius = tonumber(wp.radius) or M.DEFAULTS.checkpointRadius,
            })
        end
    end
    return steps
end

---@param settings table?
---@return table? race, table[]? steps
local function resolveRace(settings)
    local races = dao_activity.get(services_core.getCurrentMap(), M.DATA_TYPE)
    local race = pickRace(races, settings)
    if not race then return nil end
    local steps = normalizeSteps(race.steps)
    if #steps == 0 then return nil end
    return race, steps
end

---@param ctxt BJSContext
---@param settings table?
---@return boolean, string?
function M.canStart(ctxt, settings)
    if not resolveRace(settings) then
        return false, "beamjoy.activity.race.noData"
    end
    return true
end

--- ranks every participant: finished (by finish arrival order) > racing (by lap/step progress
--- desc) > dnf; assigns `position` 1..N, which the generic activity window already sorts by
---@param handle BJSActivityHandle
local function sortStandings(handle)
    local arr = {}
    handle.participants:forEach(function(p, name) table.insert(arr, { name = name, p = p }) end)

    local function sortKey(p)
        if p.finished then return 0, p.finishSeq or 0 end
        local progress = (p.lap or 0) * 100000 + (p.step or 0)
        return (p.dnf and 2 or 1), -progress
    end

    table.sort(arr, function(a, b)
        local at, asec = sortKey(a.p)
        local bt, bsec = sortKey(b.p)
        if at ~= bt then return at < bt end
        return asec < bsec
    end)
    for i, entry in ipairs(arr) do
        entry.p.position = i
    end
end

---@param p table participant record
local function markDnf(p)
    p.dnf = true
    p.eliminated = true -- reused by the generic activity window (strike-through row)
end

---@param handle BJSActivityHandle
local function checkRaceEnd(handle)
    if handle.phase ~= "running" then return end
    local total, done = 0, 0
    handle.participants:forEach(function(p)
        total = total + 1
        if p.finished or p.dnf then done = done + 1 end
    end)
    if total > 0 and done >= total then
        handle.state.endTime = GetCurrentTime() + M.DEFAULTS.endTimeout
        handle.setPhase("ended")
    end
end

---@param handle BJSActivityHandle
local function tryLaunchGrid(handle)
    if handle.phase ~= "lobby" then return end
    local total, ready = 0, 0
    handle.participants:forEach(function(p)
        total = total + 1
        if p.ready then ready = ready + 1 end
    end)
    if total >= M.MIN_PLAYERS and ready == total then
        -- see the module header: frozen from here on for grid-slot index stability
        handle.freezeParticipants()
        local now = GetCurrentTime()
        handle.state.gridStart = now
        handle.state.raceStartTime = now + M.DEFAULTS.gridCountdown
        handle.state.lobbyEnd = nil
        handle.setPhase("grid")
    end
end

---@param handle BJSActivityHandle
---@param settings table?
function M.onStart(handle, settings)
    settings = settings or {}
    local race, steps = resolveRace(settings)
    if not race then
        -- canStart already gates this; defensive fallback if data vanished between the calls
        handle.stop("cancelled")
        return
    end
    local loopable = race.loopable == true
    local laps = loopable and (tonumber(settings.laps) or tonumber(race.laps) or M.DEFAULTS.laps) or 1
    laps = math.clamp(math.floor(laps), 1, M.DEFAULTS.maxLaps)

    handle.settings = {
        race = race.name,
        laps = laps,
        loopable = loopable,
    }
    handle.state = {
        raceName = race.name,
        loopable = loopable,
        laps = laps,
        wpPerLap = #steps,
        steps = steps,
        startPositions = race.startPositions, -- nil/absent: clients fall back to current position
        lobbyEnd = GetCurrentTime() + M.DEFAULTS.lobbyTimeout,
    }
    handle.setPhase("lobby")
end

---@param handle BJSActivityHandle
---@param player BJSPlayer
---@return boolean?
function M.onPlayerJoin(handle, player)
    if handle.phase ~= "lobby" then return false end -- no late joins (grid slots are pre-frozen)
    handle.participants[player.playerName] = {
        ready = false, dnf = false, finished = false, lap = 0, step = 0,
    }
end

---@param handle BJSActivityHandle
function M.onPlayerReady(handle)
    tryLaunchGrid(handle)
end

---@param handle BJSActivityHandle
---@param player BJSPlayer
---@param eventName string
---@param arg number? stepIndex for "checkpoint" (cumulative across laps), timeMs for "finish"
function M.onClientEvent(handle, player, eventName, arg)
    if handle.phase ~= "running" then return end
    local p = handle.participants[player.playerName]
    if not p or p.dnf or p.finished then return end

    if eventName == "checkpoint" then
        local currentWp = math.floor(tonumber(arg) or -1)
        local wpPerLap = handle.state.wpPerLap
        if currentWp < 1 or currentWp > wpPerLap * handle.state.laps then return end
        local lap = math.ceil(currentWp / wpPerLap)
        local step = currentWp - (lap - 1) * wpPerLap
        -- ignore stale/duplicate/out-of-order reports (latency, resend)
        if lap < p.lap or (lap == p.lap and step <= p.step) then return end
        p.lap, p.step = lap, step
        sortStandings(handle)
        handle.sendState()
    elseif eventName == "finish" then
        -- only accept a finish once progress reached the last checkpoint of the last lap
        if p.lap ~= handle.state.laps or p.step ~= handle.state.wpPerLap then return end
        handle.finishSeq = (handle.finishSeq or 0) + 1
        p.finished = true
        p.finishSeq = handle.finishSeq
        local reportedMs = tonumber(arg)
        -- cosmetic only (see module header): ranking uses finishSeq, never this value
        p.finishTimeMs = (reportedMs and reportedMs >= 0) and math.round(reportedMs) or nil
        sortStandings(handle)
        handle.sendState()
        checkRaceEnd(handle)
    end
end

---@param handle BJSActivityHandle
---@param player BJSPlayer
---@param disconnected boolean
---@param entry table? the (still-linked, frozen) participant record
function M.onPlayerLeave(handle, player, disconnected, entry)
    if handle.phase == "lobby" then
        tryLaunchGrid(handle) -- remaining participants may now all be ready
    elseif handle.phase == "grid" then
        if entry then markDnf(entry) end
        local active = 0
        handle.participants:forEach(function(p) if not p.dnf then active = active + 1 end end)
        if active < M.MIN_PLAYERS then
            handle.stop("starved")
        end
    elseif handle.phase == "running" then
        if entry and not entry.finished and not entry.dnf then
            markDnf(entry)
            sortStandings(handle)
            handle.sendState()
            checkRaceEnd(handle)
        end
    end
end

---@param handle BJSActivityHandle
function M.onSlowTick(handle)
    local now = GetCurrentTime()
    if handle.phase == "lobby" then
        if handle.state.lobbyEnd and now >= handle.state.lobbyEnd then
            handle.stop("cancelled") -- lobby never filled
        end
    elseif handle.phase == "grid" then
        if now >= handle.state.raceStartTime then
            handle.state.runStartTime = now
            handle.state.maxEndTime = now + M.DEFAULTS.maxRaceDuration
            handle.participants:forEach(function(p)
                if not p.dnf then
                    p.lap, p.step, p.finished = 1, 0, false
                end
            end)
            handle.setPhase("running")
        end
    elseif handle.phase == "running" then
        -- safety net: force-DNF stragglers so a stuck/AFK racer can't hold the activity forever
        if handle.state.maxEndTime and now >= handle.state.maxEndTime then
            handle.participants:forEach(function(p)
                if not p.finished and not p.dnf then markDnf(p) end
            end)
            sortStandings(handle)
            checkRaceEnd(handle)
        end
    elseif handle.phase == "ended" then
        if now >= handle.state.endTime then
            handle.stop("ended")
        end
    end
end

return M
