-- SPDX-License-Identifier: MIT
--[[
	Maps a summon to one naming category from the tag names on its entity.

	Engine-independent (input is a plain list of tag-name strings) so it is
	unit-tested off-game; the glue that reads the Tag component off a live summon is
	Server/Naming.lua (TagNamesOf). Classification is by creature-type tag (UNDEAD,
	BEAST, ... - the 14 D&D types); FIND_FAMILIAR takes priority over creature type.
]]

local Classifier = {}

local FAMILIAR_TAG = "FIND_FAMILIAR"

-- Tiebreak order for a creature carrying more than one type tag; generic Beast
-- and Humanoid sit last so a more specific type wins.
local TYPE_ORDER = {
	"Undead",
	"Fiend",
	"Celestial",
	"Fey",
	"Elemental",
	"Dragon",
	"Aberration",
	"Monstrosity",
	"Construct",
	"Ooze",
	"Plant",
	"Giant",
	"Beast",
	"Humanoid",
}

-- Toggle metadata for the config UI, in display order.
Classifier.CATEGORIES = {
	{ key = "Familiar" },
	{ key = "Beast" },
	{ key = "Undead" },
	{ key = "Elemental" },
	{ key = "Fey" },
	{ key = "Fiend" },
	{ key = "Celestial" },
	{ key = "Construct" },
	{ key = "Dragon" },
	{ key = "Giant" },
	{ key = "Humanoid" },
	{ key = "Monstrosity" },
	{ key = "Ooze" },
	{ key = "Plant" },
	{ key = "Aberration" },
	{ key = "Untagged" },
}

-- The master toggle: when on, every summon is eligible regardless of type.
Classifier.MASTER_KEY = "NameEverySummon"

--- The settings key for a category (e.g. "Familiar" -> "NameFamiliar").
---@param category string
---@return string
function Classifier.SettingKey(category)
	return "Name" .. category
end

--- The upper-cased set of an entity's tag names, for presence lookups.
---@param tagNames string[]
---@return table<string, boolean>
local function tagSet(tagNames)
	local present = {}
	for _, name in ipairs(tagNames or {}) do
		present[tostring(name):upper()] = true
	end
	return present
end

--- The highest-priority creature-type category present, or nil if none.
---@param present table<string, boolean>
---@return string|nil
local function creatureType(present)
	for _, category in ipairs(TYPE_ORDER) do
		if present[category:upper()] then
			return category
		end
	end
	return nil
end

--- Classify a summon from the tag names on its entity. Familiars take priority
--- over their creature type, matching the per-type filter.
---@param tagNames string[]
---@return string category  one of the Classifier.CATEGORIES keys
function Classifier.Classify(tagNames)
	local present = tagSet(tagNames)
	if present[FAMILIAR_TAG] then
		return "Familiar"
	end
	return creatureType(present) or "Untagged"
end

--- A language-neutral description of a summon's type for the saved-name list.
--- Type and familiar status are independent; the client localises and composes
--- these into a label ("Fiend, Familiar", "Beast", "Familiar", "Other"). Kept pure
--- (no engine calls) so the viewing player's language, not the server's, applies.
---@class NysTypeDescription
---@field Creature string|nil  a TYPE_ORDER key, or nil when no creature-type tag
---@field Familiar boolean
---@param tagNames string[]
---@return NysTypeDescription
function Classifier.DescribeKey(tagNames)
	local present = tagSet(tagNames)
	return {
		Creature = creatureType(present),
		Familiar = present[FAMILIAR_TAG] == true,
	}
end

--- Whether a summon of these tags may be prompted, given the current settings.
---@param tagNames string[]
---@param settings table
---@return boolean
function Classifier.IsEligible(tagNames, settings)
	if settings[Classifier.MASTER_KEY] then
		return true
	end
	return settings[Classifier.SettingKey(Classifier.Classify(tagNames))] == true
end

--- Default enabled state for every category + master setting key. Only
--- familiars are named by default; the master is off.
---@return table<string, boolean>
function Classifier.DefaultSettings()
	local out = { [Classifier.MASTER_KEY] = false }
	for _, cat in ipairs(Classifier.CATEGORIES) do
		out[Classifier.SettingKey(cat.key)] = cat.key == "Familiar"
	end
	return out
end

return Classifier
