-- SPDX-License-Identifier: MIT
-- Guards the localisation handle table: every key resolvable, handles unique, the
-- English fallback wired, and the Lua-side atoms in step with SummonClassifier.

local lu = require("luaunit")

local LocaKeys = Ext.Require("Shared/LocaKeys.lua")
local Classifier = Ext.Require("Shared/SummonClassifier.lua")

TestLocaKeys = {}

function TestLocaKeys:testEveryEntryHasHandleAndFallback()
	for key, entry in pairs(LocaKeys.Strings) do
		lu.assertEquals(type(entry.handle), "string", key .. " handle")
		lu.assertEquals(entry.handle:sub(1, 1), "h", key .. " handle prefix")
		lu.assertTrue(#entry.handle > 1, key .. " handle length")
		lu.assertEquals(type(entry.en), "string", key .. " en")
		lu.assertTrue(#entry.en > 0, key .. " en non-empty")
	end
end

function TestLocaKeys:testHandlesAreUnique()
	local seen = {}
	for key, entry in pairs(LocaKeys.Strings) do
		lu.assertNil(seen[entry.handle], "handle collision on " .. entry.handle .. " (" .. key .. ")")
		seen[entry.handle] = key
	end
end

function TestLocaKeys:testFallsBackToEnglishUnderStub()
	-- spec_helper's GetTranslatedString returns "", so L must fall back to en.
	lu.assertEquals(LocaKeys.L("Confirm"), "Confirm")
	lu.assertEquals(LocaKeys.L("TypeOther"), "Other")
end

function TestLocaKeys:testUnknownKeyReturnsTheKey()
	lu.assertEquals(LocaKeys.L("NoSuchKey"), "NoSuchKey")
end

function TestLocaKeys:testResolvesGameStringWhenPresent()
	local original = Ext.Loca.GetTranslatedString
	Ext.Loca.GetTranslatedString = function()
		return "translated!"
	end
	local ok, result = pcall(LocaKeys.L, "Confirm")
	Ext.Loca.GetTranslatedString = original
	lu.assertTrue(ok)
	lu.assertEquals(result, "translated!")
end

function TestLocaKeys:testCategoryLabelsMatchClassifier()
	for _, cat in ipairs(Classifier.CATEGORIES) do
		local entry = LocaKeys.Strings["Cat" .. cat.key]
		lu.assertNotNil(entry, "missing Cat" .. cat.key)
		lu.assertEquals(entry.en, cat.label, "Cat" .. cat.key .. " fallback out of step with CATEGORIES")
	end
end

function TestLocaKeys:testCreatureAtomForEveryCreatureCategory()
	-- Every creature-type category (all but Familiar/Untagged) needs a Creature<key>
	-- atom, since the client composes the row type label from DescribeKey.Creature.
	for _, cat in ipairs(Classifier.CATEGORIES) do
		if cat.key ~= "Familiar" and cat.key ~= "Untagged" then
			lu.assertNotNil(LocaKeys.Strings["Creature" .. cat.key], "missing Creature" .. cat.key)
		end
	end
end

function TestLocaKeys:testPlaceholderStringsCarryToken()
	for _, key in ipairs({ "UnknownSummoner", "TypeAndFamiliar", "RowSlot" }) do
		lu.assertStrContains(LocaKeys.Strings[key].en, "[1]", false, key .. " must keep the [1] token")
	end
end
