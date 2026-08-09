-- SPDX-License-Identifier: MIT
--[[
    The renaming primitive, shared by the server and client Lua states. A
    creature's name comes from DisplayName.Name, a localisation handle rather
    than text, so renaming is two writes: register the text under a handle of our
    own, then point Name at it. See the README for why the handle must be ours.
]]

local Util = Ext.Require("Shared/Util.lua")

local Writer = {}

---@param ref string|EntityHandle
---@return EntityHandle|nil
function Writer.Resolve(ref)
	if ref == nil then
		return nil
	end
	local e = ref
	if type(ref) == "string" then
		local found
		found, e = pcall(Ext.Entity.Get, ref)
		if not found or e == nil then
			return nil
		end
	end
	local ok, alive = pcall(function()
		return e:IsAlive()
	end)
	return (ok and alive) and e or nil
end

--- Adds `text` to the runtime localisation table under `handle`.
---@param handle string
---@param text string
---@return boolean
function Writer.RegisterLoca(handle, text)
	local ok, res = pcall(Ext.Loca.UpdateTranslatedString, handle, text)
	if not ok then
		Util.Warn("UpdateTranslatedString failed: " .. tostring(res))
		return false
	end
	return res ~= false
end

--- Points the entity's display name at `handle` at localisation `version`.
---@param e EntityHandle
---@param handle string  a handle already registered via RegisterLoca
---@param version integer  0 for our runtime loca; a template handle keeps its own
---@param replicate boolean  true on the server, false on a client
---@return boolean ok, string|nil err
function Writer.SetDisplayName(e, handle, version, replicate)
	local dn = e.DisplayName
	if dn == nil then
		return false, "no DisplayName component"
	end
	if dn.Name == nil or dn.Name.Handle == nil then
		return false, "no Name"
	end

	-- Skip when unchanged: reapply on re-summon and on load would otherwise
	-- rewrite and re-replicate a DisplayName that already holds this name.
	if dn.Name.Handle.Handle == handle and dn.Name.Handle.Version == version then
		return true
	end

	local ok, err = pcall(function()
		dn.Name.Handle.Handle = handle
		dn.Name.Handle.Version = version
	end)
	if not ok then
		return false, tostring(err)
	end

	if replicate then
		pcall(function()
			e:Replicate("DisplayName")
		end)
	end
	pcall(function()
		e:MarkChanged("DisplayName")
	end)

	return true
end

return Writer
