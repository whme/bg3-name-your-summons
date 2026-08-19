# Architecture

How Name Your Summons works away from the client UI: detection, classification,
the rename primitive, persistence, keys, multi-summon semantics, and
localization. For anything involving the Examine panel, viewmodels, or XAML, see
[native-ui.md](native-ui.md) and [examine-panel.md](examine-panel.md) instead.

## What the mod does

Name Your Summons lets the player name a summoned creature, remembers the name,
and reapplies it automatically the next time the same creature is summoned. It is
built on Norbyte's Script Extender (BG3SE), API v30. It is pure Lua - there is no
compiler and no build step. A LuaUnit suite covers the engine-independent logic
(see [build-and-gates.md](build-and-gates.md)), but the mod's actual behaviour can
only be exercised in game.

## The two Lua states

BG3SE runs a single **server** state and one **client** state per connected peer.
Server owns detection, persistence, and name application; client owns the native
Examine rename field, settings gear, and saved-name manager.

## Detection pipeline

There is no "summon created" Osiris event. Detection is `Osi.EnteredLevel` ->
`Osi.IsSummon` -> `Osi.CharacterGetOwner`. This covers Find Familiar, Find
Companion, Conjure Animals, Animate Dead, and anything else the game classifies
as a summon, with no per-spell casing.

The `SummonCreatedEvent` / `SummonOwnerSetEvent` ECS components have no structure
known to SE, so they are not usable as a signal.

Summons are not fully assembled on the tick they enter the level. The delays in
`SummonWatcher.lua` and `Naming.lua` exist for that reason. If names
intermittently fail on a slower machine, the delays are the first suspect - do
not remove them.

## Creature-type filter

`Shared/SummonClassifier.lua` gates which summons are prompted for, by type. A
summon's type is read from its character tags - each of the 14 D&D creature types
is a plain tag (`UNDEAD`, `BEAST`, ...), and `FIND_FAMILIAR` marks Find Familiar
summons and takes priority over the creature type. The classifier is pure (tag
names in, category out); the glue that resolves a live summon's tag GUIDs to
names is `Naming.TagNamesOf`.

Per-type toggles live in settings; only familiars are named by default, and a
`NameEverySummon` master names every summon regardless of type.

## The renaming primitive

`Shared/NameWriter.lua`. A creature's name is `DisplayName.Name`, a localisation
handle rather than text. Renaming is two writes - register the text under a
handle of the mod's own via `Ext.Loca.UpdateTranslatedString`, then point
`Name.Handle` at it with `Version = 0`.

Never overwrite the template's shared handle: every creature from that template
shares it, so doing so renames all of them, in every save, until the game
restarts.

Loca handles are derived from the name text (FNV-1a), never from the entity. This
keeps them reproducible after a load and bounded to one handle per distinct name.

## Server <-> client

The NetChannel API (`Ext.Net.CreateChannel`), created in both states in
`Shared/Channels.lua`. The deprecated NetMessage API is not used.

Only the server calls `e:Replicate(...)`; a client applies to its own local view.
Get this wrong and names either do not propagate to co-op peers or double-apply.

## Persistence

Names live in ModVars (`Ext.Vars.RegisterModVariable`), written into the
savegame. `PersistentVars` is deprecated and not used. A saved value is EITHER
one string (the shared name) OR an array of strings (a "unique set" - one
distinct name per creature of a multi-summon).

## Stable key

A summon's UUID changes every conjure, so the key is
`"<owner uuid>|<root template>"` (`Util.MakeKey`). Owner and template do not
change across re-summons.

Runtime loca entries do not survive a restart, so every saved name's handle is
re-registered on `SessionLoaded` before names are reapplied. Deriving handles
from the name text is what makes that re-registration possible without finding
the entity first.

## Multi-summon

One spell, several creatures of the same type at once (e.g. Conjure Animals):
those creatures share one owner and template, hence one key. The
`MultiSummonMode` setting (`skip` default / `shared` / `unique`) decides
handling.

The summon count is NOT knowable up front - it lives in `StatsFunctors` that Lua
cannot read, and container spells resolve creatures by player choice plus upcast.
So detection stays reactive per-creature:

- `shared` prompts once and applies to every live sibling.
- `unique` prompts per creature (guarded per-UUID) and stores a set.
- `skip` prompts the first creature and retracts (`Channels.RetractPrompt`) if a
  sibling reveals it to be a group.

Re-summoning an already-named key is handled by a debounced per-cast resolver
(`scheduleResolve` -> `resolveGroup`) scoped to only THAT cast's creatures, so
older summons of the type keep their names. It follows the CURRENT
`MultiSummonMode`, not how the value was stored - switching `unique` -> `shared`
collapses the stored set to its first name on the next summon and re-asks once.

The client-side panel flow for a queued group is in
[examine-panel.md](examine-panel.md).

## Split-screen: the server side

One machine is one shared client Lua state but a BG3SE user per split-screen
player (up to four). Nothing here is hardcoded to two; state is keyed per player.

A summon's owner maps to the controlling UserID via `Osi.GetReservedUserID`, so
the saved-name list is filtered to the viewing player (`Util.IsNameVisible`) -
each player sees only summons whose owner they CURRENTLY control. This is
dynamic: when the 2nd controller leaves, that character reverts to the host, so
its names become visible to the host with no re-summon.

