local Util = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")
local Writer = Ext.Require("Shared/NameWriter.lua")
local ConfigUI = Ext.Require("Client/ConfigUI.lua")
local Layout = Ext.Require("Client/Layout.lua")

local UI = {}

---------------------------------------------------------------------------
-- Naming prompt
---------------------------------------------------------------------------

local promptWindow, promptLabel, promptInput
local queue = {} -- pending requests, FIFO
local current = nil -- the request currently on screen

--- Send the player's decision to the server.
---@param save boolean  persist the typed name
---@param alwaysSkip boolean|nil  never prompt for this summon again
---@param abort boolean|nil  dismiss without recording a skip
local function submit(save, alwaysSkip, abort)
	if not current then
		return
	end

	local name = save and Util.Sanitise(promptInput.Text or "") or ""

	Channels.SubmitName:SendToServer({
		Key = current.Key,
		SummonUuid = current.SummonUuid,
		Scope = current.Scope,
		Slot = current.Slot,
		Name = name,
		AlwaysSkip = alwaysSkip == true,
		Abort = abort or nil,
	})

	current = nil
	promptWindow.Open = false
	UI.ShowNext()
end

local function buildPrompt()
	if promptWindow then
		return
	end

	promptWindow = Ext.IMGUI.NewWindow("Name Your Summon")
	promptWindow.Closeable = true
	promptWindow.AlwaysAutoResize = true
	promptWindow.NoCollapse = true
	promptWindow.NoSavedSettings = true
	promptWindow.Open = false

	promptLabel = promptWindow:AddText("")

	promptInput = promptWindow:AddInputText("", "")
	promptInput.Hint = "Enter a name..."
	promptInput.EnterReturnsTrue = true
	promptInput.AutoSelectAll = true
	promptInput.ItemWidth = Layout.ScaleW(260)
	promptInput.OnChange = function()
		submit(true)
	end

	promptWindow:AddSpacing()

	local confirm = promptWindow:AddButton("Name it")
	confirm.OnClick = function()
		submit(true)
	end

	local skip = promptWindow:AddButton("Skip")
	skip.SameLine = true
	skip.OnClick = function()
		submit(false)
	end

	local alwaysSkip = promptWindow:AddButton("Never for this summon")
	alwaysSkip.SameLine = true
	alwaysSkip.OnClick = function()
		submit(false, true)
	end

	local settings = promptWindow:AddButton("Settings")
	settings.SameLine = true
	settings.OnClick = function()
		ConfigUI.Open()
	end

	promptWindow:AddSeparator()
	local hint = promptWindow:AddText("The name is remembered and reapplied next time you summon this creature.")
	hint.Disabled = true

	-- The X aborts rather than skips, so this summon is prompted for again.
	promptWindow.OnClose = function()
		if current then
			submit(false, false, true)
		end
	end
end

--- Drop any queued or on-screen prompt for a key the server has retracted (it
--- turned out to be a multi-summon we should not have asked about). No submit is
--- sent - the server already resolved this key.
---@param key string
local function cancel(key)
	for i = #queue, 1, -1 do
		if queue[i].Key == key then
			table.remove(queue, i)
		end
	end
	if current and current.Key == key then
		current = nil
		if promptWindow then
			promptWindow.Open = false
		end
		UI.ShowNext()
	end
end

function UI.ShowNext()
	if current ~= nil then
		return
	end
	local nextReq = table.remove(queue, 1)
	if not nextReq then
		return
	end

	buildPrompt()
	current = nextReq

	local default = nextReq.DefaultName
	if default == nil or default == "" then
		default = "Summon"
	end

	promptLabel.Label = ("You summoned: %s"):format(default)
	promptInput.Text = default

	-- "Appearing" recenters on each open yet still lets the player drag it.
	local vw, vh = Layout.Viewport()
	pcall(function()
		promptWindow:SetPos({ vw / 2, vh / 2 }, "Appearing", { 0.5, 0.5 })
	end)

	promptWindow.Open = true
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

function UI.Register()
	Channels.AskName:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		table.insert(queue, data)
		UI.ShowNext()
	end)

	Channels.RetractPrompt:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Key) ~= "string" then
			return
		end
		cancel(data.Key)
	end)

	Channels.ApplyName:SetHandler(function(data, _user)
		if type(data) ~= "table" then
			return
		end
		if type(data.Handle) ~= "string" or type(data.Text) ~= "string" then
			return
		end
		Writer.RegisterLoca(data.Handle, data.Text)
	end)

	Channels.SeedLoca:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Entries) ~= "table" then
			return
		end
		for handle, text in pairs(data.Entries) do
			if type(handle) == "string" and type(text) == "string" then
				Writer.RegisterLoca(handle, text)
			end
		end
	end)
end

return UI
