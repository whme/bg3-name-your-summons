# Debugging and exploring in game

You **cannot run Baldur's Gate 3.** The user is your eyes and hands: you write
instrumented Lua, hand the user a precise in-game script, and reason from the
Script Extender console output they paste back. This guide is the method that
made that loop fast and reliable during the native-UI work on issue #9 - where
almost nothing was documented and the game had to be interrogated live.

The golden rule: **do not guess and do not claim something works in game until a
pasted log proves it.** Overstating "it works" and being corrected wastes a full
round-trip (a game restart for the user). Instrument, get hard data, then claim.

## The debugging loop

1. **Form one specific question** ("which focus event fires when the field is
   left?"), not a vague one ("why doesn't rename work?").
2. **Instrument to answer exactly that** - add temporary logging or a throwaway
   console command that emits the signal you need.
3. **Hand the user a numbered, annotated script** with the expected output at
   each step (see template below).
4. **Read the pasted console output literally.** The `[ModName]` lines are your
   logs; engine error lines are precise (see "Reading the console").
5. **Change one thing** based on the evidence, and repeat. Bisect; do not
   shotgun-edit.

### Reloading: `reset` vs. full restart

- **Lua-only change** -> tell the user to type `reset` in the SE console. It
  reloads all Lua without restarting the game. Fast.
- **XAML / asset / packaging change** -> the user must **fully restart BG3**.
  `reset` does NOT reload UI or repack assets. Say which one every time, so the
  user does not test a stale build.

## Temporary discovery tooling

When you need to inspect live game state, add **throwaway console commands** and
remove them before the PR:

- Register `!nys_<verb>` commands in the Lua state that owns the data (UI walks
  live in the **client** state; entity/Osiris queries in the **server** state).
- Tag every temporary file/command `TEMPORARY` and wire it via a single
  `require` so it is trivial to rip out. In #9 these were `Client/UIDump.lua`,
  `Server/UIDumpBridge.lua`, a `Channels.UIDump`, and a `!nys_renameexamined`
  command - all removed before finalising.
- **Console context matters.** Commands only exist in the state they were
  registered in. The console starts in `server`; the user types `client` to
  switch (prompt goes `S >>` -> `C >>`). If a client command "does not exist",
  the user is probably still in the server context. To sidestep the back-and
  forth, register the command server-side too and bounce it to the client over a
  net channel - then it works from either prompt.

## Instrument broadly when you do not know the answer

The highest-leverage technique from #9: when you do not know which engine
event/field/path is the live one, **do not subscribe to a single guess -
subscribe to the whole candidate set, each logging when it fires and with what
payload.** One test run then tells you exactly which path is real, instead of one
failed guess per round-trip.

Example: rename-on-leave was not firing and it was unclear which focus event the
node received. Rather than try `LostKeyboardFocus`, rebuild, test, try
`LostFocus`, rebuild, test... a single diagnostic subscribed the entire battery:

```
GotFocus, LostFocus, GotKeyboardFocus, LostKeyboardFocus,
PreviewGotKeyboardFocus, PreviewLostKeyboardFocus,
KeyDown, PreviewKeyDown, KeyUp, TextInput, PreviewTextInput,
MouseLeftButtonDown, PreviewMouseLeftButtonDown, MouseLeftButtonUp,
MouseDown, MouseUp
```

each handler logging `NYS DIAG: <event> fired  src=... new=... old=...`. The
single resulting log showed which events actually reach the node - answering in
one run what would have been a dozen guesses. Gate this verbose output behind a
`local DEBUG = true` flag and a `dbg(...)` helper so you can silence it (and
strip it) before shipping.

## Controlled-experiment bisection

When a whole subsystem fails to load and you cannot tell if the cause is your
edits or the mechanism itself, **ship the minimal / verbatim variant to isolate
it.** In #9 the Examine page override failed to load; instead of tweaking the
edits blindly, the mod shipped a **byte-for-byte copy of Larian's own page** with
zero changes. It loaded fine - proving the override mechanism worked and the
fault was in the added controls, not the packaging. That one experiment redirected
the whole investigation. Prefer a decisive isolating test over another
speculative edit.

## Confirm engine facts from source, not stale helpers

The BG3SE IDE helpers (`ExtIdeHelpers.lua`) and community wikis drift behind the
installed build. When a `Subscribe`/field read returns nothing and you suspect a
rename, **confirm the real name from the extender source** (e.g. GitHub
code-search the `bg3se` repo for the `ThrowEvent("...")` site). In #9 the real
client mouse event was `Ext.Events.MouseButtonInput`, while the IDE helper's
`EclLuaMouseButton` was stale - only the source had the truth. Note also that
`Ext.Events` is not enumerable, so you cannot discover event names by iterating;
you must read them from source. (Cross-reference: the toolchain/reference guide
lists where these sources live.)

## Watch performance - the user will feel it

You cannot feel frame hitches, so treat any per-tick work as suspect. In #9 a
polling loop that walked the Examine visual tree every 500ms (each walk ~2s)
**hung and crashed the game**; the fix was event-driven wiring that did the
expensive lookup once, on click. Keep diagnostics cheap, gate them so they early
-return when the relevant panel is not open, and prefer an event subscription
over a poll. If the user reports the game getting sluggish or unresponsive,
suspect your instrumentation first.

## Reading the console

The SE console is a **separate window** that stays up while the game runs, so the
user can keep a panel open and type at the same time. Useful signals:

- **Startup header** - `BG3Ext v32`, `Game version v4.73.98.727 OK`, `SE v30`.
  (Version drives asset layout and API surface; see the internals guide.)
- **`[ModName]` lines** - your own `Util.Log` / `dbg` output.
- **Engine errors are literal and precise - read them as facts, not noise:**
  - `Object ls.DCExamine has no property named 'EntityUUID'` -> the property is
    on a different (child) view-model, not that one. Also a *gift*: it confirmed
    the real DataContext type name.
  - `Failed to find statemachine for UI mod` -> a UI mod must ship state
    machines, not just a page.
  - `UI State verification failed ... Issue found while verifying state 'X'` ->
    that page failed to parse/load (often an unresolved `StaticResource` or an
    unstyled bare control).

## What to ask the user for

Give a script the user can follow without interpretation, and tell them what each
step should produce so a mismatch is obvious to both of you:

```
1. `reset` (Lua change) / fully restart BG3 (XAML change).
2. Summon a creature, right-click -> Examine (leave it open).
3. In the console type `client`, then run:  !nys_diagwire
   (expect: "subscribe <Event> ok=true" for each event)
4. Slowly: (a) click into the field  (expect GotKeyboardFocus)
           (b) type one letter        (expect KeyDown/TextInput)
           (c) press Enter            (expect ...?)
           (d) click elsewhere        (expect a leave event)
5. Paste EVERY line beginning with [NameYourSummons].
```

Ask the user to **narrate what they did and saw** alongside the paste ("focus
and editing work, but leaving the field logs nothing until I reopen the panel").
That annotation is often what disambiguates the log - it tells you what the run
was *supposed* to show, so a missing line becomes signal instead of ambiguity.

## Checklist

1. One specific question per iteration.
2. Instrument to answer it - broadly (whole candidate set) when the live path is
   unknown; gate verbose logs behind a `DEBUG` flag.
3. Tell the user `reset` (Lua) or full restart (XAML/assets) - never leave it
   ambiguous.
4. Give a numbered, annotated script with expected output per step.
5. Read engine error lines literally; treat them as precise pointers.
6. Confirm suspected-renamed APIs from bg3se source, not the IDE helpers.
7. Never claim in-game success without a pasted log that shows it.
8. Keep per-tick work cheap; prefer events over polling.
9. Strip all `TEMPORARY` tooling and `DEBUG` logging before the PR.
