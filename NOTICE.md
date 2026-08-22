# Notices and Attribution

Name Your Summons bundles content owned by third parties alongside its own
source code. This file records what is covered by the [MIT License](LICENSE),
what is not, and the trademark attributions that apply.

## Original work (MIT-licensed)

Except for the game-derived content listed below, everything in this repository
is original work, Copyright (c) 2026 whme, released under the [MIT
License](LICENSE). This includes, in particular:

- `NameYourSummons/Mods/NameYourSummons/ScriptExtender/**` - all Lua source.
- The `NYS_*` elements injected into the GUI overrides (see below).
- `spec/**` - the unit-test suite.
- `make.ps1` and the repository's build, CI, and configuration scripts.

## Game content included in this repository (NOT MIT-licensed)

The following files contain material derived from Baldur's Gate 3 and are the
property of Larian Studios. They are included solely to make the mod function
and are used under Larian Studios' mod policy / EULA. They are NOT granted under
the MIT License:

- Every `.xaml` under `NameYourSummons/Mods/NameYourSummons/GUI/` except the mod's
  own `Nys`-prefixed files (e.g. `NysHudOverlay.xaml`) - these override Larian's own
  game UI (the keyboard and controller variants of the Examine page) and reproduce
  its markup: the `ls:` controls, the `SmallBrownButtonStyle` / `TickBox` styles, the
  character-sheet layout, and the `pack://application:,,,/Core;component/Assets/...`
  asset references. Only the `NYS_*` elements this mod injects into them are original.
- `assets/nys-rename.png`, `assets/nys-ingame.png`, `assets/nys-settings.png`,
  and `assets/mod-thumbnail.png` - screenshots depicting Baldur's Gate 3,
  included for documentation and preview art. `assets/mod-thumbnail.png` is
  composited from `assets/nys-rename.png`.

These remain the property of their respective owners.

## Trademarks and attribution

- Baldur's Gate and Baldur's Gate 3 are trademarks and/or copyright of Larian
  Studios.
- Dungeons & Dragons and D&D are trademarks of Wizards of the Coast LLC (a
  subsidiary of Hasbro, Inc.). The creature-type names this mod filters on
  (Undead, Beast, Fey, and the other D&D 5e creature types) are D&D taxonomy;
  the mod reads them from the game's existing character tags and embeds no D&D
  rules text.
- Baldur's Gate Script Extender (BG3SE) is Copyright (c) Norbyte. It is required
  at runtime but is not bundled with this mod.

## Not affiliated - unofficial mod

Name Your Summons is an unofficial, fan-made mod. It is not affiliated with,
endorsed by, or sponsored by Larian Studios, Wizards of the Coast, or Hasbro. It
is distributed free of charge.

## Build tools (informational)

The following tools are downloaded on demand by `make.ps1` into gitignored
directories (`.tools/`, `.luals-libs/`) and are never committed to or
redistributed by this repository. Each remains under its own upstream license:

- LSLib / `divine.exe` (Norbyte)
- StyLua (JohnnyMorganz)
- luacheck (lunarmodules)
- lua-language-server (LuaLS)
- LuaUnit (bluebird75)
- changelogging (nekitdev)
- `ExtIdeHelpers.lua` (Norbyte), fetched for type checking only.
