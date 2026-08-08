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
| KEN (KnowEasier Noesis debugger) | `nexusmods.com/baldursgate3/mods/19849` | Mazzle's in-game live Noesis inspector - object tree + property inspector. See "Inspecting the live tree" below. |
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
  attach handlers with `element:Subscribe("<RoutedEvent>", fn)`. KEN (below) does
  this interactively, so reach for it before hand-rolling a tree-walk.
- **A DataContext can be opaque.** Panels sharing the generic `ui::DCWidget` have
  zero SE-typed fields; read their **dynamic Noesis properties** with
  `dc:GetAllProperties()` / `dc:GetProperty(name)`, not `TypeInfo.Members`. Some
  panels expose a named type (`ls::DCExamine`); `no property named 'X'` hints the
  value lives on a child view-model.
- **Routed events tunnel then bubble:** `PreviewMouseLeftButtonDown` fires before
  `MouseLeftButtonDown`. Prefer the bubbling variant unless you must preempt.
- **Key names are prefixed `Key_`** (`Key_Enter`, `Key_LeftShift`).
- **Invoke native commands from SE.** View-model DataContexts expose the game's
  `ui::DeferredCommand`s as `Noesis::BaseCommand` objects (e.g. `ExamineCommand`,
  `ShowProfileCommand`). Fetch one with `dc:GetProperty("XCommand")` and call
  `cmd:CanExecute(param)` / `cmd:Execute(param)`. The parameter must be the exact
  Noesis object the game's XAML binds as that command's `CommandParameter` - a
  light C++ object, not an SE `Entity`, a uuid string, or a number (those raise
  `Param 2: expected a light C++ object` / `Expected Noesis::BaseComponent, got
  Entity`). This drives native UI that has no SE/Osiris entry point - e.g. opening
  the Examine panel even though `Ext.UI.GetStateMachine()` is stubbed (see KEN,
  below).

### Inspecting the live tree: KEN

Mazzle's KnowEasier Noesis debugger (KEN,
`nexusmods.com/baldursgate3/mods/19849`) is the interactive form of the manual
introspection above: an in-game, Script-Extender-based inspector with a
left-hand Noesis object tree (rooted at `ContentRoot` or the main root, listing
both logical children and visual children) and a right-hand property inspector
that dumps every property a selected object holds or inherits - including the
opaque `DataContext` values we otherwise probe with `dc:GetAllProperties()`. It
also generates a copy-pasteable path expression for any node.

Install and use (learned the hard way):

- **KEN depends on MCM** (Mod Configuration Menu,
  `nexusmods.com/baldursgate3/mods/9162`). Without it KEN's client script dies at
  load (`attempt to index a nil value (global 'MCM')`) and never shows a window.
  Install MCM (plus its own requirements), load it before KEN, and restart.
- The generated `FindChildWithName(...)` steps are a **display-only placeholder** -
  substitute a real child lookup (the visual-tree DFS by `.Name` that
  `NativeRenameUI` uses). The tree *shape* KEN shows is accurate.
- The inspector is read-only and shows only *live* state, so the panel you want
  must be open; its search filters tree nodes, not property names.

Verdict, from a live session driving KEN against this mod's issues:

- **General / #9 (shipped):** KEN maps our injected `NYS_NameInput` field (full
  visual path in two clicks) and the examined creature's DataContext
  (`EntityUUID`, `CharacterType`, `EntityHandle`). It replaces hand-rolled
  tree-walk diagnostics outright.
- **#19 (open Examine without the stubbed state machine) - mechanism solved.**
  KEN surfaced that the root DataContext (`ui::DCWidget`) exposes an
  `ExamineCommand`. Using the "invoke native commands from SE" technique above,
  `ExamineCommand:Execute(handle)` opens the Examine panel, where `handle` is the
  target's Noesis `EntityHandle` - the `CommandParameter` the game's own XAML
  binds (`CursorText.xaml`, `Overlay_c.xaml`, and the context-menu items all pass
  `{Binding ...EntityHandle}`). Read that handle off a live DataContext by
  `EntityUUID` - the always-on `PlayerPortraits` carry it - with the same
  visual-tree DFS `NativeRenameUI` already uses. Confirmed end to end in the SE
  console: find the summon DC by uuid -> read `EntityHandle` ->
  `ExamineCommand:Execute` -> Examine opens, no state machine. Only feature wiring
  (when to fire, replacing the custom prompt, the co-op path) remains.
- **#20 (native settings window):** the options page lives under `ContentRoot`
  with `UIData.ActiveState` = `GameOptions` / `VideoOptions` (per tab); its
  controls are `ls.GameData`-typed. KEN reads those controls and bindings so we
  can model a native config page on them. Not yet prototyped.

Bottom line: adopt KEN as the default live-Noesis introspection tool, and keep
the command-invocation technique it revealed - together they turn "the state
machine is stubbed, so we cannot" into a solved path.

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
