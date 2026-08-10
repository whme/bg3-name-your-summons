-- SPDX-License-Identifier: MIT
--[[
	The Lua-side source of truth for UI localisation. Each entry pairs a fixed
	.loca handle with its English fallback. The handles here MUST match, verbatim,
	the contentuids in Localization/<Language>/NameYourSummons.loca.xml and the inline
	handles in GUI/Pages/Examine.xaml + Examine_c.xaml.

	Script Extender has no language API, so the GAME resolves a handle to the active
	language; the English text here is only the fallback for when the loca table has
	not loaded (or a language ships no translation for a handle). XAML resolves the
	same handles via TranslatedStringConverter; Lua reads them with L(key).

	Strings with a [1] token are composed in Lua (gsub), NOT by the game's
	parameterized converter.
]]

local LocaKeys = {}

---@class NysLocaEntry
---@field handle string
---@field en string

---@type table<string, NysLocaEntry>
LocaKeys.Strings = {
	-- Rename bar
	Confirm = { handle = "h9e870cd5g805bg467dgb6b6gb12d4c9d8028", en = "Confirm" },
	Skip = { handle = "h2e1c64c5g940ag4327g9c16g82dfb467d903", en = "Skip" },
	-- Settings panel chrome
	PanelTitle = { handle = "hf22514a5g1077g4b9eg8b09g329d3d6cc37f", en = "Name Your Summons" },
	SectionPrompt = { handle = "h0397207dg538dg4a9fga9b9ga9532038ca92", en = "Prompt" },
	SectionSavedNames = { handle = "h6700b693g1816g4bd5gb6dcg7edebe82a937", en = "Saved names" },
	TypesToggle = { handle = "heee8452fg89d7g47dfgb6dfg67e334190cdf", en = "Summon types to name..." },
	Refresh = { handle = "hcdcbe581g0a56g4bf8g89fcgbea014f6d95a", en = "Refresh" },
	-- Checkboxes
	AskNew = { handle = "h0ca636b6gfbc1g43e8gaa90ga7d4c161319c", en = "Ask me to name new summons" },
	ReaskNamed = {
		handle = "h97b2a47agdec6g413fg9a9dgfdf7232a441c",
		en = "Also re-ask for summons I have already named",
	},
	PauseOnPrompt = {
		handle = "hd5911703g4eefg4918ga4b4g9e5c6f7910cf",
		en = "Pause the game (turn-based mode) while I name a summon",
	},
	AllowStory = {
		handle = "h093552b9gd8d8g48e6gb4afg4f958d58c0e0",
		en = "Allow renaming story-bound summons (e.g. 'Us')",
	},
	EverySummon = {
		handle = "h1001de43g7420g49dcgb75eg897f553d3061",
		en = "Every summon (ignore the type filter below)",
	},
	-- Descriptions
	TypesHelp = {
		handle = "ha1d27f83g8cafg4f0ag9ac0g0207d25296dd",
		en = "Which summons to prompt for, by the creature type read from its tags. Familiars count as 'Familiars' whatever their type, so the creature types below apply to non-familiar summons only.",
	},
	MultiHelp = {
		handle = "h5637f68dg2990g4632gbe15gc9c95288184e",
		en = "When one spell summons several creatures at once:",
	},
	-- Empty state
	NoSavedNames = { handle = "hf5a8ed82g5228g4af8g9678g4fe7a22e38a2", en = "No saved names yet." },
	-- Multi-summon modes
	ModeSkip = { handle = "ha7a476a3g0aeeg4ec6g9171gee80d2f7934f", en = "Do not name them" },
	ModeShared = { handle = "h1b66496bgf669g4495g92d4gac7984e3018f", en = "Share one name" },
	ModeUnique = { handle = "hde012cb1gaf00g4898gae58gb1ac51fefe21", en = "Name each individually" },
	-- Saved-name row atoms (Lua-composed; [1] is substituted in Lua)
	ForgetLabel = { handle = "h9c0401d0g357bg4656g89b8g94088b9d8146", en = "Forget" },
	UndoLabel = { handle = "h2801322fg6396g48e6g98a1g0d8ea9fece94", en = "Undo" },
	UnknownSummoner = { handle = "h4b093a8ag9906g4482g8ba5g8c9a5663050f", en = "Unknown summoner ([1])" },
	SummonFallback = { handle = "h2d7459c4g1c1dg45a9g8468g06b6842ae32e", en = "Summon" },
	RowSlot = { handle = "he0fa7c66gd744g4d05ga9afg12d8560804b5", en = "#[1]" },
	-- Composed type label (from SummonClassifier.DescribeKey)
	TypeAndFamiliar = { handle = "hfb1e5302gd90eg4ab5g8a87g212cbd9f8419", en = "[1], Familiar" },
	TypeFamiliar = { handle = "hd58d85cdg9711g497agae17ga5b2ad541843", en = "Familiar" },
	TypeOther = { handle = "h9d5e9597ga02ag4bdagb90dg98d071321320", en = "Other" },
	-- Per-creature-type filter labels (SummonClassifier.CATEGORIES, keyed Cat<key>)
	CatFamiliar = {
		handle = "h2661453cg97ebg45d7ga203gcb7b912f0297",
		en = "Familiars (all, whatever their creature type)",
	},
	CatBeast = { handle = "hcbc4a509g2a96g40a5gb947gac194c86aea9", en = "Beasts / animals" },
	CatUndead = { handle = "h525725b7g11c3g446bgb7f3g9e4093b9372f", en = "Undead" },
	CatElemental = { handle = "h1a33fffdgedbbg426fgba17g20636c273cc1", en = "Elementals" },
	CatFey = { handle = "h02eaf7e8g99cbg4946gb851g5756ccaea9a0", en = "Fey" },
	CatFiend = { handle = "hfef6a04cgf234g440fgb055g3d11cf4769dc", en = "Fiends" },
	CatCelestial = { handle = "h5b550b28g829eg493eg9f23g308ff696e219", en = "Celestials" },
	CatConstruct = { handle = "h7b2cd3f0g838dg415eg9cc0g230ded7bf5bc", en = "Constructs" },
	CatDragon = { handle = "hfd3868d7ga271g4d78gb1fag0c7e5f10894b", en = "Dragons" },
	CatGiant = { handle = "h618b5b57g0caag463ag8319g02481c164f93", en = "Giants" },
	CatHumanoid = { handle = "h5754841fg25c2g44c1g9e72ge65d16be1ea4", en = "Humanoids" },
	CatMonstrosity = { handle = "ha8c79924gf8deg4c28gaffagd05b68a0d8b1", en = "Monstrosities" },
	CatOoze = { handle = "hcf132aa6g33a8g4069ga311gd69b6a89b7c2", en = "Oozes" },
	CatPlant = { handle = "hbf52e12eg09b3g4f3cgb838g812c2ea86e64", en = "Plants" },
	CatAberration = { handle = "h9b7c9011gd422g4ce3g918eg383be079ec1b", en = "Aberrations" },
	CatUntagged = { handle = "hdd1091a0gc91bg4c2egb504gc101c5d2f11a", en = "Other / untagged summons" },
	-- Creature-type atoms used to compose a type label (keyed Creature<TypeOrder key>)
	CreatureUndead = { handle = "h99ab8f35g3456g4f6ag81fdg6607d7b697a3", en = "Undead" },
	CreatureFiend = { handle = "hb10beeafgca4ag433fga60dg04a490a80c8d", en = "Fiend" },
	CreatureCelestial = { handle = "hd6e0be15g2879g47f5gb4cagf2e7081c5523", en = "Celestial" },
	CreatureFey = { handle = "h7304e75ag96bdg49d1g9b92g38d5525528bc", en = "Fey" },
	CreatureElemental = { handle = "h9b31492egd90fg4e39g8d5dg3f67a14e78d7", en = "Elemental" },
	CreatureDragon = { handle = "h51a89768g1f65g48b2ga662gbf2a8b906a65", en = "Dragon" },
	CreatureAberration = { handle = "h6f1d5bc0gd568g4795g81e8g35505ac3097c", en = "Aberration" },
	CreatureMonstrosity = { handle = "h11ae9306g1833g4412g918dg4dae0f1c86e2", en = "Monstrosity" },
	CreatureConstruct = { handle = "h312baa53gca58g4427g939agf578b071ddd3", en = "Construct" },
	CreatureOoze = { handle = "h578d1ef6ga2bbg47e6g8345ga9118513ab95", en = "Ooze" },
	CreaturePlant = { handle = "h82ca6104ged46g41edgb1aag013ba69f8108", en = "Plant" },
	CreatureGiant = { handle = "h153d1e87g6ba4g4f35ga8b2g79d38fa35980", en = "Giant" },
	CreatureBeast = { handle = "h6e21bfe4g3c09g4493gb152gd454dfc25951", en = "Beast" },
	CreatureHumanoid = { handle = "hfb760cf5g34adg4df3g8b79g43e533abb6dd", en = "Humanoid" },
}

--- Localised text for a semantic key: the game-resolved string, or the English
--- fallback if the loca table has not loaded or the key is unknown.
---@param key string
---@return string
function LocaKeys.L(key)
	local entry = LocaKeys.Strings[key]
	if not entry then
		return key
	end
	if Ext and Ext.Loca and Ext.Loca.GetTranslatedString then
		local ok, text = pcall(Ext.Loca.GetTranslatedString, entry.handle, entry.en)
		if ok and type(text) == "string" and text ~= "" then
			return text
		end
	end
	return entry.en
end

return LocaKeys
