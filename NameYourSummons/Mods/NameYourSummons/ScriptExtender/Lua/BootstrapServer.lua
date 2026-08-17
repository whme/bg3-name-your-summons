-- SPDX-License-Identifier: MIT
local Util = Ext.Require("Shared/Util.lua")
local Trace = Ext.Require("Shared/Trace.lua")
Ext.Require("Shared/Channels.lua")

local Store = Ext.Require("Server/Store.lua")
local Watcher = Ext.Require("Server/SummonWatcher.lua")

Trace.Register()
Trace.Log("bootstrap", "server bootstrap")

-- ModVar prototypes must be registered at bootstrap, before any save loads.
Store.Register()

Watcher.RegisterNet()
Watcher.RegisterConsole()

-- `!nys_debug` un-gates Util.Log (issue #106); registered in each state so it flips both.
pcall(function()
	Ext.RegisterConsoleCommand("nys_debug", function()
		Util.SetDebug(not Util.DebugEnabled())
		Util.Say("debug logging", Util.DebugEnabled() and "ON" or "OFF", "(server)")
	end)
end)

Ext.Events.SessionLoaded:Subscribe(function()
	Trace.Log("session", "server SessionLoaded")
	Watcher.Register()
	-- Delay so summons already alive on load are fully assembled before reapply.
	Ext.Timer.WaitFor(1500, function()
		local ok, err = pcall(Watcher.ReapplyExisting)
		if not ok then
			Util.Warn("ReapplyExisting failed: " .. tostring(err))
			Trace.Log("error", "ReapplyExisting failed", { Error = tostring(err) })
		end
	end)
end)

Util.Say(("Name Your Summons v%s loaded successfully (server)."):format(Util.VersionString()))
