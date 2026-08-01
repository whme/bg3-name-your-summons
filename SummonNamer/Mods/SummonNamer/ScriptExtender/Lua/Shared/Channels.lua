--[[
    Shared net channels. Loaded by BOTH BootstrapServer.lua and BootstrapClient.lua
    so that the same channel names exist in both Lua states.
]]

local Channels = {}

-- Server -> Client: "please ask the player to name this summon"
Channels.AskName = Ext.Net.CreateChannel(ModuleUUID, "SummonNamer_AskName")

-- Client -> Server: "the player typed this name"
Channels.SubmitName = Ext.Net.CreateChannel(ModuleUUID, "SummonNamer_SubmitName")

-- Client -> Server (request/reply): "give me the full list of saved names"
Channels.ListNames = Ext.Net.CreateChannel(ModuleUUID, "SummonNamer_ListNames")

-- Client -> Server: "forget this saved name"
Channels.ForgetName = Ext.Net.CreateChannel(ModuleUUID, "SummonNamer_ForgetName")

-- Server -> All Clients: fallback naming path. Clients must run
-- Ext.Loca.UpdateTranslatedString themselves, because the loca table is
-- per-Lua-state and the server's copy is not what the client UI renders.
Channels.SetLoca = Ext.Net.CreateChannel(ModuleUUID, "SummonNamer_SetLoca")

return Channels
