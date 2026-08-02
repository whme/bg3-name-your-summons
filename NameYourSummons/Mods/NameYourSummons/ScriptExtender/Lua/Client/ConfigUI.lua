local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Layout = Ext.Require("Client/Layout.lua")
local WindowState = Ext.Require("Client/WindowState.lua")

local ConfigUI = {}

-- Key under which this window's geometry is persisted (see WindowState.lua).
local WINDOW_KEY = "config"

local configWindow, namesGroup, saveButton
local promptOnSummon, promptForNamed

-- Edits stay local until Save; reopening reloads from the server, which is
-- what discards unsaved edits. baseSettings is the checkbox baseline;
-- originalNames the per-row name baseline that keystrokes diff against.
local baseSettings = { PromptOnSummon = true, PromptForNamed = false }
local originalNames = {}
local pendingRenames = {}
local pendingForgets = {}

-- Geometry is staged like every other edit: a live resize/move sets this dirty
-- (which enables Save) but nothing hits disk until Save. Closing discards it.
local geometryDirty = false
local geometryBaseline -- { pos = {x,y}, size = {w,h} } snapshotted when the window opens
local geometryPolling = false

local refreshNames, saveGeometry, startGeometryPoll

---------------------------------------------------------------------------
-- Staged-change tracking
---------------------------------------------------------------------------

--- Grey the Save button out unless something differs from the saved baseline.
local function updateSaveButton()
	if not saveButton then
		return
	end
	saveButton.Disabled = promptOnSummon.Checked == baseSettings.PromptOnSummon
		and promptForNamed.Checked == baseSettings.PromptForNamed
		and next(pendingRenames) == nil
		and next(pendingForgets) == nil
		and not geometryDirty
end

---------------------------------------------------------------------------
-- Prompt settings
---------------------------------------------------------------------------

local function onSettingChange()
	-- Re-prompting named summons is meaningless if we never prompt at all.
	promptForNamed.Disabled = not promptOnSummon.Checked
	updateSaveButton()
end

--- Pull settings from the server and reflect them in the checkboxes.
local function loadSettings()
	Channels.GetSettings:RequestToServer({}, function(response)
		local s = response or {}
		local onSummon = s.PromptOnSummon ~= false
		local forNamed = s.PromptForNamed == true
		baseSettings = { PromptOnSummon = onSummon, PromptForNamed = forNamed }
		promptOnSummon.Checked = onSummon
		promptForNamed.Checked = forNamed
		promptForNamed.Disabled = not onSummon
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
	}
	Channels.SetSettings:SendToServer(settings)
	baseSettings = settings

	for key in pairs(pendingForgets) do
		Channels.ForgetName:SendToServer({ Key = key })
	end
	pendingForgets = {}

	for key, name in pairs(pendingRenames) do
		Channels.RenameName:SendToServer({ Key = key, Name = name })
	end
	pendingRenames = {}

	saveGeometry()
	geometryDirty = false
	geometryBaseline = nil
	updateSaveButton()
	-- Pull the canonical state back (server-side sanitising, owner names).
	Ext.Timer.WaitForRealtime(120, refreshNames)
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

		-- Group by summoner, preserving the server's (owner, name) sort order.
		local order, groups = {}, {}
		for _, entry in ipairs(entries) do
			local owner = entry.Owner or entry.Key
			if not groups[owner] then
				groups[owner] = { label = ownerLabel(entry), rows = {} }
				order[#order + 1] = owner
			end
			table.insert(groups[owner].rows, entry)
		end

		for _, owner in ipairs(order) do
			local group = groups[owner]
			local header = namesGroup:AddCollapsingHeader(group.label)
			header.DefaultOpen = true

			local tbl = header:AddTable("Names_" .. owner, 3)
			for _, entry in ipairs(group.rows) do
				local row = tbl:AddRow()
				originalNames[entry.Key] = entry.Name

				local input = row:AddCell():AddInputText("", entry.Name)
				input.IDContext = "rename_" .. entry.Key
				input.ItemWidth = Layout.ScaleW(200)
				-- Stage on every keystroke; nothing is sent until Save.
				input.OnChange = function()
					local name = Util.Sanitise(input.Text or "")
					if name ~= "" and name ~= originalNames[entry.Key] then
						pendingRenames[entry.Key] = name
					else
						pendingRenames[entry.Key] = nil
					end
					updateSaveButton()
				end

				local templateText = row:AddCell():AddText(entry.TemplateName or "Summon")
				templateText.Disabled = true

				local forget = row:AddCell():AddButton("Forget")
				forget.IDContext = "forget_" .. entry.Key
				-- Removal is staged, not immediate; toggle it and grey the row's field.
				forget.OnClick = function()
					if pendingForgets[entry.Key] then
						pendingForgets[entry.Key] = nil
						forget.Label = "Forget"
						input.Disabled = false
					else
						pendingForgets[entry.Key] = true
						pendingRenames[entry.Key] = nil
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

		configWindow:AddText("Prompt")
		promptOnSummon = configWindow:AddCheckbox("Ask me to name new summons", true)
		promptOnSummon.OnChange = onSettingChange
		promptForNamed = configWindow:AddCheckbox("Also re-ask for summons I have already named", false)
		promptForNamed.OnChange = onSettingChange

		configWindow:AddSeparator()
		configWindow:AddText("Saved names")
		local refresh = configWindow:AddButton("Refresh")
		refresh.OnClick = refreshNames
		configWindow:AddSpacing()
		namesGroup = configWindow:AddGroup("SavedNamesList")

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
	startGeometryPoll()
end

function ConfigUI.Register()
	-- Type  client  then  !nys_ui  in the Script Extender console.
	Ext.RegisterConsoleCommand("nys_ui", function()
		ConfigUI.Open()
	end)
end

return ConfigUI
