local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Layout = Ext.Require("Client/Layout.lua")
local WindowState = Ext.Require("Client/WindowState.lua")
local Classifier = Ext.Require("Shared/SummonClassifier.lua")
local MultiMode = Ext.Require("Shared/MultiSummonMode.lua")

local ConfigUI = {}

-- Key under which this window's geometry is persisted (see WindowState.lua).
local WINDOW_KEY = "config"

local configWindow, namesGroup, skippedGroup, sessionGroup, saveButton
local promptOnSummon, promptForNamed, pauseOnPrompt, allowStorySummons, everySummonCheck, multiSummonMode
-- settings key ("NameUndead", ...) -> its checkbox widget.
local typeChecks = {}

--- The currently selected mode value, or "skip" before the combo exists.
---@return string
local function selectedMultiMode()
	if not multiSummonMode then
		return "skip"
	end
	return MultiMode.ValueAt(multiSummonMode.SelectedIndex)
end

-- Edits stay local until Save; reopening reloads from the server, which is
-- what discards unsaved edits. baseSettings is the checkbox baseline;
-- originalNames the per-row name baseline that keystrokes diff against.
local baseSettings = {
	PromptOnSummon = true,
	PromptForNamed = false,
	PauseOnPrompt = false,
	AllowStorySummons = false,
	MultiSummonMode = "skip",
}
local originalNames = {}
local pendingRenames = {}
local pendingForgets = {}
local pendingUnskips = {}
local pendingSessionUnskips = {}

-- Geometry is staged like every other edit: a live resize/move sets this dirty
-- (which enables Save) but nothing hits disk until Save. Closing discards it.
local geometryDirty = false
local geometryBaseline -- { pos = {x,y}, size = {w,h} } snapshotted when the window opens
local geometryPolling = false

local refreshNames, refreshSkipped, refreshSessionSkipped, saveGeometry, startGeometryPoll

---------------------------------------------------------------------------
-- Staged-change tracking
---------------------------------------------------------------------------

--- Whether any settings checkbox differs from the saved baseline.
local function settingsDirty()
	if promptOnSummon.Checked ~= baseSettings.PromptOnSummon then
		return true
	end
	if promptForNamed.Checked ~= baseSettings.PromptForNamed then
		return true
	end
	if pauseOnPrompt.Checked ~= baseSettings.PauseOnPrompt then
		return true
	end
	if selectedMultiMode() ~= baseSettings.MultiSummonMode then
		return true
	end
	if allowStorySummons.Checked ~= baseSettings.AllowStorySummons then
		return true
	end
	if everySummonCheck.Checked ~= baseSettings[Classifier.MASTER_KEY] then
		return true
	end
	for key, cb in pairs(typeChecks) do
		if cb.Checked ~= baseSettings[key] then
			return true
		end
	end
	return false
end

--- Grey the Save button out unless something differs from the saved baseline.
local function updateSaveButton()
	if not saveButton then
		return
	end
	saveButton.Disabled = not settingsDirty()
		and next(pendingRenames) == nil
		and next(pendingForgets) == nil
		and next(pendingUnskips) == nil
		and next(pendingSessionUnskips) == nil
		and not geometryDirty
end

---------------------------------------------------------------------------
-- Prompt settings
---------------------------------------------------------------------------

--- Grey the per-type toggles when they cannot take effect: the "every summon"
--- master overrides them, and nothing is filtered when prompting is off.
local function applyTypeMasterState()
	if not everySummonCheck then
		return
	end
	local locked = everySummonCheck.Checked or not promptOnSummon.Checked
	for _, cb in pairs(typeChecks) do
		cb.Disabled = locked
	end
	everySummonCheck.Disabled = not promptOnSummon.Checked
end

local function onSettingChange()
	-- Re-prompting named summons is meaningless if we never prompt at all.
	promptForNamed.Disabled = not promptOnSummon.Checked
	applyTypeMasterState()
	updateSaveButton()
end

--- The type toggles and their master only affect the Save button and each
--- other's enabled state.
local function onTypeChange()
	applyTypeMasterState()
	updateSaveButton()
end

