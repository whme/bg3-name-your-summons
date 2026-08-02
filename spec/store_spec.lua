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

TestStoreSettings = {}

function TestStoreSettings:setUp()
	freshBacking()
end

function TestStoreSettings:testDefaultsWhenUnset()
	local s = Store.Settings()
	lu.assertEquals(s.PromptOnSummon, true)
	lu.assertEquals(s.PromptForNamed, false)
	lu.assertEquals(s.ApplyToExisting, true)
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

function TestStoreSettings:testSetSettingRejectsUnknownKey()
	lu.assertFalse(Store.SetSetting("ApplyToExisting", false))
	lu.assertFalse(Store.SetSetting("Nonsense", true))
	lu.assertNil(backing["Settings"])
end

function TestStoreSettings:testSetSettingRejectsNonBoolean()
	lu.assertFalse(Store.SetSetting("PromptOnSummon", "yes"))
	lu.assertNil(backing["Settings"])
end
