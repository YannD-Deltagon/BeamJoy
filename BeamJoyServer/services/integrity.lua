--- Integrity / anti-cheat layer - server side (cross-cutting, not an activity module).
---
--- While a player participates in the server-wide EXCLUSIVE activity AND that activity is in
--- a "running-like" phase (anything but the lobby/ended bookends - see EXEMPT_PHASES below),
--- this module vetoes vehicle spawns/config edits so participants cannot swap to a better car,
--- retune, or re-pick parts mid-game. Every veto is logged for staff review.
---
--- Vehicle spawn/edit vetoes are REAL: onVehicleSpawn/onVehicleEdited are native BeamMP hooks
--- wired by BeamJoyServer.lua's loadHooks as hookWithReturn (a non-nil return blocks the
--- action before BeamMP applies it) - see BeamJoyServer.lua:155-157.
---
--- Chat-command / console gating is DETECTION ONLY, not enforcement:
--- - onBJChatCommand (fired by services_chat.onChatMessage after prefix-stripping) is
---   delivered through the generic `extensions.hook` fan-out (BeamJoyServer.lua:116-125), which
---   calls every registered handler unconditionally and ignores return values entirely - there
---   is no way to stop services_chatCommands.lua's own onBJChatCommand handler (which performs
---   the actual dispatch) from this hook. We log every command a running participant issues so
---   staff can review, but we cannot block it. A real gate needs services_chatCommands.lua (or
---   the onBJChatCommand hook itself) to change shape - see integration.frameworkNeeds.
--- - onConsoleInput (onBJSConsoleInput) carries no player identity at all: its signature is
---   `onConsoleInput(message)` with no playerID (see services/consoleCommands.lua:90) because it
---   fires for the SERVER OPERATOR's own local console, not a remote player action - there is
---   nothing here for a per-player gate to attach to. The real per-player "console" attack
---   surface is the client's in-game Lua console (0.39 `toggleConsoleNG`), which is blocked by
---   the client-side integrity restriction set instead (see
---   BeamJoyClient/lua/ge/extensions/beamjoy/integrity.lua).
---
--- NOTE on phase-name reliance: the activity framework treats `phase` as fully module-defined
--- (docs/ACTIVITIES.md), so "lobby" and "ended" are a convention set by the reference Speed
--- module, not an enforced contract. Activities that pick different phase names for their
--- pre-game/results states will have this module treat them as "running" the whole time
--- (fail-safe: over-restrictive, never under-restrictive).

local M = {
    dependencies = { "services_activities", "services_players" },

    -- phases where vetoes are OFF: initial "" (before onStart), "lobby" (prep - players are
    -- expected to pick/spawn their vehicle here), "ended" (results screen, game already
    -- decided). Every other phase string is treated as running-like and gets vetoed.
    EXEMPT_PHASES = { [""] = true, lobby = true, ended = true },
}

---@param playerName string?
---@return boolean isParticipant
---@return BJSActivityHandle? handle
local function getRunningParticipation(playerName)
    local handle = services_activities.exclusive
    if not playerName or not handle then return false end
    if not handle.participants[playerName] then return false end
    if M.EXEMPT_PHASES[handle.phase] then return false end
    return true, handle
end

---@param playerName string
---@param handle BJSActivityHandle
---@param action string short tag for the log line
local function logVeto(playerName, handle, action)
    LogWarn(string.format(
        "[integrity] vetoed %s by \"%s\" - participant of exclusive activity \"%s\" (phase \"%s\")",
        action, playerName, handle.key, handle.phase))
end

--- hookWithReturn: return 1 to veto the spawn (see BeamJoyServer.lua loadHooks). Ordering
--- caveat: services_vehicles.lua registers the SAME hook and does real bookkeeping (writes
--- player.vehicles + broadcasts) on the SAME call before/after ours depending on
--- `extensions.hookWithReturn`'s unspecified `pairs()` iteration order over `_G.extensions` -
--- if it runs before us on a spawn we go on to veto, its bookkeeping/broadcast has already
--- happened even though the overall spawn ends up rejected. Not a correctness issue for the
--- veto itself (BeamMP still blocks the spawn client-side), but it can leave a stray
--- `player.vehicles` entry server-side; flagged in integration.frameworkNeeds.
---@param playerID integer
---@return integer? reject
local function onVehicleSpawn(playerID)
    local playerName = MP.GetPlayerName(playerID)
    local isParticipant, handle = getRunningParticipation(playerName)
    if isParticipant then
        logVeto(playerName, handle, "vehicle spawn")
        return 1
    end
end

--- hookWithReturn: return 1 to veto the config edit (parts/paints/tuning change). Same
--- ordering caveat as onVehicleSpawn above.
---@param playerID integer
---@return integer? reject
local function onVehicleEdited(playerID)
    local playerName = MP.GetPlayerName(playerID)
    local isParticipant, handle = getRunningParticipation(playerName)
    if isParticipant then
        logVeto(playerName, handle, "vehicle edit")
        return 1
    end
end

--- DETECTION ONLY - see file header. Cannot block execution; logs for staff review.
---@param ctxt BJSContext
---@param args string[] command name at [1], its own args after
local function onBJChatCommand(ctxt, args)
    local playerName = ctxt.sender and ctxt.sender.playerName or nil
    local isParticipant, handle = getRunningParticipation(playerName)
    if isParticipant then
        LogWarn(string.format(
            "[integrity] participant \"%s\" issued chat command \"/%s\" during activity \"%s\" (phase \"%s\") - NOT ENFORCED, detection only (see integration.frameworkNeeds)",
            playerName, tostring(args[1]), handle.key, handle.phase))
    end
end

M.onVehicleSpawn = onVehicleSpawn
M.onVehicleEdited = onVehicleEdited
M.onBJChatCommand = onBJChatCommand

return M
