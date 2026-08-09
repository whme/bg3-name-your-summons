-- SPDX-License-Identifier: MIT
local lu = require("luaunit")
local Classifier = Ext.Require("Shared/SummonClassifier.lua")

TestClassifierClassify = {}

function TestClassifierClassify:testFamiliarWinsOverCreatureType()
	-- A Find Familiar dog is BEAST+FIND_FAMILIAR; the ghost dog is UNDEAD+FIND_FAMILIAR.
	lu.assertEquals(Classifier.Classify({ "BEAST", "FIND_FAMILIAR", "SUMMON" }), "Familiar")
	lu.assertEquals(Classifier.Classify({ "UNDEAD", "FIND_FAMILIAR" }), "Familiar")
	lu.assertEquals(Classifier.Classify({ "FIEND", "FIND_FAMILIAR" }), "Familiar")
end

function TestClassifierClassify:testCreatureTypes()
	lu.assertEquals(Classifier.Classify({ "UNDEAD", "MONSTER" }), "Undead")
	lu.assertEquals(Classifier.Classify({ "BEAST" }), "Beast")
	lu.assertEquals(Classifier.Classify({ "ELEMENTAL", "ELEMENTAL_EARTH" }), "Elemental")
	lu.assertEquals(Classifier.Classify({ "FEY" }), "Fey")
	lu.assertEquals(Classifier.Classify({ "FIEND", "DEVIL" }), "Fiend")
end

function TestClassifierClassify:testCaseInsensitive()
	lu.assertEquals(Classifier.Classify({ "undead" }), "Undead")
end

function TestClassifierClassify:testUntaggedWhenNoKnownType()
	lu.assertEquals(Classifier.Classify({ "SUMMON", "MONSTER" }), "Untagged")
	lu.assertEquals(Classifier.Classify({}), "Untagged")
	lu.assertEquals(Classifier.Classify(nil), "Untagged")
end

function TestClassifierClassify:testMoreSpecificTypeWinsOverBeast()
	-- Beast is a low-priority tiebreak; a summon carrying both keeps the specific one.
	lu.assertEquals(Classifier.Classify({ "BEAST", "UNDEAD" }), "Undead")
end

TestClassifierEligible = {}

function TestClassifierEligible:testMasterEnablesEverything()
	local settings = { NameEverySummon = true, NameFamiliar = false }
	lu.assertTrue(Classifier.IsEligible({ "UNDEAD" }, settings))
	lu.assertTrue(Classifier.IsEligible({}, settings))
end

function TestClassifierEligible:testPerTypeToggle()
	local settings = { NameEverySummon = false, NameFamiliar = true, NameUndead = false }
	lu.assertTrue(Classifier.IsEligible({ "BEAST", "FIND_FAMILIAR" }, settings))
	lu.assertFalse(Classifier.IsEligible({ "UNDEAD" }, settings))
end

function TestClassifierEligible:testUntaggedHonoursOwnToggle()
	lu.assertFalse(Classifier.IsEligible({ "SUMMON" }, { NameUntagged = false }))
	lu.assertTrue(Classifier.IsEligible({ "SUMMON" }, { NameUntagged = true }))
end

TestClassifierMetadata = {}

function TestClassifierMetadata:testDefaultSettingsOnlyFamiliar()
	local d = Classifier.DefaultSettings()
	lu.assertEquals(d.NameFamiliar, true)
	lu.assertEquals(d.NameUndead, false)
	lu.assertEquals(d.NameEverySummon, false)
end

function TestClassifierMetadata:testEveryCategoryHasADefault()
	local d = Classifier.DefaultSettings()
	for _, cat in ipairs(Classifier.CATEGORIES) do
		lu.assertNotNil(d[Classifier.SettingKey(cat.key)], "missing default for " .. cat.key)
	end
end

TestClassifierDescribe = {}

function TestClassifierDescribe:testCreatureTypeAndFamiliar()
	-- A Find Familiar imp is FIEND+FIND_FAMILIAR; both are shown.
	lu.assertEquals(Classifier.Describe({ "FIEND", "FIND_FAMILIAR" }), "Fiend, Familiar")
end

function TestClassifierDescribe:testFamiliarWithoutCreatureType()
	lu.assertEquals(Classifier.Describe({ "FIND_FAMILIAR" }), "Familiar")
end

function TestClassifierDescribe:testCreatureTypeOnly()
	lu.assertEquals(Classifier.Describe({ "BEAST" }), "Beast")
end

function TestClassifierDescribe:testOtherWhenUntagged()
	lu.assertEquals(Classifier.Describe({ "SUMMON" }), "Other")
	lu.assertEquals(Classifier.Describe({}), "Other")
end
