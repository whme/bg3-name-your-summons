--[[
    Native (NoesisGUI) settings panel, opened by the Examine gear (GH #20).

    Unlike the ImGui ConfigUI, the markup is real Noesis: an NYS_SettingsPanel
    overlay in the Examine.xaml override whose DataContext is a viewmodel built
    here via the SE viewmodel API (Ext.UI.RegisterType / Instantiate). Bool props
    drive the checkboxes (two-way via Notify + WriteCallback), Collections feed
    the ItemsControls, and Command props back the buttons.

    There is no SE API to create a standalone native window or push a UI state on
    demand, so the panel lives inside a page we already override (Examine); the
    lifecycle glue (find the panel, set its DataContext, detect the gear click)
    lives in NativeRenameUI, which feeds this module via OnPanelOpen / Open.

    The staged-edit + Save model mirrors ConfigUI so the exact same net channels
    and payloads are reused; nothing is sent to the server until Save.
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

local vm -- the single settings viewmodel instance
local typeToggleVms = {} -- array of { key = "NameBeast", vm = <toggle vm> }
local rowMeta = {} -- saved-name rowId -> { Key = .., Slot = .. }
local originalNames = {} -- saved-name rowId -> baseline name text (dirty diff)

-- Server baseline for dirty tracking; edits stay local until Save.
local baseSettings = {}
local pendingRenames = {}
local pendingForgets = {}
local pendingUnskips = {}
local pendingSessionUnskips = {}

-- Guards WriteCallbacks against the programmatic prop writes we do while loading
-- or enforcing radio exclusivity (those writes must not be treated as edits).
local suppressWrite = false

local refreshAll, updateSaveEnabled

---------------------------------------------------------------------------
-- Small guarded property/collection accessors (a dead node or missing prop
-- must never tear down the client Lua state).
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

local function appendItem(coll, item)
	pcall(function()
		coll[#coll + 1] = item
	end)
end

local function clearCollection(coll)
	pcall(function()
		while #coll > 0 do
			table.remove(coll)
		end
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
-- Settings state (dirty tracking + dependent enable/disable)
---------------------------------------------------------------------------

--- The selected multi-summon mode value from the three radio-style toggles.
local function selectedMode()
	if get(vm, "ModeShared") then
		return "shared"
	elseif get(vm, "ModeUnique") then
		return "unique"
	end
	return "skip"
end

--- Whether any settings control differs from the saved baseline.
local function settingsDirty()
	if get(vm, "PromptOnSummon") ~= baseSettings.PromptOnSummon then
		return true
	end
	if get(vm, "PromptForNamed") ~= baseSettings.PromptForNamed then
		return true
	end
	if get(vm, "AllowStorySummons") ~= baseSettings.AllowStorySummons then
		return true
	end
	if selectedMode() ~= baseSettings.MultiSummonMode then
		return true
	end
	if get(vm, "NameEverySummon") ~= baseSettings[Classifier.MASTER_KEY] then
		return true
	end
	for _, toggle in ipairs(typeToggleVms) do
		if get(toggle.vm, "Checked") ~= baseSettings[toggle.key] then
			return true
		end
	end
	return false
end

function updateSaveEnabled()
	local dirty = settingsDirty()
		or next(pendingRenames) ~= nil
		or next(pendingForgets) ~= nil
		or next(pendingUnskips) ~= nil
		or next(pendingSessionUnskips) ~= nil
	set(vm, "SaveEnabled", dirty)
end

--- Grey the toggles that cannot take effect: the "every summon" master overrides
--- the per-type list, and nothing is filtered when prompting is off.
local function recomputeEnabled()
	local promptOn = get(vm, "PromptOnSummon") == true
	set(vm, "PromptForNamedEnabled", promptOn)
	set(vm, "NameEverySummonEnabled", promptOn)
	local typesLocked = (not promptOn) or (get(vm, "NameEverySummon") == true)
	for _, toggle in ipairs(typeToggleVms) do
		set(toggle.vm, "Enabled", not typesLocked)
	end
end

---------------------------------------------------------------------------
-- WriteCallbacks (fired by both script and Noesis writes; guarded)
---------------------------------------------------------------------------

local function onSettingWrite()
	if suppressWrite then
		return
	end
	recomputeEnabled()
	updateSaveEnabled()
end

--- Enforce radio-button exclusivity across the three multi-summon-mode toggles:
--- selecting one clears the others, and the active one cannot be turned off.
local function selectMode(active)
	if suppressWrite then
		return
	end
	suppressWrite = true
	set(vm, "ModeSkip", active == "skip")
	set(vm, "ModeShared", active == "shared")
	set(vm, "ModeUnique", active == "unique")
	suppressWrite = false
	updateSaveEnabled()
end

local function onTypeToggleWrite()
	if suppressWrite then
		return
	end
	updateSaveEnabled()
end

local function onNameRowWrite(context)
	if suppressWrite then
		return
	end
	local id = get(context, "RowId")
	local meta = id and rowMeta[id]
	if not meta then
		return
	end
	local name = Util.Sanitise(get(context, "Name") or "")
	if name ~= "" and name ~= originalNames[id] then
		pendingRenames[id] = { Key = meta.Key, Slot = meta.Slot, Name = name }
	else
		pendingRenames[id] = nil
	end
	updateSaveEnabled()
end

---------------------------------------------------------------------------
-- Row commands (per-instance handlers via command:SetHandler)
---------------------------------------------------------------------------

local function toggleForget(id, row)
	local meta = rowMeta[id]
	if not meta then
		return
	end
	if pendingForgets[id] then
		pendingForgets[id] = nil
		set(row, "ForgetLabel", "Forget")
		set(row, "NameEnabled", true)
	else
		pendingForgets[id] = { Key = meta.Key, Slot = meta.Slot }
		pendingRenames[id] = nil
		set(row, "ForgetLabel", "Undo")
		set(row, "NameEnabled", false)
	end
	updateSaveEnabled()
end

local function toggleUnskip(key, row, pendingSet)
	if pendingSet[key] then
		pendingSet[key] = nil
		set(row, "UndoLabel", "Prompt again")
	else
		pendingSet[key] = true
		set(row, "UndoLabel", "Undo")
	end
	updateSaveEnabled()
end

---------------------------------------------------------------------------
-- Load / refresh from the server
---------------------------------------------------------------------------

local function loadSettings()
	Channels.GetSettings:RequestToServer({}, function(response)
		local s = response or {}
		local onSummon = s.PromptOnSummon ~= false
		local forNamed = s.PromptForNamed == true
		local allowStory = s.AllowStorySummons == true
		local modeVal = MultiMode.ValueAt(MultiMode.IndexOf(s.MultiSummonMode))
		local every = s[Classifier.MASTER_KEY] == true

		suppressWrite = true
		set(vm, "PromptOnSummon", onSummon)
		set(vm, "PromptForNamed", forNamed)
		set(vm, "AllowStorySummons", allowStory)
		set(vm, "NameEverySummon", every)
		set(vm, "ModeSkip", modeVal == "skip")
		set(vm, "ModeShared", modeVal == "shared")
		set(vm, "ModeUnique", modeVal == "unique")

		baseSettings = {
			PromptOnSummon = onSummon,
			PromptForNamed = forNamed,
			AllowStorySummons = allowStory,
			MultiSummonMode = modeVal,
			[Classifier.MASTER_KEY] = every,
		}
		for _, toggle in ipairs(typeToggleVms) do
			local on = s[toggle.key] == true
			baseSettings[toggle.key] = on
			set(toggle.vm, "Checked", on)
		end
		suppressWrite = false

		recomputeEnabled()
		updateSaveEnabled()
	end)
end

local function refreshNames()
	clearCollection(get(vm, "SavedNames"))
	rowMeta = {}
	originalNames = {}
	pendingRenames = {}
	pendingForgets = {}
	updateSaveEnabled()

	Channels.ListNames:RequestToServer({}, function(response)
		local entries = (response and response.Entries) or {}
		set(vm, "HasSavedNames", #entries > 0)
		local coll = get(vm, "SavedNames")
		for _, entry in ipairs(entries) do
			local id = stageId(entry)
			rowMeta[id] = { Key = entry.Key, Slot = entry.Slot }
			originalNames[id] = entry.Name

			local row = instantiate(NAME_ROW_VM)
			if row then
				suppressWrite = true
				set(row, "RowId", id)
				set(row, "OwnerLabel", ownerLabel(entry))
				set(row, "RowLabel", rowLabel(entry))
				set(row, "Name", entry.Name)
				set(row, "NameEnabled", true)
				set(row, "ForgetLabel", "Forget")
				suppressWrite = false
				pcall(function()
					row.ForgetCommand:SetHandler(function()
						toggleForget(id, row)
					end)
				end)
				appendItem(coll, row)
			end
		end
	end)
end

--- Rebuild a skip list; each row's command stages an undo into `pendingSet`.
--- Shared by the always-skipped and session-skipped lists.
local function refreshSkipList(channel, collKey, hasKey, pendingSet)
	clearCollection(get(vm, collKey))
	updateSaveEnabled()

	channel:RequestToServer({}, function(response)
		local entries = (response and response.Entries) or {}
		set(vm, hasKey, #entries > 0)
		local coll = get(vm, collKey)
		for _, entry in ipairs(entries) do
			local row = instantiate(SKIP_ROW_VM)
			if row then
				set(row, "OwnerLabel", ownerLabel(entry))
				set(row, "TemplateLabel", entry.TemplateName or "Summon")
				set(row, "UndoLabel", "Prompt again")
				local key = entry.Key
				pcall(function()
					row.UndoCommand:SetHandler(function()
						toggleUnskip(key, row, pendingSet)
					end)
				end)
				appendItem(coll, row)
			end
		end
	end)
end

local function refreshSkipped()
	pendingUnskips = {}
	refreshSkipList(Channels.ListSkipped, "AlwaysSkipped", "HasAlwaysSkipped", pendingUnskips)
end

local function refreshSessionSkipped()
	pendingSessionUnskips = {}
	refreshSkipList(Channels.ListSessionSkipped, "SessionSkipped", "HasSessionSkipped", pendingSessionUnskips)
end

function refreshAll()
	loadSettings()
	refreshNames()
	refreshSkipped()
	refreshSessionSkipped()
end

---------------------------------------------------------------------------
-- Save
---------------------------------------------------------------------------

local function onSave()
	local settings = {
		PromptOnSummon = get(vm, "PromptOnSummon"),
		PromptForNamed = get(vm, "PromptForNamed"),
		AllowStorySummons = get(vm, "AllowStorySummons"),
		MultiSummonMode = selectedMode(),
		[Classifier.MASTER_KEY] = get(vm, "NameEverySummon"),
	}
	for _, toggle in ipairs(typeToggleVms) do
		settings[toggle.key] = get(toggle.vm, "Checked")
	end
	Channels.SetSettings:SendToServer(settings)
	baseSettings = settings

	for _, payload in pairs(pendingForgets) do
		Channels.ForgetName:SendToServer(payload)
	end
	pendingForgets = {}

	for _, payload in pairs(pendingRenames) do
		Channels.RenameName:SendToServer(payload)
	end
	pendingRenames = {}

	for key in pairs(pendingUnskips) do
		Channels.Unskip:SendToServer({ Key = key })
	end
	pendingUnskips = {}

	for key in pairs(pendingSessionUnskips) do
		Channels.UnskipSession:SendToServer({ Key = key })
	end
	pendingSessionUnskips = {}

	updateSaveEnabled()
	-- Pull the canonical state back (server-side sanitising, owner names).
	Ext.Timer.WaitForRealtime(120, function()
		refreshNames()
		refreshSkipped()
		refreshSessionSkipped()
	end)
end

---------------------------------------------------------------------------
-- Viewmodel registration
---------------------------------------------------------------------------

local function registerTypes()
	pcall(function()
		Ext.UI.RegisterType(SETTINGS_VM, {
			IsOpen = { Type = "Bool", Notify = true },
			PromptOnSummon = { Type = "Bool", Notify = true, WriteCallback = onSettingWrite },
			PromptForNamed = { Type = "Bool", Notify = true, WriteCallback = onSettingWrite },
			AllowStorySummons = { Type = "Bool", Notify = true, WriteCallback = onSettingWrite },
			PromptForNamedEnabled = { Type = "Bool", Notify = true },
			NameEverySummon = { Type = "Bool", Notify = true, WriteCallback = onSettingWrite },
			NameEverySummonEnabled = { Type = "Bool", Notify = true },
			ModeSkip = {
				Type = "Bool",
				Notify = true,
				WriteCallback = function()
					selectMode("skip")
				end,
			},
			ModeShared = {
				Type = "Bool",
				Notify = true,
				WriteCallback = function()
					selectMode("shared")
				end,
			},
			ModeUnique = {
				Type = "Bool",
				Notify = true,
				WriteCallback = function()
					selectMode("unique")
				end,
			},
			TypeToggles = { Type = "Collection" },
			SavedNames = { Type = "Collection" },
			AlwaysSkipped = { Type = "Collection" },
			SessionSkipped = { Type = "Collection" },
			HasSavedNames = { Type = "Bool", Notify = true },
			HasAlwaysSkipped = { Type = "Bool", Notify = true },
			HasSessionSkipped = { Type = "Bool", Notify = true },
			SaveEnabled = { Type = "Bool", Notify = true },
			SaveCommand = { Type = "Command" },
			RefreshCommand = { Type = "Command" },
			CloseCommand = { Type = "Command" },
		})
		Ext.UI.RegisterType(TOGGLE_VM, {
			Label = { Type = "String" },
			Checked = { Type = "Bool", Notify = true, WriteCallback = onTypeToggleWrite },
			Enabled = { Type = "Bool", Notify = true },
		})
		Ext.UI.RegisterType(NAME_ROW_VM, {
			RowId = { Type = "String" },
			OwnerLabel = { Type = "String" },
			RowLabel = { Type = "String" },
			Name = { Type = "String", Notify = true, WriteCallback = onNameRowWrite },
			NameEnabled = { Type = "Bool", Notify = true },
			ForgetLabel = { Type = "String", Notify = true },
			ForgetCommand = { Type = "Command" },
		})
		Ext.UI.RegisterType(SKIP_ROW_VM, {
			OwnerLabel = { Type = "String" },
			TemplateLabel = { Type = "String" },
			UndoLabel = { Type = "String", Notify = true },
			UndoCommand = { Type = "Command" },
		})
	end)
end

--- Build the persistent settings viewmodel (the type toggles are static and
--- built once; only their Checked state changes on load).
local function buildViewModel()
	vm = instantiate(SETTINGS_VM)
	if not vm then
		Util.Warn("NYS: could not instantiate the native settings viewmodel")
		return
	end
	suppressWrite = true
	typeToggleVms = {}
	local toggles = get(vm, "TypeToggles")
	for _, cat in ipairs(Classifier.CATEGORIES) do
		local toggle = instantiate(TOGGLE_VM)
		if toggle then
			local key = Classifier.SettingKey(cat.key)
			set(toggle, "Label", cat.label)
			set(toggle, "Checked", false)
			set(toggle, "Enabled", true)
			appendItem(toggles, toggle)
			typeToggleVms[#typeToggleVms + 1] = { key = key, vm = toggle }
		end
	end
	set(vm, "IsOpen", false)
	pcall(function()
		vm.SaveCommand:SetHandler(onSave)
	end)
	pcall(function()
		vm.RefreshCommand:SetHandler(refreshAll)
	end)
	pcall(function()
		vm.CloseCommand:SetHandler(function()
			set(vm, "IsOpen", false)
		end)
	end)
	suppressWrite = false
end

---------------------------------------------------------------------------
-- Public lifecycle (driven by NativeRenameUI, which owns panel detection)
---------------------------------------------------------------------------

--- Bind the viewmodel to a freshly-opened Examine panel's settings overlay.
--- The panel is recreated on each open, so its DataContext is set every time.
---@param panelNode any  the NYS_SettingsPanel Noesis element
function NativeConfigUI.OnPanelOpen(panelNode)
	if not (vm and panelNode) then
		return
	end
	pcall(function()
		panelNode.DataContext = vm
	end)
end

--- Reset the open flag when the Examine panel closes so the overlay starts
--- collapsed the next time the panel is shown.
function NativeConfigUI.OnPanelClose()
	set(vm, "IsOpen", false)
end

--- Show the overlay and (re)load everything from the server. Called from the
--- gear's click handler.
function NativeConfigUI.Open()
	if not vm then
		return
	end
	set(vm, "IsOpen", true)
	refreshAll()
end

function NativeConfigUI.Register()
	if Ext.UI == nil then
		Util.Warn("NYS: Ext.UI unavailable; native settings panel disabled")
		return
	end
	registerTypes()
	buildViewModel()
end

return NativeConfigUI
