-- SPDX-License-Identifier: MIT
local Util = Ext.Require("Shared/Util.lua")
local Trace = Ext.Require("Shared/Trace.lua")
Ext.Require("Shared/Channels.lua")

Trace.Register()
Trace.Log("bootstrap", "client bootstrap")

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

-- `!nys_debug` un-gates Util.Log (issue #106); registered in each state so it flips both.
pcall(function()
	Ext.RegisterConsoleCommand("nys_debug", function()
		Util.SetDebug(not Util.DebugEnabled())
		Util.Say("debug logging", Util.DebugEnabled() and "ON" or "OFF", "(client)")
	end)
end)

Ext.Events.SessionLoaded:Subscribe(function()
	Trace.Log("session", "client SessionLoaded")
end)

Util.Say(("Name Your Summons v%s loaded successfully (client)."):format(Util.VersionString()))

pcall(function()
	Ext.Events.GameStateChanged:Subscribe(function(e)
		Trace.Log("gamestate", "client GameStateChanged", {
			FromState = tostring(e.FromState),
			ToState = tostring(e.ToState),
		})
	end)
end)
