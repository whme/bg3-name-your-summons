# Build, gates, and packaging

The quality-gate set and how the pak is produced. Contributor setup and the release
walkthrough are in [../CONTRIBUTING.md](../CONTRIBUTING.md).

## The entrypoint

`make.ps1` drives everything and downloads its own pinned tooling into `.tools/` on
first use, so a clone plus a PowerShell runs every cross-platform gate; the
divine-backed gates additionally need the .NET 8 Desktop Runtime. The Lua tooling
targets Lua 5.4, the version BG3SE runs. Run `./make.ps1 help` for the current
command list.

**To verify a change locally, run `./make.ps1 all`** - it formats in place then runs
the cross-platform gates; a green `all` is the definition of done. CI runs `check`,
its read-only twin. The gates that need LSLib's `divine` (`loca-check`, `build`) run
separately on Windows, because that tool only accepts Windows-style paths; CI runs
them on their own Windows job.

## The gates

| Gate | Tool | Command |
|---|---|---|
| Format | StyLua | `format` (verify: `format-check`) |
| Lint | luacheck | `lint` |
| Type check | lua-language-server | `typecheck` |
| Unit tests | LuaUnit | `test` |
| XML well-formedness | System.Xml | `validate-xml` |
| Typography (ASCII only) | regex | `ascii-check` |
| XAML resolution | custom + oracle | `xaml-check` |
| Loca compile | divine | `loca-check` |
| Pak smoke | divine | `build` |
| Osiris / stats lint | LSLib | `story-check` / `stats-check` |

What the gates settle and what they do not: `all` covers syntax, formatting, types,
and the engine-independent logic. It does not cover in-game behaviour or the Noesis
semantics of Larian's XAML dialect - only running the game confirms those. The unit
tests reach only the pure logic, which is why that logic is kept out of the engine
glue. `xaml-check` resolves the mod's XAML references against the game's real UI,
either from a live game install or from a committed oracle so it can also run in CI.

## Packaging

`./make.ps1 build` packs the mod into `build/` as a versioned `.pak` and zip, and
`deploy` copies it into the game's Mods folder. Two things the build does that are
easy to miss: it compiles the plain-text localisation sources into the binary format
the game loads, and it stamps a build number into the packaged manifest while leaving
the committed one untouched. The mod version itself lives as a single packed integer
in the manifest and is the one source of truth. To test a change, `deploy` and have
the user restart the game.
