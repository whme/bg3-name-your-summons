# Native UI: the engine contract

The proven methods for driving BG3's NoesisGUI from Script Extender. This file
is about the **engine**; what our own panels do with it is
[examine-panel.md](examine-panel.md).

Every action in BG3's UI - opening the Examine panel, closing a popup, pressing
an in-game button - is a Noesis (WPF-style) *command* bound in the game's XAML.
Lua reaches those commands through live DataContexts, and that is the entry
point for all of it.

## The five ways in

Implement and extend native UI this way. There is one proven approach per
problem; do not invent a sixth.

1. **Open a game panel** (Examine) - fetch `ExamineCommand` off the HUD
   command-surface DataContext (a `ui::DCWidget` carrying ~200 of the game's
   `ui::DeferredCommand`s, inherited onto the always-present `HudIndicator` node
   under `ContentRoot`) and `Execute` it with the target's Noesis `EntityHandle`.
   On an already-open panel this SWAPS the content, so a queue of targets is
   shown through one panel.
2. **Our own overlay** - set our viewmodel as an element's `DataContext` and flip
   a `Bool` visibility prop.
3. **Panels we own** - MVVM via `Ext.UI.RegisterType` / `Ext.UI.Instantiate`
   (`Bool` / `Collection` / `Command` props, every field prefixed `Nys`).
4. **Controls on a game DataContext** - buttons we add get their own nested
   DataContext plus a `Command` binding; a text field reports edits through its
   own per-element `Subscribe` handler. Both work on the FIRST panel opened.
   Commit an edit from that handler (debounced), so the save stands on its own
   rather than on a focus change.
5. **Detecting a game panel open** - own a persistent widget in an always-active
   game state and read the panel state from a game binding inside it. See
   "Detecting a panel open" below.

## NoesisGUI: where BG3 deviates from plain WPF

- **Build every control from Larian's `ls:` set** - `ls:LSButton`,
  `ls:LSTextBox`, `ls:UIWidget` and friends - copying the styles out of the
  game's own XAML. Those carry the theme templates the page verifier requires; a
  bare WPF `<Button>` / `<TextBox>` / `<ToggleButton>` logs
  `UI State verification failed` and the page will not load.
- **Read a DataContext through its dynamic Noesis properties.** Panels sharing
  the generic `ui::DCWidget` keep their fields there, so use
  `dc:GetAllProperties()` / `dc:GetProperty(name)` rather than
  `TypeInfo.Members`.
