# BG3 modding toolchain and documentation

The tools a Baldur's Gate 3 mod depends on and where each one's authoritative
docs live, so an agent knows its stack and where to look instead of guessing an
API shape. The NoesisGUI facts themselves are in [native-ui.md](native-ui.md).

## The stack

| Layer | What it is | Used for |
|---|---|---|
| **BG3 Script Extender (BG3SE)** | Norbyte's runtime: injects a Lua VM (two states - server + client-per-peer) and the `Ext`/`Osi` API. | All mod logic. API version pinned in `Config.json`. |
| **Osiris** | The game's story/rules scripting, surfaced as `Osi.*`. | Events and queries (`Osi.EnteredLevel`, `Osi.IsSummon`). |
| **NoesisGUI** | The WPF-compatible XAML UI engine BG3 is built on (markup, data binding, visual trees, routed events). | Native UI work. |
| **LSLib / `divine.exe`** | Norbyte's lib + CLI for BG3's file formats; the packer behind the Modder's Multitool. `make.ps1` fetches it into `.tools/`. | Packing the mod; reading the game's paks (see internals guide). |
| **BG3 Modder's Multitool** | A GUI wrapper around LSLib. | Optional; `divine.exe` does the same from the CLI. |

**File formats:** `.pak` (archive, unpack with `divine.exe`); `.xaml` (NoesisGUI
markup, plain text); `.lsx` (Larian XML, plain text) with binary equivalents
`.lsf`/`.lsb`/`.loca` that `convert-resource` turns into readable `.lsx`/`.xml`;
`meta.lsx` (mod manifest).

## Where the documentation lives

| Source | URL | For |
|---|---|---|
| BG3SE API reference | `github.com/Norbyte/bg3se/blob/main/Docs/API.md` | The `Ext.*` surface. |
| BG3SE IDE helpers | `bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua` | Type/annotation reference for every component and ImGui widget. Grep it rather than guessing. **Can lag the build** - see caveat. |
| BG3SE C++ source | `Norbyte/bg3se` (GitHub code-search) | Ground truth when the helpers are stale - e.g. the real name at a `ThrowEvent("...")` site. |
| Osiris functions / events | `github.com/LaughingLeader/BG3ModdingTools/tree/master/generated` | Osiris call and event signatures. |
| Official modding docs | `docs.baldursgate3.game` (e.g. `Extending_UI`) | Larian's UI-mod / toolkit docs. |
| Community wiki | `wiki.bg3.community` | General modding knowledge and formats. |
| NoesisGUI docs | `noesisengine.com/docs` | The UI engine. Noesis mirrors WPF, so **Microsoft's WPF/XAML docs also apply**. |
| KEN (KnowEasier Noesis debugger) | `nexusmods.com/baldursgate3/mods/19849` | Mazzle's in-game live Noesis inspector - object tree + property inspector. See below. |
| Reference mods | ImpUI `github.com/TheRealDjmr/BG3ImprovedUI`; Advanced Character Sheet `github.com/Coyote-31/bg3-advanced-character-sheet` | Real UI-mod `GUI/` tree, `metadata.lsf`, state machines. |

**Caveat: the IDE helpers and wikis drift behind the installed build.** When a
documented field/event returns `nil` or a `Subscribe` never fires, suspect a
rename and confirm against the extender source. (e.g. the live client event is
`Ext.Events.MouseButtonInput`, not the helper's stale `EclLuaMouseButton`; since
`Ext.Events` is not enumerable, only the source has it.)

## KEN (live Noesis inspection)

Mazzle's KnowEasier Noesis debugger is an in-game, Script-Extender-based
inspector for the live Noesis tree - the interactive form of manually walking
`Ext.UI.GetRoot()`. Reach for it before hand-rolling a tree-walk.

**Install.** KEN depends on MCM (Mod Configuration Menu,
`nexusmods.com/baldursgate3/mods/9162`); without it KEN's client script dies at
load (`attempt to index a nil value (global 'MCM')`) and never shows a window.
Install MCM (plus its own requirements), load it before KEN, and restart.

**Use.**

- The left pane is the object tree (rooted at `ContentRoot` or the main root)
  listing both logical and visual children; the right pane is a property
  inspector that dumps every property an object holds or inherits, including its
  `DataContext` view-model.
- It generates a copy-pasteable path for any node. The `FindChildWithName(...)`
  step is a **display-only placeholder** - substitute a real child lookup; the
  tree *shape* is accurate.
- The inspector is read-only and shows only *live* state, so open the panel you
  want first. Search filters tree nodes (not property names), with
  case/exact/visual-children/depth toggles.

What KEN has already mapped for this mod is recorded in
[native-ui.md](native-ui.md) and [examine-panel.md](examine-panel.md) - read
those before re-deriving it.

## Checklist

1. Identify the layer (logic -> BG3SE/Osiris; UI -> NoesisGUI XAML + `GUI/`
   packaging, see [native-ui.md](native-ui.md)).
2. Read the API from the sources above; grep the IDE helpers for exact shapes.
3. If a field/event misbehaves, confirm the current name from bg3se source.
4. To read the game's own files, see
   [exploring-bg3-internals.md](exploring-bg3-internals.md).
