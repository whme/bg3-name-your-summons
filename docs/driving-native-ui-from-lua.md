# Driving native UI from Lua (invoking Noesis commands)

Much of BG3's UI has no Script Extender or Osiris entry point: there is no
`Ext` call to open the Examine panel, close a popup, or press an in-game button.
Those actions are Noesis (WPF-style) *commands* bound in the game's XAML. This
guide is the general method for invoking any of them from Lua, and the trap that
makes it hard - the command parameter must be a real Noesis object, not a Lua
value - plus the technique that gets past it: **plant the object you need as a
XAML resource and read it back**.

An agent cannot run the game, so confirm each step below against Script Extender
console output.

## The mechanism: commands live on view-model DataContexts

The game's view models expose its `ui::DeferredCommand`s as
`Noesis::BaseCommand` objects. You reach one through a live node's DataContext
and call it directly:

```lua
local command = node.DataContext:GetProperty("ExamineCommand")
if command and command:CanExecute(param) then
    command:Execute(param)
end
```

- Find the node by walking the visual tree from `Ext.UI.GetRoot()`
  (`.VisualChildrenCount` / `:VisualChild(i)`, reading `.Name` / `.DataContext`).
  KEN (the in-game Noesis inspector, see
  [bg3-modding-toolchain.md](bg3-modding-toolchain.md)) shows the same tree
  interactively - reach for it before hand-rolling a walk.
- The global command surface (the `ui::DCWidget` inherited onto the
  `HudIndicator` node under `ContentRoot`) carries the game-wide commands
  (`ExamineCommand`, `ShowProfileCommand`, ...). Panel-specific commands (like a
  widget's `CustomEvent`) live on that panel's own DataContext instead - use the
  DataContext that the game's XAML binds the command against, not a different one
  that merely also has a property of the same name.
- `Ext.UI.GetStateMachine()` is stubbed (returns nil) and `Ext.UI.SetState` is
  deprecated (a no-op), so there is no state-machine shortcut - commands are the
  way in.

Never cache a Noesis handle: it expires across ticks
(`Attempted to fetch Noesis::BaseObject whose lifetime has expired`). Fetch the
node, DataContext, command, and parameter fresh at each use, and test them with
truthiness, never `== nil` (equality routes through `__eq`, which throws on an
expired object).

## The trap: the parameter must be a light C++ object

`CanExecute` / `Execute` take the parameter as a `Noesis::BaseComponent`, and the
game's XAML binds a specific object as each command's `CommandParameter`. Passing
a Lua value that is not that object is rejected:

```
Param 2: expected a light C++ object, got string
```

A genuine `nil` is accepted (`CanExecute(nil)` returns true) but is a no-op, so
it does not help. You must obtain the exact Noesis object the command expects.
There are two ways.

### 1. Reuse a live object already in the tree

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

### 2. Plant the object as a XAML resource, then read it back

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
- A XAML change needs the UI reloaded (reopen the panel / reload the save /
  restart), not just an SE `reset` (which reloads only Lua).

## Why the resource is the only mint

SE has no call that produces a boxed `Noesis::String`: `Ext.Types.Construct`
builds only object types, `Ext.UI.Instantiate` builds only `se::`-prefixed
`RegisterType` classes, and a value round-tripped through a viewmodel property
comes back unwrapped (a plain Lua string) or `nil`. The game's own boxed
`CommandParameter` sits in a Blend `Interaction.Triggers` collection that SE
cannot reach (see below). Plant a resource and read it back - that is the way in.

## Navigating the Noesis tree from Lua

Useful when hunting for a live object to reuse:

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

## Worked example: closing the Examine panel

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

## Recipe

1. Identify the command in the game's XAML (extract it with `divine.exe`; see
   [exploring-bg3-internals.md](exploring-bg3-internals.md)) and note the
   `CommandParameter` it binds.
2. Find the DataContext the command is bound against and read the command with
   `dc:GetProperty("XCommand")`.
3. Get the parameter as a real Noesis object:
   - if it is a live object (an `EntityHandle`, another view model), read it off a
     node's DataContext;
   - if it is a boxed primitive, plant a `System:*` resource in a page you
     override and read it with `element:Resource(key)`.
4. `command:CanExecute(param)` then `command:Execute(param)`, all under `pcall`,
   with handles fetched fresh and tested by truthiness.
5. Confirm in game (you cannot run it yourself) and, for XAML changes, reload the
   UI - `reset` alone will not pick them up.
