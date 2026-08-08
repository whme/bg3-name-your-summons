--[[
    Client side of the native "rename this summon" control (GH #9).

    The examined creature's uuid is read from the Examine panel's Noesis
    DataContext (EntityUUID + CharacterType) and a rename is sent to the server.
    Commit is driven by global input events, not the panel's routed UI events -
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
-- tree Ext.UI.GetRoot() never receives events from, and the field's focus events do
-- not fire on the first open after a load. The global SDL-level input events fire on
-- every click and key regardless, so commit is driven by those; the gear is a plain
-- Grid whose own tunneling click is reliable and keeps a per-open subscription.
local gearWired = false -- gear click subscribed for the current panel open
local editing = false -- an edit session is active (baseline captured on first click)
local panelOpen = false -- last-seen panel presence (field exists)
local keySub = nil -- KeyInput subscription handle; only held while the panel is open
local lastSent = nil -- last committed sanitised text, to dedup Enter + click-away

--- The live rename field, or nil when no Examine panel is open.
---@return any|nil
local function liveField()
	return findNamed("NYS_NameInput")
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
	if name == "" or name == lastSent then
		return
	end
	local uuid = examinedSummonUuid()
	if uuid ~= nil and submitRename(uuid, raw) then
		lastSent = name
		Util.Log(("NYS: renamed %s -> '%s'"):format(uuid, name))
	end
end

--- Open the config window (subscribed on the gear element's tunneling click).
local function onGearClick()
	ConfigUI.Open()
end

--- Subscribe the gear's click once per panel open. The gear is a plain Grid, so its
--- own PreviewMouseLeftButtonDown fires reliably, unlike the field's focus events.
local function wireGear()
	local gear = findNamed("NYS_SettingsButton")
	if gear ~= nil then
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
		commitField(field)
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
		if keySub == nil then
			keySub = safe(function()
				return Ext.Events.KeyInput:Subscribe(onKeyInput)
			end)
		end
	else
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
		commitField(field)
	else
		editing = true
		lastSent = Util.Sanitise(nodeText(field))
	end
end

-- Event names confirmed against bg3se source (LuaClient.cpp ThrowEvent
-- "MouseButtonInput"/"KeyInput"); the IDE helper's "EclLua*" names are stale for this
-- build, and Ext.Events is not enumerable. The key hook is wired on demand elsewhere.
function NativeRenameUI.Register()
	pcall(function()
		Ext.Events.MouseButtonInput:Subscribe(onMouseButton)
	end)
end

return NativeRenameUI
