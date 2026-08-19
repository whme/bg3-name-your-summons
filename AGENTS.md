# Name Your Summons - Agent Instructions

A Baldur's Gate 3 mod that names a summoned creature and reapplies the name the
next time it is summoned. Pure Lua on Norbyte's Script Extender (BG3SE), API v30;
`./make.ps1` drives every gate and packs the pak.

**The user runs the game; you do not.** Verify every BG3SE / Osiris assumption
against the IDE helpers, the API docs, or console output the user pastes, and
hand back the exact console command that would confirm the change in play.

## Read before you touch

Read your row's doc BEFORE the first edit, not after the first failure: a wrong
guess costs the user a build, a restart, and a reproduction.

| About to touch | Read first |
|---|---|
| Anything under `Lua/Client/` or `GUI/` | [docs/native-ui.md](docs/native-ui.md), THEN [docs/examine-panel.md](docs/examine-panel.md) |
| `Lua/Server/` or `Lua/Shared/` behaviour | [docs/architecture.md](docs/architecture.md) |
| A user-facing string | [docs/architecture.md](docs/architecture.md) - three files change in lockstep |
| `make.ps1`, `.github/workflows/`, a gate | [docs/build-and-gates.md](docs/build-and-gates.md) |
| Asking the user to run the game, or reading their console output | [docs/ingame-debugging.md](docs/ingame-debugging.md) |
| A fact about BG3's own XAML, stats, templates, or paks | [docs/exploring-bg3-internals.md](docs/exploring-bg3-internals.md) |
| An `Ext.*` / `Osi.*` / Noesis API shape you are unsure of | [docs/bg3-modding-toolchain.md](docs/bg3-modding-toolchain.md) - grep the IDE helpers, do not guess |

Full index: [docs/README.md](docs/README.md). Contributor setup and releases:
[CONTRIBUTING.md](CONTRIBUTING.md).

## Rules

Each is an action to take. The trailing clause is what it costs to do otherwise;
the full reasoning is in the doc your routing row names.

Naming and state:

1. Register your own loca handle with `Ext.Loca.UpdateTranslatedString`, then
   point `DisplayName.Name.Handle` at it with `Version = 0`. Writing the
   template's shared handle renames EVERY creature from that template, in every
   save, until the game restarts.
2. Re-register every saved name's handle on `SessionLoaded` before reapplying
   names; runtime loca does not survive a restart.
3. Write `DisplayName` on the server and replicate it, and broadcast the text
   separately for peers to re-register - replication carries the handle, not the
   text, so a name that arrives without its text renders blank.
4. Wrap every SE / Osiris call that can fail in `pcall`, log a warning, and
   continue; a raw error tears down the Lua state.
5. Write a field on a component that already exists. `entity:CreateComponent()`
   is deferred, so the next line still reads `nil`.
6. Leave the delays in `SummonWatcher.lua` and `Naming.lua` alone - they are
   empirical, and a summon is not assembled on the tick it enters the level.

Noesis and native UI:

7. Fetch every Noesis node, DataContext, viewmodel, and command fresh at each
   use; a cached handle expires across ticks.
8. Test a Noesis object with truthiness; `== nil` routes through `__eq`, which
   throws on an expired object.
9. Anchor every scan at `ContentRoot`, take direct children or one bounded named
   subtree, and re-wire on events - a per-second walk is what SE profiled as a
   hitch.
10. Detect UI lifecycle from a persistent widget you own
    ([docs/native-ui.md](docs/native-ui.md)). A global input hook walks whatever
    tree is on screen and crashed on character creation's (#99).
11. Read DataContexts with `GetAllProperties()`, reserving `GetProperty` for a
    single already-matched object; scanning with it costs 238-510 ms per Examine
    open.
12. Prefix every SE viewmodel field `Nys`, so it cannot alias
    `FrameworkElement.Name` and round-trip the literal string.
13. Rebuild the viewmodel to clear a `Collection`; `coll[i] = nil` removes one
    element in place.
14. Make viewmodel writes idempotent - WriteCallbacks dispatch async, so a
    synchronous re-entry flag cannot guard them.
15. Commit an edited name from the field's own debounced `TextChanged`
    subscription; blur is not reliably delivered, least of all on controller.
16. Add every Examine control to BOTH `Examine.xaml` and `Examine_c.xaml`, and
    style a controller-navigable one with the game's
    `FocusableButtonStyleMinimal` - a custom template drops the focus wiring and
    the button becomes unreachable.

## Workflow

1. Clarify open questions and resolve ambiguities before starting.
2. Read your routing row's doc, then the module header of the file you are
   changing - the contract is usually stated there.
3. Implement. Keep pure logic engine-free so it stays testable; push ECS, net,
   native-UI, and timing code into the thin glue. Add or update a spec when
   testable logic changes.
