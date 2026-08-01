local Util     = Ext.Require("Shared/Util.lua")
local Channels = Ext.Require("Shared/Channels.lua")

local UI = {}

---------------------------------------------------------------------------
-- Naming prompt
---------------------------------------------------------------------------

local promptWindow, promptLabel, promptInput
local queue   = {}   -- pending requests, FIFO
local current = nil  -- the request currently on screen

local function submit(save)
    if not current then return end

    local name = save and Util.Sanitise(promptInput.Text or "") or ""

    Channels.SubmitName:SendToServer({
        Key        = current.Key,
        SummonUuid = current.SummonUuid,
        Name       = name,
    })

    current = nil
    promptWindow.Open = false
    UI.ShowNext()
end

local function buildPrompt()
    if promptWindow then return end

    promptWindow = Ext.IMGUI.NewWindow("Name Your Summon")
    promptWindow.Closeable       = true
    promptWindow.AlwaysAutoResize = true
    promptWindow.NoCollapse      = true
    promptWindow.NoSavedSettings = true
    promptWindow.Open            = false

    promptLabel = promptWindow:AddText("")

    promptInput = promptWindow:AddInputText("", "")
    promptInput.Hint            = "Enter a name..."
    promptInput.EnterReturnsTrue = true
    promptInput.AutoSelectAll   = true
    promptInput.ItemWidth       = 260
    promptInput.OnChange        = function() submit(true) end

    promptWindow:AddSpacing()

    local confirm = promptWindow:AddButton("Name it")
    confirm.OnClick = function() submit(true) end

    local skip = promptWindow:AddButton("Skip")
    skip.SameLine = true
    skip.OnClick  = function() submit(false) end

    promptWindow:AddSeparator()
    local hint = promptWindow:AddText("The name is remembered and reapplied next time you summon this creature.")
    hint.Disabled = true

    -- Closing via the X counts as skipping, so the queue keeps moving.
    promptWindow.OnClose = function()
        if current then submit(false) end
    end
end

function UI.ShowNext()
    if current ~= nil then return end
    local nextReq = table.remove(queue, 1)
    if not nextReq then return end

    buildPrompt()
    current = nextReq

    local default = nextReq.DefaultName
    if default == nil or default == "" then default = "Summon" end

    promptLabel.Label = ("You summoned: %s"):format(default)
    promptInput.Text  = default
    promptWindow.Open = true
end

---------------------------------------------------------------------------
-- Saved names manager
---------------------------------------------------------------------------

local managerWindow, managerList

local function refreshManager()
    if not managerList then return end

    for _, child in ipairs(managerList.Children or {}) do
        child:Destroy()
    end

    Channels.ListNames:RequestToServer({}, function(response)
        local entries = (response and response.Entries) or {}
        if #entries == 0 then
            managerList:AddText("No saved names yet.")
            return
        end

        local tbl = managerList:AddTable("SavedNames", 3)
        for _, entry in ipairs(entries) do
            local row = tbl:AddRow()
            row:AddCell():AddText(entry.Name)

            -- The key is "<ownerUuid>|<rootTemplate>"; show only the template.
            local template = entry.Key:match("|(.+)$") or entry.Key
            local templateText = row:AddCell():AddText(template)
            templateText.Disabled = true

            local forget = row:AddCell():AddButton("Forget")
            forget.IDContext = "forget_" .. entry.Key
            forget.OnClick = function()
                Channels.ForgetName:SendToServer({ Key = entry.Key })
                Ext.Timer.WaitForRealtime(120, refreshManager)
            end
        end
    end)
end

function UI.OpenManager()
    if not managerWindow then
        managerWindow = Ext.IMGUI.NewWindow("Summon Names")
        managerWindow.Closeable = true
        managerWindow.Open      = false

        local refresh = managerWindow:AddButton("Refresh")
        refresh.OnClick = refreshManager

        managerWindow:AddSeparator()
        managerList = managerWindow:AddGroup("SavedNamesList")
    end

    managerWindow.Open = true
    refreshManager()
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

function UI.Register()
    Channels.AskName:SetHandler(function(data, _user)
        if type(data) ~= "table" or type(data.Key) ~= "string" then return end
        table.insert(queue, data)
        UI.ShowNext()
    end)

    -- Fallback naming path: the server minted a new localisation handle and
    -- needs this client's loca table to know about it.
    Channels.SetLoca:SetHandler(function(data, _user)
        if type(data) ~= "table" then return end
        if type(data.Handle) ~= "string" or type(data.Text) ~= "string" then return end
        pcall(Ext.Loca.UpdateTranslatedString, data.Handle, data.Text)
    end)

    -- Type  client  then  !sn_ui  in the Script Extender console.
    Ext.RegisterConsoleCommand("sn_ui", function()
        UI.OpenManager()
    end)
end

return UI
