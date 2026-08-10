-- SPDX-License-Identifier: MIT
local Util = Ext.Require("Shared/Util.lua")
Ext.Require("Shared/Channels.lua")

local Loca = Ext.Require("Client/Loca.lua")
local NativeConfigUI = Ext.Require("Client/NativeConfigUI.lua")
local NativeRenameUI = Ext.Require("Client/NativeRenameUI.lua")

-- The docs require identical ModVar prototypes in both Lua states.
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

Loca.Register()
NativeConfigUI.Register()
-- Wire the two client modules here to avoid a circular require.
NativeConfigUI.SetPanelFinder(NativeRenameUI.FindNamedIn)
NativeConfigUI.SetViewerProvider(NativeRenameUI.ViewerOf)
NativeRenameUI.SetGearHandler(NativeConfigUI.Open)
NativeRenameUI.SetPanelCloseHandler(NativeConfigUI.Flush)
NativeRenameUI.Register()

Ext.Events.SessionLoaded:Subscribe(function()
	Util.Log("Client ready. Examine a summon and click the gear to manage saved names.")
end)
