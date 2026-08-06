local logTag = "BJIDrawBuilders"
local lineHeight = 20

-- gc prevention
local _, windowOpen, scale, footerHeight, flags, ok, err
local val1, val2, val3, val4, val5, val6, val7

-- V3.0 allocation control ------------------------------------------------------------------
-- Dear ImGui copies every value handed to it (style colors, ImVec2 sizes, in/out pointers)
-- during the call itself, so FFI objects can be scratch buffers reused across widgets instead
-- of being reallocated per call per frame - the same module-level ptr/buffer pattern the
-- game's own imgui code uses (see e.g. beammp/ui/chat.lua chatMessageBuf). Per-frame FFI and
-- table churn was this UI layer's dominant cost: every widget used to rebuild its style
-- preset as fresh ImVec4s plus a Table wrapper and closures, on every frame.

-- read-only default for builders when the caller passes no data table; NEVER write into it
local EMPTY = {}

-- refreshed once per RenderWindow call (and used by menus/children/tooltips inside it)
local uiScale = 1

-- scratch cdata, safe to share since every builder finishes reading them before returning
local scratchInt = ui_imgui.IntPtr(0)
local scratchFloat = ui_imgui.FloatPtr(0)
local scratchColor4 = ui_imgui.ArrayFloat(4)
local scratchOpen = ui_imgui.BoolPtr(true)
local scratchVecA = ui_imgui.ImVec2(0, 0)
local scratchVecB = ui_imgui.ImVec2(0, 0)

-- Widget id strings ("##id" / "label##id") are stable across frames, so they are memoized
-- instead of being concatenated per call. The caches are wiped past a safety cap so windows
-- generating pathological amounts of dynamic ids cannot grow them forever.
-- these helpers keep their own locals on purpose: they run in the middle of builder calls,
-- so they must not touch the shared val1..val7 scratch upvalues
local hiddenIds, hiddenIdsCount = {}, 0
---@param id string
---@return string
local function HiddenId(id)
    local entry = hiddenIds[id]
    if not entry then
        if hiddenIdsCount > 4096 then
            hiddenIds, hiddenIdsCount = {}, 0
        end
        entry = "##" .. id
        hiddenIds[id] = entry
        hiddenIdsCount = hiddenIdsCount + 1
    end
    return entry
end
local labeledIds, labeledIdsCount = {}, 0
---@param label string
---@param id string
---@return string
local function LabeledId(label, id)
    local entry = labeledIds[id]
    if not entry then
        -- count NEW keys only: a label changing every frame (countdown in a button label)
        -- rebuilds its entry in place and must not push the cache toward the wipe cap
        if labeledIdsCount > 4096 then
            labeledIds, labeledIdsCount = {}, 0
        end
        entry = { label = label, str = label .. "##" .. id }
        labeledIds[id] = entry
        labeledIdsCount = labeledIdsCount + 1
    elseif entry.label ~= label then
        entry.label = label
        entry.str = label .. "##" .. id
    end
    return entry.str
end
---------------------------------------------------------------------------------------------

-- IMGUI
---@class ImBool

---@return ImBool
BoolTrue = ui_imgui.BoolTrue or function() return {} end
---@return ImBool
BoolFalse = ui_imgui.BoolFalse or function() return {} end
---@param val boolean
---@return {[0]: boolean}
BoolPtr = ui_imgui.BoolPtr or function(val) return {} end
---@param val integer
---@return {[0]: integer}
IntPtr = ui_imgui.IntPtr or function(val) return { [0] = 0 } end
---@param val number
---@return {[0]: number}
FloatPtr = ui_imgui.FloatPtr or function(val) return { [0] = 0 } end
---@param size integer
---@param val string
---@return {[0]: string}
StrPtr = function(val, size) return ui_imgui.ArrayChar(size, val) end
---@param strPtr {[0]: string}
---@return string
StrPtrValue = require('ffi').string or function(strPtr) return "" end
---@param values string[]
---@return {[0]: string}
ArrayCharPtr = ui_imgui.ArrayCharPtrByTbl or function(values) return {} end
---@param count integer
---@return {[0]: number}
ArrayFloatPtr = ui_imgui.ArrayFloat or function(count) return {} end
---@param content string
---@return boolean success
SetClipboardContent = function(content)
    ok, err = pcall(ui_imgui.SetClipboardText, content)
    if not ok then
        LogError("Error setting clipboard content : " .. err)
    end
    return ok
end
---@return string
GetClipboardContent = function()
    ok, err = pcall(ui_imgui.GetClipboardText)
    if not ok then
        LogError("Error getting clipboard content : " .. err)
    end
    return ok and StrPtrValue(err) or ""
end
---@return point
ImVec2 = ui_imgui.ImVec2 or function(x, y) return {} end
---@return vec4
ImVec4 = ui_imgui.ImVec4 or function(x, y, z, w) return {} end
---@param ... integer
---@return integer
Flags = ui_imgui.flags or function(...) return 0 end
---@return integer
GetCursorPosX = ui_imgui.GetCursorPosX or function() return 0 end
---@param x number
SetCursorPosX = ui_imgui.SetCursorPosX or function(x) end
---@param colIndex integer? 0-N
---@return integer
GetTableColumnWidth = function(colIndex)
    return ui_imgui.GetColumnWidth(colIndex or ui_imgui.TableGetColumnIndex())
end
---@return table
GetStyle = ui_imgui.GetStyle or function() return {} end
---@param text string
---@return point
CalcTextSize = ui_imgui.CalcTextSize or function(text) return {} end
---@return point
GetContentRegionAvail = ui_imgui.GetContentRegionAvail or function() return {} end
---@param column integer
---@param color vec4
PushStyleColor = function(column, color)
    -- hot path: light guards only, no pcall (PushStyleColor2 does not throw on valid input)
    if type(column) ~= "number" then
        LogError("style type is invalid")
        return
    elseif color == nil then
        LogError("color must be a vec4")
        return
    end
    ui_imgui.PushStyleColor2(column, color)
