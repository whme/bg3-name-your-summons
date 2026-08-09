--[[
    Client side of the native "rename this summon" control (GH #9).

    The examined creature's uuid is read from the Examine panel's Noesis
    DataContext (EntityUUID + CharacterType) and a rename is sent to the server.
    Commit is driven by global input events, not the panel's routed UI events -
    see the note above the control handlers for why.
]]

local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")

local NativeRenameUI = {}

-- Set by BootstrapClient so this module (which owns Examine-panel detection) can
-- drive the native settings overlay without a circular require.
local onGearClickHandler -- fun() - called when the gear is clicked

-- Verbose tracing of the Examine gear/close/naming flow; off by default, toggle at
-- runtime from the client console with `!nys_uidebug` (this native UI has no other
-- way to be observed, and the flow depends on finicky Noesis event/hit behaviour).
local diagEnabled = false
local function log(...)
	if diagEnabled then
		Util.Log("NYS-UI:", ...)
	end
end

local UUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"
local MAX_DEPTH = 60

-- Examine cannot be closed from Lua (its close is a UICancel bound event / a Noesis-
-- typed CustomEvent param, neither reachable via SE), and ExamineCommand is ignored
-- while a panel is on screen. So the next queued summon opens only after the player
-- closes the current one: wait CLOSE_MS (the close animation) before Executing so the
-- old panel is gone, then keep ignoring input for SETTLE_MS (the open animation) so a
-- too-eager second close/Escape cannot dismiss the freshly opened panel. Empirical.
local EXAMINE_CLOSE_MS = 400
local EXAMINE_SETTLE_MS = 400

local function safe(fn, ...)
	local ok, res = pcall(fn, ...)
	if ok then
		return res
	end
	return nil
end

-- Hoisted out of the per-node walk so it does not allocate a closure per access
-- (the walk runs on every click). VisualChild is 1-based (bg3se GetVisualChild).
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
--- satisfying `predicate`.
---@param node any
---@param depth integer
---@param predicate fun(node:any):boolean
---@return any|nil
local function findNode(node, depth, predicate)
	if node == nil or depth > MAX_DEPTH then
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

--- The first visual node named `name` from the composition root, or nil.
---@param name string
---@return any|nil
local function findNamed(name)
	local root = safe(Ext.UI.GetRoot)
	if root == nil then
		return nil
	end
	return findNode(root, 0, function(node)
		return widgetName(node) == name
	end)
end

--- Read a Noesis property, preferring the direct getter and falling back to the
--- dynamic property bag (these view models expose runtime props via either).
---@param dc any
---@param key string
---@return any
local function dcProp(dc, key)
	-- Read ONLY the property bag. These runtime props (EntityUUID, CharacterType)
	-- live there; the typed getter lacks them and logs a Noesis warning per miss. A
	-- fallback to dc:GetProperty(key) here scanned the whole visual tree that way and
	-- spammed thousands of warnings, costing 200-500ms just to open Examine on a
	-- summon (verified in game). The bag has no such cost and always carries these
	-- props where they exist, so there is nothing useful to fall back to.
	local all = safe(function()
		return dc:GetAllProperties()
	end)
	if type(all) == "table" then
		return all[key]
	end
	return nil
end

--- The uuid of the summon shown on the currently-open Examine screen, or nil.
--- Finds the Examine panel, then the first descendant whose DataContext carries
--- an EntityUUID and a "Summon" CharacterType (the examined-creature view model,
--- inherited down the subtree).
---@return string|nil
local function examinedSummonUuid()
	local examine = findNamed("Examine")
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
	-- A channel/send failure must not escape this global input callback and tear
	-- down the client Lua state.
	return pcall(function()
		Channels.RenameSummon:SendToServer({ SummonUuid = uuid, Name = name })
	end)
end

---------------------------------------------------------------------------
-- Native controls: Enter or click-away renames the summon; the gear opens config
---------------------------------------------------------------------------
--
-- The Examine panel's routed UI events are unreliable: it is a separate Noesis popup
-- tree Ext.UI.GetRoot() never receives events from, the field's focus events do not
-- fire on the first open after a load, and a per-element mouse subscription does not
-- take effect on the first panel of a session. The global SDL-level input events
-- (MouseButtonInput / KeyInput) fire on every click and key regardless, so the whole
-- control is driven by those: on a click we hit-test the gear and close button by
-- their IsMouseOver, and commit/baseline the field.
local editing = false -- an edit session is active (baseline captured on first click)
local panelOpen = false -- last-seen panel presence (field exists)
local keySub = nil -- KeyInput subscription handle; only held while the panel is open
local lastSent = nil -- last committed sanitised text, to dedup Enter + click-away

-- On-summon naming (GH #19). The server still owns detection, the pending count,
-- the world-pause, and (in unique mode) asking per creature; the client now answers
-- by opening the native Examine panel instead of an ImGui window. Only one Examine
-- panel exists AND it cannot be closed from Lua, so summons are shown one at a time
-- and the next opens only once the player closes the current panel. Naming a summon
-- (Enter / click-away) answers over SubmitName - the channel the old window used, so
-- the server's pause/pending bookkeeping is untouched - but leaves the panel up;
-- closing it (X / Escape) advances to the next, skipping (abort) any summon left
-- unnamed. The queue is drained one close at a time.
local examineQueue = {} -- AskName requests not yet shown, FIFO
local current = nil -- the request whose summon is being examined now, or nil
local answered = false -- the current summon got a name (so closing it just advances)
local awaitingOpen = false -- next panel scheduled after a close; ignore input meanwhile
local startNext -- forward decl: advance the queue
local answerSession -- forward decl: answer a session over SubmitName
local openExamine -- forward decl: Execute Examine on a request

--- Reset per-summon state for the new `current` request.
local function beginCurrent()
	answered = false
	editing = false
	lastSent = Util.Sanitise(current.DefaultName or "")
end

--- Finish the current summon and move to the next. Called when the player closes the
--- panel (X, Escape, or a close detected after the fact); a summon left unnamed is a
--- skip (abort - the server re-asks it next summon), a named one is already saved.
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
--- tracing: whether the Examine panel and our name field are present, plus the state
--- machine's own view. Walks the tree, so it is skipped entirely unless tracing is on.
---@return string
local function uiState()
	if not diagEnabled then
		return ""
	end
	return string.format(
		"[examine=%s field=%s | current=%s answered=%s awaitingOpen=%s queued=%d]",
		tostring(findNamed("Examine") ~= nil),
		tostring(liveField() ~= nil),
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

--- Rename the examined summon to `field`'s current text. Deduped via lastSent so
--- Enter followed by a click-away (or repeated clicks) sends only once. The uuid
--- (a DataContext walk) is resolved only after we know the text actually changed.
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

--- Whether the mouse is currently over the named panel control. Read on a global
--- click to hit-test the gear / close button: unlike a per-element event
--- subscription, this works on the first Examine panel of a session too.
---@param name string
---@return boolean
local function mouseOver(name)
	local element = findNamed(name)
	if not element then
		return false
	end
	return safe(function()
		return element.IsMouseOver
	end) == true
end

--- Open the native settings overlay (on a click over the gear).
local function onGearClick()
	log("onGearClick -> native settings overlay")
	if onGearClickHandler then
		onGearClickHandler()
	end
end

--- Global key hook: Enter commits, Escape closes the panel and advances (Escape is
--- what closes Examine, so it doubles as the "next summon" step). NOTE: the engine
--- also raises ESCAPE for its own UICancel (e.g. the close button), so an "ESCAPE"
--- here is not necessarily a physical key press - the trace records it verbatim.
---@param e any
local function onKeyInput(e)
	local pressed = safe(function()
		return e.Pressed
	end)
	local key = safe(function()
		return e.Key
	end)
	-- Log only the keys we act on (plus while a session/panel is up), so the trace
	-- shows exactly what arrived without drowning in movement/hotkey spam.
	if key == "RETURN" or key == "RETURN2" or key == "KP_ENTER" or key == "ESCAPE" then
		log("onKeyInput: key =", key, "pressed =", pressed, uiState())
	end
	if pressed ~= true then
		return
	end
	if awaitingOpen then
		if key == "RETURN" or key == "RETURN2" or key == "KP_ENTER" or key == "ESCAPE" then
			log("onKeyInput: ignored (awaitingOpen)")
		end
		return
	end
	if key == "RETURN" or key == "RETURN2" or key == "KP_ENTER" then
		local field = liveField()
		if field then
			commitField(field)
		end
	elseif key == "ESCAPE" then
		finishCurrent()
	end
end

--- Keep the global key hook subscribed exactly while it is useful - during a
--- naming session, or while the panel is open for a manual rename - and dropped
--- otherwise, since KeyInput fires on every keystroke in the game.
local function refreshKeyHook()
	local want = current ~= nil or panelOpen
	if want and not keySub then
		keySub = safe(function()
			return Ext.Events.KeyInput:Subscribe(onKeyInput)
		end)
	elseif not want and keySub then
		pcall(function()
			Ext.Events.KeyInput:Unsubscribe(keySub)
		end)
		keySub = nil
	end
end

--- React to the panel opening or closing (detected by the always-live mouse hook).
--- A close we did not catch as an X/Escape still advances the active session.
---@param open boolean
local function setPanelOpen(open)
	if open == panelOpen then
		return
	end
	log("setPanelOpen:", open, uiState())
	panelOpen = open
	if not open then
		editing = false
		finishCurrent()
	end
	refreshKeyHook()
end

--- Global left-click hook (always subscribed - it is our only "panel opened"
--- detector, and it drives the gear/close hit-test since element subscriptions are
--- unreliable). A click over the close button advances the session; a click over the
--- gear opens config; otherwise it is a field click - the first captures the edit
--- baseline, a later one commits if the text changed (the click-away rename).
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
	log("onMouseButton: left click", uiState())
	-- Ignore clicks while the old panel animates shut and the next is scheduled.
	if awaitingOpen then
		log("onMouseButton: ignored (awaitingOpen)")
		return
	end
	local field = liveField()
	if field == nil then
		log("onMouseButton: no field -> treat as panel closed")
		setPanelOpen(false)
		return
	end
	setPanelOpen(true)

	local overClose = mouseOver("CloseExamine")
	local overGear = mouseOver("NYS_SettingsButton")
	log("onMouseButton: overClose =", overClose, "overGear =", overGear, "editing =", editing)

	if overClose then
		finishCurrent()
		return
	end
	if overGear then
		onGearClick()
		return
	end
	if editing then
		commitField(field)
	else
		editing = true
		lastSent = Util.Sanitise(nodeText(field))
		log("onMouseButton: baseline lastSent =", lastSent)
	end
end

---------------------------------------------------------------------------
-- On-summon naming: open the Examine panel instead of the ImGui prompt (GH #19)
---------------------------------------------------------------------------
--
-- Opening Examine on a specific creature drives native UI that has no SE/Osiris
-- entry point: fetch the game's ExamineCommand (a Noesis BaseCommand) off the root
-- DataContext and Execute it with the summon's Noesis EntityHandle - the exact
-- CommandParameter the game's own XAML binds. See docs/bg3-modding-toolchain.md.
-- Never compare a Noesis object with == nil (its __eq crashes on an expired
-- object) and never cache one across calls; fetch fresh and test with truthiness.

--- The game's ExamineCommand, found on the root DataContext (findNode visits it
--- first). Returned fresh, never cached - a stale Noesis handle crashes on use.
---@return any|nil
local function getExamineCommand()
	local root = safe(Ext.UI.GetRoot)
	if not root then
		return nil
	end
	local command
	findNode(root, 0, function(node)
		local dc = safe(function()
			return node.DataContext
		end)
		if not dc then
			return false
		end
		command = safe(function()
			return dc:GetProperty("ExamineCommand")
		end)
		return command and true or false
	end)
	return command
end

--- The Noesis EntityHandle for a summon uuid, read off any live per-entity
--- DataContext (the always-present portrait view-models carry one). The direct
--- getter returns the live object Execute needs; the property bag may copy it.
---@param uuid string
---@return any|nil
local function entityHandleFor(uuid)
	local root = safe(Ext.UI.GetRoot)
	if not root then
		return nil
	end
	local handle
	findNode(root, 0, function(node)
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
	local opened = command
		and handle
		and pcall(function()
			-- A disabled command Executes as a silent no-op, hanging the pause; CanExecute guards it.
			assert(command:CanExecute(handle))
			command:Execute(handle)
		end)
	if not opened then
		Util.Warn("Could not open Examine for summon " .. tostring(req.SummonUuid) .. "; skipping.")
		-- Nothing opened, so no close to wait for: skip and open the next at once.
		if answerSession(req, "", true) then
			startNext(false)
		end
	end
end

--- Examine the next queued request (an empty queue just clears `current`). After a
--- close, the panel's shut is animated and ExamineCommand is ignored until it is gone,
--- so defer the open by EXAMINE_CLOSE_MS; the first summon (nothing open) shows at once.
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
	refreshKeyHook()
	if not current then
		return
	end
	beginCurrent()
	if afterClose then
		awaitingOpen = true
		Ext.Timer.WaitForRealtime(EXAMINE_CLOSE_MS, function()
			if not current then
				awaitingOpen = false
				return
			end
			openExamine(current)
			-- Stay closed to input while the open animation plays, so a second, too-early
			-- close/Escape (rapid skipping) does not dismiss the panel we just opened.
			Ext.Timer.WaitForRealtime(EXAMINE_SETTLE_MS, function()
				awaitingOpen = false
			end)
		end)
	else
		openExamine(current)
	end
end

--- Find a live Noesis node by x:Name from the composition root (exposed so
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
-- "MouseButtonInput"/"KeyInput"); the IDE helper's "EclLua*" names are stale for this
-- build, and Ext.Events is not enumerable. The key hook is wired on demand elsewhere.
function NativeRenameUI.Register()
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
