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
  application; client owns the native Examine rename field, settings gear, and
  saved-name manager.
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
  `NameEverySummon` master names every summon regardless of type.
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
  "unique set" - one distinct name per creature of a multi-summon; see below).
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
- **Native UI - the proven approach.** Implement and extend native UI this way:
  1. Open a game panel (Examine) - fetch `ExamineCommand` off the HUD command-surface
     DataContext (a `ui::DCWidget` with ~200 game commands, inherited onto the
     always-present `HudIndicator` node under `ContentRoot`; `ContentRoot`'s OWN
     DataContext does not expose it) and `Execute` it with the summon's Noesis
     `EntityHandle`; on an already-open panel this SWAPS content.
  2. Our own overlay (settings) - set our viewmodel as the element `DataContext`
     and flip a `Bool` visibility prop (no window API; `GetStateMachine()` is nil).
  3. Panels we own - MVVM via `Ext.UI.RegisterType` / `Ext.UI.Instantiate`
     (`Bool` / `Collection` / `Command` props, every field prefixed `Nys`).
     WriteCallbacks dispatch ASYNC, so make writes idempotent (never a synchronous
     re-entry flag); never cache a viewmodel/node handle; rebuild the viewmodel to
     clear a `Collection` (`coll[i]=nil` is the only in-place removal).
  4. Controls on a game DataContext (the rename bar) - buttons we add get their own
     nested DataContext + a `Command` binding; the field commits via per-element
     key/focus subscriptions. These work on the FIRST panel; do NOT hit-test with a
     global mouse hook.
  5. Detecting a game panel open (Examine) - there is no way for the overridden page itself
     to tell Lua it opened. BG3SE has no panel-open event; a XAML-instantiated SE type
     (`Ext.UI.RegisterType`) comes back a propertyless `BaseComponent` so its `WriteCallback`
     never fires; there is no ECS / netmsg / Osiris signal for a client-side Examine; and Ext
     resource dictionaries are not writable from Lua. Detect it from a persistent widget WE
     own instead: merge our own `NysHudOverlay` into the always-active `PlayerHUD` game state
     with `ModType="Extend"` (in both `StateMachines/*.xaml`) so it is always in the tree, and
     wire it once. Inside it a `b:DataTrigger` on
     `CurrentPlayer.UIData.ExamineTarget.CharacterType == "Summon"` invokes a `Command` on a VM
     Lua sets as a child element's `DataContext` (the game raises `b:DataTrigger` on that path;
     an `ls:LSTextBox.Text` OneWay binding does NOT - an input control ignores binding-driven
     text). NEVER use a global input hook as a lifecycle detector: the old per-click scan walked
     whatever tree was on screen and crashed on character creation's foreign tree (#99). Scans
     run only in response to that signal, are anchored at `ContentRoot` / `Examine`, and read the
     DataContext property bag (`GetAllProperties`); the direct `GetProperty` is only ever for one
     known object (the HUD command surface, a matched entity handle).
