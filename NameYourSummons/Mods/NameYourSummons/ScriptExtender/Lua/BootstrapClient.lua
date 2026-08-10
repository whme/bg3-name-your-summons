-- SPDX-License-Identifier: MIT
local Util = Ext.Require("Shared/Util.lua")
Ext.Require("Shared/Channels.lua")

local Loca = Ext.Require("Client/Loca.lua")
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

Loca.Register()
NativeConfigUI.Register()
-- NativeRenameUI owns Examine-panel detection and node lookup; wire the two
-- client modules together here (avoids a circular require between them).
NativeConfigUI.SetPanelFinder(NativeRenameUI.FindNamed)
NativeRenameUI.SetGearHandler(NativeConfigUI.Open)
NativeRenameUI.Register()

Ext.Events.SessionLoaded:Subscribe(function()
	Util.Log("Client ready. Examine a summon and click the gear to manage saved names.")
end)
