--[[
    Shared net channels. Loaded by BOTH BootstrapServer.lua and BootstrapClient.lua
    so that the same channel names exist in both Lua states.
]]

local Channels = {}

-- Server -> Client: "please ask the player to name this summon"
Channels.AskName = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_AskName")

-- Client -> Server: "the player typed this name"
Channels.SubmitName = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SubmitName")

-- Client -> Server (request/reply): "give me the full list of saved names"
Channels.ListNames = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ListNames")

-- Client -> Server: "forget this saved name"
Channels.ForgetName = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ForgetName")

-- Server -> All Clients: the text behind a localisation handle, for remote peers
-- whose separate string table has never seen a handle the host minted.
Channels.ApplyName = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ApplyName")

-- Server -> All Clients: every saved name's handle in bulk, on session load.
Channels.SeedLoca = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SeedLoca")

return Channels
