--- Integrity / anti-cheat layer - client side (defense-in-depth, not an activity module).
---
--- Server-side (services/integrity.lua) is authoritative and vetoes vehicle spawn/edit; this
--- module only makes cheating *inconvenient* by blocking the input actions that would let a
--- participant reach for the exploit in the first place (parts/vehicle selector, editor,
--- console, nodegrabber, funstuff...) while they are in a RUNNING exclusive activity. A
--- determined client can still bypass client-side restrictions - the server veto is the real
--- gate, this is UX (fewer surprise rejections) and a second layer against casual cheats.
---
--- Two ways activity modules get this set:
--- 1. Call beamjoy_integrity.getBaseRestrictions() from their own getRestrictions(entry) and
---    merge it in (matches classic module authoring - explicit, easy to read).
--- 2. Automatically: this module's own onBJRequestRestrictions injects the same set whenever
---    beamjoy_activity_framework.current is a participant of the RUNNING exclusive activity,
---    regardless of what the activity module's own getRestrictions() returns - so a new
---    activity that forgets to add these still gets them for free.
--- Both paths funnel through the same beamjoy_restrictions Table, so overlap is harmless
--- (duplicate action names are simply redundant, not an error).

local M = {
    dependencies = { "beamjoy_activity_framework", "beamjoy_restrictions" },

    -- phases where the auto-injection is OFF: mirrors services/integrity.lua's EXEMPT_PHASES
    -- (lobby prep + results screen are not "running"). See that file for the phase-name
    -- convention caveat - unknown phase strings are treated as running-like (fail-safe).
    EXEMPT_PHASES = { [""] = true, lobby = true, ended = true },

    -- shared "can't reach for the exploit" action set - see the 0.39 action catalogs under
    -- core/input/actions/*.json for these exact names.
    BASE_RESTRICTIONS = {
        -- vehicle/parts pickers (menu.json): swapping car or retuning mid-game
        "vehicle_selector", "parts_selector",
        -- level editor (editor.json): bypasses activity state entirely
        "editorToggle", "editorSafeModeToggle",
        -- in-game Lua console (debug.json): arbitrary node/vehicle manipulation
        "toggleConsoleNG",
        -- nodegrabber (gameplay.json): remote node manipulation, including other players'
        -- vehicles
        "nodegrabberGrab", "nodegrabberRender", "nodegrabberPadMode", "nodegrabberPadGrab",
        "nodegrabberAction", "nodegrabberStrength",
        -- funstuff radial actions (gameplay.json): self-boost/break/etc. exploits mid-game
        "funBreak", "funHinges", "funTires", "funRandomTire", "funFire", "funExtinguish",
        "funBoom", "latchesOpen", "latchesClose", "funFling", "funFlingDownward", "funBoost",
        "funBoostBackwards",
        -- radial menu entry points to the funstuff/vehicle actions above (menu.json) - belt
        -- and suspenders since the menu itself is just a shortcut to the blocked actions
        "toggleRadialMenuSandbox", "toggleRadialMenuPlayerVehicle",
        "toggleRadialMenuVehicleFeatures", "toggleRadialMenuMulti",
    },
}

---@return string[] blocked input action names
function M.getBaseRestrictions()
    return table.clone(M.BASE_RESTRICTIONS)
end

--- @return boolean true if the local player is currently a participant of the RUNNING (not
--- lobby/ended) server-wide exclusive activity
local function isRunningExclusiveParticipant()
    local fw = beamjoy_activity_framework
    if not fw or not fw.currentKey or not fw.state or not fw.state.exclusive then return false end
    if fw.state.exclusive.key ~= fw.currentKey then return false end -- participating in a hybrid, not the exclusive
    return not M.EXEMPT_PHASES[fw.state.exclusive.phase]
end

--- auto-injection: fires alongside every activity module's own getRestrictions() via the
--- same beamjoy_restrictions onBJRequestRestrictions fan-out (see beamjoy/restrictions.lua)
---@param restrictions tablelib<integer, string>
local function onBJRequestRestrictions(restrictions)
    if isRunningExclusiveParticipant() then
        for _, action in ipairs(M.BASE_RESTRICTIONS) do
            restrictions:insert(action)
        end
    end
end

M.onBJRequestRestrictions = onBJRequestRestrictions

return M