end
---@param amount integer
PopStyleColor = ui_imgui.PopStyleColor or function(amount) end
---@param wrapPosX number|0 regionAvail.x wrapping if ZERO
PushTextWrapPos = ui_imgui.PushTextWrapPos or function(wrapPosX) end
PopTextWrapPos = ui_imgui.PopTextWrapPos or function() end
---@return point
GetWindowSize = ui_imgui.GetWindowSize or function() return ImVec2(0, 0) end
---@param size point
SetNextWindowSize = ui_imgui.SetNextWindowSize or function(size) end
---@param minSize point?
---@param maxSize point?
SetNextWindowSizeConstraints = ui_imgui.SetNextWindowSizeConstraints or function(minSize, maxSize) end
---@param position point
SetNextWindowPos = ui_imgui.SetNextWindowPos or function(position) end
---@param alpha number 0-1
SetNextWindowBgAlpha = ui_imgui.SetNextWindowBgAlpha or function(alpha) end
---@param scale number
SetWindowFontScale = ui_imgui.SetWindowFontScale or function(scale) end
---@param width integer|-1
PushItemWidth = ui_imgui.PushItemWidth or function(width) end
PopItemWidth = ui_imgui.PopItemWidth or function() end
---@param width integer
SetNextItemWidth = ui_imgui.SetNextItemWidth or function(width) end
---@return boolean
IsItemHovered = ui_imgui.IsItemHovered or function() return false end
---@param mouseBtn integer
---@return boolean
IsItemClicked = ui_imgui.IsItemClicked or function(mouseBtn) return false end

local menuStarted, menuLevel = false, 0
BeginMenuBar = function()
    if menuStarted then
        LogError("BeginMenuBar already called", logTag)
        return
    end
    ui_imgui.BeginMenuBar()
    menuStarted = true
end
EndMenuBar = function()
    if not menuStarted then
        LogError("EndMenuBar called without BeginMenuBar", logTag)
        return
    end
    ui_imgui.EndMenuBar()
    menuStarted = false
end
---@param label string
---@return boolean isOpen
BeginMenu = function(label)
    if not menuStarted then
        LogError("BeginMenu called without BeginMenuBar", logTag)
        return false
    elseif menuLevel >= 2 then
        LogError("3rd level menu is not supported", logTag)
        return false
    end

    menuLevel = menuLevel + 1
    val1 = ui_imgui.BeginMenu(label)
    if val1 then
        if menuLevel == 1 then
            SetWindowFontScale(1)
        else
            SetWindowFontScale(uiScale)
        end
    end
    return val1
end
--- call only if BeginMenu == true
---@param menuOpened boolean
EndMenu = function(menuOpened)
    if not menuStarted then
        LogError("EndMenu called without BeginMenuBar", logTag)
        return
    elseif menuLevel <= 0 then
        LogError("EndMenu called without BeginMenu", logTag)
        return
    end

    menuLevel = menuLevel - 1
    if menuOpened then
        ui_imgui.EndMenu()
    end
end
---@param label string
---@param shortcut string?
---@param selected boolean? default false
---@param enabled boolean? default true
---@return boolean clicked
MenuItem = function(label, shortcut, selected, enabled)
    if not menuStarted then
        LogError("MenuItem called without BeginMenuBar", logTag)
        return false
    end

    val1 = selected == true and BoolTrue() or BoolFalse()
    val2 = enabled ~= false and BoolTrue() or BoolFalse()
    return ui_imgui.MenuItem1(label, shortcut, val1, val2)
end

---@class MenuDropdownElement
---@field type "item"|"separator"|"custom"|"menu"
---@field label string? -- item|menu
---@field color vec4? -- item|menu
---@field disabled boolean? -- item
---@field checked boolean? -- item
---@field active boolean? -- item|menu
---@field onClick fun()? -- item
---@field elems MenuDropdownElement[]? -- menu -- 2 levels deep maximum
---@field render fun()? -- custom

---@param label string
---@param elements MenuDropdownElement[]
---@param parentColor? vec4
RenderMenuDropdown = function(label, elements, parentColor)
    if not menuStarted then
        LogError("RenderMenuDropdown called without BeginMenuBar", logTag)
        return
    elseif menuLevel > 0 then
        LogError("RenderMenuDropdown called on a nested menu", logTag)
        return
    end

    ---@param lbl string
    ---@param els MenuDropdownElement[]
    ---@param col vec4?
    ---@param level integer?
    local function drawMenuWithElems(lbl, els, col, level)
        level = level or 0
        if level >= 2 then
            LogError("3rd level menu is not supported", logTag)
            return
        end

        if col then
            PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR, col)
        end
        local opened = BeginMenu(lbl)
        if col then
            PopStyleColor(1)
        end
        if opened then
            for _, el in ipairs(els) do
                if el.type == "item" then
                    if el.active then
                        val7 = BJI.Utils.Style.TEXT_COLORS.HIGHLIGHT
                    elseif el.disabled then
                        val7 = BJI.Utils.Style.TEXT_COLORS.DISABLED
                    else
                        val7 = el.color or BJI.Utils.Style.TEXT_COLORS.DEFAULT
                    end
                    PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR, val7)
                    if MenuItem(el.label, nil, el.checked, not el.disabled) and el.onClick then
                        el.onClick()
                    end
                    PopStyleColor(1)
                elseif el.type == "separator" then
                    Separator()
                elseif el.type == "custom" then
                    if el.render then
                        el.render()
                    else
                        LogError("Custom element has no render function", logTag)
                    end
                elseif el.type == "menu" then
                    val7 = el.active and BJI.Utils.Style.TEXT_COLORS.HIGHLIGHT or el.color
                    drawMenuWithElems(el.label, el.elems, val7, level + 1)
                end
            end
        end
        EndMenu(opened)
    end
    drawMenuWithElems(label, elements, parentColor)
end

