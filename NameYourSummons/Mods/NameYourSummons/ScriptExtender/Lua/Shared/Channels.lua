-- SPDX-License-Identifier: MIT
--[[
    Shared net channels. Loaded by BOTH BootstrapServer.lua and BootstrapClient.lua
    so that the same channel names exist in both Lua states. Each is wrapped in a
    `traced` proxy that logs every direction of traffic to Shared/Trace.lua while
    forwarding to the real SE channel unchanged.
]]

local Trace = Ext.Require("Shared/Trace.lua")

local Channels = {}

--- Wrap an SE net channel so every direction of traffic lands in the trace file.
---@param name string
---@param channel any
---@return table
local function traced(name, channel)
	local proxy = {}

	function proxy.SetHandler(_self, fn)
		return channel:SetHandler(function(data, user)
			Trace.Log("channel", "recv " .. name, { User = user, Data = data })
			return fn(data, user)
		end)
	end

	function proxy.SetRequestHandler(_self, fn)
		return channel:SetRequestHandler(function(data, user)
			Trace.Log("channel", "request-in " .. name, { User = user, Data = data })
			local reply = fn(data, user)
			Trace.Log("channel", "reply-out " .. name, { User = user, Data = reply })
			return reply
		end)
	end

	function proxy.SendToServer(_self, data)
		Trace.Log("channel", "send-to-server " .. name, { Data = data })
		return channel:SendToServer(data)
	end

	function proxy.SendToClient(_self, data, user)
		Trace.Log("channel", "send-to-client " .. name, { User = tostring(user), Data = data })
		return channel:SendToClient(data, user)
	end

	function proxy.Broadcast(_self, data)
		Trace.Log("channel", "broadcast " .. name, { Data = data })
		return channel:Broadcast(data)
	end

	function proxy.RequestToServer(_self, data, callback)
		Trace.Log("channel", "request-to-server " .. name, { Data = data })
		return channel:RequestToServer(data, function(reply)
			Trace.Log("channel", "reply-from-server " .. name, { Data = reply })
			return callback(reply)
		end)
	end

	return proxy
end

-- Server -> Client: "ask the player to name this summon". Payload's ViewportChar
-- (the summoner's controlled character) picks the split-screen viewport to open in.
Channels.AskName = traced("AskName", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_AskName"))

-- Client -> Server: "the player typed this name"
Channels.SubmitName = traced("SubmitName", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SubmitName"))

-- Server -> Client: "cancel the naming prompt for this key" - a sibling arrived
-- and revealed it to be a multi-summon we should not have asked about.
Channels.RetractPrompt = traced("RetractPrompt", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_RetractPrompt"))

-- Client -> Server (request/reply): "give me the saved names visible to this player".
-- Payload's ViewerCharacter scopes the reply to summons that player currently controls.
Channels.ListNames = traced("ListNames", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ListNames"))

-- Client -> Server: "forget this saved name"
Channels.ForgetName = traced("ForgetName", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ForgetName"))

-- Client -> Server: "change the text of this saved name"
Channels.RenameName = traced("RenameName", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_RenameName"))

-- Client -> Server: "rename this specific live summon" (from a native UI control
-- that only knows the creature's uuid, not the storage key).
Channels.RenameSummon = traced("RenameSummon", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_RenameSummon"))

-- Client -> Server (request/reply): "does the viewing player own this summon?" ViewerCharacter is
-- the viewport's controlled character; reply is { Owned = bool }.
Channels.QueryOwnership = traced("QueryOwnership", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_QueryOwnership"))

-- Client -> Server (request/reply): "give me the current settings"
Channels.GetSettings = traced("GetSettings", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_GetSettings"))

-- Client -> Server: "store these settings"
Channels.SetSettings = traced("SetSettings", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SetSettings"))

-- Server -> All Clients: the settings changed, so a client refreshes anything it caches
-- locally (the story-summon rename gate in NativeRenameUI). Payload: the settings.
Channels.SettingsChanged =
	traced("SettingsChanged", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SettingsChanged"))

-- Server -> All Clients: the text behind a localisation handle, for remote peers
-- whose separate string table has never seen a handle the host minted.
Channels.ApplyName = traced("ApplyName", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ApplyName"))

-- Server -> All Clients: a live summon was renamed, so the client showing it can repaint
-- its Examine field for a rename it did not type itself. Payload: { SummonUuid, Name }.
Channels.SummonRenamed = traced("SummonRenamed", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SummonRenamed"))

-- Server -> All Clients: every saved name's handle in bulk, on session load.
Channels.SeedLoca = traced("SeedLoca", Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SeedLoca"))

return Channels
