local Util = Ext.Require("Shared/Util.lua")
Ext.Require("Shared/Channels.lua")

local UI = Ext.Require("Client/PromptUI.lua")
local ConfigUI = Ext.Require("Client/ConfigUI.lua")
local NativeConfigUI = Ext.Require("Client/NativeConfigUI.lua")
local NativeRenameUI = Ext.Require("Client/NativeRenameUI.lua")

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
-- The ImGui config stays for now (reached via the prompt's Settings button and
-- the !nys_ui console command); only the Examine gear moves to the native panel.
ConfigUI.Register()
NativeConfigUI.Register()
-- NativeRenameUI owns Examine-panel detection and node lookup; wire the two
-- client modules together here (avoids a circular require between them).
NativeConfigUI.SetPanelFinder(NativeRenameUI.FindNamed)
NativeRenameUI.SetGearHandler(NativeConfigUI.Open)
NativeRenameUI.SetPanelCloseHandler(NativeConfigUI.OnPanelClose)
NativeRenameUI.Register()

Ext.Events.SessionLoaded:Subscribe(function()
	Util.Log("Client ready. Type 'client' then '!nys_ui' in the console to manage saved names.")
end)
