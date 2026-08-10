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
    -- module appears here with ZERO menu wiring (docs/ACTIVITIES.md). Exclusive activities
    -- can be started when the slot is free; the running one can be stopped.
    if beamjoy_activity_framework and
        beamjoy_permissions.hasAllPermissions(nil, BJ_PERMISSIONS.StartActivity) then
        local entries = Table()
        local running = beamjoy_activity_framework.state and
            beamjoy_activity_framework.state.exclusive or nil
        table.forEach(beamjoy_activity_framework.registry, function(mod, key)
            local isRunning = running and running.key == key
            entries:insert({
                type = "item",
                label = beamjoy_lang.translate(mod.LABEL or key, mod.LABEL or key),
                active = isRunning == true,
                checked = isRunning == true,
                disabled = running ~= nil and not isRunning,
                onClick = function()
                    if isRunning then
                        beamjoy_communications.send("activityStop", key)
                    else
                        beamjoy_communications.send("activityStart", key)
                    end
                    M.toggle()
                end,
            })
        end)
        if entries:length() > 0 then
            entries:sort(function(a, b) return a.label < b.label end)
            RenderMenuDropdown(beamjoy_lang.translate("beamjoy.menu.activities", "Activities"),
                entries)
        end
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
