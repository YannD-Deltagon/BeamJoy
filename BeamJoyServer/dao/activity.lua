local M = {
    dependencies = { "dao_main" },
    path = "activities",
}

local function onInit()
    dao_main.ensureInit() -- dbPath is lazily computed; onInit fan-out order is unspecified
    if not FS.Exists(dao_main.dbPath .. "/" .. M.path) then
        FS.CreateDirectory(dao_main.dbPath .. "/" .. M.path)
    end
end

-- one subdirectory per map: the previous "<map>_<type>.json" concatenation was ambiguous
-- for map names containing underscores (nearly all of them, e.g. gridmap_v2)
---@param mapName string
---@param activityType string
---@return string
local function filePath(mapName, activityType)
    local dir = dao_main.dbPath .. "/" .. M.path .. "/" .. mapName
    if not FS.Exists(dir) then
        FS.CreateDirectory(dir)
    end
    return M.path .. "/" .. mapName .. "/" .. activityType .. ".json"
end

---@param mapName string
---@param activityType string
---@return table?
local function get(mapName, activityType)
    return dao_main.get(filePath(mapName, activityType))
end

---@param mapName string
---@param activityType string
---@param data table?
local function save(mapName, activityType, data)
    local finalData = data and table.filter(data,
        function(v) return type(v) ~= "function" end) or nil
    return dao_main.save(filePath(mapName, activityType), finalData)
end

M.onInit = onInit

M.get = get
M.save = save

return M
