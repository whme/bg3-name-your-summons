local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Store = Ext.Require("Server/Store.lua")
local Naming = Ext.Require("Server/Naming.lua")

local Watcher = {}

-- Keys we have already asked about this session, so a player who dismissed the
-- prompt is not nagged every single time they re-cast the spell.
local askedThisSession = {}

-- Summons we are currently waiting on a name for: key -> summon uuid
local pending = {}

-- True while a naming prompt holds the world in forced turn-based mode.
local paused = false

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

---@param guid string
---@return boolean
local function isSummon(guid)
	local ok, result = pcall(Osi.IsSummon, guid)
	return ok and result == 1
end

--- Only bother the player about summons that belong to their own party.
---@param ownerUuid string
---@return boolean
local function ownerIsPlayer(ownerUuid)
	local ok, result = pcall(Osi.IsPartyMember, ownerUuid, 1)
	return ok and result == 1
end

--- A readable label for a root template (e.g. "Cat"), for the saved-name list.
--- Falls back to the template's dev name and finally "Summon"; never a uuid.
---@param templateId string
---@return string
local function templateLabel(templateId)
	local ok, template = pcall(Ext.Template.GetTemplate, templateId)
	if not (ok and template) then
		return "Summon"
	end
	local displayName = template.DisplayName
	local handle = displayName and displayName.Handle and displayName.Handle.Handle
	if handle then
		local okLoca, text = pcall(Ext.Loca.GetTranslatedString, handle)
		if okLoca and type(text) == "string" and text ~= "" then
			return text
		end
	end
	if type(template.Name) == "string" and template.Name ~= "" then
		return template.Name
	end
	return "Summon"
end

