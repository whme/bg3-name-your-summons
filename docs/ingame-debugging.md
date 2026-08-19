# Debugging and exploring in game

You **cannot run Baldur's Gate 3.** The user runs it; you write instrumented Lua,
agree on the exact in-game steps, and reason from the Script Extender console
output the user pastes back. Every game run costs the user a full restart, so
**make each run count**: never claim something works in game without a pasted log
that proves it, and batch your investigation so one run answers many questions.

## The workflow

1. **Understand the goal.** Pin down the broad objective (e.g. "native text
   input on the Examine screen") fully before touching code.
2. **Research and reason.** Work out which approaches are viable, what facts you
   need to confirm each, and how to procure them (extract the game's files, probe
   live state, read the API/source).
3. **Instrument as broadly as you can**, so one run gives the full picture -
   every candidate event/field logged (gated behind `DEBUG`).
4. **Agree a runbook with the user**: the exact, ordered steps they will take in
   game, and what each should log - so you know which lines to expect and,
   crucially, what a *missing* line means.
5. **Analyze, reshape, repeat** until it works.

### Deploy and reload

The mod is installed one way: **build the `.pak` (`./make.ps1 build`) and drop it
in `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\`.** Then:

- **Lua-only change** -> the user types `reset` in the SE console (reloads Lua
  without restarting the game). Fast.
- **XAML / asset / packaging change** -> the user must **fully restart BG3**;
  `reset` does not reload UI or repack assets.

State which one every time, so the user never tests a stale build.

### Agree on the in-game steps

You cannot see the run, so a shared, explicit script is what makes a missing log
line *signal* instead of ambiguity. Have the user confirm the exact sequence and
what each step should produce. A real example the user settled on:

> Summon the cat familiar; name it on the prompt.
> Right-click the cat -> Examine. Click the name field, type "Findus", press
> Enter, hover the portrait to check the rename took, click the gear. Close
> Examine, reopen it, and repeat the rename. Then paste the full log.

## Instrument broadly

When you do not know which engine event/field/path is live, **do not subscribe to
one guess - subscribe to the whole candidate set**, each handler logging when it
fires and with what payload. One run then shows which paths are real instead of
costing one restart per guess. Example battery for a stuck focus event:

```
GotFocus, LostFocus, GotKeyboardFocus, LostKeyboardFocus,
PreviewGot/LostKeyboardFocus, KeyDown, PreviewKeyDown, KeyUp,
TextInput, PreviewTextInput, MouseLeft*, MouseDown, MouseUp
```

Gate verbose output behind `local DEBUG = true` / a `dbg(...)` helper so you can
silence and strip it before shipping.

## Isolate a failure with a verbatim variant

When a subsystem fails and you cannot tell if the cause is your edits or the
mechanism, ship the **minimal / byte-for-byte variant** to bisect. For example,
when an Examine override will not load, shipping an unmodified copy of Larian's
own page proves whether the mechanism works and isolates the fault to the added
controls. One decisive experiment beats another speculative edit.

## Confirm engine facts from source, not stale helpers

The BG3SE IDE helpers (`ExtIdeHelpers.lua`) and wikis lag the installed build.
When a `Subscribe`/field read returns nothing and you suspect a rename, confirm
the real name from the extender source (code-search `bg3se` for the
`ThrowEvent("...")` site). e.g. the live client event is
`Ext.Events.MouseButtonInput`, not the helper's stale `EclLuaMouseButton`; since
`Ext.Events` is not enumerable, only the source has it.

## Watch performance

You cannot feel frame hitches. For example, a loop that walked the Examine visual
tree every 500ms (each walk ~2s) hung the game; do the expensive lookup once, on
click. Keep diagnostics cheap, early-return when the relevant panel is closed,
and prefer an event subscription over a poll. If the user reports sluggishness,
suspect your instrumentation first.

## Reading the console

The SE console is a separate window that stays up while the game runs. Signals:

- **Startup header** - `BG3Ext v32`, `Game version v4.73.98.727 OK`, `SE v30`
  (version drives asset layout and API surface; see the internals guide).
- **`[ModName]` lines** - your own log output.
- **Console context** - commands exist only in the state that registered them.
  The console starts in `server`; `client` switches it (`S >>` -> `C >>`). A
  client command that "does not exist" usually means the wrong context; register
  it server-side and bounce it over a net channel to work from either prompt.
- **Engine errors are literal - read them as facts:**
  - `Object ls.DCExamine has no property named 'X'` -> `X` is on a child
    view-model, not that one (and it confirms the real type name).
  - `Failed to find statemachine for UI mod` -> a UI mod must ship state
    machines, not just a page.
  - `UI State verification failed ... state 'X'` -> that page failed to parse
    (often an unresolved `StaticResource` or an unstyled bare control).

## Console commands

Server state unless noted. Ask the user to run the one that answers your
question, and to paste the output verbatim.

| Command | What it does |
|---|---|
| `!nys_list` | list all saved names |
| `!nys_diag` | dump what the game thinks each summon is named |
| `!nys_rename <name>` | rename the host's summons now, no prompt |
| `!nys_clear` | wipe all saved names |
| `!nys_debug` | toggle debug console logging (registered in BOTH states so one call flips both) |
| `!nys_trace` | toggle full-detail JSONL tracing (registered in BOTH states; run from the matching console context) |
| `!nys_uidump` | (client) dump the visual-tree landmark map to `nys-trace-client.jsonl`; forces tracing on |

**`!nys_diag` is the primary debugging tool**: it dumps the loca handle, what it
resolves to, `CustomName` if present, and the root template. Ask for that output
when a name will not stick.

`!nys_uidump` dumps named nodes plus depth, and the per-namescope `:Find` reach
for each landmark. It is the authority for the tree depths in
[examine-panel.md](examine-panel.md) - re-run it rather than guessing after a
game patch, and use it to plan a shallower node anchor.

## Tracing

`Shared/Trace.lua` writes every channel payload (both directions), watcher
decision, store write, and swallowed `pcall` failure as one JSON line per event
to `nys-trace-client.jsonl` / `nys-trace-server.jsonl` in
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\`, flushed per
line so the record survives a crash.

It is OFF by default; toggle it on with `!nys_trace` (in both states) when
reproducing an issue, then ask the user for both files instead of pasted console
excerpts.

## Logging policy

Console logging is quiet by default (issue #106). Each state prints ONE startup
line (`Util.Say` with the mod version plus "loaded successfully"); after that
only warnings (`Util.Warn`) and user-invoked command output (`Util.Say`) print.
Routine info (`Util.Log` - "Named ...", "Saved name ...", "Reapply ...") is gated
behind `!nys_debug`.

So new routine tracing goes through `Util.Log` (hidden unless debugging), and
anything a console command prints for the user must use `Util.Say`.

## What you can and cannot prove offline

`./make.ps1 all` proves code correctness, never feature correctness in game. The
unit suite covers only the engine-independent logic; everything touching ECS,
net, native UI, or timing is in untested glue. See
[build-and-gates.md](build-and-gates.md) for what each gate does not prove.

State plainly when a change needs in-game verification you cannot perform, and
name the exact console command the user should run to confirm it.

## Before you finish

Strip all `TEMPORARY` discovery tooling and turn off (or remove) `DEBUG` logging
once the feature works - the throwaway commands, bridges, and verbose logs should
never reach the PR.