- **Native Examine rename** (`Client/NativeRenameUI.lua` + `GUI/`): the Examine
  panel gets an editable name field (`NYS_NameInput`) and a settings gear
  (`NYS_SettingsButton`) via an `Examine.xaml` override (a state override in
  `StateMachines/Keyboard.xaml` points the Examine state at our page). The
  examined creature's uuid is read from the panel's Noesis DataContext
  (`EntityUUID` + `CharacterType == "Summon"`, bag-only) and renames go to the
  server over `Channels.RenameSummon`. Following the approach above, the controls we
  add are driven by per-element MVVM: the gear is an `ls:LSButton` whose `Command`
  binds to a tiny `NYS_GearVM` set as its nested DataContext; the field SAVES on its
  own per-element `TextChanged` subscription, debounced by `TEXT_COMMIT_DEBOUNCE_MS` so
  rapid typing saves once, NOT on a focus-loss blur - the blur (`LostFocus` /
  `LostKeyboardFocus`) is not reliably delivered, especially on controller, so a rename
  must never hinge on it. Saving is decoupled from advancing a multi-summon queue (see
  below), and also flushed when the gear opens or the panel closes. Panel lifecycle uses the
  persistent HUD overlay of rule 5 (`installHudDetector`): on its `NysDetectCommand` signal
  `onExamineDetected` reconciles the tree (`pollLifecycle`) on a short bounded retry - the panel
  widget lags the target by up to ~`EXAMINE_SETTLE_MS` - and force-fresh-wires manual panels so a
  re-open cannot reuse stale field subscriptions. **NEVER walk the whole visual tree; the landmarks
  are direct children of ContentRoot.** Verified via `!nys_uidump` (depths relative to ContentRoot=0):
  `Examine` / `Examine_c` / `HudIndicator` / `NYS_HudOverlay` are all at depth 1, and `NYS_HudVmHost`
  is at depth 3 (`NYS_HudOverlay` -> `NYS_HudOverlayRoot` -> host). So the ContentRoot lookups scan
  ONLY direct children (`childrenNamed`) or navigate a couple of known levels (`bfsByName`, bounded
  maxDepth) - if `Examine` is not a direct child, no panel is open, full stop. (`element:Find(name)` /
  Noesis `FindNodeName` resolves only WITHIN one namescope - `GetRoot():Find("ContentRoot")` works but
  `ContentRoot:Find("HudIndicator")` does not - so it is used only for `contentRoot` itself; per-
  viewport CONTROLS are all under our `NYS_RenameBar`, so `wirePanel` DFS-walks the Examine subtree
  ONCE to that bar, then resolves each control within its tiny subtree - not four separate Examine
  walks.) The one lookup that cannot use a name is `entityHandleFor` (matches a DataContext's
  `EntityUUID`, no x:Name); every summon portrait lives under the party portrait bar, a direct child of
  ContentRoot whose x:Name differs by input layout (`PlayerPortraits` on keyboard, `PartyLine_c` on
  controller - both verified via `!nys_uidump`), so it scans ONLY those bounded subtrees, never
  ContentRoot - and tries every candidate bar (split-screen is controller-only, one bar per viewport),
  since the summon is under its owner's.
  **Re-wiring is event-driven, NOT a heartbeat.** The overlay wiring PERSISTS on the live node once set
  (verified: `wireHost` fired 0 times across a 77 s session while the host stayed wired), and a Lua
  node handle expires across ticks so it cannot be cached - together these mean we (re)wire ONLY on a
  real HUD rebuild and never poll (a per-second walk was what SE profiled - `Dispatching user function
  call ... took X ms`): `rewireBurst` (bounded retry - keep trying until a host is wired, then two
  safety passes, then stop) runs at Register, on `SessionLoaded` / `ResetCompleted`, on
  the `GameStateChanged` transition INTO a world-up state (`Running` / `Paused`) from a non-world-up
  one (the world-up HUD rebuild fires none of the others on a keyboard-only session, so the post-load
  host would go unwired until a device switch; the `FromState` guard skips the in-play pause/unpause
  toggles, which rebuild nothing), on a keyboard<->controller switch (no BG3SE input-mode event, so `onInput` bursts on
  a device-kind change seen via the live `MouseButtonInput` / `KeyInput` / `ControllerButtonInput`
  events - NOT the stale `EclLua*` helper names), and on `ViewportResized` (a split-screen viewport
  join/leave rebuilds a HUD host but fires none of the others). The `onInput` latch (`lastInputKind`)
  is CLEARED on `SessionLoaded` and on entering a world-up state, so a keyboard input pressed in the
  menu pre-load cannot latch `kbm` and suppress the first in-game backstop burst. Steady state does
  zero walks.
  While an on-summon prompt is pending a self-disarming `SAFETY_RECONCILE_MS` loop guards the
  world-pause against a missed close. All scans run only in `Running`/`Paused` (`scanAllowed`).
  `!nys_uidump` dumps the visual-tree landmark map (named nodes + depth + per-namescope `:Find` reach)
  to the trace file - the authority for these depths.
  Reads use the property bag; the direct
  `GetProperty` (238-510 ms per Examine open when scanning) is reserved for one known object (the
  HUD command surface, a matched entity handle).
  **Non-interactive by default; editing is opt-in.** The name field (`NYS_NameInput`)
  defaults to `IsReadOnly`, `Focusable`, and `IsHitTestVisible` all off in the XAML, so it
  renders as the native plain name - no caret, no hover border, not clickable. That is the
  correct look for a **forbidden** summon (a story-bound one - `Util.IsStorySummon` - with
  the opt-in off) with NO Lua action needed. `enableEditing` flips those three flags on in
  `wirePanel` for any renamable summon - an on-summon prompt OR a manually examined one - so a
  single click edits; a forbidden summon or non-summon stays plain text. The flags are checked
  at INPUT time, not painted, so this needs no repaint. A forbidden summon is never enabled:
  `isForbiddenSummon` reads the root
  template off the client entity (`Ext.Entity.Get(uuid).OriginalTemplate.OriginalTemplate`)
  and tests `Util.IsStorySummon` against `cachedAllowStory` - a copy of `AllowStorySummons`
  seeded on `SessionLoaded` and kept fresh by the server's `Channels.SettingsChanged`
  broadcast (the live value cannot be fetched synchronously; fails open to renamable if the
  template is not readable client-side). That broadcast also re-evaluates the on-screen
  panel, so toggling the setting reverts a now-forbidden summon to plain text via
  `disableEditing` without a re-summon. The gear is always shown.
