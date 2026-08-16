-- SPDX-License-Identifier: MIT
-- Guards the shipped .loca.xml tables and their agreement with LocaKeys. Unlike
-- locakeys_spec, which sees only the Lua table, this checks the XML the game
-- loads and the drift between the two - including duplicate contentuids, which
-- divine convert-loca silently accepts.
-- XAML inline handles are deliberately NOT asserted against our loca: the pages
-- also bind the game's own vanilla handles, indistinguishable from a typo offline.

local lu = require("luaunit")

local LocaKeys = Ext.Require("Shared/LocaKeys.lua")

-- Run from the repo root (spec/run.lua), so these are repo-relative.
local LOCA_DIR = "./NameYourSummons/Localization/"

-- Add a language here too, so its table gets the same parity/duplicate guarantees.
local LANGUAGES = {
	"Chinese",
	"English",
	"French",
	"German",
	"Italian",
	"Polish",
	"Russian",
	"Spanish",
}

local function readFile(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

--- Count each contentuid's occurrences in a .loca.xml body.
---@param content string
---@return table<string, integer>
local function countContentuids(content)
	local counts = {}
	for uid in content:gmatch('contentuid="([^"]+)"') do
		counts[uid] = (counts[uid] or 0) + 1
	end
	return counts
end

-- Parse each language once into a uid -> count map (count for the dup check, keys for parity).
local perLang = {}
for _, lang in ipairs(LANGUAGES) do
	local content = readFile(LOCA_DIR .. lang .. "/NameYourSummons.loca.xml")
	if content then
		perLang[lang] = countContentuids(content)
	end
end

TestLocaXml = {}

function TestLocaXml:testEveryDeclaredLanguageFilePresent()
	for _, lang in ipairs(LANGUAGES) do
		lu.assertNotNil(perLang[lang], "loca file missing for language " .. lang)
	end
end

function TestLocaXml:testEnglishTableIsPresentAndNonEmpty()
	lu.assertNotNil(perLang.English, "English loca table missing")
	lu.assertNotNil(next(perLang.English), "English loca table is empty")
end

function TestLocaXml:testNoDuplicateContentuidWithinAFile()
	for lang, counts in pairs(perLang) do
		for uid, count in pairs(counts) do
			lu.assertEquals(count, 1, ("duplicate contentuid %s in %s loca"):format(uid, lang))
		end
	end
end

function TestLocaXml:testAllLanguagesShareTheEnglishKeySet()
	lu.assertNotNil(perLang.English, "English loca table missing")
	local en = perLang.English
	for lang, counts in pairs(perLang) do
		for uid in pairs(en) do
			lu.assertNotNil(counts[uid], ("%s loca is missing contentuid %s"):format(lang, uid))
		end
		for uid in pairs(counts) do
			lu.assertNotNil(en[uid], ("%s loca has contentuid %s not present in English"):format(lang, uid))
		end
	end
end

function TestLocaXml:testEveryLocaKeysHandleIsTranslatedInEveryLanguage()
	for key, entry in pairs(LocaKeys.Strings) do
		for lang, counts in pairs(perLang) do
			lu.assertNotNil(
				counts[entry.handle],
				("LocaKeys '%s' handle %s has no entry in %s loca"):format(key, entry.handle, lang)
			)
		end
	end
end
