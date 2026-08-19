# Architecture

How Name Your Summons works away from the client UI: detection, the rename
primitive, persistence, keys, multi-summon semantics, prompting, and
localization. For anything involving the Examine panel, viewmodels, or XAML, see
[native-ui.md](native-ui.md) and [examine-panel.md](examine-panel.md) instead.

## What the mod does

Name Your Summons lets the player name a summoned creature, remembers the name,
and reapplies it automatically the next time the same creature is summoned. It is
built on Norbyte's Script Extender; `ScriptExtender/Config.json` pins
`RequiredVersion` 30. The pak is a file copy plus a loca conversion, so verify
behaviour by running the game - the gates verify the code. Packaging and the unit
gates are in [build-and-gates.md](build-and-gates.md).

## The two Lua states

BG3SE runs a single **server** state and one **client** state per connected peer.
The server owns detection, persistence, and every write to a creature's name; the
client owns the UI, and its one data write is registering localisation text
(`Client/Loca.lua`).

## Detection

Detect a summon with `Osi.EnteredLevel` -> `Osi.IsSummon` ->
`Osi.CharacterGetOwner`. That covers Find Familiar, Find Companion, Conjure
Animals, Animate Dead, and anything else the game classifies as a summon, with no
per-spell casing. `EnteredLevel` yields the object and its root template, which is
what everything downstream keys off.

Wait before reading a fresh summon: on the tick it enters the level the owner link
and the display name are both still empty. Every delay in `SummonWatcher.lua` and
`Naming.lua`, the owner-lookup retry, and the load-time delay before the reapply
pass in `BootstrapServer.lua` exist for that reason. If names intermittently fail
on a slower machine, suspect the delays first and lengthen them.

## The renaming primitive

`Shared/NameWriter.lua` carries the two writes and the rule that the handle must
be ours. Three facts to carry with it:

- **Register the text under a handle of the mod's own
  (`Ext.Loca.UpdateTranslatedString`) rather than writing the template's shared
  handle**, which renames every creature from that template, in every save, until
  the game is restarted - runtime localisation is process-global and belongs to no
  savegame.
- **Broadcast the text alongside the handle.** Replication carries the handle, and
  a peer's Lua state has its own runtime loca table, so the text goes out
  separately - `ApplyName` per rename, `SeedLoca` in bulk on load - and the client
  re-registers it. Only the server writes `DisplayName` (`Naming.Apply` /
  `Naming.Restore` replicate). A name that replicates but renders as nothing means
  the handle arrived and the text did not.
- **Write a field on the `DisplayName` that already exists.**
  `entity:CreateComponent(...)` writes to the command buffer, so the component is
  still absent on the next line.

## Persistence and the key

Persist names in ModVars (`Ext.Vars.RegisterModVariable`), written into the
savegame. All three ModVars are `Server = true` with `SyncToClient = false`, so
every list, settings read, and settings write the client needs is a channel round
trip.

A summon's UUID changes every conjure, so the stable key is
`"<owner uuid>|<root template>"` (`Util.MakeKey`).

Re-register every saved name's handle on load, before the reapply pass: runtime
loca entries live in the process, not the savegame. Because a handle is derived
from the name TEXT (FNV-1a), that pass can rebuild every handle from the store
alone, before any entity is found. Order matters - register first, then apply, or
the name renders as nothing at all.

## Server <-> client

Send between the states with `Ext.Net.CreateChannel`; every channel is created in
both states in `Shared/Channels.lua`.

## Multi-summon

One spell, several creatures of the same type at once (e.g. Conjure Minor
Elementals): those creatures share one owner and template, hence one key. The
`MultiSummonMode` setting (`skip` default / `shared` / `unique`) decides handling.

Handle a group reactively, one creature per `EnteredLevel`, keyed by owner plus
root template:

- `shared` prompts once and applies to every live sibling.
- `unique` prompts per creature (guarded per-UUID) and stores a set.
- `skip` prompts the first creature and retracts (`Channels.RetractPrompt`) when
  a sibling arrives while that prompt is still open - which is what reveals the
  cast to be a group. It stores nothing, so a later cast under a different mode
  prompts again.

Re-summoning an already-named key runs through a debounced per-cast resolver
(`scheduleResolve` -> `resolveGroup`) scoped to only THAT cast's creatures, so
older summons of the type keep their names. It follows the CURRENT
`MultiSummonMode`, not the shape of the stored value: after switching `unique` ->
`shared`, the next summon applies the set's first entry to the whole cast and (if
`PromptForNamed` is on) re-asks once; the stored set is only replaced when a name
comes back.

### Reading a spell's summon templates from stats

To ask the stats side which creatures a spell can summon, read its functors:

```lua
local spell = Ext.Stats.Get("Target_ConjureElementals_Minor_IceMephit")
for _, f in ipairs(spell.SpellProperties.FunctorList) do
	if f.TypeId == "Summon" then
		-- f.Template is the summoned creature's root template
	end
end
```

`SpellSuccess` has the same shape for spells that summon on a successful roll. A
container spell (Find Familiar, Conjure Elemental, Conjure Minor Elementals) lists
its children in `ContainerSpells`; walk each child spell the same way.
`Ext.Stats.GetCachedSpell(name).ContainerSpells` returns that list as an array.

