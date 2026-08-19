# Architecture

The server and shared side: how the mod detects, names, and remembers summons. The
client UI is in [native-ui.md](native-ui.md) and [examine-panel.md](examine-panel.md).

## Two Lua states

BG3SE runs one server state and one client state per peer. The server owns
detection, persistence, and every write to a creature's name; the client owns the
UI. Only the server writes names and replicates them to peers.

## Detection

There is no summon-created event the mod can hook, so it watches for a creature
entering the level, asks the game whether it is a summon, and looks up its owner. That one
pipeline covers every summon spell with no per-spell casing. A freshly summoned
creature is not fully assembled the instant it appears, so detection waits before
reading it.

## Naming and the key

A creature's display name is a localisation handle, not text. The mod renames by
registering its own text under a handle of its own and pointing the creature at it -
never at the template's shared handle, which every creature of that template shares.
Runtime localisation is process-global and is not part of a savegame, so names are
persisted separately and their handles rebuilt on load.

Names live in per-mod savegame variables under a key that stays stable across
re-summons (a creature's UUID does not), derived from its owner and template.

## Multi-summon

One spell can produce several creatures of the same type at once. They share a key,
so a setting decides whether to name them all alike, name each individually, or skip
the group. How many a spell will summon is not knowable ahead of time, so the mod
handles a group reactively, one creature at a time.

## Prompting and the world pause

While prompting for a name the mod can optionally freeze the world with solo
turn-based mode. A frozen world must always thaw, so the mod resolves every prompt -
whether the player names it, skips it, or the server retracts it - before lifting the
pause.

## Split-screen

One machine shares a single client state but has a separate engine user per player.
Saved names are filtered to whoever currently controls the summoner, and that
mapping updates as controllers join and leave.

## Localization

Every user-facing string is a fixed handle the game resolves to the active language.
Text is composed on the client so the viewing player's language applies rather than
the host's. Console-command output is plain English by design.

## Trust and testing

Client input is trusted but sanitised; it is never assumed authenticated. Pure logic
is kept engine-free so the unit tests can reach it, while ECS, net, and timing code
stays in thin glue. The game is the only integration test.
