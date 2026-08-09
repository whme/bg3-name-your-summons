--[[
	The MultiSummonMode setting: how to handle one spell that summons several
	creatures of the same type at once (e.g. Conjure Animals). Shared by the
	config UIs (which map the value to a 0-based control index) and kept
	engine-independent so it is unit-tested off-game.
]]

local MultiSummonMode = {}

-- Stored enum values, in the order they appear in the UI. The stored setting is
-- always one of these strings; the UI works in 0-based indices.
MultiSummonMode.MODES = { "skip", "shared", "unique" }

-- Player-facing labels, parallel to MODES.
MultiSummonMode.LABELS = {
	"Do not name them",
	"Share one name",
	"Name each individually",
}

--- The 0-based control index for a stored mode value (defaults to 0 / "skip").
---@param value any
---@return integer
function MultiSummonMode.IndexOf(value)
	for i, mode in ipairs(MultiSummonMode.MODES) do
		if mode == value then
			return i - 1
		end
	end
	return 0
end

--- The stored mode value for a 0-based control index (defaults to "skip").
---@param index integer
---@return string
function MultiSummonMode.ValueAt(index)
	return MultiSummonMode.MODES[(index or 0) + 1] or "skip"
end

return MultiSummonMode
