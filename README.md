# Name Your Summons — a BG3 mod for naming your summons

Names your summoned creatures, remembers the names, and reapplies them
automatically the next time you summon the same creature. Optionally pops a
text-entry prompt the moment a summon appears.

Built on [Norbyte's Script Extender](https://github.com/Norbyte/bg3se) (BG3SE),
API v30.

---

## 1. What the research turned up

### The modding stack

| Layer | What to use | Notes |
|---|---|---|
| Scripting | **BG3SE** (Norbyte) | The only way to do runtime logic. Lua, split into a **server** state and one **client** state per peer. |
| UI | **`Ext.IMGUI`** (Dear ImGui, built into BG3SE) | Gives you real widgets including `AddInputText`. You do **not** need a third-party UI mod. |
| Settings UI | **MCM** (Mod Configuration Menu) | Optional. Good for a settings tab, wrong tool for a transient "name this thing" prompt. |
| Persistence | **ModVars** (`Ext.Vars.RegisterModVariable`) | Written into the savegame. `PersistentVars` is deprecated. |
| Server↔client | **NetChannel API** (`Ext.Net.CreateChannel`) | Supersedes the deprecated NetMessage API. |
| Packaging | **BG3 Modder's Multitool** or **LSLib/ConverterApp** | Turns the folder into a `.pak`. |
| Load order | **BG3 Mod Manager** (LaughingLeader) | |

Reference docs worth bookmarking:

- API docs — `github.com/Norbyte/bg3se/blob/main/Docs/API.md`
- **IDE helpers** — `bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua` — this is
  the real reference. Every component and ImGui widget is declared here. Grep it.
- Osiris functions / events — `github.com/LaughingLeader/BG3ModdingTools/tree/master/generated`
- Community wiki — `wiki.bg3.community`

### Existing rename mods, and why this one is different

- **"Rename" / "Change Names and Titles"** (Nexus 23570, mod.io) — the closest prior
  art. It renames almost anything, but its input method is a hotbar *made of
  letter spells*: you cast A, then B, then C, then "Finish". That is a clever
  workaround for not having a text field, not a design goal. It also has no
  concept of remembering a name across re-summons.
- **"D83's Named Summons"** (Nexus 16513) — static renames baked into localisation
  files. No user input at all.
- **"How to Rename Your Displacer Beast"** — a tutorial for hand-editing a `.loca`
  file and repacking. Illustrates the manual approach this mod automates.

So: nothing existing does *per-instance, user-entered, persistent* naming with a
real text box. That is the gap this fills.

### The important technical finding

The community wiki's [Changing an entity's name](https://wiki.bg3.community/Tutorials/ScriptExtender/changing-entity-name)
tutorial tells you to do this:

```lua
local handle = entity.DisplayName.NameKey.Handle.Handle
Ext.Loca.UpdateTranslatedString(handle, newName)   -- ⚠ TRAP
```

**Do not use that for summons.** `NameKey.Handle` is a *localisation handle*,
and every entity spawned from the same root template shares it. Renaming one
conjured wolf renames **every** conjured wolf — in this save, in every other
save, until you restart the game. The tutorial's use case (adding a
"Stoneskin" prefix during a status) hides this because the prefix goes on
everything anyway.

