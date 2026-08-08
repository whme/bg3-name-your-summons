# BG3 modding toolchain and documentation

The tools and reference sources a Baldur's Gate 3 mod actually depends on, and -
crucially - **where the authoritative documentation for each lives.** Written so
an agent picking up a BG3 task knows what stack it is working in and where to
look, instead of guessing an API shape. Much of this was learned the hard way
during the native-UI work on issue #9.

## The stack

| Layer | What it is | You use it for |
|---|---|---|
| **BG3 Script Extender (BG3SE)** | Norbyte's runtime that injects a Lua VM (two states: server + client-per-peer) and exposes the `Ext`/`Osi` API. | All this mod's logic. API version pinned in `Config.json` (`RequiredVersion`). |
| **Osiris** | The game's own story/rules scripting layer. BG3SE surfaces it as `Osi.*`. | Events and queries (`Osi.EnteredLevel`, `Osi.IsSummon`, ...). |
| **NoesisGUI** | The third-party XAML UI engine BG3's interface is built on. WPF-compatible: XAML markup, data binding, control/visual trees, routed events. | Any native UI work (the Examine-screen rename control). |
| **LSLib / `divine.exe`** | Norbyte's library + CLI for BG3's file formats; the packer behind the Modder's Multitool. `make.ps1` fetches a pinned copy into `.tools/`. | Packing the mod; unpacking/reading the game's own paks (see the internals guide). |
| **BG3 Modder's Multitool** | A GUI wrapper around LSLib for people who prefer clicking. | Optional; `divine.exe` does the same from the CLI. |

### File formats you will meet

- `.pak` - the game's archive format (unpack with `divine.exe`).
- `.xaml` - NoesisGUI UI markup (plain text; read directly).
- `.lsx` - Larian XML resource (plain text). `.lsf` / `.lsb` / `.loca` - the
  **binary** equivalents; `divine.exe -a convert-resource` turns them into
  readable `.lsx`/`.xml`.
- `meta.lsx` - mod manifest (UUID, name, version).

## Where the documentation lives

| Source | URL | Use it for |
|---|---|---|
| BG3SE API reference | `github.com/Norbyte/bg3se/blob/main/Docs/API.md` | The `Ext.*` surface: UI, Net, Vars, Loca, Entity, Types, Events. |
| BG3SE IDE helpers | `bg3se/blob/main/BG3Extender/IdeHelpers/ExtIdeHelpers.lua` | Authoritative type/annotation reference - every component and ImGui widget is declared. Grep it rather than guessing. **Can lag the installed build** - see caveat below. |
| BG3SE C++ source | the `Norbyte/bg3se` repo (GitHub code-search) | Ground truth when the IDE helpers are stale - e.g. the real event name at a `ThrowEvent("...")` call site. |
| Osiris functions / events | `github.com/LaughingLeader/BG3ModdingTools/tree/master/generated` | Every Osiris call and event signature. |
| Official BG3 modding docs | `docs.baldursgate3.game` (e.g. `index.php?title=Extending_UI`) | Larian's own UI-mod / toolkit docs. |
| Community wiki | `wiki.bg3.community` | General modding knowledge, formats, conventions. |
| NoesisGUI docs | `noesisengine.com/docs` | The UI engine itself. Because Noesis mirrors WPF, **Microsoft's WPF/XAML docs also apply** for XAML syntax, data binding, control templates, and routed-event (tunnel/bubble) semantics. |
| Reference mods (copy proven techniques) | ImpUI: `github.com/TheRealDjmr/BG3ImprovedUI` ; Advanced Character Sheet: `github.com/Coyote-31/bg3-advanced-character-sheet` | How a real UI mod lays out its `GUI/` tree, `metadata.lsf`, and state machines. |

