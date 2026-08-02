local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")

local ConfigUI = {}

local configWindow, namesGroup, saveButton
local promptOnSummon, promptForNamed

-- Edits stay local until Save; reopening reloads from the server, which is
-- what discards unsaved edits. baseSettings is the checkbox baseline;
-- originalNames the per-row name baseline that keystrokes diff against.
local baseSettings = { PromptOnSummon = true, PromptForNamed = false }
local originalNames = {}
local pendingRenames = {}
local pendingForgets = {}

local refreshNames

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
				input.ItemWidth = 200
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
-- Window
---------------------------------------------------------------------------

function ConfigUI.Open()
	if not configWindow then
		configWindow = Ext.IMGUI.NewWindow("Name Your Summons")
		configWindow.Closeable = true
		configWindow.NoSavedSettings = true
		configWindow.Open = false
		configWindow:SetSize({ 480, 400 }, "FirstUseEver")

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
		-- Center the button: the outer columns stretch, the middle fits it.
		local saveBar = configWindow:AddTable("SaveBar", 3)
		saveBar:AddColumn("", "WidthStretch")
		saveBar:AddColumn("", "WidthFixed")
		saveBar:AddColumn("", "WidthStretch")
		local saveRow = saveBar:AddRow()
		saveRow:AddCell()
		saveButton = saveRow:AddCell():AddButton("Save")
		saveRow:AddCell()
		saveButton.Disabled = true
		saveButton.OnClick = onSave
	end

	configWindow.Open = true
	loadSettings()
	refreshNames()
end

function ConfigUI.Register()
	-- Type  client  then  !nys_ui  in the Script Extender console.
	Ext.RegisterConsoleCommand("nys_ui", function()
		ConfigUI.Open()
	end)
end

return ConfigUI