What the tutorial *does* prove is that `DisplayName.NameKey` is rendered. So
rather than overwriting the shared handle, this mod mints a handle of its own
and points the entity at that. `Ext.Loca.UpdateTranslatedString` inserts into
the string table (see `TranslatedStringRepository::UpdateTranslatedString` in
the extender source — it's a `set`, not a replace), so a handle that doesn't
exist yet is created rather than rejected, and nothing vanilla is touched.

So the whole of the renaming is these two writes, in `Shared/NameWriter.lua`:

```lua
Ext.Loca.UpdateTranslatedString(handle, "Fenrir")   -- our own handle, freshly minted
entity.DisplayName.NameKey.Handle.Handle  = handle
entity.DisplayName.NameKey.Handle.Version = 0
entity:Replicate("DisplayName")
```

`Version` matters. The lookup is keyed on handle *and* version, and
`UpdateTranslatedString` always registers at version 0. Leave the template's
version in place and the lookup misses, so the name renders as nothing.

Handles are derived from the *name text* (FNV-1a), not from the entity. That
makes them deterministic — trivial to re-register after a load — and bounded:
one handle per distinct name rather than one per summoned instance. Runtime
loca entries are never freed within a session, so per-instance handles leak.

#### Things that look right and are not

**`CustomName`.** `eoc::CustomNameComponent` is a plain per-entity string, which
is exactly the shape you want, and it is where a player character's chosen name
lives. But summons don't have the component, and *adding* one is a structural
ECS change driven from a Lua callback — which crashed the game outright. Not
worth it when a field write on a component that already exists does the job.

**`Osi.SetStoryDisplayName(guid, handle)`.** The engine's own route, through
`EsvDisplayNameSystem`, and it works. It's redundant next to the write above,
though, and it stores the handle in the server's name list, which *is* saved —
so a reloaded save references a handle that no longer exists.

**`entity:CreateComponent(...)` is deferred.** It writes into the ECS command
buffer; the entity does not gain the component until the frame is flushed, so
`entity.CustomName` still reads `nil` on the next line. This is what made the
first version of this mod silently rename nothing. Nothing here needs it any
more, but it's a trap worth knowing. See `CreateComponentRaw` in
`BG3Extender/GameDefinitions/EntitySystem.cpp`.

### There is no "summon created" event

I checked the full generated Osiris event list. There is no `Summoned`,
`SummonCreated`, or equivalent. What exists:

- `Osi.EnteredLevel(object, objectRootTemplate, level)` — fires for anything
  spawning into a level, and hands you the root template for free
- `Osi.IsSummon(guid)` — returns `1` for summons
- `Osi.CharacterGetOwner(character)` — the summoner

So the detection is `EnteredLevel` → `IsSummon` → `CharacterGetOwner`. This covers
Find Familiar, the Ranger's Find Companion, Conjure Animals, Animate Dead, and
anything else the game classifies as a summon — no per-spell special-casing.

(There *are* ECS components — `SummonCreatedEvent`, `SummonOwnerSetEvent`,
`IsSummon`, `SummonContainer` — that you could subscribe to via
`Ext.Entity.OnCreateDeferred`. The two event components have no structure known
to SE, so the Osiris route is the safer bet. `SummonContainer` on the owner *is*
used here, to re-apply names after a save/load.)

### How "keeps its name across re-summons" works

A summon's UUID is new every single time you conjure it, so it cannot be the key.
The stable pair is **owner + root template**:

```
key = "<owner uuid>|<root template>"
```

Your ranger's wolf is always "Fenrir". Gale's familiar cat has its own name.
Different familiar shapes (cat, raven, spider) get separate names, since they are
separate templates — change `Util.MakeKey` if you'd rather they share one.

---

## 2. Layout

```
NameYourSummons/                     <- pak this folder
└── Mods/NameYourSummons/
    ├── meta.lsx
    └── ScriptExtender/
        ├── Config.json
        └── Lua/
            ├── BootstrapServer.lua
            ├── BootstrapClient.lua
            ├── Shared/
            │   ├── Channels.lua     net channels, created in both states
            │   ├── NameWriter.lua   the two writes that do the renaming
            │   └── Util.lua         uuid/sanitising/key/loca-handle helpers
            ├── Server/
            │   ├── Store.lua        ModVar persistence
            │   ├── Naming.lua       applying names + diagnostics
            │   └── SummonWatcher.lua detection, prompting, net handlers
            └── Client/
                └── PromptUI.lua     ImGui prompt + saved-name manager
```

---

## 3. Building and installing

1. **Generate your own UUID.** `meta.lsx` ships with
   `04825fb4-1f56-40ab-8bde-ff1ebfa4c003`. Replace it before you publish anything,
   or two mods will collide.
2. **Pack it.** BG3 Modder's Multitool → *Create Package*, pointed at the
   top-level `NameYourSummons/` folder. Or `divine.exe -a create-package`.
3. Drop the `.pak` in
   `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\`, enable it in BG3 Mod
   Manager, export the load order.

**For development, skip the packing loop entirely.** Symlink the folder into the
game's `Data/` directory, then type `reset` in the SE console to reload Lua
without restarting the game. As of Patch 7 a symlinked mod still has to be
enabled and exported in BG3MM once.

Enable the console in
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\ScriptExtenderSettings.json`:

```json
{ "CreateConsole": true, "DeveloperMode": true }
```

---

## 4. Using it

Summon something. A window appears with a text box pre-filled with the creature's
current name. Type, press Enter (or *Name it*). *Skip* declines, and you won't be
asked again for that creature this session.

Console commands — press Enter to enter console mode first:

| Command | Context | What it does |
|---|---|---|
| `!nys_list` | server | list all saved names |
| `!nys_diag` | server | dump what the game thinks your summons are named |
| `!nys_rename <name>` | server | rename the host's summons right now, no prompt |
| `!nys_clear` | server | wipe all saved names |
| `!nys_ui` | **client** (type `client` first) | open the saved-names manager |

---

## 5. If something goes wrong

Summon something, then `!nys_rename Test1` to rename it without going through
the prompt. `!nys_diag` dumps what the game thinks the summon is called: the
localisation handle, what it resolves to, `CustomName` if the entity has one,
and the root template. That's the output to paste if a name won't stick.

### Other things worth knowing

- **Multiplayer** is wired but untested: the prompt is sent with
  `SendToClient(payload, ownerGuid)` so only the summoner is asked. Names live in
  server-side ModVars, so the host's save owns them.
- **Client input is trusted.** A modified client could submit any string. It's
  sanitised (length-clamped, control characters stripped) but not authenticated.
  Fine for a co-op mod, worth knowing.
- **Timing is empirical.** The 100 ms / 400 ms / 250 ms delays in
  `SummonWatcher.lua` and `Naming.lua` exist because a summon isn't fully assembled
  on the tick it enters the level. If names intermittently fail to stick on a
  slower machine, raise them.
- **Localisation entries don't survive a restart.** Every saved name's handle is
  re-registered on `SessionLoaded`, before any names are re-applied — which
  works only because handles are derived from the text rather than from the
  entity, so they can be reproduced without finding the entity first.
- **Patch breakage.** BG3SE is tied to game builds and component layouts shift
  between patches. `RequiredVersion: 30` in `Config.json` guards the API version,
  not the component layout.
