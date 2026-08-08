local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Store = Ext.Require("Server/Store.lua")
local Naming = Ext.Require("Server/Naming.lua")
local Classifier = Ext.Require("Shared/SummonClassifier.lua")

local Watcher = {}

-- Keys we have already asked about this session, so a player who dismissed the
-- prompt is not nagged every single time they re-cast the spell.
local askedThisSession = {}

-- Keys the player actively skipped this session (dismissed the prompt without a
-- name), as opposed to always-skipped keys, which persist in the savegame. This
-- is transient and resets on reload; the config lists it so the player can
-- change their mind. A saved name or an always-skip clears the entry.
local sessionSkipped = {}

-- Keys we are currently waiting on a name for: key -> count of open prompts. A
-- unique multi-summon has one open prompt per creature, so this is a count, not
-- a single uuid, and the world stays paused until every one is answered.
local pending = {}

-- Summon uuids we have already prompted in "unique" mode. Guarding per-uuid
-- (rather than per-key) is what lets each creature of a group get its own prompt.
local askedUnique = {}

-- Debounce generation per key for resolving a cast's saved-name reapply. Bumping
-- it invalidates any timer from an earlier sibling so the cast resolves just once.
local resolveGen = {}

-- The summon uuids that arrived for a key in the current cast: key -> uuid[].
-- Naming is scoped to THIS batch, not every living summon of the type, so older
-- summons of the same type that are still out keep their own names.
local resolveBatch = {}

-- True while a naming prompt holds the world in forced turn-based mode.
local paused = false

-- Forward declaration: sendPrompt pauses at send time, but pauseFor is defined
-- further down (it depends on partyMembers).
local pauseFor

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

--- Run `action(summon, template)` for every live summon whose owner+template maps to `key`.
---@param key string
---@param action fun(summon: EntityHandle, template: string)
local function forLiveSummons(key, action)
	for _, summon in ipairs(Naming.AllSummons()) do
		local owner = Naming.OwnerOf(summon)
		local template = Naming.TemplateOf(summon)
		if owner and template and Util.MakeKey(owner, template) == key then
			action(summon, template)
		end
	end
end

---@param key string
local function addPending(key)
	pending[key] = (pending[key] or 0) + 1
end

--- Mark one open prompt for `key` answered; drop the key once none remain.
---@param key string
local function resolvePending(key)
	local n = (pending[key] or 0) - 1
	if n > 0 then
		pending[key] = n
	else
		pending[key] = nil
	end
end

---@param uuid string
---@return boolean
local function summonExists(uuid)
	local ok, result = pcall(Osi.Exists, uuid)
	return ok and result == 1
end

