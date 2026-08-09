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
       whole-array assignment all fail. The only way to get a clean list is a fresh
       viewmodel (its collections start empty). So the panel is fully rebuilt on
       every open/refresh/save/forget via `populate`, guarded by a generation
       counter so a slow in-flight reply cannot append to a newer viewmodel.

    There is no SE API to create a standalone native window, so the panel lives
    inside a page we already override (Examine); NativeRenameUI owns panel
    detection and feeds this module the node finder and the gear hook.
]]

local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Classifier = Ext.Require("Shared/SummonClassifier.lua")
local MultiMode = Ext.Require("Shared/MultiSummonMode.lua")

local NativeConfigUI = {}

-- Registered viewmodel type names; must be unique system-wide (hence the prefix).
local SETTINGS_VM = "NYS_SettingsVM"
local TOGGLE_VM = "NYS_TypeToggleVM"
local NAME_ROW_VM = "NYS_NameRowVM"
local SKIP_ROW_VM = "NYS_SkipRowVM"

local panelFinder -- fun(name):node|nil - finds a live Noesis node by x:Name

-- Saved-name row identity/baseline, keyed by rowId (plain strings, safe to cache
-- unlike viewmodel handles). Edited names are read from the live rows at Save;
-- forgets and un-skips are staged here and flushed on Save (so they can be undone).
local rowMeta = {} -- rowId -> { Key = .., Slot = .. }
local originalNames = {} -- rowId -> baseline name text
local pendingForgets = {} -- saved-name rowId -> true
local pendingUnskips = {} -- always-skipped key -> true
local pendingSessionUnskips = {} -- session-skipped key -> true

-- Bumped on every (re)populate; async replies from an older generation are stale
-- and must not touch the current viewmodel (see the module header, constraint 2).
local generation = 0

-- The generation whose settings reply has landed. Save reads settings off the
-- viewmodel, so it must wait for this to catch up to `generation` or it would
-- flush the fresh viewmodel's default (all-false) settings over the real ones.
local settingsLoadedGen = 0

-- Guards WriteCallbacks against the programmatic writes we do while loading or
-- enforcing radio exclusivity (those must not recurse or be treated as edits).
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
-- Row/label helpers (same shaping as ConfigUI so the server payloads match)
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
		return name .. " #" .. tostring(entry.Slot)
	end
	return name
end

---------------------------------------------------------------------------
-- Dependent enable/disable and multi-summon mode
---------------------------------------------------------------------------

--- The selected multi-summon mode value from the three radio-style toggles.
local function selectedMode(v)
	if get(v, "NysModeShared") then
		return "shared"
	elseif get(v, "NysModeUnique") then
		return "unique"
	end
	return "skip"
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

local function onSettingWrite(context)
	if suppressWrite then
		return
	end
	recomputeEnabled(context)
end

--- Enforce radio exclusivity across the three mode toggles: selecting one clears
--- the others, and the active one cannot be turned off.
local function selectMode(context, active)
	if suppressWrite then
		return
	end
	suppressWrite = true
	set(context, "NysModeSkip", active == "skip")
	set(context, "NysModeShared", active == "shared")
	set(context, "NysModeUnique", active == "unique")
	suppressWrite = false
end

---------------------------------------------------------------------------
-- Staged row actions (toggle a forget / un-skip; flushed on Save)
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

local function toggleUnskip(collKey, key, pendingSet)
	local row = findLiveRow(collKey, key)
	if pendingSet[key] then
		pendingSet[key] = nil
		set(row, "NysUndoLabel", "Prompt again")
	else
		pendingSet[key] = true
		set(row, "NysUndoLabel", "Undo")
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
		local modeVal = MultiMode.ValueAt(MultiMode.IndexOf(s.MultiSummonMode))

		suppressWrite = true
		set(v, "NysPromptOnSummon", s.PromptOnSummon ~= false)
		set(v, "NysPromptForNamed", s.PromptForNamed == true)
		set(v, "NysAllowStorySummons", s.AllowStorySummons == true)
		set(v, "NysNameEverySummon", s[Classifier.MASTER_KEY] == true)
		set(v, "NysModeSkip", modeVal == "skip")
		set(v, "NysModeShared", modeVal == "shared")
		set(v, "NysModeUnique", modeVal == "unique")
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
	end)
end

