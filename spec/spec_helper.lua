-- SPDX-License-Identifier: MIT
-- Loaded once by spec/run.lua before any spec.
--
-- BG3SE injects `Ext`, `Osi`, and `ModuleUUID` as globals and loads modules via
-- `Ext.Require`. None of that exists off-game, so we stand up a minimal stub:
-- enough for the engine-independent modules to load and for individual specs to
-- override the exact call they are testing (e.g. Ext.Loca.UpdateTranslatedString).

local LUA_ROOT = "./NameYourSummons/Mods/NameYourSummons/ScriptExtender/Lua/"

_G.ModuleUUID = "00000000-0000-0000-0000-000000000000"

-- Ext.Require caches on the real thing; mirror that so a module and its
-- dependencies resolve to a single instance within a test run.
local requireCache = {}
local function extRequire(relPath)
	if requireCache[relPath] == nil then
		local chunk = assert(loadfile(LUA_ROOT .. relPath))
		requireCache[relPath] = chunk() or true
	end
	return requireCache[relPath]
end

_G.Ext = {
	Require = extRequire,
	Utils = {
		Print = function() end,
		PrintWarning = function() end,
	},
	Loca = {
		UpdateTranslatedString = function()
			return true
		end,
		GetTranslatedString = function()
			return ""
		end,
	},
	Entity = {
		Get = function()
			return nil
		end,
		GetAllEntitiesWithComponent = function()
			return {}
		end,
	},
	Vars = {
		RegisterModVariable = function() end,
		GetModVariables = function()
			return {}
		end,
	},
	Net = {
		CreateChannel = function()
			return {
				SetHandler = function() end,
				SendToServer = function() end,
				SendToClient = function() end,
			}
		end,
	},
	Timer = {
		WaitFor = function() end,
		WaitForRealtime = function() end,
		ClockTime = function()
			return "1970-01-01 00:00:00.000"
		end,
	},
	Events = setmetatable({}, {
		__index = function()
			return { Subscribe = function() end }
		end,
	}),
	Osiris = { RegisterListener = function() end },
	Mod = {
		-- Mirrors SE's ModVersion array shape: {major, minor, revision, build}.
		GetMod = function()
			return { Info = { ModVersion = { 1, 2, 3, 0 } } }
		end,
	},
	RegisterConsoleCommand = function() end,
	IsServer = function()
		return false
	end,
	IO = {
		SaveFile = function()
			return true
		end,
		LoadFile = function()
			return nil
		end,
	},
	Json = {
		-- A shape-preserving stand-in: specs assert on decoded entries via
		-- Trace.EntryFor, not on real JSON text.
		Stringify = function(data)
			return "<json:" .. tostring(data) .. ">"
		end,
	},
}

_G.Osi = setmetatable({}, {
	__index = function()
		return function() end
	end,
})
