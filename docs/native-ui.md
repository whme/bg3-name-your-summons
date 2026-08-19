# Native UI: the engine contract

What Script Extender can and cannot do to BG3's NoesisGUI, and the proven method
for each thing it can. This file is about the **engine**; what our own panels do
with it is [examine-panel.md](examine-panel.md).

Much of BG3's UI has no Script Extender or Osiris entry point: there is no `Ext`
call to open the Examine panel, close a popup, or press an in-game button. Those
actions are Noesis (WPF-style) *commands* bound in the game's XAML.

An agent cannot run the game, so confirm each step below against Script Extender
console output.

## The five ways in

Implement and extend native UI this way. There is one proven approach per
problem; do not invent a sixth.

1. **Open a game panel** (Examine) - fetch `ExamineCommand` off the HUD
   command-surface DataContext (a `ui::DCWidget` with ~200 game commands,
   inherited onto the always-present `HudIndicator` node under `ContentRoot`;
   `ContentRoot`'s OWN DataContext does not expose it) and `Execute` it with the
   target's Noesis `EntityHandle`. On an already-open panel this SWAPS content.
2. **Our own overlay** (settings) - set our viewmodel as the element
   `DataContext` and flip a `Bool` visibility prop. There is no window API;
   `Ext.UI.GetStateMachine()` is nil.
3. **Panels we own** - MVVM via `Ext.UI.RegisterType` / `Ext.UI.Instantiate`
   (`Bool` / `Collection` / `Command` props, every field prefixed `Nys`).
4. **Controls on a game DataContext** (the rename bar) - buttons we add get their
   own nested DataContext plus a `Command` binding; a field commits via
   per-element key/focus subscriptions. These work on the FIRST panel; do NOT
   hit-test with a global mouse hook.
5. **Detecting a game panel open** - own a persistent widget in an always-active
   game state and read the panel state from a game binding inside it. See
   "Detecting a panel open" below.

## NoesisGUI: what is not obvious from WPF alone

- **Use Larian's `ls:` controls, not bare WPF ones.** BG3's Noesis theme has no
  template for a plain `<Button>`/`<TextBox>`/`<ToggleButton>`, so one fails UI
  verification and the page will not load. Use `ls:LSButton`, `ls:LSTextBox`,
  `ls:UIWidget`, etc. (find styles by extracting the game's XAML).
- **Introspect the live tree** via `Ext.UI.GetRoot()`, then walk
  `.VisualChildrenCount` / `:VisualChild(i)`, reading `.Name` / `.DataContext`;
  attach handlers with `element:Subscribe("<RoutedEvent>", fn)`. KEN (the in-game
  Noesis inspector, see [bg3-modding-toolchain.md](bg3-modding-toolchain.md))
  does this interactively - reach for it before hand-rolling a tree-walk.
- **A DataContext can be opaque.** Panels sharing the generic `ui::DCWidget` have
  zero SE-typed fields; read their **dynamic Noesis properties** with
  `dc:GetAllProperties()` / `dc:GetProperty(name)`, not `TypeInfo.Members`. Some
  panels expose a named type (`ls::DCExamine`); `no property named 'X'` hints the
  value lives on a child view-model.
- **Routed events tunnel then bubble:** `PreviewMouseLeftButtonDown` fires before
  `MouseLeftButtonDown`. Prefer the bubbling variant unless you must preempt.
- **Key names are prefixed `Key_`** (`Key_Enter`, `Key_LeftShift`).
- **`Ext.UI.GetStateMachine()` is stubbed** (returns nil) and `Ext.UI.SetState` is
  deprecated (a no-op), so there is no state-machine shortcut - commands are the
  way in.

### What KEN has mapped (reusable facts)

- `ContentRoot` is the composition root; panels hang off it by name (`Examine`,
  `PlayerPortraits`, ...), and `PlayerPortraits` is always present.
- A `ui::DCWidget` DataContext carries the global command surface - ~200 of the
  game's `ui::DeferredCommand`s as `Noesis::BaseCommand` objects - plus platform
  flags. It is NOT on `ContentRoot`'s own DataContext; it is inherited onto HUD
  nodes, so read it off an always-present one such as `HudIndicator`.
- Per-entity view-models expose `EntityUUID`, `CharacterType`, and a Noesis
  `EntityHandle`; that `EntityHandle` is the object entity-commands take as their
  `CommandParameter` (confirmed against the game's XAML). `CurrentPlayer` exposes
  `SelectedCharacter` and the party `AssignedCharacters` collection.
- The options page uses `UIData.ActiveState` = `GameOptions` / `VideoOptions`
  (per tab) with `ls.GameData`-typed controls.

## UI-mod packaging (the `GUI/` tree)

A native UI mod ships a whole `Mods/<Mod>/GUI/` tree - a page alone is rejected
with `Failed to find statemachine for UI mod`:

```
GUI/
  metadata.lsf                 marker that the mod ships UI (mirror ImpUI's)
  Pages/<PageName>.xaml        your override of a base-game page
  StateMachines/Keyboard.xaml  overrides only the states you need
  StateMachines/Controller.xaml
```

Override a page with a state carrying `ModType="Override"` that points at the
bare page filename (it resolves to your own `Pages/`). **States merge by name
across mods**, so override only the one state you need - never ship a full
state-machine replacement. Larian's base UI (Patch 7/8) lives in `Game.pak` under
`Mods/MainUI/GUI/Pages/`; copy the real page as your starting point.

A XAML change ships in the pak, which is read at game launch, so it needs a full
game restart - an SE `reset` reloads only Lua, and reopening the panel reuses the
markup already in memory.

## Invoking a native command from Lua

### The mechanism: commands live on view-model DataContexts

The game's view models expose its `ui::DeferredCommand`s as
`Noesis::BaseCommand` objects. You reach one through a live node's DataContext
and call it directly:

```lua
local command = node.DataContext:GetProperty("ExamineCommand")
if command and command:CanExecute(param) then
    command:Execute(param)
end
```

Panel-specific commands (like a widget's `CustomEvent`) live on that panel's own
DataContext instead - use the DataContext that the game's XAML binds the command
against, not a different one that merely also has a property of the same name.

Never cache a Noesis handle: it expires across ticks
(`Attempted to fetch Noesis::BaseObject whose lifetime has expired`). Fetch the
node, DataContext, command, and parameter fresh at each use, and test them with
truthiness, never `== nil` (equality routes through `__eq`, which throws on an
expired object).

### The trap: the parameter must be a light C++ object

`CanExecute` / `Execute` take the parameter as a `Noesis::BaseComponent`, and the
game's XAML binds a specific object as each command's `CommandParameter`. Passing
a Lua value that is not that object is rejected:

```
Param 2: expected a light C++ object, got string
Expected Noesis::BaseComponent, got Entity
```

A genuine `nil` is accepted (`CanExecute(nil)` returns true) but is a no-op, so
it does not help. You must obtain the exact Noesis object the command expects.
There are two ways.

#### 1. Reuse a live object already in the tree

If the parameter is something the running UI already holds, read it off a live
DataContext. The per-entity portrait view models, for example, expose the
`EntityHandle` that entity commands take:

```lua
-- Open Examine on a summon: ExamineCommand's CommandParameter is the creature's
-- Noesis EntityHandle (a uuid string or an SE Entity is rejected).
local handle = perEntityDataContext:GetProperty("EntityHandle")
examineCommand:Execute(handle)
```

This works whenever the object you need is reachable as an object-typed property
of some live node. It does NOT work for values buried in Blend behaviours (see
"Why the resource is the only mint").

#### 2. Plant the object as a XAML resource, then read it back

Some parameters are boxed primitives - most commonly a boxed string naming an
event. Script Extender cannot mint a boxed Noesis primitive directly, and the
game's own boxed copy is usually unreachable. But **you control your page
overrides**, so put the value in a resource dictionary and read it back as a live
boxed object.

`element:Resource(key)` returns a `Noesis::BaseComponent` - the boxed value, not
an unwrapped Lua copy. A `System:String` resource is therefore a boxed
`Noesis::String` you can hand straight to a command:

```xml
<!-- In your overridden page. xmlns:System="clr-namespace:System;assembly=mscorlib" -->
<ls:UIWidget.Resources>
    <System:String x:Key="NYS_CloseWidget">CloseWidget</System:String>
</ls:UIWidget.Resources>
```

```lua
local param = element:Resource("NYS_CloseWidget") -- boxed Noesis::String
local command = examine.DataContext:GetProperty("CustomEvent")
command:Execute(param)                            -- closes the panel
```

The same pattern works for other boxed primitives (`System:Int32`,
`System:Boolean`, `System:Double`, ...). This is the general recipe for driving
any Noesis command whose parameter is a boxed primitive.

Caveats:
- The resource content is fixed in XAML. To pass one of several values at
  runtime, declare one resource per value (or find a live object of route 1).
- `Resource()` walks up the merged resource dictionaries in scope, so the
  resource must live in a page/tree you override and read from within it.

### Why the resource is the only mint

SE has no call that produces a boxed `Noesis::String`: `Ext.Types.Construct`
builds only object types, `Ext.UI.Instantiate` builds only `se::`-prefixed
`RegisterType` classes, and a value round-tripped through a viewmodel property
comes back unwrapped (a plain Lua string) or `nil`. The game's own boxed
`CommandParameter` sits in a Blend `Interaction.Triggers` collection that SE
cannot reach (see below). Plant a resource and read it back - that is the way in.

### Worked example: closing the Examine panel

The Examine panel's close button runs, after its animation,
`CustomEvent("CloseWidget")` - a state event whose action is `<ls:RemoveState/>`
(see the state machine in `GUI/StateMachines/Keyboard.xaml`). `CustomEvent` is on
the Examine widget's own DataContext and needs `"CloseWidget"` as a boxed string.
Putting it together:

```lua
local function closeExaminePanel()
    local examine = findNamed("Examine")
    if not examine then
        return false
    end
    local command = examine.DataContext:GetProperty("CustomEvent")
    local param = examine:Resource("NYS_CloseWidget") -- planted System:String
    if not command or not param then
        return false
    end
    command:Execute(param)
    return true
end
```

The live implementation (`Client/NativeRenameUI.lua`) guards every call with
`pcall` and fetches each handle fresh; the resource is planted in
`GUI/Pages/Examine.xaml`.

## Navigating the Noesis tree from Lua

- `node:GetProperty(name)` reads a property. Object-typed properties come back as
  live `Noesis::BaseComponent`s; string-typed properties come back as unwrapped
  Lua strings. A missing name logs a Noesis warning, so scope lookups narrowly.
- WPF property collections ARE navigable: `node:GetProperty("Triggers")` returns
  a `Noesis::BaseCollection` with a `.Count` and 1-based indexing (`coll[1]`),
  and `GetProperty` works on the nested `Noesis::DependencyObject`s.
- Blend behaviours are NOT reachable: `b:Interaction.Triggers` is an attached
  property that `GetProperty("Triggers")` cannot name (it returns the WPF
  `FrameworkElement.Triggers` instead), and the element's `DirectProperties()` is
  empty for it. This is why route 2 exists - the game's own boxed
  `CommandParameter` lives here, out of reach.

### Read the property bag when scanning

For a runtime DataContext property (`EntityUUID`, `CharacterType`, ...), read
`GetAllProperties()` and index the result. `dc:GetProperty(key)` logs a Noesis
warning for every object lacking the key, and using it while walking the tree
costs 238-510 ms to open Examine. Use the direct getter only for a single known
object (e.g. `dc:GetProperty("EntityHandle")` on the one already-matched
view-model, where you need the live object rather than a bag copy).

### Anchor every scan; never walk the whole root

Find `ContentRoot` (near the root), then the panel node by name, and DFS only
that subtree. A fixed `MAX_DEPTH` over the whole tree is both a magic number and
a perf sink - anchoring bounds the walk to what you actually need.

`element:Find(name)` (Noesis `FindNodeName`) resolves only WITHIN one namescope:
`GetRoot():Find("ContentRoot")` works, but `ContentRoot:Find("HudIndicator")`
does not. Use it only for the anchor itself and walk explicitly below that.

## Detecting a panel open

BG3SE raises no widget/panel lifecycle event, and the page you override cannot
signal Lua on its own:

- A type declared in XAML from `Ext.UI.RegisterType` (`<se:MyType/>`) is
  instantiated by the XAML parser as a bare `BaseComponent` WITHOUT the
  registered properties, so its `WriteCallback` never fires. The callback only
  reaches instances Lua itself created with `Ext.UI.Instantiate` and set as a
  `DataContext`.
- `Ext.UI.GetRoot().Resources` is not a mutable dictionary from Lua, so a
  Lua-owned VM cannot be injected for a `{DynamicResource}` binding either.
- There is no ECS, netmsg, or Osiris signal for a client-side panel open.

So do not try to make the overridden page announce itself. Instead **own a
persistent widget in an always-active game state**, wire it once, and read the
panel state from a game binding inside it.

1. Merge your own widget into an always-active state via `ModType="Extend"` in
   the state machine (the base game uses `Extend` to add to a state without
   replacing it). The in-game HUD is the `PlayerHUD` state (unpack `Game.pak`
   `Mods/MainUI/GUI/StateMachines/*.xaml` with `divine` to confirm), present on
   both keyboard and controller:

   ```xml
   <ls:State Name="PlayerHUD" ModType="Extend" Layout="Player" Owner="Player">
       <ls:State.Widgets>
           <ls:StateWidget Filename="MyOverlay.xaml" Layer="HUD" IgnoreHitTest="True"/>
       </ls:State.Widgets>
   </ls:State>
   ```

2. In that overlay, put a `b:DataTrigger` on a game DataContext path that changes
   when the panel opens, invoking a `Command` on a VM you set as a child
   element's `DataContext` (the overlay root inherits the player context, so
   `CurrentPlayer.*` resolves - the same path the Examine page uses):

   ```xml
   <Grid x:Name="MyOverlayRoot" IsHitTestVisible="False">
       <b:Interaction.Triggers>
           <b:DataTrigger Binding="{Binding CurrentPlayer.UIData.ExamineTarget.CharacterType}" Value="Summon">
               <b:InvokeCommandAction Command="{Binding DataContext.MyDetectCommand, ElementName=MyVmHost}"/>
           </b:DataTrigger>
       </b:Interaction.Triggers>
       <Grid x:Name="MyVmHost"/>   <!-- Lua sets this element's DataContext to the VM -->
   </Grid>
   ```

3. Wire it from Lua: find the host, instantiate the VM, hook the command, set it
   as the host's `DataContext`.

   ```lua
   Ext.UI.RegisterType("MyDetectVM", {
       MyDetectCommand = { Type = "Command" },
   })
   ```

The overlay is always present and the wiring PERSISTS on a live node once set, so
wire once. The HUD is nonetheless rebuilt with no event, so the wiring must be
re-established on those rebuilds - but **never by polling**. Re-wire on the
concrete rebuild signals; the authoritative trigger list is in
[examine-panel.md](examine-panel.md).

**NEVER use a global input hook as a lifecycle detector.** It walks whatever tree
is on screen and will crash on a foreign tree such as character creation's.

Gotchas:
- The game raises `b:DataTrigger` on a real binding path, but an
  `ls:LSTextBox.Text` OneWay binding does NOT update from the source (an input
  control ignores binding-driven text) - do not use a text box as a passive
  signal readout.
- The panel WIDGET lags the DataContext being set by up to a few hundred ms, so
  the command handler should reconcile on a short bounded retry, not a single
  fixed delay.
- A `DataTrigger` on `== "Summon"` fires on the transition INTO that value, not
  on close or a same-type swap; if you need those, force-fresh your per-panel
  wiring on each signal rather than relying on the trigger alone.

## Viewmodel constraints (`RegisterType` / `Instantiate`)

Four engine constraints govern any panel we own:

- **No standalone-window API** (and `Ext.UI.GetStateMachine()` is stubbed), so a
  panel must live inside a page we already override.
- **A viewmodel/node handle does not survive across ticks.** The object lives on
  as the DataContext but any Lua reference expires. Never cache it; re-fetch live
  from the panel at each use, and use the live `context`/`value` inside a
  `WriteCallback`. Never compare a Noesis object with `== nil`.
- **An SE `Collection` is effectively append-only from Lua.** `Clear` / `RemoveAt`
  / `table.remove` / whole-array assign all fail; the ONE in-place exception is
  `coll[i]=nil`, which removes a single element. The only wholly clean list is a
  fresh viewmodel, so rebuild the whole panel to clear one - guarded by a
  generation counter so a slow reply cannot append to a newer viewmodel.
- **Prefix every viewmodel field `Nys`** so it cannot alias a built-in. An
  unprefixed `Name` aliased `FrameworkElement.Name` and round-tripped the literal
  string "Name".

WriteCallbacks dispatch ASYNC, so make writes idempotent - never guard them with
a synchronous re-entry flag (it cannot suppress a deferred toggle and causes an
exponential cascade).

## The controller contract

The controller UI is a SEPARATE layout: the game loads a different page
(`Examine_c.xaml`), so a keyboard-only override leaves your controls absent on a
controller. Every control added to a game panel must exist in BOTH pages.

**Focusable.** A control is navigable by the controller ONLY if it carries the
game's focusable contract - `Focusable` + `ls:MoveFocus.Focusable` +
`ls:MoveFocus.FocusMovementMode` + `FocusVisualStyle` + a focus-frame template.
The two bare `ls:MoveFocus` attributes are NOT enough. Use the game's
`FocusableButtonStyleMinimal` (`Public/Game/GUI/Library/FocusableControls_c.xaml`)
rather than a custom template - a fully custom template drops the focus wiring
and the button becomes unreachable.

**Focus is not accept.** Being focused does NOT run a button's `Command` on
accept. BG3 routes accept through ONE hint button with `BoundEvent="UIAccept"`
and `Command="{Binding FocusedElement.Command, ElementName=<widget>}"` (copy the
game's `SignUp_c`). A focused element with no `Command` falls through to its
native behaviour.

**Text boxes.** `LSTextBox` is inherently focusable. Set
`OpenVirtualKeyboardOnFocus="False"` (as the game's own focusable text boxes do)
so merely navigating onto it just highlights it.

**Trapping focus needs two things.** `ls:MoveFocus.IsMoveFocusScope` alone does
NOT trap - navigation still walks into the content behind. As the game's
`Henchmen_c` does, also `IsEnabled`-disable the panel behind the overlay;
disabled elements are skipped by navigation, which both traps focus and lets an
initial `ls:SetMoveFocusAction` land.

**A state-level `IE.UICancel -> RemoveState` fires unconditionally** and no widget
handler can veto it. To make Circle close only an overlay, OMIT that event from
your state override and close the panel via a footer UICancel button instead;
the overlay's own `ls:LSInputBinding BoundEvent="UICancel"` then handles Circle.

**BG3 has no drop-in focusable toggle**, and a `Popup` flyout is not
controller-navigable. Substitute a `FocusableButtonStyleMinimal` button that
toggles a VM bool on accept (with a `TickBox` inside as a non-interactive state
indicator), and replace a dropdown with one focusable button per choice.

## Recipe

1. Identify the command in the game's XAML (extract it with `divine.exe`; see
   [exploring-bg3-internals.md](exploring-bg3-internals.md)) and note the
   `CommandParameter` it binds.
2. Find the DataContext the command is bound against and read the command with
   `dc:GetProperty("XCommand")`.
3. Get the parameter as a real Noesis object:
   - if it is a live object (an `EntityHandle`, another view model), read it off
     a node's DataContext;
   - if it is a boxed primitive, plant a `System:*` resource in a page you
     override and read it with `element:Resource(key)`.
4. `command:CanExecute(param)` then `command:Execute(param)`, all under `pcall`,
   with handles fetched fresh and tested by truthiness.
5. Confirm in game (you cannot run it yourself); a XAML change needs a full game
   restart, since the pak is read at launch - `reset` (Lua only) and reopening the
   panel will not pick it up.
