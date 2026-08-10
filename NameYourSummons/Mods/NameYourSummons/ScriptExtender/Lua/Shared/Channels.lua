-- SPDX-License-Identifier: MIT
--[[
    Shared net channels. Loaded by BOTH BootstrapServer.lua and BootstrapClient.lua
    so that the same channel names exist in both Lua states.
]]

local Channels = {}

-- Server -> Client: "please ask the player to name this summon"
Channels.AskName = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_AskName")

-- Client -> Server: "the player typed this name"
Channels.SubmitName = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SubmitName")

-- Server -> Client: "cancel the naming prompt for this key" - a sibling arrived
-- and revealed it to be a multi-summon we should not have asked about.
Channels.RetractPrompt = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_RetractPrompt")

-- Client -> Server (request/reply): "give me the full list of saved names"
Channels.ListNames = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ListNames")

-- Client -> Server: "forget this saved name"
Channels.ForgetName = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ForgetName")

-- Client -> Server: "change the text of this saved name"
Channels.RenameName = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_RenameName")

-- Client -> Server: "rename this specific live summon" (from a native UI control
-- that only knows the creature's uuid, not the storage key).
Channels.RenameSummon = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_RenameSummon")

-- Client -> Server (request/reply): "give me the always-skipped summons"
Channels.ListSkipped = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ListSkipped")

-- Client -> Server: "stop always-skipping this summon"
Channels.Unskip = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_Unskip")

-- Client -> Server (request/reply): "give me the summons skipped this session"
Channels.ListSessionSkipped = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ListSessionSkipped")

-- Client -> Server: "prompt me again this session for this summon"
Channels.UnskipSession = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_UnskipSession")

-- Client -> Server (request/reply): "give me the current settings"
Channels.GetSettings = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_GetSettings")

-- Client -> Server: "store these settings"
Channels.SetSettings = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SetSettings")

-- Server -> All Clients: the settings just changed, so a client can refresh anything it
-- caches locally (the story-summon rename gate in NativeRenameUI). Payload: the settings.
Channels.SettingsChanged = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SettingsChanged")

-- Server -> All Clients: the text behind a localisation handle, for remote peers
-- whose separate string table has never seen a handle the host minted.
Channels.ApplyName = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_ApplyName")

-- Server -> All Clients: every saved name's handle in bulk, on session load.
Channels.SeedLoca = Ext.Net.CreateChannel(ModuleUUID, "NameYourSummons_SeedLoca")

return Channels