4. **Run `./make.ps1 all` - that is the definition of done**, not the gates
   piecemeal. `./make.ps1 help` lists every command; do not trust a copy of that
   list in prose. The divine-dependent gates are Windows-only and also run in CI
   ([docs/build-and-gates.md](docs/build-and-gates.md)); run them locally on
   Windows if you touched loca, XAML, or the pak layout. If you cannot run a
   gate, reason through it and say so.
5. Self-review with `/workflows:scrutinize`.
6. Update the docs for any behaviour you changed, in THIS PR. UI rules go in
   [docs/native-ui.md](docs/native-ui.md).
7. Call out explicitly whatever you could not verify in game, and name the exact
   console command the user should run (`!nys_diag`, `!nys_rename`, ...).

`./make.ps1 deploy` builds the pak into BG3's Mods folder. A Lua-only change
needs an SE `reset`; a XAML, asset, or packaging change needs a full restart. Say
which one every time.

## Code Standards

### Typography (ASCII punctuation only)

Do NOT use decorative or "smart" Unicode punctuation anywhere in the repo - not
in Lua, comments, docstrings, commit messages, PR descriptions, or markdown:

- em-dash and en-dash -> single `-` (NEVER `--` in prose)
- smart quotes -> `'` or `"`; ellipsis -> `...`; arrows -> `->`, `<-`, `<->`
- bullet / middle-dot -> `-` or `*`; non-breaking space -> regular space
- warning / other symbols -> spell it out (`WARNING`, `note:`)
- math glyphs -> ASCII operators (`x`, `/`, `>=`, `<=`, `!=`)

Enforced by `.githooks/pre-commit`. If the check fails, fix the characters - do
not work around the hook.

### Docstrings and comments

EmmyLua annotations (`---@param`, `---@return`, `---@field`) on functions taking
or returning non-obvious types - the hints are what make dynamically-typed BG3SE
objects navigable. A one-line imperative `---` summary above a public helper is
enough; a `--[[ ... ]]` module header only when the module has a non-obvious
contract (see `Shared/NameWriter.lua`); none on trivial locals or getters.

Default to NO inline comments. Add a `--` comment only for a BG3SE / Osiris quirk
or trap (cite the source), an empirical timing delay (why it exists, not that it
waits), or a replication invariant. Never paraphrase the next line, narrate
steps, add banner dividers, or commit commented-out code.

```lua
-- GOOD - states a non-obvious engine invariant.
-- Loca registers at version 0; a stale version makes the lookup miss.
dn.Name.Handle.Version = 0

-- BAD - paraphrases the call.
dn.Name.Handle.Handle = handle
```

## Commit conventions

Use the `/workflows:commit` skill (the `workflows@whmade` plugin); it reads this
section. Three blocks separated by blank lines: subject, body, Git trailers.

- **Scope prefix**: optional lowercase `scope:` when the change is confined to
  one area, using only scopes matching the code layout (`server:`, `client:`,
  `NameWriter:`, `prompt:`). Do not invent scopes.
- **Subject**: imperative, capitalized when unscoped, no trailing period, under
  ~72 chars. Never pre-append a PR number - squash-merge adds it.
- **Body**: WHY, plus the observable in-game behaviour before/after. No gate
  proves in-game behaviour, so the body is where the reasoning lives. Wrap ~76.
- **References**: footer only, one per line - `GitHub: #<n>`, or `Closes #<n>`
  only when the change fully resolves an issue.
- **AI co-authorship (MANDATORY)**: exactly one lowercase `Co-authored-by:`
  trailer naming the model, e.g.
  `Co-authored-by: Claude Opus 4.7 <noreply@anthropic.com>`.

## Pull requests

Use the `/workflows:github-pr` skill for creation and review feedback; it reads
this section.

- `gh pr create --fill` derives title and body from the commit; hold them to the
  same bar. For a user-facing change, note the in-game verification done or the
  console command a reviewer should run.
- Every PR MUST add a `news/<id>.<type>.md` fragment (`feature`, `bugfix`,
  `security`, `deprecation`, `removal`) OR carry `no-news-fragment-needed`.
- Reply to every unresolved review thread - even when the fix is "done in commit
  abc123" - and resolve it only after the fix is pushed and replied to.
- **Sanctioned rebase**: rebasing the PR's OWN branch onto its base
  (`origin/<baseRefName>` - a patch-release PR targets `X.Y-maintenance`, not
  `main`) and `--force-with-lease` pushing it is allowed. Never force-push
  `main`, never plain `--force`, never `--amend` commits already pushed.

## Git over SSH

Run anything that reaches the `origin` remote (`git fetch`, `git push`,
SSH-backed `gh`) from PowerShell - it is the only shell here that can spawn
`ssh`; the bundled bash fails with `cannot spawn ssh`.
