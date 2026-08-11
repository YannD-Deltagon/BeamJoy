--- Tag Duo - client side.
--- Companion of BeamJoyServer/services/activities/tagduo.lua; this file is the whole client
--- side of the game mode and never touches the framework.
---
--- While paired and "it": watches the local vehicle's distance to the partner's vehicle every
--- slow update (~250ms) via beamjoy_vehicles (MPVehicleGE-backed positions); within tag range
--- it reports the tag and lets the server settle the swap - matching classic BeamJoy's and V4
--- Speed's trust model. The server is the sole authority on pairing/roles; this file never
--- guesses at them, it only reads the broadcast state.

local M = {
    KEY = "tagduo",
    LABEL = "beamjoy.activity.tagduo.title", -- translated by the activity window

    TAG_DISTANCE = 3,       -- meters between vehicles to register a tag
    RESEND_COOLDOWN_MS = 1000, -- local throttle so a sustained touch doesn't flood the network

    -- transition tracking (own pair/role at last onStateUpdate), nil while unpaired
    lastPairId = nil,
    lastTagger = nil,
    -- ms timestamp until which onSlowUpdate won't re-send "tagged" even if still in range
    tagCooldownUntil = nil,
}

---@param entry table activity public entry (phase/state/participants)
---@return table? own participant record (with the module's custom fields)
local function findSelf(entry)
    local self = beamjoy_players.getSelf()
    if not self then return nil end
    for _, p in ipairs(entry.participants or {}) do
        if p.name == self.playerName then return p end
    end
    return nil
end

function M.onJoin()
    M.lastPairId, M.lastTagger, M.tagCooldownUntil = nil, nil, nil
end

---@param reason string?
function M.onLeave(reason)
    M.lastPairId, M.lastTagger, M.tagCooldownUntil = nil, nil, nil
    beamjoy_communications_ui.send("BJHUDText", { message = "" })
end

---@param entry table
function M.onStateUpdate(entry)
    local self = findSelf(entry)
    if not self then return end

    if self.pairId ~= M.lastPairId then
        if self.pairId and self.partner then
            beamjoy_communications_ui.send("BJHUDText", {
                message = string.var(
                    beamjoy_lang.translate("beamjoy.activity.tagduo.paired", "Paired with {playerName}"),
                    { playerName = self.partner }),
                color = "white",
                duration = 3000,
            })
        else
            beamjoy_communications_ui.send("BJHUDText", {
                message = beamjoy_lang.translate("beamjoy.activity.tagduo.waitingForPartner",
                    "Waiting for a partner..."),
                color = "white",
                duration = 3000,
            })
        end
        M.lastTagger = nil -- force the role message below to (re-)fire for the new pair
    end

    if self.pairId and self.tagger ~= M.lastTagger then
        if self.tagger then
            beamjoy_communications_ui.send("BJHUDText", {
                message = string.var(
                    beamjoy_lang.translate("beamjoy.activity.tagduo.youAreIt", "YOU ARE IT! Catch {playerName}"),
                    { playerName = self.partner or "?" }),
                color = "red",
                duration = 3000,
            })
        else
            beamjoy_communications_ui.send("BJHUDText", {
                message = string.var(
                    beamjoy_lang.translate("beamjoy.activity.tagduo.flee", "TAGGED! Flee from {playerName}"),
                    { playerName = self.partner or "?" }),
                color = "orange",
                duration = 3000,
            })
        end
    end

    M.lastPairId = self.pairId
    M.lastTagger = self.tagger
end

---@param ctxt TickContext
---@param entry table activity public entry (phase/state/participants)
function M.onSlowUpdate(ctxt, entry)
    local self = findSelf(entry)
    if not self or not self.pairId or not self.tagger then return end -- unpaired or fleeing
    if M.tagCooldownUntil and ctxt.now < M.tagCooldownUntil then return end
    if not ctxt.mpVeh or not ctxt.mpVeh.isLocal or not ctxt.mpVeh.veh then return end -- on foot / no vehicle

    local partnerPlayer = beamjoy_players.players[self.partner]
    if not partnerPlayer or not partnerPlayer.currentVehicle then return end
    local partnerVeh = beamjoy_vehicles.getVehicleByRemoteID(partnerPlayer.currentVehicle, true)
    if not partnerVeh or not partnerVeh.position then return end

    local selfPos = beamjoy_vehicles.getVehiclePositionRotation(ctxt.mpVeh.veh)
    if math.horizontalDistance(selfPos, partnerVeh.position) <= M.TAG_DISTANCE then
        beamjoy_activity_framework.sendEvent("tagged")
        M.tagCooldownUntil = ctxt.now + M.RESEND_COOLDOWN_MS
    end
end

---@param entry table
---@return {label: string, value: string}[]
function M.getUIDetails(entry)
    local details = {}
    local self = findSelf(entry)
    if not self then return details end

    table.insert(details, {
        label = beamjoy_lang.translate("beamjoy.activity.tagduo.partnerLabel", "Partner"),
        value = self.partner or
            beamjoy_lang.translate("beamjoy.activity.tagduo.waiting", "waiting for a partner..."),
    })
    if self.partner then
        table.insert(details, {
            label = beamjoy_lang.translate("beamjoy.activity.tagduo.roleLabel", "Role"),
            value = self.tagger and
                beamjoy_lang.translate("beamjoy.activity.tagduo.roleTagger", "Tagger") or
                beamjoy_lang.translate("beamjoy.activity.tagduo.roleRunner", "Runner"),
        })
    end
    table.insert(details, {
        label = beamjoy_lang.translate("beamjoy.activity.tagduo.scoreLabel", "Your tags"),
        value = tostring(self.score or 0),
    })
    return details
end

return M
