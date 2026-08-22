-- SPDX-License-Identifier: MIT
local Util = Ext.Require("Shared/Util.lua")
local Trace = Ext.Require("Shared/Trace.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Store = Ext.Require("Server/Store.lua")
local Naming = Ext.Require("Server/Naming.lua")
local Classifier = Ext.Require("Shared/SummonClassifier.lua")

local Watcher = {}

local function twatch(msg, data)
	Trace.Log("watcher", msg, data)
end

-- Keys already asked about this session, so a dismissed prompt is not re-shown on
-- every re-cast.
local askedThisSession = {}

-- Keys awaiting a name: key -> count of open prompts. A unique multi-summon has one
-- prompt per creature, so this is a count; the world stays paused until all answer.
local pending = {}

-- Summon uuids already prompted in "unique" mode. Guarding per-uuid (not per-key)
-- lets each creature of a group get its own prompt.
local askedUnique = {}

-- Debounce generation per key for resolving a cast's reapply. Bumping it invalidates
-- an earlier sibling's timer so the cast resolves just once.
local resolveGen = {}

-- The summon uuids that arrived for a key in the current cast: key -> uuid[]. Naming
-- is scoped to this batch, so older summons of the same type keep their own names.
local resolveBatch = {}

-- True while a naming prompt holds the world in forced turn-based mode.
local paused = false

-- Forward declaration: sendPrompt pauses at send time; pauseFor is defined below.
local pauseFor

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

--- The BG3SE UserID currently reserving/controlling a character, or nil. In local
--- split-screen each player has a distinct UserID (e.g. 65537 host, 65538 P2); when a
--- player leaves, their character's reserved user flips to the host.
---@param character string|nil
---@return integer|nil
local function reservedUser(character)
	if type(character) ~= "string" or character == "" then
		return nil
	end
	local ok, uid = pcall(Osi.GetReservedUserID, character)
	if ok and type(uid) == "number" then
		return uid
	end
	return nil
end

--- The character a user currently controls, as a bare uuid, or nil. The client<->server
--- bridge for targeting a split-screen viewport: equals CurrentPlayer.SelectedCharacter.
--- EntityUUID client-side.
---@param user integer|nil
---@return string|nil
local function currentCharOfUser(user)
	if type(user) ~= "number" then
		return nil
	end
	local ok, ch = pcall(Osi.GetCurrentCharacter, user)
	if ok and type(ch) == "string" and ch ~= "" then
		return Util.ToUuid(ch)
	end
	return nil
end

--- A readable label for a root template (e.g. "Cat"), for the saved-name list.
--- The template DisplayName is a game loca handle, resolved here in the server's
--- language. Returns nil when unreadable; the client then shows its own localised
--- "Summon" fallback.
---@param templateId string
---@return string|nil
local function templateLabel(templateId)
	local ok, template = pcall(Ext.Template.GetTemplate, templateId)
	if not (ok and template) then
		return nil
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
	return nil
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

--- Record a key's type label from a live summon's tags, for the saved-name list.
--- Tags are only readable off a live instance, so capture it whenever one is seen.
---@param key string
---@param summonRef string|EntityHandle
local function rememberType(key, summonRef)
	Store.SetType(key, Classifier.DescribeKey(Naming.TagNamesOf(summonRef)))
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
--- spawning and the default name shown is the real one. Aborts if the prompt was
--- retracted during the delay (pending cleared); pausing only here means a retracted
--- skip-mode group never freezes the world.
---@param key string
---@param summonGuid string
---@param rootTemplate string
---@param ownerUuid string
---@param ownerRaw string
---@param scope string  "single" | "shared" | "unique"
---@param savedName string|nil
---@param slot integer|nil  the unique-set index this prompt replaces, if re-asking
local function sendPrompt(key, summonGuid, rootTemplate, ownerUuid, ownerRaw, scope, savedName, slot)
	twatch("sendPrompt scheduled", { Key = key, Summon = summonGuid, Scope = scope, Slot = slot })
	Ext.Timer.WaitFor(400, function()
		if (pending[key] or 0) == 0 then
			twatch("sendPrompt aborted, prompt retracted during defer", { Key = key })
			return
		end
		pauseFor(ownerUuid)
		-- ViewportChar tells the split-screen client which viewport to open Examine in;
		-- falls back to the owner uuid when the user/char cannot be resolved.
		local viewportChar = currentCharOfUser(reservedUser(ownerRaw)) or ownerUuid
		Channels.AskName:SendToClient({
			Key = key,
			SummonUuid = Util.ToUuid(summonGuid),
			OwnerUuid = ownerUuid,
			ViewportChar = viewportChar,
			DefaultName = savedName or Naming.GetCurrentName(summonGuid),
			Template = rootTemplate,
			Scope = scope,
			Slot = slot,
		}, ownerRaw)
	end)
end

--- Reapply a key's saved name(s) to the creatures a cast just produced, and with
--- PromptForNamed on, re-ask. Honours the CURRENT MultiSummonMode (a set saved under
--- "unique" collapses to one shared name after switching to "shared"), not the stored
--- value's shape. Scoped to this cast's batch.
---@param key string
---@param batch string[]  the uuids that arrived in this cast
---@param ownerUuid string
---@param ownerRaw string
---@param rootTemplate string
local function resolveGroup(key, batch, ownerUuid, ownerRaw, rootTemplate)
	local saved = Store.Get(key)
	twatch("resolveGroup", { Key = key, Batch = batch, Saved = saved })
	if saved == nil then
		return
	end
	local settings = Store.Settings()
	local mode = settings.MultiSummonMode
	-- A story summon whose opt-in is off is never re-prompted; its saved name still reapplies.
	local storyForbidden = Util.IsStorySummon(rootTemplate) and not settings.AllowStorySummons
	local reAsk = settings.PromptOnSummon
		and settings.PromptForNamed
		and ownerIsPlayer(ownerUuid)
		and not storyForbidden

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

--- Debounce resolving a cast's reapply: creatures enter over several ticks, so
--- collect the cast's uuids and restart the timer on each arrival, acting once they
--- settle. The batch scopes naming to this cast, not every living summon of the type.
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

--- Clear a skip-mode group's asked mark once its siblings have all been suppressed
--- (500ms), so a later cast re-prompts under the mode set by then. Clearing on the
--- spot would let the very next sibling re-prompt, hence the delay.
---@param key string
local function scheduleMultiSkipReset(key)
	Ext.Timer.WaitFor(500, function()
		askedThisSession[key] = nil
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

--- Freeze the world while a naming prompt is up, via solo turn-based mode. Skip in
--- real combat, and skip if the player already forced turn-based mode - that pause
--- is theirs to lift, not ours.
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
	twatch("pauseFor", { Owner = ownerUuid, Paused = paused })
end

--- Lift the pause once nothing is waiting on a name. A summon the party controls is
--- also a participant in the shared turn-based session and holds it open, so release
--- EVERY FTB participant, like the "Leave Turn-Based Mode" button.
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
	twatch("unpauseIfIdle: pause lifted")
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
		Type = Store.GetType(key),
	}
end

---@param summonGuid string
---@param rootTemplate string
---@param attempt integer|nil
function Watcher.HandleSummon(summonGuid, rootTemplate, attempt)
	attempt = attempt or 1
	twatch("HandleSummon", { Summon = summonGuid, Template = rootTemplate, Attempt = attempt })
	local okExists, exists = pcall(Osi.Exists, summonGuid)
	if okExists and exists ~= 1 then
		twatch("HandleSummon: summon no longer exists", { Summon = summonGuid })
		return
	end

	local okOwner, ownerRaw = pcall(Osi.CharacterGetOwner, summonGuid)
	if not okOwner then
		ownerRaw = nil
	end
	if not ownerRaw or ownerRaw == "" then
		-- The owner link is not wired up yet on some summon paths; retry briefly.
		if attempt < 5 then
			twatch("HandleSummon: no owner yet, retrying", { Summon = summonGuid, Attempt = attempt })
			Ext.Timer.WaitFor(200, function()
				Watcher.HandleSummon(summonGuid, rootTemplate, attempt + 1)
			end)
		else
			Util.Warn("Gave up waiting for an owner on " .. tostring(summonGuid))
			twatch("HandleSummon: gave up waiting for owner", { Summon = summonGuid })
		end
		return
	end

	local ownerUuid = Util.ToUuid(ownerRaw)
	local key = Util.MakeKey(ownerUuid, rootTemplate)

	local settings = Store.Settings()
	local saved = Store.Get(key)

	-- An already-named summon: reapply the saved name(s) and, with PromptForNamed on,
	-- re-ask. resolveGroup honours the current mode, so a mode change applies next summon.
	if saved ~= nil then
		twatch("HandleSummon: known key -> scheduleResolve", { Key = key, Summon = summonGuid })
		rememberType(key, summonGuid)
		scheduleResolve(key, Util.ToUuid(summonGuid), ownerUuid, ownerRaw, rootTemplate)
		return
	end

	if not ownerIsPlayer(ownerUuid) then
		twatch("HandleSummon: owner is not a party member", { Key = key, Owner = ownerUuid })
		return
	end
	-- Record the type regardless of prompt settings, so a summon skipped or later
	-- named via Examine still shows its type in the list.
	rememberType(key, summonGuid)

	if not settings.PromptOnSummon then
		twatch("HandleSummon: PromptOnSummon off", { Key = key })
		return
	end

	-- Story summons are gated by their own opt-in; an opted-in one then bypasses the
	-- per-creature-type filter below (its type is rarely one the player enabled, so
	-- requiring both would make the opt-in look broken).
	local isStory = Util.IsStorySummon(rootTemplate)
	if isStory and not settings.AllowStorySummons then
		twatch("HandleSummon: story summon, opt-in off", { Key = key })
		return
	end

	-- Only prompt for enabled summon types; opted-in story summons bypass this.
	if not isStory and not Classifier.IsEligible(Naming.TagNamesOf(summonGuid), settings) then
		twatch("HandleSummon: creature type not enabled", { Key = key })
		return
	end

	local mode = settings.MultiSummonMode

	-- Unique mode asks about every creature individually, so the guard is
	-- per-uuid; a sibling is not blocked by the first creature's prompt.
	if mode == "unique" then
		local uuid = Util.ToUuid(summonGuid)
		if askedUnique[uuid] then
			twatch("HandleSummon: unique creature already asked", { Key = key, Summon = uuid })
			return
		end
		askedUnique[uuid] = true
		addPending(key)
		sendPrompt(key, summonGuid, rootTemplate, ownerUuid, ownerRaw, "unique", nil)
		return
	end

	-- Single, shared, and skip all ask once per key.
	if askedThisSession[key] then
		-- A sibling arriving while the first prompt is still pending (pending > 0) reveals
		-- a multi-summon; a plain re-cast finds pending == 0 and is left alone. Retract the
		-- prompt and leave the group unnamed WITHOUT storing a skip, so a mode change
		-- re-prompts it next cast.
		if mode == "skip" and (pending[key] or 0) > 0 then
			twatch("HandleSummon: skip-mode sibling -> retract", { Key = key })
			pending[key] = nil
			retract(key, ownerRaw)
			unpauseIfIdle()
			scheduleMultiSkipReset(key)
		else
			twatch("HandleSummon: already asked this session", { Key = key, Mode = mode })
		end
		return
	end

	askedThisSession[key] = true
	addPending(key)
	sendPrompt(key, summonGuid, rootTemplate, ownerUuid, ownerRaw, mode == "shared" and "shared" or "single", nil)
end

-- There is no "summon created" Osiris event; EnteredLevel fires for every object
-- spawning into a level and hands us the root template (the stable half of the key).
function Watcher.Register()
	Ext.Osiris.RegisterListener("EnteredLevel", 3, "after", function(objectGuid, rootTemplate, level)
		if not isSummon(objectGuid) then
			return
		end
		twatch("summon entered level", { Summon = objectGuid, Template = rootTemplate, Level = level })
		-- Defer: a summon's owner link and display name are not populated on the tick
		-- it enters the level.
		Ext.Timer.WaitFor(100, function()
			Watcher.HandleSummon(objectGuid, rootTemplate)
		end)
	end)
end

-- Re-apply names to summons already alive (e.g. after loading a save).
function Watcher.ReapplyExisting()
	Naming.SeedLoca(Store.All())

	-- Reapplying names on load is opt-out, but the type refresh always runs so the
	-- list can show a type for summons that were alive at load.
	local applyNames = Store.Settings().ApplyToExisting
	local summons = Naming.AllSummons()
	local applied = 0
	local doneKeys = {}

	for _, summon in ipairs(summons) do
		local owner = Naming.OwnerOf(summon)
		local template = Naming.TemplateOf(summon)
		if owner and template then
			local key = Util.MakeKey(owner, template)
			local saved = Store.Get(key)
			if saved ~= nil then
				rememberType(key, summon)
			end
			if applyNames and type(saved) == "string" then
				if Naming.Apply(summon, saved) then
					applied = applied + 1
				end
			elseif applyNames and type(saved) == "table" and not doneKeys[key] then
				-- A unique set is distributed across the key's siblings in one pass.
				doneKeys[key] = true
				applied = applied + distributeUnique(key)
			end
		end
	end

	Util.Log(("Reapply: named %d of %d live summon(s)."):format(applied, #summons))
	twatch("ReapplyExisting done", { Applied = applied, LiveSummons = #summons, ApplyNames = applyNames })
end

function Watcher.RegisterNet()
	Channels.SubmitName:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		local key = data.Key
		local scope = data.Scope

		local name = Util.Sanitise(data.Name)
		if name == "" then
			if data.Abort then
				-- Aborted via Skip: clear the asked marks so a re-summon prompts again.
				askedThisSession[key] = nil
				if data.SummonUuid then
					askedUnique[data.SummonUuid] = nil
				end
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

	Channels.ListNames:SetRequestHandler(function(data, _user)
		-- Scope the list to the viewing player: resolve the viewer's character and each
		-- owner to a UserID and compare. A missing viewer shows all (never an empty list).
		local viewerUser = reservedUser(type(data) == "table" and data.ViewerCharacter or nil)
		local hostOk, host = pcall(Osi.GetHostCharacter)
		local hostUser = reservedUser(hostOk and host or nil)
		local ownerUserCache = {}
		local function isVisible(owner)
			if ownerUserCache[owner] == nil then
				ownerUserCache[owner] = { user = reservedUser(owner) }
			end
			return Util.IsNameVisible(ownerUserCache[owner].user, viewerUser, hostUser)
		end

		local out = {}
		for key, value in pairs(Store.All()) do
			local entry0 = describeKey(key)
			if isVisible(entry0.Owner) then
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

	-- Rename one specific live summon, addressed by uuid (from a native UI control).
	Channels.RenameSummon:SetHandler(function(data, _user)
		if not Util.IsRenameRequestValid(data) then
			return
		end
		local uuid = Util.ToUuid(data.SummonUuid)
		if not isSummon(uuid) then
			return
		end
		local ok, entity = pcall(Ext.Entity.Get, uuid)
		if not ok or not entity then
			return
		end
		local owner = Naming.OwnerOf(entity)
		local template = Naming.TemplateOf(entity)
		if not owner or not template then
			return
		end

		local key = Util.MakeKey(owner, template)
		-- Record the type here too: an Examine rename can create a saved name for a summon
		-- that was alive at load and so never passed through HandleSummon.
		rememberType(key, uuid)
		local name = Util.Sanitise(data.Name)

		-- Follow the CURRENT MultiSummonMode, like resolveGroup: a leftover unique set
		-- must not force unique behaviour after switching to shared/skip, which collapses
		-- any leftover set to one name.
		if Store.Settings().MultiSummonMode == "unique" then
			-- Rename just this creature's slot (its sorted position among live siblings, per
			-- Util.AssignByOrder) so the others keep their names.
			local siblings = {}
			forLiveSummons(key, function(summon)
				local sid = summon.Uuid and tostring(summon.Uuid.EntityUuid)
				if sid then
					siblings[#siblings + 1] = sid
				end
			end)
			table.sort(siblings)

			-- Seed a dense set aligned to the live siblings, then overwrite the target slot.
			-- SetSlot/AppendUnique no-op when the saved set is shorter than the target slot.
			local saved = Store.Get(key)
			local names = {}
			if type(saved) == "table" then
				for i, n in ipairs(saved) do
					names[i] = n
				end
			elseif type(saved) == "string" then
				names[1] = saved
			end
			local target
			for i, sid in ipairs(siblings) do
				if names[i] == nil then
					names[i] = Naming.GetCurrentName(sid)
				end
				if sid == uuid then
					target = i
				end
			end
			if target then
				names[target] = name
			else
				names[#names + 1] = name
			end
			Store.SetUnique(key, names)
			distributeUnique(key)
		else
			Store.Set(key, name)
			forLiveSummons(key, function(summon)
				Naming.Apply(summon, name)
			end)
		end
		Util.Log(("Renamed summon %s ('%s') via key %s"):format(uuid, name, key))
	end)

	-- The client cannot resolve a summon's owner (Osi is server-only), so it asks here; owned means
	-- owner and viewer share a controlling user, as Util.IsNameVisible decides for ListNames.
	Channels.QueryOwnership:SetRequestHandler(function(data, _user)
		if type(data) ~= "table" or type(data.SummonUuid) ~= "string" then
			return { Owned = false }
		end
		local uuid = Util.ToUuid(data.SummonUuid)
		if not isSummon(uuid) then
			return { Owned = false }
		end
		-- Intentionally lenient advisory UX, not a security gate: the rename itself is not
		-- owner-checked server-side, so a nil/unresolved viewer stays allowed (via IsNameVisible)
		-- to avoid a happy-path flicker; the client retracts the controls if the summon turns
		-- out to be another player's. Do not "fix" this to fail closed.
		local ownerUser = reservedUser(Osi.CharacterGetOwner(uuid))
		local viewerUser = reservedUser(type(data.ViewerCharacter) == "string" and data.ViewerCharacter or nil)
		local hostOk, host = pcall(Osi.GetHostCharacter)
		local hostUser = reservedUser(hostOk and host or nil)
		return { Owned = Util.IsNameVisible(ownerUser, viewerUser, hostUser) }
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
		-- Push to clients so a locally cached copy (the story-summon rename gate in
		-- NativeRenameUI) updates at once, not on the next re-summon.
		pcall(function()
			Channels.SettingsChanged:Broadcast(Store.Settings())
		end)
	end)
end

-- Console commands (server context).
function Watcher.RegisterConsole()
	Ext.RegisterConsoleCommand("nys_diag", function()
		local summons = Naming.HostSummons()
		if #summons == 0 then
			Util.Say("No summons found on the host character; diagnosing the host instead.")
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
			Util.Say("Usage: !nys_rename <name>")
			return
		end
		local summons = Naming.HostSummons()
		if #summons == 0 then
			Util.Say("The host character has no summons out.")
			return
		end
		local renamed = 0
		for _, summon in ipairs(summons) do
			if Naming.Apply(summon, name) then
				renamed = renamed + 1
			end
		end
		Util.Say(("Renamed %d summon(s) to '%s'."):format(renamed, name))
	end)

	Ext.RegisterConsoleCommand("nys_list", function()
		local n = 0
		for key, value in pairs(Store.All()) do
			if type(value) == "table" then
				for i, name in ipairs(value) do
					Util.Say(("  %-70s -> [%d] %s"):format(key, i, name))
					n = n + 1
				end
			else
				Util.Say(("  %-70s -> %s"):format(key, value))
				n = n + 1
			end
		end
		Util.Say(("%d saved name(s)."):format(n))
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
		askedUnique = {}
		Util.Say("Cleared all saved summon names.")
	end)
end

return Watcher
