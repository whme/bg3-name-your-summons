# Build, gates, and packaging

The quality-gate set, how far each gate takes you, and how the pak is produced.
For contributor setup and the release walkthrough see
[../CONTRIBUTING.md](../CONTRIBUTING.md); for getting facts out of a running game
see [ingame-debugging.md](ingame-debugging.md).

## The entrypoint

Everything is driven by a single cargo-style entrypoint, `make.ps1`, which
downloads its own pinned tooling into `.tools/` (gitignored) on first use, so a
clone plus a PowerShell is the whole setup. It runs under Windows PowerShell 5.1
and cross-platform `pwsh`, and CI (`.github/workflows/ci.yml`) invokes the same
commands via `pwsh`.

**Run `./make.ps1 help` for the current command list** - it prints its own
comment-block help, so it is always current.

**Every tool targets Lua 5.4 - the version BG3SE runs** - so the tooling checks
the same language the game does (integer and bitwise ops, `<const>`/`<close>`).
The interpreter (`lua54`), luacheck (a luastatic binary built on PUC-Rio Lua
5.4), and lua-language-server's `runtime.version` are all pinned to 5.4.

**To verify a change locally, run `./make.ps1 all` and nothing else.** It formats
in place and then runs the cross-platform gates it bundles (format, lint,
typecheck, test, validate-xml, ascii-check); a green `all` is the definition of
done. `xaml-check` and the divine gates are not in `all` (see below). CI runs
`check`, which is identical except it verifies formatting instead of writing it.

`all`/`check` carry the gates that behave identically for every contributor on
every platform. Run the rest as their own commands: `loca-check` and `build` on
Windows (see "Where each gate runs"), and `xaml-check` once you have the oracle
salt or a game install (see "The XAML oracle"). CI runs each of those as its own
job.

## The gates

| Gate | Tool | Config | Command |
|---|---|---|---|
| Format | StyLua | `.stylua.toml` | `format` (verify: `format-check`) |
| Lint | luacheck | `.luacheckrc` | `lint` |
| Type check | lua-language-server | `.luarc.json` | `typecheck` |
| Unit tests | LuaUnit | `spec/` | `test` |
| XML well-formedness | System.Xml | (none) | `validate-xml` |
| Typography | regex | (mirrors `.githooks/pre-commit`) | `ascii-check` |
| XAML resolution | custom | `xaml-oracle.txt` + salt | `xaml-check` |
| Loca compile | divine | (none) | `loca-check` |
| Pak smoke | divine | (none) | `build` (asserts pak members) |
| Osiris lint | LSLib StoryCompiler | (none) | `story-check` |
| Stats lint | LSLib StatParser | (none) | `stats-check` |

Notes:

- **StyLua** uses its opinionated defaults verbatim. Do not tune the config to a
  personal style; the point of a deterministic formatter is that style is not up
  for debate.
- **luacheck** lints against `std = "lua54"`, so it accepts and checks every file
  including `Util.lua`'s bitwise FNV-1a (a Lua-5.4-only construct). Engine
  globals are declared read-only in `.luacheckrc`; add one there if luacheck
  flags a real engine global as undefined.
- **lua-language-server** type-checks from the EmmyLua annotations and gates on
  **Error level only**. Read its *Warnings* (undefined-field, API drift) inline
  in the editor: they come from the dynamic `Ext`/`Osi` surface and are
  informational. `typecheck` auto-fetches the authoritative BG3SE
  `ExtIdeHelpers.lua` into `.luals-libs/` (gitignored), which is also what makes
  editor autocomplete work, since editors read the same `.luarc.json`.
- **LuaUnit** is a single pure-Lua file, so it runs directly on the prebuilt Lua
  5.4 interpreter. `spec/spec_helper.lua` stubs the `Ext`/`Osi` surface and
  reimplements `Ext.Require` so a module and its dependencies load off-game.
- The `.githooks/pre-commit` hook always runs the ASCII-punctuation scan (pure
  bash), and adds `format-check`, `lint`, `validate-xml`, and `xaml-check` when a
  PowerShell is on PATH. Set `$env:NYS_XAML_ORACLE_SALT` to include `xaml-check`.
  In CI every gate runs, but some no-op when their inputs are absent - `xaml-check`
  without the oracle salt (a fork with no secret), `story-check` / `stats-check`
  without their content (see below).

## How far each gate takes you

- **`./make.ps1 all` settles syntax, formatting, types, and the pure logic.** The
  suite covers the engine-independent modules (`Util`, `Store`, `NameWriter`,
  `SummonClassifier`, `LocaKeys`, `Trace`) plus the shipped `.loca.xml` tables.
  To settle behaviour, run `./make.ps1 deploy` and have the user exercise it in
  game (see [ingame-debugging.md](ingame-debugging.md)). Keep new pure logic in
  those modules, out of the ECS / net / native-UI / timing glue, so a spec can
  reach it.
- **`validate-xml` settles that every XAML, `meta.lsx`, and `.loca.xml` parses.**
  To settle the Noesis semantics of Larian's `ls:`/`se:` dialect, load the page
  in game and read the console for `UI State verification failed`.
- **`xaml-check` settles resource keys and `pack://` assets** - an unresolved one
  fails the run. Read its `WARNING` lines too: an unknown `ls:`/`se:`/`noesis:`
  control is reported as a warning, because the control universe is scraped from
  the controls the game's own XAML instantiates.
- **`build` settles that the pak packs and carries its key members.** Confirm the
  line `verify-pak: meta.lsx, Examine.xaml, and a compiled .loca are present.` -
  when `list-package` prints nothing, `Assert-PakContents` warns and returns, so
  the member assertions did not run.
