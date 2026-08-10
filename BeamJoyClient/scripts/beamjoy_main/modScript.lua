-- BeamJoy V4 version scheme: <BeamNG tested>-<BeamMP tested>-<release>, e.g. "0.39-4.22.1-1".
-- The first segment is enforced here, mirroring BeamMP's own modScript gate: loading the mod
-- on an untested game version produces silent, hard-to-diagnose breakage (see TRACKING.md
-- section 5/12.5 for what 0.38->0.39 alone broke), so we refuse loudly instead.
local COMPATIBLE_GAME_MINOR = 39

local ver = split(beamng_versionb, ".")
local majorVer = tonumber(ver[2])
if majorVer ~= COMPATIBLE_GAME_MINOR then
    log('W', 'beamjoy', 'BeamJoy is not compatible with BeamNG.drive version ' .. tostring(beamng_versionb)
        .. ' (built for 0.' .. COMPATIBLE_GAME_MINOR .. '.x). Not loading.')
    guihooks.trigger("toastrMsg", {
        type = "error",
        title = "BeamJoy not loaded",
        msg = "BeamJoy is built for BeamNG 0." .. COMPATIBLE_GAME_MINOR ..
            ".x and you are running " .. tostring(beamng_versionb) .. ".",
    })
    return
end

local _ = load('beamjoy_main')
setExtensionUnloadMode('beamjoy_main', 'manual')
