# Name Your Summons - Agent Instructions

## Project Overview

Name Your Summons is a Baldur's Gate 3 mod that lets the player name a
summoned creature, remembers the name, and reapplies it automatically the
next time the same creature is summoned. It is built on Norbyte's Script
Extender (BG3SE), API v30. It is pure Lua - there is no compiler, no build
system, and no test runner. The only way to exercise it is to run it inside
the game.

## Architecture

- **Two Lua states**: BG3SE runs a single **server** state and one **client**
  state per connected peer. Server owns detection, persistence, and name
  application; client owns the ImGui prompt and the saved-name manager.
- **Detection pipeline**: there is no "summon created" Osiris event. Detection
  is `Osi.EnteredLevel` -> `Osi.IsSummon` -> `Osi.CharacterGetOwner`. This
  covers Find Familiar, Find Companion, Conjure Animals, Animate Dead, and
  anything else the game classifies as a summon, with no per-spell casing.
- **Creature-type filter** (`Shared/SummonClassifier.lua`): which summons are
  prompted for is gated by type. A summon's type is read from its character
  tags - each of the 14 D&D creature types is a plain tag (`UNDEAD`, `BEAST`,
  ...), and `FIND_FAMILIAR` marks Find Familiar summons and takes priority over
  the creature type. The classifier is pure (tag names in, category out); the
  glue that resolves a live summon's tag GUIDs to names is `Naming.TagNamesOf`.
  Per-type toggles live in settings; only familiars are named by default, and a
  `NameEverySummon` master reproduces the old name-everything behaviour.
- **The renaming primitive** (`Shared/NameWriter.lua`): a creature's name is
  `DisplayName.Name`, a localisation handle rather than text. Renaming is two
  writes - register the text under a handle of the mod's own via
  `Ext.Loca.UpdateTranslatedString`, then point `Name.Handle` at it with
  `Version = 0`. Never overwrite the template's shared handle: every creature
  from that template shares it, so doing so renames all of them, in every save,
  until the game restarts.
- **Server <-> client**: the NetChannel API (`Ext.Net.CreateChannel`),
  created in both states in `Shared/Channels.lua`. The deprecated NetMessage
  API is not used.
- **Persistence**: names live in ModVars (`Ext.Vars.RegisterModVariable`),
  written into the savegame. `PersistentVars` is deprecated and not used. A
  saved value is EITHER one string (the shared name) OR an array of strings (a
  "unique set" - one distinct name per creature of a multi-summon; see below). A
  parallel `SkippedSummons` ModVar is the set of keys the player chose to always
  skip; it is mutually exclusive with a saved name (naming clears the skip and
  vice versa).
- **Stable key**: a summon's UUID changes every conjure, so the key is
  `"<owner uuid>|<root template>"` (`Util.MakeKey`). Runtime loca entries do
  not survive a restart, so every saved name's handle is re-registered on
  `SessionLoaded` before names are reapplied. Handles are derived from the name
  text (FNV-1a), which is what makes that re-registration possible without
  finding the entity first.
- **Multi-summon** (one spell, several creatures of the same type at once, e.g.
  Conjure Animals): those creatures share one owner and template, hence one key.
  The `MultiSummonMode` setting (`skip` default / `shared` / `unique`) decides
  handling. The summon count is NOT knowable up front (it lives in
  `StatsFunctors` that Lua cannot read; container spells resolve creatures by
  player choice + upcast), so detection stays reactive per-creature: `shared`
  prompts once and applies to every live sibling; `unique` prompts per creature
  (guarded per-UUID) and stores a set; `skip` prompts the first creature and
  retracts (`Channels.RetractPrompt`) if a sibling reveals it to be a group.
  Re-summoning an already-named key is handled by a debounced per-cast resolver
  (`scheduleResolve` -> `resolveGroup`) scoped to only THAT cast's creatures (so
  older summons of the type keep their names), and it follows the CURRENT
  `MultiSummonMode`, not how the value was stored - switching `unique` -> `shared`
  collapses the stored set to its first name on the next summon and re-asks once.
