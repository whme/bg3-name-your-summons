# BG3 modding toolchain and documentation

The tools this mod depends on and where each one's authoritative docs live, so
an agent knows its stack and where to look up an API shape. The NoesisGUI facts
themselves are in [native-ui.md](native-ui.md); reading the game's own files is
[exploring-bg3-internals.md](exploring-bg3-internals.md).

## The stack

| Layer | What it is | Used for |
|---|---|---|
| **BG3 Script Extender (BG3SE)** | Norbyte's runtime: injects a Lua VM (one server state, one client state per peer) and the `Ext`/`Osi` API. | All mod logic. The API version it targets is pinned as `RequiredVersion` in `ScriptExtender/Config.json`. |
| **Osiris** | The game's story/rules scripting, surfaced as `Osi.*`. | Events and queries (`Osi.EnteredLevel`, `Osi.IsSummon`). |
| **NoesisGUI** | The XAML UI engine BG3 is built on. | Native UI - see [native-ui.md](native-ui.md). |
| **LSLib / `divine.exe`** | Norbyte's lib + CLI for BG3's file formats. `make.ps1` fetches a pinned release into `.tools/` on first use. | Packing the mod; unpacking the game's paks. |
| **BG3 Modder's Multitool** | A GUI wrapper around LSLib. | The point-and-click equivalent of the `divine.exe` recipes; drive the CLI instead. |

**File formats this mod touches:** `.pak` (the archive it ships as, and the
format the game's own data comes in); `.xaml` (NoesisGUI markup, plain text);
`.lsx` (Larian XML - `meta.lsx`); `.lsf` (binary `.lsx` - `metadata.lsf`);
`.loca` (binary string table, compiled at build time from a plain-XML
`.loca.xml`). Convert the binary ones to readable text per
[exploring-bg3-internals.md](exploring-bg3-internals.md).

## Where the documentation lives

| Source | URL | For |
|---|---|---|
| BG3SE API reference | `github.com/Norbyte/bg3se/blob/main/Docs/API.md` | The `Ext.*` surface. |
| BG3SE IDE helpers | `bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua` | Type/annotation reference for every component and ImGui widget. Grep it rather than guessing a shape, then confirm the name against the source (row below). |
| BG3SE C++ source | `Norbyte/bg3se` (GitHub code-search) | The live name of an event or field - search for its `ThrowEvent("...")` / registration site. |
| Osiris functions / events | `github.com/LaughingLeader/BG3ModdingTools/tree/master/generated` | Osiris call and event signatures. |
| Official modding docs | `docs.baldursgate3.game` (e.g. `Extending_UI`) | Larian's UI-mod / toolkit docs. |
| Community wiki | `wiki.bg3.community` | General modding knowledge and formats. |
| NoesisGUI docs | `noesisengine.com/docs` | The UI engine. Noesis mirrors WPF, so **Microsoft's WPF/XAML docs also apply**. |
| KEN (KnowEasier Noesis debugger) | `nexusmods.com/baldursgate3/mods/19849` | Mazzle's in-game live Noesis inspector - object tree + property inspector. See below. |
| Reference mods | ImpUI `github.com/TheRealDjmr/BG3ImprovedUI`; Advanced Character Sheet `github.com/Coyote-31/bg3-advanced-character-sheet` | Real UI-mod `GUI/` tree, `metadata.lsf`, state machines. |

**Confirm an event or field name against the extender source before relying on
it.** The helpers and wikis track their own release, the game tracks its; the
C++ source is the one that matches the installed build. Code-search `bg3se` for
the `ThrowEvent("...")` site - that is how the live client event resolves to
`Ext.Events.MouseButtonInput`, which the helpers list under an older name and
`Ext.Events` does not enumerate at runtime. Read a `nil` field or a `Subscribe`
that never fires as a rename, and re-derive the name the same way.

## KEN (live Noesis inspection)

Reach for KEN before hand-rolling a tree-walk: it inspects the live Noesis tree
in game.

**Install.** Install MCM (Mod Configuration Menu,
`nexusmods.com/baldursgate3/mods/9162`) plus its own requirements, order it
ahead of KEN in the load order, and restart - KEN's client script indexes the
`MCM` global at load.

**Use.** Open the panel you want in game first: the inspector is read-only and
reads live state. The left pane is the object tree, the right pane a property
inspector that dumps every property an object holds or inherits, including its
`DataContext`. Search filters tree nodes by name (case/exact/visual-children/
depth toggles); to find a property, select the object and read its inspector
list. In the node path KEN generates, substitute a real child lookup for the
`FindChildWithName(...)` step - the tree shape it shows is accurate.

What KEN has already mapped for this mod is recorded in
[native-ui.md](native-ui.md) and [examine-panel.md](examine-panel.md) - read
those before re-deriving it.
