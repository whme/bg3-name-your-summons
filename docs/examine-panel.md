# The Examine panel: our implementation

What Name Your Summons builds on top of the engine contract in
[native-ui.md](native-ui.md): the rename bar, the settings overlay, the
on-summon prompt and its multi-summon queue, split-screen, controller, and
re-wiring. This file assumes native-ui.md and does not restate the engine rules.

Files (all under `Mods/NameYourSummons/`): `ScriptExtender/Lua/Client/
NativeRenameUI.lua`, `.../NativeConfigUI.lua`, `GUI/Pages/Examine.xaml`,
`GUI/Pages/Examine_c.xaml`, `GUI/Pages/NysHudOverlay.xaml`,
`GUI/StateMachines/{Keyboard,Controller}.xaml`.

## The rename bar

`Examine.xaml` overrides the keyboard Examine page (the state override lives in
`StateMachines/Keyboard.xaml`) and injects `NYS_RenameBar`, which holds four
controls: the name field `NYS_NameInput`, the settings gear
`NYS_SettingsButton`, and the queue buttons `NYS_ConfirmButton` /
`NYS_SkipButton`.

Read the examined creature's uuid off the panel's own Noesis DataContext
(`EntityUUID` plus `CharacterType == "Summon"`, property bag only). Send a
manual rename to the server over `Channels.RenameSummon`.

Commit the name from the field's own `TextChanged` subscription, debounced by
`TEXT_COMMIT_DEBOUNCE_MS` (20 ms) so one edit commits once; a blur
(`LostFocus` / `LostKeyboardFocus`) is not a commit path. Keep saving decoupled
from advancing a multi-summon queue: `commitField` never calls `showNext`.
Flush the tracked text with `flushName` at the two definitive exits where the
field may already be gone: the gear opening, and the panel closing.

### Turning editing on

Call `enableEditing` from `wirePanel` for any renamable summon, prompted on
summon or examined manually: it turns `IsReadOnly` off and `Focusable` /
`IsHitTestVisible` on, so a single click edits. The flags are consulted at
INPUT time rather than painted, so flipping them takes effect with no repaint -
which matters, because a manually-opened panel repaints only on a real click.

For a **forbidden** summon (a story-bound one - `Util.IsStorySummon` - with the
opt-in off), leave the field alone. `NYS_NameInput` ships with `IsReadOnly` on
and `Focusable` / `IsHitTestVisible` off, so the XAML default already renders
the native plain name: no caret, no hover border, not clickable.

Classify with `isForbiddenSummon`: it reads the root template off the client
entity (`Ext.Entity.Get(uuid).OriginalTemplate.OriginalTemplate`) and tests
`Util.IsStorySummon` against `cachedAllowStory`, the client's own copy of
`AllowStorySummons`. Seed that copy at `Register` and again on `SessionLoaded`
(a fresh boot has not loaded persisted ModVars at Register), and keep it fresh
from the server's `Channels.SettingsChanged` broadcast. That broadcast also
re-evaluates every open panel, so toggling the setting reverts a now-forbidden
summon to plain text via `disableEditing` with no re-summon. An unreadable
template fails open to renamable. The gear is always shown.

## The visual-tree landmarks

Resolve a landmark by scanning `ContentRoot`'s direct children
(`childrenNamed`); they sit at depth 1. Measured in game with `!nys_uidump`
(depths relative to `ContentRoot` = 0):

| Node | Depth |
|---|---|
| `Examine` / `Examine_c` / `HudIndicator` / `NYS_HudOverlay` | 1 |
| `PlayerPortraits` (keyboard) / `PartyLine_c` (controller) | 1 |
| `NYS_HudVmHost` (`NYS_HudOverlay` -> `NYS_HudOverlayRoot` -> host) | 3 |

For the overlay host, navigate the two known levels below `NYS_HudOverlay`
(`bfsByName`, `maxDepth` 2). Read `Examine`'s absence from `ContentRoot`'s
direct children as "no panel is open, full stop".

