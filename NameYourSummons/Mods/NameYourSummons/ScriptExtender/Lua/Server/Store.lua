local Classifier = Ext.Require("Shared/SummonClassifier.lua")

local Store = {}

local VAR_NAMES = "SummonNames"
local VAR_SETTINGS = "Settings"
local VAR_SKIPPED = "SkippedSummons"

--- How a spell that summons several creatures of the same type at once is
--- handled. All such creatures share one storage key, so the mode decides
--- whether they share a name, each get their own, or are left unnamed.
local MULTI_SUMMON_MODES = {
	skip = true, -- do not prompt for multi-summons; leave their original names
	shared = true, -- one prompt, applied to every creature in the group
	unique = true, -- a separate prompt per creature
}

local DEFAULT_SETTINGS = {
	PromptOnSummon = true, -- pop the naming window the first time a summon appears
	PromptForNamed = false, -- also re-prompt for summons that already have a saved name
	ApplyToExisting = true, -- re-apply saved names to summons already alive on load
	PauseOnPrompt = true, -- freeze the world (solo turn-based mode) while the prompt is up
	AllowStorySummons = false, -- prompt to rename story-bound summons (e.g. "Us"); off = leave them alone
	MultiSummonMode = "skip", -- skip | shared | unique (see MULTI_SUMMON_MODES)
}

local function isBoolean(value)
	return type(value) == "boolean"
end

--- The settings a client is allowed to change from the in-game config, each
--- mapped to a validator for the incoming value.
local WRITABLE_SETTINGS = {
	PromptOnSummon = isBoolean,
	PromptForNamed = isBoolean,
	AllowStorySummons = isBoolean,
	MultiSummonMode = function(value)
		return MULTI_SUMMON_MODES[value] == true
	end,
}