--- The current party's player characters (host plus companions).
---@return string[]
local function partyMembers()
	local out = {}
	local ok, rows = pcall(function()
		return Osi.DB_Players:Get(nil)
	end)
	if not ok or type(rows) ~= "table" then
		return out
	end
	for _, row in pairs(rows) do
		local guid = row[1]
		if type(guid) == "string" then
			out[#out + 1] = guid
		end
	end
	return out
end

--- Freeze the world while a naming prompt is up, via solo turn-based mode (what
--- community pause mods use out of combat). Skip in real combat, and skip if the
--- player already forced turn-based mode - that pause is theirs to lift, not ours.
---@param ownerUuid string
local function pauseFor(ownerUuid)
	if paused then
		return
	end
	if not Store.Settings().PauseOnPrompt then
		return
	end
	local okCombat, inCombat = pcall(Osi.IsInCombat, ownerUuid)
	if okCombat and inCombat == 1 then
		return
	end
	local okFtb, inFtb = pcall(Osi.IsInForceTurnBasedMode, ownerUuid)
	if okFtb and inFtb == 1 then
		return
	end

	for _, guid in ipairs(partyMembers()) do
		local okDead, dead = pcall(Osi.IsDead, guid)
		if not (okDead and dead == 1) and pcall(Osi.ForceTurnBasedMode, guid, 1) then
			paused = true
		end
	end
end

--- Lift the pause once nothing is waiting on a name. A summon the party controls
--- is also a participant in the shared turn-based session and holds it open, so
--- release EVERY FTB participant, exactly like the "Leave Turn-Based Mode" button.
local function unpauseIfIdle()
	if not paused then
		return
	end
	if next(pending) ~= nil then
		return
	end

	local ok, entities = pcall(Ext.Entity.GetAllEntitiesWithComponent, "FTBParticipant")
	if ok and type(entities) == "table" then
		for _, entity in ipairs(entities) do
			local okUuid, uuid = pcall(function()
				return entity.Uuid and entity.Uuid.EntityUuid
			end)
			if okUuid and type(uuid) == "string" then
				pcall(Osi.ForceTurnBasedMode, uuid, 0)
			end
		end
	end
	paused = false
end

---------------------------------------------------------------------------
-- Core
---------------------------------------------------------------------------

---@param summonGuid string
---@param rootTemplate string
---@param attempt integer|nil
function Watcher.HandleSummon(summonGuid, rootTemplate, attempt)
	attempt = attempt or 1
	if not Osi.Exists(summonGuid) or Osi.Exists(summonGuid) == 0 then
		return
	end

	local ownerRaw = Osi.CharacterGetOwner(summonGuid)
	if not ownerRaw or ownerRaw == "" then
		-- The owner link isn't wired up yet on some summon paths; retry briefly.
		if attempt < 5 then
			Ext.Timer.WaitFor(200, function()
				Watcher.HandleSummon(summonGuid, rootTemplate, attempt + 1)
			end)
		else
			Util.Warn("Gave up waiting for an owner on " .. tostring(summonGuid))
		end
		return
	end

	local ownerUuid = Util.ToUuid(ownerRaw)
	local key = Util.MakeKey(ownerUuid, rootTemplate)

	local settings = Store.Settings()
	local saved = Store.Get(key)

	-- Saved names are always reapplied. With PromptForNamed on we also re-ask so
	-- the player can rename; that path ignores askedThisSession, which only stops
	-- repeat prompts for summons left UNNAMED this session.
	if saved then
		Naming.ApplyDeferred(summonGuid, saved)
		if not (settings.PromptOnSummon and settings.PromptForNamed) then
			return
		end
	else
		if not settings.PromptOnSummon then
			return
		end
		if askedThisSession[key] then
			return
		end
	end

	if not ownerIsPlayer(ownerUuid) then
		return
	end

	askedThisSession[key] = true
	pending[key] = Util.ToUuid(summonGuid)
	pauseFor(ownerUuid)

	-- Give the summon a moment to finish spawning so the default name we show
	-- in the prompt is the real one.
	Ext.Timer.WaitFor(400, function()
		Channels.AskName:SendToClient({
			Key = key,
			SummonUuid = Util.ToUuid(summonGuid),
			OwnerUuid = ownerUuid,
			DefaultName = saved or Naming.GetCurrentName(summonGuid),
			Template = rootTemplate,
		}, ownerRaw)
	end)
end

---------------------------------------------------------------------------
-- Osiris hook
--
-- There is no "summon created" Osiris event in BG3. EnteredLevel fires for
-- every object that spawns into a level, and it conveniently hands us the
-- root template, which is the stable half of our storage key.
---------------------------------------------------------------------------

function Watcher.Register()
	Ext.Osiris.RegisterListener("EnteredLevel", 3, "after", function(objectGuid, rootTemplate, _level)
		if not isSummon(objectGuid) then
			return
		end
		-- Defer: on the tick a summon enters the level its owner link and
		-- display name are not reliably populated yet.
		Ext.Timer.WaitFor(100, function()
			Watcher.HandleSummon(objectGuid, rootTemplate)
		end)
	end)
end

---------------------------------------------------------------------------
-- Re-apply names to summons that are already alive (e.g. after loading a save)
---------------------------------------------------------------------------

function Watcher.ReapplyExisting()
	Naming.SeedLoca(Store.All())

	if not Store.Settings().ApplyToExisting then
		return
	end

	local summons = Naming.AllSummons()
	local applied = 0

	for _, summon in ipairs(summons) do
		local owner = Naming.OwnerOf(summon)
		local template = Naming.TemplateOf(summon)
		if owner and template then
			local saved = Store.Get(Util.MakeKey(owner, template))
			if saved and Naming.Apply(summon, saved) then
				applied = applied + 1
			end
		end
	end

	Util.Log(("Reapply: named %d of %d live summon(s)."):format(applied, #summons))
end

---------------------------------------------------------------------------
-- Net handlers
---------------------------------------------------------------------------

function Watcher.RegisterNet()
	Channels.SubmitName:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end

		local name = Util.Sanitise(data.Name)
		if name == "" then
			pending[data.Key] = nil
			unpauseIfIdle()
			return
		end

		Store.Set(data.Key, name)

		local target = data.SummonUuid or pending[data.Key]
		if target then
			Naming.Apply(target, name)
		end
		pending[data.Key] = nil
		unpauseIfIdle()
		Util.Log(("Saved name '%s' for key %s"):format(name, data.Key))
	end)

	Channels.ListNames:SetRequestHandler(function(_data, _user)
		local out = {}
		for key, name in pairs(Store.All()) do
			-- The key is "<ownerUuid>|<rootTemplate>"; split it so the client can
			-- group saved names by character and label each by its summon type.
			local owner, template = key:match("^(.-)|(.+)$")
			out[#out + 1] = {
				Key = key,
				Name = name,
				Owner = owner or key,
				-- Empty when the summoner is not loaded; the client shows the uuid.
				OwnerName = owner and Naming.GetCurrentName(owner) or "",
				TemplateName = templateLabel(template or key),
			}
		end
		table.sort(out, function(a, b)
			if a.OwnerName ~= b.OwnerName then
				return a.OwnerName:lower() < b.OwnerName:lower()
			end
			return a.Name:lower() < b.Name:lower()
		end)
		return { Entries = out }
	end)

	Channels.ForgetName:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		Store.Forget(data.Key)
		askedThisSession[data.Key] = nil
		Util.Log("Forgot saved name for key " .. data.Key)
	end)

	Channels.RenameName:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		if not Store.Get(data.Key) then
			return
		end
		local name = Util.Sanitise(data.Name)
		if name == "" then
			return
		end

		Store.Set(data.Key, name)

		-- Naming.Apply registers the new handle; update any live summon on the spot.
		for _, summon in ipairs(Naming.AllSummons()) do
			local owner = Naming.OwnerOf(summon)
			local template = Naming.TemplateOf(summon)
			if owner and template and Util.MakeKey(owner, template) == data.Key then
				Naming.Apply(summon, name)
			end
		end
		Util.Log(("Renamed key %s to '%s'"):format(data.Key, name))
	end)

	Channels.GetSettings:SetRequestHandler(function(_data, _user)
		return Store.Settings()
	end)

	Channels.SetSettings:SetHandler(function(data, _user)
		if type(data) ~= "table" then
			return
		end
		-- Store.SetSetting whitelists writable keys and rejects non-booleans.
		for key, value in pairs(data) do
			Store.SetSetting(key, value)
		end
	end)