---@param entries MenuDropdownElement[]
MenuDropdownSanitize = function(entries)
    -- remove separators at the beginning
    while #entries > 0 and entries[1].type == "separator" do
        table.remove(entries, 1)
    end
    -- remove separators at the end
    while #entries > 0 and entries[#entries].type == "separator" do
        table.remove(entries, #entries)
    end
    -- remove following separators
    for i = 2, #entries - 2 do
        if entries[i].type == "separator" then
            while entries[i + 1] and entries[i + 1].type == "separator" do
                table.remove(entries, i + 1)
            end
        end
    end
end

---@param id string
---@return boolean isValid
BeginTabBar = ui_imgui.BeginTabBar or function(id) return false end
--- call only if BeginTabBar == true
EndTabBar = ui_imgui.EndTabBar or function() end
---@param label string
---@return boolean isSelected
BeginTabItem = ui_imgui.BeginTabItem or function(label) return false end
--- call only if BeginTabItem == true
EndTabItem = ui_imgui.EndTabItem or function() end
---@param label string
SetTabItemClosed = ui_imgui.SetTabItemClosed or function(label) end
local childLevel = 0
---@param id string
---@param data {size: point?, outsideSize: boolean?, border: boolean?, flags: integer[]?, bgColor: vec4?}?
---@return boolean isVisible
-- transparent HEADER color pushed around children with a custom background; built once
local childHeaderTransparent = ui_imgui.ImVec4(0, 0, 0, 0)
BeginChild = function(id, data)
    if childLevel > 10 then
        LogError("Too many nested children", logTag)
        return false
    end
    data = data or EMPTY
    -- size resolution on locals: the caller's descriptor (possibly reused) is never mutated
    local sx, sy = -1, -1
    if data.size then
        sx, sy = data.size.x, data.size.y
        if sx < -1 then                              -- substract from avail space
            sx = GetContentRegionAvail().x + sx
        elseif sx > -1 and not data.outsideSize then -- content size
            sx = sx + BJI.Utils.UI.MARGINS.CHILD * 2
        end
        if sy < -1 then                              -- substract from avail space
            sy = GetContentRegionAvail().y + sy
        elseif sy > -1 and not data.outsideSize then -- content size
            sy = sy + BJI.Utils.UI.MARGINS.CHILD * 2
        end
    end

    if data.bgColor then
        PushStyleColor(BJI.Utils.Style.STYLE_COLS.HEADER, childHeaderTransparent)
        PushStyleColor(BJI.Utils.Style.STYLE_COLS.CHILD_BG, data.bgColor)
    end

    val1 = nil
    if data.flags and #data.flags > 0 then
        val1 = Flags(table.unpack(data.flags))
    end
    scratchVecA.x, scratchVecA.y = sx, sy
    val2 = ui_imgui.BeginChild1(HiddenId(id), scratchVecA, data.border, val1)

    if data.bgColor then
        PopStyleColor(2)
    end

    childLevel = childLevel + 1
    if val2 then
        if childLevel % 2 == 0 then
            SetWindowFontScale(uiScale)
        else
            SetWindowFontScale(1)
        end
    end

    return val2
end
EndChild = function()
    if childLevel <= 0 then
        LogError("EndChild called without BeginChild", logTag)
        return
    end
    ui_imgui.EndChild()

    childLevel = childLevel - 1
    if childLevel % 2 == 0 then
        SetWindowFontScale(uiScale)
    else
        SetWindowFontScale(1)
    end
end

---@param label string
---@param data {color: vec4?}?
---@return boolean isOpen
BeginTree = function(label, data)
    data = data or EMPTY

    PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR,
        data.color or BJI.Utils.Style.TEXT_COLORS.DEFAULT)

    val1 = ui_imgui.TreeNode1(label)

    PopStyleColor(1)

    return val1
end
---@param label string
---@param flags integer
---@return boolean isOpen
BeginTreeFlags = ui_imgui.TreeNodeEx1 or function(label, flags) return false end
--- call only if BeginTree == true
EndTree = ui_imgui.TreePop or function() end

---@param width integer?
Indent = ui_imgui.Indent or function(width) end
---@param width integer?
Unindent = ui_imgui.Unindent or function(width) end
SameLine = ui_imgui.SameLine or function() end
NewLine = ui_imgui.NewLine or function() end
Separator = ui_imgui.Separator or function() end
---@param text any
---@param data {color: vec4?, align: "left"|"center"|"right"?, wrap: boolean?}?
Text = function(text, data)
    if type(text) ~= "string" then text = tostring(text) end
    data = data or EMPTY

    if data.align == "center" then
        SetCursorPosX(GetCursorPosX() + (GetContentRegionAvail().x - CalcTextSize(text).x) / 2)
    elseif data.align == "right" then
        SetCursorPosX(GetCursorPosX() + GetContentRegionAvail().x - CalcTextSize(text).x)
    end

    if data.wrap then
        PushTextWrapPos(0)
    end

    ui_imgui.TextColored(data.color or BJI.Utils.Style.TEXT_COLORS.DEFAULT, text)

    if data.wrap then
        PopTextWrapPos()
    end
end
EmptyLine = function() Text("") end

---@param text string?
TooltipText = function(text)
    -- ui_imgui.tooltip(text) -- cannot use because UIScale couldn't get updated
    if text and IsItemHovered() then
        BeginTooltip(); Text(text); EndTooltip()
    end
end
---@return boolean isValid
BeginTooltip = function()
    val2 = ui_imgui.BeginTooltip()
    if val2 then
        SetWindowFontScale(uiScale)
    end
    return val2
end
EndTooltip = ui_imgui.EndTooltip or function() end
---@param text string
ShowHelpMarker = ui_imgui.ShowHelpMarker or function(text) end

local colsCount, currCol = 1, 1
---@param count integer 1-N
---@param id string?
---@param border boolean?
---@return boolean isCreated
Columns = function(count, id, border)
    EndColumns()
    ui_imgui.Columns(count, id, border)
    colsCount, currCol = count, 1
    return true
end
---@param width number|-1
ColumnSetWidth = function(width)
    ui_imgui.SetColumnWidth(currCol - 1, math.ceil(width))
end
ColumnNext = function()
    ui_imgui.NextColumn()
    -- increment and wrap if needed
    currCol = (currCol % colsCount) + 1
end
ColumnNextLine = function()
    ColumnNext()
    while currCol > 1 do
        ColumnNext()
    end
end
EndColumns = function()
    if colsCount > 1 then
        if currCol > 1 then
            ColumnNextLine()
        end
        ui_imgui.Columns(1)
        colsCount, currCol = 1, 1
    end
end