--- Fill one skip list. `pendingSet` is the stage table for its "prompt again"
--- toggles (always-skipped and this-session share a layout and row viewmodel).
local function refreshSkipList(channel, collKey, hasKey, pendingSet, gen)
	channel:RequestToServer({}, function(response)
		if gen ~= generation then
			return
		end
		local v = liveVm()
		if not v then
			return
		end
		local coll = get(v, collKey)
		local entries = (response and response.Entries) or {}
		set(v, hasKey, #entries > 0)
		for _, entry in ipairs(entries) do
			local row = instantiate(SKIP_ROW_VM)
			if row then
				local key = entry.Key
				set(row, "NysRowId", key)
				set(row, "NysOwnerLabel", ownerLabel(entry))
				set(row, "NysTemplateLabel", entry.TemplateName or "Summon")
				set(row, "NysUndoLabel", "Prompt again")
				pcall(function()
					row.NysUndoCommand:SetHandler(function()
						toggleUnskip(collKey, key, pendingSet)
					end)
				end)
				appendItem(coll, row)
			end
		end
	end)
end

---------------------------------------------------------------------------
-- Save (read settings and edited names off the live viewmodel, send, rebuild)
---------------------------------------------------------------------------

local function onSave()
	local v = liveVm()
	if not v then
		return
	end
	-- Before the settings reply lands the viewmodel holds only its all-false
	-- defaults; saving then would overwrite the real settings with them.
	if settingsLoadedGen ~= generation then
		return
	end
	local settings = {
		PromptOnSummon = get(v, "NysPromptOnSummon") == true,
		PromptForNamed = get(v, "NysPromptForNamed") == true,
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

	-- Read edited names straight from the live rows (no per-keystroke staging);
	-- a row staged for forget is dropped, not renamed.
	local names = get(v, "NysSavedNames")
	for index = 1, count(names) do
		local row = names[index]
		local id = get(row, "NysRowId")
		local meta = id and rowMeta[id]
		if meta and not pendingForgets[id] then
			local text = Util.Sanitise(get(row, "NysNameText") or "")
			if text ~= "" and text ~= originalNames[id] then
				Channels.RenameName:SendToServer({ Key = meta.Key, Slot = meta.Slot, Name = text })
			end
		end
	end

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
	for key in pairs(pendingUnskips) do
		Channels.Unskip:SendToServer({ Key = key })
	end
	for key in pairs(pendingSessionUnskips) do
		Channels.UnskipSession:SendToServer({ Key = key })
	end

	-- Rebuild from the canonical server state (server-side sanitising, owner names).
	Ext.Timer.WaitForRealtime(120, populate)
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
			NysPromptForNamed = { Type = "Bool", Notify = true },
			NysAllowStorySummons = { Type = "Bool", Notify = true },
			NysPromptForNamedEnabled = { Type = "Bool", Notify = true },
			NysNameEverySummon = { Type = "Bool", Notify = true, WriteCallback = onSettingWrite },
			NysNameEverySummonEnabled = { Type = "Bool", Notify = true },
			NysModeSkip = {
				Type = "Bool",
				Notify = true,
				WriteCallback = function(context)
					selectMode(context, "skip")
				end,
			},
			NysModeShared = {
				Type = "Bool",
				Notify = true,
				WriteCallback = function(context)
					selectMode(context, "shared")
				end,
			},
			NysModeUnique = {
				Type = "Bool",
				Notify = true,
				WriteCallback = function(context)
					selectMode(context, "unique")
				end,
			},
			NysTypeToggles = { Type = "Collection" },
			NysSavedNames = { Type = "Collection" },
			NysAlwaysSkipped = { Type = "Collection" },
			NysSessionSkipped = { Type = "Collection" },
			NysHasSavedNames = { Type = "Bool", Notify = true },
			NysHasAlwaysSkipped = { Type = "Bool", Notify = true },
			NysHasSessionSkipped = { Type = "Bool", Notify = true },
			NysSaveCommand = { Type = "Command" },
			NysRefreshCommand = { Type = "Command" },
			NysCloseCommand = { Type = "Command" },
			NysToggleTypesCommand = { Type = "Command" },
		})
		Ext.UI.RegisterType(TOGGLE_VM, {
			NysLabel = { Type = "String" },
			NysChecked = { Type = "Bool", Notify = true },
			NysEnabled = { Type = "Bool", Notify = true },
		})
		Ext.UI.RegisterType(NAME_ROW_VM, {
			NysRowId = { Type = "String" },
			NysOwnerLabel = { Type = "String" },
			NysRowLabel = { Type = "String" },
			NysNameText = { Type = "String", Notify = true },
			NysNameEnabled = { Type = "Bool", Notify = true },
			NysForgetLabel = { Type = "String", Notify = true },
			NysForgetCommand = { Type = "Command" },
		})
		Ext.UI.RegisterType(SKIP_ROW_VM, {
			NysRowId = { Type = "String" },
			NysOwnerLabel = { Type = "String" },
			NysTemplateLabel = { Type = "String" },
			NysUndoLabel = { Type = "String", Notify = true },
			NysUndoCommand = { Type = "Command" },
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
	for _, cat in ipairs(Classifier.CATEGORIES) do
		local toggle = instantiate(TOGGLE_VM)
		if toggle then
			set(toggle, "NysLabel", cat.label)
			set(toggle, "NysChecked", false)
			set(toggle, "NysEnabled", true)
			appendItem(toggles, toggle)
		end
	end
	set(vm, "NysIsOpen", false)
	set(vm, "NysTypesExpanded", false)
	pcall(function()
		vm.NysSaveCommand:SetHandler(onSave)
	end)
	pcall(function()
		vm.NysRefreshCommand:SetHandler(function()
			populate()
		end)
	end)
	pcall(function()
		vm.NysCloseCommand:SetHandler(function()
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
	pendingUnskips = {}
	pendingSessionUnskips = {}
	loadSettings(gen)
	refreshNames(gen)
	refreshSkipList(Channels.ListSkipped, "NysAlwaysSkipped", "NysHasAlwaysSkipped", pendingUnskips, gen)
	refreshSkipList(
		Channels.ListSessionSkipped,
		"NysSessionSkipped",
		"NysHasSessionSkipped",
		pendingSessionUnskips,
		gen
	)
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

function NativeConfigUI.Register()
	if Ext.UI == nil then
		Util.Warn("NYS: Ext.UI unavailable; native settings panel disabled")
		return
	end
	registerTypes()
end

return NativeConfigUI
