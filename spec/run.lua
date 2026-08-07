-- Entry point for the unit suite: `lua spec/run.lua` (run from the repo root).
-- Invoked by `./make.ps1 test`, which downloads a Lua 5.4 interpreter and
-- LuaUnit into .tools/ first.

package.path = table.concat({
	".tools/lua/?.lua", -- luaunit.lua from the make.ps1 bootstrap
	"spec/?.lua",
	package.path,
}, ";")

require("spec_helper") -- installs the Ext/Osi stubs before any module loads

local lu = require("luaunit")

-- Each spec registers its Test* tables as a side effect of loading.
require("util_spec")
require("store_spec")
require("name_writer_spec")
require("classifier_spec")

os.exit(lu.LuaUnit.run())
