-- SPDX-License-Identifier: MIT
local lu = require("luaunit")
local Store = Ext.Require("Server/Store.lua")

-- Store reads and writes a single ModVariables table; back it with a plain Lua
-- table so we can assert on persistence semantics without the engine.
local backing
local function freshBacking()
	backing = {}
	Ext.Vars.GetModVariables = function()
		return backing
	end
end

TestStoreNames = {}

function TestStoreNames:setUp()
	freshBacking()
end

function TestStoreNames:testEmptyBeforeAnythingStored()
	lu.assertEquals(Store.All(), {})
	lu.assertNil(Store.Get("k"))
end

function TestStoreNames:testStoreAndRetrieve()
	Store.Set("owner|tmpl", "Fluffy")
	lu.assertEquals(Store.Get("owner|tmpl"), "Fluffy")
end

function TestStoreNames:testReassignsContainerSoModVarIsDirty()
	Store.Set("k", "Rex")
	-- Store.Set must replace the backing slot, not mutate a stale nested table,
	-- or the engine would not persist the change.
	lu.assertEquals(backing["SummonNames"]["k"], "Rex")
end

function TestStoreNames:testForget()
	Store.Set("k", "Rex")
	Store.Forget("k")
	lu.assertNil(Store.Get("k"))
end

TestStoreTypes = {}

function TestStoreTypes:setUp()
	freshBacking()
end

function TestStoreTypes:testEmptyBeforeAnythingStored()
	lu.assertEquals(Store.AllTypes(), {})
	lu.assertNil(Store.GetType("k"))
end

function TestStoreTypes:testStoreAndRetrieve()
	local token = { Creature = "Beast", Familiar = false }
	Store.SetType("owner|tmpl", token)
	lu.assertIs(Store.GetType("owner|tmpl"), token)
	lu.assertIs(backing["SummonTypes"]["owner|tmpl"], token)
end

function TestStoreTypes:testIdenticalTokenIsNoOp()
	-- DescribeKey mints a fresh table each call; equal fields must not rewrite the
	-- ModVar, so the originally stored table is retained (identity unchanged).
	local first = { Creature = "Fiend", Familiar = true }
	Store.SetType("k", first)
	Store.SetType("k", { Creature = "Fiend", Familiar = true })
	lu.assertIs(Store.GetType("k"), first)
end

function TestStoreTypes:testChangedTokenRewrites()
	Store.SetType("k", { Creature = "Fiend", Familiar = true })
	local second = { Creature = "Fiend", Familiar = false }
	Store.SetType("k", second)
	lu.assertIs(Store.GetType("k"), second)
end

TestStoreSettings = {}

function TestStoreSettings:setUp()
	freshBacking()
end

function TestStoreSettings:testDefaultsWhenUnset()
	local s = Store.Settings()
	lu.assertEquals(s.PromptOnSummon, true)
	lu.assertEquals(s.PromptForNamed, false)
	lu.assertEquals(s.ApplyToExisting, true)
	lu.assertEquals(s.PauseOnPrompt, false)
	lu.assertEquals(s.MultiSummonMode, "skip")
end

function TestStoreSettings:testHonoursStoredOverride()
	backing["Settings"] = { PromptOnSummon = false, PromptForNamed = true }
	local s = Store.Settings()
	lu.assertEquals(s.PromptOnSummon, false)
	lu.assertEquals(s.PromptForNamed, true)
	lu.assertEquals(s.ApplyToExisting, true)
end

function TestStoreSettings:testSetSettingPersistsWhitelistedKey()
	lu.assertTrue(Store.SetSetting("PromptForNamed", true))
	lu.assertEquals(backing["Settings"]["PromptForNamed"], true)
	lu.assertEquals(Store.Settings().PromptForNamed, true)
end

function TestStoreSettings:testSetPauseOnPromptPersists()
	lu.assertTrue(Store.SetSetting("PauseOnPrompt", true))
	lu.assertEquals(backing["Settings"]["PauseOnPrompt"], true)
	lu.assertEquals(Store.Settings().PauseOnPrompt, true)
end