- **Native Examine settings** (`Client/NativeConfigUI.lua` + `GUI/`): the gear
  opens a native (Noesis) settings overlay - an `NYS_SettingsPanel` in the same
  `Examine.xaml` override - covering prompt options, the per-creature-type filter,
  multi-summon mode, and the saved-name manager. It is real MVVM: a viewmodel built
  via `Ext.UI.RegisterType` / `Ext.UI.Instantiate` (`Bool` props for checkboxes,
  a `Collection` per `ItemsControl`, `Command` props for buttons) is set as the
  panel's `DataContext`. `NativeRenameUI` owns Examine-panel detection and feeds
  this module the node finder (`SetPanelFinder(NativeRenameUI.FindNamed)`) and the
  gear hook (`SetGearHandler`), avoiding a circular require. Markup uses Larian
  `ls:` controls only (`ls:LSToggleButton` + `TickBox`, `ls:LSButton` +
  `SmallBrownButtonStyle`, `ls:LSTextBox`) extracted from the game's own
  `OptionTemplates.xaml` / `Buttons.xaml`. The multi-summon mode is a single-value
  dropdown (not a radio group): an `ls:LSToggleButton` "pill" (whose `IsChecked`
  binds a `NysModeOpen` Bool) over a `Popup` flyout of one `Button` per value,
  built from the vanilla options-menu dropdown art (self-contained
  `pack://.../Core;component/Assets/Options/...` URIs, declared `NYS_`-prefixed in
  `Examine.xaml`). The stored value is a single `NysModeValue` String; each flyout
  Button's `Command` sets it and closes the flyout, so radio exclusivity is
  inherent (one value) with no WriteCallback re-entry to guard. Four engine constraints:
  - **No standalone-window API** (and `Ext.UI.GetStateMachine()` is stubbed), so
    the panel must live inside a page we already override (Examine).
  - **A viewmodel/node handle does not survive across ticks** - the object lives
    on as the DataContext but any Lua reference expires (`Attempted to fetch
    Noesis::BaseObject whose lifetime has expired`). Never cache it; re-fetch live
    from the panel (`liveVm`) at each use, and use the live `context`/`value`
    inside a `WriteCallback`. Never compare a Noesis object with `== nil` (routes
    through `__eq`, which throws on an expired object) - use truthiness.
  - **An SE `Collection` is effectively append-only from Lua** (`Clear`/`RemoveAt`/
    `table.remove`/whole-array assign all fail; the ONE in-place exception is
    `coll[i]=nil`, which removes a single element - unused here). The only wholly
    clean list is a fresh viewmodel, so the whole panel is rebuilt on open and on
    Refresh (`populate`), guarded by a `generation` counter so a slow reply cannot
    append to a newer viewmodel.
  - **Prefix every viewmodel field `Nys`** so it cannot alias a built-in (an
    unprefixed `Name` aliased `FrameworkElement.Name` and round-tripped the
    literal "Name").
  There is no Save button - every change is live: each setting's
  WriteCallback (`onSettingWrite` / `pushIfLive`) sends the whole settings object
  to the server as it is toggled, and an edited name commits via `onNameWrite` (a
  WriteCallback on the row's `NysNameText`, whose binding is
  `UpdateSourceTrigger=LostFocus`), so it commits on blur - Enter reaches the
  `LSTextBox` as a blur too. A forget still toggles to Undo and stays visible while
  the panel is open; the staged forgets flush only when the panel closes
  (`flushStaged`, run from the overlay's own close button and from the whole
  Examine panel closing via `NativeConfigUI.Flush`), so a forgotten name vanishes
  on close and does not reappear on re-open. **Escape closes only the overlay, not
  Examine** (like the controller's Circle): the `CloseExamine` button is gated
  `Collapsed` while the overlay is open - a Collapsed `BoundEvent` button does not
  receive the event - and the overlay's own `ls:LSInputBinding BoundEvent="UICancel"`
  (enabled on `NysIsOpen`) closes it. Editing a saved name also applies to the live
  creature, but a manually-opened Examine panel does not repaint a name changed from
  outside, so the server broadcasts `Channels.SummonRenamed` (uuid + text) from its
  single apply path (`Server/Naming.lua`) and `NativeRenameUI`
  writes the new text into the on-screen field.
- **On-summon prompt = the Examine panel** (`Client/NativeRenameUI.lua`):
  the on-summon naming UI is the native Examine panel. Detection, the pending
  count, the world-pause, and per-creature `unique` prompting are all server-side;
  the server sends `AskName`.
  The client answers by opening Examine on the summon: fetch the game's
  `ExamineCommand` (a Noesis `BaseCommand`) off the HUD command-surface DataContext
  (the `HudIndicator` node under `ContentRoot`) and
  `Execute` it with the summon's Noesis `EntityHandle` (the exact
  `CommandParameter` its XAML binds; a uuid string or SE `Entity` is rejected) -
  the handle is read by `EntityUUID` off a live per-entity DataContext (the
  always-present portrait view-models carry it). An on-summon request renames over
  `Channels.SubmitName` (not `RenameSummon`) so the server saves the name AND
  clears its pending count / lifts the pause.
- **Local split-screen**: one machine is one shared client Lua state but a BG3SE
  user per split-screen player (up to four), each able to have its own Examine panel open at
  once - nothing here is hardcoded to two; state is keyed per player. **Server**: a summon's
  owner maps to the controlling UserID via `Osi.GetReservedUserID`, so the saved-name list is
  filtered to the viewing player (`Util.IsNameVisible`) - each player sees only summons whose
  owner they CURRENTLY control. This is dynamic: when the 2nd controller leaves, that character
  reverts to the host, so its names become visible to the host with no re-summon. `AskName`
  carries `ViewportChar` - the summoner's controlled character, which equals that viewport's
  `CurrentPlayer.SelectedCharacter` client-side and the server's
  `Osi.GetCurrentCharacter(reservedUser)` - so the client opens Examine on the summoner's
  viewport (`getExamineCommand` matches the right `HudIndicator` by it), not always player 1's.
  `ListNames` takes a `ViewerCharacter`; the client's own `CurrentPlayer.UserId` (a small 1/2
  index) is NOT the Osiris UserID, so a character uuid is the bridge. **Client**: all panel
  state is keyed by `CurrentPlayer.PlayerId` (`NativeRenameUI` `panels[id]`, `NativeConfigUI`
  per-viewport `sessions[id]`) and every node lookup is scoped to a viewport
  (`examineNodeById` / `findNamedIn` / `liveFieldIn`), so every player examines, names, and opens
  settings independently. Trap: opening one Examine panel REBUILDS the other open panels' field
  elements (a shared re-layout) which silently kills our `Subscribe`d handlers - so already-open
  panels are re-wired after any panel opens (`rewireStale`, EXCLUDING the just-opened one, so a
  single panel / single-player is never disturbed).
