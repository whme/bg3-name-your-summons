# The Examine panel: our implementation

What Name Your Summons builds on top of the engine contract in
[native-ui.md](native-ui.md): the rename bar, the settings overlay, the
on-summon prompt and its multi-summon queue, split-screen, controller, and
re-wiring. This file assumes native-ui.md and does not restate the engine rules.

Files: `Client/NativeRenameUI.lua`, `Client/NativeConfigUI.lua`,
`GUI/Pages/Examine.xaml`, `GUI/Pages/Examine_c.xaml`,
`GUI/Pages/NysHudOverlay.xaml`, `GUI/StateMachines/{Keyboard,Controller}.xaml`.

## The rename bar

The Examine panel gets an editable name field (`NYS_NameInput`) and a settings
gear (`NYS_SettingsButton`) via an `Examine.xaml` override (a state override in
`StateMachines/Keyboard.xaml` points the Examine state at our page). The examined
creature's uuid is read from the panel's Noesis DataContext (`EntityUUID` +
`CharacterType == "Summon"`, bag-only) and renames go to the server over
`Channels.RenameSummon`.

The controls we add are driven by per-element MVVM: the gear is an `ls:LSButton`
whose `Command` binds to a tiny `NYS_GearVM` set as its nested DataContext.

The field SAVES on its own per-element `TextChanged` subscription, debounced by
`TEXT_COMMIT_DEBOUNCE_MS` so rapid typing saves once - **not** on a focus-loss
blur. The blur (`LostFocus` / `LostKeyboardFocus`) is not reliably delivered,
especially on controller, so a rename must never hinge on it. Saving is decoupled
from advancing a multi-summon queue, and is also flushed when the gear opens and
when the panel closes.

### Non-interactive by default; editing is opt-in

`NYS_NameInput` defaults to `IsReadOnly`, `Focusable`, and `IsHitTestVisible` all
off in the XAML, so it renders as the native plain name - no caret, no hover
border, not clickable. That is the correct look for a **forbidden** summon (a
story-bound one - `Util.IsStorySummon` - with the opt-in off) with NO Lua action
needed.

`enableEditing` flips those three flags on in `wirePanel` for any renamable
summon - an on-summon prompt OR a manually examined one - so a single click
edits. The flags are checked at INPUT time, not painted, so this needs no
repaint.

A forbidden summon is never enabled: `isForbiddenSummon` reads the root template
off the client entity (`Ext.Entity.Get(uuid).OriginalTemplate.OriginalTemplate`)
and tests `Util.IsStorySummon` against `cachedAllowStory` - a copy of
`AllowStorySummons` seeded on `SessionLoaded` and kept fresh by the server's
`Channels.SettingsChanged` broadcast (the live value cannot be fetched
synchronously; fails open to renamable if the template is not readable
client-side). That broadcast also re-evaluates the on-screen panel, so toggling
the setting reverts a now-forbidden summon to plain text via `disableEditing`
without a re-summon. The gear is always shown.

## The visual-tree landmarks

**NEVER walk the whole visual tree; the landmarks are direct children of
ContentRoot.** Verified via `!nys_uidump` (depths relative to `ContentRoot` = 0):

| Node | Depth |
|---|---|
| `Examine` / `Examine_c` / `HudIndicator` / `NYS_HudOverlay` | 1 |
| `NYS_HudVmHost` (`NYS_HudOverlay` -> `NYS_HudOverlayRoot` -> host) | 3 |

So the `ContentRoot` lookups scan ONLY direct children (`childrenNamed`) or
navigate a couple of known levels (`bfsByName`, bounded `maxDepth`). If `Examine`
is not a direct child, no panel is open, full stop.

Because `element:Find(name)` resolves only within one namescope, it is used only
for `contentRoot` itself. Per-viewport CONTROLS are all under our
`NYS_RenameBar`, so `wirePanel` DFS-walks the Examine subtree ONCE to that bar,
then resolves each control within its tiny subtree - not four separate Examine
walks.