function TestStoreSettings:testSetSettingRejectsUnknownKey()
	lu.assertFalse(Store.SetSetting("ApplyToExisting", false))
	lu.assertFalse(Store.SetSetting("Nonsense", true))
	lu.assertNil(backing["Settings"])
end

function TestStoreSettings:testSetSettingRejectsNonBoolean()
	lu.assertFalse(Store.SetSetting("PromptOnSummon", "yes"))
	lu.assertNil(backing["Settings"])
end

function TestStoreSettings:testSummonTypeDefaults()
	local s = Store.Settings()
	-- Only familiars are named out of the box.
	lu.assertEquals(s.NameFamiliar, true)
	lu.assertEquals(s.NameUndead, false)
	lu.assertEquals(s.NameElemental, false)
	lu.assertEquals(s.NameEverySummon, false)
end

function TestStoreSettings:testSetSummonTypePersists()
	lu.assertTrue(Store.SetSetting("NameUndead", true))
	lu.assertEquals(backing["Settings"]["NameUndead"], true)
	lu.assertEquals(Store.Settings().NameUndead, true)
end

function TestStoreSettings:testSetEverySummonMasterPersists()
	lu.assertTrue(Store.SetSetting("NameEverySummon", true))
	lu.assertEquals(Store.Settings().NameEverySummon, true)
end

function TestStoreSettings:testSetSettingAcceptsMultiSummonModeEnum()
	lu.assertTrue(Store.SetSetting("MultiSummonMode", "shared"))
	lu.assertEquals(Store.Settings().MultiSummonMode, "shared")
	lu.assertTrue(Store.SetSetting("MultiSummonMode", "unique"))
	lu.assertEquals(Store.Settings().MultiSummonMode, "unique")
end

function TestStoreSettings:testSetSettingRejectsUnknownMultiSummonMode()
	lu.assertFalse(Store.SetSetting("MultiSummonMode", "sometimes"))
	lu.assertFalse(Store.SetSetting("MultiSummonMode", true))
	lu.assertNil(backing["Settings"])
end

TestStoreUniqueSets = {}

function TestStoreUniqueSets:setUp()
	freshBacking()
end

function TestStoreUniqueSets:testAppendBuildsDenseArray()
	Store.AppendUnique("k", "Alpha")
	Store.AppendUnique("k", "Beta")
	lu.assertEquals(Store.Get("k"), { "Alpha", "Beta" })
end

function TestStoreUniqueSets:testAppendPromotesExistingString()
	Store.Set("k", "Alpha")
	Store.AppendUnique("k", "Beta")
	lu.assertEquals(Store.Get("k"), { "Alpha", "Beta" })
end

function TestStoreUniqueSets:testSetSlotOverwrites()
	Store.AppendUnique("k", "Alpha")
	Store.AppendUnique("k", "Beta")
	Store.SetSlot("k", 2, "Gamma")
	lu.assertEquals(Store.Get("k"), { "Alpha", "Gamma" })
end

function TestStoreUniqueSets:testSetSlotIgnoresOutOfRange()
	Store.AppendUnique("k", "Alpha")
	Store.SetSlot("k", 5, "Nope")
	lu.assertEquals(Store.Get("k"), { "Alpha" })
end

function TestStoreUniqueSets:testForgetSlotCompacts()
	Store.AppendUnique("k", "Alpha")
	Store.AppendUnique("k", "Beta")
	Store.AppendUnique("k", "Gamma")
	Store.ForgetSlot("k", 2)
	-- The array stays dense (1..N), never sparse, or it serialises as an object.
	lu.assertEquals(Store.Get("k"), { "Alpha", "Gamma" })
end

function TestStoreUniqueSets:testForgetLastSlotDropsKey()
	Store.AppendUnique("k", "Alpha")
	Store.ForgetSlot("k", 1)
	lu.assertNil(Store.Get("k"))
end

function TestStoreUniqueSets:testSetUniqueStoresDenseArray()
	Store.SetUnique("k", { "Alpha", "Beta", "Gamma" })
	lu.assertEquals(Store.Get("k"), { "Alpha", "Beta", "Gamma" })
end
