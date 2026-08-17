-- SPDX-License-Identifier: MIT
local Util = Ext.Require("Shared/Util.lua")
local Trace = Ext.Require("Shared/Trace.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Writer = Ext.Require("Shared/NameWriter.lua")

local Naming = {}

---@param ref string|EntityHandle
---@return string
function Naming.GetCurrentName(ref)
	local e = Writer.Resolve(ref)
	if not e then
		return ""
	end

	if e.CustomName and e.CustomName.Name and e.CustomName.Name ~= "" then
		return e.CustomName.Name
	end

	local dn = e.DisplayName
	if dn and dn.Name and dn.Name.Handle and dn.Name.Handle.Handle then
		local ok, text = pcall(Ext.Loca.GetTranslatedString, dn.Name.Handle.Handle)
		if ok and type(text) == "string" and text ~= "" then
			return text
		end
	end

	return ""
end

---@param ref string|EntityHandle
---@param name string
---@return boolean success, string|nil err
function Naming.Apply(ref, name)
	local e = Writer.Resolve(ref)
	if not e then
		Trace.Log("naming", "Apply failed: entity not found", { Ref = tostring(ref), Name = name })
		return false, "entity not found"
	end

	name = Util.Sanitise(name)
	if name == "" then
		return false, "empty name"
	end

	local handle = Util.LocaHandleFor(name)

	-- Must come first: an unregistered handle renders as nothing at all.
	if not Writer.RegisterLoca(handle, name) then
		Trace.Log("naming", "Apply failed: loca registration", { Ref = tostring(ref), Handle = handle })
		return false, "could not register localisation handle"
	end

	-- Runtime loca registers at version 0; a stale version makes the lookup miss.
	local ok, err = Writer.SetDisplayName(e, handle, 0, true)
	if not ok then
		Trace.Log("naming", "Apply failed: SetDisplayName", { Ref = tostring(ref), Error = tostring(err) })
		return false, err
	end
	Trace.Log("naming", "Applied name", { Ref = tostring(ref), Name = name, Handle = handle })

	-- Remote peers have their own localisation table and have not seen this handle.
	pcall(function()
		Channels.ApplyName:Broadcast({ Handle = handle, Text = name })
	end)

	local uuid = e.Uuid and tostring(e.Uuid.EntityUuid) or tostring(ref)

	-- A manually-opened Examine panel does not repaint a rename from elsewhere; tell the
	-- client to write the new text into its on-screen field directly.
	pcall(function()
		Channels.SummonRenamed:Broadcast({ SummonUuid = uuid, Name = name })
	end)

	Util.Log(("Named %s '%s'"):format(uuid, name))
	return true
end

--- Apply the name after the entity settles: a summon is still assembling on the
--- tick it enters the level, and an immediate write can be clobbered by the engine.
---@param guid string
---@param name string
---@param delayMs integer|nil
function Naming.ApplyDeferred(guid, name, delayMs)
	Ext.Timer.WaitFor(delayMs or 250, function()
		local ok, err = Naming.Apply(guid, name)
		if not ok then
			Util.Warn(("Could not name %s '%s': %s"):format(tostring(guid), tostring(name), tostring(err)))
		end
	end)
end

--- Point a summon's display name back at its template's original handle. The
--- template handle is a shipped game loca entry, so co-op peers already have it.
---@param ref string|EntityHandle
---@param rootTemplate string
---@return boolean success, string|nil err
function Naming.Restore(ref, rootTemplate)
	local e = Writer.Resolve(ref)
	if not e then
		return false, "entity not found"
	end

	local ok, template = pcall(Ext.Template.GetTemplate, rootTemplate)
	local original = ok and template and template.DisplayName and template.DisplayName.Handle
	if not (original and original.Handle) then
		return false, "template has no display name"
	end

	local restored, err = Writer.SetDisplayName(e, original.Handle, original.Version, true)
	if not restored then
		return false, err
	end

	local uuid = e.Uuid and tostring(e.Uuid.EntityUuid) or tostring(ref)
	Util.Log(("Restored %s to its original name"):format(uuid))
	Trace.Log("naming", "Restored original name", { Summon = uuid, Template = rootTemplate })
	return true
end

--- Re-register every saved name's handle. Runtime loca does not survive a restart,
--- so this runs on session load before any name is re-applied. A stored value is
--- either one name (string) or a unique set (array of names).
---@param names table<string,string|string[]>  key -> name or unique set
function Naming.SeedLoca(names)
	local seeded = {}
	local n = 0
	local function seed(name)
		local handle = Util.LocaHandleFor(name)
		if not seeded[handle] then
			seeded[handle] = name
			Writer.RegisterLoca(handle, name)
			n = n + 1
		end
	end
	for _, value in pairs(names) do
		if type(value) == "table" then
			for _, name in ipairs(value) do
				seed(name)
			end
		else
			seed(value)
		end
	end
	if n > 0 then
		pcall(function()
			Channels.SeedLoca:Broadcast({ Entries = seeded })
		end)
		Util.Log(("Registered %d localisation handle(s) for saved names."):format(n))
	end
end

---@param ref string|EntityHandle
function Naming.Diagnose(ref)
	local e = Writer.Resolve(ref)
	if not e then
		Util.Say("Diagnose: no such entity")
		return
	end

	Util.Say("---- NameYourSummons diagnosis ----")

	local uuid
	if e.Uuid then
		uuid = tostring(e.Uuid.EntityUuid)
		Util.Say("Uuid                     :", uuid)
	end

	if e.DisplayName and e.DisplayName.Name and e.DisplayName.Name.Handle then
		local h = e.DisplayName.Name.Handle.Handle
		Util.Say(
			"DisplayName.Name         :",
			tostring(h),
			"(version " .. tostring(e.DisplayName.Name.Handle.Version) .. ")"
		)
		Util.Say("  resolves to            :", tostring(Ext.Loca.GetTranslatedString(h)))
	end

	if e.CustomName then
		Util.Say("CustomName.Name          :", tostring(e.CustomName.Name))
	end

	if e.OriginalTemplate then
		Util.Say("OriginalTemplate         :", tostring(e.OriginalTemplate.OriginalTemplate))
	end
	if uuid then
		Util.Say("Is summon (Osiris)       :", tostring(Osi.IsSummon(uuid)))
		Util.Say("Owner (Osiris)           :", tostring(Osi.CharacterGetOwner(uuid)))
	end

	Util.Say("-------------------------------")
end

--- The resolved tag names on a summon, for classification. Runtime tags are GUIDs;
--- each resolves to a Tag resource whose Name is the creature type. Unresolvable
--- tags are dropped.
---@param ref string|EntityHandle
---@return string[]
function Naming.TagNamesOf(ref)
	local e = Writer.Resolve(ref)
	local names = {}
	if e and e.Tag and e.Tag.Tags then
		for _, tagGuid in ipairs(e.Tag.Tags) do
			local ok, tag = pcall(Ext.StaticData.Get, tostring(tagGuid), "Tag")
			if ok and tag and tag.Name and tag.Name ~= "" then
				names[#names + 1] = tostring(tag.Name)
			end
		end
	end
	return names
end

--- Every live summon in the session. SummonContainer.Characters is userdata that
--- will not iterate from Lua, so enumerate by the IsSummon marker component.
---@return EntityHandle[]
function Naming.AllSummons()
	local ok, summons = pcall(Ext.Entity.GetAllEntitiesWithComponent, "IsSummon")
	if not ok or not summons then
		Util.Warn("Could not enumerate summons: " .. tostring(summons))
		return {}
	end
	return summons
end

--- The owner uuid of a summon, via Osiris, or nil.
---@param summon EntityHandle
---@return string|nil
function Naming.OwnerOf(summon)
	local uuid = summon.Uuid and tostring(summon.Uuid.EntityUuid)
	if not uuid then
		return nil
	end
	local ownerRaw = Osi.CharacterGetOwner(uuid)
	if not ownerRaw or ownerRaw == "" then
		return nil
	end
	return Util.ToUuid(ownerRaw)
end

--- The root template of a summon, or nil.
---@param summon EntityHandle
---@return string|nil
function Naming.TemplateOf(summon)
	return summon.OriginalTemplate and summon.OriginalTemplate.OriginalTemplate
end

--- Every summon the host currently has out.
---@return EntityHandle[]
function Naming.HostSummons()
	local out = {}
	local ok, host = pcall(Osi.GetHostCharacter)
	if not ok or not host then
		return out
	end
	local hostUuid = Util.ToUuid(host)

	for _, summon in ipairs(Naming.AllSummons()) do
		if Naming.OwnerOf(summon) == hostUuid then
			table.insert(out, summon)
		end
	end
	return out
end

return Naming