- **Native Examine rename** (`Client/NativeRenameUI.lua` + `GUI/`): the Examine
  panel gets an editable name field (`NYS_NameInput`) and a settings gear
  (`NYS_SettingsButton`) via an `Examine.xaml` override (a state override in
  `StateMachines/Keyboard.xaml` points the Examine state at our page). The
  examined creature's uuid is read from the panel's Noesis DataContext
  (`DCExamine.EntityUUID` + `CharacterType == "Summon"`) and renames go to the
  server over `Channels.RenameSummon`. Commit is driven by GLOBAL input events
  (`Ext.Events.MouseButtonInput` / `KeyInput`), NOT the panel's routed UI events:
  the panel is a separate Noesis popup tree (`Ext.UI.GetRoot()` never sees its
  events) and the field's focus events do not fire on the first open after a load.
  Enter and click-away both commit (deduped). The gear and close button are NOT
  driven by per-element event subscriptions - those never take effect on the first
  Examine panel of a session (confirmed by tracing). Instead the always-reliable
  global mouse hook hit-tests them on each click by their `IsMouseOver` (the same
  property their XAML hover uses): a click over `CloseExamine` aborts the session, a
  click over `NYS_SettingsButton` opens the native settings panel (below), otherwise
  it is a field click. A `!nys_uidebug` client console command toggles verbose
  tracing of this whole flow. The mouse hook is always live
  (it is the only "panel opened" detector - `Ext.UI.GetStateMachine()` is stubbed
  to `nullptr` in this SE build, so there is no cheap/event-driven signal); the key
  hook is subscribed only while the panel is open. See GH issue for the
  state-machine follow-up.
- **Native Examine settings** (`Client/NativeConfigUI.lua` + `GUI/`): the gear
  opens a native (Noesis) settings overlay - an `NYS_SettingsPanel` in the same
  `Examine.xaml` override - reproducing the ImGui `ConfigUI` (prompt options,
  per-creature-type filter, multi-summon mode, and the saved-name /
  always-skipped / session-skipped managers). It is real MVVM: a viewmodel built
  via `Ext.UI.RegisterType` / `Ext.UI.Instantiate` (`Bool` props for checkboxes,
  a `Collection` per `ItemsControl`, `Command` props for buttons) is set as the
  panel's `DataContext`. `NativeRenameUI` owns Examine-panel detection and feeds
  this module the node finder (`SetPanelFinder(NativeRenameUI.FindNamed)`) and the
  gear hook (`SetGearHandler`), avoiding a circular require. Markup uses Larian
  `ls:` controls only (`ls:LSToggleButton` + `TickBox`, `ls:LSButton` +
  `SmallBrownButtonStyle`, `ls:LSTextBox`) extracted from the game's own
  `OptionTemplates.xaml` / `Buttons.xaml`. Four traps, learned the hard way and
  encoded in the module header:
  - **No standalone-window API** (and `Ext.UI.GetStateMachine()` is stubbed), so
    the panel must live inside a page we already override (Examine).
  - **A viewmodel/node handle does not survive across ticks** - the object lives
    on as the DataContext but any Lua reference expires (`Attempted to fetch
    Noesis::BaseObject whose lifetime has expired`). Never cache it; re-fetch live
    from the panel (`liveVm`) at each use, and use the live `context`/`value`
    inside a `WriteCallback`. Never compare a Noesis object with `== nil` (routes
    through `__eq`, which throws on an expired object) - use truthiness.
  - **An SE `Collection` is append-only from Lua** (`Clear`/`RemoveAt`/
    `table.remove`/whole-array assign all fail). The only clean list is a fresh
    viewmodel, so the whole panel is rebuilt on every open/refresh/save/forget
    (`populate`), guarded by a `generation` counter so a slow reply cannot append
    to a newer viewmodel.
  - **Prefix every viewmodel field `Nys`** so it cannot alias a built-in (an
    unprefixed `Name` aliased `FrameworkElement.Name` and round-tripped the
    literal "Name").
  Forgets and un-skips are staged (toggle to Undo) and flushed on Save; edited
  names are read off the live rows at Save. Same net channels as `ConfigUI`; no
  server changes. The ImGui `ConfigUI` stays for now (prompt Settings button +
  `!nys_ui`); both it and the prompt button are slated for later removal.
