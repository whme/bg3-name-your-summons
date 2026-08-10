-- SPDX-License-Identifier: MIT
--[[
    Native (NoesisGUI) settings panel, opened by the Examine gear (GH #20).

    The markup is an NYS_SettingsPanel overlay in the Examine.xaml override; its
    DataContext is an SE viewmodel (Ext.UI.RegisterType / Instantiate). Bool props
    drive the checkboxes, Collections feed the ItemsControls, Command props back
    the buttons. Every viewmodel field is prefixed `Nys` so it cannot collide with
    a built-in Noesis/WPF property (an unprefixed `Name` did - it aliased
    FrameworkElement.Name and the edit box round-tripped the literal "Name").

    Two hard-won engine constraints shape this module:

    1. A viewmodel/node reference obtained from Lua does NOT survive across ticks -
       the object lives on as the panel's DataContext, but any Lua handle to it
       expires. So we never cache the viewmodel; we re-fetch it live from the panel
       (liveVm) at each point of use, and inside a WriteCallback we use the live
       `context`/`value` it is handed.
    2. An SE Collection is append-only from Lua: Clear/RemoveAt/table.remove and
       whole-array assignment all fail (the ONE in-place exception is `coll[i] = nil`,
       which removes a single element - we do not rely on it here). The only way to
       get a wholly clean list is a fresh viewmodel (its collections start empty), so
       the panel is fully rebuilt on every open/refresh/save/forget via `populate`,
       guarded by a generation counter so a slow in-flight reply cannot append to a
       newer viewmodel.

    There is no SE API to create a standalone native window, so the panel lives
    inside a page we already override (Examine); NativeRenameUI owns panel
    detection and feeds this module the node finder and the gear hook.
]]

local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Classifier = Ext.Require("Shared/SummonClassifier.lua")

local NativeConfigUI = {}

-- Registered viewmodel type names; must be unique system-wide (hence the prefix).
local SETTINGS_VM = "NYS_SettingsVM"
local TOGGLE_VM = "NYS_TypeToggleVM"
local NAME_ROW_VM = "NYS_NameRowVM"

local panelFinder -- fun(name):node|nil - finds a live Noesis node by x:Name

-- Saved-name row identity/baseline, keyed by rowId (plain strings, safe to cache
-- unlike viewmodel handles). A name edit commits live when its field loses focus
-- (onNameWrite); forgets are staged here and flushed when the panel closes
-- (flushStaged), so they keep an Undo affordance while it is open (GH #76).
local rowMeta = {} -- rowId -> { Key = .., Slot = .. }
local originalNames = {} -- rowId -> baseline name text
local pendingForgets = {} -- saved-name rowId -> true

-- Bumped on every (re)populate; async replies from an older generation are stale
-- and must not touch the current viewmodel (see the module header, constraint 2).
local generation = 0

-- The generation whose settings reply has landed. pushSettings reads settings off
-- the viewmodel, so it must wait for this to catch up to `generation` or a toggle
-- fired mid-load would push the fresh viewmodel's default (all-false) settings over
-- the real ones.
local settingsLoadedGen = 0

-- Guards the `onSettingWrite` recompute against the bulk programmatic writes we do
-- while loading a viewmodel (those must not be treated as user edits).
local suppressWrite = false

local populate

---------------------------------------------------------------------------
-- Guarded accessors (a dead node/prop must never tear down the Lua state)
---------------------------------------------------------------------------

local function get(obj, key)
	local ok, value = pcall(function()
		return obj[key]
	end)
	if ok then
		return value
	end
	return nil
end

local function set(obj, key, value)
	pcall(function()
		obj[key] = value
	end)
end

local function count(coll)
	local n = 0
	pcall(function()
		n = #coll
	end)
	return n
end

local function appendItem(coll, item)
	pcall(function()
		coll[#coll + 1] = item
	end)
end

local function instantiate(typeName)
	local ok, obj = pcall(function()
		return Ext.UI.Instantiate(typeName)
	end)
	if ok then
		return obj
	end
	return nil
end

--- The live settings viewmodel (the panel's DataContext). Valid only in the
--- immediate scope - re-fetch every time; never cache across calls/ticks.
---@return any|nil
local function liveVm()
	if not panelFinder then
		return nil
	end
	local panel = panelFinder("NYS_SettingsPanel")
	if not panel then
		return nil
	end
	local ok, dc = pcall(function()
		return panel.DataContext
	end)
	if ok then
		return dc
	end
	return nil
end

---------------------------------------------------------------------------
-- Row/label helpers (shaped to match the server's net-channel payloads)
---------------------------------------------------------------------------

local function ownerLabel(entry)
	if type(entry.OwnerName) == "string" and entry.OwnerName ~= "" then
		return entry.OwnerName
	end
	return "Unknown summoner (" .. tostring(entry.Owner):sub(1, 8) .. ")"
end

--- A stable per-row id. A unique set has several rows under one key, so the slot
--- disambiguates them; a plain saved name has no slot and keys by itself.
local function stageId(entry)
	if entry.Slot then
		return entry.Key .. "#" .. tostring(entry.Slot)
	end
	return entry.Key
end

local function rowLabel(entry)
	local name = entry.TemplateName or "Summon"
	if entry.Slot then
		name = name .. " #" .. tostring(entry.Slot)
	end
	-- Tag the row with its type (GH #47).
	if type(entry.Type) == "string" and entry.Type ~= "" then
		name = name .. " (" .. entry.Type .. ")"
	end
	return name
end

---------------------------------------------------------------------------
-- Dependent enable/disable and multi-summon mode
---------------------------------------------------------------------------

--- The selected multi-summon mode value from the dropdown.
local function selectedMode(v)
	return get(v, "NysModeValue") or "skip"
end

--- Grey the toggles that cannot take effect: the "every summon" master overrides
--- the per-type list, and nothing is filtered when prompting is off. `v` is the
--- live viewmodel (usually the WriteCallback's context).
local function recomputeEnabled(v)
	local promptOn = get(v, "NysPromptOnSummon") == true
	set(v, "NysPromptForNamedEnabled", promptOn)
	set(v, "NysNameEverySummonEnabled", promptOn)
	local locked = (not promptOn) or (get(v, "NysNameEverySummon") == true)
	local toggles = get(v, "NysTypeToggles")
	for index = 1, count(toggles) do
		set(toggles[index], "NysEnabled", not locked)
	end
end

---------------------------------------------------------------------------
-- WriteCallbacks (Noesis hands them the LIVE context and new value)
---------------------------------------------------------------------------

--- Send the whole settings object to the server. Settings are live (GH #76), so
--- this fires from every setting WriteCallback instead of a Save button.
local function pushSettings()
	local v = liveVm()
	if not v then
		return
	end
	-- Before the settings reply lands the viewmodel holds only its all-false
	-- defaults; pushing then would overwrite the real settings with them.
	if settingsLoadedGen ~= generation then
		return
	end
	local settings = {
		PromptOnSummon = get(v, "NysPromptOnSummon") == true,
		PromptForNamed = get(v, "NysPromptForNamed") == true,
		PauseOnPrompt = get(v, "NysPauseOnPrompt") == true,
		AllowStorySummons = get(v, "NysAllowStorySummons") == true,
		MultiSummonMode = selectedMode(v),
		[Classifier.MASTER_KEY] = get(v, "NysNameEverySummon") == true,
	}
	local toggles = get(v, "NysTypeToggles")
	for index, cat in ipairs(Classifier.CATEGORIES) do
		local toggle = toggles and toggles[index]
		settings[Classifier.SettingKey(cat.key)] = toggle ~= nil and get(toggle, "NysChecked") == true
	end
	Channels.SetSettings:SendToServer(settings)
end

local function onSettingWrite(context)
	if suppressWrite then
		return
	end
	recomputeEnabled(context)
	pushSettings()
end

--- WriteCallback for props that only need a live push (the mode dropdown value and
--- each per-type toggle); recompute is handled by the booleans' onSettingWrite.
local function pushIfLive()
	if suppressWrite then
		return
	end
	pushSettings()
end

--- Commit an edited saved name when its field loses focus (the row binding uses
--- UpdateSourceTrigger=LostFocus, so this fires on blur, which is also how Enter
--- arrives on the LSTextBox). A row staged for forget is left alone.
local function onNameWrite(context)
	if suppressWrite then
		return
	end
	local id = get(context, "NysRowId")
	local meta = id and rowMeta[id]
	if not meta or pendingForgets[id] then
		return
	end
	local text = Util.Sanitise(get(context, "NysNameText") or "")
	if text == "" or text == originalNames[id] then
		return
	end
	originalNames[id] = text
	Channels.RenameName:SendToServer({ Key = meta.Key, Slot = meta.Slot, Name = text })
end

---------------------------------------------------------------------------
-- Staged row actions (toggle a forget / un-skip; flushed when the panel closes)
---------------------------------------------------------------------------

--- The live row in `collKey` whose NysRowId matches `id`, or nil. Used to update
--- a single row's label/enabled state in place (re-fetched, never cached).
local function findLiveRow(collKey, id)
	local v = liveVm()
	local coll = v and get(v, collKey)
	for index = 1, count(coll) do
		local row = coll[index]
		if get(row, "NysRowId") == id then
			return row
		end
	end
	return nil
end

local function toggleForget(id)
	if not rowMeta[id] then
		return
	end
	local row = findLiveRow("NysSavedNames", id)
	if pendingForgets[id] then
		pendingForgets[id] = nil
		set(row, "NysForgetLabel", "Forget")
		set(row, "NysNameEnabled", true)
	else
		pendingForgets[id] = true
		set(row, "NysForgetLabel", "Undo")
		set(row, "NysNameEnabled", false)
	end
end

---------------------------------------------------------------------------
-- Load from the server into the just-built viewmodel (guarded by generation)
---------------------------------------------------------------------------

local function loadSettings(gen)
	Channels.GetSettings:RequestToServer({}, function(response)
		if gen ~= generation then
			return
		end
		local v = liveVm()
		if not v then
			return
		end
		local s = response or {}
		local modeVal = s.MultiSummonMode or "skip"

		suppressWrite = true
		set(v, "NysPromptOnSummon", s.PromptOnSummon ~= false)
		set(v, "NysPromptForNamed", s.PromptForNamed == true)
		set(v, "NysPauseOnPrompt", s.PauseOnPrompt == true)
		set(v, "NysAllowStorySummons", s.AllowStorySummons == true)
		set(v, "NysNameEverySummon", s[Classifier.MASTER_KEY] == true)
		set(v, "NysModeValue", modeVal)
		local toggles = get(v, "NysTypeToggles")
		for index, cat in ipairs(Classifier.CATEGORIES) do
			local toggle = toggles and toggles[index]
			if toggle then
				set(toggle, "NysChecked", s[Classifier.SettingKey(cat.key)] == true)
			end
		end
		suppressWrite = false

		recomputeEnabled(v)
		settingsLoadedGen = gen
	end)
end

local function refreshNames(gen)
	Channels.ListNames:RequestToServer({}, function(response)
		if gen ~= generation then
			return
		end
		local v = liveVm()
		if not v then
			return
		end
		local coll = get(v, "NysSavedNames")
		local entries = (response and response.Entries) or {}
		set(v, "NysHasSavedNames", #entries > 0)
		-- Server-populated NysNameText must not fire onNameWrite (user edits only).
		suppressWrite = true
		for _, entry in ipairs(entries) do
			local id = stageId(entry)
			rowMeta[id] = { Key = entry.Key, Slot = entry.Slot }
			originalNames[id] = entry.Name

			local row = instantiate(NAME_ROW_VM)
			if row then
				set(row, "NysRowId", id)
				set(row, "NysOwnerLabel", ownerLabel(entry))
				set(row, "NysRowLabel", rowLabel(entry))
				set(row, "NysNameText", entry.Name)
				set(row, "NysForgetLabel", "Forget")
				set(row, "NysNameEnabled", true)
				pcall(function()
					row.NysForgetCommand:SetHandler(function()
						toggleForget(id)
					end)
				end)
				appendItem(coll, row)
			end
		end
		suppressWrite = false
	end)
end

---------------------------------------------------------------------------
-- Flush staged forgets when the panel closes (GH #76)
---------------------------------------------------------------------------

--- Commit the staged forgets, then clear the stage. Both close paths (the overlay
--- button and the whole panel closing) call it, so clearing the table keeps it
--- idempotent. Reads only the cached tables, so it is safe once the live node is
--- gone.
local function flushStaged()
	-- ForgetSlot compacts the unique set, so several slots under one key must be
	-- sent highest-first; otherwise each removal shifts the ones still to come.
	local forgetSlotsByKey = {}
	for id in pairs(pendingForgets) do
		local meta = rowMeta[id]
		local slots = forgetSlotsByKey[meta.Key]
		if not slots then
			slots = {}
			forgetSlotsByKey[meta.Key] = slots
		end
		if meta.Slot then
			slots[#slots + 1] = meta.Slot
		end
	end
	for key, slots in pairs(forgetSlotsByKey) do
		if #slots == 0 then
			Channels.ForgetName:SendToServer({ Key = key })
		else
			table.sort(slots, function(left, right)
				return left > right
			end)
			for _, slot in ipairs(slots) do
				Channels.ForgetName:SendToServer({ Key = key, Slot = slot })
			end
		end
	end
	pendingForgets = {}
end

---------------------------------------------------------------------------
-- Viewmodel type registration
---------------------------------------------------------------------------

local function registerTypes()
	pcall(function()
		Ext.UI.RegisterType(SETTINGS_VM, {
			NysIsOpen = { Type = "Bool", Notify = true },
			NysTypesExpanded = { Type = "Bool", Notify = true },
			NysPromptOnSummon = { Type = "Bool", Notify = true, WriteCallback = onSettingWrite },
			NysPromptForNamed = { Type = "Bool", Notify = true, WriteCallback = onSettingWrite },
			NysPauseOnPrompt = { Type = "Bool", Notify = true, WriteCallback = onSettingWrite },
			NysAllowStorySummons = { Type = "Bool", Notify = true, WriteCallback = onSettingWrite },
			NysPromptForNamedEnabled = { Type = "Bool", Notify = true },
			NysNameEverySummon = { Type = "Bool", Notify = true, WriteCallback = onSettingWrite },
			NysNameEverySummonEnabled = { Type = "Bool", Notify = true },
			NysModeValue = { Type = "String", Notify = true, WriteCallback = pushIfLive },
			NysModeOpen = { Type = "Bool", Notify = true },
			NysSelectSkipCommand = { Type = "Command" },
			NysSelectSharedCommand = { Type = "Command" },
			NysSelectUniqueCommand = { Type = "Command" },
			NysTypeToggles = { Type = "Collection" },
			NysSavedNames = { Type = "Collection" },
			NysHasSavedNames = { Type = "Bool", Notify = true },
			NysRefreshCommand = { Type = "Command" },
			NysCloseCommand = { Type = "Command" },
			NysToggleTypesCommand = { Type = "Command" },
			-- Controller-only: on a gamepad a checkbox is a focusable button toggled by accept
			-- (there is no mouse click on the TickBox), one command per boolean (GH #6).
			NysTogglePromptOnSummonCommand = { Type = "Command" },
			NysTogglePromptForNamedCommand = { Type = "Command" },
			NysTogglePauseOnPromptCommand = { Type = "Command" },
			NysToggleAllowStoryCommand = { Type = "Command" },
			NysToggleNameEveryCommand = { Type = "Command" },
		})
		Ext.UI.RegisterType(TOGGLE_VM, {
			NysLabel = { Type = "String" },
			NysChecked = { Type = "Bool", Notify = true, WriteCallback = pushIfLive },
			NysEnabled = { Type = "Bool", Notify = true },
			NysToggleCommand = { Type = "Command" },
		})
		Ext.UI.RegisterType(NAME_ROW_VM, {
			NysRowId = { Type = "String" },
			NysOwnerLabel = { Type = "String" },
			NysRowLabel = { Type = "String" },
			NysNameText = { Type = "String", Notify = true, WriteCallback = onNameWrite },
			NysNameEnabled = { Type = "Bool", Notify = true },
			NysForgetLabel = { Type = "String", Notify = true },
			NysForgetCommand = { Type = "Command" },
		})
	end)
end

--- Build a fresh viewmodel (empty collections) and wire the window-level commands.
--- Kept alive by the DataContext assignment in populate, not by any Lua handle;
--- the command handlers re-fetch the live viewmodel and never close over this one.
---@return any|nil vm
local function buildViewModel()
	local vm = instantiate(SETTINGS_VM)
	if not vm then
		Util.Warn("NYS: could not instantiate the native settings viewmodel")
		return nil
	end
	suppressWrite = true
	local toggles = get(vm, "NysTypeToggles")
	for index, cat in ipairs(Classifier.CATEGORIES) do
		local toggle = instantiate(TOGGLE_VM)
		if toggle then
			set(toggle, "NysLabel", cat.label)
			set(toggle, "NysChecked", false)
			set(toggle, "NysEnabled", true)
			-- Controller accept-toggle (GH #6): re-fetch the live row by its fixed index (the
			-- item handle does not survive), and only toggle when the row is enabled.
			pcall(function()
				toggle.NysToggleCommand:SetHandler(function()
					local v = liveVm()
					local list = v and get(v, "NysTypeToggles")
					local item = list and list[index]
					if item and get(item, "NysEnabled") == true then
						set(item, "NysChecked", get(item, "NysChecked") ~= true)
					end
				end)
			end)
			appendItem(toggles, toggle)
		end
	end
	set(vm, "NysIsOpen", false)
	set(vm, "NysTypesExpanded", false)
	set(vm, "NysModeValue", "skip")
	set(vm, "NysModeOpen", false)
	for field, mode in pairs({
		NysSelectSkipCommand = "skip",
		NysSelectSharedCommand = "shared",
		NysSelectUniqueCommand = "unique",
	}) do
		pcall(function()
			vm[field]:SetHandler(function()
				local v = liveVm()
				if v then
					set(v, "NysModeValue", mode)
					set(v, "NysModeOpen", false)
				end
			end)
		end)
	end
	pcall(function()
		vm.NysRefreshCommand:SetHandler(function()
			populate()
		end)
	end)
	pcall(function()
		vm.NysCloseCommand:SetHandler(function()
			-- Closing the overlay commits the staged forgets/un-skips (GH #76).
			flushStaged()
			local v = liveVm()
			if v then
				set(v, "NysIsOpen", false)
			end
		end)
	end)
	pcall(function()
		vm.NysToggleTypesCommand:SetHandler(function()
			local v = liveVm()
			if v then
				set(v, "NysTypesExpanded", not get(v, "NysTypesExpanded"))
			end
		end)
	end)
	-- Controller accept-toggle for each boolean setting (GH #6): flip the live value and
	-- recompute the enabled/greyed dependents, exactly as the mouse WriteCallback does.
	for field, command in pairs({
		NysPromptOnSummon = "NysTogglePromptOnSummonCommand",
		NysPromptForNamed = "NysTogglePromptForNamedCommand",
		NysPauseOnPrompt = "NysTogglePauseOnPromptCommand",
		NysAllowStorySummons = "NysToggleAllowStoryCommand",
		NysNameEverySummon = "NysToggleNameEveryCommand",
	}) do
		pcall(function()
			vm[command]:SetHandler(function()
				local v = liveVm()
				if v then
					set(v, field, get(v, field) ~= true)
					recomputeEnabled(v)
				end
			end)
		end)
	end
	suppressWrite = false
	return vm
end

--- Rebuild the whole panel: fresh viewmodel (empty append-only collections),
--- bind it as the DataContext, then load everything under a new generation.
function populate()
	local vm = buildViewModel()
	if not vm then
		return
	end
	local panel = panelFinder and panelFinder("NYS_SettingsPanel")
	if panel then
		set(panel, "DataContext", vm)
	end
	set(vm, "NysIsOpen", true)
	generation = generation + 1
	local gen = generation
	rowMeta = {}
	originalNames = {}
	pendingForgets = {}
	loadSettings(gen)
	refreshNames(gen)
end

---------------------------------------------------------------------------
-- Public lifecycle (NativeRenameUI owns panel detection and node lookup)
---------------------------------------------------------------------------

--- Set the finder that resolves a live Noesis node by x:Name (NativeRenameUI).
---@param fn fun(name:string):any|nil
function NativeConfigUI.SetPanelFinder(fn)
	panelFinder = fn
end

--- Open the overlay (build + bind + load). Called from the gear's click handler.
function NativeConfigUI.Open()
	populate()
end

--- Commit any staged forgets / un-skips. Called when the whole Examine panel
--- closes (NativeRenameUI), so a forget takes effect even if the overlay was not
--- closed first; idempotent, so it is harmless when nothing is staged (GH #76).
function NativeConfigUI.Flush()
	flushStaged()
end

function NativeConfigUI.Register()
	if Ext.UI == nil then
		Util.Warn("NYS: Ext.UI unavailable; native settings panel disabled")
		return
	end
	registerTypes()
end

return NativeConfigUI
