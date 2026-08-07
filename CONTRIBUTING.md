# Contributing to Name Your Summons

Name Your Summons is a pure-Lua Baldur's Gate 3 mod built on Norbyte's Script
Extender (BG3SE). There is no build step - the game itself is the only
integration test - but the engine-independent logic is covered by unit tests and
guarded by static checks, all driven by one task runner.

For architecture and the deeper BG3SE-specific standards, see
[AGENTS.md](AGENTS.md). This file is the short version: how to set up, run the
checks, and submit a change.

## Prerequisites

- **PowerShell** - Windows PowerShell 5.1 (built into Windows) or PowerShell 7
  (`pwsh`, any OS). That is all you need; the task runner downloads every other
  tool itself.
- **To test in game** (optional): Baldur's Gate 3 with the Script Extender
  installed.

No Rust, Lua, or LuaRocks toolchain is required - all tools are prebuilt
binaries fetched on first use into `.tools/` (gitignored).

## The task runner: `make.ps1`

`make.ps1` is a cargo-style entrypoint. Run it from the repo root:

```powershell
./make.ps1 setup         # download all tooling up front (optional)
./make.ps1 format        # format the code in place with StyLua
./make.ps1 format-check  # verify formatting (diff only, no writes)
./make.ps1 lint          # luacheck
./make.ps1 typecheck     # lua-language-server
./make.ps1 test          # LuaUnit suite
./make.ps1 check         # format-check + lint + typecheck + test (what CI runs)
./make.ps1 build         # pack the mod into build/ (.pak + .zip)
```

Run `./make.ps1 check` before you push; CI runs the exact same commands via
`pwsh` on Linux, so a green local `check` means a green CI.

## Building the mod

`./make.ps1 build` packs the mod into `build/`. On first run it downloads a
pinned [LSLib](https://github.com/Norbyte/lslib) release into `.tools/` (needs
the [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/8.0)),
then produces:

- `build/NameYourSummons-<version>.pak` - the installable mod; drop it in
  `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\`.
- `build/NameYourSummons-<version>.zip` - the same `.pak` zipped for upload.

Pass `-Clean` (`./make.ps1 build -Clean`) to wipe `build/` first. (The **BG3
Modder's Multitool** *Create Package* still works too - it wraps the same LSLib
packer.)

## Quality gates

Every tool targets **Lua 5.4** - the version BG3SE runs - so the checks accept
and validate the same language the game does (integer and bitwise operators,
`<const>`/`<close>`).

| Gate | Tool | Config |
|---|---|---|
| Format | [StyLua](https://github.com/JohnnyMorganz/StyLua) | `.stylua.toml` (its opinionated defaults) |
| Lint | [luacheck](https://github.com/lunarmodules/luacheck) | `.luacheckrc` (`std = "lua54"`) |
| Type check | [lua-language-server](https://github.com/LuaLS/lua-language-server) | `.luarc.json` |
| Unit tests | [LuaUnit](https://github.com/bluebird75/luaunit) | `spec/` |

Notes:

- **Formatting is not up for debate.** StyLua is deterministic and uses its
  defaults; run `./make.ps1 format` and commit the result. Do not hand-tune
  style.
- **lua-language-server** gates on Error level only. The dynamic `Ext`/`Osi`
  surface produces Warnings (undefined-field, API drift) that are helpful inline
  in an editor but are not build failures. For editor autocomplete, the type
  check auto-fetches the BG3SE `ExtIdeHelpers.lua` into `.luals-libs/`
  (gitignored); `.luarc.json` points your editor at it too.

## Enabling the git hook

A pre-commit hook rejects non-ASCII "smart" punctuation (see below) and runs the
format and lint gates. Enable it once per clone:

```powershell
git config core.hooksPath .githooks
```

## Testing

You **cannot run the game** in CI, and neither can a reviewer quickly. So:

- **Unit tests** (`./make.ps1 test`) cover the engine-independent logic - key
  derivation, hashing, input sanitising, ModVar shaping, and the two
  `DisplayName` writes. `spec/spec_helper.lua` stubs the `Ext`/`Osi` surface so
  modules load off-game. When you change testable logic, add or update a spec.
- **Keep pure logic engine-free** so it stays testable; push unavoidable ECS,
  net, ImGui, and timing code into the thin glue modules (`SummonWatcher`,
  `Naming`, `PromptUI`, `Channels`).
- **In-game behaviour** is verified with the Script Extender console commands
  (`!nys_diag`, `!nys_rename`, `!nys_list`, ...). If a change needs in-game
  confirmation, say so in your PR and name the command a reviewer should run.

## Coding conventions

- **ASCII punctuation only.** No em/en-dashes, smart quotes, ellipsis glyphs, or
  arrows anywhere in the repo - use `-`, `'`/`"`, `...`, `->`. The pre-commit
  hook enforces this.
- **EmmyLua annotations** (`---@param`, `---@return`, `---@field`) on functions
  with non-obvious types - the type hints are what make the dynamically-typed
  BG3SE objects navigable.
- Default to no inline comments; add one only for a non-obvious BG3SE/Osiris
  quirk, an empirical timing delay, or a replication invariant.

See [AGENTS.md](AGENTS.md) for the full standards and the BG3SE gotchas.

## Submitting changes

1. Make sure `./make.ps1 check` is green and specs are added/updated.
2. Write a clear commit message (subject + body explaining the "why"). Keep it
   ASCII. For AI-assisted commits, add a `Co-authored-by:` trailer naming the
   model.
3. Open a pull request describing the change and how you verified it in game (if
   applicable).
