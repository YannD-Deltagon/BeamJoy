--- Destruction Derby: last vehicle still able to move wins.
--- Ported from classic BeamJoy (DerbyManager.lua) onto the V4 activity framework - this file
--- is the whole server side of the game mode and never touches the dispatcher.
---
--- Phases: "lobby" (join + ready up) -> "countdown" -> "running" -> "ended".
--- Gameplay outcomes are client-reported (each client detects its own vehicle being stuck or
--- wrecked), matching classic BeamJoy's trust model; the server owns lives, ordering and the
--- win condition.
---
--- Lives: classic's "extra lives" system. lives = 0 (default) means a single destruction event
--- eliminates the participant outright; lives > 0 lets them respawn (repaired, a life spent)
--- until they run out.
---
--- Arena: optional per-map data at dao_activity(<map>, "derby") shaped
--- `{ startPositions = { { pos = {x,y,z}, rot = {x,y,z} }, ... } }`. When present, participants
--- get a free slot assigned on join (classic's findFreeStartPosition, minus the shrinking safe
--- zone - not ported, see TRACKING). When absent (no per-map editor exists yet - see
--- docs/ACTIVITIES.md checklist item 4) participants simply fight from wherever their vehicle
--- already is: the mode still runs on any map.

local M = {
    KEY = "derby",
    TYPE = "exclusive",
    MIN_PLAYERS = 2, -- classic defaults to 3 (scaled down in its debug mode); lowered here so a
    -- small group can test the mode tonight - purely a module-owned constant, the dispatcher
    -- does not enforce it.

    DEFAULTS = {
        lives = 0,          -- 0 = no respawns (elimination on first stuck/wrecked report)
        maxLives = 20,       -- sanity clamp against a bogus/abusive settings.lives value
        gridTimeout = 60,   -- seconds for the lobby to fill + everyone ready up (classic default)
        startCountdown = 10, -- seconds between all-ready and start (classic default)
        endTimeout = 10,    -- seconds before the results screen closes (classic default)
    },
}

---@param handle BJSActivityHandle
---@return integer
local function countAlive(handle)
    local alive = 0
    handle.participants:forEach(function(p)
        if not p.eliminationTime then alive = alive + 1 end
    end)
    return alive
end

---@param handle BJSActivityHandle
local function checkWinCondition(handle)
    if handle.phase ~= "running" then return end
    if countAlive(handle) <= 1 then
        handle.participants:forEach(function(p, name)
            if not p.eliminationTime then
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

--- assign a free arena slot (classic's findFreeStartPosition); nil when the map has no arena
--- data or the arena is full - the participant then just fights from their current position
---@param handle BJSActivityHandle
---@return integer?
local function findFreeStartPosition(handle)
    local arena = handle.state.arena
    if type(arena) ~= "table" or type(arena.startPositions) ~= "table" or #arena.startPositions == 0 then
        return nil
    end
    local free = Range(1, #arena.startPositions):filter(function(i)
        return not handle.participants:any(function(p) return p.startPosition == i end)
    end)
    return #free > 0 and free:random() or nil
end

---@param handle BJSActivityHandle
---@param settings table?
function M.onStart(handle, settings)
    settings = settings or {}
    handle.settings = {
        lives = math.clamp(math.floor(tonumber(settings.lives) or M.DEFAULTS.lives),
            0, M.DEFAULTS.maxLives),
    }
    handle.state = {
        lobbyEnd = GetCurrentTime() + M.DEFAULTS.gridTimeout,
        -- optional per-map arena (nil = FALLBACK: no forced positions, no safe zone)
        arena = dao_activity.get(services_core.getCurrentMap(), M.KEY),
    }
    handle.setPhase("lobby")
end

---@param handle BJSActivityHandle
---@param player BJSPlayer
---@return boolean?
function M.onPlayerJoin(handle, player)
    if handle.phase ~= "lobby" then return false end -- no late joins
    handle.participants[player.playerName] = {
        ready = false,
        lives = handle.settings.lives,
        eliminationTime = nil,
        startPosition = findFreeStartPosition(handle),
    }
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
        handle.state.startTime = GetCurrentTime() + M.DEFAULTS.startCountdown
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
    if eventName == "destroyed" and handle.phase == "running" then
        local p = handle.participants[player.playerName]
        if p and not p.eliminationTime then
            if p.lives > 0 then
                p.lives = p.lives - 1 -- respawn: a life is spent, still in the fight
            else
                p.eliminationTime = GetCurrentTime()
                -- BR scoring: first out gets the worst position
                p.position = countAlive(handle) + 1
            end
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
        checkWinCondition(handle) -- the departed participant is already gone from the roster
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
            handle.state.startTime = nil
            handle.setPhase("running")
        end
    elseif handle.phase == "ended" then
        if now >= handle.state.endTime then
            handle.stop("ended")
        end
    end
end

return M
