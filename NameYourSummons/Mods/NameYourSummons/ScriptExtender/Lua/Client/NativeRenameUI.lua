--[[
    Client side of the native "rename this summon" control (GH #9).

    The examined creature's identity is read from the Examine panel's Noesis
    DataContext, which exposes EntityUUID + CharacterType. This module:
      - reads the uuid of the summon on the open Examine screen (ExaminedSummonUuid),
      - sends a rename to the server (SubmitRename), and
      - drives the native name field: Enter or clicking away renames it, and the
        gear button opens the config window.

    Commit is driven by global input events, not the panel's own routed UI events -
    see the note above the control handlers for why.
]]

local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local ConfigUI = Ext.Require("Client/ConfigUI.lua")

local NativeRenameUI = {}

local UUID_PATTERN = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"
local MAX_DEPTH = 60

local function safe(fn, ...)
	local ok, res = pcall(fn, ...)
	if ok then
		return res
	end
	return nil
end

-- Shared readers for the hot visual-tree walk. Defined once (not per node) so the
-- traversal does not allocate a fresh closure for every property/child access - that
-- allocation load was the bulk of the walk's cost. VisualChild is 1-based (verified
-- in bg3se: GetVisualChild returns child index-1 for index in 1..count).
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

--- Depth-first collect of EVERY node (incl. `node`) satisfying `predicate` into
--- `out`. Used because the tree can hold more than one node with a given Name (a
--- stale panel plus the live one); we must act on all of them, not just the first.
---@param node any
---@param depth integer
---@param predicate fun(node:any):boolean
---@param out any[]
local function findAllNodes(node, depth, predicate, out)
	if node == nil or depth > MAX_DEPTH then
		return
	end
	if predicate(node) then
		out[#out + 1] = node
	end
	for i = 1, visualChildCount(node) do
		findAllNodes(safe(readChild, node, i), depth + 1, predicate, out)
	end
end

--- Read a Noesis property, preferring the direct getter and falling back to the
--- dynamic property bag (these view models expose runtime props via either).
---@param dc any
---@param key string
---@return any
local function dcProp(dc, key)
	-- Prefer the property bag: these runtime props live there, and asking the typed
	-- getter for one it lacks (e.g. EntityUUID on DCExamine) logs a Noesis warning.
	local all = safe(function()
		return dc:GetAllProperties()
	end)
	if type(all) == "table" and all[key] ~= nil then
		return all[key]
	end
	return safe(function()
		return dc:GetProperty(key)
	end)
end

--- The uuid of the summon shown on the currently-open Examine screen, or nil.
--- Finds the Examine panel, then the first descendant whose DataContext carries
--- an EntityUUID and a "Summon" CharacterType (the examined-creature view model,
--- inherited down the subtree).
---@return string|nil
function NativeRenameUI.ExaminedSummonUuid()
	local root = safe(Ext.UI.GetRoot)
	if root == nil then
		return nil
	end
	local examine = findNode(root, 0, function(node)
		return widgetName(node) == "Examine"
	end)
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

--- Send a rename for a specific summon uuid. Returns false on empty input.
---@param uuid string
---@param rawName string
---@return boolean
function NativeRenameUI.SubmitRename(uuid, rawName)
	local name = Util.Sanitise(rawName)
	if type(uuid) ~= "string" or name == "" then
		return false
	end
	Channels.RenameSummon:SendToServer({ SummonUuid = uuid, Name = name })
	return true
end

---------------------------------------------------------------------------
-- Native controls: Enter or click-away renames the summon; the gear opens config
---------------------------------------------------------------------------
--
-- The Examine panel's own routed UI events are unreliable: the panel is a separate
-- Noesis popup tree that Ext.UI.GetRoot() never receives events from, and the
-- field's focus events (LostKeyboardFocus etc.) do not fire on the first open after
-- a load. What IS reliable are the global SDL-level input events, which fire on
-- every click and key regardless of what the UI consumes. So the rename is driven
-- by those:
--   - Enter (KeyInput) commits the field's current text,
--   - clicking away after editing commits it too (MouseButtonInput), deduped,
--   - the examined summon's uuid (a DataContext walk) is resolved only at commit.
-- The gear is a plain Grid whose own tunneling click IS reliable, so it keeps a
-- per-open element subscription.
local DEBUG = false -- flip to true for verbose client-side lifecycle logging
local gearWired = false -- gear click subscribed for the current panel open
local editing = false -- an edit session is active (baseline captured on first click)
local panelOpen = false -- last-seen panel presence (field exists), for open/close logs
local keySub = nil -- KeyInput subscription handle; only held while the panel is open
local lastSent = nil -- last committed sanitised text, to dedup Enter + click-away

local function dbg(...)
	if DEBUG then
		Util.Log(...)
	end
end

--- Every visual node whose Name matches, found from the composition root.
---@param name string
---@return any[]
local function collectNamed(name)
	local out = {}
	local root = safe(Ext.UI.GetRoot)
	if root ~= nil then
		findAllNodes(root, 0, function(node)
			return widgetName(node) == name
		end, out)
	end
	return out
end

--- The live rename field (first NYS_NameInput in the tree), or nil when no Examine
--- panel is open. Early-exit search, so a click with no panel open stays cheap.
---@return any|nil
local function liveField()
	local root = safe(Ext.UI.GetRoot)
	if root == nil then
		return nil
	end
	return findNode(root, 0, function(node)
		return widgetName(node) == "NYS_NameInput"
	end)
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
local function commitField(field, reason)
	local raw = safe(function()
		return field.Text
	end)
	local name = type(raw) == "string" and Util.Sanitise(raw) or ""
	if name == "" or name == lastSent then
		dbg(("NYS: commit(%s) skipped (name='%s' last='%s')"):format(reason, name, tostring(lastSent)))
		return
	end
	local uuid = NativeRenameUI.ExaminedSummonUuid()
	dbg(("NYS: commit(%s) name='%s' uuid=%s"):format(reason, name, tostring(uuid)))
	if uuid ~= nil and NativeRenameUI.SubmitRename(uuid, raw) then
		lastSent = name
		Util.Log(("NYS: renamed %s -> '%s'"):format(uuid, name))
	end
end

--- Open the config window (subscribed on the gear element's tunneling click).
local function onGearClick()
	dbg("NYS: gear clicked -> open config")
	ConfigUI.Open()
end

--- Subscribe the gear's click once per panel open. The gear is a plain Grid, so its
--- own PreviewMouseLeftButtonDown fires reliably, unlike the field's focus events.
local function wireGear()
	for _, gear in ipairs(collectNamed("NYS_SettingsButton")) do
		pcall(function()
			gear:Subscribe("PreviewMouseLeftButtonDown", onGearClick)
		end)
	end
end

--- Global key hook (subscribed only while the panel is open): Enter commits.
---@param e any
local function onKeyInput(e)
	if safe(function()
		return e.Pressed
	end) ~= true then
		return
	end
	local key = safe(function()
		return e.Key
	end)
	if key ~= "RETURN" and key ~= "RETURN2" and key ~= "KP_ENTER" then
		return
	end
	local field = liveField()
	if field ~= nil then
		dbg("NYS: enter pressed")
		commitField(field, "enter")
	end
end

--- React to the panel opening or closing. KeyInput fires on every keystroke in the
--- game, so we only subscribe it while the panel is open (and drop it on close) -
--- otherwise it would burn dispatch time on movement/hotkeys/console typing.
---@param open boolean
local function setPanelOpen(open)
	if open == panelOpen then
		return
	end
	panelOpen = open
	if open then
		dbg("NYS: panel open")
		if keySub == nil then
			keySub = safe(function()
				return Ext.Events.KeyInput:Subscribe(onKeyInput)
			end)
		end
	else
		dbg("NYS: panel closed")
		gearWired = false
		editing = false
		if keySub ~= nil then
			pcall(function()
				Ext.Events.KeyInput:Unsubscribe(keySub)
			end)
			keySub = nil
		end
	end
end

--- Global left-click hook (always subscribed - it is our only "panel opened"
--- detector). The first click while the panel is open captures the field's current
--- text as the edit baseline; any later click commits the field if its text changed
--- (the click-away rename). Opening/closing also (un)subscribes the key hook.
---@param e any
local function onMouseButton(e)
	if safe(function()
		return e.Pressed
	end) ~= true or safe(function()
		return e.Button
	end) ~= 1 then
		return
	end
	local field = liveField()
	if field == nil then
		setPanelOpen(false)
		return
	end
	setPanelOpen(true)
	if not gearWired then
		wireGear()
		gearWired = true
	end
	if editing then
		commitField(field, "click-away")
	else
		editing = true
		lastSent = Util.Sanitise(nodeText(field))
		dbg(("NYS: edit session start; baseline='%s'"):format(tostring(lastSent)))
	end
end

-- Global input event names, confirmed against bg3se source (LuaClient.cpp:
-- ThrowEvent("MouseButtonInput"/"KeyInput", ...)); the IDE helper's "EclLua*" names
-- are stale for this build, and Ext.Events is not enumerable. Only the mouse hook
-- is always live; the key hook is subscribed on demand (see setPanelOpen).
function NativeRenameUI.Register()
	pcall(function()
		Ext.Events.MouseButtonInput:Subscribe(onMouseButton)
	end)
end

return NativeRenameUI
