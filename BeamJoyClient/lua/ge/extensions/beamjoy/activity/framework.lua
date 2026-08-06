--- Activity framework - client side.
---
--- Mirrors the server dispatcher (BeamJoyServer/services/activities.lua). Client activity
--- modules are auto-discovered from lua/ge/extensions/beamjoy/activity/activities/ - adding
--- a game mode requires NO change to this file (see docs/ACTIVITIES.md).
---
--- Responsibilities: receive the activityState cache slice, route lifecycle transitions to
--- the active module (onJoin/onStateUpdate/onLeave), enforce the module's input restrictions
--- through beamjoy_restrictions, forward the shared slow-update tick, bridge join/ready/
--- leave/start actions from the Angular UI, and expose sendEvent() for gameplay reports.

local M = {
    dependencies = { "beamjoy_communications", "beamjoy_communications_ui",
        "beamjoy_players", "beamjoy_permissions", "beamjoy_restrictions" },

    ---@type table<string, BJClientActivityModule> key -> module
    registry = {},

    ---@type table? last received public state ({exclusive?, hybrids})
    state = nil,
    ---@type BJClientActivityModule? module the local player currently participates in
    current = nil,
    ---@type string? key of the activity the local player currently participates in
    currentKey = nil,
}

---@class BJClientActivityModule
---@field KEY string matches the server module KEY
---@field LABEL string? UI label (falls back to KEY)
---@field getRestrictions? fun(state: table): string[] input actions blocked while participating
---@field onJoin? fun(state: table) local player entered the participants list
---@field onStateUpdate? fun(state: table) any state/phase/participants change while participating
---@field onLeave? fun(reason: string?) local player left / activity stopped
---@field onSlowUpdate? fun(ctxt: TickContext, state: table) ~250ms while participating
---@field getUIDetails? fun(state: table): {label: string, value: string}[] extra rows for the activity window

--- module discovery (same pattern as classic BJI managers, on the game VFS)
local function loadModules()
    Table(FS:directoryList("/lua/ge/extensions/beamjoy/activity/activities"))
        :filter(function(path) return path:endswith(".lua") end)
        :forEach(function(path)
            local ok, module = pcall(require, path:gsub("^/lua/", ""):gsub(".lua$", ""))
            if not ok or type(module) ~= "table" then
                LogError(string.format("Client activity module \"%s\" failed to load: %s",
                    path, tostring(module)))
            elseif type(module.KEY) ~= "string" or #module.KEY == 0 then
                LogError(string.format("Client activity module \"%s\" has no KEY", path))
            else
                M.registry[module.KEY] = module
                LogInfo(string.format("Client activity \"%s\" registered", module.KEY))
            end
        end)
end

---@return string? playerName of the local player
local function getSelfName()
    local self = beamjoy_players.getSelf()
    return self and self.playerName or nil
end

--- participants travel as an array of {name, ...} records (see the server dispatcher)
---@param entry table?
---@param playerName string?
---@return table? record
local function findParticipant(entry, playerName)
    if not entry or not playerName then return nil end
    for _, p in ipairs(entry.participants or {}) do
        if p.name == playerName then return p end
    end
    return nil
end

--- the activity entry (exclusive or hybrid) the local player participates in, if any
---@param state table?
---@return table? entry, string? key
local function findSelfActivity(state)
    local selfName = getSelfName()
    if not state or not selfName then return nil, nil end
    if findParticipant(state.exclusive, selfName) then
        return state.exclusive, state.exclusive.key
    end
    for key, entry in pairs(state.hybrids or {}) do
        if findParticipant(entry, selfName) then
            return entry, key
        end
    end
    return nil, nil
end

