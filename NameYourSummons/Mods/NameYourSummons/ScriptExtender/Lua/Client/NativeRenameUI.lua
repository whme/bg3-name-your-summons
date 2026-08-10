-- SPDX-License-Identifier: MIT
--[[
    Client side of the native "rename this summon" control (GH #9, #19, #50, #51).

    The examined creature's uuid is read from the Examine panel's Noesis
    DataContext (EntityUUID + CharacterType) and a rename is sent to the server.

    Native-UI approach (see docs/bg3-modding-toolchain.md and AGENTS.md):
    - Controls WE add to the game's Examine panel are driven by per-element MVVM,
      not by global mouse hit-testing: the gear is an `ls:LSButton` whose `Command`
      binds to a small viewmodel we set as its nested DataContext; the name field
      commits via its own per-element key/focus subscriptions.
    - There is no panel-open event (Ext.UI.GetStateMachine() is nil), so ONE global
      mouse hook remains as the sole lifecycle detector (panel present in the tree =
      open). This is the single exception to "our controls use bindings".
    - Close the panel from Lua with closeExaminePanel (GH #54): drive its CustomEvent
      command with a boxed string planted as a XAML resource.
    - Never compare a Noesis object with `== nil` (its __eq crashes on an expired
      object) and never cache one across ticks; fetch fresh and test truthiness.
]]

local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")

local NativeRenameUI = {}

-- Set by BootstrapClient so this module (which owns Examine-panel detection) can
-- drive the native settings overlay without a circular require.
local onGearClickHandler -- fun() - called when the gear is clicked

-- Verbose tracing of the Examine gear/field/naming flow; off by default, toggle at
-- runtime from the client console with `!nys_uidebug` (this native UI has no other
-- way to be observed, and the flow depends on finicky Noesis event/hit behaviour).
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

-- The registered gear viewmodel: one Command, set as the gear button's nested
-- DataContext so its XAML `Command="{Binding NysGearCommand}"` resolves.
local GEAR_VM = "NYS_GearVM"

-- The Skip button viewmodel: a Command plus a Bool visibility flag (shown only for a
-- multi-summon group). Set as the Skip button's nested DataContext (GH #51).
local SKIP_VM = "NYS_SkipVM"

-- After opening or swapping the panel, ignore input for SETTLE_MS while the swapped-in
-- field element and its DataContext appear, then wire the fresh field and set its text.
-- Empirical.
local EXAMINE_SETTLE_MS = 400

-- KeyDown is not delivered to our Subscribe on the rename LSTextBox (verified in game), so
-- Enter is detected as a focus loss. A blur within this window of a left click is treated
-- as click-driven (Skip/gear/close/elsewhere), not an Enter commit. Empirical.
local CLICK_BLUR_WINDOW_MS = 250

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
--- satisfying `predicate`. Callers ANCHOR the search by passing ContentRoot or the
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

--- The composition root (`ContentRoot`), the cheap anchor for every scan: panels
--- and the always-present portrait view-models hang off it. Fetched fresh (a stale
--- Noesis handle crashes on use); the search is shallow (ContentRoot sits near root).
---@return any|nil
local function contentRoot()
	return findFrom(safe(Ext.UI.GetRoot), "ContentRoot")
end

--- The Examine panel node, or nil when it is not on screen. Anchored at ContentRoot.
---@return any|nil
local function examineNode()
	return findFrom(contentRoot(), "Examine")
end

--- A live Noesis node by x:Name from WITHIN the Examine subtree, or nil. Used for
--- our own controls (NYS_NameInput, NYS_SettingsButton) and the game's CloseExamine.
---@param name string
---@return any|nil
local function findNamed(name)
	return findFrom(examineNode(), name)
end

--- Read a runtime property from a view model's dynamic property bag.
---@param dc any
---@param key string
---@return any
local function dcProp(dc, key)
	-- Bag only: dc:GetProperty warns per missing key, so falling back to it while
	-- scanning the tree cost 238-510ms to open Examine (verified in game, GH #50).
	local all = safe(function()
		return dc:GetAllProperties()
	end)
	if type(all) == "table" then
		return all[key]
	end
	return nil
end

--- The uuid of the summon shown on the currently-open Examine screen, or nil.
--- Scans the Examine subtree for the first DataContext carrying an EntityUUID and a
--- "Summon" CharacterType (the examined-creature view model, inherited down the subtree).
---@return string|nil
local function examinedSummonUuid()
	local examine = examineNode()
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

--- Send a rename for a specific summon uuid. Returns false on empty input or a
--- failed send, so commitField only dedupes a rename that was actually submitted.
---@param uuid string
---@param rawName string
---@return boolean
local function submitRename(uuid, rawName)
	local name = Util.Sanitise(rawName)
	if type(uuid) ~= "string" or name == "" then
		return false
	end
	-- A channel/send failure must not escape this input callback and tear down the
	-- client Lua state.
	return pcall(function()
		Channels.RenameSummon:SendToServer({ SummonUuid = uuid, Name = name })
	end)
end

---------------------------------------------------------------------------
-- On-summon naming state (GH #19, #51); the interaction below drives it
---------------------------------------------------------------------------
--
-- The server owns detection, the pending count, the world-pause, and (in unique mode)
-- asking per creature; the client answers by opening the native Examine panel. Only one
-- Examine panel exists, and Executing Examine on an open panel SWAPS its content (GH #50
-- finding C4), so a multi-summon group is shown in ONE panel that swaps through the queue:
-- the player names each with Enter (which answers over SubmitName and swaps to the next),
-- skips one with the Skip button (abort + swap), and closes the panel once at the end.
-- Closing before the queue drains skips every remaining summon (abort each), so the
-- server's pending count still clears and the pause lifts. Naming answers over SubmitName
-- (the channel the ImGui window used, so the server's pause/pending bookkeeping is
-- untouched).
local examineQueue = {} -- AskName requests not yet shown, FIFO
local current = nil -- the request whose summon is being examined now, or nil
local answered = false -- the current summon got a name (SubmitName sent; later edits rename)
local awaitingOpen = false -- panel opening/swapping; ignore input until it settles
local openGeneration = 0 -- bumped per open/swap so a superseded settle callback bails
local showNext -- forward decl: swap to the next queued request (or open the first)
local answerSession -- forward decl: answer a session over SubmitName
local openExamine -- forward decl: Execute Examine on a request
local getExamineCommand -- forward decl: fetch the game's ExamineCommand
local entityHandleFor -- forward decl: Noesis EntityHandle for a summon uuid

-- Panel lifecycle + per-element wiring. `panelOpen` is the last-seen presence of the
-- Examine node; `wired` is whether the current panel's field/gear have their
-- per-element bindings/subscriptions attached (idempotent, torn down on close).
local panelOpen = false
local wired = false
local fieldSubs = {} -- { { field = node, handle = h }, ... } to unsubscribe on teardown
local lastSent = nil -- last committed sanitised text, to dedupe Enter + blur
local recentClick = false -- a left click just happened, so a blur now is click-driven not Enter (no save)

-- Editing state for the current panel (GH #48): `editEnabled` whether we turned editing on,
-- `panelForbidden` whether the examined summon may not be renamed. Both reset on unwire.
local editEnabled = false
local panelForbidden = false

-- The AllowStorySummons setting, cached client-side so the forbidden check is synchronous
-- (GH #48): the live value cannot be fetched without a server round-trip. Seeded on
-- SessionLoaded (once the persisted ModVars have loaded) and kept fresh by the server's
-- SettingsChanged broadcast.
local cachedAllowStory = false

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

--- Reset per-summon state for the new `current` request.
local function beginCurrent()
	answered = false
	lastSent = Util.Sanitise(current.DefaultName or "")
end

--- Skip the current summon (if unnamed) and every summon still queued, then clear the
--- batch. Called when the player closes the panel: closing means "skip the rest", so each
--- is aborted (the server re-asks it next cast) and its pending count clears.
local function abortRemaining()
	if not current and #examineQueue == 0 then
		return
	end
	log("abortRemaining: current =", current and current.SummonUuid or "none", "queued =", #examineQueue)
	if current and not answered then
		answerSession(current, "", true)
	end
	for _, req in ipairs(examineQueue) do
		answerSession(req, "", true)
	end
	examineQueue = {}
	current = nil
	answered = false
end

--- The live rename field, or nil when no Examine panel is open.
---@return any|nil
local function liveField()
	return findNamed("NYS_NameInput")
end

--- A snapshot of what is ACTUALLY on screen right now (not our internal flags), for
--- tracing. Walks the Examine subtree, so it is skipped entirely unless tracing is on.
---@return string
local function uiState()
	if not diagEnabled then
		return ""
	end
	return string.format(
		"[examine=%s field=%s wired=%s | current=%s answered=%s awaitingOpen=%s queued=%d]",
		tostring(examineNode() ~= nil),
		tostring(liveField() ~= nil),
		tostring(wired),
		current and current.SummonUuid or "none",
		tostring(answered),
		tostring(awaitingOpen),
		#examineQueue
	)
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

--- Set the rename field's text from Lua. The field's `Text` binding is OneWay and does
--- NOT follow an Examine content swap (GH #51), so on each swap we write the new
--- creature's name in directly. Baseline lastSent so a blur without an edit does not
--- re-submit.
---@param text string
local function setFieldText(text)
	local field = liveField()
	if not field then
		return
	end
	pcall(function()
		field.Text = text or ""
	end)
	lastSent = Util.Sanitise(text or "")
end

--- Rename the examined summon to `field`'s current text. Deduped via lastSent so an
--- Enter followed by a blur (or repeated triggers) sends only once. The uuid (a
--- DataContext walk) is resolved only after we know the text actually changed.
---@param field any
local function commitField(field)
	if awaitingOpen then
		return
	end
	local raw = nodeText(field)
	local name = Util.Sanitise(raw)
	log("commitField: text =", name, "lastSent =", lastSent)
	if name == "" or name == lastSent then
		return
	end
	local uuid = examinedSummonUuid()
	log("commitField: examined uuid =", uuid, "session =", current and current.SummonUuid or nil)
	if uuid == nil then
		return
	end
	if current ~= nil and not answered and uuid == current.SummonUuid then
		-- First answer of an on-summon session: over SubmitName, which decrements the
		-- server's pending count once. A later edit before the panel closes must NOT
		-- re-answer (it would double-decrement pending and append a duplicate unique
		-- slot); it falls through to the idempotent RenameSummon path below.
		if answerSession(current, name) then
			lastSent = name
			answered = true
		end
		log("commitField: on-summon answered =", answered)
		return
	end
	if submitRename(uuid, raw) then
		lastSent = name
		Util.Log(("NYS: renamed %s -> '%s'"):format(uuid, name))
	end
end

---------------------------------------------------------------------------
-- Owned controls: per-element MVVM (gear Command binding + field key/focus subs)
---------------------------------------------------------------------------

--- Open the native settings overlay (bound to the gear's NysGearCommand).
local function onGearClick()
	log("onGearClick -> native settings overlay")
	if onGearClickHandler then
		onGearClickHandler()
	end
end

--- Skip the current summon (abort so the server re-asks it next cast) and swap to the
--- next. Bound to the Skip button's NysSkipCommand; only shown for a multi-summon group.
--- The click's preceding blur never saves during a session (onFieldBlur), so any typed
--- name is discarded and the abort always fires.
local function skipCurrent()
	if not current or awaitingOpen then
		return
	end
	log("skipCurrent:", current.SummonUuid)
	if answerSession(current, "", true) then
		showNext()
	end
end

--- Commit the field now (from a key/focus event). Re-fetches the live field.
local function commitLiveField()
	local field = liveField()
	if field then
		commitField(field)
	end
end

--- Enter on the name field. During an active on-summon session it names (or confirms) the
--- current creature and swaps to the next; an empty field is a no-op (skipping is the Skip
--- button's job). With no active session it is a plain rename of the examined creature.
local function onFieldEnter()
	if awaitingOpen then
		return
	end
	local field = liveField()
	if not field then
		return
	end
	if current == nil then
		commitField(field)
		return
	end
	local raw = nodeText(field)
	local name = Util.Sanitise(raw)
	if not answered then
		if name == "" then
			return
		end
		-- First answer over SubmitName; a failed send keeps us here so Enter can retry.
		if not answerSession(current, name) then
			return
		end
		lastSent = name
		answered = true
	elseif name ~= "" and name ~= lastSent then
		-- Already answered this creature: a further edit renames idempotently.
		local uuid = examinedSummonUuid()
		if uuid and submitRename(uuid, raw) then
			lastSent = name
		end
	end
	log("onFieldEnter: advancing", uiState())
	showNext()
end

--- Per-element focus-loss on the name field. Enter is not delivered as KeyDown here, it
--- arrives as a focus loss, so a blur with no preceding click is an Enter commit (save +
--- advance via onFieldEnter). A blur right after a click is click-driven: during an active
--- session it does NOT save (the clicked control - Skip / gear / close - acts, and Skip and
--- close must be free to abort), while a plain Examine rename (no session) still saves on
--- blur. Both LostFocus and LostKeyboardFocus fire per blur; the second is deduped
--- (commitField) or gated (awaitingOpen after an advance).
---@param evName string
local function onFieldBlur(evName)
	log("field blur event:", evName, "recentClick =", tostring(recentClick), uiState())
	if recentClick then
		if current == nil then
			commitLiveField()
		end
	else
		onFieldEnter()
	end
end

--- Show the Skip button only when there is a next summon to swap to (hidden for single
--- summons and on the last of a group). Update the live button - the queue may have grown
--- or shrunk after it was wired. Fetch fresh; a Noesis handle does not survive.
local function refreshSkipVisibility()
	local skip = findNamed("NYS_SkipButton")
	local vm = skip and safe(function()
		return skip.DataContext
	end)
	if vm then
		pcall(function()
			vm.NysShowSkip = #examineQueue > 0
		end)
	end
end

--- The root template of a summon, read client-side (Ext.Entity is available in both
--- states) so the forbidden check is synchronous. Nil if OriginalTemplate is not
--- replicated to the client - then we fail open (treat as renamable).
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

--- Whether the examined summon must not offer a rename: a story-bound template (e.g.
--- "Us") while the opt-in is off (GH #48). Mirrors the server's HandleSummon story gate
--- via the shared Util.IsStorySummon and the cached setting.
---@param uuid string
---@return boolean
local function isForbiddenSummon(uuid)
	local template = clientTemplateOf(uuid)
	return template ~= nil and Util.IsStorySummon(template) and not cachedAllowStory
end

--- Flip the name field's three input-checked flags (GH #48): editable = interactive and
--- writable, else non-interactive plain text. All checked at INPUT time, not painted, so
--- the change needs no repaint - which is why a manual click can enable editing at all (a
--- Visibility change would not paint until the next click).
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

--- Turn on editing for the current panel: the field starts as plain text; once enabled the
--- player focuses it with a click and types. Idempotent (guarded by `editEnabled`).
local function enableEditing()
	if editEnabled then
		return
	end
	local field = liveField()
	if not field then
		return
	end
	setFieldEditable(field, true)
	editEnabled = true
	log("enableEditing", uiState())
end

--- Revert the field to non-interactive plain text - used when AllowStorySummons is toggled
--- off while a now-forbidden summon's panel is open, so it stops being editable without a
--- re-summon.
local function disableEditing()
	editEnabled = false
	local field = liveField()
	if field then
		setFieldEditable(field, false)
	end
	log("disableEditing", uiState())
end

--- Attach the gear's Command viewmodel and the field's key/focus subscriptions to the
--- current panel. Idempotent (guarded by `wired`); no-op until the field node exists
--- (the panel may still be animating open).
local function wirePanel()
	if wired then
		return
	end
	local field = liveField()
	if not field then
		return
	end

	-- Baseline the dedupe key to the text already shown, so a blur without an edit
	-- does not submit.
	lastSent = Util.Sanitise(nodeText(field))

	fieldSubs = {}
	local function sub(event, fn)
		local handle = safe(function()
			return field:Subscribe(event, fn)
		end)
		if handle ~= nil then
			fieldSubs[#fieldSubs + 1] = { field = field, handle = handle }
		end
	end
	sub("LostFocus", function()
		onFieldBlur("LostFocus")
	end)
	sub("LostKeyboardFocus", function()
		onFieldBlur("LostKeyboardFocus")
	end)

	-- Gear: nested DataContext = a fresh NYS_GearVM whose command opens settings.
	local gear = findNamed("NYS_SettingsButton")
	if gear then
		local vm = safe(function()
			return Ext.UI.Instantiate(GEAR_VM)
		end)
		if vm then
			pcall(function()
				vm.NysGearCommand:SetHandler(onGearClick)
			end)
			pcall(function()
				gear.DataContext = vm
			end)
		end
	end

	-- Skip: nested DataContext = a fresh NYS_SkipVM; NysShowSkip hides it for single
	-- summons (only a group needs a per-creature skip).
	local skip = findNamed("NYS_SkipButton")
	if skip then
		local vm = safe(function()
			return Ext.UI.Instantiate(SKIP_VM)
		end)
		if vm then
			pcall(function()
				vm.NysSkipCommand:SetHandler(skipCurrent)
			end)
			pcall(function()
				vm.NysShowSkip = #examineQueue > 0
			end)
			pcall(function()
				skip.DataContext = vm
			end)
		end
	end

	wired = true
	log("wirePanel: wired", #fieldSubs, "field subs", uiState())

	-- An on-summon prompt (current ~= nil) is the server asking for a name, so enable editing
	-- now; a manually examined summon stays plain text until a click, if it may be renamed.
	local summonUuid = examinedSummonUuid()
	panelForbidden = summonUuid ~= nil and isForbiddenSummon(summonUuid)
	if current ~= nil then
		enableEditing()
	end
end

--- Drop the current panel's per-element wiring. The Examine field element is
--- destroyed/hidden on close, so unsubscribe is best-effort (a dead handle throws).
local function unwirePanel()
	for _, entry in ipairs(fieldSubs) do
		pcall(function()
			entry.field:Unsubscribe(entry.handle)
		end)
	end
	fieldSubs = {}
	wired = false
	editEnabled = false
	panelForbidden = false
end

--- React to the panel opening or closing. On close, tear down wiring and skip whatever is
--- left of the batch (the player closed, so the rest of the queue is skipped).
---@param open boolean
local function setPanelOpen(open)
	if open == panelOpen then
		return
	end
	log("setPanelOpen:", open, uiState())
	panelOpen = open
	if open then
		wirePanel()
	else
		unwirePanel()
		abortRemaining()
	end
end

--- Reconcile our state with the live tree (presence of the Examine node) and wire the
--- panel once its field exists. Returns whether Examine is currently present.
---@return boolean
local function pollLifecycle()
	local present = examineNode() ~= nil
	if present ~= panelOpen then
		setPanelOpen(present)
	elseif present then
		wirePanel() -- idempotent; catches the field appearing after the open transition
	end
	return present
end

--- Global left-click hook - the ONLY global input hook, and purely a lifecycle
--- detector (there is no panel-open event; C9). It does NOT hit-test the gear/close/
--- field: those are per-element bindings/subscriptions now.
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
	-- Mark the blur that this click is about to cause as click-driven, not an Enter commit.
	recentClick = true
	Ext.Timer.WaitForRealtime(CLICK_BLUR_WINDOW_MS, function()
		recentClick = false
	end)
	-- Ignore clicks while the panel opens/swaps and its field settles.
	if awaitingOpen then
		log("onMouseButton: ignored (awaitingOpen)")
		return
	end
	log("onMouseButton: left click", uiState())
	local present = pollLifecycle()
	-- A click on a renamable manually-examined summon is the player asking to edit it (there
	-- is no edit hotkey); the same click that focuses the field also clears IsReadOnly, so
	-- typing works at once. A forbidden summon stays plain text (GH #48).
	if present and current == nil and not editEnabled and not panelForbidden then
		enableEditing()
	end
	-- A click may start a close animation not yet reflected in the tree; reconcile once
	-- after it settles. One-shot, not a poll loop.
	if present or current ~= nil then
		Ext.Timer.WaitForRealtime(2 * EXAMINE_SETTLE_MS, pollLifecycle)
	end
end

---------------------------------------------------------------------------
-- On-summon naming: open the Examine panel instead of the ImGui prompt (GH #19)
---------------------------------------------------------------------------
--
-- Opening Examine on a specific creature drives native UI that has no SE/Osiris
-- entry point: fetch the game's ExamineCommand (a Noesis BaseCommand) off the HUD
-- command-surface DataContext and Execute it with the summon's Noesis EntityHandle -
-- the exact CommandParameter the game's own XAML binds. See docs/bg3-modding-toolchain.md.

-- The global command surface (ExamineCommand + ~200 other game commands) is a ui::DCWidget
-- that is NOT on ContentRoot's own DataContext but IS inherited onto the always-present
-- "HudIndicator" node beneath it (verified in game, GH #50). Named for the direct lookup.
local COMMAND_SURFACE_NODE = "HudIndicator"

--- The game's ExamineCommand. Read directly off the HUD command-surface DataContext
--- (a small anchored hop: ContentRoot -> HudIndicator). Runs once per open. Returned
--- fresh, never cached (a stale Noesis handle crashes on use).
---@return any|nil
function getExamineCommand()
	local hud = findFrom(contentRoot(), COMMAND_SURFACE_NODE)
	local dc = hud and safe(function()
		return hud.DataContext
	end)
	return dc and safe(function()
		return dc:GetProperty("ExamineCommand")
	end)
end

--- The Noesis EntityHandle for a summon uuid, off any live per-entity DataContext (the
--- always-present portrait view-models carry one). Anchored at ContentRoot. The direct
--- getter returns the object Execute needs; the bag may copy it.
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

--- Answer a session over SubmitName - the channel the old window used - so the
--- server saves the name, or (empty name + abort) re-asks next summon, AND clears
--- its pending count, lifting the world-pause. Returns pcall success.
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

--- Execute Examine on `req`'s summon: opens the panel (nothing on screen) or SWAPS its
--- content (a panel already open, C4). Returns whether it opened. If it cannot - the
--- command or entity view-model is missing, or Execute throws on a stale handle - the
--- caller skips this summon so the server's pending count never hangs the pause.
---@param req table
---@return boolean
function openExamine(req)
	local command = getExamineCommand()
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
		-- Name which precondition failed - unconditional, so it survives a diag-flag reset.
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

--- Show the next queued request by swapping the open panel (or opening the first). The
--- outgoing `current` must already be resolved (answered, skipped, or retracted) - this
--- never aborts it. An empty queue leaves the panel open on the last creature and ends
--- the batch. A summon that cannot be opened is skipped so the pause never hangs.
function showNext()
	current = table.remove(examineQueue, 1)
	log("showNext: next =", current and current.SummonUuid or "none", "queued =", #examineQueue)
	if not current then
		return
	end
	beginCurrent()
	-- Execute on an already-open panel swaps in a fresh field element (C4), so drop the
	-- prior panel's wiring; the settle below re-wires the new field.
	unwirePanel()
	-- Bump the token so any prior open's settle callback (e.g. a retract swapped current
	-- mid-settle) bails instead of acting on this newer swap.
	openGeneration = openGeneration + 1
	local generation = openGeneration
	awaitingOpen = true
	if not openExamine(current) then
		awaitingOpen = false
		if answerSession(current, "", true) then
			showNext()
		end
		return
	end
	-- Ignore input while the open/swap settles, then wire the fresh field and set its text
	-- (the OneWay binding does not follow a swap). One-shot, not a poll loop.
	Ext.Timer.WaitForRealtime(EXAMINE_SETTLE_MS, function()
		if generation ~= openGeneration then
			return
		end
		awaitingOpen = false
		if not current then
			-- A retract cleared current while this settle was pending; show any AskName that
			-- queued meanwhile, else nothing is left and the panel is already closing.
			if #examineQueue > 0 then
				showNext()
			end
			return
		end
		-- pollLifecycle may notice the panel closed and clear the batch, so re-check current.
		pollLifecycle()
		if current then
			setFieldText(current.DefaultName)
		end
	end)
end

-- Closing Examine from Lua (GH #54): its close runs the "CloseWidget" state event (action
-- <ls:RemoveState/>) through the widget's CustomEvent command, whose parameter must be a
-- BOXED Noesis string - a raw Lua string is rejected and SE cannot mint one, so we plant a
-- <System:String x:Key="NYS_CloseWidget"> resource in the Examine.xaml override and read it
-- back live via element:Resource(). See AGENTS.md for why the resource is the only way in.
local CLOSE_WIDGET_RESOURCE = "NYS_CloseWidget"

--- Close the open Examine panel; true if the close command was issued. Command and param
--- are fetched fresh - a Noesis handle does not survive across ticks.
---@return boolean
local function closeExaminePanel()
	local examine = examineNode()
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
		-- A disabled command Executes as a silent no-op; CanExecute guards that.
		assert(command:CanExecute(param))
		command:Execute(param)
	end) == true
end

--- Find a live Noesis node by x:Name within the Examine subtree (exposed so
--- NativeConfigUI can resolve its overlay fresh at the moment it binds it).
---@param name string
---@return any|nil
function NativeRenameUI.FindNamed(name)
	return findNamed(name)
end

--- Wire the gear-click action (opens the native settings overlay).
---@param fn fun()
function NativeRenameUI.SetGearHandler(fn)
	onGearClickHandler = fn
end

-- Event names confirmed against bg3se source (LuaClient.cpp ThrowEvent
-- "MouseButtonInput"); the IDE helper's "EclLua*" names are stale for this build, and
-- Ext.Events is not enumerable.
function NativeRenameUI.Register()
	pcall(function()
		Ext.UI.RegisterType(GEAR_VM, { NysGearCommand = { Type = "Command" } })
	end)

	pcall(function()
		Ext.UI.RegisterType(SKIP_VM, { NysSkipCommand = { Type = "Command" }, NysShowSkip = { Type = "Bool" } })
	end)

	pcall(function()
		Ext.Events.MouseButtonInput:Subscribe(onMouseButton)
	end)

	-- Seed cachedAllowStory (GH #48). A fresh boot has not loaded the persisted ModVars at
	-- Register, so the SessionLoaded seed is what honours a saved opt-in; the immediate call
	-- covers a Lua `reset` reload, where ModVars are loaded but SessionLoaded does not re-fire.
	refreshSettingsCache()
	pcall(function()
		Ext.Events.SessionLoaded:Subscribe(refreshSettingsCache)
	end)

	-- The setting changed (config UI); refresh the cache so the forbidden check is right on
	-- the very next examine, not after a re-summon (GH #48). Also re-evaluate the panel on
	-- screen: a summon that just became forbidden reverts to plain text at once; one that
	-- became renamable is enabled on the next click.
	Channels.SettingsChanged:SetHandler(function(data, _user)
		if type(data) ~= "table" then
			return
		end
		cachedAllowStory = data.AllowStorySummons == true
		if wired then
			local uuid = examinedSummonUuid()
			panelForbidden = uuid ~= nil and isForbiddenSummon(uuid)
			if panelForbidden and editEnabled then
				disableEditing()
			end
		end
	end)

	-- Toggle the verbose UI tracing above from the client console: `!nys_uidebug`.
	Ext.RegisterConsoleCommand("nys_uidebug", function()
		diagEnabled = not diagEnabled
		Util.Log("NYS-UI: tracing", diagEnabled and "ON" or "OFF")
	end)

	-- The server asks the summoner's client to name a summon; open Examine on it.
	Channels.AskName:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" or type(data.SummonUuid) ~= "string" then
			return
		end
		log("AskName:", data.SummonUuid, "scope =", data.Scope)
		table.insert(examineQueue, data)
		if current == nil and not awaitingOpen then
			showNext()
		else
			-- A sibling arrived while a session is active: there is now a next to skip to,
			-- so reveal the Skip button on the panel already showing.
			refreshSkipVisibility()
		end
	end)

	-- The server retracted a prompt (a skip-mode sibling revealed a group it already
	-- resolved): its pending is cleared, so answer nothing. Drop it from the queue; if it
	-- is the on-screen summon, swap to the next queued summon, or close the panel from Lua
	-- (closeExaminePanel, GH #54) when nothing is left. Do NOT abort it - the server
	-- already cleared it.
	Channels.RetractPrompt:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		local key = data.Key
		for i = #examineQueue, 1, -1 do
			if examineQueue[i].Key == key then
				table.remove(examineQueue, i)
			end
		end
		if current ~= nil and current.Key == key then
			if #examineQueue > 0 then
				showNext()
			else
				current = nil
				answered = false
				closeExaminePanel()
			end
		else
			refreshSkipVisibility()
		end
	end)
end

return NativeRenameUI
