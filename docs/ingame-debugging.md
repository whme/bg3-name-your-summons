# Debugging and exploring in game

The user runs Baldur's Gate 3. You write the instrumented Lua, agree the exact
in-game steps, and reason from the Script Extender console output and trace
files the user pastes back. Every run costs the user a full restart, so make
each one count: batch the investigation so a single run answers many questions,
and back every "this works in game" claim with a pasted log that shows it.

## The workflow

1. **Understand the goal.** Pin down the broad objective (e.g. "native text
   input on the Examine screen") fully before touching code.
2. **Research and reason.** Work out which approaches are viable, what facts you
   need to confirm each, and how to procure them (extract the game's files, probe
   live state, read the API/source).
3. **Instrument as broadly as you can**, so one run gives the full picture -
   every candidate event/field logged (gated behind `DEBUG`).
4. **Agree a runbook with the user**: the exact, ordered steps they will take in
   game and what each should log, so an expected line that never appears is
   itself an answer.
5. **Analyze, reshape, repeat** until it works.

### Deploy and reload

Install the mod one way: build the `.pak` (`./make.ps1 build`) and drop it in
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\`. Then:

- **Lua-only change** -> have the user type `reset` in the SE console, which
  reloads Lua in place. Fast.
- **XAML, asset, or packaging change** -> have the user fully restart BG3.

Say which one applies every time, so the user never tests a stale build.

Collect the trace files BEFORE asking for a reload: a `reset` returns both
`!nys_debug` and `!nys_trace` to OFF and the new state's first line overwrites
the trace file. Re-enable both toggles after the reload.

### Agree on the in-game steps

Have the user confirm the exact ordered sequence and what each step should
produce, so you know which lines to expect and a missing one is signal. A real
example the user settled on:

> Summon the cat familiar; name it on the prompt.
> Right-click the cat -> Examine. Click the name field, type "Findus", press
> Enter, hover the portrait to check the rename took, click the gear. Close
> Examine, reopen it, and repeat the rename. Then paste the full log.

## Instrument broadly

When the live engine event/field/path is still unknown, subscribe to the whole
candidate set at once, each handler logging when it fires and with what payload.
One run then shows which paths are real, instead of costing one restart per
guess. Example battery for a stuck focus event:

```
GotFocus, LostFocus, GotKeyboardFocus, LostKeyboardFocus,
PreviewGot/LostKeyboardFocus, KeyDown, PreviewKeyDown, KeyUp,
TextInput, PreviewTextInput, MouseLeft*, MouseDown, MouseUp
```

Gate verbose output behind `local DEBUG = true` / a `dbg(...)` helper so you can
silence and strip it before shipping.

## Isolate a failure with a verbatim variant

When a subsystem fails and you cannot tell whether the cause is your edits or
the mechanism, ship the **minimal / byte-for-byte variant** to bisect. When an
Examine override will not load, ship an unmodified copy of Larian's own page:
that proves whether the mechanism works and isolates the fault to the added
controls. One decisive experiment beats another speculative edit.

## Confirm event and field names against the extender source

Before you build on an event or field name, confirm it against the extender
source: code-search `bg3se` for the `ThrowEvent("...")` site and use the name
thrown there. The source is the one readable listing of `Ext.Events`, and it is
what resolves the live client event to `Ext.Events.MouseButtonInput` over the
helpers' stale `EclLuaMouseButton`. Treat `ExtIdeHelpers.lua` and the wikis as
the starting point and settle the name in the source.

## Keep diagnostics cheap

Do the expensive lookup once, on a real signal, and prefer an event
subscription to a poll. Early-return as soon as the relevant panel is closed, so
a handler that does fire costs nothing. A single Examine visual-tree walk runs
~2s, so a repeating one hangs the game. If the user reports sluggishness,
suspect your instrumentation first.

## Reading the console

The SE console is a separate window that stays up while the game runs. Read it
for these:

- **Startup header** - the extender build and a `Game version ... OK` line. Note
  the game version; it drives asset layout and API surface (see
  [exploring-bg3-internals.md](exploring-bg3-internals.md)).
- **Our startup lines** - `[NameYourSummons] Name Your Summons vX.Y.Z loaded
  successfully (server).` and the `(client)` twin. Check both are present before
  reading anything below them: when one is missing, fix that state's load error
  first, because nothing it registered will fire.
- **`[NameYourSummons]` prefix** - all of our output carries it; filter on it.
- **Console context** - a command lives in the state that registered it. The
  console starts in `server`; typing `client` switches it (`S >>` -> `C >>`).
  When a command reports as unknown, switch context and repeat it there:
  `!nys_uidump` is client-side, the two toggles live in both states, everything
  else is server-side.

Engine errors are literal. Read each as a symptom and act:

- `Object ls.DCExamine has no property named 'X'` -> read `X` off the child
  view-model, and take `ls.DCExamine` as the confirmed type name.
- `Failed to find statemachine for UI mod` -> ship the state machines
  (`StateMachines/Keyboard.xaml` and `Controller.xaml`) alongside the page.
- `UI State verification failed ... state 'X'` -> fix that page's parse error;
  start with unresolved `StaticResource` keys and bare unstyled controls, then
  re-run `./make.ps1 xaml-check`.

## Console commands

Ask the user to run the one that answers your question, and to paste the output
verbatim.

| Command | State | What it does |
|---|---|---|
| `!nys_list` | server | list every saved name, unique sets one row per slot |
| `!nys_diag` | server | dump what the game thinks each of the HOST's summons is named |
| `!nys_rename <name>` | server | rename the host's summons on the spot, no prompt |
| `!nys_reapply` | server | re-run the session-load reapply pass without reloading |
| `!nys_clear` | server | wipe all saved names and this session's "already asked" state |
| `!nys_debug` | both | toggle routine `Util.Log` output |
| `!nys_trace` | both | toggle JSONL tracing |
| `!nys_uidump` | client | dump the visual-tree landmark map to the client trace file |

`!nys_debug` and `!nys_trace` are registered in each state, so one invocation
flips both. Each state answers with its own tag (`(server)` / `(client)`, plus
the trace file name); when only one tag comes back, have the user switch context
and repeat the command there.

**Reach for `!nys_diag` first when a name will not stick.** It prints the whole
handle chain (the `DisplayName` handle, its version, and what that handle
currently resolves to) next to `CustomName`, the root template, and Osiris' own
summon/owner verdicts. It covers the **host character's** summons only - to
diagnose a co-op peer's or a second split-screen player's, you need a different
route - and with no host summons out it diagnoses the host character instead.

Use `!nys_rename` to test the rename primitive in isolation from detection and
persistence: it writes to the live creature only, so the summon reverts on the
next conjure.

Turn on `!nys_debug` before `!nys_reapply`; it reports through `Util.Log`.

Run `!nys_uidump` with the world up (`Running` / `Paused`) and ask for the file
rather than a paste: it writes to `nys-trace-client.jsonl`, forcing tracing on
for the dump and restoring the previous setting afterwards. It is the authority
for the tree depths in [examine-panel.md](examine-panel.md) - re-run it after a
game patch, and use it to plan a shallower node anchor.

## Tracing

Tracing writes one JSON line per event to `nys-trace-server.jsonl` /
`nys-trace-client.jsonl` in `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script
Extender\`. It is OFF by default. When an issue is reproducible, have the user
enable it with `!nys_trace`, run the agreed steps, and send **both** files. They
beat pasted console excerpts: every net payload, watcher decision and store
write is in them with its payload intact, and the last line before a crash is
already on disk.

Keep the repro short: the trace buffer caps at 8000 lines and drops the oldest,
so a long session pushes the interesting lines out.

## Logging policy

Console logging is quiet by default (issue #106) so the user's console stays
readable and the startup lines above stay visible. Respect that split when you
add output:

- `Util.Log` - routine progress, shown while `!nys_debug` is on. Use it for
  anything that fires on its own.
- `Util.Say` - always prints. Reserve it for console-command output the user
  asked for, and the one startup line per state.
- `Util.Warn` - always prints. Use it for a real failure the user should see
  unprompted.
- `Trace.Log` - diagnosis only. Costs nothing while tracing is off and keeps the
  payload structured, so prefer it over a `Util.Log` you will delete later.

To make a debugging session easier, turn on `!nys_debug` and leave the line at
`Util.Log`.

## Where to settle a question

Answer each question in the cheapest place that can answer it:

- **Code correctness** (format, lint, types, pure logic) - `./make.ps1 all`. See
  [build-and-gates.md](build-and-gates.md) for what each gate covers.
- **Game data facts** (real XAML, templates, stats, asset paths) - unpack the
  game's own paks and read them, per
  [exploring-bg3-internals.md](exploring-bg3-internals.md).
- **ECS, net, native UI, and timing behaviour** - an in-game run. Say so
  plainly, and name the exact console command the user should run to confirm it.

## Before you finish

Strip all `TEMPORARY` discovery tooling and turn off (or remove) `DEBUG` logging
once the feature works - the throwaway commands, bridges, and verbose logs should
never reach the PR.
