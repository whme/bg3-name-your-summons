--[[
    Client side of the native "rename this summon" control (GH #9, #19, #50).

    The examined creature's uuid is read from the Examine panel's Noesis
    DataContext (EntityUUID + CharacterType) and a rename is sent to the server.

    Native-UI approach (verified in game, GH #50 - see docs/bg3-modding-toolchain.md
    and AGENTS.md for the full "one proven way"):
    - Controls WE add to the game's Examine panel are driven by per-element MVVM,
      not by global mouse hit-testing: the gear is an `ls:LSButton` whose `Command`
      binds to a small viewmodel we set as its nested DataContext; the name field
      commits via its own per-element key/focus subscriptions. All of these fire on
      the FIRST panel of a session (the old "per-element events are dead on the
      first panel" claim was WRONG).
    - There is no panel-open event (Ext.UI.GetStateMachine() is nil) and Examine
      cannot be closed from Lua, so exactly ONE cheap global mouse hook remains, as
      the sole lifecycle detector (panel present in the tree = open). This is the
      single sanctioned exception to "our controls use bindings".
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

-- One-shot open-animation settle (ms) after we Execute Examine on a queued summon:
-- keep ignoring input while it plays so rapid skipping cannot dismiss the fresh
-- panel, and wire the field/gear once it has settled. Empirical.
local EXAMINE_CLOSE_MS = 400
local EXAMINE_SETTLE_MS = 400

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
-- On-summon naming state (GH #19); the interaction below drives it
---------------------------------------------------------------------------
--
-- The server still owns detection, the pending count, the world-pause, and (in
-- unique mode) asking per creature; the client answers by opening the native Examine
-- panel. Only one Examine panel exists and it cannot be closed from Lua (C3), so as a
-- DESIGN CHOICE the queued summons are shown one at a time and the next opens once the
-- player closes the current panel (a swap-through-the-queue redesign is GH #51 - the
-- engine does NOT force one-at-a-time: ExamineCommand:Execute on an open panel swaps
-- its content, C4). Naming a summon answers over SubmitName (the channel the old ImGui
-- window used, so the server's pause/pending bookkeeping is untouched) and leaves the
-- panel up; closing it advances, skipping (abort) any summon left unnamed.
local examineQueue = {} -- AskName requests not yet shown, FIFO
local current = nil -- the request whose summon is being examined now, or nil
local answered = false -- the current summon got a name (so closing it just advances)
local awaitingOpen = false -- next panel scheduled after a close; ignore input meanwhile
local startNext -- forward decl: advance the queue
local answerSession -- forward decl: answer a session over SubmitName
local openExamine -- forward decl: Execute Examine on a request

-- Panel lifecycle + per-element wiring. `panelOpen` is the last-seen presence of the
-- Examine node; `wired` is whether the current panel's field/gear have their
-- per-element bindings/subscriptions attached (idempotent, torn down on close).
local panelOpen = false
local wired = false
local fieldSubs = {} -- { { field = node, handle = h }, ... } to unsubscribe on teardown
local lastSent = nil -- last committed sanitised text, to dedupe Enter + blur

--- Reset per-summon state for the new `current` request.
local function beginCurrent()
	answered = false
	lastSent = Util.Sanitise(current.DefaultName or "")
end

--- Finish the current summon and move to the next. Called when the player closes the
--- panel; a summon left unnamed is a skip (abort - the server re-asks it next summon),
--- a named one is already saved.
local function finishCurrent()
	if not current then
		return
	end
	log("finishCurrent: answered =", answered)
	if not answered then
		-- Skip an unnamed summon; a failed abort send keeps it so a later close retries.
		local sent = answerSession(current, "", true)
		log("finishCurrent: abort sent =", sent)
		if not sent then
			return
		end
	end
	startNext(true)
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

--- Rename the examined summon to `field`'s current text. Deduped via lastSent so an
--- Enter followed by a blur (or repeated triggers) sends only once. The uuid (a
--- DataContext walk) is resolved only after we know the text actually changed.
---@param field any
local function commitField(field)
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

--- element:Subscribe hands the handler either (args) or (sender, args); return the
--- one that looks like the event args (has a readable field), else the first.
local function eventArgs(a, b)
	if b ~= nil then
		return b
	end
	return a
end

-- Enter-key names, covering the shapes the Noesis KeyEventArgs.Key may report.
local ENTER_KEYS = {
	Return = true,
	Enter = true,
	Key_Return = true,
	Key_Enter = true,
	KP_Enter = true,
	Key_NumPadEnter = true,
	NumPadEnter = true,
}

--- Commit the field now (from a key/focus event). Re-fetches the live field.
local function commitLiveField()
	local field = liveField()
	if field then
		commitField(field)
	end
end

--- Per-element KeyDown on the name field: commit on Enter only (committing on every
--- keystroke would fire a rename mid-typing). The raw key is traced so the exact name
--- is known (GH #50 spike). C1/C7: KeyDown fires on the field first-open; focus does not.
local function onFieldKeyDown(a, b)
	local e = eventArgs(a, b)
	local key = safe(function()
		return e.Key
	end)
	log("field KeyDown key =", tostring(key), uiState())
	if key ~= nil and ENTER_KEYS[tostring(key)] then
		commitLiveField()
	end
end

--- Per-element focus-loss on the name field: commit unconditionally (blur = save). Both
--- LostFocus and LostKeyboardFocus fire on every blur (verified GH #50) - we keep both
--- for robustness; commitField dedupes so the second is a cheap no-op.
---@param evName string
local function onFieldBlur(evName)
	log("field blur event:", evName, uiState())
	commitLiveField()
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
	sub("KeyDown", onFieldKeyDown)
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

	wired = true
	log("wirePanel: wired", #fieldSubs, "field subs", uiState())
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
end

--- React to the panel opening or closing. On close, tear down wiring and advance the
--- active on-summon session (a close we did not otherwise catch still advances).
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
		finishCurrent()
	end
end

--- The single sanctioned global hook: reconcile our state with the live tree
--- (presence of the Examine node), and wire the panel once its field exists.
local function pollLifecycle()
	local present = examineNode() ~= nil
	if present ~= panelOpen then
		setPanelOpen(present)
	elseif present then
		wirePanel() -- idempotent; catches the field appearing after the open transition
	end
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
	-- Ignore clicks while the old panel animates shut and the next is scheduled.
	if awaitingOpen then
		log("onMouseButton: ignored (awaitingOpen)")
		return
	end
	log("onMouseButton: left click", uiState())
	pollLifecycle()
	-- A click while a panel is up (or a session is active) may have started a close (the
	-- animated X) or opened a panel still animating in - neither is visible in the tree
	-- yet. Reconcile once after the animations settle so the panel wires, or a close
	-- advances the queue, without needing a second click. One-shot, not a poll loop.
	if examineNode() ~= nil or current ~= nil then
		Ext.Timer.WaitForRealtime(EXAMINE_CLOSE_MS + EXAMINE_SETTLE_MS, pollLifecycle)
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
local function getExamineCommand()
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
local function entityHandleFor(uuid)
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

--- Execute Examine on `req`'s summon. Only ever called with no panel on screen (the
--- first summon, or after the player closed the previous one). If it cannot open - the
--- command or entity view-model is missing, or Execute throws on a stale handle - skip
--- it and go straight to the next, so the server's pending count never hangs the pause.
---@param req table
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
		-- Nothing opened, so no close to wait for: skip and open the next at once.
		if answerSession(req, "", true) then
			startNext(false)
		end
	end
end

--- Examine the next queued request (an empty queue just clears `current`). After a
--- close, the panel's shut is animated and the next open must wait for it to be gone,
--- so defer by EXAMINE_CLOSE_MS; the first summon (nothing open) shows at once.
---@param afterClose boolean|nil
function startNext(afterClose)
	current = table.remove(examineQueue, 1)
	log(
		"startNext: next =",
		current and current.SummonUuid or "none",
		"queued =",
		#examineQueue,
		"afterClose =",
		afterClose == true
	)
	if not current then
		return
	end
	beginCurrent()
	-- Execute on an already-open panel swaps in a fresh field element (C4), so drop the
	-- prior panel's wiring; pollLifecycle re-wires the new field once it has settled.
	unwirePanel()
	if afterClose then
		awaitingOpen = true
		Ext.Timer.WaitForRealtime(EXAMINE_CLOSE_MS, function()
			if not current then
				awaitingOpen = false
				return
			end
			openExamine(current)
			-- Stay closed to input while the open animation plays, so a second, too-early
			-- close/Escape (rapid skipping) does not dismiss the panel we just opened; then
			-- wire the fresh panel without waiting for a click.
			Ext.Timer.WaitForRealtime(EXAMINE_SETTLE_MS, function()
				awaitingOpen = false
				pollLifecycle()
			end)
		end)
	else
		openExamine(current)
		Ext.Timer.WaitForRealtime(EXAMINE_SETTLE_MS, pollLifecycle)
	end
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
		Ext.Events.MouseButtonInput:Subscribe(onMouseButton)
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
			startNext(false)
		end
	end)

	-- The server retracted a prompt (a skip-mode sibling revealed a group it already
	-- resolved): its pending is cleared, so answer nothing. Drop it from the queue; if it
	-- is the summon on screen, mark it answered so closing its panel just advances.
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
			answered = true
		end
	end)
end

return NativeRenameUI
