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
  written into the savegame. `PersistentVars` is deprecated and not used.
- **Stable key**: a summon's UUID changes every conjure, so the key is
  `"<owner uuid>|<root template>"` (`Util.MakeKey`). Runtime loca entries do
  not survive a restart, so every saved name's handle is re-registered on
  `SessionLoaded` before names are reapplied. Handles are derived from the name
  text (FNV-1a), which is what makes that re-registration possible without
  finding the entity first.

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
          NameWriter.lua             the two writes that do the renaming
          Util.lua                   uuid / sanitising / key / loca-handle helpers
        Server/
          Store.lua                  ModVar persistence
          Naming.lua                 applying names + diagnostics
          SummonWatcher.lua          detection, prompting, net handlers
        Client/
          PromptUI.lua               ImGui prompt + saved-name manager
```

## Reference docs

- API docs - `github.com/Norbyte/bg3se/blob/main/Docs/API.md`
- IDE helpers - `bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua` -
  the authoritative reference. Every component and ImGui widget is declared
  here. Grep it rather than guessing an API shape.
- Osiris functions / events -
  `github.com/LaughingLeader/BG3ModdingTools/tree/master/generated`
- Community wiki - `wiki.bg3.community`

## Build & Test Commands

There is no build step and no local test suite. You **cannot run the game**;
only the user can. Do not claim a change works in game - you have not seen it
run. When a change depends on a BG3SE or Osiris behaviour, verify the
assumption against Script Extender console output the user pastes, or against
the IDE helpers / API docs, before relying on it.

Packaging: run `./build.ps1` (PowerShell). It downloads a pinned LSLib release
into `.tools/` and wraps `divine.exe -a create-package` to produce
`build/NameYourSummons.pak` plus a zip. The Modder's Multitool *Create Package*
does the same thing by hand. Trap: divine excludes any file whose ABSOLUTE path
contains a dot-segment (e.g. a `.paseo` worktree), silently emitting an empty
pak - `build.ps1` stages the mod into a dot-free temp dir to dodge this. For
iteration the folder is symlinked into the game's `Data/`, and `reset` in the
SE console reloads Lua without restarting.

Diagnostic console commands (server state unless noted):

| Command | What it does |
|---|---|
| `!nys_list` | list all saved names |
| `!nys_diag` | dump what the game thinks each summon is named |
| `!nys_rename <name>` | rename the host's summons now, no prompt |
| `!nys_clear` | wipe all saved names |
| `!nys_ui` | open the saved-names manager (client state; type `client` first) |

`!nys_diag` is the primary debugging tool: it dumps the loca handle, what it
resolves to, `CustomName` if present, and the root template. Ask the user to
paste that output when a name will not stick.

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
  in-game verification you cannot perform.
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
5. Any behaviour you could not verify in game is called out explicitly, with
   the console command the user should run to confirm it.
