# Build, gates, and packaging

The quality-gate set, why it is split the way it is, what each gate does NOT
prove, and how the pak is produced. For the contributor-facing setup and release
walkthrough see [../CONTRIBUTING.md](../CONTRIBUTING.md); for getting facts out
of a running game see [ingame-debugging.md](ingame-debugging.md).

## The entrypoint

Everything is driven by a single cargo-style entrypoint, `make.ps1`, which
downloads its own pinned tooling into `.tools/` (gitignored) on first use - no
Rust or Lua build toolchain required. It runs under Windows PowerShell 5.1 and
cross-platform `pwsh`, so CI (`.github/workflows/ci.yml`) invokes the same
commands via `pwsh`.

**Run `./make.ps1 help` for the current command list.** `make.ps1` prints its own
comment-block help, so that is always accurate; a copy in a markdown file is
stale by construction.

**Every tool targets Lua 5.4 - the version BG3SE runs** - so the tooling checks
the same language the game does (integer and bitwise ops, `<const>`/`<close>`).
The interpreter (`lua54`), luacheck (built on PUC-Rio Lua 5.4), and
lua-language-server's `runtime.version` are all pinned to 5.4.

**To verify a change locally, run `./make.ps1 all` and nothing else.** It formats
in place and then runs the cross-platform gates it bundles (format, lint,
typecheck, test, validate-xml, ascii-check); a green `all` is the definition of
done. `xaml-check` and the divine gates are not in `all` (see below). CI runs
`check`, which is identical except it verifies formatting instead of writing it.

## The gates

| Gate | Tool | Config | Command |
|---|---|---|---|
| Format | StyLua | `.stylua.toml` | `format` (verify: `format-check`) |
| Lint | luacheck | `.luacheckrc` | `lint` |
| Type check | lua-language-server | `.luarc.json` | `typecheck` |
| Unit tests | LuaUnit | `spec/` | `test` |
| XML well-formedness | System.Xml | (none) | `validate-xml` |
| Typography | regex | (mirrors `.githooks/pre-commit`) | `ascii-check` |
| XAML resolution | custom + oracle | `xaml-oracle.txt` | `xaml-check` |
| Loca compile | divine | (none) | `loca-check` |
| Pak smoke | divine | (none) | `build` (asserts pak members) |
| Osiris lint | LSLib StoryCompiler | (none) | `story-check` |
| Stats lint | LSLib StatParser | (none) | `stats-check` |

Notes:

- **StyLua** uses its opinionated defaults verbatim (`.stylua.toml`) - tabs, 120
  columns, Roblox Lua Style Guide. Do not tune the config to a personal style;
  the point of a deterministic formatter is that style is not up for debate.
- **luacheck** lints against `std = "lua54"`, so it accepts and checks every file
  including `Util.lua`'s bitwise FNV-1a (a Lua-5.4-only construct). Engine
  globals (`Ext`, `Osi`, `Mods`, `ModuleUUID`, `_C/_D/_P`) are declared in
  `.luacheckrc` as read-only; add one there if luacheck flags a real engine
  global as undefined. `spec/` has a scoped override (writable `Ext`/`Osi` for
  the stubs, `allow_defined_top` for the LuaUnit `Test*` tables). Line length is
  disabled - StyLua owns that.
- **lua-language-server** type-checks from the EmmyLua annotations. `typecheck`
  auto-fetches the authoritative BG3SE `ExtIdeHelpers.lua` into `.luals-libs/`
  (gitignored; `.luarc.json` points `workspace.library` there) and gates on
  **Error level only**. The dynamic `Ext`/`Osi` surface produces unavoidable
  *Warnings* (undefined-field, API drift) that are useful inline in an editor but
  are not build failures. Editors read the same `.luarc.json`, so autocomplete
  works once `.luals-libs/` is populated.