- **On-summon prompt = the Examine panel** (`Client/NativeRenameUI.lua`, GH #19):
  the on-summon naming UI is the native Examine panel, not the ImGui window.
  Detection, the pending count, the world-pause, and per-creature `unique`
  prompting all stay server-side and unchanged; the server still sends `AskName`.
  The client answers by opening Examine on the summon: fetch the game's
  `ExamineCommand` (a Noesis `BaseCommand`) off the root DataContext and
  `Execute` it with the summon's Noesis `EntityHandle` (the exact
  `CommandParameter` its XAML binds; a uuid string or SE `Entity` is rejected) -
  the handle is read by `EntityUUID` off a live per-entity DataContext (the
  always-present portrait view-models carry it). An on-summon request renames over
  `Channels.SubmitName` (not `RenameSummon`) so the server saves the name AND
  clears its pending count / lifts the pause, exactly as the old window did.
- **Multi-summon = one panel at a time, close to advance.** Only one Examine panel
  exists AND it cannot be closed from Lua (its close is a `UICancel` bound event /
  a Noesis-typed `CustomEvent("CloseWidget")` param - both unreachable via SE; a Lua
  string is rejected, `CanExecute` returns nil), and `ExamineCommand` is IGNORED
  while a panel is on screen. So summons are shown one at a time and the NEXT opens
  only after the PLAYER closes the current one. Naming (Enter / click-away) answers
  over `SubmitName` but leaves the panel up (`answered = true`); closing it (the
  `CloseExamine` button, hit-tested by the global mouse hook, or Escape - which the
  engine ALSO raises as its own `UICancel`, so an "ESCAPE" key event is not
  necessarily a physical press) advances: a summon left unnamed is a skip (abort),
  a named one is already saved. Because close is animated, `startNext(afterClose)`
  waits `EXAMINE_CLOSE_MS` before Executing the next (old panel gone) and keeps
  ignoring input for `EXAMINE_SETTLE_MS` after (open animation), so rapid skipping
  cannot dismiss the freshly opened panel (`awaitingOpen` gates all input in that
  window). One-shot `Ext.Timer.WaitForRealtime`, not polling. A failure to open
  Examine (command/handle missing or `Execute` throwing) skips to the next, so the
  pause never deadlocks. Noesis objects are fetched fresh and tested with truthiness
  (never `== nil`, never cached - a stale handle crashes on use). A `!nys_uidebug`
  client console command toggles verbose tracing (each line carries a live
  `[examine=.. field=.. | current=.. answered=.. awaitingOpen=..]` snapshot of the
  real UI, since internal flags alone once misled a debugging pass). The old ImGui
  prompt (`Client/PromptUI.lua`) is kept but no longer wired to `AskName`; its
  removal is a separate follow-up.

## Project Structure

```
NameYourSummons/                     <- pak this folder
  Mods/NameYourSummons/
    meta.lsx                         mod manifest (UUID, name, version)
    ScriptExtender/
      Config.json                    RequiredVersion, ModTable, feature flags
      Lua/
        BootstrapServer.lua          server entry point
        BootstrapClient.lua          client entry point
        Shared/
          Channels.lua               net channels, created in both states
          MultiSummonMode.lua        pure MultiSummonMode enum <-> control-index mapping (shared by both config UIs)
          NameWriter.lua             the two writes that do the renaming
          SummonClassifier.lua       pure tag-name -> creature-type category + per-type setting keys
          Util.lua                   uuid / sanitising / key / loca-handle helpers
        Server/
          Store.lua                  ModVar persistence
          Naming.lua                 applying names + diagnostics + reading a summon's tag names
          SummonWatcher.lua          detection, prompting, net handlers
        Client/
          Layout.lua                 viewport-relative sizing (4K-referenced) for the windows
          WindowState.lua            persist window geometry to a mod file (open-state is never persisted)
          PromptUI.lua               legacy ImGui naming prompt (GH #19 replaced it with the Examine panel; kept, no longer wired to AskName) + client loca handlers
          ConfigUI.lua               ImGui config: prompt settings (story-summon opt-in, per-creature-type filter, multi-summon mode) + saved-name, always-skipped and session-skipped managers
          NativeConfigUI.lua         native (Noesis) settings panel (viewmodel + data flow) opened by the Examine gear (see "Native Examine settings")
          NativeRenameUI.lua         native Examine-panel rename field + gear; owns panel detection and drives NativeConfigUI (see "Native Examine rename")
    GUI/                             UI-mod overlay (packed alongside ScriptExtender)
      metadata.lsf                   UI-mod marker (empty config)
      Pages/Examine.xaml             Examine.xaml override: injects the editable name field, settings gear, and native settings overlay (NYS_SettingsPanel) for summons
      StateMachines/Keyboard.xaml    overrides only the Examine state so it loads our Examine.xaml
      StateMachines/Controller.xaml  empty (no controller overrides)
```

