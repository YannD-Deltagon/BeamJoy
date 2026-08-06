local im = ui_imgui

local U = {}

---@param r number
---@param g number
---@param b number
---@param a number
---@return vec4
function U.RGBA(r, g, b, a)
    return im.ImVec4(r, g, b, a)
end

U.RGBA_PRECISION = 3

U.WINDOW_FLAGS = {
    MENU_BAR = im.WindowFlags_MenuBar, -- adds menu bar
    NO_SCROLLBAR = im.WindowFlags_NoScrollbar, -- prevents scrollbar to appear
    NO_SCROLL_WITH_MOUSE = im.WindowFlags_NoScrollWithMouse, -- prevents window from getting scrolled with mouse
    NO_COLLAPSE = im.WindowFlags_NoCollapse, -- hides the collapse button
    NO_FOCUS_ON_APPEARING = im.WindowFlags_NoFocusOnAppearing, -- prevents window from taking focus on showing
    NO_RESIZE = im.WindowFlags_NoResize, -- prevents window from being resized
    NO_TITLE_BAR = im.WindowFlags_NoTitleBar, -- prevents window from having a title bar
    NO_MOVE = im.WindowFlags_NoMove, -- prevents window from being moved by user
    NO_BACKGROUND = im.WindowFlags_NoBackground, -- hides background and borders
    NO_INPUTS = im.WindowFlags_NoInputs, -- prevents user from interacting with the window
    NO_DOCKING = im.WindowFlags_NoDocking, -- prevents window from being docked
    ALWAYS_AUTO_RESIZE = im.WindowFlags_AlwaysAutoResize, -- window will always auto resize to fit its contents (avoid BeginChild as they are wrongly shrinked)
}

U.COLOR_PICKER_FLAGS = {
    NO_INPUTS = im.ColorEditFlags_NoInputs,
    NO_ALPHA = im.ColorEditFlags_NoAlpha,
    NO_PICKER = im.ColorEditFlags_NoPicker,
    NO_OPTIONS = im.ColorEditFlags_NoOptions,
    NO_SMALLPREVIEW = im.ColorEditFlags_NoSmallPreview,
    NO_TOOLTIP = im.ColorEditFlags_NoTooltip,
    NO_LABEL = im.ColorEditFlags_NoLabel,
    NO_SIDEPREVIEW = im.ColorEditFlags_NoSidePreview,
    NO_BORDER = im.ColorEditFlags_NoBorder,
}

U.STYLE_COLS = {
    WINDOW_BG = im.Col_WindowBg,
    POPUP_BG = im.Col_PopupBg,
    CHILD_BG = im.Col_ChildBg,
    MENUBAR_BG = im.Col_MenuBarBg,
    TEXT_COLOR = im.Col_Text,
    HELPMARKER = im.Col_TextDisabled,
    BORDER_COLOR = im.Col_Border,
    RESIZE_GRIP = im.Col_ResizeGrip,
    RESIZE_GRIP_HOVERED = im.Col_ResizeGripHovered,
    RESIZE_GRIP_ACTIVE = im.Col_ResizeGripActive,
    SCROLLBAR = im.Col_ScrollbarGrab,
    SCROLLBAR_HOVERED = im.Col_ScrollbarGrabHovered,
    SCROLLBAR_ACTIVE = im.Col_ScrollbarGrabActive,
    TITLE_BG = im.Col_TitleBg,
    TITLE_BG_ACTIVE = im.Col_TitleBgActive,
    TITLE_BG_COLLAPSED = im.Col_TitleBgCollapsed,
    TAB = im.Col_Tab,
    TAB_HOVERED = im.Col_TabHovered,
    TAB_ACTIVE = im.Col_TabActive,
    TAB_UNFOCUSED = im.Col_TabUnfocused,
    TAB_UNFOCUSED_ACTIVE = im.Col_TabUnfocusedActive,
    FRAME_BG = im.Col_FrameBg,
    FRAME_BG_HOVERED = im.Col_FrameBgHovered,
    FRAME_BG_ACTIVE = im.Col_FrameBgActive,
    HEADER = im.Col_Header,
    HEADER_HOVERED = im.Col_HeaderHovered,
    HEADER_ACTIVE = im.Col_HeaderActive,
    SEPARATOR = im.Col_Separator,
    SEPARATOR_HOVERED = im.Col_SeparatorHovered,
    SEPARATOR_ACTIVE = im.Col_SeparatorActive,
    BUTTON = im.Col_Button,
    BUTTON_HOVERED = im.Col_ButtonHovered,
    BUTTON_ACTIVE = im.Col_ButtonActive,
    SLIDER_GRAB = im.Col_SliderGrab,
    SLIDER_GRAB_ACTIVE = im.Col_SliderGrabActive,
    TABLE_HEADER_BG = im.Col_TableHeaderBg,
    TABLE_ROW_BG = im.Col_TableRowBg,
    TABLE_ROW_BG_ALT = im.Col_TableRowBgAlt,
    TABLE_BORDER_STRONG = im.Col_TableBorderStrong,
    TABLE_BORDER_LIGHT = im.Col_TableBorderLight,
    DOCKING_PREVIEW = im.Col_DockingPreview,
    PROGRESSBAR = im.Col_PlotHistogram,
}