TABLE_FLAGS = {
    RESIZABLE = ui_imgui.TableFlags_Resizable,
    REORDERABLE = ui_imgui.TableFlags_Reorderable,
    HIDEABLE = ui_imgui.TableFlags_Hideable,
    SORTABLE = ui_imgui.TableFlags_Sortable,
    NO_SAVED_SETTINGS = ui_imgui.TableFlags_NoSavedSettings,
    CONTEXT_MENU_IN_BODY = ui_imgui.TableFlags_ContextMenuInBody,
    ALTERNATE_ROW_BG = ui_imgui.TableFlags_RowBg,
    BORDERS_INNER_H = ui_imgui.TableFlags_BordersInnerH,
    BORDERS_OUTER_H = ui_imgui.TableFlags_BordersOuterH,
    BORDERS_INNER_V = ui_imgui.TableFlags_BordersInnerV,
    BORDERS_OUTER_V = ui_imgui.TableFlags_BordersOuterV,
    BORDERS_H = ui_imgui.TableFlags_BordersH,
    BORDERS_V = ui_imgui.TableFlags_BordersV,
    BORDERS_INNER = ui_imgui.TableFlags_BordersInner,
    BORDERS_OUTER = ui_imgui.TableFlags_BordersOuter,
    BORDERS = ui_imgui.TableFlags_Borders,
    NO_BORDERS_IN_BODY = ui_imgui.TableFlags_NoBordersInBody,
    NO_BORDERS_IN_BODY_UNTIL_RESIZE = ui_imgui.TableFlags_NoBordersInBodyUntilResize,
    SIZING_FIXED_FIT = ui_imgui.TableFlags_SizingFixedFit,
    SIZING_FIXED_SAME = ui_imgui.TableFlags_SizingFixedSame,
    SIZING_STRETCH_PROP = ui_imgui.TableFlags_SizingStretchProp,
    SIZING_STRETCH_SAME = ui_imgui.TableFlags_SizingStretchSame,
    NO_HOST_EXTEND_X = ui_imgui.TableFlags_NoHostExtendX,
    NO_HOST_EXTEND_Y = ui_imgui.TableFlags_NoHostExtendY,
    NO_KEEP_COLUMNS_VISIBLE = ui_imgui.TableFlags_NoKeepColumnsVisible,
    PRECISE_WIDTHS = ui_imgui.TableFlags_PreciseWidths,
    NO_CLIP = ui_imgui.TableFlags_NoClip,
    PAD_OUTER_X = ui_imgui.TableFlags_PadOuterX,
    NO_PAD_OUTER_X = ui_imgui.TableFlags_NoPadOuterX,
    NO_PAD_INNER_X = ui_imgui.TableFlags_NoPadInnerX,
    SCROLL_X = ui_imgui.TableFlags_ScrollX,
    SCROLL_Y = ui_imgui.TableFlags_ScrollY,
}
TABLE_COLUMNS_FLAGS = {
    DISABLED = ui_imgui.TableColumnFlags_Disabled,
    DEFAULT_HIDE = ui_imgui.TableColumnFlags_DefaultHide,
    DEFAULT_SORT = ui_imgui.TableColumnFlags_DefaultSort,
    WIDTH_STRETCH = ui_imgui.TableColumnFlags_WidthStretch,
    WIDTH_FIXED = ui_imgui.TableColumnFlags_WidthFixed,
    NO_RESIZE = ui_imgui.TableColumnFlags_NoResize,
    NO_REORDER = ui_imgui.TableColumnFlags_NoReorder,
    NO_HIDE = ui_imgui.TableColumnFlags_NoHide,
    NO_CLIP = ui_imgui.TableColumnFlags_NoClip,
    NO_SORT = ui_imgui.TableColumnFlags_NoSort,
    NO_SORT_ASCENDING = ui_imgui.TableColumnFlags_NoSortAscending,
    NO_SORT_DESCENDING = ui_imgui.TableColumnFlags_NoSortDescending,
    NO_HEADER_LABEL = ui_imgui.TableColumnFlags_NoHeaderLabel,
    NO_HEADER_WIDTH = ui_imgui.TableColumnFlags_NoHeaderWidth,
    PREFER_SORT_ASCENDING = ui_imgui.TableColumnFlags_PreferSortAscending,
    PREFER_SORT_DESCENDING = ui_imgui.TableColumnFlags_PreferSortDescending,
    INDENT_ENABLE = ui_imgui.TableColumnFlags_IndentEnable,
    INDENT_DISABLE = ui_imgui.TableColumnFlags_IndentDisable,
    IS_ENABLED = ui_imgui.TableColumnFlags_IsEnabled,
    IS_VISIBLE = ui_imgui.TableColumnFlags_IsVisible,
    IS_SORTED = ui_imgui.TableColumnFlags_IsSorted,
    IS_HOVERED = ui_imgui.TableColumnFlags_IsHovered,
}
---@param id string
---@param columnsConfig {label: string, flags: integer[]?, width: integer?, userID: integer?}[]
---@param data {showHeader: boolean?, flags: integer[]?}?
---@return boolean isVisible
local tableSizingFlags = {
    [TABLE_FLAGS.SIZING_FIXED_FIT] = true,
    [TABLE_FLAGS.SIZING_FIXED_SAME] = true,
    [TABLE_FLAGS.SIZING_STRETCH_PROP] = true,
    [TABLE_FLAGS.SIZING_STRETCH_SAME] = true,
}
BeginTable = function(id, columnsConfig, data)
    if not table.isArray(columnsConfig) then
        LogError(string.var("Table {1} must be an array", { id }))
        return false
    elseif #columnsConfig < 1 then
        LogError(string.var("Table {1} must have at least one column", { id }))
        return false
    end

    data = data or EMPTY
    -- flags folded on a local accumulator; caller's flag arrays are left untouched
    val2, val3 = 0, false
    if data.flags then
        for i = 1, #data.flags do
            val2 = Flags(val2, data.flags[i])
            if tableSizingFlags[data.flags[i]] then val3 = true end
        end
    end
    if not val3 then -- fit max content size by default
        val2 = Flags(val2, TABLE_FLAGS.SIZING_FIXED_FIT)
    end

    val1 = ui_imgui.BeginTable(id, #columnsConfig, val2)
    if val1 then
        for _, conf in ipairs(columnsConfig) do
            ui_imgui.TableSetupColumn(conf.label, conf.flags and #conf.flags > 0 and
                Flags(table.unpack(conf.flags)) or nil, conf.width, conf.userID)
        end
        if data.showHeader then
            ui_imgui.TableHeadersRow()
        end
    end
    return val1
end
---@param isHeader boolean?
---@param minHeight number?
TableNewRow = function(isHeader, minHeight)
    ui_imgui.TableNextRow(isHeader and ui_imgui.TableRowFlags_Headers or nil, minHeight)
    TableNextColumn() -- auto set to first column
end
---@param colIndex integer 0-N
TableSetColumnIndex = ui_imgui.TableSetColumnIndex or function(colIndex) end
TableNextColumn = ui_imgui.TableNextColumn or function() end
EndTable = function()
    ui_imgui.EndTable()
end
---@param title string
---@param openPtr {[0]: boolean}? window not closeable if nil
---@param flags integer?
---@return boolean isExpanded
BeginWindow = ui_imgui.Begin or function(title, openPtr, flags) return false end
EndWindow = ui_imgui.End or function() end
local baseWindowFlags = Flags(
    BJI.Utils.Style.WINDOW_FLAGS.NO_SCROLLBAR,
    BJI.Utils.Style.WINDOW_FLAGS.NO_SCROLL_WITH_MOUSE,
    BJI.Utils.Style.WINDOW_FLAGS.NO_FOCUS_ON_APPEARING
)
-- reusable body-child descriptor (its size vector is refreshed right before each use)
local bodyChildData = { size = scratchVecB, outsideSize = true }
---@param ctxt TickContext
---@param title string
---@param data BJIWindow
RenderWindow = function(ctxt, title, data)
    -- single UI-scale read per window; every builder below uses the uiScale upvalue
    uiScale = BJI_LocalStorage.get(BJI_LocalStorage.GLOBAL_VALUES.UI_SCALE) or 1
    scale = uiScale
    -- resolved on a local: assigning EMPTY into the persistent window descriptor would alias
    -- the shared read-only sentinel into caller-owned tables (a later table.insert on any
    -- window's flags would then corrupt every EMPTY user at once)
    local dataFlags = data.flags or EMPTY

    -- real local: the shared valN scratch upvalues are clobbered by the builders that the
    -- menu/header/body callbacks below invoke
    local autoResize = table.includes(dataFlags, BJI.Utils.Style.WINDOW_FLAGS.ALWAYS_AUTO_RESIZE)
    if not autoResize then
        if data.size then
            scratchVecA.x, scratchVecA.y = data.size.x * scale, data.size.y * scale
            SetNextWindowSize(scratchVecA)
        else
            if data.minSize then
                scratchVecA.x, scratchVecA.y = data.minSize.x * scale, data.minSize.y * scale
            else
                scratchVecA.x, scratchVecA.y = 0, 0
            end
            if data.maxSize then
                scratchVecB.x = data.maxSize.x >= 0 and data.maxSize.x * scale or -1
                scratchVecB.y = data.maxSize.y >= 0 and data.maxSize.y * scale or -1
            else
                scratchVecB.x = ui_imgui.GetMainViewport().Size.x * scale
                scratchVecB.y = ui_imgui.GetMainViewport().Size.y * scale
            end
            SetNextWindowSizeConstraints(scratchVecA, scratchVecB)
        end
    end
    if data.position then
        SetNextWindowPos(data.position)
    end
    SetNextWindowBgAlpha(BJI.Utils.Style.BJIStyles[BJI.Utils.Style.STYLE_COLS.WINDOW_BG] and
        BJI.Utils.Style.BJIStyles[BJI.Utils.Style.STYLE_COLS.WINDOW_BG].w or .5)

    flags = baseWindowFlags
    for i = 1, #dataFlags do
        flags = Flags(flags, dataFlags[i])
    end
    if data.size then
        flags = Flags(flags, BJI.Utils.Style.WINDOW_FLAGS.NO_RESIZE)
    end
    if data.menu then
        flags = Flags(flags, BJI.Utils.Style.WINDOW_FLAGS.MENU_BAR)
    end

    windowOpen = nil
    if data.onClose then
        scratchOpen[0] = true
        windowOpen = scratchOpen
    end
    if BeginWindow(title, windowOpen, flags) then
        SetWindowFontScale(scale)

        --menu
        if data.menu then
            BeginMenuBar()
            data.menu(ctxt)
            EndMenuBar()
        end

        if data.header then
            data.header(ctxt)
        end

        -- body
        if autoResize then
            data.body(ctxt)
        else
            footerHeight = 0
            if data.footer then
                footerHeight = lineHeight + 5 -- 1 line
                if data.footerLines then
                    footerHeight = footerHeight * data.footerLines(ctxt)
                end
                footerHeight = footerHeight * uiScale
            end
            data._bodyChildId = data._bodyChildId or (data.name .. "_Body")
            scratchVecB.x, scratchVecB.y = -1, -footerHeight
            if BeginChild(data._bodyChildId, bodyChildData) then
                data.body(ctxt)
            end
            EndChild()
        end

        -- footer
        if data.footer then
            data.footer(ctxt)
        end
    end
    SetWindowFontScale(scale)
    EndWindow()
    if data.onClose and windowOpen and not windowOpen[0] then
        data.onClose()
    end
end

---@param id string
---@param label string
---@param data {disabled: boolean?, btnStyle: vec4[]?, width: integer|-1?, noSound: boolean?, sound: string?}?
---@return boolean clicked
Button = function(id, label, data)
    data = data or EMPTY

    -- style presets are already ImVec4 arrays built once at LoadTheme (imgui copies pushed
    -- colors, so sharing them is safe); custom caller styles fall back per missing slot
    if data.disabled then
        val1 = BJI.Utils.Style.BTN_PRESETS.DISABLED
        val6 = val1[4] or BJI.Utils.Style.TEXT_COLORS.DISABLED
    else
        val1 = data.btnStyle or BJI.Utils.Style.BTN_PRESETS.INFO
        val6 = val1[4] or BJI.Utils.Style.TEXT_COLORS.DEFAULT
    end
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON, val1[1])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON_HOVERED, val1[2])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON_ACTIVE, val1[3])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR, val6)

    val2 = nil
    if data.width then
        val5 = data.width
        if val5 == -1 then
            val5 = GetContentRegionAvail().x
        elseif val5 < -1 then
            val5 = val5 + GetContentRegionAvail().x
        end
        scratchVecA.x, scratchVecA.y = val5, 23 * uiScale
        val2 = scratchVecA
    end

    val3 = ui_imgui.Button(LabeledId(label, id), val2)

    if val3 and not data.noSound then
        BJI_Sound.play(data.sound or BJI_Sound.SOUNDS.BIGMAP_HOVER)
    end

    PopStyleColor(4)

    return val3 and not data.disabled