## Reference docs

For the full tool/documentation map (BG3SE, Osiris, NoesisGUI, LSLib) and the
NoesisGUI facts an agent needs for native UI, see
[docs/bg3-modding-toolchain.md](docs/bg3-modding-toolchain.md). The essentials:

- API docs - `github.com/Norbyte/bg3se/blob/main/Docs/API.md`
- IDE helpers - `bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua` -
  the authoritative reference. Every component and ImGui widget is declared
  here. Grep it rather than guessing an API shape.
- Osiris functions / events -
  `github.com/LaughingLeader/BG3ModdingTools/tree/master/generated`
- Community wiki - `wiki.bg3.community`

## Build & Test Commands

There is no build step, and you **cannot run the game** - only the user can. Do
not claim a change works in game - you have not seen it run. When a change
depends on a BG3SE or Osiris behaviour, verify the assumption against Script
Extender console output the user pastes, or against the IDE helpers / API docs,
before relying on it.

You can, however, read the game's own files directly: LSLib's `divine.exe` (the
same tool `make.ps1 build` downloads) unpacks BG3's `.pak` files, so you can
inspect the game's real UI XAML, templates, and stats instead of guessing from
wikis. See [docs/exploring-bg3-internals.md](docs/exploring-bg3-internals.md).

There **is** a local unit-test suite (LuaUnit) covering the engine-independent
logic (`Util`, `Store`, `NameWriter`), plus static gates (StyLua, luacheck,
lua-language-server), all driven by the `./make.ps1` entrypoint and all pinned to
Lua 5.4 to match BG3SE. See "Tooling and Quality Gates" below. These verify code
correctness, never feature correctness in game.

Packaging: run `./make.ps1 build` (PowerShell). It downloads a pinned LSLib
release into `.tools/` and wraps `divine.exe -a create-package` to produce
`build/NameYourSummons-<version>.pak` plus a matching zip, both suffixed with the
mod's semantic version (`-Clean` wipes `build/` first). The Modder's Multitool
*Create Package* does the same thing by hand. Trap: divine
excludes any file whose ABSOLUTE path contains a dot-segment (e.g. a `.paseo`
worktree), silently emitting an empty pak - `make.ps1 build` stages the mod into
a dot-free temp dir to dodge this. For iteration the folder is symlinked into the
game's `Data/`, and `reset` in the SE console reloads Lua without restarting.

