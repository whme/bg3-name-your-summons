# Name Your Summons - a BG3 mod for naming your summons

Names your summoned creatures, remembers the names, and reapplies them
automatically the next time you summon the same creature. Optionally pops a
text-entry prompt the moment a summon appears.

Requires [Norbyte's Script Extender](https://github.com/Norbyte/bg3se) (BG3SE).

## Installing

1. Download the latest `.pak` from the
   [Releases](https://github.com/whme/bg3-name-your-summons/releases) page.
2. Drop the `.pak` in
   `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods\`.
3. Enable the mod in-game from the **Mods** menu.

### Installing from source

Pack the top-level `NameYourSummons/` folder into a `.pak` with the **BG3
Modder's Multitool** (*Create Package*), then follow steps 2-3 above.

## Using it

Summon something. A window appears with a text box pre-filled with the
creature's current name. Type a name and press Enter (or *Name it*). *Skip*
declines, and you won't be asked again for that creature this session. The name
comes back automatically every time you re-summon that creature.

Each summoner keeps its own names, and different familiar shapes (cat, raven,
spider) are remembered separately.

### Console commands

The commands run in the Script Extender console - a separate window that opens
alongside the game once you enable it in
`%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\ScriptExtenderSettings.json`:

```json
{ "CreateConsole": true, "DeveloperMode": true }
```

| Command | Context | What it does |
|---|---|---|
| `!nys_list` | server | list all saved names |
| `!nys_diag` | server | dump what the game thinks your summons are named |
| `!nys_rename <name>` | server | rename the host's summons right now, no prompt |
| `!nys_clear` | server | wipe all saved names |
| `!nys_ui` | **client** (type `client` first) | open the saved-names manager |

If a name won't stick, run `!nys_diag` and paste the output when asking for help.

## Multiplayer

Names are stored in the host's save and only the summoner is prompted. This
should work in co-op, but is untested.
