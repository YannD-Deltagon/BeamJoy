--- Activity framework - server dispatcher.
---
--- An "activity" is any joinable game mode (race, speed game, hunter...). Adding one requires
--- NO change to this file: drop a module into services/activities/<key>.lua and it is
--- auto-discovered at boot (see docs/ACTIVITIES.md for the module contract).
---
--- Activity types:
--- - "exclusive": one at a time server-wide (races, speed, derby...). Starting one requires
---   the StartActivity permission and no other exclusive activity running.
--- - "hybrid": always-on joinable lobbies coexisting with freeroam (tag duo, delivery
---   together...). One handle per activity key, created lazily on first join.
---
--- The dispatcher owns: registration, the exclusive slot rule, participant tracking (join /
--- leave / ready / disconnect), state broadcasting (activityState cache slice + push on
--- change), and the generic client->server gameplay event channel ("activityEvent").
--- Modules own: their phase machine, per-participant fields, win conditions and rewards.

local M = {
    dependencies = { "services_players", "services_permissions",
        "communications_rx", "communications_tx" },

    TYPES = {
        EXCLUSIVE = "exclusive",
        HYBRID = "hybrid",
    },

    ---@type table<string, BJSActivityModule> key -> module
    registry = {},

    ---@type BJSActivityHandle?
    exclusive = nil,
    ---@type table<string, BJSActivityHandle> key -> handle
    hybrids = {},
}

---@class BJSActivityModule
---@field KEY string unique id (wire + cache key)
---@field TYPE string M.TYPES value
---@field MIN_PLAYERS integer?
---@field canStart? fun(ctxt: BJSContext, settings: table?): boolean, string?
---@field onStart? fun(handle: BJSActivityHandle, settings: table?)
---@field onPlayerJoin? fun(handle: BJSActivityHandle, player: BJSPlayer): boolean? deny join when false
---@field onPlayerReady? fun(handle: BJSActivityHandle, player: BJSPlayer)
---@field onClientEvent? fun(handle: BJSActivityHandle, player: BJSPlayer, eventName: string, ...)
---@field onPlayerLeave? fun(handle: BJSActivityHandle, player: BJSPlayer, disconnected: boolean)
---@field onSlowTick? fun(handle: BJSActivityHandle)
---@field onStop? fun(handle: BJSActivityHandle, reason: string)

---@class BJSActivityHandle
---@field key string
---@field module BJSActivityModule
---@field phase string module-defined; "" until onStart sets one
---@field settings table
---@field participants tablelib<string, table> playerName -> module-owned public fields (ready flag managed here)
---@field state table module-owned public state, broadcast to every client

--- broadcast the public activity state to every player (and fill caches on request)
--- participants travel as an ARRAY of records ({name = ..., ...fields}), never as a
--- playerName-keyed map: purely-numeric display names would otherwise be mangled by the
--- JSON layer (numeric-string keys are converted back to numbers by the client parser)
local function getPublicState()
    local function pack(handle)
        if not handle then return nil end
        local participants = {}
        handle.participants:forEach(function(fields, playerName)
            local record = { name = playerName }
            for k, v in pairs(fields) do
                record[k] = v
            end
            table.insert(participants, record)
        end)
        table.sort(participants, function(a, b) return a.name < b.name end)
        return {
            key = handle.key,
            type = handle.module.TYPE,
            phase = handle.phase,
            settings = handle.settings,
            participants = participants,
            state = handle.state,
        }
    end
    local res = { exclusive = pack(M.exclusive), hybrids = {} }
    table.forEach(M.hybrids, function(handle, key)
        res.hybrids[key] = pack(handle)
    end)
    return res
end

local function broadcastState()
    communications_tx.sendToPlayer(communications_tx.ALL_PLAYERS, "sendCache", {
        activityState = getPublicState(),
    })
end

---@param caches table
local function onBJRequestCache(caches)
    caches.activityState = getPublicState()
end

--- handle factory: the object passed to every module callback
---@param key string
---@param module BJSActivityModule
---@param settings table?
---@return BJSActivityHandle
local function createHandle(key, module, settings)
    local handle = {
        key = key,
        module = module,
        phase = "",
        settings = settings or {},
        participants = Table(),
        state = {},
    }

    --- switch phase and broadcast
    ---@param phase string
    function handle.setPhase(phase)
        handle.phase = phase
        broadcastState()
    end

    --- broadcast current state (call after mutating handle.state/participants)
    function handle.sendState()
        broadcastState()
    end

    ---@return integer
    function handle.countParticipants()
        return handle.participants:length()
    end

    --- stop this activity (exclusive: frees the slot; hybrid: resets the lobby)
    ---@param reason string "ended"|"cancelled"|"starved"|"forced"
    function handle.stop(reason)
        M.stopActivity(handle, reason)
    end

    --- call when results become final (e.g. a winner is declared): participants leaving or
    --- disconnecting afterwards stay in the broadcast roster so the results screen stays
    --- coherent (their player.activity is still released normally)
    function handle.freezeParticipants()
        handle.frozen = true
    end

    return handle
