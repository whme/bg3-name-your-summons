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

    Native-UI approach (see docs/native-ui.md and docs/examine-panel.md):
    - Controls we add are driven by per-element MVVM, not global mouse hit-testing:
      the gear's Command binds to a viewmodel on its nested DataContext; the field
      commits via its own per-element subscriptions.
    - Manual-open detection is a persistent HUD overlay's DataTrigger, not an input
      hook (installHudDetector; see docs/native-ui.md). The old per-click tree scan
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
--- or a half-torn-down level can access-violate past pcall. Fails closed otherwise.
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

--- First descendant of `root` (incl. `root`) named `name`, or nil (DFS). Not for ContentRoot -
--- its landmarks are direct children (use `childrenNamed` / `bfsByName`).
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

--- Immediate children of `node` named `name` (one level; `node` excluded).
---@param node any
---@param name string
---@return any[]
local function childrenNamed(node, name)
	local out = {}
	if not node then
		return out
	end
	for i = 1, visualChildCount(node) do
		local child = safe(readChild, node, i)
		if child and widgetName(child) == name then
			out[#out + 1] = child
		end
	end
	return out
end

--- First node named `name` within `maxDepth` levels of `root` (root = depth 0), or nil (BFS).
---@param root any
---@param name string
---@param maxDepth integer
---@return any|nil
local function bfsByName(root, name, maxDepth)
	local frontier = root and { root } or {}
	local depth = 0
	while #frontier > 0 do
		local nextFrontier = {}
		for _, node in ipairs(frontier) do
			if widgetName(node) == name then
				return node
			end
			if depth < maxDepth then
				for i = 1, visualChildCount(node) do
					local child = safe(readChild, node, i)
					if child then
						nextFrontier[#nextFrontier + 1] = child
					end
				end
			end
		end
		frontier = nextFrontier
		depth = depth + 1
	end
	return nil
end

--- The composition root (`ContentRoot`), the anchor for every scan. Fetch fresh; a stale Noesis
--- handle crashes on use.
---@return any|nil
local function contentRoot()
	local root = safe(Ext.UI.GetRoot)
	return root and safe(function()
		return root:Find("ContentRoot")
	end) or nil
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

--- Call `fn` for each open Examine/Examine_c node (direct children of ContentRoot; one per viewport).
---@param fn fun(node:any)
local function forEachExamineNode(fn)
	local cr = contentRoot()
	if not cr then
		return
	end
	for i = 1, visualChildCount(cr) do
		local child = safe(readChild, cr, i)
		if child and isExamineName(widgetName(child)) then
			fn(child)
		end
	end
end

--- The open Examine node belonging to viewport `id` (its CurrentPlayer.PlayerId), or nil.
---@param id integer
---@return any|nil
local function examineNodeById(id)
	local cr = contentRoot()
	if not cr then
		return nil
	end
	for i = 1, visualChildCount(cr) do
		local child = safe(readChild, cr, i)
		if child and isExamineName(widgetName(child)) and playerIdOf(child) == id then
			return child
		end
	end
	return nil
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
	if not examine then
		return nil
	end
	local found
	findNode(examine, 0, function(node)
		local dc = safe(function()
			return node.DataContext
		end)
		if not dc then
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
			owned = false, -- summon belongs to this viewport's player; gates rename + gear
			ownedUuid = nil, -- the uuid `owned` was resolved for
			ownershipResolved = nil, -- true once the server has answered for ownedUuid
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
-- Forward-declared: commitField/flushName above gate their send on it, but it is defined below.
local canCommit

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
	-- Strict send: the display is optimistic, but never rename until ownership is confirmed.
	if not canCommit(id) then
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
	elseif field and canCommit(id) then
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
	local st = panels[id]
	-- Inert only once the server confirms the summon is another player's (optimistic until then).
	if st and st.current == nil and st.ownershipResolved and not st.owned then
		return
	end
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

--- Show or hide viewport `id`'s settings gear (its NYS_GearVM's NysShowGear flag).
---@param id integer
---@param visible boolean
local function setGearVisible(id, visible)
	local gear = findNamedIn(id, "NYS_SettingsButton")
	local vm = gear and safe(function()
		return gear.DataContext
	end)
	if vm then
		pcall(function()
			vm.NysShowGear = visible and true or false
		end)
	end
end

--- Whether to SHOW viewport `id`'s rename field + gear: true for a prompt, optimistically true for
--- a manual examine until the server says the summon is not the viewer's, false when forbidden.
---@param id integer
---@return boolean
local function isRenamable(id)
	local st = panels[id]
	if not st then
		return false
	end
	if st.current ~= nil then
		return true
	end
	local uuid = examinedSummonUuidIn(id)
	if uuid == nil then
		return false
	end
	if isForbiddenSummon(uuid) then
		return false
	end
	-- Optimistic until the server answers for THIS summon; a stale answer (ownedUuid ~= uuid) reads
	-- as unresolved so the controls do not flicker when the panel is reused for a new summon.
	if not st.ownershipResolved or st.ownedUuid ~= uuid then
		return true
	end
	return st.owned == true
end

--- Whether a rename may actually be SENT for viewport `id`: only once the server confirms the
--- summon is the viewer's own (a prompt is owned by construction). Display stays optimistic.
---@param id integer
---@return boolean
function canCommit(id)
	local st = panels[id]
	if not st then
		return false
	end
	if st.current ~= nil then
		return true
	end
	local uuid = examinedSummonUuidIn(id)
	return uuid ~= nil
		and not isForbiddenSummon(uuid)
		and st.ownershipResolved == true
		and st.owned == true
		and st.ownedUuid == uuid
end

--- Gate viewport `id`'s rename field and gear on renamability.
---@param id integer
local function applyGates(id)
	local renamable = isRenamable(id)
	setGearVisible(id, renamable)
	if renamable then
		enableEditing(id)
	else
		disableEditing(id)
	end
end

-- Bounded retry while the summon's DataContext settles: split-screen re-layout can wire the field
-- a few ticks before its summon context is readable.
local OWNERSHIP_RETRY_MS = 100
local OWNERSHIP_MAX_TRIES = 12

--- Reveal viewport `id`'s controls optimistically, then ask the server whether the summon is the
--- viewer's own (the client cannot read an owner) and keep or retract them. Retries until readable.
---@param id integer
---@param triesLeft integer|nil
local function resolveOwnership(id, triesLeft)
	triesLeft = triesLeft or OWNERSHIP_MAX_TRIES
	local st = panels[id]
	-- Panel gone or unwired (a rewire will call us again); stop retrying.
	if not st or not st.wired or st.current ~= nil then
		return
	end
	local function retry()
		if triesLeft > 0 then
			Ext.Timer.WaitForRealtime(OWNERSHIP_RETRY_MS, function()
				resolveOwnership(id, triesLeft - 1)
			end)
		end
	end
	local uuid = examinedSummonUuidIn(id)
	if uuid == nil then
		retry()
		return
	end
	if st.ownershipResolved and st.ownedUuid == uuid then
		applyGates(id)
		return
	end
	st.ownershipResolved = false
	applyGates(id)
	local viewer = selectedCharOf(examineNodeById(id))
	-- Supersede an earlier in-flight query so a slow stale reply cannot clobber a newer one.
	st.ownGen = (st.ownGen or 0) + 1
	local gen = st.ownGen
	pcall(function()
		Channels.QueryOwnership:RequestToServer({ SummonUuid = uuid, ViewerCharacter = viewer }, function(response)
			local pst = panels[id]
			if not pst or pst.ownGen ~= gen then
				return
			end
			if examinedSummonUuidIn(id) ~= uuid then
				-- The panel shifted mid-relayout; re-resolve for whatever it now shows.
				retry()
				return
			end
			pst.ownedUuid = uuid
			pst.ownershipResolved = true
			pst.owned = type(response) == "table" and response.Owned == true
			-- Never write the field text here: the OneWay Name binding already keeps the name on
			-- screen, and writing it blanked the name when captured before Name had bound.
			applyGates(id)
			if pst.owned then
				-- Flush a name the player typed during the optimistic window (held until now).
				local field = liveFieldIn(id)
				if field then
					commitField(id, field)
				end
			end
		end)
	end)
end

--- Attach viewport `id`'s gear Command viewmodel and its field's key/focus subscriptions.
--- Idempotent (guarded by st.wired); no-op until the field node exists.
---@param id integer
local function wirePanel(id)
	local st = panelState(id)
	if st.wired then
		return
	end
	-- Resolve the rename bar once; the four controls live under it, so the lookups below stay in
	-- that small subtree instead of walking the whole Examine panel four times.
	local examine = examineNodeById(id)
	local renameBar = findFrom(examine, "NYS_RenameBar")
	local field = renameBar and findFrom(renameBar, "NYS_NameInput")
	if not field then
		Trace.Log("wire", "wirePanel: rename bar / NYS_NameInput not found", {
			PlayerId = id,
			HasExamineNode = examine and true or false,
			HasRenameBar = renameBar and true or false,
		})
		return
	end
	Trace.Log("wire", "wirePanel: found rename bar + field, wiring", { PlayerId = id })

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
	local gear = findFrom(renameBar, "NYS_SettingsButton")
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
			-- Seed on the vm directly (like NysShowSkip): a just-assigned DataContext re-fetches stale.
			pcall(function()
				vm.NysShowGear = isRenamable(id)
			end)
			pcall(function()
				gear.DataContext = vm
			end)
		end
	end

	-- Skip: nested DataContext = a fresh NYS_SkipVM; NysShowSkip hides it for single summons.
	local skip = findFrom(renameBar, "NYS_SkipButton")
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
	local confirm = findFrom(renameBar, "NYS_ConfirmButton")
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

	-- A prompt is the owner's own by construction; a manual examine may be another player's
	-- summon, so ask the server.
	if st.current ~= nil then
		st.owned = true
		st.ownedUuid = examinedSummonUuidIn(id)
		st.ownershipResolved = true
		applyGates(id)
	else
		resolveOwnership(id)
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
	local examineCount = 0
	forEachExamineNode(function(node)
		examineCount = examineCount + 1
		local id = playerIdOf(node)
		-- No examinedSummonUuidIn here: it is a per-node subtree DFS and this runs every safety tick.
		Trace.Log("lifecycle", "examine node visited", { PlayerId = id })
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
	Trace.Log("lifecycle", "pollLifecycle done", { ExamineNodesFound = examineCount })
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
	local cr = contentRoot()
	local firstCmd, matchedCmd
	for _, node in ipairs(childrenNamed(cr, COMMAND_SURFACE_NODE)) do
		local dc = safe(function()
			return node.DataContext
		end)
		local cmd = dc and safe(function()
			return dc:GetProperty("ExamineCommand")
		end)
		if cmd then
			firstCmd = firstCmd or cmd
			if matchChar and surfaceSelectedChar(dc) == Util.ToUuid(matchChar) then
				matchedCmd = cmd
				break
			end
		end
	end
	return matchedCmd or firstCmd
end

-- The party portrait bar (direct child of ContentRoot) carries every summon portrait, whose
-- DataContext holds the EntityUUID + EntityHandle. Its x:Name differs by layout - PlayerPortraits
-- (keyboard) / PartyLine_c (controller) - and only one exists at a time.
local PARTY_BAR_NAMES = { "PlayerPortraits", "PartyLine_c" }

--- The Noesis EntityHandle for a summon uuid, matched by EntityUUID across the party portrait bars
--- (the portrait has no x:Name, so no `:Find`). nil if not on any bar; the caller then skips the open.
---@param uuid string
---@return any|nil
function entityHandleFor(uuid)
	local cr = contentRoot()
	local handle
	local function scanBar(bar)
		findNode(bar, 0, function(node)
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
	end
	for _, name in ipairs(PARTY_BAR_NAMES) do
		for _, bar in ipairs(childrenNamed(cr, name)) do
			scanBar(bar)
			if handle then
				return handle
			end
		end
	end
	Trace.Log("open", "entityHandleFor: summon not found in any party bar", { Uuid = uuid })
	return handle
end

--- The PlayerId of the viewport currently controlling `char` (its SelectedCharacter), or nil.
---@param char string|nil
---@return integer|nil
local function viewportIdForChar(char)
	if type(char) ~= "string" then
		return nil
	end
	local want = Util.ToUuid(char)
	local cr = contentRoot()
	for _, name in ipairs({ COMMAND_SURFACE_NODE, "Examine", "Examine_c" }) do
		for _, node in ipairs(childrenNamed(cr, name)) do
			if selectedCharOf(node) == want then
				local id = playerIdOf(node)
				if id then
					return id
				end
			end
		end
	end
	return nil
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
	Trace.Log("open", "openExamine resolving", {
		SummonUuid = req.SummonUuid,
		ViewportChar = req.ViewportChar,
		HasCommand = command and true or false,
		HasHandle = handle and true or false,
	})
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
-- element:Resource(). See docs/native-ui.md.
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
local hudInstalled = false
local reconcileGen = 0 -- bumped per signal so a newer change supersedes older retries
local rewireGen = 0 -- bumped per rewire burst so an older burst's retries stop

--- Detected by a `NysWired` Bool marker prop, not the Command (reading a Command back is unreliable).
---@param host any
---@return boolean
local function hostIsWired(host)
	local dc = host and safe(function()
		return host.DataContext
	end)
	return (dc and dcProp(dc, "NysWired")) == true
end

-- The rename bar renders a beat after the examine target is set, so reconcile on a fine-grained
-- bounded retry (gen-deduped) that reveals the controls without a visible lag, and exits as soon
-- as every open panel is latched rather than running all TRIES passes.
local DETECT_RECONCILE_MS = 25
local DETECT_RECONCILE_TRIES = 24
local DETECT_SETTLE_PASSES = 2

--- Whether every open Examine panel is now wired (or mid-open), so the reconcile burst can stop.
---@return boolean
local function examinesSettled()
	if next(openIds) == nil then
		return false
	end
	for id in pairs(openIds) do
		local st = panels[id]
		if not st or (not st.wired and not st.awaitingOpen) then
			return false
		end
	end
	return true
end

--- Manual panels are unwired first so a re-open re-subscribes; an active on-summon session is left alone.
local function onExamineDetected()
	Trace.Log("detect", "onExamineDetected (overlay DataTrigger fired)")
	reconcileGen = reconcileGen + 1
	local gen = reconcileGen
	for id, st in pairs(panels) do
		if st.wired and st.current == nil then
			unwirePanel(id)
		end
	end
	local function pass(triesLeft, settle)
		if gen ~= reconcileGen then
			return
		end
		pollLifecycle()
		if examinesSettled() then
			-- Latched. A couple of safety passes catch a laggy second split-screen viewport, then stop.
			if settle <= 0 then
				return
			end
			settle = settle - 1
		else
			settle = DETECT_SETTLE_PASSES
		end
		if triesLeft > 0 then
			Ext.Timer.WaitForRealtime(DETECT_RECONCILE_MS, function()
				pass(triesLeft - 1, settle)
			end)
		end
	end
	pass(DETECT_RECONCILE_TRIES, DETECT_SETTLE_PASSES)
end

---@param host any
local function wireHost(host)
	local vm = safe(function()
		return Ext.UI.Instantiate(DETECT_VM)
	end)
	if not vm then
		Trace.Log("detect", "wireHost: Instantiate(DETECT_VM) failed")
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
	if Trace.Enabled() then
		Trace.Log("detect", "wireHost: set DataContext on NYS_HudVmHost", { NowWired = hostIsWired(host) })
	end
end

--- Wire every unwired overlay host; returns the count now wired (not merely present), so a failed
--- wire keeps a burst retrying.
---@return integer
local function ensureOverlaysWired()
	local wired = 0
	local cr = contentRoot()
	for _, overlay in ipairs(childrenNamed(cr, "NYS_HudOverlay")) do
		local host = bfsByName(overlay, "NYS_HudVmHost", 2)
		if host then
			if not hostIsWired(host) then
				wireHost(host)
			end
			if hostIsWired(host) then
				wired = wired + 1
			end
		end
	end
	Trace.Log(
		"detect",
		"ensureOverlaysWired (direct navigation)",
		{ HasContentRoot = cr and true or false, HostsWired = wired }
	)
	return wired
end

-- The HUD rebuild fires no event and the new host lags it, so retry on a bounded schedule then stop.
-- Re-wiring is event-driven, never polled; the authoritative trigger list is in docs/examine-panel.md.
local REWIRE_INTERVAL_MS = 400
local REWIRE_MAX_TRIES = 25

local function rewireBurst()
	rewireGen = rewireGen + 1
	local gen = rewireGen
	local safetyPasses = 2
	local function pass(tries)
		if gen ~= rewireGen then
			return
		end
		local wired = scanAllowed() and ensureOverlaysWired() or 0
		if wired > 0 then
			safetyPasses = safetyPasses - 1
			if safetyPasses < 0 then
				return
			end
		end
		if tries + 1 < REWIRE_MAX_TRIES then
			Ext.Timer.WaitForRealtime(REWIRE_INTERVAL_MS, function()
				pass(tries + 1)
			end)
		end
	end
	pass(0)
end

-- No BG3SE input-mode event, but a kbm<->controller switch (which can rebuild the HUD) brings an
-- input on the new device, so re-wire on a device-kind change.
local lastInputKind = nil
local function onInput(kind)
	if kind == lastInputKind then
		return
	end
	lastInputKind = kind
	Trace.Log("detect", "input-kind change -> rewire burst", { Kind = kind })
	rewireBurst()
end

--- Subscribe the HUD-rebuild triggers that re-wire the overlay; the wiring persists, so no idle poll.
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
	-- Each wrapped so a name gone stale on a future build cannot tear down the module; the rest bind.
	pcall(function()
		Ext.Events.MouseButtonInput:Subscribe(function()
			onInput("kbm")
		end)
	end)
	pcall(function()
		Ext.Events.KeyInput:Subscribe(function()
			onInput("kbm")
		end)
	end)
	pcall(function()
		Ext.Events.ControllerButtonInput:Subscribe(function()
			onInput("pad")
		end)
	end)
	-- A split-screen viewport join/leave resizes viewports but fires no session/reset/input-kind
	-- change, so its new overlay host would go unwired without this.
	pcall(function()
		Ext.Events.ViewportResized:Subscribe(rewireBurst)
	end)
	pcall(function()
		Ext.Events.ResetCompleted:Subscribe(rewireBurst)
	end)
	-- The world coming up (re)builds the HUD but fires none of the triggers above on a keyboard-only
	-- session; guarding on FromState fires the backstop only on entry INTO a world-up state, not on
	-- in-play pause/unpause (which rebuild nothing). Clearing the latch re-arms a kbm burst that a
	-- pre-load menu keypress would otherwise suppress.
	pcall(function()
		local function isWorldUp(state)
			return state == "Running" or state == "Paused"
		end
		Ext.Events.GameStateChanged:Subscribe(function(e)
			local to = safe(function()
				return tostring(e.ToState)
			end)
			local from = safe(function()
				return tostring(e.FromState)
			end)
			if isWorldUp(to) and not isWorldUp(from) then
				lastInputKind = nil
				rewireBurst()
			end
		end)
	end)
	rewireBurst()
end

-- !nys_uidump maps how to reach our landmark nodes. Empirically element:Find resolves a name only
-- WITHIN one namescope (finds ContentRoot from the UI root, but not HudIndicator/NYS_HudVmHost from
-- ContentRoot), which is why the module navigates by structure rather than a single :Find.
local UIDUMP_NAMES = {
	"ContentRoot",
	"HudIndicator",
	"NYS_HudOverlay",
	"NYS_HudVmHost",
	"PlayerHUD",
	"Examine",
	"Examine_c",
	"NYS_NameInput",
	"NYS_SettingsButton",
}

--- Every named node under `node` as "Name @depth (Nch)" strings.
---@param node any
---@param depth integer
---@param out string[]
local function collectNamed(node, depth, out)
	if not node or depth > SEARCH_DEPTH_LIMIT then
		return
	end
	local nm = widgetName(node)
	if nm ~= "" then
		out[#out + 1] = string.format("%s @%d (%dch)", nm, depth, visualChildCount(node))
	end
	for i = 1, visualChildCount(node) do
		collectNamed(safe(readChild, node, i), depth + 1, out)
	end
end

--- For each named ancestor of `node` (nearest first), whether `ancestor:Find(name)` resolves -
--- reveals the shallowest namescope a native :Find could reach `name` from.
---@param node any
---@param name string
---@return table[]
local function ancestryReach(node, name)
	local out = {}
	local cur = safe(function()
		return node.VisualParent
	end)
	local guard = 0
	while cur and guard < SEARCH_DEPTH_LIMIT do
		guard = guard + 1
		local nm = widgetName(cur)
		if nm ~= "" then
			local hit = safe(function()
				return cur:Find(name)
			end)
			out[#out + 1] = { Ancestor = nm, FindResolves = (hit and true) or false }
		end
		cur = safe(function()
			return cur.VisualParent
		end)
	end
	return out
end

local function dumpUiStructure()
	-- Walks the whole tree, so gate on a live world: a foreign-tree walk can access-violate past
	-- pcall (#99).
	if not scanAllowed() then
		Util.Say(("UI dump skipped: game state is %s, need Running/Paused."):format(tostring(gameStateName())))
		return
	end
	local root = safe(Ext.UI.GetRoot)
	local cr = contentRoot()
	Util.Say(
		("UI dump: UIRoot=%s ContentRoot=%s state=%s -> nys-trace-client.jsonl"):format(
			tostring(root and true or false),
			tostring(cr and true or false),
			tostring(gameStateName())
		)
	)
	local wasTracing = Trace.Enabled()
	Trace.SetEnabled(true) -- capture the dump even if !nys_trace was off
	Trace.Log(
		"uidump",
		"begin",
		{ HasUIRoot = root and true or false, HasContentRoot = cr and true or false, State = gameStateName() }
	)

	if cr then
		local named = {}
		collectNamed(cr, 0, named)
		Trace.Log("uidump", "named nodes under ContentRoot", { Count = #named })
		local chunk = {}
		for i, s in ipairs(named) do
			chunk[#chunk + 1] = s
			if #chunk >= 50 or i == #named then
				Trace.Log("uidump-nodes", "chunk", chunk)
				chunk = {}
			end
		end
	end

	for _, name in ipairs(UIDUMP_NAMES) do
		local fromRoot = root and safe(function()
			return root:Find(name)
		end)
		local fromCr = cr and safe(function()
			return cr:Find(name)
		end)
		local node = cr and findFrom(cr, name)
		local entry = {
			FindFromUIRoot = (fromRoot and true) or false,
			FindFromContentRoot = (fromCr and true) or false,
			FoundByDfs = (node and true) or false,
		}
		if node then
			entry.Ancestry = ancestryReach(node, name)
		end
		Trace.Log("uidump-target", name, entry)
	end

	Trace.Log("uidump", "end")
	-- Restore the prior trace state: the lifecycle/detect hooks would otherwise rewrite the trace
	-- file every heartbeat until !nys_trace is toggled off.
	Trace.SetEnabled(wasTracing)
	Util.Say("UI dump written to nys-trace-client.jsonl. Please send that file.")
end

function NativeRenameUI.Register()
	pcall(function()
		Ext.RegisterConsoleCommand("nys_uidump", dumpUiStructure)
	end)
	pcall(function()
		Ext.UI.RegisterType(GEAR_VM, { NysGearCommand = { Type = "Command" }, NysShowGear = { Type = "Bool" } })
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
	-- A session load rebuilds the HUD, dropping our overlay wiring, so re-wire on it too.
	pcall(function()
		Ext.Events.SessionLoaded:Subscribe(function()
			refreshSettingsCache()
			-- Re-arm the input-kind backstop: a menu keyboard input may have latched it pre-load.
			lastInputKind = nil
			rewireBurst()
		end)
	end)

	-- Re-gate every open panel so a story summon that just became (dis)allowed updates its
	-- field and gear at once. Ownership is cached per panel, so this reuses it.
	Channels.SettingsChanged:SetHandler(function(data, _user)
		if type(data) ~= "table" then
			return
		end
		cachedAllowStory = data.AllowStorySummons == true
		for id, st in pairs(panels) do
			if st.wired then
				applyGates(id)
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