`AskName` carries `ViewportChar` - the summoner's controlled character, which
equals that viewport's `CurrentPlayer.SelectedCharacter` client-side and the
server's `Osi.GetCurrentCharacter(reservedUser)` - so the client opens Examine on
the summoner's viewport, not always player 1's. `ListNames` takes a
`ViewerCharacter`; the client's own `CurrentPlayer.UserId` (a small 1/2 index) is
NOT the Osiris UserID, so a character uuid is the bridge.

The client half is in [examine-panel.md](examine-panel.md).

## Localization

`Shared/LocaKeys.lua` + `Localization/<Language>/NameYourSummons.loca.xml`.

Every user-facing UI string (NOT console commands) is a fixed loca handle,
resolved by the GAME to the active language - Script Extender exposes no language
getter, so the game must choose. `LocaKeys.Strings` maps a semantic key to
`{ handle, en }`; the same handles are the `contentuid`s in the per-language
`.loca.xml` tables AND appear inline in the XAML. XAML resolves a handle via
`{Binding Source='<handle>', Converter={StaticResource TranslatedStringConverter}}`;
Lua reads it with `LocaKeys.L(key)` (`Ext.Loca.GetTranslatedString`, falling back
to the English `en`).

The `.loca.xml` sources live at the pak ROOT (sibling of `Mods/`); `make.ps1
build` compiles each to a binary `.loca` in the temp stage via `divine --action
convert-loca` and drops the `.xml` (never committed - `*.loca` is gitignored).

Handles are UUID-style (`h` + a UUID with `-` as `g`), disjoint from the FNV
summon-NAME handles (a different resolver).

**To add or change a string, edit all three in lockstep** - `LocaKeys.Strings`,
every `.loca.xml`, and the inline XAML handle. A spec asserts the Lua table's
uniqueness, English fallbacks, and parity with `SummonClassifier.CATEGORIES`.

User-facing text is composed CLIENT-side so the viewing player's language applies
(the server resolves in the host's language): the saved-name row's type label
comes from a language-neutral token (`SummonClassifier.DescribeKey` ->
`{ Creature, Familiar }`, stored/sent, localized in `NativeConfigUI`), and the
template-name "Summon" fallback is applied client-side too.

## Module map

```
NameYourSummons/                     <- pak this folder
  Mods/NameYourSummons/
    meta.lsx                         mod manifest (UUID, name, version)
    mod_publish_logo.png             mod-manager thumbnail; found by filename, not
                                     referenced in meta.lsx (see build-and-gates.md)
    ScriptExtender/
      Config.json                    RequiredVersion, ModTable, feature flags
      Lua/
        BootstrapServer.lua          server entry point
        BootstrapClient.lua          client entry point
        Shared/
          Channels.lua               net channels, created in both states
          NameWriter.lua             the two writes that do the renaming
          SummonClassifier.lua       pure tag-name -> creature-type category
          LocaKeys.lua               semantic key -> { handle, en } + L(key)
          Trace.lua                  JSONL tracing (see ingame-debugging.md)
          Util.lua                   uuid / sanitising / key / loca-handle helpers
        Server/
          Store.lua                  ModVar persistence
          Naming.lua                 applying names + diagnostics + tag names
          SummonWatcher.lua          detection, prompting, net handlers
        Client/
          Loca.lua                   register names broadcast by the server
          NativeConfigUI.lua         native settings panel (see examine-panel.md)
          NativeRenameUI.lua         Examine rename field + panel detection
    GUI/                             UI-mod overlay (see native-ui.md)
      metadata.lsf                   UI-mod marker (empty config)
      Pages/Examine.xaml             keyboard Examine override
      Pages/Examine_c.xaml           controller Examine override
      Pages/NysHudOverlay.xaml       persistent overlay merged into PlayerHUD
      StateMachines/Keyboard.xaml    Examine state override + PlayerHUD extend
      StateMachines/Controller.xaml  Examine state override + PlayerHUD extend
  Localization/<Language>/           UI string tables (pak root, sibling of Mods/)
    NameYourSummons.loca.xml         .loca.xml source (committed)
```

Two placement facts a file listing does not tell you: `Localization/` sits at the
**pak root, sibling of `Mods/`**, and `mod_publish_logo.png` is found by
filename, not referenced in `meta.lsx`.

## Why the development patterns are what they are

- **`pcall` every fallible SE call.** Entities may be dead, components may be
  absent, and a raw error tears down the Lua state. Log a warning and continue
  rather than propagating.
- **Deferred ECS ops.** `entity:CreateComponent(...)` writes to the command
  buffer; the component is not present until the frame flushes, so the next line
  still reads `nil`. Prefer writing a field on a component that already exists.
- **API drift.** BG3SE tracks game builds and component layouts shift between
  patches, so field names change. When a field read returns `nil` unexpectedly,
  suspect a rename and check the current IDE helpers.
- **`RequiredVersion` guards the API version, not the component layout.** A
  matching version does not guarantee a field still exists.

## Testing posture

Client input is trusted but sanitised (length-clamped, control characters
stripped) - keep it sanitised, but do not assume it is authenticated.

Multiplayer is wired (`SendToClient(payload, ownerGuid)` targets only the
summoner) but untested; flag changes that could affect the co-op path.

Keep pure logic (key derivation, hashing, sanitising, ModVar shaping, the two
`DisplayName` writes) free of direct engine calls so it stays testable. Push
unavoidable ECS / net / native-UI / timing code into the thin, untested glue
(`SummonWatcher`, `Naming`, `NativeRenameUI`, `Channels`). When you add such
logic, add a spec for it.