- **LuaUnit** is a single pure-Lua file, so it bootstraps on the prebuilt Lua 5.4
  interpreter with no C-compiler dependency (unlike busted). It tests only the
  engine-independent modules. `spec/spec_helper.lua` stubs the `Ext`/`Osi`
  surface and reimplements `Ext.Require` so a module and its dependencies load
  off-game; `spec/run.lua` is the runner.
- The `.githooks/pre-commit` hook runs `format-check`, `lint`, `validate-xml`,
  and `xaml-check` when a PowerShell is available, so the ASCII-punctuation check
  still works without one. `xaml-check` skips unless the committer has
  `$env:NYS_XAML_ORACLE_SALT` set. In CI every gate runs, but some no-op when
  their inputs are absent - `xaml-check` without the oracle salt (a fork with no
  secret), `story-check` / `stats-check` without their content (see below).

## What the gates do NOT prove

- **The unit suite proves code correctness, never feature correctness in game.**
  It covers only the engine-independent logic (`Util`, `Store`, `NameWriter`).
- **`validate-xml` proves the XML parses, NOT that the Noesis semantics hold.**
  There is no offline validator for Larian's `ls:`/`se:` XAML dialect: the
  controls are compiled game code, not extractable data, so XamlPlayer/Noesis
  cannot load them even with full game data. Real XAML validity is only provable
  in game (the `UI State verification failed` console line).
- **Nothing here proves in-game behaviour.** You cannot run the game; only the
  user can.

## Asset gates: local vs CI, and the divine-on-Linux trap

The Lua gates and the two game-data-free asset gates (`validate-xml`,
`ascii-check`) run on `ubuntu-latest` and are folded into `all`/`check`. The
**divine-dependent** gates are split off because **LSLib's `divine` CLI crashes
on POSIX paths** - `Divine/CLI/CommandLineActions.cs::TryToValidatePath` runs
`Uri.IsFile` on a relative `Uri` for any `/abs/path` (uncaught throw) and rejects
`file:///abs/path` as non-rooted, so no input works on Linux (identical on
`master`). Therefore:

- `loca-check` and the `build` pak-smoke gate run on a **`windows-latest`** CI
  job (`ci.yml` `assets`), matching `release.yml`. This is the first time the pak
  is built on a PR - `release.yml` only builds on a tag. They are NOT in
  `all`/`check` (which stay cross-platform); run them locally on Windows.

`xaml-check` resolves the mod's XAML `Static`/`DynamicResource` keys,
`ls:`/`se:`/`noesis:` controls, and `pack://` assets against the game's real UI,
catching typo'd resources/assets that `validate-xml` (well-formedness only)
cannot. It gets the game's identifier universe one of two ways: live from
`-Bg3Data <Data folder>` (the game's `Data` directory, unpacked by `divine` -
exact and always current), or from a committed HMAC oracle so it can also run in
CI with no game install. With neither available (a fork with no secret) it skips
cleanly, so it is not in `all`/`check` but does run as its own CI job. Only the
game can confirm the runtime binding semantics.

The oracle (`xaml-oracle.txt`) is keyed HMAC-SHA-256 (128-bit) digests of every
game key/control/asset identifier - no readable game data, so committing it does
not redistribute Larian's copyrighted XAML. `xaml-extract` regenerates it from
the installed game and must be re-run after a game patch (a stale oracle drifts
into false results). Both `xaml-extract` and the CI job read the salt from
`$env:NYS_XAML_ORACLE_SALT`; the extract salt and the CI secret of the same name
MUST match, or every game reference fails to resolve. No install path is ever
assumed - `-Bg3Data` is explicit.

`story-check` and `stats-check` share that local-only, game-data-backed bucket
and are scaffolded now for content that does not exist yet: `story-check` runs
LSLib `StoryCompiler --check-only` once a `Mods/NameYourSummons/Story/` tree
exists, and `stats-check` runs LSLib `StatParser` once a
`Mods/NameYourSummons/Stats/` tree exists (both tools ship in the vendored
`ExportTool` zip, located via `Get-LslibTool`). Like `xaml-check`, each no-ops
cleanly when its content or `-Bg3Data` is absent, so they never run on the hosted
runners.