Per-viewport CONTROLS all live under `NYS_RenameBar`, so `wirePanel` DFS-walks
the Examine subtree ONCE down to that bar and then resolves the four controls
within that small subtree.

Match `entityHandleFor` by DataContext rather than by name: a summon portrait
carries no `x:Name`, so compare each candidate's `EntityUUID`. Bound the scan to
the party portrait bars (whose own `x:Name` differs by input layout) and try
every candidate bar - split-screen is controller-only, one bar per viewport, and
a summon sits under its owner's.

`!nys_uidump` is the authority for this table. Re-run it after a game patch
rather than guessing.

## Panel lifecycle and re-wiring

Detection is the persistent-HUD-overlay mechanism from
[native-ui.md](native-ui.md): `NysHudOverlay.xaml` is merged into `PlayerHUD`
with `ModType="Extend"` in BOTH state machines, so keyboard and controller
detect a manual open through the identical path.

On the overlay's `NysDetectCommand` signal, `onExamineDetected` first unwires
every panel that has no live prompt session - so a re-open always wires a fresh
field subscription - and then runs `pollLifecycle` on a bounded retry, because
the panel widget lags the DataContext that fired the trigger.

### Re-wire on these five signals

**This list is authoritative; native-ui.md defers to it.**

Run `rewireBurst` (retry until a host is wired, then two more safety passes,
then stop) on each of:

1. `Register`, at the tail of `installHudDetector`.
2. `SessionLoaded` and `ResetCompleted`.
3. The `GameStateChanged` transition INTO a world-up state (`Running` /
   `Paused`) FROM a non-world-up one. This is what wires the post-load host on a
   keyboard-only session, where the world-up HUD rebuild raises none of the
   other four. Keep the `FromState` guard so the in-play pause/unpause toggles,
   which rebuild nothing, stay silent.
4. A keyboard <-> controller switch: `onInput` bursts on a device-kind change
   seen across the live `MouseButtonInput` / `KeyInput` /
   `ControllerButtonInput` events.
5. `ViewportResized`, which is what a split-screen viewport join/leave raises
   when it rebuilds a HUD host.

Clear the `onInput` latch (`lastInputKind`) on `SessionLoaded` and on entering
a world-up state, so a keypress in the pre-load menu cannot latch `kbm` and
suppress the first in-game backstop burst.

Five signals suffice because the wiring PERSISTS on the live node once set -
measured: `wireHost` fired 0 times across a 77 s session while the host stayed
wired - so wiring is needed only at a real HUD rebuild. Re-fetch the host inside
each burst; a Lua node handle expires across ticks. Steady state does zero
walks.

While a prompt is pending, a self-disarming `SAFETY_RECONCILE_MS` (1 s) loop
reconciles, so a missed panel close still lifts the server's pause. Gate every
scan on `scanAllowed` (`Running` / `Paused` only): a walk over a foreign tree
such as character creation's can access-violate past `pcall` (#99).

## The settings overlay

`Client/NativeConfigUI.lua` drives `NYS_SettingsPanel`, an overlay inside the
same Examine override, covering the prompt options, the per-creature-type
filter, the multi-summon mode, and the saved-name manager. `NativeRenameUI` owns
panel detection and hands this module its viewport-scoped node finder
(`SetPanelFinder(NativeRenameUI.FindNamedIn)`), its viewer resolver
(`SetViewerProvider(NativeRenameUI.ViewerOf)`), and its gear hook
(`SetGearHandler(NativeConfigUI.Open)`) - all wired in `BootstrapClient`, which
keeps the two modules free of a circular require.

Store the multi-summon mode as ONE value. An `ls:LSToggleButton` pill
(`IsChecked` bound to `NysModeOpen`) opens a `Popup` of one button per mode, and
each button's `Command` writes `NysModeValue` and closes the flyout.
Exclusivity is inherent in the single value.