end

---@param id string
---@param value integer
---@param data {step: integer?, stepFast: integer?, disabled: boolean?, inputStyle: vec4[]?, btnStyle: vec4[]?, width: integer|-1?, min: integer?, max: integer?}?
---@return integer? changed
InputInt = function(id, value, data)
    data = data or EMPTY

    if data.disabled then
        val2 = BJI.Utils.Style.INPUT_PRESETS.DISABLED
        val6 = val2[2] or BJI.Utils.Style.TEXT_COLORS.DISABLED
        val3 = BJI.Utils.Style.BTN_PRESETS.DISABLED
    else
        val2 = data.inputStyle or BJI.Utils.Style.INPUT_PRESETS.DEFAULT
        val6 = val2[2] or BJI.Utils.Style.TEXT_COLORS.DEFAULT
        val3 = data.btnStyle or BJI.Utils.Style.BTN_PRESETS.INFO
    end
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG, val2[1])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR, val6)
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON, val3[1])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON_HOVERED, val3[2])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON_ACTIVE, val3[3])

    val7 = data.width or -1
    if val7 < -1 then
        val7 = val7 + GetContentRegionAvail().x
    end
    SetNextItemWidth(val7)

    scratchInt[0] = value
    val5 = ui_imgui.InputInt(HiddenId(id), scratchInt,
        data.step or 1, data.stepFast or (data.step or 1) * 2)

    PopStyleColor(5)

    val4 = nil
    if val5 and not data.disabled then
        val4 = scratchInt[0]
        if data.min or data.max then
            val4 = math.clamp(val4, data.min, data.max)
        end
    end

    return val4 ~= value and val4 or nil