**NOT YET EXERCISED.** Nothing in this mod calls `Ext.Stats`. The shapes above
come from the BG3SE IDE helpers (`SpellData.SpellProperties` /
`SpellData.SpellSuccess` are `StatsFunctors`, `StatsFunctors.FunctorList` is
`StatsFunctor[]`, `StatsFunctorId` includes `"Summon"`, `StatsSummonFunctor` has
`Template`) and from the game's own
`Public/Shared/Stats/Generated/Data/Spell_Target.txt`. Nobody has run this in
game.

Read the result as the set of templates a spell can produce, and take the count
from the cast rather than from the list length. In the game's own data
`Target_ConjureElementals_Minor_IceMephit` carries two ungated `Summon` functors
on one template (two creatures, one key - exactly the multi-summon case), while
`Target_FindFamiliar_Cat` carries two on one template behind mutually exclusive
`IF(...)` conditions (one creature) and `Target_InvokeDuplicity` carries 23, one
per race and gender (one creature). An exact count therefore takes two further
inputs: each functor's `StatsConditions` evaluated for this caster (it arrives as
a compiled `stats::ConditionId`), and the spell name for the cast in hand, which
means listening for the cast itself. The reactive route above takes neither.

The client-side panel flow for a queued group is in
[examine-panel.md](examine-panel.md).

## Prompting and the world pause

Freeze the world for a prompt with solo turn-based mode (`Osi.ForceTurnBasedMode`
across the party). It is opt-in (`PauseOnPrompt`, off by default), skipped in real
combat, and skipped when the player has already forced turn-based mode, which is
theirs to lift.

`pending` counts OPEN PROMPTS per key, not keys, because `unique` mode opens one
per creature. The pause lifts only when the last one is resolved, so **every
client path that abandons a prompt on its own still answers over `SubmitName`**
(with an empty name to skip) - a silently dropped prompt leaves the world frozen.
The one exception is a server-driven `RetractPrompt`: the server has already
cleared that prompt's count, so the client drops it WITHOUT answering, or the
count would be resolved twice.

## Split-screen: the server side

One machine is one shared client Lua state but a BG3SE user per split-screen
player (up to four). Nothing here is hardcoded to two; state is keyed per player.

A summon's owner maps to the controlling UserID via `Osi.GetReservedUserID`, so
the saved-name list is filtered to the viewing player (`Util.IsNameVisible`) -
each player sees only summons whose owner they CURRENTLY control. This is
dynamic: when the 2nd controller leaves, that character's reserved user flips
back to the host, so its names become visible to the host with no re-summon.

Bridge a viewport to a server-side user with a character uuid (the client's own
`CurrentPlayer.UserId` is a small 1/2 viewport index, unrelated to the Osiris
UserID). `AskName` carries `ViewportChar` (the summoner's controlled character,
which the client matches against its viewport) and `ListNames` takes a
`ViewerCharacter` the server resolves back to a UserID.

The client half is in [examine-panel.md](examine-panel.md).

## Localization

`Shared/LocaKeys.lua` + `Localization/<Language>/NameYourSummons.loca.xml`.

Let the GAME resolve every user-facing string: each one is a fixed handle,
present in three places at once - `LocaKeys.Strings`, the `contentuid` in every
per-language `.loca.xml`, and inline in the XAML. **Change a string and all three
change in lockstep.** Console-command output is plain English by design.

Two specs gate the Lua/XML pair (`spec/locakeys_spec.lua` for uniqueness, English
fallbacks, `[1]` tokens, and parity with `SummonClassifier.CATEGORIES`;
`spec/loca_xml_spec.lua` for per-language parity and duplicate contentuids). Check
the inline XAML handles in game.

These handles are UUID-style (`h` + a UUID with `-` written as `g`) and so are
disjoint from the FNV summon-NAME handles, which go through a different resolver.

Compose user-facing text CLIENT-side, because the server would resolve it in the
HOST's language: the server sends language-neutral tokens
(`SummonClassifier.DescribeKey` -> `{ Creature, Familiar }`, stored in a ModVar so
the list can show a type with nothing alive to read tags from) and the client
localises them. The "Summon" fallback for an unreadable template name is applied
client-side for the same reason.

`make.ps1 build` compiles the `.loca.xml` sources into the binary `.loca` the
game loads - see [build-and-gates.md](build-and-gates.md).

## Where things sit in the pak

Two placement facts:

- `Localization/` sits at the **pak root, a sibling of `Mods/`**.
- `mod_publish_logo.png` is found **by filename** alone (rendering caveat:
  [build-and-gates.md](build-and-gates.md)).

## Trust boundary and testing posture

Client input is trusted but sanitised: names are length-clamped and stripped of
control characters (`Util.Sanitise`), a rename request is shape-checked and
re-confirmed against `Osi.IsSummon`, and settings writes are whitelisted per key
with a type validator. Storage keys arrive from the client as given, so treat
every request as unauthenticated input and keep it sanitised.

Multiplayer is wired and unverified in game: prompts are addressed to the
summoner's client (`SendToClient(payload, ownerGuid)`) while loca text and
settings changes go to everyone. Flag changes that could affect the co-op path.

Keep pure logic (key derivation, hashing, sanitising, ModVar shaping, unique-set
assignment, the two `DisplayName` writes) free of direct engine calls so it stays
testable, and push unavoidable ECS / net / timing code into the thin, untested
glue (`SummonWatcher`, `Naming`, `Channels`). When you add such logic, add a spec
for it.