--- Apply a key's unique set across the given creatures, one distinct name each in
--- sorted-uuid order (see Util.AssignByOrder). Dead uuids are dropped first so a
--- name is never wasted on one. Returns the number of creatures named.
---@param key string
---@param uuids string[]
---@return integer
local function applySetTo(key, uuids)
	local names = Store.Get(key)
	if type(names) ~= "table" then
		return 0
	end
	local live = {}
	for _, uuid in ipairs(uuids) do
		if summonExists(uuid) then
			live[#live + 1] = uuid
		end
	end
	local applied = 0
	for uuid, name in pairs(Util.AssignByOrder(live, names)) do
		if Naming.Apply(uuid, name) then
			applied = applied + 1
		end
	end
	return applied
end

--- Apply a key's unique set across EVERY live sibling of the key. Used on load
--- and from the config, where there is no single cast to scope to.
---@param key string
---@return integer
local function distributeUnique(key)
	local uuids = {}
	forLiveSummons(key, function(summon)
		local uuid = summon.Uuid and tostring(summon.Uuid.EntityUuid)
		if uuid then
			uuids[#uuids + 1] = uuid
		end
	end)
	return applySetTo(key, uuids)
end

--- Tell the owner's client to cancel a naming prompt it may be showing for `key`.
---@param key string
---@param ownerRaw string
local function retract(key, ownerRaw)
	pcall(function()
		Channels.RetractPrompt:SendToClient({ Key = key }, ownerRaw)
	end)
end

--- Ask the owner's client to name a summon. Deferred so the summon has finished
--- spawning and the default name we show is the real one. Aborts if the prompt
--- was retracted or the group always-skipped during the delay (pending cleared);
--- pausing only here means a retracted skip-mode group never freezes the world.
---@param key string
---@param summonGuid string
---@param rootTemplate string
---@param ownerUuid string
---@param ownerRaw string
---@param scope string  "single" | "shared" | "unique"
---@param savedName string|nil
---@param slot integer|nil  the unique-set index this prompt replaces, if re-asking
local function sendPrompt(key, summonGuid, rootTemplate, ownerUuid, ownerRaw, scope, savedName, slot)
	Ext.Timer.WaitFor(400, function()
		if (pending[key] or 0) == 0 then
			return
		end
		pauseFor(ownerUuid)
		Channels.AskName:SendToClient({
			Key = key,
			SummonUuid = Util.ToUuid(summonGuid),
			OwnerUuid = ownerUuid,
			DefaultName = savedName or Naming.GetCurrentName(summonGuid),
			Template = rootTemplate,
			Scope = scope,
			Slot = slot,
		}, ownerRaw)
	end)
end

--- Reapply a key's saved name(s) to the creatures a cast just produced, and with
--- PromptForNamed on, re-ask. Honours the CURRENT MultiSummonMode - so a set
--- saved under "unique" collapses to one shared name once the player switches to
--- "shared" - rather than the stored value's shape. Scoped to this cast's batch,
--- so older summons of the same type keep their own names.
---@param key string
---@param batch string[]  the uuids that arrived in this cast
---@param ownerUuid string
---@param ownerRaw string
---@param rootTemplate string
local function resolveGroup(key, batch, ownerUuid, ownerRaw, rootTemplate)
	local saved = Store.Get(key)
	if saved == nil then
		return
	end
	local settings = Store.Settings()
	local mode = settings.MultiSummonMode
	local reAsk = settings.PromptOnSummon and settings.PromptForNamed and ownerIsPlayer(ownerUuid)

	local live = {}
	for _, uuid in ipairs(batch) do
		if summonExists(uuid) then
			live[#live + 1] = uuid
		end
	end
	table.sort(live)

	-- Unique: a distinct name per creature from the saved set.
	if mode == "unique" and type(saved) == "table" then
		applySetTo(key, live)
		if reAsk then
			-- Re-ask each at its own slot so a rename replaces that entry and a
			-- dismissal keeps it; a creature past the set's end (upcast) appends.
			for i, uuid in ipairs(live) do
				if not askedUnique[uuid] then
					askedUnique[uuid] = true
					addPending(key)
					local slot = saved[i] ~= nil and i or nil
					sendPrompt(key, uuid, rootTemplate, ownerUuid, ownerRaw, "unique", saved[i], slot)
				end
			end
		end
		return
	end

	-- Otherwise the whole cast shares one name, collapsing a leftover set to its
	-- first entry. Skip mode still reapplies; it just never re-asks a group.
	local sharedName = type(saved) == "table" and saved[1] or saved
	if type(sharedName) == "string" and sharedName ~= "" then
		for _, uuid in ipairs(live) do
			Naming.ApplyDeferred(uuid, sharedName)
		end
	end
	if reAsk and (#live <= 1 or mode ~= "skip") and live[1] then
		-- One prompt for the cast; on submit it applies to every live sibling.
		addPending(key)
		local scope = #live > 1 and "shared" or "single"
		sendPrompt(key, live[1], rootTemplate, ownerUuid, ownerRaw, scope, sharedName)
	end
end

--- Debounce resolving a cast's saved-name reapply: creatures enter over several
--- ticks, so collect the cast's uuids and restart the timer on each arrival,
--- acting once when they settle. The batch is what scopes naming to this cast
--- rather than every living summon of the type.
---@param key string
---@param summonUuid string
---@param ownerUuid string
---@param ownerRaw string
---@param rootTemplate string
local function scheduleResolve(key, summonUuid, ownerUuid, ownerRaw, rootTemplate)
	local batch = resolveBatch[key]
	if not batch then
		batch = {}
		resolveBatch[key] = batch
	end
	batch[#batch + 1] = summonUuid

	local generation = (resolveGen[key] or 0) + 1
	resolveGen[key] = generation
	Ext.Timer.WaitFor(500, function()
		if resolveGen[key] ~= generation then
			return
		end
		resolveGen[key] = nil
		resolveBatch[key] = nil
		resolveGroup(key, batch, ownerUuid, ownerRaw, rootTemplate)
	end)
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
function pauseFor(ownerUuid)
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

--- Split a storage key into the owner/template fields the client groups by.
--- The key is "<ownerUuid>|<rootTemplate>".
---@param key string
---@return table
local function describeKey(key)
	local owner, template = key:match("^(.-)|(.+)$")
	return {
		Key = key,
		Owner = owner or key,
		-- Empty when the summoner is not loaded; the client shows the uuid.
		OwnerName = owner and Naming.GetCurrentName(owner) or "",
		TemplateName = templateLabel(template or key),
	}
end

--- Order display entries by summoner, then by summon type.
---@param a table
---@param b table
---@return boolean
local function byOwnerThenTemplate(a, b)
	if a.OwnerName ~= b.OwnerName then
		return a.OwnerName:lower() < b.OwnerName:lower()
	end
	return a.TemplateName:lower() < b.TemplateName:lower()
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

	-- An already-named summon: reapply the saved name(s) and, with PromptForNamed
	-- on, re-ask - resolveGroup honours the current mode, so a mode change takes
	-- effect on the next summon rather than being locked to how it was named.
	if saved ~= nil then
		scheduleResolve(key, Util.ToUuid(summonGuid), ownerUuid, ownerRaw, rootTemplate)
		return
	end

	if not settings.PromptOnSummon then
		return
	end
	-- The player asked never to be prompted about this summon.
	if Store.IsSkipped(key) then
		return
	end
	if not ownerIsPlayer(ownerUuid) then
		return
	end

	-- Story summons (e.g. "Us") are not prompted unless opted in; a saved name still reapplies above.
	if Util.IsStorySummon(rootTemplate) and not settings.AllowStorySummons then
		return
	end

	-- Only prompt for summon types the player has enabled (GH #14); a saved name
	-- still reapplies above regardless of type.
	if not Classifier.IsEligible(Naming.TagNamesOf(summonGuid), settings) then
		return
	end

	local mode = settings.MultiSummonMode

	-- Unique mode asks about every creature individually, so the guard is
	-- per-uuid; a sibling is not blocked by the first creature's prompt.
	if mode == "unique" then
		local uuid = Util.ToUuid(summonGuid)
		if askedUnique[uuid] then
			return
		end
		askedUnique[uuid] = true
		addPending(key)
		sendPrompt(key, summonGuid, rootTemplate, ownerUuid, ownerRaw, "unique", nil)
		return
	end

	-- Single, shared, and skip all ask once per key.
	if askedThisSession[key] then
		-- In skip mode a sibling arriving while the first prompt is still open
		-- reveals this to be a multi-summon: retract the prompt (or abort it, if
		-- still in its send delay) and leave the group unnamed this session.
		if mode == "skip" and (pending[key] or 0) > 0 then
			pending[key] = nil
			sessionSkipped[key] = true
			retract(key, ownerRaw)
			unpauseIfIdle()
		end
		return
	end

	askedThisSession[key] = true
	addPending(key)
	sendPrompt(key, summonGuid, rootTemplate, ownerUuid, ownerRaw, mode == "shared" and "shared" or "single", nil)
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
	local doneKeys = {}

	for _, summon in ipairs(summons) do
		local owner = Naming.OwnerOf(summon)
		local template = Naming.TemplateOf(summon)
		if owner and template then
			local key = Util.MakeKey(owner, template)
			local saved = Store.Get(key)
			if type(saved) == "string" then
				if Naming.Apply(summon, saved) then
					applied = applied + 1
				end
			elseif type(saved) == "table" and not doneKeys[key] then
				-- A unique set is distributed across the key's siblings in one pass.
				doneKeys[key] = true
				applied = applied + distributeUnique(key)
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
		local key = data.Key
		local scope = data.Scope

		-- "Always skip": persist the choice so we never prompt for this key again,
		-- and cancel the rest of a unique group so a later slot cannot revive it.
		if data.AlwaysSkip then
			Store.Skip(key)
			sessionSkipped[key] = nil
			pending[key] = nil
			unpauseIfIdle()
			Util.Log("Always-skipping key " .. key)
			return
		end

		-- A straggling submit for a key that was always-skipped (e.g. another
		-- creature of this group) is ignored, name and all.
		if Store.IsSkipped(key) then
			resolvePending(key)
			unpauseIfIdle()
			return
		end

		local name = Util.Sanitise(data.Name)
		if name == "" then
			if data.Abort then
				-- Aborted via the X: clear the "already asked" marks so a re-summon
				-- prompts again rather than recording a skip.
				askedThisSession[key] = nil
				if data.SummonUuid then
					askedUnique[data.SummonUuid] = nil
				end
			elseif scope ~= "unique" then
				-- Dismissed via Skip: a session-only skip the config can undo. One
				-- creature of a unique group is just left unnamed; siblings still ask.
				sessionSkipped[key] = true
			end
			resolvePending(key)
			unpauseIfIdle()
			return
		end

		if scope == "unique" then
			-- A re-ask carries the slot it replaces; a first-time prompt appends.
			if type(data.Slot) == "number" then
				Store.SetSlot(key, data.Slot, name)
			else
				Store.AppendUnique(key, name)
			end
		else
			Store.Set(key, name)
		end
		sessionSkipped[key] = nil

		if scope == "shared" then
			-- Name every live sibling now, not just the one that was prompted.
			forLiveSummons(key, function(summon)
				Naming.Apply(summon, name)
			end)
		elseif data.SummonUuid then
			Naming.Apply(data.SummonUuid, name)
		end

		resolvePending(key)
		unpauseIfIdle()
		Util.Log(("Saved name '%s' for key %s"):format(name, key))
	end)

	Channels.ListNames:SetRequestHandler(function(_data, _user)
		local out = {}
		for key, value in pairs(Store.All()) do
			if type(value) == "table" then
				-- A unique set: one row per distinct name, tagged with its slot.
				for i, name in ipairs(value) do
					local entry = describeKey(key)
					entry.Name = name
					entry.Slot = i
					out[#out + 1] = entry
				end
			else
				local entry = describeKey(key)
				entry.Name = value
				out[#out + 1] = entry
			end
		end
		table.sort(out, function(a, b)
			if a.OwnerName ~= b.OwnerName then
				return a.OwnerName:lower() < b.OwnerName:lower()
			end
			return a.Name:lower() < b.Name:lower()
		end)
		return { Entries = out }
	end)

	Channels.ListSkipped:SetRequestHandler(function(_data, _user)
		local out = {}
		for key in pairs(Store.AllSkipped()) do
			out[#out + 1] = describeKey(key)
		end
		table.sort(out, byOwnerThenTemplate)
		return { Entries = out }
	end)

	Channels.Unskip:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		Store.Unskip(data.Key)
		-- Let the prompt reappear for this summon this session.
		askedThisSession[data.Key] = nil
		Util.Log("Cleared always-skip for key " .. data.Key)
	end)

	Channels.ListSessionSkipped:SetRequestHandler(function(_data, _user)
		local out = {}
		for key in pairs(sessionSkipped) do
			-- A key that has since been named or always-skipped no longer counts.
			if not Store.Get(key) and not Store.IsSkipped(key) then
				out[#out + 1] = describeKey(key)
			end
		end
		table.sort(out, byOwnerThenTemplate)
		return { Entries = out }
	end)

	Channels.UnskipSession:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		sessionSkipped[data.Key] = nil
		-- Clear the "already asked" mark so the next summon re-prompts this session.
		askedThisSession[data.Key] = nil
		Util.Log("Cleared session-skip for key " .. data.Key)
	end)

	Channels.ForgetName:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		local key = data.Key
		if type(data.Slot) == "number" then
			Store.ForgetSlot(key, data.Slot)
		else
			Store.Forget(key)
		end
		askedThisSession[key] = nil

		-- Revert every live sibling to its template default, then reapply any
		-- names the key still has (a unique set may keep its other entries).
		forLiveSummons(key, function(summon, template)
			Naming.Restore(summon, template)
		end)
		if type(Store.Get(key)) == "table" then
			distributeUnique(key)
		end
		Util.Log("Forgot saved name for key " .. key)
	end)

	Channels.RenameName:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		local key = data.Key
		if Store.Get(key) == nil then
			return
		end
		local name = Util.Sanitise(data.Name)
		if name == "" then
			return
		end

		if type(data.Slot) == "number" then
			Store.SetSlot(key, data.Slot, name)
			-- Distributing is the single idempotent apply path for a unique set.
			distributeUnique(key)
		else
			Store.Set(key, name)
			-- Naming.Apply registers the new handle; update live summons now.
			forLiveSummons(key, function(summon)
				Naming.Apply(summon, name)
			end)
		end
		Util.Log(("Renamed key %s to '%s'"):format(key, name))
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
		for key, value in pairs(Store.All()) do
			if type(value) == "table" then
				for i, name in ipairs(value) do
					Util.Log(("  %-70s -> [%d] %s"):format(key, i, name))
					n = n + 1
				end
			else
				Util.Log(("  %-70s -> %s"):format(key, value))
				n = n + 1
			end
		end
		Util.Log(("%d saved name(s)."):format(n))

		local skipped = 0
		for key in pairs(Store.AllSkipped()) do
			Util.Log(("  %-70s -> (always skipped)"):format(key))
			skipped = skipped + 1
		end
		Util.Log(("%d always-skipped summon(s)."):format(skipped))

		local session = 0
		for key in pairs(sessionSkipped) do
			Util.Log(("  %-70s -> (skipped this session)"):format(key))
			session = session + 1
		end
		Util.Log(("%d summon(s) skipped this session."):format(session))
	end)

	-- Run the save/load reapply pass on demand, without reloading.
	Ext.RegisterConsoleCommand("nys_reapply", function()
		Watcher.ReapplyExisting()
	end)

	Ext.RegisterConsoleCommand("nys_clear", function()
		for key in pairs(Store.All()) do
			Store.Forget(key)
		end
		for key in pairs(Store.AllSkipped()) do
			Store.Unskip(key)
		end
		askedThisSession = {}
		sessionSkipped = {}
		askedUnique = {}
		Util.Log("Cleared all saved summon names and always-skip choices.")
	end)
end

return Watcher
