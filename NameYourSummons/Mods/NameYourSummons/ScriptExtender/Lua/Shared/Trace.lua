-- SPDX-License-Identifier: MIT
--[[
    Opt-in JSONL tracing, one file per Lua state (see docs/ingame-debugging.md).
    Two invariants make it safe for crash forensics: every Trace.Log
    flushes the whole buffer to disk immediately (SaveFile has no append), so the
    last line before a crash is on disk; and payloads are sanitised (userdata ->
    tostring, depth/size-capped, cycle-safe) under pcall, so a Trace call never throws.
]]

local Trace = {}

local enabled = false

Trace.MAX_DEPTH = 6
Trace.MAX_TABLE_ENTRIES = 64
-- SaveFile rewrites the whole file per flush, so an unbounded buffer makes late writes slow.
Trace.MAX_LINES = 8000

local buffer = {}
local dropped = 0
local headerLine = nil

local function safeCall(fn, ...)
	local ok, res = pcall(fn, ...)
	if ok then
		return res
	end
	return nil
end

local function stateName()
	return safeCall(Ext.IsServer) == true and "server" or "client"
end

local function traceFileName()
	return "nys-trace-" .. stateName() .. ".jsonl"
end

--- Copy `value` into a plain, cycle-free, depth/size-capped structure Ext.Json.Stringify
--- can always encode (userdata, functions and threads become their tostring form).
---@param value any
---@param depth integer|nil
---@param seen table|nil
---@return any
function Trace.Sanitize(value, depth, seen)
	depth = depth or 0
	local t = type(value)
	if t == "nil" or t == "boolean" or t == "number" or t == "string" then
		return value
	end
	if t ~= "table" then
		return "<" .. t .. ": " .. tostring(safeCall(tostring, value) or "?") .. ">"
	end
	if depth >= Trace.MAX_DEPTH then
		return "<table: depth capped>"
	end
	seen = seen or {}
	if seen[value] then
		return "<table: cycle>"
	end
	seen[value] = true
	local out = {}
	local n = 0
	for k, v in pairs(value) do
		n = n + 1
		if n > Trace.MAX_TABLE_ENTRIES then
			out["..."] = "entries capped"
			break
		end
		local key = (type(k) == "string" or type(k) == "number") and k or (safeCall(tostring, k) or "<key>")
		out[key] = Trace.Sanitize(v, depth + 1, seen)
	end
	seen[value] = nil
	return out
end

--- Build the entry table for one trace line (time fields fail soft to 0/"").
---@param cat string
---@param msg string
---@param data any
---@return table
function Trace.EntryFor(cat, msg, data)
	local entry = {
		t = safeCall(Ext.Utils.MonotonicTime) or 0,
		clock = safeCall(Ext.Timer.ClockTime) or "",
		state = stateName(),
		cat = tostring(cat),
		msg = tostring(msg),
	}
	if data ~= nil then
		entry.data = Trace.Sanitize(data)
	end
	return entry
end

local function encode(entry)
	local ok, line = pcall(function()
		return Ext.Json.Stringify(entry, { Beautify = false })
	end)
	if ok and type(line) == "string" then
		return line
	end
	return string.format('{"cat":"trace","msg":"encode failed","error":%q}', tostring(line))
end

local function flush()
	local parts = { headerLine or "" }
	for i = 1, #buffer do
		parts[#parts + 1] = buffer[i]
	end
	pcall(function()
		Ext.IO.SaveFile(traceFileName(), table.concat(parts, "\n") .. "\n")
	end)
end

--- Never throws; no-op while off.
---@param cat string  short category ("lifecycle", "channel", "watcher", ...)
---@param msg string
---@param data any|nil  payload; sanitised, so any value is safe to pass
function Trace.Log(cat, msg, data)
	if not enabled then
		return
	end
	-- Guard everything: Sanitize runs tostring on payload keys, which a hostile __tostring throws.
	pcall(function()
		buffer[#buffer + 1] = encode(Trace.EntryFor(cat, msg, data))
		while #buffer > Trace.MAX_LINES do
			table.remove(buffer, 1)
			dropped = dropped + 1
		end
		if dropped > 0 then
			headerLine = encode(Trace.EntryFor("trace", "header", { DroppedOldestLines = dropped }))
		end
		flush()
	end)
end

---@return boolean
function Trace.Enabled()
	return enabled
end

---@param on boolean
function Trace.SetEnabled(on)
	enabled = on == true
end

--- Call once per bootstrap. A console `reset` reruns it, so one trace file spans one
--- Lua-state lifetime.
function Trace.Register()
	buffer = {}
	dropped = 0
	headerLine = encode(Trace.EntryFor("trace", "header", { ModuleUUID = ModuleUUID }))
	if enabled then
		flush()
	end
	pcall(function()
		Ext.RegisterConsoleCommand("nys_trace", function()
			Trace.SetEnabled(not enabled)
			safeCall(function()
				Ext.Utils.Print("[NameYourSummons] tracing", enabled and "ON" or "OFF", "->", traceFileName())
			end)
			if enabled then
				flush()
			end
		end)
	end)
end

return Trace
