-- SPDX-License-Identifier: MIT
--[[
    Native (NoesisGUI) settings panel, opened by the Examine gear (GH #20).

    The markup is an NYS_SettingsPanel overlay in the Examine.xaml override; its
    DataContext is an SE viewmodel (Ext.UI.RegisterType / Instantiate). Bool props
    drive the checkboxes, Collections feed the ItemsControls, Command props back
    the buttons. Every viewmodel field is prefixed `Nys` so it cannot collide with
    a built-in Noesis/WPF property (an unprefixed `Name` did - it aliased
    FrameworkElement.Name and the edit box round-tripped the literal "Name").

    Per-viewport (GH #86): local split-screen can have one settings overlay open PER
    viewport at once, so all state is keyed by PlayerId in `sessions[id]` and every
    node lookup is scoped to that viewport (panelFinder(id, name)). Each viewmodel
    carries its viewport id in `NysViewport`, so a WriteCallback (handed only the live
    context) can find its session. Command handlers are built per viewport and close
    over the id. The saved-name list is scoped to the viewing player (its viewer
    character is sent to the server, which returns only that player's names).

    Two hard-won engine constraints shape this module:

    1. A viewmodel/node reference obtained from Lua does NOT survive across ticks -
       so we never cache the viewmodel; we re-fetch it live from the panel (liveVm)
       at each point of use, and inside a WriteCallback we use the live context.
    2. An SE Collection is append-only from Lua, so the only way to a clean list is a
       fresh viewmodel; the panel is fully rebuilt on every open/refresh via
       `populate`, guarded by a per-session generation counter so a slow in-flight
       reply cannot append to a newer viewmodel.

    There is no SE API to create a standalone native window, so the panel lives
    inside a page we already override (Examine); NativeRenameUI owns panel
    detection and feeds this module the (viewport-scoped) node finder and gear hook.
]]

local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Classifier = Ext.Require("Shared/SummonClassifier.lua")

local NativeConfigUI = {}

-- Registered viewmodel type names; must be unique system-wide (hence the prefix).
local SETTINGS_VM = "NYS_SettingsVM"
local TOGGLE_VM = "NYS_TypeToggleVM"
local NAME_ROW_VM = "NYS_NameRowVM"

local panelFinder -- fun(id, name):node|nil - finds a live Noesis node by x:Name within viewport id
local viewerProvider -- fun(id):string|nil - the viewing player's controlled character (GH #86)

-- Per-viewport settings sessions, keyed by PlayerId (GH #86). Each holds the saved-name
-- row identity/baselines, staged forgets, and the async generation guards for that panel.
-- A name edit commits live on blur (onNameWrite); forgets are staged and flushed when the
-- overlay/panel closes (flushStaged), keeping an Undo affordance while open (GH #76).
local sessions = {} -- id -> { rowMeta, originalNames, pendingForgets, generation, settingsLoadedGen, lastPushedSettings }

-- Guards onSettingWrite against the bulk programmatic writes done while loading a
-- viewmodel (those must not be treated as user edits). Set/cleared synchronously around
-- each bulk write, so a single global is safe (Lua is single-threaded; the bulk sections
-- never yield).
local suppressWrite = false

local populate

---@param id integer
---@return table
local function sessionFor(id)
	local s = sessions[id]
	if not s then
		s = {
			rowMeta = {},
			originalNames = {},
			pendingForgets = {},
			generation = 0,
			settingsLoadedGen = 0,
			lastPushedSettings = nil,
		}
		sessions[id] = s
	end
	return s
end

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

--- The live settings viewmodel for viewport `id` (its panel's DataContext). Valid only
--- in the immediate scope - re-fetch every time; never cache across calls/ticks.
---@param id integer
---@return any|nil
local function liveVm(id)
	if not panelFinder then
		return nil
	end
	local panel = panelFinder(id, "NYS_SettingsPanel")
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

--- The viewport id a viewmodel context belongs to (set as NysViewport when built).
---@param context any
---@return integer|nil
local function viewportOf(context)
	return tonumber(get(context, "NysViewport"))
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
--- the per-type list, and nothing is filtered when prompting is off.
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

--- The settings payload as it currently stands on the live viewmodel. Settings are a
--- shared/global mod config (not per-player), so any viewport's edit writes them all.
---@param v any live settings viewmodel
---@return table
local function collectSettings(v)
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
	return settings
end

--- Flat-table equality for the settings payload (boolean/string values only).
local function sameSettings(a, b)
	if not a or not b then
		return false
	end
	for key, value in pairs(a) do
		if b[key] ~= value then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

--- Send the whole settings object to the server for viewport `id`. Settings are live
--- (GH #76), so this fires from every setting WriteCallback instead of a Save button.
---@param id integer
local function pushSettings(id)
	local session = sessions[id]
	if not session then
		return
	end
	local v = liveVm(id)
	if not v then
		return
	end
	-- Before the settings reply lands the viewmodel holds only its all-false defaults;
	-- pushing then would overwrite the real settings with them.
	if session.settingsLoadedGen ~= session.generation then
		return
	end
	local settings = collectSettings(v)
	if sameSettings(settings, session.lastPushedSettings) then
		return
	end
	session.lastPushedSettings = settings
	Channels.SetSettings:SendToServer(settings)
end

local function onSettingWrite(context)
	if suppressWrite then
		return
	end
	recomputeEnabled(context)
	pushSettings(viewportOf(context))
end

--- WriteCallback for props that only need a live push (the mode dropdown value and each
--- per-type toggle); recompute is handled by the booleans' onSettingWrite.
local function pushIfLive(context)
	if suppressWrite then
		return
	end
	pushSettings(viewportOf(context))
end

--- Commit an edited saved name when its field loses focus (the row binding uses
--- UpdateSourceTrigger=LostFocus). A row staged for forget is left alone.
local function onNameWrite(context)
	if suppressWrite then
		return
	end
	local session = sessions[viewportOf(context)]
	if not session then
		return
	end
	local id = get(context, "NysRowId")
	local meta = id and session.rowMeta[id]
	if not meta or session.pendingForgets[id] then
		return
	end
	local text = Util.Sanitise(get(context, "NysNameText") or "")
	if text == "" or text == session.originalNames[id] then
		return
	end
	session.originalNames[id] = text
	Channels.RenameName:SendToServer({ Key = meta.Key, Slot = meta.Slot, Name = text })
end

---------------------------------------------------------------------------
-- Staged row actions (toggle a forget / un-skip; flushed when the panel closes)
---------------------------------------------------------------------------

--- The live row in viewport `id`'s `collKey` whose NysRowId matches `rowId`, or nil.
local function findLiveRow(id, collKey, rowId)
	local v = liveVm(id)
	local coll = v and get(v, collKey)
	for index = 1, count(coll) do
		local row = coll[index]
		if get(row, "NysRowId") == rowId then
			return row
		end
	end
	return nil
end

local function toggleForget(id, rowId)
	local session = sessions[id]
	if not session or not session.rowMeta[rowId] then
		return
	end
	local row = findLiveRow(id, "NysSavedNames", rowId)
	if session.pendingForgets[rowId] then
		session.pendingForgets[rowId] = nil
		set(row, "NysForgetLabel", "Forget")
		set(row, "NysNameEnabled", true)
	else
		session.pendingForgets[rowId] = true
		set(row, "NysForgetLabel", "Undo")
		set(row, "NysNameEnabled", false)
	end
end

---------------------------------------------------------------------------
-- Load from the server into the just-built viewmodel (guarded by generation)
---------------------------------------------------------------------------

local function loadSettings(id, gen)
	Channels.GetSettings:RequestToServer({}, function(response)
		local session = sessions[id]
		if not session or gen ~= session.generation then
			return
		end
		local v = liveVm(id)
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
		session.settingsLoadedGen = gen
		-- The load's own writes fire pushSettings asynchronously; seed the dedupe baseline
		-- with the just-loaded values so those pushes are dropped (GH #76).
		session.lastPushedSettings = collectSettings(v)
	end)
end

local function refreshNames(id, gen)
	-- Scope the list to the viewing split-screen player (GH #86): send the character this
	-- viewport controls; the server returns only summons whose owner that player controls.
	local viewer = viewerProvider and viewerProvider(id) or nil
	Channels.ListNames:RequestToServer({ ViewerCharacter = viewer }, function(response)
		local session = sessions[id]
		if not session or gen ~= session.generation then
			return
		end
		local v = liveVm(id)
		if not v then
			return
		end
		local coll = get(v, "NysSavedNames")
		local entries = (response and response.Entries) or {}
		set(v, "NysHasSavedNames", #entries > 0)
		-- Server-populated NysNameText must not fire onNameWrite (user edits only).
		suppressWrite = true
		for _, entry in ipairs(entries) do
			local rowId = stageId(entry)
			session.rowMeta[rowId] = { Key = entry.Key, Slot = entry.Slot }
			session.originalNames[rowId] = entry.Name

			local row = instantiate(NAME_ROW_VM)
			if row then
				set(row, "NysViewport", tostring(id))
				set(row, "NysRowId", rowId)
				set(row, "NysOwnerLabel", ownerLabel(entry))
				set(row, "NysRowLabel", rowLabel(entry))
				set(row, "NysNameText", entry.Name)
				set(row, "NysForgetLabel", "Forget")
				set(row, "NysNameEnabled", true)
				pcall(function()
					row.NysForgetCommand:SetHandler(function()
						toggleForget(id, rowId)
					end)
				end)
				appendItem(coll, row)
			end
		end
		suppressWrite = false
	end)
end

---------------------------------------------------------------------------
-- Flush staged forgets when the overlay/panel closes (GH #76)
---------------------------------------------------------------------------

--- Commit viewport `id`'s staged forgets, then clear the stage. Idempotent; reads only
--- the cached tables, so it is safe once the live node is gone.
---@param id integer
local function flushStaged(id)
	local session = sessions[id]
	if not session then
		return
	end
	-- ForgetSlot compacts the unique set, so several slots under one key must be sent
	-- highest-first; otherwise each removal shifts the ones still to come.
	local forgetSlotsByKey = {}
	for rowId in pairs(session.pendingForgets) do
		local meta = session.rowMeta[rowId]
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
	session.pendingForgets = {}
end

---------------------------------------------------------------------------
-- Viewmodel type registration
---------------------------------------------------------------------------

local function registerTypes()
	pcall(function()
		Ext.UI.RegisterType(SETTINGS_VM, {
			NysViewport = { Type = "String" },
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
			NysViewport = { Type = "String" },
			NysLabel = { Type = "String" },
			NysChecked = { Type = "Bool", Notify = true, WriteCallback = pushIfLive },
			NysEnabled = { Type = "Bool", Notify = true },
			NysToggleCommand = { Type = "Command" },
		})
		Ext.UI.RegisterType(NAME_ROW_VM, {
			NysViewport = { Type = "String" },
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

--- Build a fresh viewmodel (empty collections) for viewport `id` and wire its commands.
--- Command handlers close over `id` (a stable number) and re-fetch the live viewmodel via
--- liveVm(id); they never close over the viewmodel handle (it does not survive).
---@param id integer
---@return any|nil vm
local function buildViewModel(id)
	local vm = instantiate(SETTINGS_VM)
	if not vm then
		Util.Warn("NYS: could not instantiate the native settings viewmodel")
		return nil
	end
	suppressWrite = true
	set(vm, "NysViewport", tostring(id))
	local toggles = get(vm, "NysTypeToggles")
	for index, cat in ipairs(Classifier.CATEGORIES) do
		local toggle = instantiate(TOGGLE_VM)
		if toggle then
			set(toggle, "NysViewport", tostring(id))
			set(toggle, "NysLabel", cat.label)
			set(toggle, "NysChecked", false)
			set(toggle, "NysEnabled", true)
			-- Controller accept-toggle (GH #6): re-fetch the live row by its fixed index (the
			-- item handle does not survive), and only toggle when the row is enabled.
			pcall(function()
				toggle.NysToggleCommand:SetHandler(function()
					local v = liveVm(id)
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
				local v = liveVm(id)
				if v then
					set(v, "NysModeValue", mode)
					set(v, "NysModeOpen", false)
				end
			end)
		end)
	end
	pcall(function()
		vm.NysRefreshCommand:SetHandler(function()
			populate(id)
		end)
	end)
	pcall(function()
		vm.NysCloseCommand:SetHandler(function()
			-- Closing the overlay commits the staged forgets/un-skips (GH #76).
			flushStaged(id)
			local v = liveVm(id)
			if v then
				set(v, "NysIsOpen", false)
			end
		end)
	end)
	pcall(function()
		vm.NysToggleTypesCommand:SetHandler(function()
			local v = liveVm(id)
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
				local v = liveVm(id)
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

--- Rebuild viewport `id`'s whole panel: fresh viewmodel (empty append-only collections),
--- bind it as the DataContext, then load everything under a new generation.
---@param id integer
function populate(id)
	local vm = buildViewModel(id)
	if not vm then
		return
	end
	local panel = panelFinder and panelFinder(id, "NYS_SettingsPanel")
	if panel then
		set(panel, "DataContext", vm)
	end
	set(vm, "NysIsOpen", true)
	local session = sessionFor(id)
	session.generation = session.generation + 1
	local gen = session.generation
	session.rowMeta = {}
	session.originalNames = {}
	session.pendingForgets = {}
	loadSettings(id, gen)
	refreshNames(id, gen)
end

---------------------------------------------------------------------------
-- Public lifecycle (NativeRenameUI owns panel detection and node lookup)
---------------------------------------------------------------------------

--- Set the finder that resolves a live Noesis node by x:Name within a viewport's Examine
--- subtree (NativeRenameUI.FindNamedIn).
---@param fn fun(id:integer, name:string):any|nil
function NativeConfigUI.SetPanelFinder(fn)
	panelFinder = fn
end

--- Set the provider for a viewport's viewing character, used to scope its saved-name list
--- per split-screen player (NativeRenameUI.ViewerOf, GH #86).
---@param fn fun(id:integer):string|nil
function NativeConfigUI.SetViewerProvider(fn)
	viewerProvider = fn
end

--- Open the overlay for viewport `id` (build + bind + load). Called from the gear handler.
---@param id integer
function NativeConfigUI.Open(id)
	populate(id)
end

--- Commit a viewport's staged forgets and drop its session. Called when its whole Examine
--- panel closes (NativeRenameUI), so a forget takes effect even if the overlay was not
--- closed first; idempotent (GH #76).
---@param id integer
function NativeConfigUI.Flush(id)
	flushStaged(id)
	sessions[id] = nil
end

function NativeConfigUI.Register()
	if Ext.UI == nil then
		Util.Warn("NYS: Ext.UI unavailable; native settings panel disabled")
		return
	end
	registerTypes()
end

return NativeConfigUI
