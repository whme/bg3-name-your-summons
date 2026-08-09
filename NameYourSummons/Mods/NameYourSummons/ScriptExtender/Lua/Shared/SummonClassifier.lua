--[[
	Maps a summon to one naming category from the tag names on its entity.

	Engine-independent on purpose (input is a plain list of tag-name strings, not
	an EntityHandle) so it is unit-tested off-game; the thin glue that reads the
	Tag component off a live summon lives in Server/Naming.lua (TagNamesOf).

	Classification is by the character's creature-type tag (UNDEAD, BEAST, FEY,
	... - the 14 D&D types, each a plain character tag). FIND_FAMILIAR takes
	priority over the creature type: a Find Familiar imp carries
	FIEND+FIND_FAMILIAR but the player thinks "familiar".
]]

local Classifier = {}

local FAMILIAR_TAG = "FIND_FAMILIAR"

-- Tiebreak order for the rare creature carrying more than one type tag; the
-- generic Beast and Humanoid sit last so a more specific type wins. Each
-- category's tag name is its key uppercased (Undead -> "UNDEAD").
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

-- Toggle metadata for the config UI, in display order. Familiar first, the
-- generic catch-all Untagged last.
Classifier.CATEGORIES = {
	{ key = "Familiar", label = "Familiars (all, whatever their creature type)" },
	{ key = "Beast", label = "Beasts / animals" },
	{ key = "Undead", label = "Undead" },
	{ key = "Elemental", label = "Elementals" },
	{ key = "Fey", label = "Fey" },
	{ key = "Fiend", label = "Fiends" },
	{ key = "Celestial", label = "Celestials" },
	{ key = "Construct", label = "Constructs" },
	{ key = "Dragon", label = "Dragons" },
	{ key = "Giant", label = "Giants" },
	{ key = "Humanoid", label = "Humanoids" },
	{ key = "Monstrosity", label = "Monstrosities" },
	{ key = "Ooze", label = "Oozes" },
	{ key = "Plant", label = "Plants" },
	{ key = "Aberration", label = "Aberrations" },
	{ key = "Untagged", label = "Other / untagged summons" },
}

-- The master toggle: when on, every summon is eligible regardless of type
-- (reproduces the pre-#14 behaviour).
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

--- A human-readable label of a summon's type for the saved-name list. Creature
--- type and familiar status are independent (an imp is a Fiend and a Familiar),
--- so both are shown: "Fiend, Familiar", "Beast", "Familiar", or "Other".
---@param tagNames string[]
---@return string
function Classifier.Describe(tagNames)
	local present = tagSet(tagNames)
	local category = creatureType(present)
	if category and present[FAMILIAR_TAG] then
		return category .. ", Familiar"
	end
	if present[FAMILIAR_TAG] then
		return "Familiar"
	end
	return category or "Other"
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
