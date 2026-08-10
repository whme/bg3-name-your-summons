-- SPDX-License-Identifier: MIT
local lu = require("luaunit")
local Util = Ext.Require("Shared/Util.lua")

local UUID = "abcdef01-2345-6789-abcd-ef0123456789"

TestToUuid = {}

function TestToUuid:testBareUuidLowercased()
	lu.assertEquals(Util.ToUuid(UUID), UUID)
	lu.assertEquals(Util.ToUuid(string.upper(UUID)), UUID)
end

function TestToUuid:testExtractsFromPrefixedGuidstring()
	lu.assertEquals(Util.ToUuid("S_Wolf_" .. UUID), UUID)
end

function TestToUuid:testLowercasesStringWithoutUuid()
	lu.assertEquals(Util.ToUuid("HOST"), "host")
end

function TestToUuid:testNilForNonStrings()
	lu.assertNil(Util.ToUuid(nil))
	lu.assertNil(Util.ToUuid(42))
end

TestSanitise = {}

function TestSanitise:testEmptyForNonStrings()
	lu.assertEquals(Util.Sanitise(nil), "")
	lu.assertEquals(Util.Sanitise(123), "")
end

function TestSanitise:testTrimsAndCollapsesWhitespace()
	lu.assertEquals(Util.Sanitise("   Fluffy   the\tWolf  "), "Fluffy the Wolf")
end

function TestSanitise:testReplacesControlCharacters()
	lu.assertEquals(Util.Sanitise("a\0b"), "a b")
end

