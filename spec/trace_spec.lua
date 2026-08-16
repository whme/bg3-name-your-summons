-- SPDX-License-Identifier: MIT
local lu = require("luaunit")
local Trace = Ext.Require("Shared/Trace.lua")

TestSanitize = {}

function TestSanitize:testScalarsPassThrough()
	lu.assertEquals(Trace.Sanitize(nil), nil)
	lu.assertEquals(Trace.Sanitize(true), true)
	lu.assertEquals(Trace.Sanitize(42), 42)
	lu.assertEquals(Trace.Sanitize("name"), "name")
end

function TestSanitize:testFunctionBecomesTaggedString()
	local out = Trace.Sanitize(print)
	lu.assertStrContains(out, "<function: ")
end

function TestSanitize:testPlainTableCopiedDeeply()
	local out = Trace.Sanitize({ Key = "a|b", Nested = { N = 1 } })
	lu.assertEquals(out, { Key = "a|b", Nested = { N = 1 } })
end

function TestSanitize:testNonStringKeysStringified()
	local key = {}
	local out = Trace.Sanitize({ [key] = "v" })
	lu.assertEquals(out[tostring(key)], "v")
end

function TestSanitize:testCycleDoesNotRecurseForever()
	local a = {}
	a.self = a
	local out = Trace.Sanitize(a)
	lu.assertEquals(out.self, "<table: cycle>")
end

function TestSanitize:testSharedSubtableIsNotAFalseCycle()
	local shared = { X = 1 }
	local out = Trace.Sanitize({ A = shared, B = shared })
	lu.assertEquals(out.A, { X = 1 })
	lu.assertEquals(out.B, { X = 1 })
end

function TestSanitize:testDepthCapped()
	local deep = {}
	local node = deep
	for _ = 1, Trace.MAX_DEPTH + 2 do
		node.next = {}
		node = node.next
	end
	local out = Trace.Sanitize(deep)
	for _ = 1, Trace.MAX_DEPTH do
		out = out.next
	end
	lu.assertEquals(out, "<table: depth capped>")
end

function TestSanitize:testEntriesCapped()
	local wide = {}
	for i = 1, Trace.MAX_TABLE_ENTRIES + 10 do
		wide["k" .. i] = i
	end
	local out = Trace.Sanitize(wide)
	local n = 0
	for _ in pairs(out) do
		n = n + 1
	end
	-- The cap plus the "..." marker.
	lu.assertEquals(n, Trace.MAX_TABLE_ENTRIES + 1)
	lu.assertEquals(out["..."], "entries capped")
end

TestEntryFor = {}

function TestEntryFor:testShapeAndSanitisedData()
	local entry = Trace.EntryFor("lifecycle", "panel open", { Id = 1, Node = print })
	lu.assertEquals(entry.state, "client")
	lu.assertEquals(entry.cat, "lifecycle")
	lu.assertEquals(entry.msg, "panel open")
	lu.assertEquals(entry.data.Id, 1)
	lu.assertStrContains(entry.data.Node, "<function: ")
	lu.assertNotNil(entry.t)
	lu.assertNotNil(entry.clock)
end

function TestEntryFor:testNoDataFieldWhenNil()
	lu.assertNil(Trace.EntryFor("cat", "msg").data)
end

TestLogging = {}

function TestLogging:setUp()
	self.savedCalls = {}
	self.origSaveFile = Ext.IO.SaveFile
	Ext.IO.SaveFile = function(path, contents)
		table.insert(self.savedCalls, { path = path, contents = contents })
		return true
	end
	self.wasEnabled = Trace.Enabled()
	Trace.Register()
end

function TestLogging:tearDown()
	Ext.IO.SaveFile = self.origSaveFile
	Trace.SetEnabled(self.wasEnabled)
end

function TestLogging:testDisabledLogWritesNothing()
	Trace.SetEnabled(false)
	self.savedCalls = {}
	Trace.Log("cat", "msg", { X = 1 })
	lu.assertEquals(#self.savedCalls, 0)
end

function TestLogging:testEnabledLogFlushesEveryLine()
	Trace.SetEnabled(true)
	self.savedCalls = {}
	Trace.Log("cat", "one")
	Trace.Log("cat", "two")
	lu.assertEquals(#self.savedCalls, 2)
	lu.assertEquals(self.savedCalls[1].path, "nys-trace-client.jsonl")
	-- Header plus both lines, one per row, trailing newline.
	local _, rows = self.savedCalls[2].contents:gsub("\n", "")
	lu.assertEquals(rows, 3)
end

function TestLogging:testLogNeverThrowsOnHostileData()
	Trace.SetEnabled(true)
	local cyclic = {}
	cyclic.self = cyclic
	lu.assertTrue(pcall(Trace.Log, "cat", "msg", { Fn = print, Cycle = cyclic, Co = coroutine.create(function() end) }))
end

function TestLogging:testLogNeverThrowsOnThrowingKeyTostring()
	Trace.SetEnabled(true)
	local badKey = setmetatable({}, {
		__tostring = function()
			error("boom")
		end,
	})
	lu.assertTrue(pcall(Trace.Log, "cat", "msg", { [badKey] = "v" }))
end
