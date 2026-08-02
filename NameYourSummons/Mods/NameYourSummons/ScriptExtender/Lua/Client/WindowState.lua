--[[
    Client-side persistence of ImGui window geometry (position and size).

    The windows deliberately keep NoSavedSettings = true so BG3SE never persists
    their open/visible state - a window must NEVER reappear on its own just
    because it happened to be open when the game closed (the game state was not
    even saved). Geometry is the only thing worth remembering, so we persist just
    that ourselves to a mod-local file that survives saves, reloads and restarts.
    Open-state is never touched.
]]

local WindowState = {}

local FILE = "NameYourSummons/window_layout.json"

-- Lazily loaded: key -> { pos = { x, y }, size = { w, h } }.
local cache

local function load()
	if cache then
		return cache
	end
	cache = {}
	local ok, raw = pcall(Ext.IO.LoadFile, FILE)
	if ok and type(raw) == "string" and raw ~= "" then
		local parsedOk, parsed = pcall(Ext.Json.Parse, raw)
		if parsedOk and type(parsed) == "table" then
			cache = parsed
		end
	end
	return cache
end

local function persist()
	local ok, str = pcall(Ext.Json.Stringify, cache or {})
	if ok and type(str) == "string" then
		pcall(Ext.IO.SaveFile, FILE, str)
	end
end

--- The saved geometry for `key`, or nil if none is stored.
---@param key string
---@return table|nil
function WindowState.Get(key)
	return load()[key]
end

--- Store geometry for `key` and write it to disk.
---@param key string
---@param pos number[]
---@param size number[]
function WindowState.Set(key, pos, size)
	load()[key] = { pos = { pos[1], pos[2] }, size = { size[1], size[2] } }
	persist()
end

--- Forget geometry for `key` (the reset button).
---@param key string
function WindowState.Clear(key)
	load()[key] = nil
	persist()
end

return WindowState
