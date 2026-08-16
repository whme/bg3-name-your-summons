-- SPDX-License-Identifier: MIT
--[[
    Client side of the native "rename this summon" control. The examined creature's
    uuid is read from the Examine panel's Noesis DataContext (EntityUUID +
    CharacterType) and a rename is sent to the server.

    Per-viewport: local split-screen has ONE shared client Lua state but up to one
    Examine panel per viewport open at once. Each panel carries its own CurrentPlayer
    (a distinct PlayerId and the viewer's SelectedCharacter), so all panel state is
    keyed by PlayerId (`panels[id]`) and every node lookup is scoped to a given panel
    (`examineNodeById`, `findNamedIn`, `liveFieldIn`). The server routes an on-summon
    prompt to a viewport via ViewportChar, matched to a panel by SelectedCharacter.

    Native-UI approach (see docs/bg3-modding-toolchain.md and AGENTS.md):
    - Controls we add are driven by per-element MVVM, not global mouse hit-testing:
      the gear's Command binds to a viewmodel on its nested DataContext; the field
      commits via its own per-element subscriptions.
    - Manual-open detection is a persistent HUD overlay's DataTrigger, not an input
      hook (installHudDetector; see AGENTS.md rule 5). The old per-click tree scan
      crashed on character creation's foreign tree (#99).
    - Close a panel from Lua with closeExaminePanel: drive its CustomEvent command
      with a boxed string planted as a XAML resource.
    - Never compare a Noesis object with `== nil` (its __eq crashes on an expired
      object) and never cache one across ticks; fetch fresh and test truthiness.
]]

local Util = Ext.Require("Shared/Util.lua")
local Trace = Ext.Require("Shared/Trace.lua")
local Channels = Ext.Require("Shared/Channels.lua")

local NativeRenameUI = {}

-- Set by BootstrapClient so this module (which owns Examine-panel detection) can drive
-- the settings overlay without a circular require. Both take the panel's PlayerId.
local onGearClickHandler -- fun(id) - called when a panel's gear is clicked
local panelCloseHandler -- fun(id) - called when a panel closes (commit its staged config edits)

local UUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

-- Recursion safety only; every search is anchored at ContentRoot/Examine.
local SEARCH_DEPTH_LIMIT = 80

