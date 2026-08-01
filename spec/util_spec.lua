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
