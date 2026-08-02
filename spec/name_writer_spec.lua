local lu = require("luaunit")
local Writer = Ext.Require("Shared/NameWriter.lua")

-- A fake DisplayName-bearing entity that records the engine calls Writer makes.
local function fakeEntity()
	local e = {
		DisplayName = { Name = { Handle = { Handle = "old", Version = 7 } } },
		replicated = {},
		marked = {},
	}
	function e:IsAlive()
		return true
	end
	function e:Replicate(component)
		table.insert(self.replicated, component)
	end
	function e:MarkChanged(component)
		table.insert(self.marked, component)
	end
	return e
end

TestRegisterLoca = {}

function TestRegisterLoca:testTrueWhenEngineAccepts()
	Ext.Loca.UpdateTranslatedString = function()
		return true
	end
	lu.assertEquals(Writer.RegisterLoca("hHandle", "Fluffy"), true)
end

function TestRegisterLoca:testFalseWhenEngineRejects()
	Ext.Loca.UpdateTranslatedString = function()
		return false
	end
	lu.assertEquals(Writer.RegisterLoca("hHandle", "Fluffy"), false)
end

function TestRegisterLoca:testFalseWhenEngineErrors()
	Ext.Loca.UpdateTranslatedString = function()
		error("boom")
	end
	lu.assertEquals(Writer.RegisterLoca("hHandle", "Fluffy"), false)
end

TestSetDisplayName = {}

function TestSetDisplayName:testPointsHandleAndWritesVersion()
	local e = fakeEntity()
	lu.assertEquals(Writer.SetDisplayName(e, "hHandle", 0, false), true)
	lu.assertEquals(e.DisplayName.Name.Handle.Handle, "hHandle")
	lu.assertEquals(e.DisplayName.Name.Handle.Version, 0)
end

function TestSetDisplayName:testWritesNonZeroVersion()
	local e = fakeEntity()
	Writer.SetDisplayName(e, "hOriginal", 3, false)
	lu.assertEquals(e.DisplayName.Name.Handle.Version, 3)
end

function TestSetDisplayName:testReplicatesOnlyWhenAsked()
	local server = fakeEntity()
	Writer.SetDisplayName(server, "hHandle", 0, true)
	lu.assertEquals(server.replicated, { "DisplayName" })

	local client = fakeEntity()
	Writer.SetDisplayName(client, "hHandle", 0, false)
	lu.assertEquals(client.replicated, {})
end

function TestSetDisplayName:testAlwaysMarksChanged()
	local e = fakeEntity()
	Writer.SetDisplayName(e, "hHandle", 0, false)
	lu.assertEquals(e.marked, { "DisplayName" })
end

function TestSetDisplayName:testFailsWhenComponentMissing()
	local ok, err = Writer.SetDisplayName({ DisplayName = nil }, "h", 0, false)
	lu.assertEquals(ok, false)
	lu.assertEquals(err, "no DisplayName component")
end

function TestSetDisplayName:testFailsWhenNameMissing()
	local ok, err = Writer.SetDisplayName({ DisplayName = { Name = nil } }, "h", 0, false)
	lu.assertEquals(ok, false)
	lu.assertEquals(err, "no Name")
end

TestResolve = {}

function TestResolve:testNilRef()
	lu.assertNil(Writer.Resolve(nil))
end

function TestResolve:testLiveEntityReturnedUnchanged()
	local e = fakeEntity()
	lu.assertEquals(Writer.Resolve(e), e)
end

function TestResolve:testDeadEntityReturnsNil()
	local e = fakeEntity()
	function e:IsAlive()
		return false
	end
	lu.assertNil(Writer.Resolve(e))
end
