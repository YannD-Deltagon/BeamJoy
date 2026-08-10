local M = {
    dependencies = { "beamjoy_communications" },

    defaultColor = { 1, 1, 1 },

    ready = false,
    ---@type tablelib<integer, any[]> index 1-N, value printMessage args list
    queue = Table(),

}

-- BeamMP 4.22.1 (BeamNG 0.39) replaced its HTML chat with an imgui window and relocated the
-- module from "multiplayer/ui/chat" to "beammp/ui/chat". The old integration pushed rich
-- colored segments straight into the private chatMessages model; the new module's documented
-- external access point is beammp_ui_chat.addMessage(username, message, id, color), whose
-- message string carries BeamMP caret color codes (^0-^f) parsed into colored segments.
-- Resolution is lazy and protected so a missing module (older BeamMP) degrades to the HTML
-- chat only instead of erroring on every message.
local mpChatModule
---@return table? chat module exposing addMessage(username, message, id, color)
local function getMPChat()
    if mpChatModule == nil then
        local ok, mod = pcall(require, "beammp.ui.chat")
        mpChatModule = (ok and type(mod) == "table") and mod or false
    end
    return mpChatModule or nil
end

-- BeamMP caret color palette (chat.lua colorCodes), used to quantize the mod's RGB colors
local CARET_COLORS = {
    ["0"] = { 0, 0, 0 }, ["1"] = { 0, 0, .667 }, ["2"] = { 0, .667, 0 }, ["3"] = { 0, .667, .667 },
    ["4"] = { .667, 0, 0 }, ["5"] = { .667, 0, .667 }, ["6"] = { 1, .667, 0 }, ["7"] = { .667, .667, .667 },
    ["8"] = { .333, .333, .333 }, ["9"] = { .333, .333, 1 }, ["a"] = { .333, 1, .333 }, ["b"] = { .333, 1, 1 },
    ["c"] = { 1, .333, .333 }, ["d"] = { 1, .333, 1 }, ["e"] = { 1, 1, .333 }, ["f"] = { 1, 1, 1 },
}
---@param rgb number[]? index 1-3, value 0-1
---@return string caret code ("^X")
local function nearestCaretCode(rgb)
    if not rgb then return "^f" end
    local best, bestDist = "f", math.huge
    for code, c in pairs(CARET_COLORS) do
        local d = (c[1] - (rgb[1] or 1)) ^ 2 + (c[2] - (rgb[2] or 1)) ^ 2 + (c[3] - (rgb[3] or 1)) ^ 2
        if d < bestDist then
            best, bestDist = code, d
        end
    end
    return "^" .. best
end

-- transparent username color: with color set, the renderer prints the (empty) username
-- without the ": " suffix, giving full control over the message content
local TRANSPARENT = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }

---@param payload {sender: {text: string, color: number[], tag: string?, tagColor: number[]}?, message: {text: string, color: number[]}}
local function addImguiMessage(payload)
    local mpChat = getMPChat()
    if not mpChat or not mpChat.addMessage then return end

    local str = ""
    if payload.sender then
        local defaultCode = nearestCaretCode(M.defaultColor)
        if payload.sender.tag then
            str = str .. defaultCode .. "[" .. nearestCaretCode(payload.sender.tagColor) ..
                payload.sender.tag .. defaultCode .. "]"
        end
        str = str .. nearestCaretCode(payload.sender.color) .. payload.sender.text .. ": "
    end
    str = str .. nearestCaretCode(payload.message.color) .. payload.message.text

    -- addMessage also handles show-on-message focus and the unread counter internally.
    -- username MUST be "Server": it is the only value routed through the color-preserving
    -- formatTextWithColor(nocolor=false) path - any other username strips every caret code
    -- to white (BeamMP chat.lua:244-249). The transparent color makes the "Server" prefix
    -- itself invisible.
    mpChat.addMessage("Server", str, nil, TRANSPARENT)
end

