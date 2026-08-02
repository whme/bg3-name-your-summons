local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")

local ConfigUI = {}

local configWindow, namesGroup
local promptOnSummon, promptForNamed

---------------------------------------------------------------------------
-- Prompt settings
---------------------------------------------------------------------------

--- Push the current checkbox state to the server.
local function pushSettings()
	-- Re-prompting named summons is meaningless if we never prompt at all.
	promptForNamed.Disabled = not promptOnSummon.Checked
	Channels.SetSettings:SendToServer({
		PromptOnSummon = promptOnSummon.Checked,
		PromptForNamed = promptForNamed.Checked,
	})
end

--- Pull settings from the server and reflect them in the checkboxes.
local function loadSettings()
	Channels.GetSettings:RequestToServer({}, function(response)
		local s = response or {}
		promptOnSummon.Checked = s.PromptOnSummon ~= false
		promptForNamed.Checked = s.PromptForNamed == true
		promptForNamed.Disabled = s.PromptOnSummon == false
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

local function refreshNames()
	if not namesGroup then
		return
	end

	for _, child in ipairs(namesGroup.Children or {}) do
		child:Destroy()
	end

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

				local input = row:AddCell():AddInputText("", entry.Name)
				input.IDContext = "rename_" .. entry.Key
				input.EnterReturnsTrue = true
				input.ItemWidth = 200
				input.OnChange = function()
					local name = Util.Sanitise(input.Text or "")
					if name ~= "" and name ~= entry.Name then
						Channels.RenameName:SendToServer({ Key = entry.Key, Name = name })
						Ext.Timer.WaitForRealtime(120, refreshNames)
					end
				end

				local templateText = row:AddCell():AddText(entry.TemplateName or "Summon")
				templateText.Disabled = true

				local forget = row:AddCell():AddButton("Forget")
				forget.IDContext = "forget_" .. entry.Key
				forget.OnClick = function()
					Channels.ForgetName:SendToServer({ Key = entry.Key })
					Ext.Timer.WaitForRealtime(120, refreshNames)
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
		configWindow.Open = false
		configWindow:SetSize({ 480, 400 }, "FirstUseEver")

		configWindow:AddText("Prompt")
		promptOnSummon = configWindow:AddCheckbox("Ask me to name new summons", true)
		promptOnSummon.OnChange = pushSettings
		promptForNamed = configWindow:AddCheckbox("Also re-ask for summons I have already named", false)
		promptForNamed.OnChange = pushSettings

		configWindow:AddSeparator()
		configWindow:AddText("Saved names")
		local refresh = configWindow:AddButton("Refresh")
		refresh.OnClick = refreshNames
		configWindow:AddSpacing()
		namesGroup = configWindow:AddGroup("SavedNamesList")
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