end

---@param id string
---@param value number
---@param data {step: integer?, stepFast: integer?, disabled: boolean?, inputStyle: vec4[]?, btnStyle: vec4[]?, width: integer|-1?, min: number?, max: number?, precision: integer?}?
---@return number? changed
InputFloat = function(id, value, data)
    data = data or EMPTY

    if data.disabled then
        val2 = BJI.Utils.Style.INPUT_PRESETS.DISABLED
        val6 = val2[2] or BJI.Utils.Style.TEXT_COLORS.DISABLED
        val3 = BJI.Utils.Style.BTN_PRESETS.DISABLED
    else
        val2 = data.inputStyle or BJI.Utils.Style.INPUT_PRESETS.DEFAULT
        val6 = val2[2] or BJI.Utils.Style.TEXT_COLORS.DEFAULT
        val3 = data.btnStyle or BJI.Utils.Style.BTN_PRESETS.INFO
    end
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG, val2[1])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR, val6)
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON, val3[1])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON_HOVERED, val3[2])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON_ACTIVE, val3[3])

    val7 = data.width or -1
    if val7 < -1 then
        val7 = val7 + GetContentRegionAvail().x
    end
    SetNextItemWidth(val7)

    val6 = data.step or (1 / ((data.precision or 1) ^ 10))
    scratchFloat[0] = value
    val5 = ui_imgui.InputFloat(HiddenId(id), scratchFloat, val6, data.stepFast or val6 * 10)

    PopStyleColor(5)

    val4 = nil
    if val5 and not data.disabled then
        val4 = scratchFloat[0]
        if data.min or data.max then
            val4 = math.clamp(math.round(val4, data.precision or 3), data.min, data.max)
        end
    end

    return val4 ~= value and val4 or nil
end

---@param id string
---@param value string
---@param data {size: integer?, disabled: boolean?, inputStyle: vec4[]?, width: integer|-1?}?
---@return string? changed
InputText = function(id, value, data)
    data = data or EMPTY
    val6 = data.size or 64

    if data.disabled then
        val2 = BJI.Utils.Style.INPUT_PRESETS.DISABLED
        val7 = val2[2] or BJI.Utils.Style.TEXT_COLORS.DISABLED
    else
        val2 = data.inputStyle or BJI.Utils.Style.INPUT_PRESETS.DEFAULT
        val7 = val2[2] or BJI.Utils.Style.TEXT_COLORS.DEFAULT
    end
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG, val2[1])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR, val7)

    val5 = data.width or -1
    if val5 < -1 then
        val5 = val5 + GetContentRegionAvail().x
    end
    SetNextItemWidth(val5)

    -- text buffers stay per-call: their size varies per widget and imgui edits them in place
    val1 = StrPtr(value, val6)
    val3 = ui_imgui.InputText(HiddenId(id), val1, val6)

    val4 = nil
    if val3 and not data.disabled then
        val4 = StrPtrValue(val1)
    end

    PopStyleColor(2)

    return val4 ~= value and val4 or nil
end

---@param id string
---@param value string
---@param data {size: integer?, width: integer|-1?, disabled: boolean?, inputStyle: vec4[]?}?
---@return string? changed
InputTextMultiline = function(id, value, data)
    data = data or EMPTY
    val6 = data.size or 128

    if data.disabled then
        val2 = BJI.Utils.Style.INPUT_PRESETS.DISABLED
        val7 = val2[2] or BJI.Utils.Style.TEXT_COLORS.DISABLED
    else
        val2 = data.inputStyle or BJI.Utils.Style.INPUT_PRESETS.DEFAULT
        val7 = val2[2] or BJI.Utils.Style.TEXT_COLORS.DEFAULT
    end
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG, val2[1])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR, val7)

    val1 = StrPtr(value, val6)
    -- line count without the split2 table+strings allocation
    val2, val3 = 1, 1
    while true do
        val3 = value:find("\n", val3, true)
        if not val3 then break end
        val2, val3 = val2 + 1, val3 + 1
    end
    if val2 < 2 then val2 = 2 end

    val5 = data.width or -1
    if val5 < -1 then
        val5 = val5 + GetContentRegionAvail().x
    end
    scratchVecA.x, scratchVecA.y = val5, math.ceil(val2 * lineHeight * uiScale)

    SetWindowFontScale(uiScale)
    val4 = ui_imgui.InputTextMultiline(HiddenId(id), val1, val6, scratchVecA)

    PopStyleColor(2)

    val5 = nil
    if val4 and not data.disabled then
        val5 = StrPtrValue(val1)
    end

    SetWindowFontScale(uiScale)
    return val5 ~= value and val5 or nil
end

---@class ComboOption
---@field value any
---@field label string

---@param id string
---@param value any
---@param options ComboOption[]
---@param data {disabled: boolean?, width: integer|-1?, inputStyle: vec4[]?}?
---@return any? changed
Combo = function(id, value, options, data)
    data = data or EMPTY
    val7 = data.disabled or #options < 2

    if val7 then
        val2 = BJI.Utils.Style.INPUT_PRESETS.DISABLED
        val6 = val2[2] or BJI.Utils.Style.TEXT_COLORS.DISABLED
    else
        val2 = data.inputStyle or BJI.Utils.Style.INPUT_PRESETS.DEFAULT
        val6 = val2[2] or BJI.Utils.Style.TEXT_COLORS.DEFAULT
    end
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG, val2[1])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR, val6)

    -- the label array (and its FFI conversion below) is rebuilt per call since options come
    -- from the caller each frame; plain loops instead of the filter/map closure chains
    val3 = 1
    if val7 then
        val4 = { "" }
        for _, el in ipairs(options) do
            if el.value == value then
                val4[1] = el.label
                break
            end
        end
    else
        val4 = {}
        for i, el in ipairs(options) do
            if el.value == value then
                val3 = i
            end
            val4[i] = el.label
        end
    end

    val5 = data.width
    if val5 then
        if val5 < -1 then
            val5 = val5 + GetContentRegionAvail().x
        end
    else
        val5 = 0
        for _, v in ipairs(val4) do
            val6 = BJI.Utils.UI.GetComboWidthByContent(v)
            if val6 > val5 then
                val5 = val6
            end
        end
    end
    SetNextItemWidth(val5)

    scratchInt[0] = val3 - 1
    val5 = ui_imgui.Combo1(HiddenId(id), scratchInt, ArrayCharPtr(val4))

    PopStyleColor(2)

    val6 = nil
    if val5 and not val7 then
        val6 = options[scratchInt[0] + 1].value
    end

    return val6 ~= value and val6 or nil
