-- SPDX-License-Identifier: MIT
--[[
    Client-side localisation handlers. Runtime loca added via UpdateTranslatedString
    is not persisted and does not replicate, so the server broadcasts each summon
    name's handle/text (ApplyName) and re-seeds the full set on load (SeedLoca); the
    client re-registers them locally so co-op peers resolve the correct names.
]]

local Channels = Ext.Require("Shared/Channels.lua")
local Writer = Ext.Require("Shared/NameWriter.lua")

local Loca = {}

function Loca.Register()
	Channels.ApplyName:SetHandler(function(data, _user)
		if type(data) ~= "table" then
			return
		end
		if type(data.Handle) ~= "string" or type(data.Text) ~= "string" then
			return
		end
		Writer.RegisterLoca(data.Handle, data.Text)
	end)

	Channels.SeedLoca:SetHandler(function(data, _user)
		if type(data) ~= "table" or type(data.Entries) ~= "table" then
			return
		end
		for handle, text in pairs(data.Entries) do
			if type(handle) == "string" and type(text) == "string" then
				Writer.RegisterLoca(handle, text)
			end
		end
	end)
end

return Loca