--- compose and push the descriptor consumed by the Angular activity window;
--- the entry shown is the one the local player participates in (exclusive OR hybrid),
--- falling back to the running exclusive activity for spectators
local function pushUIState()
    local selfName = getSelfName()
    local entry = findSelfActivity(M.state)
    entry = entry or (M.state and M.state.exclusive) or nil
    if not entry then
        beamjoy_communications_ui.send("BJActivityState", { visible = false })
        return
    end
    local module = M.registry[entry.key]
    local participants = {}
    for _, p in ipairs(entry.participants or {}) do
        table.insert(participants, {
            name = p.name,
            ready = p.ready == true,
            eliminated = p.eliminated == true,
            position = p.position,
        })
    end
    table.sort(participants, function(a, b)
        if a.position ~= b.position then
            return (a.position or math.huge) < (b.position or math.huge)
        end
        return a.name < b.name
    end)
    local selfP = findParticipant(entry, selfName)
    local details = {}
    if module and module.getUIDetails then
        local ok, res = pcall(module.getUIDetails, entry)
        if ok and type(res) == "table" then details = res end
    end
    beamjoy_communications_ui.send("BJActivityState", {
        visible = true,
        key = entry.key,
        label = module and module.LABEL or entry.key,
        phase = entry.phase,
        participants = participants,
        self = {
            participant = selfP ~= nil,
            ready = selfP and selfP.ready == true or false,
        },
        -- mirrors the server-side stop authorization (permission OR staff)
        canStop = beamjoy_permissions.hasAnyPermission(nil, BJ_PERMISSIONS.StartActivity)
            or beamjoy_permissions.isStaff(),
        state = entry.state,
        details = details,
    })
end

---@param caches table
local function retrieveCache(caches)
    if not caches.activityState then return end
    M.state = caches.activityState

    local entry, key = findSelfActivity(M.state)
    if key and key ~= M.currentKey then
        -- joined (or switched) an activity
        if M.current and M.current.onLeave then pcall(M.current.onLeave, "switched") end
        M.currentKey = key
        M.current = M.registry[key]
        if M.current and M.current.onJoin then pcall(M.current.onJoin, entry) end
        extensions.hook("onBJScenarioChanged") -- beamjoy_restrictions listens to this
    elseif not key and M.currentKey then
        -- left / activity stopped
        if M.current and M.current.onLeave then pcall(M.current.onLeave, "stopped") end
        M.current, M.currentKey = nil, nil
        extensions.hook("onBJScenarioChanged")
    elseif key then
        if M.current and M.current.onStateUpdate then
            pcall(M.current.onStateUpdate, entry)
        end
        -- restrictions may depend on the phase (module.getRestrictions receives the entry),
        -- so they are re-evaluated on every state change too - update() diffs before applying
        beamjoy_restrictions.update()
    end

    pushUIState()
    extensions.hook("onBJActivityStateChanged", M.state)
end

--- contributes the active module's blocked input actions (beamjoy_restrictions hook)
---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    if M.current and M.current.getRestrictions then
        local entry = findSelfActivity(M.state)
        local ok, list = pcall(M.current.getRestrictions, entry or {})
        if ok and type(list) == "table" then
            for _, action in ipairs(list) do
                restrictions:insert(action)
            end
        end
    end
end

---@param ctxt TickContext
local function onSlowUpdate(ctxt)
    if M.current and M.current.onSlowUpdate then
        local entry = findSelfActivity(M.state)
        if entry then
            pcall(M.current.onSlowUpdate, ctxt, entry)
        end
    end
end

--- gameplay report channel for modules (self-elimination, checkpoint...)
---@param eventName string
local function sendEvent(eventName, ...)
    if M.currentKey then
        beamjoy_communications.send("activityEvent", M.currentKey, eventName, ...)
    end
end

--- UI actions bridge (join/leave/ready/start/stop from the Angular window)
---@param action string
---@param key string?
---@param settings table?
local function onUIAction(action, key, settings)
    key = key or (M.state and M.state.exclusive and M.state.exclusive.key) or M.currentKey
    if not key then return end
    if action == "join" then
        beamjoy_communications.send("activityJoin", key)
    elseif action == "leave" then
        beamjoy_communications.send("activityLeave", key)
    elseif action == "ready" then
        beamjoy_communications.send("activityReady", key)
    elseif action == "start" then
        beamjoy_communications.send("activityStart", key, settings)
    elseif action == "stop" then
        beamjoy_communications.send("activityStop", key)
    end
end

local function onInit()
    loadModules()
    beamjoy_communications.addHandler("sendCache", retrieveCache)
    beamjoy_communications.addHandler("activityDenied", function(key, errKey)
        beamjoy_communications_ui.uiBroadcast(errKey, nil, "orange", 5)
    end)
    beamjoy_communications_ui.addHandler("BJActivityAction", onUIAction)
end

M.onInit = onInit
M.onBJRequestRestrictions = onBJRequestRestrictions
M.onSlowUpdate = onSlowUpdate

M.retrieveCache = retrieveCache
M.sendEvent = sendEvent
M.startActivity = function(key, settings) onUIAction("start", key, settings) end

return M