end

--- module discovery: every services/activities/*.lua file is required and registered
local function loadModules()
    local dir = BJSPluginPath .. "/services/activities"
    if not FS.Exists(dir) then return end
    for _, fileName in pairs(FS.ListFiles(dir)) do
        if fileName:endswith(".lua") then
            local modName = fileName:gsub(".lua$", "")
            local ok, module = pcall(require, "services/activities/" .. modName)
            if not ok or type(module) ~= "table" then
                LogError(string.format("Activity module \"%s\" failed to load: %s",
                    modName, tostring(module)))
            elseif type(module.KEY) ~= "string" or #module.KEY == 0 then
                LogError(string.format("Activity module \"%s\" has no KEY", modName))
            elseif M.registry[module.KEY] then
                LogError(string.format("Duplicate activity KEY \"%s\" (%s)", module.KEY, modName))
            elseif module.TYPE ~= M.TYPES.EXCLUSIVE and module.TYPE ~= M.TYPES.HYBRID then
                LogError(string.format("Activity \"%s\" has invalid TYPE \"%s\"",
                    module.KEY, tostring(module.TYPE)))
            else
                -- NOT registered into extensions[] on purpose: contract names like
                -- onPlayerJoin(handle, player) would collide with the same-named native
                -- BeamMP hooks (onPlayerJoin(playerID)); the dispatcher forwards everything
                M.registry[module.KEY] = module
                LogInfo(string.format("Activity \"%s\" registered (%s)", module.KEY, module.TYPE))
            end
        end
    end
end

---@param handle BJSActivityHandle
---@param reason string
function M.stopActivity(handle, reason)
    if handle.module.onStop then
        pcall(handle.module.onStop, handle, reason)
    end
    -- release players
    handle.participants:forEach(function(_, playerName)
        local player = services_players.players[playerName]
        if player and player.activity == handle.key then
            player.activity = nil
        end
    end)
    if M.exclusive == handle then
        M.exclusive = nil
    elseif M.hybrids[handle.key] == handle then
        M.hybrids[handle.key] = nil
    end
    broadcastState()
end

---@param ctxt BJSContext
---@param key string
---@param settings table?
local function onActivityStart(ctxt, key, settings)
    local module = M.registry[key]
    if not module or module.TYPE ~= M.TYPES.EXCLUSIVE then return end
    -- ctxt.origin == "vote": a successful ACTIVITY_START vote is its own authorization
    -- (services_votes gates vote creation on the VoteActivity permission instead)
    if ctxt.origin ~= "vote" and
        not services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.StartActivity) then
        return
    end
    if M.exclusive then return end -- slot busy

    if module.canStart then
        local ok, errKey = module.canStart(ctxt, settings)
        if not ok then
            if errKey then
                communications_tx.sendToPlayer(ctxt.senderID, "activityDenied", key, errKey)
            end
            return
        end
    end

    M.exclusive = createHandle(key, module, settings)
    if module.onStart then
        local ok, err = pcall(module.onStart, M.exclusive, settings)
        if not ok then
            LogError(string.format("Activity \"%s\" onStart failed: %s", key, tostring(err)))
            M.stopActivity(M.exclusive, "cancelled")
            return
        end
    end
    broadcastState()
end

---@param ctxt BJSContext
---@param key string
local function onActivityStop(ctxt, key)
    local handle = (M.exclusive and M.exclusive.key == key) and M.exclusive or M.hybrids[key]
    if not handle then return end
    -- staff or the StartActivity permission can force-stop
    if not services_permissions.hasAllPermissions(ctxt.senderID, BJ_PERMISSIONS.StartActivity) and
        not services_permissions.isStaff(MP.GetPlayerName(ctxt.senderID)) then
        return
    end
    M.stopActivity(handle, "forced")
end

---@param ctxt BJSContext
---@return BJSPlayer?
local function getSender(ctxt)
    local playerName = MP.GetPlayerName(ctxt.senderID)
    return services_players.players[playerName]
end

---@param ctxt BJSContext
---@param key string
local function onActivityJoin(ctxt, key)
    local player = getSender(ctxt)
    local module = M.registry[key]
    if not player or not module then return end
    if player.activity then return end -- already in an activity

    local handle
    if module.TYPE == M.TYPES.EXCLUSIVE then
        handle = M.exclusive
        if not handle or handle.key ~= key then return end
    else -- hybrid lobbies are created lazily on first join
        handle = M.hybrids[key]
        if not handle then
            handle = createHandle(key, module)
            M.hybrids[key] = handle
            if module.onStart then pcall(module.onStart, handle, nil) end
        end
    end
    if handle.participants[player.playerName] then return end

    if module.onPlayerJoin then
        local ok, deny = pcall(module.onPlayerJoin, handle, player)
        if not ok then
            LogError(string.format("Activity \"%s\" onPlayerJoin failed: %s", key, tostring(deny)))
            communications_tx.sendToPlayer(ctxt.senderID, "activityDenied", key, "activity.joinDenied")
            return
        elseif deny == false then -- module denied the join (wrong phase, full...)
            communications_tx.sendToPlayer(ctxt.senderID, "activityDenied", key, "activity.joinDenied")
            return
        end
    end
    -- modules may have populated a richer record in onPlayerJoin; minimal shape otherwise
    if not handle.participants[player.playerName] then
        handle.participants[player.playerName] = {}
    end
    handle.participants[player.playerName].ready = false
    player.activity = key
    broadcastState()
end

---@param ctxt BJSContext
---@param key string
local function onActivityLeave(ctxt, key)
    local player = getSender(ctxt)
    if not player then return end
    local handle = (M.exclusive and M.exclusive.key == key) and M.exclusive or M.hybrids[key]
    if not handle or not handle.participants[player.playerName] then return end

    local entry = handle.participants[player.playerName]
    -- frozen (results final): keep the roster intact so the results screen stays coherent
    if not handle.frozen then
        handle.participants[player.playerName] = nil
    end
    if player.activity == key then player.activity = nil end
    if handle.module.onPlayerLeave then
        -- the (possibly removed) participant entry is passed so modules can finalize scoring
        pcall(handle.module.onPlayerLeave, handle, player, false, entry)
    end
    broadcastState()
end

---@param ctxt BJSContext
---@param key string
local function onActivityReady(ctxt, key)
    local player = getSender(ctxt)
    if not player then return end
    local handle = (M.exclusive and M.exclusive.key == key) and M.exclusive or M.hybrids[key]
    if not handle or not handle.participants[player.playerName] then return end

    handle.participants[player.playerName].ready = true
    if handle.module.onPlayerReady then
        pcall(handle.module.onPlayerReady, handle, player)
    end
    broadcastState()
end

--- generic gameplay event channel (module-defined semantics)
---@param ctxt BJSContext
---@param key string
---@param eventName string
local function onActivityEvent(ctxt, key, eventName, ...)
    local player = getSender(ctxt)
    if not player then return end
    local handle = (M.exclusive and M.exclusive.key == key) and M.exclusive or M.hybrids[key]
    if not handle or not handle.participants[player.playerName] then return end

    if handle.module.onClientEvent then
        local ok, err = pcall(handle.module.onClientEvent, handle, player, eventName, ...)
        if not ok then
            LogError(string.format("Activity \"%s\" event \"%s\" failed: %s",
                key, tostring(eventName), tostring(err)))
        end
    end
end

--- disconnects: release the player everywhere, let modules react
---@param playerID integer
local function onPlayerDisconnect(playerID)
    local playerName = MP.GetPlayerName(playerID)
    local function handleLeave(handle)
        if handle and handle.participants[playerName] then
            local entry = handle.participants[playerName]
            if not handle.frozen then
                handle.participants[playerName] = nil
            end
            if handle.module.onPlayerLeave then
                local player = services_players.players[playerName]
                pcall(handle.module.onPlayerLeave, handle,
                    player or { playerName = playerName, playerID = playerID }, true, entry)
            end
            broadcastState()
        end
    end
    handleLeave(M.exclusive)
    table.forEach(M.hybrids, handleLeave)
end

local function onSlowUpdate()
    if M.exclusive and M.exclusive.module.onSlowTick then
        local ok, err = pcall(M.exclusive.module.onSlowTick, M.exclusive)
        if not ok then
            LogError(string.format("Activity \"%s\" slow tick failed: %s",
                M.exclusive.key, tostring(err)))
        end
    end
    table.forEach(M.hybrids, function(handle)
        if handle.module.onSlowTick then
            pcall(handle.module.onSlowTick, handle)
        end
    end)
end

--- map switch kills every running activity
local function onMapChanged()
    if M.exclusive then M.stopActivity(M.exclusive, "cancelled") end
    table.forEach(M.hybrids, function(handle)
        M.stopActivity(handle, "cancelled")
    end)
end

local function onInit()
    loadModules()

    communications_rx.addHandler("activityStart", onActivityStart)
    communications_rx.addHandler("activityStop", onActivityStop)
    communications_rx.addHandler("activityJoin", onActivityJoin)
    communications_rx.addHandler("activityLeave", onActivityLeave)
    communications_rx.addHandler("activityReady", onActivityReady)
    communications_rx.addHandler("activityEvent", onActivityEvent)
end

M.onInit = onInit
M.onBJRequestCache = onBJRequestCache
M.onPlayerDisconnect = onPlayerDisconnect
M.onSlowUpdate = onSlowUpdate
M.onMapChanged = onMapChanged

M.getPublicState = getPublicState
M.broadcastState = broadcastState
-- public entry for other services (votes: a successful ACTIVITY_START vote starts the
-- activity with the vote CREATOR as the permission subject)
M.requestStart = onActivityStart
M.requestStop = onActivityStop

return M