--- Pull settings from the server and reflect them in the checkboxes.
local function loadSettings()
	Channels.GetSettings:RequestToServer({}, function(response)
		local s = response or {}
		local onSummon = s.PromptOnSummon ~= false
		local forNamed = s.PromptForNamed == true
		local pausePrompt = s.PauseOnPrompt == true
		local allowStory = s.AllowStorySummons == true
		local modeIdx = MultiMode.IndexOf(s.MultiSummonMode)
		baseSettings = {
			PromptOnSummon = onSummon,
			PromptForNamed = forNamed,
			PauseOnPrompt = pausePrompt,
			AllowStorySummons = allowStory,
			MultiSummonMode = MultiMode.ValueAt(modeIdx),
		}
		promptOnSummon.Checked = onSummon
		promptForNamed.Checked = forNamed
		promptForNamed.Disabled = not onSummon
		pauseOnPrompt.Checked = pausePrompt
		allowStorySummons.Checked = allowStory
		multiSummonMode.SelectedIndex = modeIdx

		local every = s[Classifier.MASTER_KEY] == true
		baseSettings[Classifier.MASTER_KEY] = every
		everySummonCheck.Checked = every
		for key, cb in pairs(typeChecks) do
			local on = s[key] == true
			baseSettings[key] = on
			cb.Checked = on
		end
		applyTypeMasterState()
		updateSaveButton()
	end)
end

---------------------------------------------------------------------------
-- Save
---------------------------------------------------------------------------

--- Commit the staged settings, renames and removals, then resync from the server.
local function onSave()
	local settings = {
		PromptOnSummon = promptOnSummon.Checked,
		PromptForNamed = promptForNamed.Checked,
		PauseOnPrompt = pauseOnPrompt.Checked,
		AllowStorySummons = allowStorySummons.Checked,
		MultiSummonMode = selectedMultiMode(),
		[Classifier.MASTER_KEY] = everySummonCheck.Checked,
	}
	for key, cb in pairs(typeChecks) do
		settings[key] = cb.Checked
	end
	Channels.SetSettings:SendToServer(settings)
	baseSettings = settings

	-- Staged edits are keyed by row (key + optional unique-set slot); the stored
	-- value carries the Key/Slot the server needs.
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

	saveGeometry()
	geometryDirty = false
	geometryBaseline = nil
	updateSaveButton()
	-- Pull the canonical state back (server-side sanitising, owner names).
	Ext.Timer.WaitForRealtime(120, function()
		refreshNames()
		refreshSkipped()
		refreshSessionSkipped()
	end)
end

---------------------------------------------------------------------------
-- Saved-name manager
---------------------------------------------------------------------------

--- The summoner's name, or their shortened uuid when they are not loaded.
---@param entry table
---@return string
local function ownerLabel(entry)
	if type(entry.OwnerName) == "string" and entry.OwnerName ~= "" then
		return entry.OwnerName
	end
	return "Unknown summoner (" .. entry.Owner:sub(1, 8) .. ")"
end

