# Debugging and exploring in game

You **cannot run Baldur's Gate 3.** The user runs it; you write instrumented Lua,
agree on the exact in-game steps, and reason from the Script Extender console
output the user pastes back. Every game run costs the user a full restart, so
**make each run count**: never claim something works in game without a pasted log
that proves it, and batch your investigation so one run answers many questions.

## The loop

1. Form specific questions ("which event fires when the field is left?"), not
   vague ones ("why is rename broken?").
2. Instrument for **all** current theories at once - one build that logs every
   path you are unsure about, so a single run decides between them.
3. Agree with the user on the exact in-game steps before they run (see below).
4. Read the pasted console output; change one thing based on evidence; repeat.

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

> Summon the cat familiar; name it on the prompt; wait out turn-based mode.
> Right-click the cat -> Examine. Click the name field, type "Findus", press
> Enter, hover the portrait to check the rename took, click the gear. Close
> Examine, reopen it, and repeat the rename. Then paste the full log.

## Instrument broadly, and timestamp everything

When you do not know which engine event/field/path is live, **do not subscribe to
one guess - subscribe to the whole candidate set**, each handler logging when it
fires and with what payload. One run then shows which paths are real instead of
costing one restart per guess. Example battery for a stuck focus event:

```
GotFocus, LostFocus, GotKeyboardFocus, LostKeyboardFocus,
PreviewGot/LostKeyboardFocus, KeyDown, PreviewKeyDown, KeyUp,
TextInput, PreviewTextInput, MouseLeft*, MouseDown, MouseUp
```

- **Prefix every log line with a UTC timestamp at microsecond precision**
  (`%Y-%m-%d %H:%M:%S.%f %z`, the format used elsewhere in these repos). Ordering
  and inter-event gaps are what expose races - the fast-typing truncation bug in
  #9 was only visible from timestamps.
- Gate verbose output behind `local DEBUG = true` / a `dbg(...)` helper so you
  can silence and strip it before shipping.

## Isolate a failure with a verbatim variant

When a subsystem fails and you cannot tell if the cause is your edits or the
mechanism, ship the **minimal / byte-for-byte variant** to bisect. In #9 the
Examine override would not load; shipping an unmodified copy of Larian's own page
loaded fine, proving the override mechanism worked and the fault was in the added
controls. One decisive experiment beats another speculative edit.

## Confirm engine facts from source, not stale helpers

The BG3SE IDE helpers (`ExtIdeHelpers.lua`) and wikis lag the installed build.
When a `Subscribe`/field read returns nothing and you suspect a rename, confirm
the real name from the extender source (code-search `bg3se` for the
`ThrowEvent("...")` site). In #9 the live client event was
`Ext.Events.MouseButtonInput`, not the helper's stale `EclLuaMouseButton`; since
`Ext.Events` is not enumerable, only the source had it.

## Watch performance

You cannot feel frame hitches. In #9 a loop that walked the Examine visual tree
every 500ms (each walk ~2s) hung the game; the fix did the expensive lookup once,
on click. Keep diagnostics cheap, early-return when the relevant panel is closed,
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

## Checklist

1. One specific question set per iteration; instrument for all of them in one
   build.
2. Log broadly when the live path is unknown; timestamp every line (UTC, us);
   gate behind `DEBUG`.
3. Tell the user `reset` (Lua) or full restart (XAML/assets), and agree the exact
   in-game steps first.
4. Read engine errors literally; confirm suspected-renamed APIs from bg3se
   source.
5. Keep per-tick work cheap; prefer events over polling.
6. Never claim in-game success without a log that shows it.
7. Strip all `TEMPORARY` tooling and `DEBUG` logging before the PR.