- **Localization** (`Shared/LocaKeys.lua` + `Localization/<Language>/NameYourSummons.loca.xml`):
  every user-facing UI string (NOT console commands) is a fixed loca handle, resolved
  by the GAME to the active language - Script Extender exposes no language getter, so the
  game must choose. `LocaKeys.Strings` maps a semantic key to `{ handle, en }`; the same
  handles are the `contentuid`s in the per-language `.loca.xml` tables AND appear inline in
  the XAML. XAML resolves a handle via `{Binding Source='<handle>', Converter={StaticResource
  TranslatedStringConverter}}`; Lua reads it with `LocaKeys.L(key)` (`Ext.Loca.GetTranslatedString`,
  falling back to the English `en`). The `.loca.xml` sources live at the pak ROOT (sibling of
  `Mods/`); `make.ps1 build` compiles each to a binary `.loca` in the temp stage via
  `divine --action convert-loca` and drops the `.xml` (never committed - `*.loca` is gitignored).
  Handles are UUID-style (`h` + a UUID with `-` as `g`), disjoint from the FNV summon-NAME
  handles (a different resolver). To add or change a string, edit all three in lockstep -
  `LocaKeys.Strings`, every `.loca.xml`, and the inline XAML handle; a spec asserts the Lua
  table's uniqueness, English fallbacks, and parity with `SummonClassifier.CATEGORIES`.
  User-facing text is composed CLIENT-side so the viewing player's language applies (the server
  resolves in the host's language): the saved-name row's type label comes from a language-neutral
  token (`SummonClassifier.DescribeKey` -> `{ Creature, Familiar }`, stored/sent, localized in
  `NativeConfigUI`), and the template-name "Summon" fallback is applied client-side too.
- **Closing Examine from Lua** (`closeExaminePanel`): the panel's close runs the
  `CloseWidget` state event (action `<ls:RemoveState/>`) through the widget's own
  `CustomEvent` command. Its parameter must be a BOXED Noesis string, which SE cannot mint,
  so plant one as a `<System:String x:Key="NYS_CloseWidget">` resource in the `Examine.xaml`
  override and read it back live via `element:Resource("NYS_CloseWidget")` (a
  `Noesis::BaseComponent`), then pass it to `CustomEvent:Execute`. This is the general recipe
  for driving any Noesis command that needs a boxed primitive parameter -
  [docs/driving-native-ui-from-lua.md](docs/driving-native-ui-from-lua.md).