The one lookup that cannot use a name is `entityHandleFor` (it matches a
DataContext's `EntityUUID`; there is no `x:Name`). Every summon portrait lives
under the party portrait bar, a direct child of `ContentRoot` whose `x:Name`
differs by input layout (`PlayerPortraits` on keyboard, `PartyLine_c` on
controller - both verified via `!nys_uidump`), so it scans ONLY those bounded
subtrees, never `ContentRoot`, and tries every candidate bar (split-screen is
controller-only, one bar per viewport), since the summon is under its owner's.

`!nys_uidump` dumps the landmark map (named nodes + depth + per-namescope `:Find`
reach) to the trace file. It is the authority for these depths - re-run it rather
than guessing after a game patch.

## Panel lifecycle and re-wiring

Panel detection uses the persistent HUD overlay described in
[native-ui.md](native-ui.md): `NysHudOverlay.xaml` is merged into the
always-active `PlayerHUD` state with `ModType="Extend"` in BOTH
`StateMachines/*.xaml`, so it is always in the tree and detection works
identically on keyboard and controller with no input hook.

On its `NysDetectCommand` signal, `onExamineDetected` reconciles the tree
(`pollLifecycle`) on a short bounded retry - the panel widget lags the target by
up to ~`EXAMINE_SETTLE_MS` - and force-fresh-wires manual panels so a re-open
cannot reuse stale field subscriptions.

### Re-wiring is event-driven, NOT a heartbeat

This is the authoritative trigger list.

The overlay wiring PERSISTS on the live node once set (verified: `wireHost` fired
0 times across a 77 s session while the host stayed wired), and a Lua node handle
expires across ticks so it cannot be cached. Together these mean we (re)wire ONLY
on a real HUD rebuild and never poll - a per-second walk was what SE profiled
(`Dispatching user function call ... took X ms`).

`rewireBurst` (bounded retry - keep trying until a host is wired, then two safety
passes, then stop) runs:

1. At Register.
2. On `SessionLoaded` / `ResetCompleted`.
3. On the `GameStateChanged` transition INTO a world-up state (`Running` /
   `Paused`) from a non-world-up one. The world-up HUD rebuild fires none of the
   others on a keyboard-only session, so the post-load host would go unwired
   until a device switch. The `FromState` guard skips the in-play pause/unpause
   toggles, which rebuild nothing.
4. On a keyboard <-> controller switch. There is no BG3SE input-mode event, so
   `onInput` bursts on a device-kind change seen via the live `MouseButtonInput`
   / `KeyInput` / `ControllerButtonInput` events - NOT the stale `EclLua*` helper
   names.
5. On `ViewportResized` - a split-screen viewport join/leave rebuilds a HUD host
   but fires none of the others.

The `onInput` latch (`lastInputKind`) is CLEARED on `SessionLoaded` and on
entering a world-up state, so a keyboard input pressed in the menu pre-load
cannot latch `kbm` and suppress the first in-game backstop burst.

Steady state does zero walks.

While an on-summon prompt is pending, a self-disarming `SAFETY_RECONCILE_MS` loop
guards the world-pause against a missed close. All scans run only in `Running` /
`Paused` (`scanAllowed`).

## The settings overlay

`Client/NativeConfigUI.lua` + `GUI/`. The gear opens a native (Noesis) settings
overlay - an `NYS_SettingsPanel` in the same `Examine.xaml` override - covering
prompt options, the per-creature-type filter, multi-summon mode, and the
saved-name manager.

It is real MVVM: a viewmodel built via `Ext.UI.RegisterType` /
`Ext.UI.Instantiate` (`Bool` props for checkboxes, a `Collection` per
`ItemsControl`, `Command` props for buttons) is set as the panel's `DataContext`.
`NativeRenameUI` owns Examine-panel detection and feeds this module the node
finder (`SetPanelFinder(NativeRenameUI.FindNamed)`) and the gear hook
(`SetGearHandler`), avoiding a circular require.

Markup uses Larian `ls:` controls only (`ls:LSToggleButton` + `TickBox`,
`ls:LSButton` + `SmallBrownButtonStyle`, `ls:LSTextBox`) extracted from the
game's own `OptionTemplates.xaml` / `Buttons.xaml`.

The multi-summon mode is a single-value dropdown, not a radio group: an
`ls:LSToggleButton` "pill" (whose `IsChecked` binds a `NysModeOpen` Bool) over a
`Popup` flyout of one `Button` per value, built from the vanilla options-menu
dropdown art (self-contained `pack://.../Core;component/Assets/Options/...` URIs,
declared `NYS_`-prefixed in `Examine.xaml`). The stored value is a single
`NysModeValue` String; each flyout Button's `Command` sets it and closes the
flyout, so radio exclusivity is inherent (one value) with no WriteCallback
re-entry to guard.

The whole panel is rebuilt on open and on Refresh (`populate`), guarded by a
`generation` counter, because an SE `Collection` cannot be cleared in place.

### Everything is live; there is no Save button

Each setting's WriteCallback (`onSettingWrite` / `pushIfLive`) sends the whole
settings object to the server as it is toggled. An edited name commits via
`onNameWrite` (a WriteCallback on the row's `NysNameText`, whose binding is
`UpdateSourceTrigger=LostFocus`), so it commits on blur - Enter reaches the
`LSTextBox` as a blur too.

A forget toggles to Undo and stays visible while the panel is open; the staged
forgets flush only when the panel closes (`flushStaged`, run from the overlay's
own close button and from the whole Examine panel closing via
`NativeConfigUI.Flush`), so a forgotten name vanishes on close and does not
reappear on re-open.

**Escape closes only the overlay, not Examine** (like the controller's Circle):
the `CloseExamine` button is gated `Collapsed` while the overlay is open - a
Collapsed `BoundEvent` button does not receive the event - and the overlay's own
`ls:LSInputBinding BoundEvent="UICancel"` (enabled on `NysIsOpen`) closes it.

Editing a saved name also applies to the live creature, but a manually-opened
Examine panel does not repaint a name changed from outside, so the server
broadcasts `Channels.SummonRenamed` (uuid + text) from its single apply path
(`Server/Naming.lua`) and `NativeRenameUI` writes the new text into the on-screen
field.

## The on-summon prompt

The on-summon naming UI **is** the native Examine panel. Detection, the pending
count, the world-pause, and per-creature `unique` prompting are all server-side;
the server sends `AskName`.

The client answers by opening Examine on the summon: fetch the game's
`ExamineCommand` off the HUD command-surface DataContext (the `HudIndicator` node
under `ContentRoot`) and `Execute` it with the summon's Noesis `EntityHandle`.
The handle is read by `EntityUUID` off a live per-entity DataContext (the
always-present portrait view-models carry it).

An on-summon request renames over `Channels.SubmitName` (not `RenameSummon`) so
the server saves the name AND clears its pending count / lifts the pause.

## Multi-summon: one panel that swaps through the queue

Only one Examine panel exists, and `ExamineCommand:Execute` on an already-open
panel SWAPS its content rather than being ignored, so a group is named in one
panel. The creature's name is saved live as the player types (debounced
`TextChanged`), and an explicit Confirm advances the panel to the next queued
summon; repeat until the queue drains; the player closes the panel once at the
end.

- **Confirm** is `NYS_ConfirmButton` (`confirmCurrent` -> `onFieldEnter`, which
  answers over `SubmitName` if not yet answered and then swaps), shown via a
  `Bool NysShowConfirm` on its `NYS_ConfirmVM` with the SAME condition as Skip
  (`#examineQueue > 0`), so it is hidden for single summons and on the LAST
  creature of a group. Confirm is the SOLE advance on BOTH layouts - the field's
  blur is not a commit or advance path. A single summon or the last of a group
  needs no advance: its name is already saved live, and the server's pending
  count clears when the panel closes.
- **Skip** is `NYS_SkipButton` (abort + swap), shown on the same
  `#examineQueue > 0` condition as Confirm (`refreshQueueButtons` toggles both).
- `showNext` Executes Examine on the next request (open, or content-swap if a
  panel is up); the outgoing `current` is always already resolved (answered,
  skipped, or retracted), so `showNext` never aborts it.
- Because the field's `Text` binding is OneWay and does NOT follow a swap,
  `setFieldText` writes the new creature's name in directly after each swap.
- Closing the panel mid-queue skips ALL that is left (`abortRemaining` aborts
  `current` if unnamed and every still-queued request), so the pending count
  still clears and the pause lifts. A retract of the on-screen summon swaps to
  the next or, if the queue is empty, closes the panel via `closeExaminePanel`.
- After each open/swap, input is ignored for `EXAMINE_SETTLE_MS` (`awaitingOpen`
  gates it) while the swapped-in field settles, then the fresh field is wired and
  its text set - one-shot `Ext.Timer.WaitForRealtime`, not polling. An
  `openGeneration` token makes a superseded settle callback bail (and drain any
  summon queued while it waited) when a retract swaps `current` mid-settle.
- A failure to open Examine (command/handle missing or `Execute` throwing) skips
  to the next, so the pause never deadlocks.

## Split-screen: the client side

All panel state is keyed by `CurrentPlayer.PlayerId` (`NativeRenameUI`
`panels[id]`, `NativeConfigUI` per-viewport `sessions[id]`) and every node lookup
is scoped to a viewport (`examineNodeById` / `findNamedIn` / `liveFieldIn`), so
every player examines, names, and opens settings independently. `AskName` carries
`ViewportChar`, and `getExamineCommand` matches the right `HudIndicator` by it,
so the panel opens on the summoner's viewport rather than always player 1's.

**Trap:** opening one Examine panel REBUILDS the other open panels' field
elements (a shared re-layout), which silently kills our `Subscribe`d handlers. So
already-open panels are re-wired after any panel opens (`rewireStale`, EXCLUDING
the just-opened one, so a single panel / single-player is never disturbed).

The server side is in [architecture.md](architecture.md).

## Controller layout

`StateMachines/Controller.xaml` overrides the `Examine` state (the base controller
Examine STATE is named `Examine`, not `Examine_c`; that is only the widget
filename) to load our own `GUI/Pages/Examine_c.xaml` - a copy of the game's
controller Examine page with the same rename bar, gear, Confirm, Skip, and
`NYS_SettingsPanel` overlay injected next to the inline `{Binding Name}` title.
Unlike the keyboard page, the controller name is inline in the page, not in an
external template.

Unlike the keyboard state, the controller state carries five events - four copied
verbatim, with `IE.UICancel` deliberately omitted so Circle closes only the
overlay (see the controller contract in [native-ui.md](native-ui.md)).

The base Examine has no `BoundEvent="UIAccept"` hint button, so `NYS_AcceptPrompt`
supplies it. Our buttons use `FocusableButtonStyleMinimal`. The name field
carries `ls:MoveFocus.Focusable` permanently but gates real navigability through
`Focusable` (toggled by `NativeRenameUI`), so a forbidden/plain field is skipped,
and it sets `OpenVirtualKeyboardOnFocus="False"`.

Lua deltas in `NativeRenameUI.lua`: `examineNode` accepts `Examine` OR
`Examine_c`; `isControllerPanel` (the `Examine_c` node is present) tells the
layouts apart; lifecycle needs no controller-specific detector, since
`Controller.xaml` extends the same `PlayerHUD` state with `NysHudOverlay`.
`wirePanel` auto-enables editing for a renamable summon on both layouts.

The settings overlay jumps focus in on open (`ls:SetMoveFocusAction` on an
`IsVisible=True` trigger) and its text rows set
`OpenVirtualKeyboardOnFocus="False"`. The whole Examine `Panel` is
`IsEnabled`-disabled while the overlay is open, which traps focus and lets the
initial `SetMoveFocusAction` land.

The checkboxes and the multi-summon dropdown could not stay as-is on controller,
so on the controller page each checkbox is a `FocusableButtonStyleMinimal` button
that toggles a VM bool on accept (the `TickBox` inside is a non-interactive state
indicator), and the dropdown is three focusable choice buttons (the current value
bold/accent) reusing the same `NysSelectX` commands. The toggles are driven by
per-boolean `Nys*Command`s added to `NativeConfigUI`'s viewmodels; the keyboard
page still uses the mouse `TwoWay`/pill path, unchanged.
