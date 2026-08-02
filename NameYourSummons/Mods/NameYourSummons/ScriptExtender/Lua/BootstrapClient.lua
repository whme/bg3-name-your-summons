local Util = Ext.Require("Shared/Util.lua")
Ext.Require("Shared/Channels.lua")

local UI = Ext.Require("Client/PromptUI.lua")
local ConfigUI = Ext.Require("Client/ConfigUI.lua")

-- Server-owned and not synced, but the docs recommend identical registrations
-- on both states to avoid serialisation mismatches.
Ext.Vars.RegisterModVariable(ModuleUUID, "SummonNames", {
	Server = true,
	Client = false,
	WriteableOnServer = true,
	Persistent = true,
	SyncToClient = false,
})
Ext.Vars.RegisterModVariable(ModuleUUID, "Settings", {
	Server = true,
	Client = false,
	WriteableOnServer = true,
	Persistent = true,
	SyncToClient = false,
})
Ext.Vars.RegisterModVariable(ModuleUUID, "SkippedSummons", {
	Server = true,
	Client = false,
	WriteableOnServer = true,
	Persistent = true,
	SyncToClient = false,
})

UI.Register()
ConfigUI.Register()

Ext.Events.SessionLoaded:Subscribe(function()
	Util.Log("Client ready. Type 'client' then '!nys_ui' in the console to manage saved names.")
end)
