# Contributing to Name Your Summons

Name Your Summons is a pure-Lua Baldur's Gate 3 mod built on Norbyte's Script
Extender (BG3SE). Packaging is a file copy plus a loca conversion, and the game
itself is the integration test; the engine-independent logic is covered by unit
tests and guarded by static checks, all driven by one task runner.

This file is how to set up, run the checks, and submit a change. The rules a
coding agent must follow are in [AGENTS.md](AGENTS.md); the architecture and the
BG3SE-specific reasoning live in [docs/](docs/README.md).

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
./make.ps1 help          # the full, current command list
./make.ps1 all           # format in place, then the bundled cross-platform gates
./make.ps1 check         # the read-only twin of `all` (what CI runs)
./make.ps1 build         # pack the mod into build/ (.pak + .zip)
./make.ps1 deploy        # build, then copy the .pak into BG3's Mods folder
```

`./make.ps1 help` prints the authoritative list - it is generated from the
script itself, so it never drifts. Run `./make.ps1 all` while you work and
`./make.ps1 check` before you push; CI runs the same commands via `pwsh` on
Linux, so a green local `check` means a green CI for those gates. The
divine-dependent gates (`loca-check`, `build`) are Windows-only and run in a
separate CI job - see [docs/build-and-gates.md](docs/build-and-gates.md).

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
| XML, typography, XAML, loca, pak | System.Xml / regex / divine | see [docs/build-and-gates.md](docs/build-and-gates.md) |

The full gate list, what each one does *not* prove, and why the divine-backed
gates are split onto a Windows CI job are in
[docs/build-and-gates.md](docs/build-and-gates.md).

Notes:

- **Let StyLua decide formatting.** It is deterministic and uses its defaults;
  run `./make.ps1 format` and commit the result.
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

The game is the only integration test, and neither CI nor a reviewer runs it
quickly. So:

- **Unit tests** (`./make.ps1 test`) cover the engine-independent logic - key
  derivation, hashing, input sanitising, ModVar shaping, and the two
  `DisplayName` writes. `spec/spec_helper.lua` stubs the `Ext`/`Osi` surface so
  modules load off-game. When you change testable logic, add or update a spec.
- **Keep pure logic engine-free** so it stays testable; push unavoidable ECS,
  net, native-UI, and timing code into the thin glue modules (`SummonWatcher`,
  `Naming`, `NativeRenameUI`, `Channels`).
- **In-game behaviour** is verified with the Script Extender console commands
  (see below). If a change needs in-game confirmation, say so in your PR and
  name the command a reviewer should run.

## Console commands

These commands run in the Script Extender console - a separate window that opens
alongside the game once you enable it in
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\ScriptExtenderSettings.json`:

```json
{ "CreateConsole": true, "DeveloperMode": true }
```

| Command | Context | What it does |
|---|---|---|
| `!nys_list` | server | list all saved names |
| `!nys_diag` | server | dump what the game thinks your summons are named |
| `!nys_rename <name>` | server | rename the host's summons right now, no prompt |
| `!nys_clear` | server | wipe all saved names |

`!nys_diag` is the primary debugging tool: when a name will not stick, paste its
output when reporting the issue. There are more commands than the four above -
`!nys_reapply`, `!nys_debug`, `!nys_trace`, `!nys_uidump` - each with traps
worth knowing; see [docs/ingame-debugging.md](docs/ingame-debugging.md).

## Coding conventions

- **ASCII punctuation only.** No em/en-dashes, smart quotes, ellipsis glyphs, or
  arrows anywhere in the repo - use `-`, `'`/`"`, `...`, `->`. The pre-commit
  hook enforces this.
- **EmmyLua annotations** (`---@param`, `---@return`, `---@field`) on functions
  with non-obvious types - the type hints are what make the dynamically-typed
  BG3SE objects navigable.
- Default to no inline comments; add one only for a non-obvious BG3SE/Osiris
  quirk, an empirical timing delay, or a replication invariant.

See [AGENTS.md](AGENTS.md) for the full standards and [docs/](docs/README.md)
for the BG3SE and NoesisGUI reasoning behind them.

## News fragments

User-facing changes are recorded in `news/` as a **news fragment** - a short
markdown file that [changelogging](https://github.com/nekitdev/changelogging)
assembles into `CHANGELOG.md` at release time. Add one in the same PR as your
change:

- **Filename**: `news/<id>.<type>.md`. The `<id>` is the PR or issue number
  (e.g. `news/42.feature.md`), or an arbitrary name prefixed with `~` when
  there is no number (e.g. `news/~fix-summon-name.bugfix.md`). A bare
  non-numeric name without the `~` is silently ignored.
- **Type**: one of `feature`, `bugfix`, `security`, `deprecation`, `removal`.
- **Body**: one or two sentences describing the change from a player's point of
  view. Plain markdown, ASCII punctuation, **no byte-order mark** (a BOM ends up
  verbatim in the changelog - the `make.ps1`/editor default of UTF-8 without BOM
  is correct).

The `news-fragment-check` workflow fails a PR that neither adds a fragment nor
carries the `no-news-fragment-needed` label. Use that label for docs, CI, or
internal changes that players never see.

To preview the assembled changelog locally, run `./make.ps1 changelog` - but
note it consumes (deletes) the fragments, so revert before committing unless you
are actually cutting a release.

## Releasing (maintainers)

Releases are driven by two `make.ps1` commands and one tag-triggered workflow.
Run the `git`/`gh` steps from PowerShell (the SSH `origin` remote only works
there on this machine).

1. **Prepare** - from `main` (major/minor) or a `*-maintenance` branch (patch):

   ```powershell
   ./make.ps1 prepare-release
   ```

   It bumps `meta.lsx`, assembles the changelog, commits `Version X.Y.Z`, and
   either opens a PR against the maintenance branch (major/minor from `main`) or
   pushes straight to the maintenance branch (patch).

2. **Merge** the release PR if one was opened, then check out and pull the
   maintenance branch.

3. **Tag** - creates and pushes the annotated `X.Y.Z` tag:

   ```powershell
   ./make.ps1 create-release-tag
   ```

   The tag push fires `.github/workflows/release.yml`, which packs the `.pak`,
   attests it, and publishes a **draft** release (its body is built from
   `templates/release_template.md` plus the tagged `CHANGELOG.md` section). Review
   and publish it from the GitHub Releases page.

## Submitting changes

1. Make sure `./make.ps1 check` is green and specs are added/updated.
2. Add a news fragment (see above) or the `no-news-fragment-needed` label.
3. Write a clear commit message (subject + body explaining the "why"). Keep it
   ASCII. For AI-assisted commits, add a `Co-authored-by:` trailer naming the
   model.
4. Open a pull request describing the change and how you verified it in game (if
   applicable).