Rebuild the whole panel on open and on Refresh (`populate`): a fresh viewmodel
is the one clean list. Stamp each rebuild with a per-session `generation`
counter so a slow server reply that lands afterwards drops itself instead of
appending to the new viewmodel.

### Every change is live

Each setting's WriteCallback (`onSettingWrite`, or `pushIfLive` for the mode
value and the per-type toggles) pushes the WHOLE settings object to the server
as it is toggled, so the panel needs no Save button.

A saved name commits from `onNameWrite`, the WriteCallback on the row's
`NysNameText`, whose binding is `UpdateSourceTrigger=LostFocus` - Enter reaches
an `LSTextBox` as a blur too, so both gestures commit.

Stage a forget rather than sending it: the row's button toggles to Undo and the
row stays visible while the panel is open. `flushStaged` sends the real
`ForgetName` messages when the overlay's own close button runs, and when the
whole Examine panel closes (`NativeConfigUI.Flush`), so a forgotten name
disappears on close and stays gone on re-open.

Escape closes only the overlay, matching the controller's Circle: bind the
`CloseExamine` button `Collapsed` while the overlay is visible - a Collapsed
`BoundEvent` button does not receive the event - and let the overlay's own
`ls:LSInputBinding BoundEvent="UICancel"`, enabled on `NysIsOpen`, pick it up.

Push an edited name to the live panel as well as to the creature: the server
broadcasts `Channels.SummonRenamed` (`SummonUuid` + `Name`) from its single
apply path in `Server/Naming.lua`, and `NativeRenameUI` writes the text into the
on-screen field itself - only for panels with no active prompt session, since
those manage their own field. The write must be explicit because a
manually-opened panel repaints only on a real click.

## The on-summon prompt

The on-summon naming UI **is** the Examine panel. Everything stateful is
server-side: detection, the per-key pending count, the world-pause, and
per-creature `unique` prompting. The server sends `AskName` (`Key`,
`SummonUuid`, `OwnerUuid`, `ViewportChar`, `DefaultName`, `Template`, `Scope`,
`Slot`) to the summoner's client only.

The client answers by opening Examine on the summon: fetch the game's
`ExamineCommand` off a HUD command-surface DataContext (`HudIndicator`) and
`Execute` it with the summon's Noesis `EntityHandle`, read by `EntityUUID` off
the always-present portrait view-models.

Answer a prompt over `Channels.SubmitName`: it carries the `Key` / `Scope` /
`Slot` the server stores under, and it is what decrements the pending count and
lifts the pause. A later edit of an already-answered summon goes over
`RenameSummon`.

## Multi-summon: one panel that swaps through the queue

Only one Examine panel exists per viewport, and `ExamineCommand:Execute` on an
already-open panel SWAPS its content. Name a whole group in that one panel: the
name saves live as the player types, Confirm advances to the next queued summon,
and the player closes the panel once at the end.

- **Confirm** (`NYS_ConfirmButton` -> `confirmCurrent` -> `onFieldEnter`) is the
  SOLE advance on BOTH layouts. It answers over `SubmitName` if the summon is
  not yet answered, then swaps. Its `NysShowConfirm` Bool on `NYS_ConfirmVM`
  uses the same condition as Skip (a next summon is queued, `#st.queue > 0`), so
  it shows exactly when there is somewhere to advance to; a single summon and
  the last of a group are already saved live, and the server's pending count
  clears when the panel closes.
- **Skip** (`NYS_SkipButton` -> `skipCurrent`) aborts the current summon so the
  server re-asks on the next cast, then swaps. `refreshQueueButtons` toggles
  both buttons on every queue mutation.
- Resolve `current` - answer, skip, or retract it - before calling `showNext`;
  `showNext` then Executes Examine on the next request, opening the panel or
  swapping its content.
- Write the incoming creature's name in with `setFieldTextIn` after every swap:
  the field's `Text` binding is OneWay and does not follow a swap.
- Closing the panel mid-queue skips everything left (`abortRemaining` aborts an
  unnamed `current` and every still-queued request), so the pending count still
  clears and the pause still lifts.
