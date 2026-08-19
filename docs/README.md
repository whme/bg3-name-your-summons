# Documentation index

[AGENTS.md](../AGENTS.md) carries the rules. These files carry the reasoning, the
maps, and the procedures.

**Each fact has one home.** AGENTS.md carries the terse rule; the matching docs/
file carries its mechanism and reasoning. Do not
explain the same mechanism in two docs/ files - delete one and link it. That
layering is deliberate; two *docs/* copies of one explanation is the drift to
avoid.

## Read this when

| You are about to | Read | Scope |
|---|---|---|
| Touch anything under `Lua/Client/` or `GUI/` | [native-ui.md](native-ui.md), THEN [examine-panel.md](examine-panel.md) | The Noesis engine contract, then our panels |
| Change `Lua/Server/` or `Lua/Shared/` behaviour | [architecture.md](architecture.md) | Detection, naming, persistence, keys |
| Add or change a user-facing string | [architecture.md](architecture.md) | Localization: three files change in lockstep |
| Touch `make.ps1`, a workflow, or a quality gate | [build-and-gates.md](build-and-gates.md) | Gates, the CI split, packaging |
| Ask the user to run the game, or read their console output | [ingame-debugging.md](ingame-debugging.md) | Console commands, tracing, the run loop |
| Need a fact about BG3's own XAML, stats, templates, or paks | [exploring-bg3-internals.md](exploring-bg3-internals.md) | Unpacking the game with `divine.exe` |
| Be unsure of an `Ext.*` / `Osi.*` / Noesis API shape | [bg3-modding-toolchain.md](bg3-modding-toolchain.md) | Where the authoritative docs live |
| Set up, build, or cut a release as a contributor | [../CONTRIBUTING.md](../CONTRIBUTING.md) | Human workflow |

## What each file does NOT cover

- **architecture.md** - not the client UI. Panels, viewmodels, and XAML are in
  native-ui.md and examine-panel.md.
- **native-ui.md** - the engine contract only. What OUR panels do is in
  examine-panel.md. In particular: the re-wire trigger list lives in
  examine-panel.md.
- **examine-panel.md** - assumes native-ui.md; does not restate the engine rules.
- **build-and-gates.md** - the gate set and the pak. The human setup and release
  walkthrough is in CONTRIBUTING.md. The `make.ps1` command list is not copied
  here at all - run `./make.ps1 help`.
- **ingame-debugging.md** - how to get a fact out of a running game via the user.
  How to get one out of a pak is exploring-bg3-internals.md.
- **exploring-bg3-internals.md** - reading the game's files. Nothing about our
  own code.

## Maintaining these files

1. A behaviour change updates its doc in the **same PR**. A doc that describes a
   mechanism you just replaced is worse than no doc.
2. If a rule is in AGENTS.md, docs/ states the *reasoning*, never the rule again.
3. Write prescriptively - "to do X, do D, because Y". No "we tried A, then B,
   then C" travelogue; when an approach is superseded, delete it rather than
   recording it as an alternative.
