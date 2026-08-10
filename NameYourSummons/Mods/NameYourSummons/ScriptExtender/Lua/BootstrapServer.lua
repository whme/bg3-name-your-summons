-- SPDX-License-Identifier: MIT
local Util = Ext.Require("Shared/Util.lua")
Ext.Require("Shared/Channels.lua")

local Store = Ext.Require("Server/Store.lua")
local Watcher = Ext.Require("Server/SummonWatcher.lua")

-- ModVar prototypes must be registered at bootstrap, before any save loads.
Store.Register()

Watcher.RegisterNet()
Watcher.RegisterConsole()

Ext.Events.SessionLoaded:Subscribe(function()
	Watcher.Register()
	-- Delay so summons already alive on load are fully assembled before reapply.
	Ext.Timer.WaitFor(1500, function()
		local ok, err = pcall(Watcher.ReapplyExisting)
		if not ok then
			Util.Warn("ReapplyExisting failed: " .. tostring(err))
		end
	end)
	Util.Log("Server ready.")
end)