- **The user settles in-game behaviour.** Hand them the exact console command to
  run (`!nys_diag`, `!nys_rename`, ...) and read the output or the trace files;
  see [ingame-debugging.md](ingame-debugging.md).

## Where each gate runs

Run `loca-check` and the `build` pak-smoke gate on Windows. CI runs them on a
`windows-latest` job (`ci.yml`, job `assets`), matching `release.yml`; that job
is the first time the pak is built on a PR, since `release.yml` only builds on a
tag. Windows is required because both drive LSLib's `divine` CLI, which accepts
Windows-style paths only (`Divine/CLI/CommandLineActions.cs::TryToValidatePath`
rejects `/abs/path` and `file:///abs/path` alike). The Lua gates and the two
game-data-free asset gates (`validate-xml`, `ascii-check`) run on
`ubuntu-latest`.

`story-check` and `stats-check` are scaffolded for content still to come: run
`story-check` (LSLib `StoryCompiler --check-only`) once a
`Mods/NameYourSummons/Story/` tree exists, and `stats-check` (`StatParser`) once
a `Mods/NameYourSummons/Stats/` tree exists. Both tools ship in the vendored
LSLib `ExportTool` zip, located by filename via `Get-LslibTool`, and both take
`-Bg3Data`, so run them locally against an installed game.

## The XAML oracle

`xaml-check` resolves the mod's XAML against the game's real UI identifiers, and
gets that universe one of two ways: live from `-Bg3Data <Data folder>` (exact and
always current), or from the committed oracle, which also lets it run in CI with
no game install. Pass `-Bg3Data` explicitly; no install path is guessed. In a
fork with neither the salt nor a game install it skips cleanly.

The oracle (`xaml-oracle.txt`) holds keyed HMAC-SHA-256 digests truncated to 128
bits, so the committed file carries no readable game data and is safe to publish
alongside the mod. Two rules keep it honest:

- Keep the salt `xaml-extract` runs with identical to the CI secret of the same
  name, `$env:NYS_XAML_ORACLE_SALT`; a mismatched salt resolves every game
  reference as a miss.
- Re-run `xaml-extract` after a game patch; a stale oracle likewise resolves
  against identifiers the game no longer has.

## Packaging

`./make.ps1 build` downloads a pinned LSLib release into `.tools/` and wraps
`divine.exe -a create-package` to produce `build/NameYourSummons-<version>.pak`
plus a matching zip (`-Clean` wipes `build/` first). The Modder's Multitool
*Create Package* does the same thing by hand.

**Stage the mod into a dot-free temp directory before packing.** `Cmd-Build`
does this, and refuses to run when the system temp path is itself dotted: divine
excludes any file whose ABSOLUTE path contains a dot-segment (e.g. a `.paseo`
worktree) and silently emits an EMPTY pak.

In that stage `Cmd-Build` also:

- compiles every `Localization/**/*.loca.xml` into the binary `.loca` the game
  loads (`Convert-StageLoca`, via `divine --action convert-loca`) and drops the
  `.xml`, so only compiled tables ship;
- stamps the STAGED `meta.lsx` `Version64` build field with the build time as
  Unix epoch seconds (UTC) (`Set-StagedBuildTimestamp`) - the build number. The
  committed `meta.lsx` keeps build 0.

After packing, `Assert-PakContents` lists the pak and requires `meta.lsx`,
`Examine.xaml`, and a compiled `NameYourSummons.loca`, on top of the raw size
check.

The LOCAL `build` / `deploy` filenames carry the build number
(`NameYourSummons-X.Y.Z.<epoch>.{pak,zip}`) and the startup line shows it
(`Util.VersionString` appends `.build` when non-zero). Since the epoch makes each
filename unique, `deploy` clears any other `NameYourSummons-*.pak` out of the
Mods folder before copying, so the game loads exactly one pak of the mod.

For the PUBLIC release asset, pack with `build -NoBuildNumber` (what
`release.yml` does) to get `NameYourSummons-X.Y.Z.zip`; that drops the epoch from
the filename only, and the pak is still stamped.

To test a change, run `./make.ps1 deploy` and have the user restart the game.

## Versioning

The mod version is a packed `Version64` int64 in `meta.lsx` (the `ModuleInfo`
node and its nested `PublishVersion`, which are kept in step), and is **the
single source of truth**. `Get-ModVersion` decodes it, `Set-ModVersion`
re-encodes a semver into it. The top-level `<version>` node in `meta.lsx` is the
LSX file-format version, not the mod's - do not touch it.

The release workflow itself (`prepare-release`, `create-release-tag`, the
maintenance-branch flow, news fragments) is documented for humans in
[../CONTRIBUTING.md](../CONTRIBUTING.md).

## Mod-manager thumbnail

Keep `mod_publish_logo.png` next to `meta.lsx` - the path every
Larian-toolkit-published mod uses, discovered by filename rather than referenced
from `meta.lsx`. `make.ps1 build` packs the whole `NameYourSummons/` folder, so
it ships with no build change. Its source is `assets/mod-thumbnail.png`
(1920x1080, 16:9); replace both together.

Expect the grey placeholder card in the in-game mod manager: the engine populates
the card image (`VMModPreview.MainScreenshot.Screenshot`, with a
`HasScreenshotTexture` fallback - see `Mods/ModBrowser/GUI/...` in `Game.pak`)
for mods it downloaded from mod.io, and a Script-Extender mod ships as a local
`.pak`. The description does render, read fresh from the pak at startup: to see a
description change, fully restart the game, and reinstall the pak if the old text
persists.
