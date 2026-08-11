local M = {
    _windowName = "BJMenu",

    show = false,

    menuHeight = 20,
    ---@type BJWindow?
    windowConfig = nil,
}
-- gc prevention
local size, position

---@param ctxt TickContext
local function render(ctxt)
    local isStaff = beamjoy_permissions.isStaff()
    BeginMenuBar()

    if not isStaff and MenuItem(beamjoy_lang.translate("beamjoy.menu.toggleMain"), nil,
            beamjoy_communications_ui.windowStates["main"]) then
        beamjoy_communications_ui.toggleWindow("main")
        M.toggle()
    end

    if isStaff and MenuItem(beamjoy_lang.translate("beamjoy.menu.toggleConfig"), nil,
            beamjoy_communications_ui.windowStates["config"]) then
        beamjoy_communications_ui.toggleWindow("config")
        M.toggle()
    end

    if beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.SwitchMap) then
        local currentMap = getCurrentLevelIdentifier()
        local countAvail = 0
        local maps = table.filter(beamjoy_maps.data, function(map, name)
            if not map.ignore and map.enabled and
                currentMap ~= tostring(name):lower() then
                countAvail = countAvail + 1
            end
            return not map.ignore and map.enabled
        end)
        if maps:length() > 0 and countAvail > 0 then
            RenderMenuDropdown(beamjoy_lang.translate("beamjoy.menu.switchMap"),
                maps:map(function(map, name)
                    local isCurrent = currentMap == tostring(name):lower()
                    return {
                        type = "item",
                        label = map.label,
                        active = isCurrent,
                        checked = isCurrent,
                        disabled = isCurrent,
                        onClick = function()
                            beamjoy_communications.send("switchMap", name)
                            M.toggle()
                        end,
                    }
                end):values():sort(function(a, b)
                    return a.label < b.label
                end) or {})
        end
    end

    -- Activities dropdown, built dynamically from the framework registry: a new activity
    -- module appears here with ZERO menu wiring (docs/ACTIVITIES.md).
    -- EXCLUSIVE modules: start/stop entries, gated by the StartActivity permission (matching
    -- the dispatcher's own rule). HYBRID modules: join/leave entries, open to EVERY player -
    -- the dispatcher's onActivityJoin does not require any permission either.
    if beamjoy_activity_framework then
        local canStartExclusive = beamjoy_permissions.hasAllPermissions(nil,
            BJ_PERMISSIONS.StartActivity)
        local entries = Table()
        local state = beamjoy_activity_framework.state
        local running = state and state.exclusive or nil
        table.forEach(beamjoy_activity_framework.registry, function(mod, key)
            local serverEntry = running and running.key == key and running
                or (state and state.hybrids and state.hybrids[key]) or nil
            local isHybrid = serverEntry and serverEntry.type == "hybrid"
            -- client modules do not carry TYPE; hybrids are recognizable once their lobby
            -- exists server-side, and by an optional TYPE field on the client module
            isHybrid = isHybrid or mod.TYPE == "hybrid"
            local label = beamjoy_lang.translate(mod.LABEL or key, mod.LABEL or key)

            if isHybrid then
                local joined = beamjoy_activity_framework.currentKey == key
                local count = 0
                if serverEntry and serverEntry.participants then
                    count = #serverEntry.participants
                end
                entries:insert({
                    type = "item",
                    label = string.format("%s (%d)", label, count),
                    active = joined,
                    checked = joined,
                    disabled = beamjoy_activity_framework.currentKey ~= nil and not joined,
                    onClick = function()
                        beamjoy_communications.send(joined and "activityLeave" or "activityJoin", key)
                        M.toggle()
                    end,
                })
            elseif canStartExclusive then
                local isRunning = running and running.key == key
                entries:insert({
                    type = "item",
                    label = label,
                    active = isRunning == true,
                    checked = isRunning == true,
                    disabled = running ~= nil and not isRunning,
                    onClick = function()
                        beamjoy_communications.send(isRunning and "activityStop" or "activityStart", key)
                        M.toggle()
                    end,
                })
            end
        end)
        if entries:length() > 0 then
            entries:sort(function(a, b) return a.label < b.label end)
            RenderMenuDropdown(beamjoy_lang.translate("beamjoy.menu.activities", "Activities"),
                entries)
        end
    end

    -- Spectate dropdown: visible while an exclusive activity runs and the local player is
    -- not a participant (beamjoy_spectate gates itself)
    if beamjoy_spectate and beamjoy_spectate.isAvailable and beamjoy_spectate.isAvailable() then
        RenderMenuDropdown(beamjoy_lang.translate("beamjoy.menu.spectate", "Spectate"), {
            { type = "item", label = beamjoy_lang.translate("beamjoy.spectate.next", "Next participant"),
                onClick = function() beamjoy_spectate.next() end },
            { type = "item", label = beamjoy_lang.translate("beamjoy.spectate.prev", "Previous participant"),
                onClick = function() beamjoy_spectate.prev() end },
            { type = "item", label = beamjoy_lang.translate("beamjoy.spectate.autoFollow", "Auto-follow leader"),
                checked = beamjoy_spectate.autoFollow == true,
                onClick = function() beamjoy_spectate.toggleAutoFollow() end },
            { type = "item", label = beamjoy_lang.translate("beamjoy.spectate.stop", "Stop spectating"),
                onClick = function() beamjoy_spectate.stop() end },
        })
    end

    if beamjoy_config.data.IntroPanel and beamjoy_config.data.IntroPanel.enabled and
        MenuItem(beamjoy_lang.translate("beamjoy.menu.showIntroPanel")) then
        beamjoy_communications_ui.openIntroPanel()
        M.toggle()
    end

    RenderMenuDropdown(beamjoy_lang.translate("beamjoy.menu.about"), {
        { type = "item", label = string.var(beamjoy_lang.translate("beamjoy.menu.about.label"), { version = beamjoy_main.VERSION, buildversion = beamjoy_main.BUILD }) },
        { type = "item", label = beamjoy_lang.translate("beamjoy.menu.about.createdBy") },
        { type = "item", label = beamjoy_lang.translate("beamjoy.menu.about.continuedBy") },
        { type = "item", label = string.var(beamjoy_lang.translate("beamjoy.menu.about.computerTime"), { time = math.floor(ctxt.now / 1000) }) },
    })

    EndMenuBar()
end

local function onInit()
    size = ImVec2(GetMainViewport().Size.x, M.menuHeight)
    beamjoy_imgui_manager.GUI.registerWindow(M._windowName, size)

    M.windowConfig = {
        name = M._windowName,
        flags = {
            ui_imgui.WindowFlags_MenuBar,
            ui_imgui.WindowFlags_NoResize,
            ui_imgui.WindowFlags_NoMove,
            ui_imgui.WindowFlags_NoCollapse,
            ui_imgui.WindowFlags_NoScrollbar,
            ui_imgui.WindowFlags_NoScrollWithMouse,
            ui_imgui.WindowFlags_NoTitleBar,
            ui_imgui.WindowFlags_NoBackground,
            ui_imgui.WindowFlags_NoDocking,
        },
        alpha = 1,
        render = render,
    }
end

local function onUpdate()
    if M.show and M.windowConfig and beamjoy_context then
        size = ImVec2(GetMainViewport().Size.x, M.menuHeight)
        position = ImVec2(GetMainViewport().Pos.x, GetMainViewport().Pos.y)
        RenderWindow(beamjoy_context.get(), M.windowConfig.name,
            table.assign(M.windowConfig, { size = size, position = position }))
    end
end

local function toggle()
    M.show = not M.show
end

M.onInit = onInit
M.onUpdate = onUpdate

M.toggle = toggle

return M
