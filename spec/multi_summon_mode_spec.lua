local lu = require("luaunit")
local MultiMode = Ext.Require("Shared/MultiSummonMode.lua")

TestMultiSummonMode = {}

function TestMultiSummonMode:testModesAndLabelsAlign()
	lu.assertEquals(#MultiMode.MODES, #MultiMode.LABELS)
	lu.assertEquals(MultiMode.MODES, { "skip", "shared", "unique" })
end

function TestMultiSummonMode:testIndexOfKnownValues()
	lu.assertEquals(MultiMode.IndexOf("skip"), 0)
	lu.assertEquals(MultiMode.IndexOf("shared"), 1)
	lu.assertEquals(MultiMode.IndexOf("unique"), 2)
end

function TestMultiSummonMode:testIndexOfUnknownDefaultsToZero()
	lu.assertEquals(MultiMode.IndexOf(nil), 0)
	lu.assertEquals(MultiMode.IndexOf("nonsense"), 0)
	lu.assertEquals(MultiMode.IndexOf(42), 0)
end

function TestMultiSummonMode:testValueAtKnownIndices()
	lu.assertEquals(MultiMode.ValueAt(0), "skip")
	lu.assertEquals(MultiMode.ValueAt(1), "shared")
	lu.assertEquals(MultiMode.ValueAt(2), "unique")
end

function TestMultiSummonMode:testValueAtOutOfRangeDefaultsToSkip()
	lu.assertEquals(MultiMode.ValueAt(nil), "skip")
	lu.assertEquals(MultiMode.ValueAt(3), "skip")
	lu.assertEquals(MultiMode.ValueAt(-1), "skip")
end

function TestMultiSummonMode:testRoundTrip()
	for i, mode in ipairs(MultiMode.MODES) do
		lu.assertEquals(MultiMode.ValueAt(MultiMode.IndexOf(mode)), mode)
		lu.assertEquals(MultiMode.IndexOf(MultiMode.ValueAt(i - 1)), i - 1)
	end
end