U.MOUSE_BUTTONS = {
    LEFT = im.MouseButton_Left,
    RIGHT = im.MouseButton_Right,
    MIDDLE = im.MouseButton_Middle
}

-- reverse lookup built once; SetStyleColor used to linear-scan the ~40 STYLE_COLS entries on
-- every push, and it runs dozens of times per frame (InitDefaultStyles + every builder)
local VALID_STYLE_COLS = {}
for _, v in pairs(U.STYLE_COLS) do
    VALID_STYLE_COLS[v] = true
end

---@param col number
---@param color vec4
function U.SetStyleColor(col, color)
    if not VALID_STYLE_COLS[col] then
        error(string.var("Invalid style column: {1}", { col }))
        return
    end

    im.PushStyleColor2(col, color)
end

function U.PopStyleColor(amount)
    im.PopStyleColor(amount)
end

---@typetable<string, vec4>
U.BJIStyles = {}
---@typetable<string, vec4>
U.TEXT_COLORS = {}
---@typetable<string, vec4[]>
U.BTN_PRESETS = {}
---@typetable<string, vec4[]>
U.INPUT_PRESETS = {}

U.BJIThemeLoaded = false
local stylesCount = 0
---@param data { Fields: table<string, number[]>, Text: table<string, number[]>, Button: table<string, number[][]>, Input: table<string, number[][]> }
function U.LoadTheme(data)
    if U.BJIThemeLoaded then
        U.PopStyleColor(2)
    end

    for k, v in pairs(data.Fields) do
        U.BJIStyles[U.STYLE_COLS[k]] = U.RGBA(v[1], v[2], v[3], v[4])
    end

    for k, v in pairs(data.Text) do
        U.TEXT_COLORS[k] = U.RGBA(v[1], v[2], v[3], v[4])
    end

    for k, v in pairs(data.Button) do
        local colors = {}
        for i, col in pairs(v) do
            colors[tonumber(i)] = U.RGBA(col[1], col[2], col[3], col[4])
        end
        U.BTN_PRESETS[k] = colors
    end

    for k, v in pairs(data.Input) do
        local colors = {}
        for i, col in pairs(v) do
            colors[tonumber(i)] = U.RGBA(col[1], col[2], col[3], col[4])
        end
        U.INPUT_PRESETS[k] = colors
    end

    -- Preset normalization: the builders push these colors directly every frame (they no
    -- longer copy presets per call), so every slot they index must be non-nil after this
    -- point. Button presets: [1..3] = bg/hovered/active, [4] = text/icon color. Input
    -- presets: [1] = frame bg, [2] = text override, [3..6] = hovered/active/grab/grab-active.
    -- Required slots are backfilled too: themes come from the server's bjc.json which admins
    -- hand-edit; a missing slot would otherwise skip a push while the builder still pops a
    -- fixed count, underflowing the frame-level style stack.
    local fallback = U.RGBA(.5, .5, .5, .5)
    for k, preset in pairs(U.BTN_PRESETS) do
        preset[1] = preset[1] or fallback
        preset[2] = preset[2] or preset[1]
        preset[3] = preset[3] or preset[1]
        preset[4] = preset[4] or
            (k == "DISABLED" and U.TEXT_COLORS.DISABLED or U.TEXT_COLORS.DEFAULT)
    end
    for k, preset in pairs(U.INPUT_PRESETS) do
        preset[1] = preset[1] or fallback
        preset[2] = preset[2] or
            (k == "DISABLED" and U.TEXT_COLORS.DISABLED or U.TEXT_COLORS.DEFAULT)
        preset[3] = preset[3] or preset[1]
        preset[4] = preset[4] or preset[1]
        preset[5] = preset[5] or preset[1]
        preset[6] = preset[6] or preset[1]
    end

    -- style count is stable between theme loads; cached for the per-frame ResetStyles pop
    stylesCount = table.length(U.BJIStyles)

    -- pre-applying those to have multi-windows colors right
    U.SetStyleColor(U.STYLE_COLS.TITLE_BG, U.BJIStyles[U.STYLE_COLS.TITLE_BG])
    U.SetStyleColor(U.STYLE_COLS.TITLE_BG_ACTIVE, U.BJIStyles[U.STYLE_COLS.TITLE_BG_ACTIVE])
    U.BJIThemeLoaded = true
end

function U.InitDefaultStyles()
    for k, v in pairs(U.BJIStyles) do
        U.SetStyleColor(k, v)
    end
    U.SetStyleColor(U.STYLE_COLS.TEXT_COLOR, U.TEXT_COLORS.DEFAULT)
end

function U.ResetStyles()
    U.PopStyleColor(stylesCount + 1)
end

return U
