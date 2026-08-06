--- Speed game (battle-royale): stay above an ever-increasing minimum speed or explode.
--- Ported from classic BeamJoy onto the V4 activity framework - this file is the whole
--- server side of the game mode and never touches the dispatcher.
---
--- Phases: "lobby" (join + ready up) -> "countdown" -> "running" -> "ended".
--- Gameplay outcomes are client-reported (each client detects its own elimination), matching
--- classic BeamJoy's trust model; the server owns the ramp, ordering and win condition.

local M = {
    KEY = "speed",
    TYPE = "exclusive",
    MIN_PLAYERS = 2,

    DEFAULTS = {
        minSpeed = 30,     -- km/h at start
        rampAdd = 5,       -- km/h added at every ramp step
        rampEvery = 10,    -- seconds between ramp steps
        lobbyTimeout = 60, -- seconds before an unfilled lobby cancels
        countdown = 5,     -- seconds between all-ready and start
        endTimeout = 10,   -- seconds before the results screen closes
    },
}

---@param handle BJSActivityHandle
---@return integer
local function countAlive(handle)
    local alive = 0
    handle.participants:forEach(function(p)
        if not p.eliminated then alive = alive + 1 end
    end)
    return alive
end

---@param handle BJSActivityHandle
local function checkWinCondition(handle)
    if handle.phase ~= "running" then return end
    if countAlive(handle) <= 1 then
        handle.participants:forEach(function(p, name)
            if not p.eliminated then
                p.position = 1
                handle.state.winner = name
            end
        end)
        handle.state.endTime = GetCurrentTime() + M.DEFAULTS.endTimeout
        -- results are final: keep the roster intact even if players leave/disconnect
        handle.freezeParticipants()
        handle.setPhase("ended")
    end
end

---@param handle BJSActivityHandle
---@param settings table?
function M.onStart(handle, settings)
    settings = settings or {}
    handle.settings = {
        minSpeed = tonumber(settings.minSpeed) or M.DEFAULTS.minSpeed,
        rampAdd = tonumber(settings.rampAdd) or M.DEFAULTS.rampAdd,
        rampEvery = tonumber(settings.rampEvery) or M.DEFAULTS.rampEvery,
    }
    handle.state = {
        minSpeed = handle.settings.minSpeed,
        lobbyEnd = GetCurrentTime() + M.DEFAULTS.lobbyTimeout,
    }
    handle.setPhase("lobby")
end

---@param handle BJSActivityHandle
---@param player BJSPlayer
---@return boolean?
function M.onPlayerJoin(handle, player)
    if handle.phase ~= "lobby" then return false end -- no late joins
    handle.participants[player.playerName] = { ready = false, eliminated = false }
end

---@param handle BJSActivityHandle
local function tryLaunch(handle)
    if handle.phase ~= "lobby" then return end
    local total, ready = 0, 0
    handle.participants:forEach(function(p)
        total = total + 1
        if p.ready then ready = ready + 1 end
    end)
    if total >= M.MIN_PLAYERS and ready == total then
        handle.state.startTime = GetCurrentTime() + M.DEFAULTS.countdown
        handle.state.lobbyEnd = nil
        handle.setPhase("countdown")
    end
end

---@param handle BJSActivityHandle
function M.onPlayerReady(handle)
    tryLaunch(handle)
end

---@param handle BJSActivityHandle
---@param player BJSPlayer
---@param eventName string
function M.onClientEvent(handle, player, eventName)
    if eventName == "eliminated" and handle.phase == "running" then
        local p = handle.participants[player.playerName]
        if p and not p.eliminated then
            p.eliminated = true
            -- BR scoring: first out gets the worst position
            p.position = countAlive(handle) + 1
            handle.sendState()
            checkWinCondition(handle)
        end
    end
end

---@param handle BJSActivityHandle
---@param player BJSPlayer
---@param disconnected boolean
function M.onPlayerLeave(handle, player, disconnected)
    if handle.phase == "running" then
        checkWinCondition(handle)
    elseif handle.phase == "lobby" then
        tryLaunch(handle) -- remaining players may now all be ready
    elseif handle.phase == "countdown" and handle.countParticipants() < M.MIN_PLAYERS then
        handle.stop("starved")
    end
end

---@param handle BJSActivityHandle
function M.onSlowTick(handle)
    local now = GetCurrentTime()
    if handle.phase == "lobby" then
        if handle.state.lobbyEnd and now >= handle.state.lobbyEnd then
            handle.stop("cancelled") -- lobby never filled
        end
    elseif handle.phase == "countdown" then
        if now >= handle.state.startTime then
            handle.state.nextRamp = now + handle.settings.rampEvery
            handle.setPhase("running")
        end
    elseif handle.phase == "running" then
        if now >= handle.state.nextRamp then
            handle.state.minSpeed = handle.state.minSpeed + handle.settings.rampAdd
            handle.state.nextRamp = now + handle.settings.rampEvery
            handle.sendState()
        end
    elseif handle.phase == "ended" then
        if now >= handle.state.endTime then
            handle.stop("ended")
        end
    end
end

return M
