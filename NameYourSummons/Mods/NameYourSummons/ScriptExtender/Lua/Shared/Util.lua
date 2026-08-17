-- SPDX-License-Identifier: MIT
local Util = {}

Util.MAX_NAME_LENGTH = 40

--- Extract the bare, lowercased uuid from a GUIDSTRING ("SomeName_<uuid>").
---@param guidstring string|nil
---@return string|nil
function Util.ToUuid(guidstring)
	if type(guidstring) ~= "string" then
		return nil
	end
	local uuid = string.match(guidstring, "(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)$")
	return uuid and string.lower(uuid) or string.lower(guidstring)
end

--- Trim, collapse whitespace, strip control characters, clamp length.
---@param raw any
---@return string
function Util.Sanitise(raw)
	if type(raw) ~= "string" then
		return ""
	end
	local s = raw:gsub("%c", " ")
	s = s:gsub("%s+", " ")
	s = s:gsub("^%s*(.-)%s*$", "%1")
	if #s > Util.MAX_NAME_LENGTH then
		s = s:sub(1, Util.MAX_NAME_LENGTH)
		s = s:gsub("%s+$", "")
	end
	return s
end

--- Storage key "<owner>|<template>", both normalised to bare uuids. Stable across
--- re-summons: the summon's own uuid changes each conjure, owner and template do not.
---@param ownerUuid string
---@param rootTemplate string
---@return string
function Util.MakeKey(ownerUuid, rootTemplate)
	return Util.ToUuid(ownerUuid) .. "|" .. Util.ToUuid(rootTemplate)
end

--- Whether a saved name is visible to the viewing player: its owner is currently
--- controlled by the same user. A nil viewer shows all (never an empty list); an
--- owner with no resolvable user (not loaded) is shown only to the host.
---@param ownerUser integer|nil  the UserID reserving the summon's owner
---@param viewerUser integer|nil  the UserID viewing the settings panel
---@param hostUser integer|nil  the host's UserID
---@return boolean
function Util.IsNameVisible(ownerUser, viewerUser, hostUser)
	if viewerUser == nil then
		return true
	end
	if ownerUser == nil then
		return viewerUser == hostUser
	end
	return ownerUser == viewerUser
end

-- Story creatures the game classifies as summons but should not be prompted to
-- rename (e.g. "Us"). Keyed by root-template uuid; verify each with !nys_diag.
local STORY_SUMMON_TEMPLATES = {
	["27b9089b-9aef-44e9-aaf7-100e3e320823"] = true, -- Us
	["b5deaa14-03b5-41c6-8372-7a9d758b4dfb"] = true, -- Scratch (familiar)
	["000c1be8-615a-4324-b59d-1f0f5637df36"] = true, -- Shovel
	["ffb05cca-cf38-4586-981f-7dca89092ff5"] = true, -- Owlbear Cub (combat)
	["c66b2865-6613-4372-b97a-e330c1d75d09"] = true, -- Owlbear Cub (primary)
}

--- Whether a root template is one of the story-bound summons above.
---@param rootTemplate string|nil
---@return boolean
function Util.IsStorySummon(rootTemplate)
	return STORY_SUMMON_TEMPLATES[Util.ToUuid(rootTemplate)] == true
end

--- Assign names to uuids by sorted-uuid order: the i-th uuid (ascending) gets
--- names[i]. Uuids beyond #names are left unassigned. Deterministic regardless of
--- call order, so it converges as a unique set's creatures trickle in one by one.
---@param uuids string[]
---@param names string[]
---@return table<string,string>  uuid -> name
function Util.AssignByOrder(uuids, names)
	local sorted = {}
	for _, uuid in ipairs(uuids) do
		sorted[#sorted + 1] = uuid
	end
	table.sort(sorted)
	local out = {}
	for i, uuid in ipairs(sorted) do
		if names[i] ~= nil then
			out[uuid] = names[i]
		end
	end
	return out
end

-- A bare or trailing uuid, matching Util.ToUuid's accepted shape.
local UUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

--- Validate a client "rename this summon" request: a uuid-shaped SummonUuid and a
--- name non-empty after sanitising. The caller still confirms Osi.IsSummon.
---@param payload any
---@return boolean
function Util.IsRenameRequestValid(payload)
	if type(payload) ~= "table" then
		return false
	end
	if type(payload.SummonUuid) ~= "string" or not payload.SummonUuid:match(UUID_PATTERN) then
		return false
	end
	return Util.Sanitise(payload.Name) ~= ""
end

--- FNV-1a, 32 bit.
---@param s string
---@return integer
function Util.Hash32(s)
	local h = 2166136261
	for i = 1, #s do
		h = h ~ s:byte(i)
		h = (h * 16777619) & 0xFFFFFFFF
	end
	return h
end

--- A localisation handle derived from the text, so the same name maps to the same
--- handle: reproducible after a save/load, one handle per name.
---@param text string
---@return string
function Util.LocaHandleFor(text)
	return string.format("hNameYourSummons%08x", Util.Hash32(text))
end

-- Off by default: Util.Log stays silent unless `!nys_debug` turns it on (issue #106). Warn and Say are never gated.
local debugEnabled = false

---@param on boolean
function Util.SetDebug(on)
	debugEnabled = on == true
end

---@return boolean
function Util.DebugEnabled()
	return debugEnabled
end

-- Prefixed with a sub-second wall clock so pasted debug logs show event timing.
function Util.Log(...)
	if debugEnabled then
		Ext.Utils.Print(Ext.Timer.ClockTime(), "[NameYourSummons]", ...)
	end
end

-- Ungated: the startup line and user-invoked console-command output.
function Util.Say(...)
	Ext.Utils.Print("[NameYourSummons]", ...)
end

function Util.Warn(...)
	Ext.Utils.PrintWarning(Ext.Timer.ClockTime(), "[NameYourSummons]", ...)
end

--- The installed mod version as "major.minor.revision", or "unknown" if unreadable. Fails soft:
--- the ModVersion shape varies across SE builds, so read it under pcall.
---@return string
function Util.VersionString()
	local ok, version = pcall(function()
		local mod = Ext.Mod.GetMod(ModuleUUID)
		local v = mod.Info.ModVersion
		return string.format("%d.%d.%d", v[1], v[2], v[3])
	end)
	return (ok and type(version) == "string") and version or "unknown"
end

--- Register a UI viewmodel type only if it is not already registered. The UI type registry is
--- process-global and survives the Lua VM resets that happen on every context switch / reload, so
--- re-registering makes SE warn "Registering type X when it already exists". GetTypeInfo returns nil
--- for an unregistered type. Fails safe: if the check is unavailable it registers as before.
---@param name string
---@param props table
function Util.RegisterUiTypeOnce(name, props)
	local ok, info = pcall(function()
		return Ext.Types.GetTypeInfo(name)
	end)
	if ok and info ~= nil then
		return
	end
	pcall(function()
		Ext.UI.RegisterType(name, props)
	end)
end

return Util
