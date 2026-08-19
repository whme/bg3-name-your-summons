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

## What each file owns

Before adding a paragraph, check here for where it belongs - that is what keeps
one fact in one place.

- **architecture.md** - the server and shared side: detection, naming,
  persistence, keys, multi-summon semantics, localization, and the server half
  of prompting and the world pause.
- **native-ui.md** - the Noesis engine contract, including the whole controller
  focusable and accept contract.
- **examine-panel.md** - our own panels, and authoritative for the re-wire
  trigger list and the measured `!nys_uidump` tree depths.
- **build-and-gates.md** - the gate set, how far each gate takes you, and
  packaging. For the command list, run `./make.ps1 help`.
- **ingame-debugging.md** - getting a fact out of a running game via the user:
  console commands, tracing, the run loop.
- **exploring-bg3-internals.md** - getting a fact out of the game's own paks
  with `divine.exe`.
- **bg3-modding-toolchain.md** - the stack, and where each tool's authoritative
  documentation lives.
- **../CONTRIBUTING.md** - contributor setup, the git hook, news fragments, and
  the release walkthrough.

## Maintaining these files

1. Update a doc in the **same PR** as the behaviour it describes.
2. If a rule is in AGENTS.md, docs/ states the *reasoning*, never the rule again.
3. Write prescriptively - "to do X, do D, because Y". No "we tried A, then B,
   then C" travelogue; when an approach is superseded, delete it rather than
   recording it as an alternative.
