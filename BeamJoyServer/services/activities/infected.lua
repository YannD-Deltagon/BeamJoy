--- Infected: one random participant starts infected, touches survivors to convert them.
--- Ported from classic BeamJoy onto the V4 activity framework - this file is the whole
--- server side of the game mode and never touches the dispatcher.
---
--- Phases: "lobby" (join + ready up) -> "countdown" -> "running" -> "ended".
--- Touch detection is client-reported (each infected client detects proximity to survivors
--- and reports the "infect" event with the target's name), matching classic BeamJoy's trust
--- model; the server only validates the report (sender is infected, target is a non-infected
--- participant) and owns the win condition.
---
--- v1 scope cuts (see docs/ACTIVITIES.md + TRACKING.md for the extension point):
--- - No survivor/infected color forcing (classic's `enableColors` + forced vehicle config):
---   skipped, participants keep their own vehicle/paint. A later pass can add it as an
---   optional `settings.config`/color pair like classic, forwarded through `handle.settings`.
--- - No classic per-role start delay (survivors 5s / infected 10s head start via vehicle
---   freeze): replaced with a single uniform countdown (like Speed) for v1 simplicity.
--- - No per-map arena/start positions (classic's minor/major grid spots): participants start
---   wherever their vehicle already is when the round begins (current-position fallback),
---   so the mode is playable tonight on any map without per-map data.

local M = {
    KEY = "infected",
    TYPE = "exclusive",
    MIN_PLAYERS = 3, -- 1 infected + at least 2 survivors for a meaningful round

    DEFAULTS = {
        lobbyTimeout = 60, -- seconds before an unfilled lobby cancels
        countdown = 5,     -- seconds between all-ready and start
        endTimeout = 10,   -- seconds before the results screen closes
    },
}

---@param handle BJSActivityHandle
---@return integer
local function countSurvivors(handle)
    local survivors = 0
    handle.participants:forEach(function(p)
        if not p.infected then survivors = survivors + 1 end
    end)
    return survivors
end

---@param handle BJSActivityHandle
local function checkWinCondition(handle)
    if handle.phase ~= "running" then return end
    if countSurvivors(handle) <= 1 then
        handle.state.winner = nil
        handle.participants:forEach(function(p, name)
            if not p.infected then
                p.position = 1
                handle.state.winner = name -- nil if the last survivor also left/disconnected
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
    handle.settings = {} -- nothing configurable for v1 (see file header)
    handle.state = {
        lobbyEnd = GetCurrentTime() + M.DEFAULTS.lobbyTimeout,
    }
    handle.setPhase("lobby")
end

---@param handle BJSActivityHandle
---@param player BJSPlayer
---@return boolean?
function M.onPlayerJoin(handle, player)
    if handle.phase ~= "lobby" then return false end -- no late joins
    handle.participants[player.playerName] = { ready = false, infected = false }
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
        -- pick one random participant as the initial infected (current-position fallback:
        -- they start wherever their vehicle already is, see file header)
        local starter = handle.participants:keys():random()
        if starter then
            handle.participants[starter].infected = true
            handle.participants[starter].originalInfected = true
        end
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
---@param targetName string?
function M.onClientEvent(handle, player, eventName, targetName)
    if eventName ~= "infect" or handle.phase ~= "running" then return end
    local infector = handle.participants[player.playerName]
    local target = type(targetName) == "string" and handle.participants[targetName] or nil
    if not infector or not infector.infected then return end -- only infected participants can infect
    if not target or target.infected then return end         -- target must be a still-alive survivor

    target.infected = true
    handle.sendState()
    checkWinCondition(handle)
end

---@param handle BJSActivityHandle
---@param player BJSPlayer
---@param disconnected boolean
function M.onPlayerLeave(handle, player, disconnected)
    if handle.phase == "running" then
        checkWinCondition(handle)
        if handle.phase == "running" then -- still running: can it still progress?
            if handle.countParticipants() < M.MIN_PLAYERS then
                handle.stop("starved")
            elseif not handle.participants:any(function(p) return p.infected end) then
                -- the only infected participant(s) left: nobody can convert survivors anymore
                handle.stop("cancelled")
            end
        end
    elseif handle.phase == "lobby" then
        tryLaunch(handle) -- remaining players may now all be ready
    elseif handle.phase == "countdown" then
        if handle.countParticipants() < M.MIN_PLAYERS then
            handle.stop("starved")
        elseif not handle.participants:any(function(p) return p.infected end) then
            -- the randomly-chosen starter left during the countdown: no infected remains
            handle.stop("cancelled")
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
    elseif handle.phase == "countdown" then
        if now >= handle.state.startTime then
            handle.setPhase("running")
        end
    elseif handle.phase == "ended" then
        if now >= handle.state.endTime then
            handle.stop("ended")
        end
    end
end

return M