end

---@param floatPercent number 0-1
---@param data {width: integer?, height: integer?, text: string?, color: vec4?}?
ProgressBar = function(floatPercent, data)
    data = data or EMPTY
    val2 = -1
    if data.width then
        val1 = tonumber(data.width)
        if val1 then
            val2 = math.round(val1) * uiScale
        elseif tostring(data.width):find("%d+%%") then
            val2 = tonumber(tostring(data.width):match("^%d+")) / 100 * GetContentRegionAvail().x
        end
    end
    if data.height then
        val3 = data.height * uiScale
    elseif data.text then
        val3 = CalcTextSize(data.text).y + 2
    else
        val3 = 5 * uiScale
    end

    if data.color then
        PushStyleColor(BJI.Utils.Style.STYLE_COLS.PROGRESSBAR, data.color)
    end

    scratchVecA.x, scratchVecA.y = val2, val3
    ui_imgui.ProgressBar(floatPercent, scratchVecA, data.text or "")

    if data.color then
        PopStyleColor(1)
    end
end

---@param icon string
---@param data {big: boolean?, color: vec4?, borderColor: vec4?}?
Icon = function(icon, data)
    data = data or EMPTY

    val2 = BJI.Utils.UI.GetIconSize(data.big)
    scratchVecA.x, scratchVecA.y = val2, val2

    BJI_Context.GUI.uiIconImage(BJI.Utils.Icon.GetIcon(icon), scratchVecA,
        data.color or BJI.Utils.Style.TEXT_COLORS.DEFAULT, data.borderColor, nil)
end

---@param id string
---@param icon string
---@param data {big: boolean?, btnStyle: vec4[]?, onRelease: boolean?, disabled: boolean?, bgLess: boolean?, noSound: boolean?, sound: string?}?
---@return boolean clicked
IconButton = function(id, icon, data)
    data = data or EMPTY

    -- val1/val2/val3 = bg, hovered, active; val6 = icon color
    if data.disabled then
        if data.bgLess then
            val4 = BJI.Utils.Style.BTN_PRESETS.TRANSPARENT
            val1, val2, val3 = val4[1], val4[2], val4[3]
            val6 = BJI.Utils.Style.BTN_PRESETS.DISABLED[1]
        else
            val4 = BJI.Utils.Style.BTN_PRESETS.DISABLED
            val1, val2, val3 = val4[1], val4[2], val4[3]
            val6 = val4[4] or BJI.Utils.Style.TEXT_COLORS.DISABLED
        end
    else
        if data.bgLess then
            val4 = BJI.Utils.Style.BTN_PRESETS.TRANSPARENT
            val1, val2, val3 = val4[1], val4[2], val4[3]
            val6 = data.btnStyle and data.btnStyle[1] or BJI.Utils.Style.TEXT_COLORS.DEFAULT
        else
            val4 = data.btnStyle or BJI.Utils.Style.BTN_PRESETS.INFO
            val1, val2, val3 = val4[1], val4[2], val4[3]
            val6 = val4[4] or BJI.Utils.Style.TEXT_COLORS.DEFAULT
        end
    end
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON_HOVERED, val2)
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.BUTTON_ACTIVE, val3)

    val5 = BJI.Utils.UI.GetIconSize(data.big)
    scratchVecA.x, scratchVecA.y = val5, val5

    val3 = BJI_Context.GUI.uiIconImageButton(BJI.Utils.Icon.GetIcon(icon), scratchVecA, val6, nil, val1,
        id, nil, nil, data.onRelease == true)

    if val3 and not data.noSound then
        BJI_Sound.play(data.sound or BJI_Sound.SOUNDS.BIGMAP_HOVER)
    end

    PopStyleColor(2)

    return val3 and not data.disabled
end

local colorPickerBaseFlags = ui_imgui.ColorEditFlags_NoInputs
---@param id string
---@param value vec4
---@param data {disabled: boolean?, flags: integer[]?}?
---@param alpha boolean?
---@return vec4? changed
local CommonColorPicker = function(id, value, data, alpha)
    data = data or EMPTY

    val1 = colorPickerBaseFlags
    if data.disabled then
        val1 = Flags(val1, ui_imgui.ColorEditFlags_NoPicker)
    end

    scratchColor4[0] = value.x
    scratchColor4[1] = value.y
    scratchColor4[2] = value.z
    scratchColor4[3] = alpha and value.w or 1

    val3 = alpha and ui_imgui.ColorEdit4 or ui_imgui.ColorEdit3
    val4 = val3(HiddenId(id), scratchColor4, val1)

    val5 = nil
    if val4 and not data.disabled then
        -- allocated only on an actual edit, never on idle frames
        val5 = ImVec4(scratchColor4[0], scratchColor4[1], scratchColor4[2], alpha and scratchColor4[3] or 1)
    end

    return not math.compareVec4(value, val5) and val5 or nil
end
---@param id string
---@param value vec4
---@param data {disabled: boolean?, flags: integer[]?}?
---@return vec4? changed
ColorPicker = function(id, value, data)
    return CommonColorPicker(id, value, data)
end
---@param id string
---@param value vec4
---@param data {disabled: boolean?, flags: integer[]?}?
---@return vec4? changed
ColorPickerAlpha = function(id, value, data)
    return CommonColorPicker(id, value, data, true)
end

