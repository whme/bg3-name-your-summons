-- Lint against the exact Lua version BG3SE runs (5.4), so the linter accepts
-- and checks the same language the game does (integer/bitwise ops in Util.lua).
std = "lua54"

-- StyLua owns line length and wrapping; the linter should not second-guess it.
max_line_length = false

-- Engine globals injected by BG3SE. read_globals = present but not writable, so
-- a stray assignment to one is flagged.
read_globals = { "Ext", "Osi", "Mods", "ModuleUUID", "_C", "_D", "_P" }

exclude_files = { ".tools", ".luals-libs" }

-- The unit suite stubs the engine (so it writes to Ext/Osi) and registers its
-- LuaUnit `Test*` tables as globals for discovery.
files["spec"] = {
    globals = { "Ext", "Osi", "ModuleUUID" },
    allow_defined_top = true,
    -- LuaUnit test methods are declared with `:` but rarely need `self`.
    ignore = { "212/self", "431/self", "432/self" },
}