---@param senderName string?
---@param message string
---@param nameColor number[]? index 1-3, value 0-1
---@param textColor number[] index 1-3, value 0-1
---@param tag string?
local function printMessage(senderName, message, nameColor, textColor, tag)
    nameColor = nameColor or M.defaultColor
    textColor = textColor or M.defaultColor
    local payload = {
        sender = senderName and {
            text = senderName,
            color = nameColor,
            tag = tag,
            tagColor = beamjoy_config.data.Chat.ServerNameColor,
        } or nil,
        message = {
            text = message,
            color = textColor,
        }
    }
    beamjoy_communications_ui.send("BJChat", jsonEncode(payload))
    addImguiMessage(payload)
end

---@param message string
---@param color number[]
local function directChat(message, color)
    M.queue:insert({ nil, message, nil, color })
end

---@param senderName string
---@param message string
local function chatMessage(senderName, message)
    if not beamjoy_config.data.Chat then
        return async.task(function()
            return beamjoy_config.data.Chat ~= nil
        end, function()
            chatMessage(senderName, message)
        end)
    end

    local sender = beamjoy_players.players[senderName]
    if not sender then return end
    local group = beamjoy_groups.getGroup(sender.group)
    if not group then return end
    local tag
    if beamjoy_config.data.Chat.ShowStaffTag and group.staff then
        tag = beamjoy_lang.translate("beamjoy.groups.staffMark")
    end
    M.queue:insert({ senderName, message, group.nameColor, group.textColor, tag })
end

---@param key string
---@param args table?
local function serverMessage(key, args)
    if not beamjoy_config.data.Chat then
        return async.task(function()
            return beamjoy_config.data.Chat ~= nil
        end, function()
            serverMessage(key, args)
        end)
    end

    local nameColor = beamjoy_config.data.Chat.ServerNameColor
    local textColor = beamjoy_config.data.Chat.ServerTextColor
    local message = string.var(beamjoy_lang.translate(key),
        table.map(args or {}, function(v)
            return beamjoy_lang.translate(v)
        end))
    M.queue:insert({ beamjoy_lang.translate("beamjoy.chat.senderServer"),
        message, nameColor, textColor })
end

---@param key string
---@param args table?
local function chatEvent(key, args)
    if not beamjoy_config.data.Chat then
        return async.task(function()
            return beamjoy_config.data.Chat ~= nil
        end, function()
            chatEvent(key, args)
        end)
    end

    local message = string.var(beamjoy_lang.translate(key),
        table.map(args or {}, function(v)
            return beamjoy_lang.translate(v)
        end))
    M.queue:insert({ nil, message, nil, beamjoy_config.data.Chat.EventColor })
end

local function onInit()
    beamjoy_communications.addHandler("chat", M.directChat)
    beamjoy_communications.addHandler("chatMessage", chatMessage)
    beamjoy_communications.addHandler("serverMessage", serverMessage)
    beamjoy_communications.addHandler("chatEvent", chatEvent)

    beamjoy_communications.addHandler("sendCache", M.retrieveCache)
    beamjoy_communications_ui.addHandler("BJRequestChatData", M.sendChatDataToUI)
end

local function onBJClientReady()
    M.ready = true
end

local function onUpdate(ctxt)
    if M.ready and M.queue[1] then
        printMessage(table.unpack(M.queue[1], 1, 20))
        table.remove(M.queue, 1)
    end
end

local function retrieveCache(caches)
    if caches.config then
        async.delayTask(M.sendChatDataToUI, 0)
    end
end

local function sendChatDataToUI()
    ---@type table
    local payload = table.clone(beamjoy_config.data.Chat)
    payload.ServerNameColor = BJColor():fromArray(payload.ServerNameColor)
    payload.ServerTextColor = BJColor():fromArray(payload.ServerTextColor)
    payload.EventColor = BJColor():fromArray(payload.EventColor)
    payload.BroadcastColor = BJColor():fromArray(payload.BroadcastColor)
    table.forEach(beamjoy_lang.langs, function(lang)
        if not payload.WelcomeMessage[lang] then
            payload.WelcomeMessage[lang] = ""
        end
    end)
    beamjoy_communications_ui.send("BJSendChatData", payload)
end

M.onInit = onInit
M.onBJClientReady = onBJClientReady
M.onUpdate = onUpdate

M.directChat = directChat
M.sendChatDataToUI = sendChatDataToUI
M.retrieveCache = retrieveCache

return M