Releasing: the mod version is a packed `Version64` int64 in `meta.lsx` (the
`ModuleInfo` node and its nested `PublishVersion`), and is the single source of
truth - `Get-ModVersion` decodes it, `Set-ModVersion` re-encodes a semver into
it. `./make.ps1 prepare-release` bumps that version, assembles pending `news/`
fragments into `CHANGELOG.md` via [changelogging](https://github.com/nekitdev/changelogging)
(a pinned prebuilt binary fetched into `.tools/`, like every other tool),
commits `Version X.Y.Z`, and manages the `main` -> `X.Y-maintenance` branch flow
(major/minor open a `release-X.Y.Z` PR; patches commit onto the maintenance
branch). `./make.ps1 create-release-tag` validates and pushes the `X.Y.Z`
annotated tag, which fires `.github/workflows/release.yml`: it packs the `.pak`,
attests its provenance, and publishes a draft release built from
`templates/release_template.md` + the tagged `CHANGELOG.md` section. News
fragments are gated on PRs by `news-fragment-check.yml` (bypass with the
`no-news-fragment-needed` label). See CONTRIBUTING.md for the full workflow.

Diagnostic console commands (server state unless noted):

| Command | What it does |
|---|---|
| `!nys_list` | list all saved names, always-skipped and session-skipped summons |
| `!nys_diag` | dump what the game thinks each summon is named |
| `!nys_rename <name>` | rename the host's summons now, no prompt |
| `!nys_clear` | wipe all saved names and always-skip choices |
| `!nys_ui` | open the in-game config: prompt settings + saved-name, always-skipped and session-skipped managers (client state; type `client` first) |

`!nys_diag` is the primary debugging tool: it dumps the loca handle, what it
resolves to, `CustomName` if present, and the root template. Ask the user to
paste that output when a name will not stick.

## Tooling and Quality Gates

Everything is driven by a single cargo-style entrypoint, `make.ps1`, which
downloads its own pinned tooling into `.tools/` (gitignored) on first use - no
Rust or Lua build toolchain required. It runs under Windows PowerShell 5.1 and
cross-platform `pwsh`, so CI (`.github/workflows/ci.yml`) invokes the same
commands via `pwsh`.

**Every tool targets Lua 5.4 - the version BG3SE runs** - so the tooling checks
the same language the game does (integer and bitwise ops, `<const>`/`<close>`).
The interpreter (`lua54`), luacheck (built on PUC-Rio Lua 5.4), and
lua-language-server's `runtime.version` are all pinned to 5.4.

```
./make.ps1 setup         # download all tooling into .tools/
./make.ps1 format        # StyLua, writing changes in place
./make.ps1 format-check  # StyLua, verify only (diff, no writes)
./make.ps1 lint          # luacheck
./make.ps1 typecheck     # lua-language-server --check
./make.ps1 test          # LuaUnit suite
./make.ps1 build         # pack the mod into build/ (.pak + .zip); -Clean wipes first
./make.ps1 deploy        # build, then copy the .pak into BG3's %LOCALAPPDATA% Mods folder
./make.ps1 all           # format + lint + typecheck + test (verify locally)
./make.ps1 check         # format-check + lint + typecheck + test (what CI runs)
./make.ps1 changelog     # assemble news/ fragments into CHANGELOG.md (changelogging)
./make.ps1 prepare-release      # bump version, changelog, branch, commit, push, open PR
./make.ps1 create-release-tag   # tag the release commit and push (fires release.yml)
```

**To verify a change locally, run `./make.ps1 all` and nothing else.** It formats
in place and then runs every gate; a green `all` is the definition of done. (CI
runs `check`, which is identical except it verifies formatting instead of
writing it.)

| Gate | Tool | Config | Command |
|---|---|---|---|
| Format | StyLua | `.stylua.toml` | `./make.ps1 format` (verify: `./make.ps1 format-check`) |
| Lint | luacheck | `.luacheckrc` | `./make.ps1 lint` |
| Type check | lua-language-server | `.luarc.json` | `./make.ps1 typecheck` |
| Unit tests | LuaUnit | `spec/` | `./make.ps1 test` |

Notes:

- **StyLua** uses its opinionated defaults verbatim (`.stylua.toml`) - tabs,
  120 columns, Roblox Lua Style Guide. `format` writes changes in place;
  `format-check` only diffs. Do not tune the config to a personal style; the
  point of a deterministic formatter is that style is not up for debate.
- **luacheck** lints against `std = "lua54"`, so it accepts and checks every
  file including `Util.lua`'s bitwise FNV-1a (a Lua-5.4-only construct). Engine
  globals (`Ext`, `Osi`, `Mods`, `ModuleUUID`, `_C/_D/_P`) are declared in
  `.luacheckrc` as read-only; add one there if luacheck flags a real engine
  global as undefined. `spec/` has a scoped override (writable `Ext`/`Osi` for
  the stubs, `allow_defined_top` for the LuaUnit `Test*` tables). Line length is
  disabled - StyLua owns that. (Selene was evaluated and rejected: its released
  CLI cannot parse Lua 5.3/5.4 syntax - upstream PR #666 is still open.)
- **lua-language-server** type-checks from the EmmyLua annotations. `./make.ps1
  typecheck` auto-fetches the authoritative BG3SE `ExtIdeHelpers.lua` into
  `.luals-libs/` (gitignored; `.luarc.json` points `workspace.library` there)
  and gates on **Error level only**. The dynamic `Ext`/`Osi` surface produces
  unavoidable *Warnings* (undefined-field, API drift) that are useful inline in
  an editor but are not build failures. Editors read the same `.luarc.json`, so
  autocomplete works once `.luals-libs/` is populated (`./make.ps1 typecheck` or
  `setup` once).
- **LuaUnit** (a single pure-Lua file, so it bootstraps on the prebuilt Lua 5.4
  interpreter with no C-compiler dependency, unlike busted) tests only the
  engine-independent modules. `spec/spec_helper.lua` stubs the `Ext`/`Osi`
  surface and reimplements `Ext.Require` so a module and its dependencies load
  off-game; `spec/run.lua` is the runner. **Keep pure logic (key derivation,
  hashing, sanitising, ModVar shaping, the two DisplayName writes) free of
  direct engine calls so it stays testable** - push unavoidable ECS / net /
  ImGui / timing code into the thin, untested glue (`SummonWatcher`, `Naming`,
  `PromptUI`, `Channels`). When you add such logic, add a spec for it.
- The `.githooks/pre-commit` hook runs `./make.ps1 format-check` and `lint` when a
  PowerShell is available, so the ASCII-punctuation check still works without
  one. CI enforces every gate unconditionally.

## Code Standards

### Typography (ASCII punctuation only)

Do NOT use decorative or "smart" Unicode punctuation anywhere in the repo -
not in Lua, comments, docstrings, commit messages, PR descriptions, or
markdown. Use the ASCII equivalent:

- em-dash and en-dash -> single `-` (NEVER `--` in prose)
- smart quotes        -> `'` or `"`
- ellipsis            -> `...`
- arrows              -> `->`, `<-`, `<->`, etc.
- bullet / middle-dot -> `-` or `*`
- warning / other symbols -> spell it out (`WARNING`, `note:`)
- non-breaking space  -> regular space
- math glyphs         -> ASCII operators (`x`, `/`, `>=`, `<=`, `!=`)

This is enforced by `.githooks/pre-commit`. If the check fails, fix the
offending characters - do not work around the hook.

### Lua docstrings

- Use EmmyLua annotations (`---@param`, `---@return`, `---@field`) on functions
  that take or return non-obvious types. Keep the `---@param` lines - the type
  hints are what make the code navigable, since BG3SE objects are dynamically
  typed.
- A one-line `---` summary above a public helper is enough. Use the imperative
  (`Register the text ...`, not `This function registers ...`).
- Module headers use a `--[[ ... ]]` block only when the module has a
  non-obvious contract worth stating (see `Shared/NameWriter.lua`). Trivial
  modules need none.
- No docstrings on trivial locals, closures, or obvious getters.

### Inline comments

Default to no inline comments. Add a `--` comment only for:

- BG3SE / Osiris quirks and traps - cite the API doc, wiki page, or extender
  source location (e.g. the handle-and-version keying, deferred ECS ops).
- The empirical timing delays (why a wait exists, not that it waits).
- Shared-state or replication invariants (server writes replicate, client
  writes do not).

Never paraphrase the next line, narrate steps, add banner dividers, or commit
commented-out code.

```lua
-- GOOD - states a non-obvious engine invariant.
-- Loca registers at version 0; a stale version makes the lookup miss.
dn.Name.Handle.Version = 0

-- BAD - paraphrases the call.
-- Set the handle.
dn.Name.Handle.Handle = handle
```

## Development Patterns

- **Guard every SE call that can fail** with `pcall`. Entities may be dead,
  components may be absent, and a raw error tears down the Lua state. Log a
  warning and continue rather than propagating.
- **Server vs client writes**: only the server calls `e:Replicate(...)`; a
  client applies to its own local view. Get this wrong and names either do not
  propagate to co-op peers or double-apply.
- **Deterministic handles**: derive loca handles from the name text (FNV-1a),
  never from the entity. This keeps them reproducible after a load and bounded
  to one handle per distinct name.
- **Deferred ECS ops are a trap**: `entity:CreateComponent(...)` writes to the
  command buffer; the component is not present until the frame flushes, so the
  next line still reads `nil`. Prefer writing a field on a component that
  already exists.
- **Timing is empirical**: summons are not fully assembled on the tick they
  enter the level. The delays in `SummonWatcher.lua` and `Naming.lua` exist for
  that reason. If names intermittently fail on a slower machine, the delays are
  the first suspect - do not remove them.

## BG3SE-Specific Notes

- **API drift**: BG3SE tracks game builds and component layouts shift between
  patches. Field names change (e.g. `DisplayName.NameKey` was renamed to
  `.Name`; a shim resolves the old name but warns). When a field read returns
  `nil` unexpectedly, suspect a rename and check the current IDE helpers.
- **No summon-created event**: use the `EnteredLevel` -> `IsSummon` route, not
  a hypothetical `Summoned` event. The `SummonCreatedEvent` /
  `SummonOwnerSetEvent` ECS components have no structure known to SE.
- **Runtime loca is not persisted**: entries added via
  `UpdateTranslatedString` vanish on restart; re-register on `SessionLoaded`.
- **`RequiredVersion` guards the API version, not the component layout** - a
  matching version does not guarantee a field still exists.

## Testing Standards

- You cannot run the game. Reason about correctness from the code, the API
  docs, and console output the user provides. State plainly when a change needs
  in-game verification you cannot perform. For the full method - temporary
  discovery commands, instrumenting broadly when the live code path is unknown,
  and the in-game script/console-reading loop - see
  [docs/ingame-debugging.md](docs/ingame-debugging.md).
- Client input is trusted but sanitised (length-clamped, control characters
  stripped) - keep it sanitised, but do not assume it is authenticated.
- Multiplayer is wired (`SendToClient(payload, ownerGuid)` targets only the
  summoner) but untested; flag changes that could affect the co-op path.

## Commit Messages

Follow the conventions in
[`.claude/skills/commit/SKILL.md`](.claude/skills/commit/SKILL.md).
AI-generated commits MUST include a `Co-authored-by:` trailer naming the
model.

## User Interaction

- Clarify open questions before starting work.
- Identify and resolve ambiguities and assumptions up front.
- Because you cannot test in game, surface the exact console command
  (`!nys_diag`, `!nys_rename`, etc.) the user should run to confirm a change.

## GitHub Pull Requests

Both PR creation and addressing review feedback are covered in
[`.claude/skills/github-pr/SKILL.md`](.claude/skills/github-pr/SKILL.md).
When addressing feedback: reply to every unresolved review comment, mark each
thread resolved once addressed, and push to update the PR.

## Git over SSH

The `origin` remote uses SSH. On this machine only PowerShell can spawn `ssh`;
the bundled bash fails with `cannot spawn ssh`. Run any command that reaches the
remote (`git fetch`, `git push`, SSH-backed `gh`) from PowerShell.

## Completion Checklist

Before considering any task complete, first self-review your changes by
running [`/scrutinize`](.claude/skills/scrutinize/SKILL.md) on them. Then
confirm:

1. Documentation (README, this file, docstrings) is accurate for the change.
2. No forbidden Unicode punctuation (the pre-commit hook passes).
3. Every fallible SE call is `pcall`-guarded.
4. Server/client replication is correct for any renaming path touched.
5. `./make.ps1 all` passes - this single command (format, lint, type check,
   LuaUnit tests) is how you verify a change locally; do not run the gates
   piecemeal. If you cannot run it, reason through each gate and say so. Add or
   update a spec when you change testable logic.
6. Any behaviour you could not verify in game is called out explicitly, with
   the console command the user should run to confirm it.