## Packaging

`./make.ps1 build` downloads a pinned LSLib release into `.tools/` and wraps
`divine.exe -a create-package` to produce `build/NameYourSummons-<version>.pak`
plus a matching zip, both suffixed with the mod's semantic version (`-Clean`
wipes `build/` first). The Modder's Multitool *Create Package* does the same
thing by hand.

**Trap: divine excludes any file whose ABSOLUTE path contains a dot-segment**
(e.g. a `.paseo` worktree), silently emitting an empty pak. `make.ps1 build`
stages the mod into a dot-free temp dir to dodge this.

In that stage it also:

- compiles every `Localization/**/*.loca.xml` into the binary `.loca` the game
  loads (via `divine --action convert-loca`) and drops the `.xml`, so only
  compiled tables ship (`Convert-StageLoca`);
- stamps the STAGED `meta.lsx` `Version64` build field with the build time as
  Unix epoch seconds (UTC) (`Set-StagedBuildTimestamp`) - the build number. The
  committed `meta.lsx` keeps build 0.

The LOCAL `build` / `deploy` filenames carry the build number
(`NameYourSummons-X.Y.Z.<epoch>.{pak,zip}`) and the startup line shows it
(`Util.VersionString` appends `.build` when non-zero). Since the epoch makes each
filename unique, `deploy` clears its prior `NameYourSummons-*.pak` from the Mods
folder before copying, so the game never loads two paks of the same mod.

The PUBLIC release asset stays `NameYourSummons-X.Y.Z.zip`: `release.yml` packs
with `build -NoBuildNumber`, which drops the epoch from the filename only - the
pak is still stamped.

The build field is 31 bits, so epoch seconds overflow it on 2038-01-19; past that
the stamp and suffix are omitted (a warning) and the filename is `X.Y.Z`.

To test a change, run `./make.ps1 deploy` and have the user restart the game.

## Versioning

The mod version is a packed `Version64` int64 in `meta.lsx` (the `ModuleInfo`
node and its nested `PublishVersion`), and is **the single source of truth**.
`Get-ModVersion` decodes it, `Set-ModVersion` re-encodes a semver into it.

The release workflow itself (`prepare-release`, `create-release-tag`, the
maintenance-branch flow, news fragments) is documented for humans in
[../CONTRIBUTING.md](../CONTRIBUTING.md).

## Mod-manager thumbnail (known limitation)

`mod_publish_logo.png` sits next to `meta.lsx` by convention (the same path every
Larian-toolkit-published mod uses; it is discovered by filename and is not
referenced in `meta.lsx`). `make.ps1 build` packs the whole `NameYourSummons/`
folder, so the file ships automatically - no build change needed. The source
image is `assets/mod-thumbnail.png` (1920x1080, 16:9); update both if you replace
it.

**It does NOT render in the in-game mod manager for our mod, and cannot.** The
manager reads a mod's description AND thumbnail fresh from the pak at game
startup (neither is cached to disk - confirmed: the description updates on a full
relaunch, nothing in `%LOCALAPPDATA%\...\Baldur's Gate 3` stores it). The
description shows, but the thumbnail stays the grey placeholder: the engine only
populates the card image (`VMModPreview.MainScreenshot.Screenshot`, with a
`HasScreenshotTexture` fallback - see `Mods/ModBrowser/GUI/...` in `Game.pak`)
for mods it downloaded from mod.io, not for a locally-installed `.pak`. Because
Name Your Summons requires the Script Extender it can never be published to
mod.io, so there is no path to an in-game thumbnail. The file is kept anyway: it
is zero-cost, correct by convention, and would light up if the mod were ever
distributed through mod.io.

Note: the mod manager only re-scans a mod's metadata on a full game restart, and
description/thumbnail changes to an already-installed pak may need an uninstall
plus reinstall of the pak to take effect.
