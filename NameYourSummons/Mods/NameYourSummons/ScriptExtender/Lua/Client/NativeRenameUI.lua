-- SPDX-License-Identifier: MIT
--[[
    Client side of the native "rename this summon" control (GH #9, #19, #50, #51, #86).

    The examined creature's uuid is read from the Examine panel's Noesis
    DataContext (EntityUUID + CharacterType) and a rename is sent to the server.

    Per-viewport (GH #86): local split-screen has ONE shared client Lua state but
    up to one Examine panel PER viewport open at once. Each panel carries its own
    CurrentPlayer (a distinct PlayerId 1/2 and the viewer's SelectedCharacter), so
    all panel state - wiring, the rename field, the gear, and the on-summon naming
    queue - is keyed by PlayerId (`panels[id]`). Every node lookup is scoped to a
    given panel (`examineNodeById`, `findNamedIn`, `liveFieldIn`) so two players can
    examine, name, and open settings independently. The server routes an on-summon
    prompt to a viewport by sending ViewportChar (the summoner's controlled
    character); the client matches it to a panel via CurrentPlayer.SelectedCharacter.

    Native-UI approach (see docs/bg3-modding-toolchain.md and AGENTS.md):
    - Controls WE add to the Examine panel are driven by per-element MVVM, not by
      global mouse hit-testing: the gear is an `ls:LSButton` whose `Command` binds to
      a small viewmodel we set as its nested DataContext; the name field commits via
      its own per-element key/focus subscriptions.
    - There is no panel-open event (Ext.UI.GetStateMachine() is nil), so ONE global
      mouse hook (and one controller-button hook) remain as the sole lifecycle
      detectors (panels present in the tree = open).
    - Close a panel from Lua with closeExaminePanel (GH #54): drive its CustomEvent
      command with a boxed string planted as a XAML resource.
    - Never compare a Noesis object with `== nil` (its __eq crashes on an expired
      object) and never cache one across ticks; fetch fresh and test truthiness.
]]

local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")

local NativeRenameUI = {}

-- Set by BootstrapClient so this module (which owns Examine-panel detection) can
-- drive the native settings overlay without a circular require. Both take the
-- PlayerId of the panel the gear/close happened on (GH #86).
local onGearClickHandler -- fun(id) - called when a panel's gear is clicked
local panelCloseHandler -- fun(id) - called when a panel closes (commit its staged config edits)

-- Verbose tracing of the Examine gear/field/naming flow; off by default, toggle at
-- runtime from the client console with `!nys_uidebug`.
local diagEnabled = false
local function log(...)
	if diagEnabled then
		Util.Log("NYS-UI:", ...)
	end
end

local UUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"

-- Recursion safety only. Every search below is ANCHORED at ContentRoot/Examine, so
-- it never walks the whole tree; this bound just stops a pathological cycle.
local SEARCH_DEPTH_LIMIT = 80

-- Registered viewmodel type names for our added controls (nested DataContexts).
local GEAR_VM = "NYS_GearVM"
local SKIP_VM = "NYS_SkipVM"
-- The Confirm button viewmodel (GH #80): a Command + a Bool visibility flag shared with Skip
-- (#queue > 0). It is the sole commit-and-advance trigger for a multi-summon queue - the field's
-- focus-loss blur was removed as an advance path (unreliable on controller; GH #86).
local CONFIRM_VM = "NYS_ConfirmVM"

-- The global command surface (ExamineCommand + ~200 other game commands) is inherited
-- onto the always-present "HudIndicator" node; one per viewport in split-screen (GH #50, #86).
local COMMAND_SURFACE_NODE = "HudIndicator"

-- After opening or swapping a panel, ignore input for SETTLE_MS while the swapped-in
-- field element and its DataContext appear, then wire the fresh field and set its text.
local EXAMINE_SETTLE_MS = 400

-- Debounce for the live name save: commit only once text changes settle (this long after the
-- last TextChanged), so rapid typing saves once, not per keystroke (GH #86).
local TEXT_COMMIT_DEBOUNCE_MS = 20

local function safe(fn, ...)
	local ok, res = pcall(fn, ...)
	if ok then
		return res
	end
	return nil
end

-- Hoisted out of the per-node walk so it does not allocate a closure per access.
-- VisualChild is 1-based (bg3se GetVisualChild).
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

--- Depth-first search of the visual tree for the first node (incl. `node`)
--- satisfying `predicate`. Callers ANCHOR the search by passing ContentRoot or an
--- Examine node as `node`, so it only ever walks that subtree.
---@param node any
---@param depth integer
---@param predicate fun(node:any):boolean
---@return any|nil
local function findNode(node, depth, predicate)
	if node == nil or depth > SEARCH_DEPTH_LIMIT then
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
	if root == nil then
		return nil
	end
	return findNode(root, 0, function(node)
		return widgetName(node) == name
	end)
end

--- The composition root (`ContentRoot`), the cheap anchor for every scan. Fetched
--- fresh (a stale Noesis handle crashes on use); the search is shallow.
---@return any|nil
local function contentRoot()
	return findFrom(safe(Ext.UI.GetRoot), "ContentRoot")
end

--- Read a runtime property from a view model's dynamic property bag (bag only:
--- dc:GetProperty warns per missing key and is slow while scanning, GH #50).
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

---------------------------------------------------------------------------
-- Per-viewport identity (GH #86)
---------------------------------------------------------------------------

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
--- EntityUUID), as a bare uuid, or nil. This is the client<->server bridge: it equals
--- the server's Osi.GetCurrentCharacter(reservedUser) for that player (GH #86).
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

--- Visit every open Examine/Examine_c node under ContentRoot (there is one per
--- viewport with a panel open). Never stops early.
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

---------------------------------------------------------------------------
-- Per-viewport state
---------------------------------------------------------------------------
--
-- Each viewport with a panel has an entry here, keyed by PlayerId. Naming answers over
-- SubmitName (server clears its pending count and lifts the world-pause); a later edit
-- renames idempotently over RenameSummon.
local panels = {} -- id -> state
local openIds = {} -- id -> true, the set of panels currently open (for close detection)

-- AllowStorySummons cached client-side so the forbidden check is synchronous (GH #48).
local cachedAllowStory = false

---@param id integer
---@return table
local function panelState(id)
	local st = panels[id]
	if not st then
		st = {
			id = id,
			controller = false,
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

--- A snapshot of a viewport's state for tracing (skipped unless tracing is on).
---@param id integer
---@return string
local function uiState(id)
	if not diagEnabled then
		return ""
	end
	local st = panels[id]
	if not st then
		return "[id=" .. tostring(id) .. " no-state]"
	end
	return string.format(
		"[id=%s examine=%s field=%s wired=%s | current=%s answered=%s awaitingOpen=%s queued=%d]",
		tostring(id),
		tostring(examineNodeById(id) ~= nil),
		tostring(liveFieldIn(id) ~= nil),
		tostring(st.wired),
		st.current and st.current.SummonUuid or "none",
		tostring(st.answered),
		tostring(st.awaitingOpen),
		#st.queue
	)
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

-- Forward declarations for the mutually-recursive on-summon flow.
local showNext, openExamine, answerSession, getExamineCommand, entityHandleFor

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
--- mirroring the server's HandleSummon gate (GH #48).
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
	log("enableEditing", uiState(id))
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
	log("disableEditing", uiState(id))
end

--- Reset per-summon state for a viewport's new `current` request.
---@param st table
local function beginCurrent(st)
	st.answered = false
	st.lastSent = Util.Sanitise(st.current.DefaultName or "")
end

--- Skip a viewport's current summon (if unnamed) and everything still queued for it, then
--- clear the batch. Called when its panel closes: closing means "skip the rest".
---@param st table
local function abortRemaining(st)
	if not st.current and #st.queue == 0 then
		return
	end
	log("abortRemaining: current =", st.current and st.current.SummonUuid or "none", "queued =", #st.queue)
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
--- NOT follow an Examine content swap (GH #51), so on each swap we write it in directly.
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
--- st.lastSent. During an active on-summon session the first answer goes over SubmitName
--- (decrements the server's pending count once); a later edit falls through to the
--- idempotent RenameSummon path.
---@param id integer
---@param field any
local function commitField(id, field)
	local st = panels[id]
	if not st or st.awaitingOpen then
		return
	end
	local raw = nodeText(field)
	local name = Util.Sanitise(raw)
	log("commitField: text =", name, "lastSent =", st.lastSent)
	if name == "" or name == st.lastSent then
		return
	end
	local uuid = examinedSummonUuidIn(id)
	log("commitField: id =", id, "examined uuid =", uuid, "session =", st.current and st.current.SummonUuid or "none")
	if uuid == nil then
		return
	end
	if st.current ~= nil and not st.answered and uuid == st.current.SummonUuid then
		if answerSession(st.current, name) then
			st.lastSent = name
			st.answered = true
		end
		log("commitField: on-summon answered =", st.answered)
		return
	end
	if submitRename(uuid, raw) then
		st.lastSent = name
		Util.Log(("NYS: renamed %s -> '%s'"):format(uuid, name))
	end
end

--- Commit the name the player typed, WITHOUT depending on a focus-loss event. The field's
--- blur (LostFocus/LostKeyboardFocus) is not reliably delivered on controller, so a rename
--- must not hinge on it (GH #86): TextChanged is reliable, so we track the latest text in
--- st.liveText and flush it here at definitive exits - the gear opening or the panel closing.
--- Reads the live field if still present (gear open), else the tracked text (panel closed).
--- Deduped via st.lastSent; a first on-summon answer goes over SubmitName, a later edit renames.
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
			log("flushName: answered on-summon", id, name)
		end
	elseif field then
		local uuid = examinedSummonUuidIn(id)
		if uuid and submitRename(uuid, raw) then
			st.lastSent = name
			log("flushName: renamed", id, name)
		end
	end
end

--- Commit viewport `id`'s current summon and advance to the next queued one. This is the
--- multi-summon advance, driven ONLY by the Confirm button (confirmCurrent) - the field's blur
--- is no longer an advance path (unreliable on controller; GH #80, #86). The name itself is
--- saved live on TextChanged; this also flushes a not-yet-answered name (first answer over
--- SubmitName so the server's pending count clears, later edits rename), then swaps.
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
	log("onFieldEnter: advancing", uiState(id))
	showNext(id)
end

--- The Confirm button handler (GH #80): commit the current summon and advance. Shown only while
--- a next summon is queued, so it is the multi-summon advance trigger; a keyboard player uses
--- the same button. Single summons, the last of a group, and manual examines have no Confirm and
--- rely on the live TextChanged save (GH #86).
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
	log("skipCurrent:", st.current.SummonUuid)
	if answerSession(st.current, "", true) then
		showNext(id)
	end
end

--- Open the native settings overlay for viewport `id` (bound to its gear's NysGearCommand).
--- Opening the gear leaves the name field, so commit any typed name first - the field's own
--- blur may not fire on controller (GH #86).
---@param id integer
local function onGearClick(id)
	log("onGearClick -> settings overlay for viewport", id)
	flushName(id)
	if onGearClickHandler then
		onGearClickHandler(id)
	end
end

--- Show viewport `id`'s Skip and Confirm buttons only while a next summon is queued (GH #80).
--- Refresh both live on every queue mutation; fetch fresh, a Noesis handle does not survive.
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
	local field = liveFieldIn(id)
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
	-- Save the name on every text change - this is the ONE commit path (GH #86). The field's
	-- focus-loss blur is not reliably delivered (esp. on controller), so a rename must not
	-- hinge on it; TextChanged is reliable. Saving does NOT advance a multi-summon queue -
	-- commitField never calls showNext, so the next creature still needs the explicit button.
	sub("TextChanged", function()
		local pst = panels[id]
		if not pst then
			return
		end
		pst.liveText = nodeText(field)
		-- Debounce: commit once typing settles (TEXT_COMMIT_DEBOUNCE_MS after the last change),
		-- so rapid typing saves once, not per keystroke. Saving never advances a multi-summon
		-- queue - commitField does not call showNext, so the next creature still needs the
		-- explicit button (GH #86).
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
	local gear = findNamedIn(id, "NYS_SettingsButton")
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
	local skip = findNamedIn(id, "NYS_SkipButton")
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
	-- revealed on the same condition as Skip (a next summon is queued) (GH #80).
	local confirm = findNamedIn(id, "NYS_ConfirmButton")
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
	log("wirePanel: wired", #st.fieldSubs, "field subs", uiState(id))

	-- An on-summon prompt (current ~= nil) is the server asking for a name, so enable editing
	-- now; a manually examined summon stays plain text until a click, except on the controller
	-- layout where there is no click (GH #6).
	local summonUuid = examinedSummonUuidIn(id)
	st.forbidden = summonUuid ~= nil and isForbiddenSummon(summonUuid)
	if st.current ~= nil or (not st.forbidden and st.controller) then
		enableEditing(id)
	end
end

--- Drop viewport `id`'s per-element wiring (its field element is destroyed on close/swap,
--- so unsubscribe is best-effort).
---@param id integer
local function unwirePanel(id)
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

--- Re-wire the ALREADY-open panels after another panel opened. Opening/swapping one
--- Examine panel rebuilds the OTHER open panels' field elements in split-screen (a shared
--- re-layout), silently killing our field subscriptions on them; re-attaching restores
--- their rename commit (GH #86). `exclude` is the set of freshly-wired panels to leave
--- ALONE - critically the just-opened panel itself, so single-player (its sole panel is
--- always the new one) is never disturbed. A panel mid-open is skipped too.
---@param exclude table|nil  set of panel ids (id -> true) to skip
local function rewireStale(exclude)
	for id in pairs(openIds) do
		local st = panels[id]
		if st and not st.awaitingOpen and not (exclude and exclude[id]) then
			log("rewire panel (relayout):", id)
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
	log("closePanel:", id, uiState(id))
	-- Closing the panel is a definitive "done": commit a typed-but-unblurred name (the field
	-- is gone now, so this uses the text tracked via TextChanged) before aborting the rest (GH #86).
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
			st.controller = widgetName(node) == "Examine_c"
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
	-- A newly-appeared panel rebuilds the OTHER open panels' field elements (shared
	-- split-screen re-layout), so re-wire the already-open panels once it settles - EXCLUDING
	-- the new ones (the just-appeared panel is freshly wired; in single-player it is the only
	-- panel, which must be left untouched or its own rename breaks). Covers a manually opened
	-- second panel, where there is no on-summon settle to re-attach the first (GH #86).
	if newIds then
		local exclude = newIds
		Ext.Timer.WaitForRealtime(EXAMINE_SETTLE_MS, function()
			rewireStale(exclude)
		end)
	end
	return present
end

--- Global left-click hook - a lifecycle detector only (there is no panel-open event; it
--- does NOT hit-test the gear/close/field, which are per-element bindings). The mouse
--- cannot say which viewport was clicked, so a click that starts editing enables it on
--- every open renamable manual panel (harmless; the focus lands on the clicked one).
---@param e any
local function onMouseButton(e)
	local pressed = safe(function()
		return e.Pressed
	end)
	local button = safe(function()
		return e.Button
	end)
	if pressed ~= true or button ~= 1 then
		return
	end
	local present = pollLifecycle()
	for id in pairs(present) do
		local st = panels[id]
		if st and st.current == nil and not st.editEnabled and not st.forbidden then
			enableEditing(id)
		end
	end
	-- A click may start a close animation not yet reflected in the tree; reconcile once
	-- after it settles. One-shot, not a poll loop.
	if next(present) ~= nil or next(panels) ~= nil then
		Ext.Timer.WaitForRealtime(2 * EXAMINE_SETTLE_MS, pollLifecycle)
	end
end

--- Global controller-button hook - the controller-layout counterpart of onMouseButton
--- (MouseButtonInput never fires on a controller and there is no panel-open event). It
--- reconciles the tree; wirePanel enables editing for a renamable manual summon on
--- controller. It ALWAYS re-polls after a settle because the button that OPENS Examine fires
--- this while the panel is still mid-open and a stick-only navigation produces no further
--- events.
---@param e any
local function onControllerButton(e)
	local pressed = safe(function()
		return e.Pressed
	end)
	if pressed ~= true then
		return
	end
	pollLifecycle()
	Ext.Timer.WaitForRealtime(2 * EXAMINE_SETTLE_MS, pollLifecycle)
end

---------------------------------------------------------------------------
-- Opening Examine on a specific creature and viewport (GH #19, #50, #51, #86)
---------------------------------------------------------------------------

--- The game's ExamineCommand off a HUD command surface, returned fresh (never cached).
--- In split-screen there is one HudIndicator per viewport; `matchChar` (the summoner's
--- controlled character) selects that player's surface so Examine opens on the right side
--- (GH #86). Falls back to the first surface for single-player / no match.
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
--- nil. Scans the always-present HUD surfaces plus any open Examine panels (GH #86).
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
--- count, lifting the pause), or (empty name + abort) re-asks next summon. pcall success.
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

--- Execute Examine on `req`'s summon and viewport: opens the panel or SWAPS its content
--- (C4). Returns whether it opened; the caller skips the summon otherwise so the pause
--- never hangs.
---@param req table
---@return boolean
function openExamine(req)
	local command = getExamineCommand(req.ViewportChar)
	local handle = entityHandleFor(req.SummonUuid)
	log("openExamine:", req.SummonUuid, "command =", command and true or false, "handle =", handle and true or false)
	local canExec = nil
	local opened = command
		and handle
		and pcall(function()
			-- A disabled command Executes as a silent no-op, hanging the pause; CanExecute guards it.
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
	log("showNext:", id, "next =", st.current and st.current.SummonUuid or "none", "queued =", #st.queue)
	if not st.current then
		return
	end
	beginCurrent(st)
	-- Execute on an already-open panel swaps in a fresh field element (C4); drop the prior
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
		-- re-attach their subscriptions or their rename would never commit; never touch this
		-- panel itself (GH #86).
		rewireStale({ [id] = true })
		if st.current then
			setFieldTextIn(id, st.current.DefaultName)
		end
	end)
end

-- Closing Examine from Lua (GH #54): its close runs the "CloseWidget" state event through
-- the widget's CustomEvent command, whose parameter must be a BOXED Noesis string - we
-- plant a <System:String x:Key="NYS_CloseWidget"> resource in the Examine.xaml override and
-- read it back live via element:Resource(). See AGENTS.md.
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

---------------------------------------------------------------------------
-- Public interface (NativeConfigUI owns the settings overlay; wired in BootstrapClient)
---------------------------------------------------------------------------

--- Find a live node by x:Name within viewport `id`'s Examine subtree (so NativeConfigUI
--- resolves its overlay fresh at the moment it binds it, scoped to the opening panel).
---@param id integer
---@param name string
---@return any|nil
function NativeRenameUI.FindNamedIn(id, name)
	return findNamedIn(id, name)
end

--- The character the viewer of viewport `id` controls, for scoping its saved-name list
--- to that player (GH #86). nil when unresolvable (the server then shows all).
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

-- Event names confirmed against bg3se source (LuaClient.cpp ThrowEvent "MouseButtonInput");
-- the IDE helper's "EclLua*" names are stale for this build, and Ext.Events is not enumerable.
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

	pcall(function()
		Ext.Events.MouseButtonInput:Subscribe(onMouseButton)
	end)
	-- Controller-layout lifecycle detector (GH #6); wrapped so a wrong event name cannot tear
	-- down the module.
	pcall(function()
		Ext.Events.ControllerButtonInput:Subscribe(onControllerButton)
	end)

	-- Seed cachedAllowStory (GH #48): a fresh boot has not loaded persisted ModVars at Register,
	-- so SessionLoaded honours a saved opt-in; the immediate call covers a Lua `reset` reload.
	refreshSettingsCache()
	pcall(function()
		Ext.Events.SessionLoaded:Subscribe(refreshSettingsCache)
	end)

	-- The setting changed (config UI); refresh the cache and re-evaluate every open panel so a
	-- summon that just became forbidden reverts to plain text at once (GH #48).
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

	-- A summon renamed from elsewhere (the settings panel) will not repaint on a manually-opened
	-- panel, so write the new text into the on-screen field ourselves (GH #76). An active session
	-- manages its own field.
	Channels.SummonRenamed:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.SummonUuid) ~= "string" or type(data.Name) ~= "string" then
			return
		end
		for id, st in pairs(panels) do
			if not st.awaitingOpen and st.current == nil then
				local examined = examinedSummonUuidIn(id)
				if examined ~= nil and Util.ToUuid(examined) == Util.ToUuid(data.SummonUuid) then
					log("SummonRenamed: refreshing viewport", id, "field to", data.Name)
					setFieldTextIn(id, data.Name)
				end
			end
		end
	end)

	-- The server asks the summoner's client to name a summon; route it to that viewport's queue
	-- and open Examine on it (GH #86).
	Channels.AskName:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" or type(data.SummonUuid) ~= "string" then
			return
		end
		local id = viewportIdForChar(data.ViewportChar) or 1
		log("AskName:", data.SummonUuid, "viewport =", id, "scope =", data.Scope)
		local st = panelState(id)
		table.insert(st.queue, data)
		if st.current == nil and not st.awaitingOpen then
			showNext(id)
		else
			-- A sibling arrived while a session is active: reveal Skip and Confirm (GH #80).
			refreshQueueButtons(id)
		end
	end)

	-- The server retracted a prompt (a skip-mode sibling revealed a group it already resolved):
	-- its pending is cleared, so answer nothing. Drop it from whichever viewport's queue holds it;
	-- if it is on-screen, swap to the next or close that panel (GH #54). Do NOT abort it.
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
				end
			else
				refreshQueueButtons(id)
			end
		end
	end)

	-- Toggle verbose UI tracing from the client console: `!nys_uidebug`.
	Ext.RegisterConsoleCommand("nys_uidebug", function()
		diagEnabled = not diagEnabled
		Util.Log("NYS-UI: tracing", diagEnabled and "ON" or "OFF")
	end)
end

return NativeRenameUI
