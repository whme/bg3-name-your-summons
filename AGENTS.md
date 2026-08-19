# Name Your Summons - Agent Instructions

A Baldur's Gate 3 mod that names a summoned creature and reapplies the name the next
time it is summoned. Pure Lua on Norbyte's Script Extender (BG3SE), API v30;
`./make.ps1` drives every gate and packs the pak.

**The user runs the game; you do not.** Verify every BG3SE / Osiris assumption
against the IDE helpers, the API docs, or console output the user pastes, and hand
back the exact console command that would confirm the change in play.

## Read before you touch

Read your row's doc BEFORE the first edit - the docs carry the architecture, the
code and its inline comments carry the detail.

| About to touch | Read first |
|---|---|
| Anything under `Lua/Client/` or `GUI/` | [docs/native-ui.md](docs/native-ui.md), THEN [docs/examine-panel.md](docs/examine-panel.md) |
| `Lua/Server/` or `Lua/Shared/` behaviour, or a user-facing string | [docs/architecture.md](docs/architecture.md) |
| `make.ps1`, `.github/workflows/`, a gate | [docs/build-and-gates.md](docs/build-and-gates.md) |
| Asking the user to run the game, or reading their console output | [docs/ingame-debugging.md](docs/ingame-debugging.md) |
| A fact about BG3's own XAML, stats, templates, or paks | [docs/exploring-bg3-internals.md](docs/exploring-bg3-internals.md) |
| An `Ext.*` / `Osi.*` / Noesis API shape you are unsure of | [docs/bg3-modding-toolchain.md](docs/bg3-modding-toolchain.md) |

Full index: [docs/README.md](docs/README.md). Contributor setup and releases:
[CONTRIBUTING.md](CONTRIBUTING.md).

## Principles

Naming and state:

- Rename through a loca handle of the mod's own, never the template's shared handle;
  re-register handles on load. The server writes and replicates names; the client
  re-registers the text.
- Guard every fallible SE / Osiris call with `pcall` - a raw error tears down the Lua
  state.
- Respect the empirical delays around a fresh summon; it is not assembled the instant
  it enters the level.

Native UI:

- Fetch every Noesis handle fresh and test it with truthiness - handles expire
  between frames.
- Anchor scans at a known node and re-wire on events, never poll; detect UI
  lifecycle from a persistent widget you own, never a global input hook.
- Read data contexts from the property bag, prefix every view-model field, and make
  writes idempotent (they dispatch asynchronously).
- Add every control to both the keyboard and controller page, using the game's own
  focusable styles; commit an edited name from the field's own debounced handler, not
  on focus loss.

The reasoning behind each lives in the doc your routing row names; the specific traps
live in inline comments at their call sites.

## Workflow

1. Clarify open questions and resolve ambiguities before starting.
2. Read your routing row's doc, then the module header of the file you are changing.
3. Implement. Keep pure logic engine-free so it stays testable; push ECS, net,
   native-UI, and timing code into the thin glue. Add or update a spec when testable
   logic changes.
4. **Run `./make.ps1 all` - that is the definition of done**, not the gates piecemeal.
   The divine-dependent gates are Windows-only and also run in CI; run them locally on
   Windows if you touched loca, XAML, or the pak layout. If you cannot run a gate,
   reason through it and say so.
5. Self-review with `/workflows:scrutinize`.
6. Update the docs for any behaviour you changed, in THIS PR - high-level only.
7. Call out explicitly whatever you could not verify in game, and name the exact
   console command the user should run.

`./make.ps1 deploy` builds the pak into BG3's Mods folder. A Lua-only change needs an
SE `reset`; a XAML, asset, or packaging change needs a full restart. Say which every
time.

## Code standards

**Typography: ASCII punctuation only**, everywhere in the repo. em/en-dash -> `-`
(never `--` in prose); smart quotes -> `'`/`"`; ellipsis -> `...`; arrows -> `->`;
symbols spelled out; math glyphs -> ASCII. Enforced by `.githooks/pre-commit`.

**Docstrings and comments.** EmmyLua annotations on functions with non-obvious types.
Default to NO inline comments - add a `--` only for a genuine BG3SE / Osiris quirk (a
non-obvious engine fact or trap), an empirical timing delay, or a replication
invariant. Never paraphrase the next line, narrate steps, or commit commented-out
code. Inline comments are where the low-level detail belongs.

## Commit conventions

Use the `/workflows:commit` skill. Three blocks separated by blank lines: subject,
body, Git trailers.

- **Scope prefix**: optional lowercase `scope:` matching the code layout (`server:`,
  `client:`, ...); do not invent scopes.
- **Subject**: imperative, no trailing period, under ~72 chars. Never pre-append a PR
  number.
- **Body**: WHY, plus the observable in-game behaviour before/after. Wrap ~76.
- **References**: footer only - `GitHub: #<n>`, or `Closes #<n>` when it fully
  resolves an issue.
- **AI co-authorship (MANDATORY)**: exactly one lowercase `Co-authored-by:` trailer
  naming the model, e.g. `Co-authored-by: Claude Opus 4.7 <noreply@anthropic.com>`.

## Pull requests

Use the `/workflows:github-pr` skill.

- `gh pr create --fill` derives title and body from the commit. For a user-facing
  change, note the in-game verification done or the console command a reviewer runs.
- Every PR MUST add a `news/<id>.<type>.md` fragment OR carry `no-news-fragment-needed`.
- Reply to every unresolved review thread and resolve it only after the fix is pushed.
- **Sanctioned rebase**: rebasing the PR's OWN branch onto its base and
  `--force-with-lease` pushing is allowed. Never force-push `main`, never plain
  `--force`, never `--amend` commits already pushed.

## Git over SSH

Run anything that reaches `origin` from PowerShell - it is the only shell here that
can spawn `ssh`; the bundled bash fails with `cannot spawn ssh`.
