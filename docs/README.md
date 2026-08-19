# Documentation index

[AGENTS.md](../AGENTS.md) carries the rules; these files carry the high-level
architecture and concepts. Details - exact timings, function names, engine traps -
live in the code and its inline comments, not here. **One fact lives in exactly one
place.**

## Read this when

| You are about to | Read |
|---|---|
| Touch anything under `Lua/Client/` or `GUI/` | [native-ui.md](native-ui.md), THEN [examine-panel.md](examine-panel.md) |
| Change `Lua/Server/` or `Lua/Shared/` behaviour, or a user-facing string | [architecture.md](architecture.md) |
| Touch `make.ps1`, a workflow, or a gate | [build-and-gates.md](build-and-gates.md) |
| Ask the user to run the game, or read their console | [ingame-debugging.md](ingame-debugging.md) |
| Need a fact about BG3's own XAML, stats, templates, or paks | [exploring-bg3-internals.md](exploring-bg3-internals.md) |
| Be unsure of an `Ext.*` / `Osi.*` / Noesis API shape | [bg3-modding-toolchain.md](bg3-modding-toolchain.md) |
| Set up, build, or cut a release | [../CONTRIBUTING.md](../CONTRIBUTING.md) |

## Maintaining these files

Keep them high-level and current. Update a doc in the same PR as the behaviour it
describes; put a non-obvious detail in an inline comment at its call site, not here;
and delete a superseded approach rather than recording it as a "we tried X" history.
