# The Examine panel: our implementation

What the mod builds on the engine contract in [native-ui.md](native-ui.md): the
rename UI, the settings overlay, the on-summon prompt, and how they behave in
split-screen and on a controller. The server side is in
[architecture.md](architecture.md).

## The rename bar

The mod overrides the game's Examine page to add a name field and a settings gear for
summons. Typing in the field saves the name. A story-bound summon the player has not
opted into renaming is shown as plain, non-editable text rather than an input field.

## The settings overlay

The gear opens a native settings panel covering the prompt options, the
per-creature-type filter, the multi-summon mode, and a saved-name manager. Every
change applies live, so there is no save button, and the panel is rebuilt when it
opens rather than mutated in place.

## The on-summon prompt

The naming prompt reuses the Examine panel. The pending count and the world pause
live on the server, while the client owns its per-viewport panel and queue state; the
client opens Examine on the new summon and sends the typed name back.

## Multi-summon

A group is named through the single Examine panel, which swaps its content from one
creature to the next as the player confirms each. Closing the panel skips whatever is
left, and the server's pause always lifts.

## Split-screen and controller

All panel state is keyed per viewport, so each player names and configures
independently. One Lua path serves both keyboard and controller; the controller
layout differs only where the engine requires focusable controls.
