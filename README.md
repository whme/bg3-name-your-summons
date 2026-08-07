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

Want to build from source instead? See [CONTRIBUTING.md](CONTRIBUTING.md).

## Using it

Summon something. The world freezes and a window appears in the center of the
screen with a text box pre-filled with the creature's current name, so you can
name it in peace. Type a name and press Enter (or *Name it*). *Skip* declines,
and you won't be asked again for that creature this session. The name comes back
automatically every time you re-summon that creature.

Out of combat the freeze is solo turn-based mode (the same pause the tactical
camera uses); in combat your turn is already paused, so nothing extra happens.
Play resumes as soon as you name or skip.

Each summoner keeps its own names, and different familiar shapes (cat, raven,
spider) are remembered separately.

### In-game config

The naming prompt has a *Settings* button that opens the config window (also
reachable from the console with `!nys_ui`). There you can:

- Review every saved name in the current save, grouped by the character that
  summoned it, then edit or forget any of them. Nothing takes effect until you
  press Save; closing the window discards unsaved edits. Saving applies each
  rename to any matching summon that is currently out, and reverts any summon
  whose name you forgot back to its original.
- Choose when the prompt appears:
  - **Ask me to name new summons** - turn the prompt on or off entirely.
  - **Also re-ask for summons I have already named** - when on, the prompt
    reappears for a summon that already has a saved name (pre-filled, so you can
    keep or change it); when off, a saved name is reapplied silently.
  - **Allow renaming story-bound summons (e.g. 'Us')** - off by default, so named
    story creatures like the intellect devourer "Us" are never offered the rename
    prompt; turn it on to name them like any other summon.

Settings and names live in the host's save.

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
| `!nys_ui` | **client** (type `client` first) | open the in-game config (settings + saved-name manager) |

If a name won't stick, run `!nys_diag` and paste the output when asking for help.

## Multiplayer

Names are stored in the host's save and only the summoner is prompted. This
should work in co-op, but is untested.
