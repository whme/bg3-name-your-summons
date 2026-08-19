# Native UI: the engine contract

How to drive BG3's NoesisGUI from Script Extender, at a conceptual level. Our own
panels are in [examine-panel.md](examine-panel.md).

Most actions in BG3's UI - opening a panel, closing a popup, pressing a button - are
commands bound in the game's XAML, which Lua reaches through the live data contexts
the running UI already holds. Other UI state is read or written as properties on
those same contexts.

## The five ways in

There is one proven approach for each need; do not invent a sixth.

1. **Open a game panel** by executing the game's own command for it.
2. **Show an overlay of our own** by toggling a visibility flag on a view-model we
   set as a data context.
3. **Own a whole panel** through the Script Extender MVVM API.
4. **Add controls onto a game panel**, each with its own nested data context and
   command binding.
5. **Detect that a game panel opened** by watching a binding on a persistent widget
   we own - there is no panel-open event.

## Where BG3 deviates from plain WPF

Build controls from Larian's own control set so they carry the theme templates the
page verifier requires; a bare WPF control fails to load. Read a data context
through its dynamic properties rather than static type information. Per-entity
view-models carry the identifiers the game's commands expect as parameters.

## Packaging

A UI mod ships a whole GUI tree: a marker file, the page overrides, and the state
machines. Override only the one state you need - states merge by name across mods -
carrying over the base state's events, except any you deliberately drop to change
behaviour. A page shipped without its state machine will not load.

## Invoking a command

Reach a command through the exact data context the XAML binds it against, obtain its
parameter as a real engine object - either reused from the live tree or planted as a
XAML resource when it is a value Lua cannot mint - and execute it. Noesis handles
expire between frames, so fetch node, context, command, and parameter fresh each
time and never cache them.

## Scanning the tree

Anchor every scan at a known node and walk only that subtree; never walk the whole
tree, and never on a timer, because a repeating walk visibly hitches the game. When
scanning many nodes, read their properties from the property bag rather than probing
each by name.

## Detecting a panel open

Own a widget that is always in the tree and let a binding inside it fire a command
when the panel's state changes. Wire it once and re-wire only when the HUD is
actually rebuilt - never by polling. A global input hook must never stand in for this:
it walks whatever tree is on screen and crashes on a foreign one.

## View-models

A view-model persists as a data context, but any Lua reference to it expires, so
re-fetch it at each use. Rebuilding it is the clean way to reset a list. Prefix every
field so it cannot collide with a built-in, and make writes idempotent because they
dispatch asynchronously.

## Controller

The controller loads a separate layout, so every control must exist in both pages. A
control is reachable by controller only if it carries the game's full focusable
contract and the page wires the accept button; reuse the game's own focusable styles
rather than rolling your own.
