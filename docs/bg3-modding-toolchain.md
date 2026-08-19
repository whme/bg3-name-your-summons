# BG3 modding toolchain and documentation

The tools this mod depends on and where each one's authoritative docs live. The
NoesisGUI concepts are in [native-ui.md](native-ui.md); reading the game's own files
is [exploring-bg3-internals.md](exploring-bg3-internals.md).

## The stack

| Layer | What it is | Used for |
|---|---|---|
| **BG3 Script Extender** | Norbyte's runtime: a Lua VM (one server state, one client per peer) plus the `Ext`/`Osi` API. | All mod logic. |
| **Osiris** | The game's story/rules scripting, surfaced as `Osi.*`. | Events and queries. |
| **NoesisGUI** | The XAML UI engine BG3 is built on. | Native UI. |
| **LSLib / `divine.exe`** | Norbyte's lib and CLI for BG3's file formats. | Packing the mod; unpacking the game's paks. |

## Where the documentation lives

| Source | For |
|---|---|
| BG3SE API reference (`Norbyte/bg3se`, `Docs/API.md`) | The `Ext.*` surface. |
| BG3SE IDE helpers (`ExtIdeHelpers.lua`) | Type reference for every component - grep it rather than guessing a shape. |
| BG3SE C++ source (code-search) | The live name of an event or field, matched to the installed build. |
| Osiris signatures (`LaughingLeader/BG3ModdingTools`) | Osiris call and event shapes. |
| Official docs (`docs.baldursgate3.game`) and community wiki | Larian's UI-mod docs; general modding knowledge. |
| NoesisGUI docs (and Microsoft's WPF docs, which also apply) | The UI engine. |
| KEN (Nexus mod) | An in-game live Noesis inspector - reach for it before hand-rolling a tree walk. |
| Reference mods (ImpUI, Advanced Character Sheet) | Real examples of a UI-mod's GUI tree and state machines. |

Confirm an event or field name against the C++ source before relying on it: the
helpers and wikis track their own release, while the source matches the installed
game. Read a `nil` field or a never-firing subscription as a rename and re-derive the
name there.