-- Registered viewmodel type names for our added controls (nested DataContexts).
local GEAR_VM = "NYS_GearVM"
local SKIP_VM = "NYS_SkipVM"
-- The Confirm button viewmodel: a Command + a Bool visibility flag shared with Skip
-- (#queue > 0). The sole commit-and-advance trigger for a multi-summon queue.
local CONFIRM_VM = "NYS_ConfirmVM"

-- The global command surface (ExamineCommand + ~200 other game commands) is inherited onto
-- the always-present "HudIndicator" node; one per viewport in split-screen.
local COMMAND_SURFACE_NODE = "HudIndicator"

-- After opening or swapping a panel, ignore input for this long while the swapped-in field
-- element and its DataContext appear, then wire the fresh field and set its text.
local EXAMINE_SETTLE_MS = 400

-- Debounce for the live name save: commit only once text changes settle, so rapid typing
-- saves once, not per keystroke.
local TEXT_COMMIT_DEBOUNCE_MS = 20

-- Period of the reconcile loop that guards the world-pause while a prompt is pending.
local SAFETY_RECONCILE_MS = 1000

local function safe(fn, ...)
	local ok, res = pcall(fn, ...)
	if ok then
		return res
	end
	if Trace.Enabled() then
		Trace.Log("swallowed", "safe() caught", { Error = tostring(res) })
	end
	return nil
end

---@return string|nil  the client game state ("Running", "Paused", ...), nil when unreadable
local function gameStateName()
	local state = safe(Ext.Utils.GetGameState)
	return state ~= nil and tostring(state) or nil
end

--- Scan only while the world is up: a VisualChild walk on a foreign tree (character creation, #99)
--- or a half-torn-down level can access-violate past pcall. Fails closed on any other or unreadable
--- state; the next heartbeat retries.
---@return boolean
local function scanAllowed()
	local state = gameStateName()
	return state == "Running" or state == "Paused"
end

-- Hoisted out of the per-node walk to avoid a closure per access. VisualChild is 1-based.
local function readName(node)
	return node.Name
end
local function readChildCount(node)
	return node.VisualChildrenCount
end
local function readChild(node, i)
	return node:VisualChild(i)
end

---@param node any
---@return string
local function widgetName(node)
	local name = safe(readName, node)
	return name ~= nil and tostring(name) or ""
end

---@param node any
---@return integer
local function visualChildCount(node)
	local count = safe(readChildCount, node)
	return type(count) == "number" and count or 0
end

--- Depth-first search of the visual tree for the first node (incl. `node`) satisfying
--- `predicate`. Callers anchor by passing ContentRoot or an Examine node.
---@param node any
---@param depth integer
---@param predicate fun(node:any):boolean
---@return any|nil
local function findNode(node, depth, predicate)
	-- `not node`, never `== nil`: an expired Noesis node throws via __eq.
	if not node or depth > SEARCH_DEPTH_LIMIT then
		return nil
	end
	if predicate(node) then
		return node
	end
	for i = 1, visualChildCount(node) do
		local hit = findNode(safe(readChild, node, i), depth + 1, predicate)
		if hit then
			return hit
		end
	end
	return nil
end

--- The first descendant of `root` (incl. `root`) named `name`, or nil.
---@param root any
---@param name string
---@return any|nil
local function findFrom(root, name)
	if not root then
		return nil
	end
	return findNode(root, 0, function(node)
		return widgetName(node) == name
	end)
end

--- The composition root (`ContentRoot`), the anchor for every scan. Fetched fresh (a
--- stale Noesis handle crashes on use).
---@return any|nil
local function contentRoot()
	return findFrom(safe(Ext.UI.GetRoot), "ContentRoot")
end

--- Read a runtime property from a viewmodel's dynamic property bag (bag only:
--- dc:GetProperty warns per missing key and is slow while scanning).
---@param dc any
---@param key string
---@return any
local function dcProp(dc, key)
	local all = safe(function()
		return dc:GetAllProperties()
	end)
	if type(all) == "table" then
		return all[key]
	end
	return nil
end

-- Per-viewport identity.

--- The CurrentPlayer view model on a node's DataContext (each viewport has its own).
---@param node any
---@return any|nil
local function currentPlayerOf(node)
	local dc = node and safe(function()
		return node.DataContext
	end)
	return dc and safe(function()
		return dc:GetProperty("CurrentPlayer")
	end)
end

--- The stable per-viewport key: CurrentPlayer.PlayerId (1, 2, ...), or nil.
---@param node any
---@return integer|nil
local function playerIdOf(node)
	local cp = currentPlayerOf(node)
	local pid = cp and safe(function()
		return cp:GetProperty("PlayerId")
	end)
	return tonumber(pid)
end

--- The character a viewport currently controls (CurrentPlayer.SelectedCharacter.
--- EntityUUID), as a bare uuid, or nil. The client<->server bridge: it equals the
--- server's Osi.GetCurrentCharacter(reservedUser) for that player.
---@param node any
---@return string|nil
local function selectedCharOf(node)
	local cp = currentPlayerOf(node)
	local sc = cp and safe(function()
		return cp:GetProperty("SelectedCharacter")
	end)
	local uuid = sc and safe(function()
		return sc:GetProperty("EntityUUID")
	end)
	return type(uuid) == "string" and Util.ToUuid(uuid) or nil
end

--- CurrentPlayer.SelectedCharacter.EntityUUID off a command-surface DataContext, for
--- matching a HudIndicator to its viewport (used by getExamineCommand).
---@param dc any
---@return string|nil
local function surfaceSelectedChar(dc)
	local cp = dc and safe(function()
		return dc:GetProperty("CurrentPlayer")
	end)
	local sc = cp and safe(function()
		return cp:GetProperty("SelectedCharacter")
	end)
	local uuid = sc and safe(function()
		return sc:GetProperty("EntityUUID")
	end)
	return type(uuid) == "string" and Util.ToUuid(uuid) or nil
end

---@param name string
---@return boolean
local function isExamineName(name)
	return name == "Examine" or name == "Examine_c"
end

--- Visit every open Examine/Examine_c node under ContentRoot (one per viewport with a
--- panel open). Never stops early.
---@param fn fun(node:any)
local function forEachExamineNode(fn)
	findNode(contentRoot(), 0, function(node)
		if isExamineName(widgetName(node)) then
			fn(node)
		end
		return false
	end)
end

--- The open Examine node belonging to viewport `id` (its CurrentPlayer.PlayerId), or nil.
---@param id integer
---@return any|nil
local function examineNodeById(id)
	local found
	findNode(contentRoot(), 0, function(node)
		if isExamineName(widgetName(node)) and playerIdOf(node) == id then
			found = node
			return true
		end
		return false
	end)
	return found
end

--- A live node by x:Name within viewport `id`'s Examine subtree, or nil.
---@param id integer
---@param name string
---@return any|nil
local function findNamedIn(id, name)
	return findFrom(examineNodeById(id), name)
end

--- The rename field of viewport `id`, or nil.
---@param id integer
---@return any|nil
local function liveFieldIn(id)
	return findNamedIn(id, "NYS_NameInput")
end

--- The uuid of the summon shown on viewport `id`'s Examine screen, or nil. Scans that
--- panel's subtree for the first DataContext with an EntityUUID and a "Summon" type.
---@param id integer
---@return string|nil
local function examinedSummonUuidIn(id)
	local examine = examineNodeById(id)
	if examine == nil then
		return nil
	end
	local found
	findNode(examine, 0, function(node)
		local dc = safe(function()
			return node.DataContext
		end)
		if dc == nil then
			return false
		end
		local uuid = dcProp(dc, "EntityUUID")
		if type(uuid) ~= "string" or not uuid:match(UUID_PATTERN) then
			return false
		end
		if tostring(dcProp(dc, "CharacterType")) ~= "Summon" then
			return false
		end
		found = Util.ToUuid(uuid)
		return true
	end)
	return found
end

--- The Text of a node, or "" when unreadable.
---@param node any
---@return string
local function nodeText(node)
	local t = safe(function()
		return node.Text
	end)
	return type(t) == "string" and t or ""
end

-- Per-viewport state, keyed by PlayerId. Naming answers over SubmitName (server clears
-- its pending count and lifts the world-pause); a later edit renames over RenameSummon.
local panels = {} -- id -> state
local openIds = {} -- id -> true, the set of panels currently open (for close detection)

-- AllowStorySummons cached client-side so the forbidden check is synchronous.
local cachedAllowStory = false

---@param id integer
---@return table
local function panelState(id)
	local st = panels[id]
	if not st then
		st = {
			id = id,
			wired = false,
			fieldSubs = {}, -- { { field = node, handle = h }, ... }
			lastSent = nil,
			liveText = nil, -- latest field text seen via TextChanged (commit does not depend on a blur)
			textGen = 0, -- debounce token: bumped per TextChanged so only the last one commits
			editEnabled = false,
			forbidden = false,
			queue = {}, -- AskName requests not yet shown, FIFO
			current = nil, -- the request being examined now, or nil
			answered = false, -- current got a name (SubmitName sent)
			awaitingOpen = false, -- panel opening/swapping; ignore input until it settles
			openGen = 0, -- bumped per open/swap so a superseded settle callback bails
		}
		panels[id] = st
	end
	return st
end

--- Refresh the cached AllowStorySummons setting (async; for the NEXT open).
local function refreshSettingsCache()
	pcall(function()
		Channels.GetSettings:RequestToServer({}, function(response)
			if type(response) == "table" then
				cachedAllowStory = response.AllowStorySummons == true
			end
		end)
	end)
end

-- Forward declarations for the mutually-recursive on-summon flow (and the wire/unwire
-- pair, which reference each other via the deferred swap-rewire).
local showNext, openExamine, answerSession, getExamineCommand, entityHandleFor, unwirePanel

---------------------------------------------------------------------------
-- Rename primitives
---------------------------------------------------------------------------

--- Send a rename for a specific summon uuid. Returns false on empty input or a failed
--- send, so a caller dedupes only a rename that was actually submitted.
---@param uuid string
---@param rawName string
---@return boolean
local function submitRename(uuid, rawName)
	local name = Util.Sanitise(rawName)
	if type(uuid) ~= "string" or name == "" then
		return false
	end
	return pcall(function()
		Channels.RenameSummon:SendToServer({ SummonUuid = uuid, Name = name })
	end)
end

--- The root template of a summon, read client-side (nil if OriginalTemplate is not
--- replicated to the client; caller then fails open to renamable).
---@param uuid string
---@return string|nil
local function clientTemplateOf(uuid)
	local entity = safe(function()
		return Ext.Entity.Get(uuid)
	end)
	if not entity then
		return nil
	end
	local template = safe(function()
		return entity.OriginalTemplate and entity.OriginalTemplate.OriginalTemplate
	end)
	return type(template) == "string" and template or nil
end

--- Whether the summon may not be renamed: a story-bound template with the opt-in off,
--- mirroring the server's HandleSummon gate.
---@param uuid string
---@return boolean
local function isForbiddenSummon(uuid)
	local template = clientTemplateOf(uuid)
	return template ~= nil and Util.IsStorySummon(template) and not cachedAllowStory
end

--- Flip the field between editable and plain text. These flags are checked at input
--- time, not painted, so the change needs no repaint (a manually-opened panel repaints
--- only on a real click).
---@param field any
---@param editable boolean
local function setFieldEditable(field, editable)
	pcall(function()
		field:SetProperty("IsReadOnly", not editable)
	end)
	pcall(function()
		field:SetProperty("Focusable", editable)
	end)
	pcall(function()
		field:SetProperty("IsHitTestVisible", editable)
	end)
end

--- Make viewport `id`'s field editable. Idempotent (guarded by st.editEnabled).
---@param id integer
local function enableEditing(id)
	local st = panelState(id)
	if st.editEnabled then
		return
	end
	local field = liveFieldIn(id)
	if not field then
		return
	end
	setFieldEditable(field, true)
	st.editEnabled = true
end

--- Revert viewport `id`'s field to plain text (a summon that became forbidden while open).
---@param id integer
local function disableEditing(id)
	local st = panelState(id)
	st.editEnabled = false
	local field = liveFieldIn(id)
	if field then
		setFieldEditable(field, false)
	end
end

--- Reset per-summon state for a viewport's new `current` request.
---@param st table
local function beginCurrent(st)
	st.answered = false
	st.lastSent = Util.Sanitise(st.current.DefaultName or "")
end

--- Skip a viewport's current summon (if unnamed) and everything still queued for it, then
--- clear the batch. Called when its panel closes.
---@param st table
local function abortRemaining(st)
	if not st.current and #st.queue == 0 then
		return
	end
	if st.current and not st.answered then
		answerSession(st.current, "", true)
	end
	for _, req in ipairs(st.queue) do
		answerSession(req, "", true)
	end
	st.queue = {}
	st.current = nil
	st.answered = false
end

--- Set viewport `id`'s field text from Lua. The field's Text binding is OneWay and does
--- NOT follow an Examine content swap, so on each swap we write it in directly.
---@param id integer
---@param text string
local function setFieldTextIn(id, text)
	local st = panels[id]
	local field = liveFieldIn(id)
	if not field then
		return
	end
	pcall(function()
		field.Text = text or ""
	end)
	if st then
		st.lastSent = Util.Sanitise(text or "")
	end
end

--- Rename viewport `id`'s examined summon to `field`'s current text. Deduped via
--- st.lastSent. During an on-summon session the first answer goes over SubmitName
--- (decrements the pending count once); a later edit falls through to RenameSummon.
---@param id integer
---@param field any
local function commitField(id, field)
	local st = panels[id]
	if not st or st.awaitingOpen then
		return
	end
	local raw = nodeText(field)
	local name = Util.Sanitise(raw)
	if name == "" or name == st.lastSent then
		return
	end
	local uuid = examinedSummonUuidIn(id)
	if uuid == nil then
		return
	end
	if st.current ~= nil and not st.answered and uuid == st.current.SummonUuid then
		if answerSession(st.current, name) then
			st.lastSent = name
			st.answered = true
		end
		return
	end
	if submitRename(uuid, raw) then
		st.lastSent = name
		Util.Log(("NYS: renamed %s -> '%s'"):format(uuid, name))
	end
end

--- Commit the name the player typed, WITHOUT depending on a focus-loss event (the field's
--- blur is not reliably delivered on controller). TextChanged tracks the latest text in
--- st.liveText; this flushes it at definitive exits - the gear opening or the panel
--- closing. Reads the live field if present (gear open), else the tracked text (closed).
---@param id integer
local function flushName(id)
	local st = panels[id]
	if not st then
		return
	end
	local field = liveFieldIn(id)
	local raw = field and nodeText(field) or st.liveText
	if type(raw) ~= "string" then
		return
	end
	local name = Util.Sanitise(raw)
	if name == "" or name == st.lastSent then
		return
	end
	if st.current ~= nil and not st.answered then
		if answerSession(st.current, name) then
			st.lastSent = name
			st.answered = true
		end
	elseif field then
		local uuid = examinedSummonUuidIn(id)
		if uuid and submitRename(uuid, raw) then
			st.lastSent = name
		end
	end
end

--- Commit viewport `id`'s current summon and advance to the next queued one - the
--- multi-summon advance, driven only by the Confirm button. The name itself is saved live
--- on TextChanged; this also flushes a not-yet-answered name (first answer over SubmitName
--- so the pending count clears, later edits rename), then swaps.
---@param id integer
local function onFieldEnter(id)
	local st = panels[id]
	if not st or not st.current or st.awaitingOpen then
		return
	end
	local field = liveFieldIn(id)
	if not field then
		return
	end
	local raw = nodeText(field)
	local name = Util.Sanitise(raw)
	if not st.answered then
		if name == "" then
			return
		end
		if not answerSession(st.current, name) then
			return
		end
		st.lastSent = name
		st.answered = true
	elseif name ~= "" and name ~= st.lastSent then
		local uuid = examinedSummonUuidIn(id)
		if uuid and submitRename(uuid, raw) then
			st.lastSent = name
		end
	end
	showNext(id)
end

--- The Confirm button handler: commit the current summon and advance. Shown only while a
--- next summon is queued. Single summons, the last of a group, and manual examines have no
--- Confirm and rely on the live TextChanged save.
---@param id integer
local function confirmCurrent(id)
	onFieldEnter(id)
end

--- Skip viewport `id`'s current summon (abort so the server re-asks next cast) and swap
--- to the next. Only shown for a multi-summon group.
---@param id integer
local function skipCurrent(id)
	local st = panels[id]
	if not st or not st.current or st.awaitingOpen then
		return
	end
	if answerSession(st.current, "", true) then
		showNext(id)
	end
end

--- Open the settings overlay for viewport `id` (bound to its gear's NysGearCommand).
--- Opening the gear leaves the field, so commit any typed name first.
---@param id integer
local function onGearClick(id)
	flushName(id)
	if onGearClickHandler then
		onGearClickHandler(id)
	end
end

--- Show viewport `id`'s Skip and Confirm buttons only while a next summon is queued.
--- Refresh both on every queue mutation; fetch fresh, a Noesis handle does not survive.
---@param id integer
local function refreshQueueButtons(id)
	local st = panels[id]
	if not st then
		return
	end
	local show = #st.queue > 0
	for name, prop in pairs({ NYS_SkipButton = "NysShowSkip", NYS_ConfirmButton = "NysShowConfirm" }) do
		local button = findNamedIn(id, name)
		local vm = button and safe(function()
			return button.DataContext
		end)
		if vm then
			pcall(function()
				vm[prop] = show
			end)
		end
	end
end

--- Attach viewport `id`'s gear Command viewmodel and its field's key/focus subscriptions.
--- Idempotent (guarded by st.wired); no-op until the field node exists.
---@param id integer
local function wirePanel(id)
	local st = panelState(id)
	if st.wired then
		return
	end
	-- One anchored walk for the panel node; every named lookup below searches its subtree.
	local examine = examineNodeById(id)
	local field = findFrom(examine, "NYS_NameInput")
	if not field then
		return
	end

	st.lastSent = Util.Sanitise(nodeText(field))

	st.fieldSubs = {}
	local function sub(event, fn)
		local handle = safe(function()
			return field:Subscribe(event, fn)
		end)
		if handle ~= nil then
			st.fieldSubs[#st.fieldSubs + 1] = { field = field, handle = handle }
		end
	end

	-- Save the name on every text change - the one commit path, since the field's blur is
	-- not reliably delivered (esp. on controller). Saving does NOT advance a multi-summon
	-- queue (commitField never calls showNext), so the next creature still needs the button.
	sub("TextChanged", function()
		local pst = panels[id]
		if not pst then
			return
		end
		pst.liveText = nodeText(field)
		-- Debounce so rapid typing saves once, not per keystroke.
		pst.textGen = pst.textGen + 1
		local gen = pst.textGen
		Ext.Timer.WaitForRealtime(TEXT_COMMIT_DEBOUNCE_MS, function()
			local st2 = panels[id]
			if not st2 or st2.textGen ~= gen then
				return
			end
			local f = liveFieldIn(id)
			if f then
				commitField(id, f)
			end
		end)
	end)

	-- Gear: nested DataContext = a fresh NYS_GearVM whose command opens THIS viewport's settings.
	local gear = findFrom(examine, "NYS_SettingsButton")
	if gear then
		local vm = safe(function()
			return Ext.UI.Instantiate(GEAR_VM)
		end)
		if vm then
			pcall(function()
				vm.NysGearCommand:SetHandler(function()
					onGearClick(id)
				end)
			end)
			pcall(function()
				gear.DataContext = vm
			end)
		end
	end

	-- Skip: nested DataContext = a fresh NYS_SkipVM; NysShowSkip hides it for single summons.
	local skip = findFrom(examine, "NYS_SkipButton")
	if skip then
		local vm = safe(function()
			return Ext.UI.Instantiate(SKIP_VM)
		end)
		if vm then
			pcall(function()
				vm.NysSkipCommand:SetHandler(function()
					skipCurrent(id)
				end)
			end)
			pcall(function()
				vm.NysShowSkip = #st.queue > 0
			end)
			pcall(function()
				skip.DataContext = vm
			end)
		end
	end

	-- Confirm: nested DataContext = a fresh NYS_ConfirmVM; the multi-summon advance trigger,
	-- revealed on the same condition as Skip (a next summon is queued).
	local confirm = findFrom(examine, "NYS_ConfirmButton")
	if confirm then
		local vm = safe(function()
			return Ext.UI.Instantiate(CONFIRM_VM)
		end)
		if vm then
			pcall(function()
				vm.NysConfirmCommand:SetHandler(function()
					confirmCurrent(id)
				end)
			end)
			pcall(function()
				vm.NysShowConfirm = #st.queue > 0
			end)
			pcall(function()
				confirm.DataContext = vm
			end)
		end
	end

	st.wired = true

	-- Enable editing for any renamable summon (on-summon or manual); forbidden/non-summon stays plain.
	local summonUuid = examinedSummonUuidIn(id)
	st.forbidden = summonUuid ~= nil and isForbiddenSummon(summonUuid)
	if st.current ~= nil or (summonUuid ~= nil and not st.forbidden) then
		enableEditing(id)
	end
end

--- Drop viewport `id`'s per-element wiring (its field element is destroyed on close/swap,
--- so unsubscribe is best-effort).
---@param id integer
function unwirePanel(id)
	local st = panels[id]
	if not st then
		return
	end
	for _, entry in ipairs(st.fieldSubs) do
		pcall(function()
			entry.field:Unsubscribe(entry.handle)
		end)
	end
	st.fieldSubs = {}
	st.wired = false
	st.editEnabled = false
	st.forbidden = false
end

--- Re-wire the already-open panels after another panel opened. Opening one Examine panel
--- rebuilds the OTHER open panels' field elements in split-screen (a shared re-layout),
--- silently killing our field subscriptions; re-attaching restores their rename commit.
--- `exclude` is the set of freshly-wired panels to leave alone - critically the just-opened
--- panel itself, so single-player (its sole panel is always the new one) is never disturbed.
---@param exclude table|nil  set of panel ids (id -> true) to skip
local function rewireStale(exclude)
	for id in pairs(openIds) do
		local st = panels[id]
		if st and not st.awaitingOpen and not (exclude and exclude[id]) then
			unwirePanel(id)
			wirePanel(id)
		end
	end
end

--- Tear down a closed viewport: unwire, skip whatever remained of its batch, flush its
--- settings overlay, and drop its state.
---@param id integer
local function closePanel(id)
	local st = panels[id]
	if not st then
		return
	end
	-- Closing is a definitive "done": commit a typed-but-unblurred name (the field is gone,
	-- so this uses the text tracked via TextChanged) before aborting the rest.
	flushName(id)
	unwirePanel(id)
	abortRemaining(st)
	if panelCloseHandler then
		pcall(panelCloseHandler, id)
	end
	panels[id] = nil
end

--- Reconcile our per-viewport state with the live tree: wire every open panel (that is not
--- mid-open) and tear down any that closed. Returns the set of open ids.
---@return table
local function pollLifecycle()
	if not scanAllowed() then
		return {}
	end
	local present = {}
	local newIds = nil
	forEachExamineNode(function(node)
		local id = playerIdOf(node)
		if id ~= nil then
			present[id] = true
			if not openIds[id] then
				newIds = newIds or {}
				newIds[id] = true
			end
			local st = panelState(id)
			if not st.awaitingOpen then
				wirePanel(id)
			end
		end
	end)
	for id in pairs(openIds) do
		if not present[id] then
			closePanel(id)
		end
	end
	openIds = present
	-- A newly-appeared panel rebuilds the OTHER open panels' field elements, so re-wire the
	-- already-open panels once it settles - excluding the new ones (leaving single-player's
	-- sole panel untouched). Covers a manually opened second panel.
	if newIds then
		local exclude = newIds
		Ext.Timer.WaitForRealtime(EXAMINE_SETTLE_MS, function()
			rewireStale(exclude)
		end)
	end
	return present
end

local safetyArmed = false

--- Whether any viewport still has an unanswered prompt (current or queued).
---@return boolean
local function anyPromptPending()
	for _, st in pairs(panels) do
		if st.current ~= nil or #st.queue > 0 then
			return true
		end
	end
	return false
end

--- Reconcile on a slow clock while a prompt is pending so a missed close cannot leave the server
--- paused forever; self-disarms once nothing is pending.
local function armSafetyReconcile()
	if safetyArmed then
		return
	end
	safetyArmed = true
	local function tick()
		if not anyPromptPending() then
			safetyArmed = false
			return
		end
		pollLifecycle()
		Ext.Timer.WaitForRealtime(SAFETY_RECONCILE_MS, tick)
	end
	Ext.Timer.WaitForRealtime(SAFETY_RECONCILE_MS, tick)
end

-- Opening Examine on a specific creature and viewport.

--- The game's ExamineCommand off a HUD command surface, returned fresh (never cached). In
--- split-screen there is one HudIndicator per viewport; `matchChar` selects that player's
--- surface. Falls back to the first surface for single-player / no match.
---@param matchChar string|nil
---@return any|nil
function getExamineCommand(matchChar)
	local firstCmd, matchedCmd
	findNode(contentRoot(), 0, function(node)
		if widgetName(node) ~= COMMAND_SURFACE_NODE then
			return false
		end
		local dc = safe(function()
			return node.DataContext
		end)
		local cmd = dc and safe(function()
			return dc:GetProperty("ExamineCommand")
		end)
		if not cmd then
			return false
		end
		if not firstCmd then
			firstCmd = cmd
		end
		if matchChar and surfaceSelectedChar(dc) == Util.ToUuid(matchChar) then
			matchedCmd = cmd
			return true
		end
		return false
	end)
	return matchedCmd or firstCmd
end

--- The Noesis EntityHandle for a summon uuid, off any live per-entity DataContext.
---@param uuid string
---@return any|nil
function entityHandleFor(uuid)
	local handle
	findNode(contentRoot(), 0, function(node)
		local dc = safe(function()
			return node.DataContext
		end)
		if not dc then
			return false
		end
		local id = dcProp(dc, "EntityUUID")
		if type(id) ~= "string" or Util.ToUuid(id) ~= uuid then
			return false
		end
		handle = safe(function()
			return dc:GetProperty("EntityHandle")
		end)
		return handle and true or false
	end)
	return handle
end

--- The PlayerId of the viewport currently controlling `char` (its SelectedCharacter), or
--- nil. Scans the always-present HUD surfaces plus any open Examine panels.
---@param char string|nil
---@return integer|nil
local function viewportIdForChar(char)
	if type(char) ~= "string" then
		return nil
	end
	local want = Util.ToUuid(char)
	local found
	findNode(contentRoot(), 0, function(node)
		local name = widgetName(node)
		if name ~= COMMAND_SURFACE_NODE and not isExamineName(name) then
			return false
		end
		if selectedCharOf(node) == want then
			found = playerIdOf(node)
			return found ~= nil
		end
		return false
	end)
	return found
end

--- Answer a session over SubmitName so the server saves the name (and clears its pending
--- count, lifting the pause), or (empty name + abort) re-asks next summon.
---@param req table
---@param name string
---@param abort boolean|nil
---@return boolean
function answerSession(req, name, abort)
	return pcall(function()
		Channels.SubmitName:SendToServer({
			Key = req.Key,
			SummonUuid = req.SummonUuid,
			Scope = req.Scope,
			Slot = req.Slot,
			Name = name,
			Abort = abort or nil,
		})
	end)
end

--- Execute Examine on `req`'s summon and viewport: opens the panel or swaps its content.
--- Returns whether it opened; the caller skips the summon otherwise so the pause never hangs.
---@param req table
---@return boolean
function openExamine(req)
	local command = getExamineCommand(req.ViewportChar)
	local handle = entityHandleFor(req.SummonUuid)
	local canExec = nil
	local opened = command
		and handle
		and pcall(function()
			-- A disabled command Executes as a silent no-op, hanging the pause; guard with CanExecute.
			canExec = command:CanExecute(handle)
			assert(canExec)
			command:Execute(handle)
		end)
	if not opened then
		Util.Warn(
			("Could not open Examine for summon %s (command=%s handle=%s canExecute=%s); skipping."):format(
				tostring(req.SummonUuid),
				tostring(command and true or false),
				tostring(handle and true or false),
				tostring(canExec)
			)
		)
	end
	return opened and true or false
end

--- Show viewport `id`'s next queued request by swapping its panel (or opening the first).
--- The outgoing current must already be resolved. An empty queue leaves the panel on the
--- last creature. A summon that cannot be opened is skipped so the pause never hangs.
---@param id integer
function showNext(id)
	local st = panelState(id)
	st.current = table.remove(st.queue, 1)
	if not st.current then
		return
	end
	beginCurrent(st)
	-- Execute on an already-open panel swaps in a fresh field element; drop the prior
	-- wiring, the settle below re-wires the new field.
	unwirePanel(id)
	st.openGen = st.openGen + 1
	local gen = st.openGen
	st.awaitingOpen = true
	if not openExamine(st.current) then
		st.awaitingOpen = false
		if answerSession(st.current, "", true) then
			showNext(id)
		end
		return
	end
	Ext.Timer.WaitForRealtime(EXAMINE_SETTLE_MS, function()
		if gen ~= st.openGen then
			return
		end
		st.awaitingOpen = false
		if not st.current then
			-- A retract cleared current while this settle was pending; show any AskName queued
			-- meanwhile, else nothing is left and the panel is already closing.
			if #st.queue > 0 then
				showNext(id)
			end
			return
		end
		-- pollLifecycle may notice the panel closed and clear the batch, so re-check current.
		pollLifecycle()
		-- Opening this viewport's panel rebuilt the OTHER open panels' field elements, so
		-- re-attach their subscriptions or their rename would never commit; never touch this one.
		rewireStale({ [id] = true })
		if st.current then
			setFieldTextIn(id, st.current.DefaultName)
		end
	end)
end

-- Closing Examine from Lua: its close runs the "CloseWidget" state event through the widget's
-- CustomEvent command, whose parameter must be a BOXED Noesis string - we plant a
-- <System:String x:Key="NYS_CloseWidget"> resource in Examine.xaml and read it back live via
-- element:Resource(). See AGENTS.md.
local CLOSE_WIDGET_RESOURCE = "NYS_CloseWidget"

--- Close viewport `id`'s open Examine panel; true if the close command was issued.
---@param id integer
---@return boolean
local function closeExaminePanel(id)
	local examine = examineNodeById(id)
	if not examine then
		return false
	end
	local command = safe(function()
		return examine.DataContext:GetProperty("CustomEvent")
	end)
	local param = safe(function()
		return examine:Resource(CLOSE_WIDGET_RESOURCE)
	end)
	if not command or not param then
		return false
	end
	return pcall(function()
		assert(command:CanExecute(param))
		command:Execute(param)
	end) == true
end

-- Public interface (NativeConfigUI owns the settings overlay; wired in BootstrapClient).

--- Find a live node by x:Name within viewport `id`'s Examine subtree.
---@param id integer
---@param name string
---@return any|nil
function NativeRenameUI.FindNamedIn(id, name)
	return findNamedIn(id, name)
end

--- The character the viewer of viewport `id` controls, for scoping its saved-name list to
--- that player. nil when unresolvable (the server then shows all).
---@param id integer
---@return string|nil
function NativeRenameUI.ViewerOf(id)
	return selectedCharOf(examineNodeById(id))
end

--- Wire the gear-click action (opens the native settings overlay for a viewport).
---@param fn fun(id:integer)
function NativeRenameUI.SetGearHandler(fn)
	onGearClickHandler = fn
end

--- Wire the panel-close action (commits a viewport's settings overlay staged edits).
---@param fn fun(id:integer)
function NativeRenameUI.SetPanelCloseHandler(fn)
	panelCloseHandler = fn
end

local DETECT_VM = "NYS_DetectVM"
local HUD_WIRE_HEARTBEAT_MS = 1000
local hudInstalled = false
local reconcileGen = 0 -- bumped per signal so a newer change supersedes older retries

--- Detected by a `NysWired` Bool marker prop, not the Command (reading a Command back is unreliable).
---@param host any
---@return boolean
local function hostIsWired(host)
	local dc = host and safe(function()
		return host.DataContext
	end)
	return (dc and dcProp(dc, "NysWired")) == true
end

--- The panel widget lags the examine target, so reconcile on a short bounded retry (gen-deduped).
--- Manual panels are unwired first so a re-open re-subscribes; an active on-summon session is left alone.
local function onExamineDetected()
	reconcileGen = reconcileGen + 1
	local gen = reconcileGen
	for id, st in pairs(panels) do
		if st.wired and st.current == nil then
			unwirePanel(id)
		end
	end
	local function pass(triesLeft)
		if gen ~= reconcileGen then
			return
		end
		pollLifecycle()
		if triesLeft > 0 then
			Ext.Timer.WaitForRealtime(100, function()
				pass(triesLeft - 1)
			end)
		end
	end
	pass(6)
end

---@param host any
local function wireHost(host)
	local vm = safe(function()
		return Ext.UI.Instantiate(DETECT_VM)
	end)
	if not vm then
		return
	end
	pcall(function()
		vm.NysDetectCommand:SetHandler(onExamineDetected)
	end)
	pcall(function()
		vm.NysWired = true
	end)
	pcall(function()
		host.DataContext = vm
	end)
end

--- Split-screen gives each viewport its own PlayerHUD, so its own NysHudOverlay: wire every host
--- or a player's manual Examine goes undetected.
local function ensureOverlaysWired()
	findNode(contentRoot(), 0, function(node)
		if widgetName(node) == "NYS_HudVmHost" and not hostIsWired(node) then
			wireHost(node)
		end
		return false -- always false: visit every host, wiring as a side effect
	end)
end

--- The HUD is rebuilt with no event on session load and input-mode switch, so a heartbeat is the
--- only reliable re-wire.
local function installHudDetector()
	if hudInstalled then
		return
	end
	hudInstalled = true
	pcall(function()
		Ext.UI.RegisterType(DETECT_VM, {
			NysDetectCommand = { Type = "Command" },
			NysWired = { Type = "Bool", Notify = true },
		})
	end)
	local function heartbeat()
		if scanAllowed() then
			ensureOverlaysWired()
		end
		Ext.Timer.WaitForRealtime(HUD_WIRE_HEARTBEAT_MS, heartbeat)
	end
	heartbeat()
end

function NativeRenameUI.Register()
	pcall(function()
		Ext.UI.RegisterType(GEAR_VM, { NysGearCommand = { Type = "Command" } })
	end)
	pcall(function()
		Ext.UI.RegisterType(SKIP_VM, { NysSkipCommand = { Type = "Command" }, NysShowSkip = { Type = "Bool" } })
	end)
	pcall(function()
		Ext.UI.RegisterType(
			CONFIRM_VM,
			{ NysConfirmCommand = { Type = "Command" }, NysShowConfirm = { Type = "Bool" } }
		)
	end)

	-- Seed cachedAllowStory: a fresh boot has not loaded persisted ModVars at Register, so
	-- SessionLoaded honours a saved opt-in; the immediate call covers a Lua `reset` reload.
	refreshSettingsCache()
	pcall(function()
		Ext.Events.SessionLoaded:Subscribe(refreshSettingsCache)
	end)

	-- The setting changed; refresh the cache and re-evaluate every open panel so a summon
	-- that just became forbidden reverts to plain text at once.
	Channels.SettingsChanged:SetHandler(function(data, _user)
		if type(data) ~= "table" then
			return
		end
		cachedAllowStory = data.AllowStorySummons == true
		for id, st in pairs(panels) do
			if st.wired then
				local uuid = examinedSummonUuidIn(id)
				st.forbidden = uuid ~= nil and isForbiddenSummon(uuid)
				if st.forbidden and st.editEnabled then
					disableEditing(id)
				end
			end
		end
	end)

	-- A summon renamed from elsewhere will not repaint on a manually-opened panel, so write the
	-- new text into the on-screen field ourselves. An active session manages its own field.
	Channels.SummonRenamed:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.SummonUuid) ~= "string" or type(data.Name) ~= "string" then
			return
		end
		for id, st in pairs(panels) do
			if not st.awaitingOpen and st.current == nil then
				local examined = examinedSummonUuidIn(id)
				if examined ~= nil and Util.ToUuid(examined) == Util.ToUuid(data.SummonUuid) then
					setFieldTextIn(id, data.Name)
				end
			end
		end
	end)

	-- The server asks the summoner's client to name a summon; route it to that viewport's queue
	-- and open Examine on it.
	Channels.AskName:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" or type(data.SummonUuid) ~= "string" then
			return
		end
		local id = viewportIdForChar(data.ViewportChar) or 1
		local st = panelState(id)
		table.insert(st.queue, data)
		armSafetyReconcile()
		if st.current == nil and not st.awaitingOpen then
			showNext(id)
		else
			-- A sibling arrived while a session is active: reveal Skip and Confirm.
			refreshQueueButtons(id)
		end
	end)

	-- The server retracted a prompt (a skip-mode sibling revealed an already-resolved group):
	-- its pending is cleared, so answer nothing. Drop it from whichever viewport's queue holds it;
	-- if it is on-screen, swap to the next or close that panel. Do NOT abort it.
	Channels.RetractPrompt:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		local key = data.Key
		for id, st in pairs(panels) do
			for i = #st.queue, 1, -1 do
				if st.queue[i].Key == key then
					table.remove(st.queue, i)
				end
			end
			if st.current ~= nil and st.current.Key == key then
				if #st.queue > 0 then
					showNext(id)
				else
					st.current = nil
					st.answered = false
					closeExaminePanel(id)
					-- Nothing pending, so no other tick follows; reconcile once the close settles.
					Ext.Timer.WaitForRealtime(2 * EXAMINE_SETTLE_MS, pollLifecycle)
				end
			else
				refreshQueueButtons(id)
			end
		end
	end)

	installHudDetector()
end

return NativeRenameUI
