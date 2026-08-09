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
	{ key = "Familiar", label = "Familiars (Find Familiar)" },
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

--- A short, human-readable label for a category, for the saved-name list. The
--- category key is already a single word; only the catch-all is reworded.
---@param category string
---@return string
function Classifier.TypeLabel(category)
	if category == "Untagged" then
		return "Other"
	end
	return category
end

--- Classify a summon from the tag names on its entity.
---@param tagNames string[]
---@return string category  one of the Classifier.CATEGORIES keys
function Classifier.Classify(tagNames)
	local present = {}
	for _, name in ipairs(tagNames or {}) do
		present[tostring(name):upper()] = true
	end

	if present[FAMILIAR_TAG] then
		return "Familiar"
	end
	for _, category in ipairs(TYPE_ORDER) do
		if present[category:upper()] then
			return category
		end
	end
	return "Untagged"
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