-- Per-summon-type toggles (GH #14): one boolean per creature type plus the
-- "every summon" master. All client-writable; only familiars default on.
for key, def in pairs(Classifier.DefaultSettings()) do
	DEFAULT_SETTINGS[key] = def
	WRITABLE_SETTINGS[key] = isBoolean
end

--- Must be called from BootstrapServer.lua (before a savegame is loaded)
--- and mirrored in BootstrapClient.lua.
function Store.Register()
	Ext.Vars.RegisterModVariable(ModuleUUID, VAR_NAMES, {
		Server = true,
		Client = false,
		WriteableOnServer = true,
		Persistent = true,
		SyncToClient = false,
	})
	Ext.Vars.RegisterModVariable(ModuleUUID, VAR_SETTINGS, {
		Server = true,
		Client = false,
		WriteableOnServer = true,
		Persistent = true,
		SyncToClient = false,
	})
	Ext.Vars.RegisterModVariable(ModuleUUID, VAR_SKIPPED, {
		Server = true,
		Client = false,
		WriteableOnServer = true,
		Persistent = true,
		SyncToClient = false,
	})
end

local function vars()
	return Ext.Vars.GetModVariables(ModuleUUID)
end

---------------------------------------------------------------------------
-- Names
---------------------------------------------------------------------------

---@return table<string,string>
function Store.All()
	return vars()[VAR_NAMES] or {}
end

---@param key string
---@return string|nil
function Store.Get(key)
	return Store.All()[key]
end

---@param key string
---@param name string
function Store.Set(key, name)
	local v = vars()
	local t = v[VAR_NAMES] or {}
	t[key] = name
	-- Reassigning marks the ModVar dirty; mutating the nested table would not.
	v[VAR_NAMES] = t
	-- A name and an always-skip are mutually exclusive; naming clears the skip.
	Store.Unskip(key)
end

---@param key string
function Store.Forget(key)
	local v = vars()
	local t = v[VAR_NAMES] or {}
	t[key] = nil
	v[VAR_NAMES] = t
end

---------------------------------------------------------------------------
-- Unique sets
--
-- A key's value is EITHER a string (one shared name) OR an array of strings
-- (one distinct name per creature, for the "unique" multi-summon mode). The
-- array is always kept dense: a sparse Lua table would serialise to a JSON
-- object and break the `#value` length checks the distribution relies on.
---------------------------------------------------------------------------

--- Coerce a key's stored value into an array of names (empty if unset/string).
---@param value string|string[]|nil
---@return string[]
local function asList(value)
	if type(value) == "table" then
		return value
	end
	if type(value) == "string" then
		return { value }
	end
	return {}
end

--- Append a name to a key's unique set. Skipped keys are never resurrected.
---@param key string
---@param name string
function Store.AppendUnique(key, name)
	if Store.IsSkipped(key) then
		return
	end
	local v = vars()
	local t = v[VAR_NAMES] or {}
	local list = asList(t[key])
	list[#list + 1] = name
	t[key] = list
	v[VAR_NAMES] = t
end

--- Replace a key's unique set with a dense array of names, seeding one that does
--- not exist yet (unlike SetSlot). Clears any always-skip, like Store.Set.
---@param key string
---@param list string[]
function Store.SetUnique(key, list)
	local v = vars()
	local t = v[VAR_NAMES] or {}
	t[key] = list
	v[VAR_NAMES] = t
	-- A name and an always-skip are mutually exclusive; naming clears the skip.
	Store.Unskip(key)
end

--- Overwrite one entry of a key's unique set. Out-of-range slots are ignored.
---@param key string
---@param slot integer
---@param name string
function Store.SetSlot(key, slot, name)
	if Store.IsSkipped(key) then
		return
	end
	local v = vars()
	local t = v[VAR_NAMES] or {}
	local list = asList(t[key])
	if slot < 1 or slot > #list then
		return
	end
	list[slot] = name
	t[key] = list
	v[VAR_NAMES] = t
end

--- Remove one entry from a key's unique set, compacting the array. When the
--- last entry goes, the key is forgotten entirely.
---@param key string
---@param slot integer
function Store.ForgetSlot(key, slot)
	local v = vars()
	local t = v[VAR_NAMES] or {}
	local list = asList(t[key])
	if slot < 1 or slot > #list then
		return
	end
	table.remove(list, slot)
	if #list == 0 then
		t[key] = nil
	else
		t[key] = list
	end
	v[VAR_NAMES] = t
end

---------------------------------------------------------------------------
-- Always-skip
--
-- Keys the player has chosen never to be prompted about. Stored as a set
-- (key -> true) alongside the names, and mutually exclusive with them: a
-- saved name clears the skip, and skipping clears any saved name.
---------------------------------------------------------------------------

---@return table<string,boolean>
function Store.AllSkipped()
	return vars()[VAR_SKIPPED] or {}
end

---@param key string
---@return boolean
function Store.IsSkipped(key)
	return Store.AllSkipped()[key] == true
end

---@param key string
function Store.Skip(key)
	local v = vars()
	local t = v[VAR_SKIPPED] or {}
	t[key] = true
	-- Reassigning marks the ModVar dirty; mutating the nested table would not.
	v[VAR_SKIPPED] = t
	-- A name and an always-skip are mutually exclusive; skipping clears the name.
	Store.Forget(key)
end

---@param key string
function Store.Unskip(key)
	local v = vars()
	local t = v[VAR_SKIPPED] or {}
	t[key] = nil
	v[VAR_SKIPPED] = t
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

---@return table
function Store.Settings()
	local s = vars()[VAR_SETTINGS] or {}
	local out = {}
	for k, def in pairs(DEFAULT_SETTINGS) do
		if s[k] == nil then
			out[k] = def
		else
			out[k] = s[k]
		end
	end
	return out
end

--- Persist a single setting. Only whitelisted keys are honoured, and each is
--- validated, so a client cannot write arbitrary fields or types into the ModVar.
---@param key string
---@param value boolean|string
---@return boolean persisted
function Store.SetSetting(key, value)
	local validate = WRITABLE_SETTINGS[key]
	if not validate or not validate(value) then
		return false
	end
	local v = vars()
	local t = v[VAR_SETTINGS] or {}
	t[key] = value
	-- Reassigning marks the ModVar dirty; mutating the nested table would not.
	v[VAR_SETTINGS] = t
	return true
end

return Store