function TestSanitise:testClampsToMaxLength()
	local out = Util.Sanitise(string.rep("x", Util.MAX_NAME_LENGTH + 10))
	lu.assertEquals(#out, Util.MAX_NAME_LENGTH)

	local clamped = Util.Sanitise(string.rep("a", Util.MAX_NAME_LENGTH - 1) .. "  bb")
	lu.assertEquals(#clamped, Util.MAX_NAME_LENGTH - 1)
	lu.assertNil(string.match(clamped, "%s$"))
end

TestMakeKey = {}

function TestMakeKey:testJoinsNormalisedHalvesWithPipe()
	local owner = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	local tmpl = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	lu.assertEquals(Util.MakeKey(owner, "S_Wolf_" .. tmpl), owner .. "|" .. tmpl)
end

function TestMakeKey:testStableRegardlessOfTemplatePrefix()
	local owner = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	local tmpl = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
	lu.assertEquals(Util.MakeKey(owner, "S_Wolf_" .. tmpl), Util.MakeKey(owner, tmpl))
end

TestIsStorySummon = {}

local US_TEMPLATE = "27b9089b-9aef-44e9-aaf7-100e3e320823"

function TestIsStorySummon:testTrueForKnownStoryTemplate()
	lu.assertTrue(Util.IsStorySummon(US_TEMPLATE))
end

function TestIsStorySummon:testTrueRegardlessOfGuidstringPrefix()
	lu.assertTrue(Util.IsStorySummon("Intellect_Devourer_" .. string.upper(US_TEMPLATE)))
end

function TestIsStorySummon:testFalseForOrdinarySummon()
	lu.assertFalse(Util.IsStorySummon("S_Wolf_bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
end

function TestIsStorySummon:testFalseForNonStrings()
	lu.assertFalse(Util.IsStorySummon(nil))
	lu.assertFalse(Util.IsStorySummon(42))
end

TestIsRenameRequestValid = {}

function TestIsRenameRequestValid:testTrueForUuidAndName()
	lu.assertTrue(Util.IsRenameRequestValid({ SummonUuid = UUID, Name = "Fluffy" }))
end

function TestIsRenameRequestValid:testAcceptsPrefixedGuidstring()
	lu.assertTrue(Util.IsRenameRequestValid({ SummonUuid = "S_Wolf_" .. UUID, Name = "Rex" }))
end

function TestIsRenameRequestValid:testFalseForNonTable()
	lu.assertFalse(Util.IsRenameRequestValid(nil))
	lu.assertFalse(Util.IsRenameRequestValid("nope"))
end

function TestIsRenameRequestValid:testFalseForMissingOrMalformedUuid()
	lu.assertFalse(Util.IsRenameRequestValid({ Name = "Fluffy" }))
	lu.assertFalse(Util.IsRenameRequestValid({ SummonUuid = "not-a-uuid", Name = "Fluffy" }))
	lu.assertFalse(Util.IsRenameRequestValid({ SummonUuid = 42, Name = "Fluffy" }))
end

function TestIsRenameRequestValid:testFalseForEmptyName()
	lu.assertFalse(Util.IsRenameRequestValid({ SummonUuid = UUID, Name = "   " }))
	lu.assertFalse(Util.IsRenameRequestValid({ SummonUuid = UUID }))
end

TestIsNameVisible = {}

local HOST_USER = 65537
local P2_USER = 65538

function TestIsNameVisible:testOwnerControlledByViewerIsVisible()
	lu.assertTrue(Util.IsNameVisible(P2_USER, P2_USER, HOST_USER))
	lu.assertTrue(Util.IsNameVisible(HOST_USER, HOST_USER, HOST_USER))
end

function TestIsNameVisible:testOwnerControlledByAnotherPlayerIsHidden()
	lu.assertFalse(Util.IsNameVisible(P2_USER, HOST_USER, HOST_USER))
	lu.assertFalse(Util.IsNameVisible(HOST_USER, P2_USER, HOST_USER))
end

function TestIsNameVisible:testUnresolvedOwnerVisibleOnlyToHost()
	lu.assertTrue(Util.IsNameVisible(nil, HOST_USER, HOST_USER))
	lu.assertFalse(Util.IsNameVisible(nil, P2_USER, HOST_USER))
end

function TestIsNameVisible:testUnresolvedViewerShowsAll()
	lu.assertTrue(Util.IsNameVisible(P2_USER, nil, HOST_USER))
	lu.assertTrue(Util.IsNameVisible(nil, nil, HOST_USER))
end

TestHash32 = {}

-- Canonical FNV-1a 32-bit test vectors.
function TestHash32:testKnownVectors()
	lu.assertEquals(Util.Hash32(""), 0x811c9dc5)
	lu.assertEquals(Util.Hash32("a"), 0xe40c292c)
	lu.assertEquals(Util.Hash32("foobar"), 0xbf9cf968)
end

TestLocaHandleFor = {}

function TestLocaHandleFor:testDeterministic()
	lu.assertEquals(Util.LocaHandleFor("Fluffy"), Util.LocaHandleFor("Fluffy"))
end

function TestLocaHandleFor:testDiffersForDifferentText()
	lu.assertNotEquals(Util.LocaHandleFor("Fluffy"), Util.LocaHandleFor("Rex"))
end

function TestLocaHandleFor:testShape()
	lu.assertEquals(Util.LocaHandleFor(""), "hNameYourSummons811c9dc5")
	lu.assertStrMatches(Util.LocaHandleFor("x"), "hNameYourSummons%x%x%x%x%x%x%x%x")
end

TestAssignByOrder = {}

function TestAssignByOrder:testAssignsBySortedUuidOrder()
	local out = Util.AssignByOrder({ "ccc", "aaa", "bbb" }, { "Alpha", "Beta", "Gamma" })
	-- Sorted uuids: aaa, bbb, ccc -> Alpha, Beta, Gamma.
	lu.assertEquals(out, { aaa = "Alpha", bbb = "Beta", ccc = "Gamma" })
end

function TestAssignByOrder:testConvergesRegardlessOfInputOrder()
	local a = Util.AssignByOrder({ "aaa", "bbb" }, { "One", "Two" })
	local b = Util.AssignByOrder({ "bbb", "aaa" }, { "One", "Two" })
	lu.assertEquals(a, b)
end

function TestAssignByOrder:testLeavesExtraUuidsUnassigned()
	local out = Util.AssignByOrder({ "aaa", "bbb", "ccc" }, { "Only" })
	lu.assertEquals(out, { aaa = "Only" })
end

function TestAssignByOrder:testIgnoresExtraNames()
	local out = Util.AssignByOrder({ "aaa" }, { "One", "Two", "Three" })
	lu.assertEquals(out, { aaa = "One" })
end
