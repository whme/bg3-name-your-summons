# BG3 modding toolchain and documentation

The tools a Baldur's Gate 3 mod depends on and where each one's authoritative
docs live, so an agent knows its stack and where to look instead of guessing an
API shape. Most of this was learned the hard way during the native-UI work on
issue #9.

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
| BG3SE IDE helpers | `bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua` | Type/annotation reference for every component and ImGui widget. Grep it. **Can lag the build** - see caveat. |
| BG3SE C++ source | `Norbyte/bg3se` (GitHub code-search) | Ground truth when the helpers are stale - e.g. the real name at a `ThrowEvent("...")` site. |
| Osiris functions / events | `github.com/LaughingLeader/BG3ModdingTools/tree/master/generated` | Osiris call and event signatures. |
| Official modding docs | `docs.baldursgate3.game` (e.g. `Extending_UI`) | Larian's UI-mod / toolkit docs. |
| Community wiki | `wiki.bg3.community` | General modding knowledge and formats. |
| NoesisGUI docs | `noesisengine.com/docs` | The UI engine. Noesis mirrors WPF, so **Microsoft's WPF/XAML docs also apply**. |
| Reference mods | ImpUI `github.com/TheRealDjmr/BG3ImprovedUI`; Advanced Character Sheet `github.com/Coyote-31/bg3-advanced-character-sheet` | Real UI-mod `GUI/` tree, `metadata.lsf`, state machines. |

**Caveat: the IDE helpers and wikis drift behind the installed build.** When a
documented field/event returns `nil` or a `Subscribe` never fires, suspect a
rename and confirm against the extender source. (In #9 the live client event was
`Ext.Events.MouseButtonInput`, not the helper's stale `EclLuaMouseButton`; since
`Ext.Events` is not enumerable, only the source had it.)

## NoesisGUI: what is not obvious from WPF alone

- **Use Larian's `ls:` controls, not bare WPF ones.** BG3's Noesis theme has no
  template for a plain `<Button>`/`<TextBox>`/`<ToggleButton>`, so one fails UI
  verification and the page will not load. Use `ls:LSButton`, `ls:LSTextBox`,
  `ls:UIWidget`, etc. (find styles by extracting the game's XAML).
- **Introspect the live tree** via `Ext.UI.GetRoot()`, then walk
  `.VisualChildrenCount` / `:VisualChild(i)`, reading `.Name` / `.DataContext`;
  attach handlers with `element:Subscribe("<RoutedEvent>", fn)`.
- **A DataContext can be opaque.** Panels sharing the generic `ui::DCWidget` have
  zero SE-typed fields; read their **dynamic Noesis properties** with
  `dc:GetAllProperties()` / `dc:GetProperty(name)`, not `TypeInfo.Members`. Some
  panels expose a named type (`ls::DCExamine`); `no property named 'X'` hints the
  value lives on a child view-model.
- **Routed events tunnel then bubble:** `PreviewMouseLeftButtonDown` fires before
  `MouseLeftButtonDown`. Prefer the bubbling variant unless you must preempt.
- **Key names are prefixed `Key_`** (`Key_Enter`, `Key_LeftShift`).

### UI-mod packaging (the `GUI/` tree)

A native UI mod ships a whole `Mods/<Mod>/GUI/` tree - a page alone is rejected
with `Failed to find statemachine for UI mod`:

```
GUI/
  metadata.lsf                 marker that the mod ships UI (mirror ImpUI's)
  Pages/<PageName>.xaml        your override of a base-game page
  StateMachines/Keyboard.xaml  overrides only the states you need
  StateMachines/Controller.xaml
```

Override a page with a state carrying `ModType="Override"` that points at the
bare page filename (it resolves to your own `Pages/`). **States merge by name
across mods**, so override only the one state you need - never ship a full
state-machine replacement (a total UI overhaul that conflicts with everything).
Larian's base UI (Patch 7/8) lives in `Game.pak` under `Mods/MainUI/GUI/Pages/`;
copy the real page as your starting point.

## Checklist

1. Identify the layer (logic -> BG3SE/Osiris; UI -> NoesisGUI XAML + `GUI/`
   packaging).
2. Read the API from the sources above; grep the IDE helpers for exact shapes.
3. If a field/event misbehaves, confirm the current name from bg3se source.
4. For UI: use `ls:` controls, base off the extracted real XAML, and ship the
   full `GUI/` tree, overriding only the state you need.