- A retract of the on-screen summon swaps to the next, or closes the panel via
  `closeExaminePanel` when the queue is empty. DROP a retracted request rather
  than aborting it: the server has already cleared its own pending count for it.
- After each open or swap, `awaitingOpen` ignores input for `EXAMINE_SETTLE_MS`
  (400 ms) while the swapped-in field element and its DataContext appear; then
  wire the fresh field and set its text, from a one-shot
  `Ext.Timer.WaitForRealtime`. A per-panel `openGen` token makes a superseded
  settle callback bail - and drain anything queued while it waited - when a
  retract swaps `current` mid-settle.
- Check `CanExecute` before Execute, and skip the summon on any failure to open
  (no command, no handle, `CanExecute` false, or `Execute` throwing) so the
  pause always lifts. `CanExecute` earns its place because a disabled command
  Executes as a silent no-op.

## Split-screen: the client side

Key all panel state by the viewport's `CurrentPlayer.PlayerId`
(`NativeRenameUI` `panels[id]`, `NativeConfigUI` `sessions[id]`) and scope every
node lookup to one viewport (`examineNodeById`, `findNamedIn`, `liveFieldIn`),
so each player examines, names, and opens settings independently.

`viewportIdForChar` maps an incoming `AskName`'s `ViewportChar` to a PlayerId by
matching each candidate node's `CurrentPlayer.SelectedCharacter.EntityUUID`, and
`getExamineCommand` picks that viewport's `HudIndicator` the same way, so the
panel opens on the summoner's viewport. An unresolvable `ViewportChar` falls
back to viewport 1.

Re-wire every already-open panel after any panel opens (`rewireStale`,
EXCLUDING the just-opened ones, so a lone panel - and therefore all of
single-player - is never disturbed): opening one Examine panel rebuilds the
other panels' field elements in a shared re-layout, which silently drops their
`Subscribe`d handlers and would leave them unable to commit a rename.

The server side is in [architecture.md](architecture.md).

## Controller layout

`StateMachines/Controller.xaml` overrides the `Examine` state - the base
controller Examine STATE is named `Examine`, `Examine_c` being the widget
filename - to load our `GUI/Pages/Examine_c.xaml`, a copy of the game's
controller Examine page with the rename bar, gear, Confirm, Skip, and
`NYS_SettingsPanel` injected. The controller page carries the creature name
inline rather than in an external template, so the bar goes next to that
`{Binding Name}` title.

Copy four of the base state's five events verbatim and close Examine on Circle
through the footer UICancel button (gated `Collapsed` while the overlay is
open), leaving `IE.UICancel` out of the state itself: a state-level
`IE.UICancel -> RemoveState` fires unconditionally and no widget handler can
veto it, so Circle would take the whole panel down instead of just the overlay.

Our page adds `NYS_AcceptPrompt`, the `BoundEvent="UIAccept"` hint button that
runs the focused element's `Command`.

**One Lua path serves both layouts.** `isExamineName` accepts `Examine` OR
`Examine_c`, detection is the same `PlayerHUD` overlay, and `wirePanel`
auto-enables editing for a renamable summon on both. The name field is reachable
because `LSTextBox` is inherently focusable; it carries `ls:MoveFocus.Focusable`
permanently and gates real navigability through `Focusable`, which
`NativeRenameUI` toggles, so a forbidden or plain field is skipped by controller
navigation exactly as it is by the mouse.

Two controls take a different form on the controller page. Each checkbox is a
focusable button that flips a VM bool on accept, backed by a per-boolean
`Nys*Command` (`NysTogglePromptOnSummonCommand` and friends) added to the
settings viewmodel; and the mode dropdown is three focusable choice buttons
reusing the same `NysSelectSkipCommand` / `NysSelectSharedCommand` /
`NysSelectUniqueCommand`. The keyboard page keeps its mouse `TwoWay` / pill
path, so both pages drive ONE viewmodel.