- **Multi-summon = ONE panel that swaps through the queue, closed once at the end.**
  Only one Examine panel exists, and `ExamineCommand:Execute` on an already-open panel
  SWAPS its content rather than being ignored, so a group is named in one panel: the
  creature's name is saved live as the player types (debounced `TextChanged`), and an
  explicit Confirm advances the panel to the next queued summon; repeat until the queue
  drains; the player closes the panel once at the end.
  Advancing is the `NYS_ConfirmButton` (`confirmCurrent` -> `onFieldEnter`, which answers over
  `SubmitName` if not yet answered and then swaps), shown via a `Bool NysShowConfirm` on its
  `NYS_ConfirmVM` with the SAME condition as Skip (`#examineQueue > 0`), so it is hidden for
  single summons and on the LAST creature of a group. Confirm is the SOLE advance on BOTH
  layouts - the field's blur is not a commit or advance path (unreliable on controller); a
  single summon or the last of a group needs no advance (its name is already saved live, and
  the server's pending count clears when the panel closes). `showNext` Executes Examine on
  the next request (open, or content-swap if a panel is
  up); the outgoing `current` is always already resolved (answered, skipped, or retracted), so
  `showNext` never aborts it. Because the field's `Text` binding is OneWay and does NOT
  follow a swap, `setFieldText` writes the new creature's name in directly after each swap.
  Skipping one creature is the `NYS_SkipButton` (abort + swap), shown on the same
  `#examineQueue > 0` condition as Confirm (`refreshQueueButtons` toggles both). Closing the panel
  mid-queue skips ALL that is left (`abortRemaining` aborts `current` if unnamed and every
  still-queued request), so the pending count still clears and the pause lifts; a retract of
  the on-screen summon swaps to the next or, if the queue is empty, closes the panel via
  `closeExaminePanel`. After each open/swap, input is ignored for
  `EXAMINE_SETTLE_MS` (`awaitingOpen` gates it) while the swapped-in field settles, then the
  fresh field is wired and its text set - one-shot `Ext.Timer.WaitForRealtime`, not polling;
  an `openGeneration` token makes a superseded settle callback bail (and drain any summon
  queued while it waited) when a retract swaps `current` mid-settle. A failure to open Examine
  (command/handle missing or `Execute` throwing) skips to the next, so the pause never
  deadlocks. Noesis objects are fetched fresh and tested with truthiness (never `== nil`,
  never cached - a stale handle crashes on use).
- **Controller support.** The controller UI is a SEPARATE layout: the game
  loads a different page (`Examine_c.xaml`), so the keyboard override alone leaves
  our controls absent on a controller. Support mirrors the keyboard side:
  `StateMachines/Controller.xaml` overrides the `Examine` state (the base controller
  Examine STATE is named `Examine`, not `Examine_c`; that is only the widget
  filename, and unlike the keyboard state it carries five events, four copied
  verbatim and IE.UICancel deliberately omitted - see below)
  to load our own `GUI/Pages/Examine_c.xaml` - a copy of the game's controller
  Examine page with the same rename bar + gear + Skip + `NYS_SettingsPanel` overlay
  injected next to the inline `{Binding Name}` title (unlike the keyboard page, the
  controller name is inline in the page, not in an external template). A control is
  navigable by the controller ONLY if it carries the game's focusable contract -
  `Focusable` + `ls:MoveFocus.Focusable` + `ls:MoveFocus.FocusMovementMode` +
  `FocusVisualStyle` + a focus-frame template; the two bare `ls:MoveFocus` attrs are
  NOT enough. So our buttons use the game's `FocusableButtonStyleMinimal`
  (`Public/Game/GUI/Library/FocusableControls_c.xaml`, gear icon / "Skip" as content),
  not a custom template - a fully custom template drops the focus wiring and the button
  becomes unreachable.
  Focusable is only half of it - being focused does NOT run a button's `Command` on
  accept. BG3 routes accept through ONE hint button with `BoundEvent="UIAccept"` and
  `Command="{Binding FocusedElement.Command, ElementName=<widget>}"` (copied from the
  game's `SignUp_c`); the base Examine has none, so `NYS_AcceptPrompt` supplies it.
  A focused element with no `Command` (the name field) falls through to its native
  behaviour. The name field is reachable because `LSTextBox`
  is inherently focusable; it carries `ls:MoveFocus.Focusable` permanently but gates real
  navigability through `Focusable` (toggled by `NativeRenameUI`), so a forbidden/plain
  field is skipped, and it sets `OpenVirtualKeyboardOnFocus="False"` (as the game's own
  focusable text boxes) so merely NAVIGATING onto it just highlights it - the on-screen
  keyboard opens on accept, not on focus. Lua deltas (`NativeRenameUI.lua`): `examineNode`
  accepts `Examine` OR `Examine_c`; `isControllerPanel` (the `Examine_c` node is
  present) tells the layouts apart; lifecycle needs no controller-specific detector -
  `Controller.xaml` extends the same `PlayerHUD` state with `NysHudOverlay`, so its
  `b:DataTrigger` detects the controller Examine open exactly as on keyboard, with no input hook
  or stick-axis polling. `wirePanel` auto-enables editing for a renamable summon (keyboard and
  controller alike).
  **Advancing a queued multi-summon is the explicit Confirm button.** The
  `NYS_ConfirmButton` (`confirmCurrent` -> `onFieldEnter`) is the sole advance trigger on BOTH
  layouts, stacked above Skip and focusable via `FocusableButtonStyleMinimal`; the field blur is
  not a commit or advance path. The name itself is saved live as the player types (debounced
  `TextChanged`), so a single summon, the last of a group, or a manual examine needs no
  Confirm and no blur - its name is already saved.
  The settings overlay (`NYS_SettingsPanel`) jumps focus in on open (`ls:SetMoveFocusAction`
  on an `IsVisible=True` trigger) and its text rows set `OpenVirtualKeyboardOnFocus="False"`.
  Trapping focus needs TWO things: `ls:MoveFocus.IsMoveFocusScope` alone does NOT trap
  (navigation still walks into the Examine content behind), so - as the game's `Henchmen_c`
  does - the whole Examine `Panel` is `IsEnabled`-disabled while the overlay is open (disabled
  elements are skipped by navigation), which both traps focus and lets the initial
  `SetMoveFocusAction` land. Circle-closes-only-the-overlay likewise needs a state-machine
  change: a state-level `IE.UICancel -> RemoveState` fires unconditionally and no widget
  handler can veto it, so `Controller.xaml` OMITS it and closes Examine via the
  footer UICancel button (gated `Collapsed` while the overlay is open); the overlay's own
  `ls:LSInputBinding BoundEvent="UICancel"` (enabled on `NysIsOpen`) then handles Circle to
  close just it. Its buttons use `FocusableButtonStyleMinimal`. The checkboxes and the
  multi-summon dropdown could not stay as-is on controller (BG3 has no drop-in focusable
  toggle, and a `Popup` flyout is not controller-navigable), so on the controller page each
  checkbox is a `FocusableButtonStyleMinimal` button that toggles a VM bool on accept (the
  `TickBox` inside is a non-interactive state indicator), and the dropdown is three focusable
  choice buttons (the current value bold/accent) reusing the same `NysSelectX` commands. The
  toggles are driven by per-boolean `Nys*Command`s added to `NativeConfigUI`'s viewmodels
  (the keyboard page still uses the mouse `TwoWay`/pill path, unchanged).

## Project Structure

```
NameYourSummons/                     <- pak this folder
  Mods/NameYourSummons/
    meta.lsx                         mod manifest (UUID, name, version)
    mod_publish_logo.png             mod-manager thumbnail (16:9 PNG; found by filename, not referenced in meta.lsx) - see "Mod-manager thumbnail" below
    ScriptExtender/
      Config.json                    RequiredVersion, ModTable, feature flags
      Lua/
        BootstrapServer.lua          server entry point
        BootstrapClient.lua          client entry point
        Shared/
          Channels.lua               net channels, created in both states
          NameWriter.lua             the two writes that do the renaming
          SummonClassifier.lua       pure tag-name -> creature-type category + per-type setting keys
          LocaKeys.lua               UI localisation handles: semantic key -> { handle, en } + L(key)
          Trace.lua                  full-detail JSONL tracing to a per-state file (nys-trace-*.jsonl); !nys_trace toggles
          Util.lua                   uuid / sanitising / key / loca-handle helpers
        Server/
          Store.lua                  ModVar persistence
          Naming.lua                 applying names + diagnostics + reading a summon's tag names
          SummonWatcher.lua          detection, prompting, net handlers
        Client/
          Loca.lua                   client loca handlers (register names broadcast by the server so co-op peers resolve them)
          NativeConfigUI.lua         native (Noesis) settings panel (viewmodel + data flow) opened by the Examine gear (see "Native Examine settings")
          NativeRenameUI.lua         native Examine-panel rename field + gear; owns panel detection and drives NativeConfigUI (see "Native Examine rename")
    GUI/                             UI-mod overlay (packed alongside ScriptExtender)
      metadata.lsf                   UI-mod marker (empty config)
      Pages/Examine.xaml             keyboard Examine override: injects the editable name field, settings gear, and native settings overlay (NYS_SettingsPanel) for summons
      Pages/Examine_c.xaml           controller Examine override: the same controls injected into the game's controller Examine layout, controller-navigable via ls:MoveFocus.Focusable
      Pages/NysHudOverlay.xaml       persistent overlay merged into the always-active PlayerHUD; its b:DataTrigger on the examine target is how the mod detects a manual Examine open (see "Native UI" rule 5)
      StateMachines/Keyboard.xaml    overrides the Examine state to load Examine.xaml, and extends PlayerHUD with NysHudOverlay
      StateMachines/Controller.xaml  overrides the Examine state to load Examine_c.xaml, and extends PlayerHUD with NysHudOverlay
  Localization/<Language>/           UI string tables (pak root, sibling of Mods/); one folder per language
    NameYourSummons.loca.xml         .loca.xml source (committed); make.ps1 build compiles it to binary .loca
```

### Mod-manager thumbnail (known limitation)

`mod_publish_logo.png` sits next to `meta.lsx` by convention (the same path
every Larian-toolkit-published mod uses; it is discovered by filename and is not
referenced in `meta.lsx`). `make.ps1 build` packs the whole `NameYourSummons/`
folder, so the file ships automatically - no build change needed. The source
image is `assets/mod-thumbnail.png` (1920x1080, 16:9); update both if you replace
it.

**It does NOT render in the in-game mod manager for our mod, and cannot.** The
manager reads a mod's description AND thumbnail fresh from the pak at game
startup (neither is cached to disk - confirmed: the description updates on a full
relaunch, nothing in `%LOCALAPPDATA%\...\Baldur's Gate 3` stores it). The
description shows, but the thumbnail stays the grey placeholder: the engine only
populates the card image (`VMModPreview.MainScreenshot.Screenshot`, with a
`HasScreenshotTexture` fallback - see `Mods/ModBrowser/GUI/...` in `Game.pak`)
for mods it downloaded from mod.io, not for a locally-installed `.pak`. Because
Name Your Summons requires the Script Extender it can never be published to
mod.io, so there is no path to an in-game thumbnail. The file is kept anyway: it
is zero-cost, correct by convention, and would light up if the mod were ever
distributed through mod.io.

Note: the mod manager only re-scans a mod's metadata on a full game restart, and
description/thumbnail changes to an already-installed pak may need an uninstall +
reinstall of the pak to take effect.

## Reference docs

For the full tool/documentation map (BG3SE, Osiris, NoesisGUI, LSLib) and the
NoesisGUI facts an agent needs for native UI, see
[docs/bg3-modding-toolchain.md](docs/bg3-modding-toolchain.md). To invoke any
native UI command from Lua - including passing a boxed parameter SE cannot mint -
see [docs/driving-native-ui-from-lua.md](docs/driving-native-ui-from-lua.md). The
essentials:

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
a dot-free temp dir to dodge this. In that stage it also compiles every
`Localization/**/*.loca.xml` into the binary `.loca` the game loads (via
`divine --action convert-loca`) and drops the `.xml`, so only compiled tables ship.
It also stamps the STAGED `meta.lsx` `Version64` build field with the build time
as Unix epoch seconds (UTC) (`Set-StagedBuildTimestamp`) - the build number; the
committed `meta.lsx` keeps build 0. The LOCAL `build` / `deploy` filenames carry it
(`NameYourSummons-X.Y.Z.<epoch>.{pak,zip}`) and the startup line shows it
(`Util.VersionString` appends `.build` when non-zero); since the epoch now makes
each filename unique, `deploy` clears its prior `NameYourSummons-*.pak` from the
Mods folder before copying, so the game never loads two paks of the same mod. The PUBLIC release asset
stays `NameYourSummons-X.Y.Z.zip`: `release.yml` packs with `build -NoBuildNumber`,
which drops the epoch from the filename only - the pak is still stamped. The build
field is 31 bits, so epoch seconds overflow it on 2038-01-19; past that the stamp
and suffix are omitted (a warning) and the filename is `X.Y.Z`. To test a change,
put the built `.pak` in the game's `Mods` folder (see `deploy` above) and restart
the game.

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
| `!nys_list` | list all saved names |
| `!nys_diag` | dump what the game thinks each summon is named |
| `!nys_rename <name>` | rename the host's summons now, no prompt |
| `!nys_clear` | wipe all saved names |
| `!nys_debug` | toggle debug console logging (registered in BOTH states so one call flips both). Off by default: only the startup version line, warnings, and command output print; on shows every routine `Util.Log` |
| `!nys_trace` | toggle full-detail JSONL tracing to `nys-trace-<state>.jsonl` (registered in BOTH states; run from the matching console context) |
| `!nys_uidump` | (client) dump the visual-tree landmark map (named nodes + depth, and per-namescope `:Find` reach for each landmark) to `nys-trace-client.jsonl`; forces tracing on. Use to plan a shallower node anchor |

`!nys_diag` is the primary debugging tool: it dumps the loca handle, what it
resolves to, `CustomName` if present, and the root template. Ask the user to
paste that output when a name will not stick.

`Shared/Trace.lua` writes every channel payload (both directions), watcher
decision, store write, and swallowed pcall failure as one JSON line per event to
`nys-trace-client.jsonl` / `nys-trace-server.jsonl` in
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\`, flushed per
line so the record survives a crash. It is OFF by default; toggle it on with
`!nys_trace` (in both states) when reproducing an issue, then ask the user for
both files instead of pasted console excerpts.

Console logging is quiet by default (issue #106): each state prints ONE startup
line (`Util.Say` with the mod version + "loaded successfully"); after that only
warnings (`Util.Warn`) and user-invoked command output (`Util.Say`) print. Routine
info (`Util.Log` - "Named ...", "Saved name ...", "Reapply ...") is gated behind
`!nys_debug`. So new routine tracing goes through `Util.Log` (hidden unless
debugging); anything a console command prints for the user must use `Util.Say`.

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
./make.ps1 validate-xml  # well-formedness of every XAML / meta.lsx / loca.xml (System.Xml)
./make.ps1 ascii-check   # reject non-ASCII typography in tracked text (CI twin of the pre-commit hook)
./make.ps1 xaml-check    # resolve mod XAML keys/controls/pack assets vs the game or the committed oracle
./make.ps1 xaml-extract  # regenerate the committed xaml-check oracle from the installed game
./make.ps1 loca-check    # compile every .loca.xml with divine (Windows only - see below)
./make.ps1 build         # pack the mod into build/ (.pak + .zip); -Clean wipes first
./make.ps1 deploy        # build, then copy the .pak into BG3's %LOCALAPPDATA% Mods folder
./make.ps1 story-check   # Osiris lint via StoryCompiler --check-only (needs -Bg3Data; no-op if no Story/)
./make.ps1 stats-check   # stats lint via StatParser (needs -Bg3Data; no-op if no Stats/)
./make.ps1 all           # format + lint + typecheck + test + validate-xml + ascii-check (verify locally)
./make.ps1 check         # the read-only twin of `all` (what CI runs)
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
| XML well-formedness | System.Xml | (none) | `./make.ps1 validate-xml` |
| Typography | regex | (mirrors `.githooks/pre-commit`) | `./make.ps1 ascii-check` |
| Loca compile | divine | (none) | `./make.ps1 loca-check` |
| Pak smoke | divine | (none) | `./make.ps1 build` (asserts pak members) |

### Asset gates: local vs CI, and the divine-on-Linux trap

The Lua gates and the two game-data-free asset gates (`validate-xml`,
`ascii-check`) run on `ubuntu-latest` and are folded into `all`/`check`. The
**divine-dependent** gates are split off because **LSLib's `divine` CLI crashes
on POSIX paths** - `Divine/CLI/CommandLineActions.cs::TryToValidatePath` runs
`Uri.IsFile` on a relative `Uri` for any `/abs/path` (uncaught throw) and rejects
`file:///abs/path` as non-rooted, so no input works on Linux (identical on
`master`). Therefore:

- `loca-check` and the `build` pak-smoke gate run on a **`windows-latest`** CI
  job (`ci.yml` `assets`), matching `release.yml`. This is the first time the pak
  is built on a PR - `release.yml` only builds on a tag. They are NOT in
  `all`/`check` (which stay cross-platform); run them locally on Windows.
- **`validate-xml` proves the XML parses, NOT that the Noesis semantics hold.**
  There is no offline validator for Larian's `ls:`/`se:` XAML dialect: the
  controls are compiled game code, not extractable data, so XamlPlayer/Noesis
  cannot load them even with full game data. Real XAML validity is only provable
  in game (the `UI State verification failed` console line).

`xaml-check` resolves the mod's XAML `Static`/`DynamicResource` keys,
`ls:`/`se:`/`noesis:` controls, and `pack://` assets against the game's real UI,
catching typo'd resources/assets that `validate-xml` (well-formedness only)
cannot. It gets the game's identifier universe one of two ways: live from
`-Bg3Data <Data folder>` (the game's `Data` directory, unpacked by `divine` -
exact and always current), or from a committed HMAC oracle so it can also run in
CI with no game install. With neither available (a fork with no secret) it skips
cleanly, so it is not in `all`/`check` but does run as its own CI job. Only the
game can confirm the runtime binding semantics.

The oracle (`xaml-oracle.txt`) is keyed HMAC-SHA-256 (128-bit) digests of every
game key/control/asset identifier - no readable game data, so committing it does
not redistribute Larian's copyrighted XAML. `xaml-extract` regenerates it from
the installed game and must be re-run after a game patch (a stale oracle drifts
into false results). Both `xaml-extract` and the CI job read the salt from
`$env:NYS_XAML_ORACLE_SALT`; the extract salt and the CI secret of the same name
MUST match, or every game reference fails to resolve. No install path is ever
assumed - `-Bg3Data` is explicit.

`story-check` and `stats-check` share that local-only, game-data-backed bucket
and are scaffolded now for content that does not exist yet: `story-check` runs
LSLib `StoryCompiler --check-only` once a `Mods/NameYourSummons/Story/` tree
exists, and `stats-check` runs LSLib `StatParser` once a
`Mods/NameYourSummons/Stats/` tree exists (both tools ship in the vendored
`ExportTool` zip, located via `Get-LslibTool`). Like `xaml-check`, each no-ops
cleanly when its content or `-Bg3Data` is absent, so they never run on the
hosted runners.

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
  disabled - StyLua owns that.
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
  native-UI / timing code into the thin, untested glue (`SummonWatcher`, `Naming`,
  `NativeRenameUI`, `Channels`). When you add such logic, add a spec for it.
- The `.githooks/pre-commit` hook runs `./make.ps1 format-check`, `lint`,
  `validate-xml`, and `xaml-check` when a PowerShell is available, so the
  ASCII-punctuation check still works without one. `xaml-check` skips unless the
  committer has `$env:NYS_XAML_ORACLE_SALT` set. CI enforces every gate
  unconditionally.

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
  patches, so field names change. When a field read returns `nil` unexpectedly,
  suspect a rename and check the current IDE helpers.
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

## Commit conventions

Use the `/workflows:commit` skill (the `workflows@whmade` marketplace plugin);
it reads this section and applies these specifics on top of its generic flow.

Commit messages use the three-block layout: a single-line subject, an optional
wrapped body, and a footer of Git trailers, each block separated by a blank
line.

- **Scope prefix**: an optional lowercase `scope:` prefix when the change is
  confined to one area, using only scopes that match the code layout (e.g.
  `server:`, `client:`, `NameWriter:`, `prompt:`). Do not invent scopes. After
  the prefix, follow the casing `git log` uses.
- **Subject**: imperative mood, first word capitalized when unscoped, no
  trailing period, under ~72 chars. Do not pre-append a PR number in
  parentheses - GitHub's squash-merge adds that when the PR lands.
- **Body**: explain WHY the change is made and the observable in-game behaviour
  before/after when relevant (names not sticking, a summon reverting to its
  default name, a crash). This project cannot be unit-tested, so the body is
  where the reasoning lives. Wrap at ~72-76 chars; use `-` for bullet lists.
- **Punctuation**: ASCII only - see the typography rule in `## Code Standards`.
  No em-dashes, arrows, or smart quotes anywhere in the message.
- **Issue/PR references**: one per line in the footer, never in the subject or
  body prose. Use the non-closing `GitHub: #<number>` style; use `Closes
  #<number>` only when the change fully resolves an issue.
- **AI co-authorship (MANDATORY for AI-generated commits)**: exactly one
  `Co-authored-by:` trailer naming the model in use, with email
  `<noreply@anthropic.com>` and lowercase `Co-authored-by:` - e.g.
  `Co-authored-by: Claude Opus 4.7 <noreply@anthropic.com>`.

Example:

```
server: re-register loca handles before reapplying names

Loading a save dropped every custom summon name: runtime localisation
entries do not survive a restart, so the reapply pass pointed each
summon at a handle that no longer resolved and the name rendered as
nothing. Re-register every saved name's handle on SessionLoaded, before
the reapply pass runs.

GitHub: #12
Co-authored-by: Claude Opus 4.7 <noreply@anthropic.com>
```

## User Interaction

- Clarify open questions before starting work.
- Identify and resolve ambiguities and assumptions up front.
- Because you cannot test in game, surface the exact console command
  (`!nys_diag`, `!nys_rename`, etc.) the user should run to confirm a change.

## Pull requests

Use the `/workflows:github-pr` skill (the `workflows@whmade` marketplace
plugin) for both PR creation and addressing review feedback; it reads this
section and applies these specifics on top of its generic flow.

- **Create from the commit**: `gh pr create --fill` derives the title and body
  from the latest commit, so a well-formed commit (see `## Commit conventions`)
  yields a well-formed PR. Hold the title and body to the same bar as the
  commit message.
- **PR body**: for a user-facing change, note the in-game verification done (or
  the console command a reviewer should run - `!nys_diag`, `!nys_rename`, ...).
  A docs/CI/internal change has no in-game effect to note.
- **News fragment**: every PR MUST add a `news/<id>.<type>.md` fragment (type
  one of `feature`, `bugfix`, `security`, `deprecation`, `removal`) OR carry
  the `no-news-fragment-needed` label, or the `news-fragment-check` workflow
  fails it.
- **Addressing feedback**: reply to every unresolved review thread - even when
  the fix is "done in commit abc123" - and resolve each thread only after the
  fix is pushed and a reply is posted. Push to update the PR; local commits
  alone do not count.
- **Sanctioned rebase patchset**: rebasing the PR's OWN branch onto its base
  branch (`origin/<baseRefName>` - a patch-release PR targets a
  `X.Y-maintenance` branch, not `main`) and `--force-with-lease` pushing it is
  allowed. Never force-push `main`, never plain `--force`, and never `--amend`
  commits already pushed for review.

## Git over SSH

The `origin` remote uses SSH. On this machine only PowerShell can spawn `ssh`;
the bundled bash fails with `cannot spawn ssh`. Run any command that reaches the
remote (`git fetch`, `git push`, SSH-backed `gh`) from PowerShell.

## Completion Checklist

Before considering any task complete, first self-review your changes by
running the `/workflows:scrutinize` skill on them. Then confirm:

1. Documentation (README, this file, docstrings) is accurate for the change.
2. No forbidden Unicode punctuation (the pre-commit hook passes).
3. Every fallible SE call is `pcall`-guarded.
4. Server/client replication is correct for any renaming path touched.
5. `./make.ps1 all` passes - this single command (format, lint, type check,
   LuaUnit tests, XML well-formedness, ASCII typography) is how you verify a
   change locally; do not run the gates piecemeal. The divine-dependent gates
   (`loca-check`, `build`) are Windows-only and run in CI; run them locally on
   Windows if you touched loca or the pak layout. If you cannot run a gate,
   reason through it and say so. Add or update a spec when you change testable
   logic.
6. Any behaviour you could not verify in game is called out explicitly, with
   the console command the user should run to confirm it.