**Caveat - the IDE helpers and wikis drift behind the installed build.** BG3SE
tracks game builds and component layouts shift between patches; field and event
names get renamed. When a documented field/event returns `nil` or a `Subscribe`
never fires, suspect a rename and confirm against the **extender source**, not
the helpers. (In #9 the live client mouse event was `Ext.Events.MouseButtonInput`
while the helper's `EclLuaMouseButton` was stale; `Ext.Events` is not enumerable,
so the name could only be found in source.)

## NoesisGUI: the facts that are not obvious from WPF alone

BG3's UI is NoesisGUI, so WPF intuition mostly transfers - but a few BG3-specific
realities cost real iteration to discover:

- **Use Larian's `ls:` styled controls, not bare WPF ones.** BG3's Noesis theme
  has no default control template for a plain `<Button>`, `<TextBox>`, or
  `<ToggleButton>`, so instantiating one fails UI-state verification and the page
  will not load. Use `ls:LSButton`, `ls:LSTextBox`, `ls:LSNineSliceImage`,
  `ls:UIWidget`, etc. (find the exact styles by extracting the game's own XAML -
  see the internals guide).
- **Introspect the live tree from Lua** via `Ext.UI.GetRoot()` (returns a Noesis
  framework element), then walk with `.VisualChildrenCount` / `:VisualChild(i)`,
  reading `.Name` and `.DataContext`. Attach handlers with
  `element:Subscribe("<RoutedEvent>", fn)`. For SE-typed objects,
  `Ext.Types.GetObjectType(o)` and `Ext.Types.GetTypeInfo(t).Members` describe
  the shape.
- **A DataContext can be opaque.** Many panels share the generic `ui::DCWidget`,
  which has **zero SE-typed fields** - `GetTypeInfo().Members` shows nothing. Its
  data lives in **Noesis dynamic properties**: read them with
  `dc:GetAllProperties()` / `dc:GetProperty(name)`, not via `TypeInfo.Members`.
  Some panels do expose a named view-model type (e.g. `ls::DCExamine`); an error
  like `Object ls.DCExamine has no property named 'X'` is a useful hint that the
  property lives on a child VM.
- **Routed events tunnel then bubble** (WPF semantics): `PreviewMouseLeftButtonDown`
  fires top-down before `MouseLeftButtonDown` bubbles up. A tunneling handler on a
  parent node can interfere with a child receiving the event - prefer the bubbling
  variant unless you specifically need to preempt.
- **Key names are prefixed `Key_`** (`Key_Enter`, `Key_LeftShift`), not the bare
  WPF key name.

### UI-mod packaging (the `GUI/` tree)

A native UI mod ships a `Mods/<Mod>/GUI/` tree - a page alone is not enough:

```
GUI/
  metadata.lsf                 marker that the mod ships UI (mirror ImpUI's)
  Pages/<PageName>.xaml        your override of a base-game page
  StateMachines/Keyboard.xaml  overrides only the states you need
  StateMachines/Controller.xaml
```

- A UI mod with no state machines is rejected at load:
  `Failed to find statemachine for UI mod`.
- Override a page by defining a state with `ModType="Override"` pointing at the
  bare page filename (which resolves to your own mod's `Pages/`). **States merge
  by name across mods**, so a state machine that overrides only the one state you
  care about leaves every other state merging from the base UI untouched - do not
  ship a full state-machine replacement (that is a total UI overhaul and conflicts
  with everything).
- Larian's base UI (post Patch 7/8) lives in `Game.pak` under
  `Mods/MainUI/GUI/Pages/*.xaml`; copy the real page as your override's starting
  point (extract it per the internals guide).

## Checklist

1. Identify which layer the task touches (logic -> BG3SE/Osiris; UI -> NoesisGUI
   XAML + the `GUI/` packaging).
2. Read the API from the source table above; grep the IDE helpers for exact
   shapes.
3. If a documented field/event misbehaves, confirm the current name from bg3se
   source before trusting the helpers.
4. For UI, use `ls:` controls, extract the real game XAML as your base, and ship
   the full `GUI/` tree (metadata + page + state machines), overriding only the
   state you need.
