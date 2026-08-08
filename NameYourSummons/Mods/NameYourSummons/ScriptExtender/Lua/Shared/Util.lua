local Util = {}

Util.MAX_NAME_LENGTH = 40

--- Osiris hands back GUIDSTRINGs that are often "SomeName_<uuid>".
--- We only ever want the bare uuid so that our storage keys are stable.
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
	local s = raw:gsub("%c", " ") -- control chars -> space
	s = s:gsub("%s+", " ") -- collapse runs of whitespace
	s = s:gsub("^%s*(.-)%s*$", "%1") -- trim
	if #s > Util.MAX_NAME_LENGTH then
		s = s:sub(1, Util.MAX_NAME_LENGTH)
		s = s:gsub("%s+$", "")
	end
	return s
end

--- Storage key: one saved name per (owner, root template) pair.
--- This is what makes "re-summon keeps its name" work: the summon's own UUID
--- changes every time it is conjured, but the owner and the template do not.
--- Both halves are normalised to a bare uuid so the GUIDSTRING template seen on
--- summon ("S_Wolf_<uuid>") matches the bare-uuid template seen on reapply.
---@param ownerUuid string
---@param rootTemplate string
---@return string
function Util.MakeKey(ownerUuid, rootTemplate)
	return Util.ToUuid(ownerUuid) .. "|" .. Util.ToUuid(rootTemplate)
end

-- Named story creatures the game classifies as summons but that the player
-- should not be prompted to rename (e.g. the intellect devourer "Us"). Keyed by
-- root-template uuid; verify each in game with !nys_diag.
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

--- Assign a set of names to a set of uuids by sorted-uuid order: the i-th uuid
--- (sorted ascending) gets names[i]. Uuids beyond #names are left unassigned
--- (an upcast summoned more creatures than there are saved names). Deterministic
--- and independent of call order, so distributing a unique set converges as the
--- creatures trickle in one by one, without any per-creature identity.
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

--- A localisation handle derived from the text, so the same name always maps to
--- the same handle: reproducible after a save/load, and one handle per name.
---@param text string
---@return string
function Util.LocaHandleFor(text)
	return string.format("hNameYourSummons%08x", Util.Hash32(text))
end

function Util.Log(...)
	Ext.Utils.Print("[NameYourSummons]", ...)
end

function Util.Warn(...)
	Ext.Utils.PrintWarning("[NameYourSummons]", ...)
end

return Util