end

---------------------------------------------------------------------------
-- Console commands (server context)
---------------------------------------------------------------------------

function Watcher.RegisterConsole()
	Ext.RegisterConsoleCommand("nys_diag", function()
		local summons = Naming.HostSummons()
		if #summons == 0 then
			Util.Log("No summons found on the host character; diagnosing the host instead.")
			Naming.Diagnose(Osi.GetHostCharacter())
			return
		end
		for _, summon in ipairs(summons) do
			Naming.Diagnose(summon)
		end
	end)

	-- Rename the host's summons on the spot, without going through the prompt.
	Ext.RegisterConsoleCommand("nys_rename", function(_cmd, ...)
		local name = Util.Sanitise(table.concat({ ... }, " "))
		if name == "" then
			Util.Log("Usage: !nys_rename <name>")
			return
		end
		local summons = Naming.HostSummons()
		if #summons == 0 then
			Util.Log("The host character has no summons out.")
			return
		end
		for _, summon in ipairs(summons) do
			Naming.Apply(summon, name)
		end
	end)

	Ext.RegisterConsoleCommand("nys_list", function()
		local n = 0
		for key, name in pairs(Store.All()) do
			Util.Log(("  %-70s -> %s"):format(key, name))
			n = n + 1
		end
		Util.Log(("%d saved name(s)."):format(n))
	end)

	-- Run the save/load reapply pass on demand, without reloading.
	Ext.RegisterConsoleCommand("nys_reapply", function()
		Watcher.ReapplyExisting()
	end)

	Ext.RegisterConsoleCommand("nys_clear", function()
		for key in pairs(Store.All()) do
			Store.Forget(key)
		end
		askedThisSession = {}
		Util.Log("Cleared all saved summon names.")
	end)
end

return Watcher