- **Per-entity view-models** expose `EntityUUID`, `CharacterType`, and a Noesis
  `EntityHandle`. That `EntityHandle` is the object entity-commands take as their
  `CommandParameter` (confirmed against the game's XAML). `CurrentPlayer` exposes
  `SelectedCharacter` and `PlayerId`.
- **Host any panel of your own inside a page you already override**, and drive it
  through commands.
- **Introspect the live tree** from `Ext.UI.GetRoot()`, walking
  `.VisualChildrenCount` / `:VisualChild(i)` and reading `.Name` / `.DataContext`;
  attach handlers with `element:Subscribe("<RoutedEvent>", fn)`. KEN (the in-game
  Noesis inspector, see [bg3-modding-toolchain.md](bg3-modding-toolchain.md))
  does this interactively - reach for it before hand-rolling a tree walk.

## UI-mod packaging (the `GUI/` tree)

A native UI mod ships a whole `Mods/<Mod>/GUI/` tree; a page on its own logs
`Failed to find statemachine for UI mod`:

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
state-machine replacement. Copy the base state's own events into your override:
whatever you omit is gone, which is a lever rather than a hazard (see the
controller contract). Larian's base UI (Patch 7/8) lives in `Game.pak` under
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

Use the DataContext that the game's XAML binds the command against, not a
different one that merely also has a property of the same name: panel-specific
commands (like a widget's `CustomEvent`) live on that panel's own DataContext.

Fetch the node, DataContext, command, and parameter fresh at each use, and test
them with truthiness: a Lua handle to a Noesis object expires across ticks
(`Attempted to fetch Noesis::BaseObject whose lifetime has expired`), and
`== nil` routes through `__eq`, which throws on an expired one.

### Getting the command parameter

`CanExecute` / `Execute` take the parameter as a `Noesis::BaseComponent`: the
exact object the game's XAML binds as that command's `CommandParameter`. Anything
else is rejected with `Param 2: expected a light C++ object, got string`. There
are two ways to obtain it.

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

Use this whenever the object you need is reachable as an object-typed property of
some live node. For a boxed primitive, use route 2.

#### 2. Plant the object as a XAML resource, then read it back

For a boxed primitive - most commonly a boxed string naming an event - declare
the value as a `System:*` resource in a page you override and read it back with
`element:Resource(key)`, which returns the live boxed `Noesis::BaseComponent`
rather than an unwrapped Lua copy. A `System:String` resource is therefore a
boxed `Noesis::String` you can hand straight to a command:

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
any Noesis command whose parameter is a boxed primitive. Two rules for it:

- Declare one resource per value you need to pass; a resource's content is fixed
  in XAML.
- Declare the resource in a page or tree you override, and read it from within
  that tree: `Resource()` walks up the merged resource dictionaries in scope.

### Worked example: closing the Examine panel

The Examine panel's close button runs, after its animation,
`CustomEvent("CloseWidget")` - a state event whose action is `<ls:RemoveState/>`,
so declare that event in your state override for the close to land. `CustomEvent`
lives on the Examine widget's own DataContext, and its parameter must be the
boxed string `"CloseWidget"`: plant it as a `System:String` resource in the page
override, read it back with `examine:Resource(...)`, and `Execute`. Call site:
`closeExaminePanel` in `Client/NativeRenameUI.lua`; the resource is declared in
both `GUI/Pages/Examine.xaml` and `GUI/Pages/Examine_c.xaml`.

## Navigating the Noesis tree from Lua

- `node:GetProperty(name)` reads a property. Object-typed properties come back as
  live `Noesis::BaseComponent`s; string-typed properties come back as unwrapped
  Lua strings. Scope each lookup to an object you know carries the name - a
  missing one logs a Noesis warning.
- WPF property collections ARE navigable: `node:GetProperty("Triggers")` returns
  a `Noesis::BaseCollection` with a `.Count` and 1-based indexing (`coll[1]`),
  and `GetProperty` works on the nested `Noesis::DependencyObject`s. That name
  resolves to the WPF `FrameworkElement.Triggers`; to use a value the game
  declares inside a Blend `b:Interaction.Triggers` behaviour, declare your own
  copy as a resource and read that (route 2).

### Read the property bag when scanning

For a runtime DataContext property (`EntityUUID`, `CharacterType`, ...), read
`GetAllProperties()` and index the result. Reserve the direct
`dc:GetProperty(key)` for a single known object where you need the live object
rather than a bag copy (e.g. `dc:GetProperty("EntityHandle")` on the one
already-matched view-model): it logs a Noesis warning for every object lacking
the key, and using it while walking the tree costs 238-510 ms to open Examine.

### Anchor every scan

Find `ContentRoot` (near the root), then the panel node by name, and walk only
that subtree. Anchoring bounds the walk to what you actually need, where a fixed
`MAX_DEPTH` over the whole tree is both a magic number and a perf sink.

Use `element:Find(name)` (Noesis `FindNodeName`) for the anchor itself and walk
explicitly below it: it resolves only WITHIN one namescope, so
`GetRoot():Find("ContentRoot")` works while `ContentRoot:Find("HudIndicator")`
does not.

Confirm an `x:Name` in the live tree before anchoring on it - some are
layout-dependent: the party portrait bar is `PlayerPortraits` on keyboard and
`PartyLine_c` on controller, and only one exists at a time.

## Detecting a panel open

To learn that a game panel opened, **own a persistent widget in an always-active
game state**, wire it once, and read the panel state from a game binding inside
it.

1. Merge your own widget into an always-active state via `ModType="Extend"` in
   the state machine (the base game uses `Extend` to add to a state without
   replacing it). The in-game HUD is the `PlayerHUD` state (unpack `Game.pak`
   `Mods/MainUI/GUI/StateMachines/*.xaml` with `divine` to confirm), present on
   both keyboard and controller. Mirror the base state's own attributes for that
   layout - they differ between the keyboard and controller state machines:

   ```xml
   <ls:State Name="PlayerHUD" ModType="Extend" Layout="Player" Owner="Player">
       <ls:State.Widgets>
           <ls:StateWidget Filename="MyOverlay.xaml" Layer="HUD" IgnoreHitTest="True"/>
       </ls:State.Widgets>
   </ls:State>
   ```

2. Inside that widget's `ControlTemplate`, put a `b:DataTrigger` on a game
   DataContext path that changes when the panel opens, invoking a `Command` on a
   VM you set as a child element's `DataContext` (the overlay root inherits the
   player context, so `CurrentPlayer.*` resolves - the same path the game's own
   pages bind):

   ```xml
   <Grid x:Name="MyOverlayRoot" Background="Transparent" IsHitTestVisible="False">
       <b:Interaction.Triggers>
           <b:DataTrigger Binding="{Binding CurrentPlayer.UIData.ExamineTarget.CharacterType}" Value="Summon">
               <b:InvokeCommandAction Command="{Binding DataContext.MyDetectCommand, ElementName=MyVmHost}"/>
           </b:DataTrigger>
       </b:Interaction.Triggers>
       <Grid x:Name="MyVmHost"/>   <!-- Lua sets this element's DataContext to the VM -->
   </Grid>
   ```

3. From Lua, register a VM type carrying a `Command` prop, find the host,
   instantiate the VM, hook the command, and set the VM as the host's
   `DataContext`.

The overlay is always present and the wiring PERSISTS on a live node once set, so
wire once and re-wire on the concrete signals that rebuild the HUD - never by
polling, which SE profiles as `Dispatching user function call ... took X ms`. The
authoritative trigger list is in [examine-panel.md](examine-panel.md).

Run every scan in response to that signal and anchored at a known node: a global
input hook used as a lifecycle detector walks whatever tree is on screen and
crashes on a foreign one such as character creation's.

Two things to build into the handler:

- Reconcile the tree on a short bounded retry: the panel widget lags the
  DataContext being set by up to a few hundred ms.
- Force-fresh the per-panel wiring on every signal. The trigger fires on the
  transition INTO the value, so a close or a same-type swap is covered by that
  re-wire rather than by the trigger.

## Building a viewmodel (`RegisterType` / `Instantiate`)

- **Re-fetch the viewmodel live from the panel at each use**, and use the live
  `context` / `value` inside a `WriteCallback`. The object lives on as the
  DataContext, but a Lua reference to it expires across ticks.
- **To change a `Collection`, rebuild the viewmodel** and set it as the
  DataContext again; that is the only wholly clean list. To remove a single
  element in place, assign `coll[i] = nil`.
- **Prefix every viewmodel field** (we use `Nys`) so it cannot alias a built-in:
  a field named `Name` aliases `FrameworkElement.Name` and round-trips the
  literal string "Name".
- **Make every write idempotent**, guarding by "set only if the value differs".
  WriteCallbacks dispatch ASYNC, so a synchronous re-entry flag cannot suppress a
  deferred toggle and instead cascades exponentially.

## The controller contract

Declare every control you add in BOTH pages: the game loads a separate controller
layout (`Examine_c.xaml`), so a control reaches the controller only if the
controller page has it.

**Focusable.** Give every navigable control all five parts of the game's
focusable contract - `Focusable` + `ls:MoveFocus.Focusable` +
`ls:MoveFocus.FocusMovementMode` + `FocusVisualStyle` + a focus-frame template.
Use the game's
`FocusableButtonStyleMinimal` (`Public/Game/GUI/Library/FocusableControls_c.xaml`)
rather than a custom template, which drops the focus wiring and leaves the button
unreachable.

**Wire accept explicitly.** Add ONE hint button with `BoundEvent="UIAccept"`
and `Command="{Binding FocusedElement.Command, ElementName=<widget>}"` (copy the
game's `SignUp_c`) to your page: that button is what runs the focused element's
`Command`. A focused element with no `Command` falls through to its native
behaviour.

**Text boxes.** `LSTextBox` is inherently focusable. Set
`OpenVirtualKeyboardOnFocus="False"` (as the game's own focusable text boxes do)
so merely navigating onto it just highlights it.

**Trapping focus needs two things**: `ls:MoveFocus.IsMoveFocusScope` on the
overlay AND, as the game's `Henchmen_c` does, `IsEnabled`-disabling the panel
behind it. Navigation skips disabled elements, which both traps focus and lets an
initial `ls:SetMoveFocusAction` land.

**To make Circle close only an overlay**, handle UICancel at widget level:
omit the state-level `IE.UICancel -> RemoveState` from your state override, close
the panel through a footer button with `BoundEvent="UICancel"`, and gate that
button `Collapsed` while the overlay is open, which is what stops it receiving
the event. The overlay's own `ls:LSInputBinding BoundEvent="UICancel"` then
handles Circle. The same Collapsed gating makes Escape close only the overlay on
keyboard.

**Build toggles and dropdowns out of focusable buttons.** A checkbox becomes a
`FocusableButtonStyleMinimal` button that toggles a VM bool on accept, with a
`TickBox` inside as a non-interactive state indicator; a dropdown becomes one
focusable button per choice.

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