--- Bucket entries by summoner, preserving the server's sort order.
---@param entries table[]
---@return string[] order  owner uuids in first-seen order
---@return table<string, {label: string, rows: table[]}> groups
local function groupBySummoner(entries)
	local order, groups = {}, {}
	for _, entry in ipairs(entries) do
		local owner = entry.Owner or entry.Key
		if not groups[owner] then
			groups[owner] = { label = ownerLabel(entry), rows = {} }
			order[#order + 1] = owner
		end
		table.insert(groups[owner].rows, entry)
	end
	return order, groups
end

--- A stable per-row id. A unique set has several rows under one key, so the slot
--- disambiguates them; a plain saved name has no slot and keys by itself.
---@param entry table
---@return string
local function stageId(entry)
	if entry.Slot then
		return entry.Key .. "#" .. tostring(entry.Slot)
	end
	return entry.Key
end

--- The template label for a row, suffixed with its slot for a unique set so the
--- several rows of one creature type are told apart (e.g. "Wolf #2"), and tagged
--- with its type (GH #47, e.g. "Wolf #2 (Beast)").
---@param entry table
---@return string
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

function refreshNames()
	if not namesGroup then
		return
	end

	for _, child in ipairs(namesGroup.Children or {}) do
		child:Destroy()
	end
	originalNames = {}
	pendingRenames = {}
	pendingForgets = {}
	updateSaveButton()

	Channels.ListNames:RequestToServer({}, function(response)
		local entries = (response and response.Entries) or {}
		if #entries == 0 then
			namesGroup:AddText("No saved names yet.")
			return
		end

		local order, groups = groupBySummoner(entries)
		for _, owner in ipairs(order) do
			local group = groups[owner]
			local header = namesGroup:AddCollapsingHeader(group.label)
			header.DefaultOpen = true

			local tbl = header:AddTable("Names_" .. owner, 3)
			for _, entry in ipairs(group.rows) do
				local row = tbl:AddRow()
				local id = stageId(entry)
				originalNames[id] = entry.Name

				local input = row:AddCell():AddInputText("", entry.Name)
				input.IDContext = "rename_" .. id
				input.ItemWidth = Layout.ScaleW(200)
				-- Stage on every keystroke; nothing is sent until Save.
				input.OnChange = function()
					local name = Util.Sanitise(input.Text or "")
					if name ~= "" and name ~= originalNames[id] then
						pendingRenames[id] = { Key = entry.Key, Slot = entry.Slot, Name = name }
					else
						pendingRenames[id] = nil
					end
					updateSaveButton()
				end

				local templateText = row:AddCell():AddText(rowLabel(entry))
				templateText.Disabled = true

				local forget = row:AddCell():AddButton("Forget")
				forget.IDContext = "forget_" .. id
				-- Removal is staged, not immediate; toggle it and grey the row's field.
				forget.OnClick = function()
					if pendingForgets[id] then
						pendingForgets[id] = nil
						forget.Label = "Forget"
						input.Disabled = false
					else
						pendingForgets[id] = { Key = entry.Key, Slot = entry.Slot }
						pendingRenames[id] = nil
						forget.Label = "Undo"
						input.Disabled = true
					end
					updateSaveButton()
				end
			end
		end
	end)
end

---------------------------------------------------------------------------
-- Skip managers (always-skipped and skipped-this-session share a layout)
---------------------------------------------------------------------------

--- Render a per-summoner list of skipped summons into `group`. Each row's button
--- stages an undo into `pendingSet`; nothing is sent until Save flushes it.
---@param group any
---@param entries table[]
---@param pendingSet table<string, boolean>
---@param emptyText string
---@param idPrefix string
local function buildSkipList(group, entries, pendingSet, emptyText, idPrefix)
	if #entries == 0 then
		group:AddText(emptyText)
		return
	end

	local order, groups = groupBySummoner(entries)
	for _, owner in ipairs(order) do
		local ownerGroup = groups[owner]
		local header = group:AddCollapsingHeader(ownerGroup.label)
		header.DefaultOpen = true

		local tbl = header:AddTable(idPrefix .. "_" .. owner, 2)
		for _, entry in ipairs(ownerGroup.rows) do
			local row = tbl:AddRow()

			local templateText = row:AddCell():AddText(entry.TemplateName or "Summon")
			templateText.Disabled = true

			local undo = row:AddCell():AddButton("Prompt again")
			undo.IDContext = idPrefix .. "_" .. entry.Key
			-- Staged, not immediate; toggle the label until Save flushes it.
			undo.OnClick = function()
				if pendingSet[entry.Key] then
					pendingSet[entry.Key] = nil
					undo.Label = "Prompt again"
				else
					pendingSet[entry.Key] = true
					undo.Label = "Undo"
				end
				updateSaveButton()
			end
		end
	end
end

function refreshSkipped()
	if not skippedGroup then
		return
	end
	for _, child in ipairs(skippedGroup.Children or {}) do
		child:Destroy()
	end
	pendingUnskips = {}
	updateSaveButton()

	Channels.ListSkipped:RequestToServer({}, function(response)
		buildSkipList(
			skippedGroup,
			(response and response.Entries) or {},
			pendingUnskips,
			"No always-skipped summons yet.",
			"unskip"
		)
	end)
end

function refreshSessionSkipped()
	if not sessionGroup then
		return
	end
	for _, child in ipairs(sessionGroup.Children or {}) do
		child:Destroy()
	end
	pendingSessionUnskips = {}
	updateSaveButton()

	Channels.ListSessionSkipped:RequestToServer({}, function(response)
		buildSkipList(
			sessionGroup,
			(response and response.Entries) or {},
			pendingSessionUnskips,
			"Nothing skipped this session.",
			"unsession"
		)
	end)
end

---------------------------------------------------------------------------
-- Window geometry (persisted ourselves; see WindowState.lua)
---------------------------------------------------------------------------

--- Seed a freshly created window with its saved position and size, clamped to
--- the current viewport so geometry saved on a bigger monitor still fits.
local function applySavedGeometry()
	local saved = WindowState.Get(WINDOW_KEY)
	if not (saved and saved.size) then
		configWindow:SetSize(Layout.Size(1200, 900), "FirstUseEver")
		return
	end

	local vw, vh = Layout.Viewport()
	local w = math.min(saved.size[1], vw * 0.98)
	local h = math.min(saved.size[2], vh * 0.98)
	configWindow:SetSize({ w, h }, "FirstUseEver")

	if saved.pos then
		-- Keep the title bar reachable if the window was saved partly off-screen.
		local x = math.max(0, math.min(saved.pos[1], vw - w))
		local y = math.max(0, math.min(saved.pos[2], vh - h))
		configWindow:SetPos({ x, y }, "FirstUseEver")
	end
end

--- The window's live geometry (its last drawn frame), or nil if not yet drawn.
---@return table|nil
local function currentGeometry()
	if not configWindow then
		return nil
	end
	local pos, size = configWindow.LastPosition, configWindow.LastSize
	if pos and size and size[1] > 0 and size[2] > 0 then
		return { pos = { pos[1], pos[2] }, size = { size[1], size[2] } }
	end
	return nil
end

--- Persist the window's current geometry. Only called from Save.
function saveGeometry()
	local g = currentGeometry()
	if g then
		WindowState.Set(WINDOW_KEY, g.pos, g.size)
	end
end

--- Forget the persisted geometry and snap the live window back to the centered
--- default. This one is immediate (like Refresh), not staged behind Save.
local function resetGeometry()
	WindowState.Clear(WINDOW_KEY)
	geometryDirty = false
	geometryBaseline = nil
	if configWindow then
		local vw, vh = Layout.Viewport()
		configWindow:SetSize(Layout.Size(1200, 900), "Always")
		configWindow:SetPos({ vw / 2, vh / 2 }, "Always", { 0.5, 0.5 })
	end
	updateSaveButton()
end

--- Discard an unsaved resize/move when the window closes.
local function discardGeometry()
	geometryDirty = false
	geometryBaseline = nil
end

---@param a table
---@param b table
---@return boolean
local function geometryDiffers(a, b)
	return math.abs(a.pos[1] - b.pos[1]) > 1
		or math.abs(a.pos[2] - b.pos[2]) > 1
		or math.abs(a.size[1] - b.size[1]) > 1
		or math.abs(a.size[2] - b.size[2]) > 1
end

--- While the window is open, watch for the player dragging or resizing it and
--- flag Save. ImGui has no resize event, so we sample the geometry each tick and
--- diff it against the snapshot taken when the window opened.
local function pollGeometry()
	if not (configWindow and configWindow.Open) then
		geometryPolling = false
		return
	end
	local g = currentGeometry()
	if g then
		if not geometryBaseline then
			geometryBaseline = g
		elseif not geometryDirty and geometryDiffers(g, geometryBaseline) then
			geometryDirty = true
			updateSaveButton()
		end
	end
	Ext.Timer.WaitForRealtime(300, pollGeometry)
end

function startGeometryPoll()
	geometryDirty = false
	geometryBaseline = nil
	if geometryPolling then
		return
	end
	geometryPolling = true
	Ext.Timer.WaitForRealtime(300, pollGeometry)
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

--- Reload every list and the settings from the server (the Refresh button).
local function refreshAll()
	loadSettings()
	refreshNames()
	refreshSkipped()
	refreshSessionSkipped()
end

function ConfigUI.Open()
	if not configWindow then
		configWindow = Ext.IMGUI.NewWindow("Name Your Summons")
		configWindow.Closeable = true
		-- Never let BG3SE persist open-state (it would reopen on its own next
		-- launch); we persist only geometry ourselves. See WindowState.lua.
		configWindow.NoSavedSettings = true
		configWindow.Open = false
		configWindow.OnClose = discardGeometry
		applySavedGeometry()

		-- Title row: Refresh sits top-right (empty stretch column pushes it over).
		local topBar = configWindow:AddTable("TopBar", 2)
		topBar:AddColumn("", "WidthStretch")
		topBar:AddColumn("", "WidthFixed")
		local topRow = topBar:AddRow()
		topRow:AddCell()
		local refresh = topRow:AddCell():AddButton("Refresh")
		refresh.OnClick = refreshAll

		configWindow:AddSeparatorText("Prompt")
		promptOnSummon = configWindow:AddCheckbox("Ask me to name new summons", true)
		promptOnSummon.OnChange = onSettingChange
		promptForNamed = configWindow:AddCheckbox("Also re-ask for summons I have already named", false)
		promptForNamed.OnChange = onSettingChange
		pauseOnPrompt = configWindow:AddCheckbox("Pause the game (turn-based mode) while I name a summon", false)
		pauseOnPrompt.OnChange = onSettingChange
		allowStorySummons = configWindow:AddCheckbox("Allow renaming story-bound summons (e.g. 'Us')", false)
		allowStorySummons.OnChange = onSettingChange

		local typesHeader = configWindow:AddCollapsingHeader("Summon types to name")
		local typesHint = typesHeader:AddText(
			"Which summons to prompt for, by the creature type read from its tags. "
				.. "Familiars count as 'Familiars' whatever their type, so the creature types below "
				.. "apply to non-familiar summons only."
		)
		typesHint.Disabled = true
		everySummonCheck = typesHeader:AddCheckbox("Every summon (ignore the type filter below)", false)
		everySummonCheck.OnChange = onTypeChange
		for _, cat in ipairs(Classifier.CATEGORIES) do
			local cb = typesHeader:AddCheckbox(cat.label, cat.key == "Familiar")
			cb.OnChange = onTypeChange
			typeChecks[Classifier.SettingKey(cat.key)] = cb
		end

		local multiLabel = configWindow:AddText("When one spell summons several creatures at once:")
		multiLabel.Disabled = true
		multiSummonMode = configWindow:AddCombo("")
		multiSummonMode.IDContext = "multiSummonMode"
		multiSummonMode.Options = MultiMode.LABELS
		multiSummonMode.SelectedIndex = 0
		multiSummonMode.OnChange = updateSaveButton
		local multiHint = configWindow:AddText("The names are remembered and reused the next time you summon.")
		multiHint.Disabled = true

		configWindow:AddSeparatorText("Saved names")
		namesGroup = configWindow:AddGroup("SavedNamesList")

		configWindow:AddSeparatorText("Always skipped")
		local skipHint =
			configWindow:AddText("Summons you chose never to be prompted about. Use 'Prompt again' to undo.")
		skipHint.Disabled = true
		skippedGroup = configWindow:AddGroup("SkippedList")

		configWindow:AddSeparatorText("Skipped this session")
		local sessionHint = configWindow:AddText("Summons you skipped since the game loaded; forgotten on reload.")
		sessionHint.Disabled = true
		sessionGroup = configWindow:AddGroup("SessionSkippedList")

		configWindow:AddSeparator()
		-- Save centered (middle fixed column); reset sits in the left column.
		local saveBar = configWindow:AddTable("SaveBar", 3)
		saveBar:AddColumn("", "WidthStretch")
		saveBar:AddColumn("", "WidthFixed")
		saveBar:AddColumn("", "WidthStretch")
		local saveRow = saveBar:AddRow()
		local reset = saveRow:AddCell():AddButton("Reset window size & position")
		reset.OnClick = resetGeometry
		saveButton = saveRow:AddCell():AddButton("Save")
		saveRow:AddCell()
		saveButton.Disabled = true
		saveButton.OnClick = onSave
	end

	configWindow.Open = true
	loadSettings()
	refreshNames()
	refreshSkipped()
	refreshSessionSkipped()
	startGeometryPoll()
end

function ConfigUI.Register()
	-- Type  client  then  !nys_ui  in the Script Extender console.
	Ext.RegisterConsoleCommand("nys_ui", function()
		ConfigUI.Open()
	end)
end

return ConfigUI
