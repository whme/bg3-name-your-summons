local Classifier = Ext.Require("Shared/SummonClassifier.lua")

local Store = {}

local VAR_NAMES = "SummonNames"
local VAR_SETTINGS = "Settings"
local VAR_SKIPPED = "SkippedSummons"

local DEFAULT_SETTINGS = {
	PromptOnSummon = true, -- pop the naming window the first time a summon appears
	PromptForNamed = false, -- also re-prompt for summons that already have a saved name
	ApplyToExisting = true, -- re-apply saved names to summons already alive on load
	PauseOnPrompt = true, -- freeze the world (solo turn-based mode) while the prompt is up
	AllowStorySummons = false, -- prompt to rename story-bound summons (e.g. "Us"); off = leave them alone
}

--- The settings a client is allowed to change from the in-game config.
local WRITABLE_SETTINGS = {
	PromptOnSummon = true,
	PromptForNamed = true,
	AllowStorySummons = true,
}

-- Per-summon-type toggles (GH #14): one boolean per creature type plus the
-- "every summon" master. All client-writable; only familiars default on.
for key, def in pairs(Classifier.DefaultSettings()) do
	DEFAULT_SETTINGS[key] = def
	WRITABLE_SETTINGS[key] = true
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

--- Persist a single setting. Only whitelisted keys are honoured, so a client
--- cannot write arbitrary fields into the ModVar.
---@param key string
---@param value boolean
---@return boolean persisted
function Store.SetSetting(key, value)
	if not WRITABLE_SETTINGS[key] or type(value) ~= "boolean" then
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