local sliderBaseFlags = ui_imgui.SliderFlags_AlwaysClamp
local floatFormats = {}
---@param id string
---@param value integer
---@param min integer
---@param max integer
---@param data {disabled: boolean?, inputStyle: vec4[]?, width: integer?, formatRender: string?, flags: integer[]?}?
---@return integer? changed
SliderInt = function(id, value, min, max, data)
    data = data or EMPTY

    if data.disabled then
        val1 = BJI.Utils.Style.INPUT_PRESETS.DISABLED
        val6 = val1[2] or BJI.Utils.Style.TEXT_COLORS.DISABLED
    else
        val1 = data.inputStyle or BJI.Utils.Style.INPUT_PRESETS.DEFAULT
        val6 = val1[2] or BJI.Utils.Style.TEXT_COLORS.DEFAULT
    end
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG, val1[1])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR, val6)
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG_HOVERED, val1[3])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG_ACTIVE, val1[4])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.SLIDER_GRAB, val1[5])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.SLIDER_GRAB_ACTIVE, val1[6])

    val7 = data.width or -1
    if val7 < -1 then
        val7 = val7 + GetContentRegionAvail().x
    end
    SetNextItemWidth(val7)

    val3 = sliderBaseFlags
    if data.flags then
        for i = 1, #data.flags do
            val3 = Flags(val3, data.flags[i])
        end
    end
    scratchInt[0] = value
    val4 = ui_imgui.SliderInt(HiddenId(id), scratchInt, min, max, data.formatRender, val3)

    PopStyleColor(6)

    val5 = nil
    if val4 and not data.disabled then
        val5 = scratchInt[0]
    end

    return val5 ~= value and val5 or nil
end

---@param id string
---@param value number
---@param min number
---@param max number
---@param data {disabled: boolean?, inputStyle: vec4[]?, width: integer?, formatRender: string?, flags: integer[]?, precision: integer?}?
---@return number? changed
SliderFloat = function(id, value, min, max, data)
    data = data or EMPTY

    if data.disabled then
        val1 = BJI.Utils.Style.INPUT_PRESETS.DISABLED
        val6 = val1[2] or BJI.Utils.Style.TEXT_COLORS.DISABLED
    else
        val1 = data.inputStyle or BJI.Utils.Style.INPUT_PRESETS.DEFAULT
        val6 = val1[2] or BJI.Utils.Style.TEXT_COLORS.DEFAULT
    end
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG, val1[1])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.TEXT_COLOR, val6)
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG_HOVERED, val1[3])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.FRAME_BG_ACTIVE, val1[4])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.SLIDER_GRAB, val1[5])
    PushStyleColor(BJI.Utils.Style.STYLE_COLS.SLIDER_GRAB_ACTIVE, val1[6])

    val7 = data.width or -1
    if val7 < -1 then
        val7 = val7 + GetContentRegionAvail().x
    end
    SetNextItemWidth(val7)

    val6 = data.formatRender
    if not val6 and data.precision then
        -- per-precision format strings are tiny and few; memoized in a static table
        val6 = floatFormats[data.precision]
        if not val6 then
            val6 = "%." .. data.precision .. "f"
            floatFormats[data.precision] = val6
        end
    end

    val3 = sliderBaseFlags
    if data.flags then
        for i = 1, #data.flags do
            val3 = Flags(val3, data.flags[i])
        end
    end
    scratchFloat[0] = value
    val4 = ui_imgui.SliderFloat(HiddenId(id), scratchFloat, min, max, val6, val3)

    PopStyleColor(6)

    val5 = nil
    if val4 and not data.disabled then
        val5 = math.round(scratchFloat[0], data.precision or 3)
    end

    return val5 ~= value and val5 or nil
end

-- keep track of slider states (switch between slider and number input)
local sliderPrecisionStates = {
    int = {},
    float = {},
}

---@param id string
---@param value integer
---@param min integer
---@param max integer
---@param data {step: integer?, stepFast: integer?, disabled: boolean?, inputStyle: vec4[]?, btnStyle: vec4[]?, width: integer?, formatRender: string?, flags: integer[]?}?
---@return integer? changed
SliderIntPrecision = function(id, value, min, max, data)
    if not sliderPrecisionStates.int[id] then
        val1 = SliderInt(id, value, min, max, data)
        if max - min > 20 then
            TooltipText(BJI_Lang.get("common.precisionInputTooltip"))
            if IsItemClicked(BJI.Utils.Style.MOUSE_BUTTONS.RIGHT) then
                sliderPrecisionStates.int[id] = true
            end
        end
    else
        data = data or {}
        val1 = InputInt(id, value, {
            min = min,
            max = max,
            step = data.step,
            stepFast = data.stepFast,
            disabled = data.disabled,
            width = data.width,
            inputStyle = data.inputStyle,
            btnStyle = data.btnStyle,
        })
        TooltipText(BJI_Lang.get("common.precisionInputTooltip"))
        if IsItemClicked(BJI.Utils.Style.MOUSE_BUTTONS.RIGHT) then
            sliderPrecisionStates.int[id] = nil
        end
    end

    return val1 ~= value and val1 or nil
end

---@param id string
---@param value number
---@param min number
---@param max number
---@param data {step: integer?, stepFast: integer?, disabled: boolean?, inputStyle: vec4[]?, btnStyle: vec4[]?, width: integer?, formatRender: string?, flags: integer[]?, precision: integer?}?
---@return number? changed
SliderFloatPrecision = function(id, value, min, max, data)
    if not sliderPrecisionStates.float[id] then
        val1 = SliderFloat(id, value, min, max, data)
        TooltipText(BJI_Lang.get("common.precisionInputTooltip"))
        if IsItemClicked(BJI.Utils.Style.MOUSE_BUTTONS.RIGHT) then
            sliderPrecisionStates.float[id] = true
        end
    else
        data = data or {}
        val1 = InputFloat(id, value, {
            min = min,
            max = max,
            step = data.step,
            stepFast = data.stepFast,
            disabled = data.disabled,
            width = data.width,
            inputStyle = data.inputStyle,
            btnStyle = data.btnStyle,
            precision = data.precision,
        })
        TooltipText(BJI_Lang.get("common.precisionInputTooltip"))
        if IsItemClicked(BJI.Utils.Style.MOUSE_BUTTONS.RIGHT) then
            sliderPrecisionStates.float[id] = nil
        end
    end

    return val1 ~= value and val1 or nil
end

-- BeamNG 0.39 no longer defines the ImVec2Zero / ImVec2One constants on ui_imgui (they are
-- still referenced by some stock editor scripts, but nothing assigns them anymore), so the UV
-- corners are built once here instead of resolving to nil at every call. Tint/border colors
-- are constant too and were previously rebuilt through ImColorByRGB on every call.
local IMAGE_UV_MIN = ui_imgui.ImVec2(0, 0)
local IMAGE_UV_MAX = ui_imgui.ImVec2(1, 1)
local IMAGE_TINT = ui_imgui.ImColorByRGB(255, 255, 255, 255).Value
local IMAGE_BORDER = ui_imgui.ImColorByRGB(255, 255, 255, 255).Value

---@param texId any
---@param size point
Image = function(texId, size)
    ui_imgui.Image(texId, size, IMAGE_UV_MIN, IMAGE_UV_MAX, IMAGE_TINT, IMAGE_BORDER)
end
